# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'shellwords'

module HyperstackVM
  class ProvisioningScripts
    def initialize(config:)
      @config = config
    end

    def guest_bootstrap_script
      script = []
      script << 'set -euo pipefail'

      # Wait for any running unattended-upgrades or apt locks to release
      # before attempting package operations (transient lock on fresh VMs)
      script << 'echo "Waiting for apt locks to clear..."'
      script << 'for i in $(seq 1 30); do'
      script << '  if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then break; fi'
      script << '  echo "  apt lock held, waiting ($i/30)..."; sleep 10'
      script << 'done'
      script << 'sudo systemctl stop unattended-upgrades.service 2>/dev/null || true'
      script << 'sudo systemctl disable unattended-upgrades.service 2>/dev/null || true'

      if @config.install_wireguard?
        script << 'which wg >/dev/null 2>&1 || (sudo apt-get update && sudo apt-get install -y wireguard)'
      end

      if @config.configure_ufw?
        script << "sudo ufw allow #{@config.ssh_port}/tcp comment 'Allow SSH' >/dev/null 2>&1 || true"
        script << 'sudo ufw --force enable >/dev/null 2>&1 || true'
        script << "sudo ufw allow #{@config.wireguard_udp_port}/udp comment 'WireGuard #{@config.local_interface_name}' >/dev/null 2>&1 || true"
        # Port 11434 is shared by Ollama and vLLM; open for both regardless of which is installed.
        script << "sudo ufw allow from #{Shellwords.escape(@config.wireguard_subnet)} to any port #{@config.ollama_port} proto tcp comment 'Inference API (Ollama/vLLM) via #{@config.local_interface_name}' >/dev/null 2>&1 || true"
        # ComfyUI REST API on port 8188; only open when ComfyUI is enabled.
        if @config.comfyui_install_enabled?
          script << "sudo ufw allow from #{Shellwords.escape(@config.wireguard_subnet)} to any port #{@config.comfyui_port} proto tcp comment 'ComfyUI API via #{@config.local_interface_name}' >/dev/null 2>&1 || true"
        end
      end

      if @config.configure_ollama_host?
        # Only write a minimal OLLAMA_HOST override if no override exists yet;
        # ollama_setup_script writes the full override (OLLAMA_MODELS, GPU_OVERHEAD, etc.)
        script << "if systemctl list-unit-files | grep -q '^ollama.service'; then"
        script << '  if [ ! -f /etc/systemd/system/ollama.service.d/override.conf ]; then'
        script << '    sudo mkdir -p /etc/systemd/system/ollama.service.d'
        script << "    cat <<'OVERRIDE' | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null"
        script << '[Service]'
        script << "Environment=\"OLLAMA_HOST=0.0.0.0:#{@config.ollama_port}\""
        script << 'OVERRIDE'
        script << '    sudo systemctl daemon-reload'
        script << '    sudo systemctl restart ollama || true'
        script << '  fi'
        script << 'fi'
      end

      script << 'echo bootstrap-ok'
      script.join("\n")
    end

    def desired_ollama_models
      normalized_model_list(@config.ollama_pull_models)
    end

    def model_list_signature(models)
      normalized_model_list(models).sort
    end

    def ollama_install_script
      models_dir = @config.ollama_models_dir
      listen_host = @config.ollama_listen_host

      script = []
      script << 'set -euo pipefail'
      script << 'sudo pkill -f unattended-upgrade >/dev/null 2>&1 || true'
      script << 'if ! command -v ollama >/dev/null 2>&1; then curl -fsSL https://ollama.ai/install.sh | sh; fi'
      if models_dir.start_with?('/ephemeral')
        script << "mountpoint -q /ephemeral || { echo 'Expected /ephemeral mount is missing'; exit 1; }"
      end
      script << "sudo mkdir -p #{Shellwords.escape(models_dir)}"
      script << "sudo chown -R ollama:ollama #{Shellwords.escape(models_dir)}"
      script << 'sudo mkdir -p /etc/systemd/system/ollama.service.d'
      script << "cat <<'OVERRIDE' | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null"
      script << '[Service]'
      script << "Environment=\"OLLAMA_MODELS=#{models_dir}\""
      script << "Environment=\"OLLAMA_GPU_OVERHEAD=#{@config.ollama_gpu_overhead_mb}\""
      script << "Environment=\"OLLAMA_NUM_PARALLEL=#{@config.ollama_num_parallel}\""
      script << "Environment=\"OLLAMA_CONTEXT_LENGTH=#{@config.ollama_context_length}\""
      script << "Environment=\"OLLAMA_HOST=#{listen_host}\""
      script << 'OVERRIDE'
      script << 'sudo systemctl daemon-reload'
      script << 'sudo systemctl enable --now ollama'
      script << 'sudo systemctl restart ollama'
      script << 'sleep 3'
      script << 'systemctl is-active --quiet ollama'
      script << 'echo ollama-install-ok'
      script.join("\n")
    end

    def ollama_pull_script(models: desired_ollama_models)
      models_dir = @config.ollama_models_dir

      script = []
      script << 'set -euo pipefail'
      # Pull each model with retry (transient network failures) and verify
      # it is actually present afterwards
      models.each do |model|
        escaped = Shellwords.escape(model)
        script << "echo \"Pulling model #{model}...\""
        script << 'for attempt in 1 2 3; do'
        script << "  if ollama pull #{escaped}; then break; fi"
        script << "  if [ \"$attempt\" -eq 3 ]; then echo \"FATAL: failed to pull #{model} after 3 attempts\"; exit 1; fi"
        script << '  echo "  pull attempt $attempt failed, retrying in 15s..."; sleep 15'
        script << 'done'
        script << "ollama show #{escaped} --modelfile >/dev/null 2>&1 || { echo \"FATAL: model #{model} not found after pull\"; exit 1; }"
      end
      # Final verification: ensure all expected models are listed
      script << 'echo "Verifying all models are present..."'
      models.each do |model|
        escaped = Shellwords.escape(model)
        script << "ollama show #{escaped} --modelfile >/dev/null 2>&1 || { echo \"FATAL: model #{model} missing in final check\"; exit 1; }"
      end
      script << "echo ollama-models-dir=#{models_dir}"
      script << 'echo ollama-ok'
      script.join("\n")
    end

    def vllm_stop_script(container_name)
      script = []
      script << 'set -euo pipefail'
      script << "docker stop #{Shellwords.escape(container_name)} 2>/dev/null || true"
      script << "docker rm #{Shellwords.escape(container_name)} 2>/dev/null || true"
      script << 'echo vllm-stopped'
      script.join("\n")
    end

    def vllm_install_script(preset_config: nil, pull_image: true)
      cfg = preset_config || {}
      model = cfg['model'] || @config.vllm_model
      cache_dir = @config.vllm_hug_cache_dir
      compile_cache = @config.vllm_compile_cache_dir
      container = cfg['container_name'] || @config.vllm_container_name
      max_len = Integer(cfg['max_model_len'] || @config.vllm_max_model_len)
      gpu_util = Float(cfg['gpu_memory_utilization'] || @config.vllm_gpu_memory_utilization)
      tp_size = Integer(cfg['tensor_parallel_size'] || @config.vllm_tensor_parallel_size)
      parser = cfg['tool_call_parser']
      # parser is nil only when preset explicitly omits the key and config has no default;
      # empty string means "disable tool calling" (e.g. gpt-oss reasoning models).
      parser = @config.vllm_tool_call_parser if parser.nil?
      # Fall back to the top-level [vllm] config values when no preset is in use.
      # This allows setting trust_remote_code / extra_vllm_args in the default [vllm] block
      # without requiring a --model preset flag at create time.
      trust_remote = cfg.key?('trust_remote_code') ? cfg['trust_remote_code'] : @config.vllm_trust_remote_code
      # Prefix caching: preset value takes priority; nil means fall back to top-level [vllm] setting.
      prefix_cache = if cfg.key?('enable_prefix_caching') && !cfg['enable_prefix_caching'].nil?
                       cfg['enable_prefix_caching'] == true
                     else
                       @config.vllm_prefix_caching_enabled?
                     end
      extra_env = cfg.key?('extra_docker_env') ? Array(cfg['extra_docker_env']) : @config.vllm_extra_docker_env
      # docker_image: preset value takes priority; nil falls back to [vllm] top-level or default.
      image = (cfg.key?('docker_image') ? cfg['docker_image'] : nil) || @config.vllm_docker_image
      # pre_start_cmd: shell command to run inside the container before vLLM starts.
      # When set, --entrypoint bash is used so the command can patch dependencies at runtime
      # (e.g. upgrading transformers for Gemma 4, which requires transformers>=5.x).
      pre_cmd = (cfg.key?('pre_start_cmd') ? cfg['pre_start_cmd'] : nil) || @config.vllm_pre_start_cmd
      port = @config.ollama_port

      docker_args = [
        'docker run -d',
        '--gpus all', '--ipc=host', '--network host',
        "--name #{Shellwords.escape(container)}",
        '--restart always',
        "-v #{Shellwords.escape(cache_dir)}:/root/.cache/huggingface",
        # Mount torch.compile cache so CUDA kernel compilation is skipped on warm restarts.
        # Without this, every container restart recompiles (~30-60 s extra).
        "-v #{Shellwords.escape(compile_cache)}:/root/.cache/vllm"
      ]
      # Extra Docker env vars (e.g. CUDA_VISIBLE_DEVICES=0) injected before the image name.
      extra_env.each { |kv| docker_args << "-e #{Shellwords.escape(kv)}" }
      # vllm_flags holds the vLLM CLI arguments (everything passed after the image name).
      # Kept separate from docker_args so pre_start_cmd can wrap them in a bash -c string.
      vllm_flags = [
        "--model #{Shellwords.escape(model)}",
        "--tensor-parallel-size #{tp_size}",
        "--gpu-memory-utilization #{gpu_util}",
        "--max-model-len #{max_len}",
        '--host 0.0.0.0',
        "--port #{port}"
      ]
      # Prefix caching is beneficial for most models but forces Mamba "all" cache mode on
      # NemotronH, which pre-allocates states for all sequences and can OOM on startup.
      vllm_flags << '--enable-prefix-caching' if prefix_cache
      # Tool calling is optional: empty/nil parser disables it.
      unless parser.nil? || parser.empty?
        vllm_flags << '--enable-auto-tool-choice'
        vllm_flags << "--tool-call-parser #{Shellwords.escape(parser)}"
      end
      vllm_flags << '--trust-remote-code' if trust_remote
      extra_args = cfg.key?('extra_vllm_args') ? Array(cfg['extra_vllm_args']) : @config.vllm_extra_args
      extra_args.each { |arg| vllm_flags << arg }

      # When pre_start_cmd is set (e.g. to upgrade transformers for Gemma 4), override the
      # container entrypoint to bash and chain the patch command before vLLM starts.
      # CUDA_VISIBLE_DEVICES must be set via extra_docker_env when using --entrypoint bash because
      # the EngineCore subprocess loses GPU visibility without it (DP adjusted local rank OOB error).
      docker_run = if pre_cmd
                     vllm_cmd = "python3 -m vllm.entrypoints.openai.api_server #{vllm_flags.join(' ')}"
                     entrypoint_cmd = Shellwords.escape("#{pre_cmd}; #{vllm_cmd}")
                     "#{docker_args.join(' ')} --entrypoint bash #{image} -c #{entrypoint_cmd}"
                   else
                     "#{docker_args.join(' ')} #{image} #{vllm_flags.join(' ')}"
                   end

      script = []
      script << 'set -euo pipefail'
      script << "sudo mkdir -p #{Shellwords.escape(cache_dir)} #{Shellwords.escape(compile_cache)}"
      script << "sudo chmod -R 0777 #{Shellwords.escape(cache_dir)} #{Shellwords.escape(compile_cache)}"
      script << "docker stop #{Shellwords.escape(container)} 2>/dev/null || true"
      script << "docker rm #{Shellwords.escape(container)} 2>/dev/null || true"
      script << "docker pull #{Shellwords.escape(image)}" if pull_image
      script << docker_run
      # Stage patterns cover the full vLLM startup sequence:
      #   HuggingFace download → safetensors shard loading → torch.compile → CUDA graphs → API up.
      # The sed strip removes the "(EngineCore pid=N) INFO date time [file.py:line] " log prefix
      # so only the human-readable message is shown.
      stage_pat = 'Starting to load model|Fetching|Downloading shards|checkpoint shards:.*% Completed' \
                  '|Loading weights took|Model loading took|torch\\.compile took' \
                  '|Graph capturing|Application startup complete'
      strip_pfx = 's/^\\([A-Za-z]+ [^)]+\\) INFO [^ ]+ [^ ]+ \\[[^]]+\\] //'
      script << 'echo "Waiting for vLLM to become ready (live progress from container logs)..."'
      script << "stage_pat='#{stage_pat}'"
      script << "strip_pfx='#{strip_pfx}'"
      script << 'for i in $(seq 1 240); do'
      script << "  if curl -sf http://localhost:#{port}/v1/models >/dev/null 2>&1; then echo vllm-ready; break; fi"
      script << "  state=$(docker inspect --format='{{.State.Status}}' #{Shellwords.escape(container)} 2>/dev/null || echo unknown)"
      script << "  progress=$(docker logs --tail 100 #{Shellwords.escape(container)} 2>&1 | grep -E \"$stage_pat\" | tail -1 | sed -E \"$strip_pfx\" | cut -c1-100)"
      script << '  if [ -n "$progress" ]; then'
      script << '    echo "  vLLM ($i/240, $state): $progress"'
      script << '  else'
      script << '    echo "  vLLM not ready yet ($i/240, container=$state)..."'
      script << '  fi'
      script << '  sleep 5'
      script << 'done'
      script << "curl -sf http://localhost:#{port}/v1/models >/dev/null || { echo 'FATAL: vLLM did not become ready within 20 minutes'; exit 1; }"
      script << 'echo vllm-install-ok'
      script.join("\n")
    end

    def comfyui_install_script
      models_dir  = @config.comfyui_models_dir
      output_dir  = @config.comfyui_output_dir
      port        = @config.comfyui_port
      model_names = @config.comfyui_models
      # Use ubuntu home dir to avoid /opt permission issues when running as the SSH user.
      install_dir = '/home/ubuntu/ComfyUI'
      venv_dir    = '/home/ubuntu/comfyui-venv'
      service     = 'comfyui'

      script = []
      script << 'set -euo pipefail'

      # Wait for apt locks released by unattended-upgrades before touching packages.
      script << 'for i in $(seq 1 30); do'
      script << '  if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then break; fi'
      script << '  echo "  apt lock held, waiting ($i/30)..."; sleep 10'
      script << 'done'
      script << 'sudo pkill -f unattended-upgrade >/dev/null 2>&1 || true'

      # Install system deps: git, python venv, wget.
      script << 'sudo apt-get update -qq'
      script << 'sudo apt-get install -y -qq git python3-venv python3-pip wget'

      # Ephemeral NVMe dirs for models and output.
      script << "sudo mkdir -p #{Shellwords.escape(models_dir)} #{Shellwords.escape(output_dir)}"
      script << "sudo chmod -R 0777 #{Shellwords.escape(models_dir)} #{Shellwords.escape(output_dir)}"

      # Clone or update ComfyUI from the official repo (no sudo needed in ubuntu home).
      script << "if [ ! -d #{Shellwords.escape(install_dir)} ]; then"
      script << "  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI #{Shellwords.escape(install_dir)}"
      script << 'else'
      script << "  git -C #{Shellwords.escape(install_dir)} pull --ff-only"
      script << 'fi'

      # Create Python venv and install PyTorch + ComfyUI deps.
      # CUDA 12.8 is installed on the VM; cu128 wheel index covers it.
      script << "[ -d #{Shellwords.escape(venv_dir)} ] || python3 -m venv #{Shellwords.escape(venv_dir)}"
      script << "#{venv_dir}/bin/pip install --quiet --upgrade pip"
      script << "#{venv_dir}/bin/pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128"
      script << "#{venv_dir}/bin/pip install --quiet -r #{Shellwords.escape("#{install_dir}/requirements.txt")}"

      # Symlink ephemeral model/output dirs into the ComfyUI directory tree.
      script << "rm -rf #{Shellwords.escape("#{install_dir}/models")} && ln -sfn #{Shellwords.escape(models_dir)} #{Shellwords.escape("#{install_dir}/models")}"
      script << "rm -rf #{Shellwords.escape("#{install_dir}/output")} && ln -sfn #{Shellwords.escape(output_dir)} #{Shellwords.escape("#{install_dir}/output")}"

      # Systemd service so ComfyUI starts on reboot.
      script << "cat <<'UNIT' | sudo tee /etc/systemd/system/#{Shellwords.escape(service)}.service >/dev/null"
      script << '[Unit]'
      script << 'Description=ComfyUI photo enhancement server'
      script << 'After=network.target'
      script << '[Service]'
      script << "ExecStart=#{venv_dir}/bin/python #{install_dir}/main.py --listen 0.0.0.0 --port #{port} --output-directory #{output_dir}"
      script << 'Restart=on-failure'
      script << 'RestartSec=5'
      script << "WorkingDirectory=#{install_dir}"
      script << 'Environment=HOME=/root'
      script << '[Install]'
      script << 'WantedBy=multi-user.target'
      script << 'UNIT'
      script << 'sudo systemctl daemon-reload'
      script << "sudo systemctl enable --now #{Shellwords.escape(service)}"
      script << "sudo systemctl restart #{Shellwords.escape(service)}"

      # Wait for ComfyUI API to respond (model loading and CUDA init can take ~60s).
      script << 'echo "Waiting for ComfyUI to become ready (up to 5 min)..."'
      script << 'for i in $(seq 1 60); do'
      script << "  if curl -sf http://localhost:#{port}/system_stats >/dev/null 2>&1; then echo comfyui-ready; break; fi"
      script << '  echo "  ComfyUI not ready yet ($i/60)..."; sleep 5'
      script << 'done'
      script << "curl -sf http://localhost:#{port}/system_stats >/dev/null || { echo 'FATAL: ComfyUI did not become ready within 5 minutes'; exit 1; }"

      # Install ComfyUI-SUPIR custom node (provides SUPIR_Upscale and related nodes).
      supir_node_dir = "#{install_dir}/custom_nodes/ComfyUI-SUPIR"
      script << "if [ ! -d #{Shellwords.escape(supir_node_dir)} ]; then"
      script << "  git clone --depth 1 https://github.com/kijai/ComfyUI-SUPIR #{Shellwords.escape(supir_node_dir)}"
      script << "  #{venv_dir}/bin/pip install --quiet -r #{Shellwords.escape("#{supir_node_dir}/requirements.txt")}"
      script << 'fi'

      # Download model weights into the ComfyUI subdirectories.
      # Real-ESRGAN → upscale_models/; SUPIR → checkpoints/; SDXL base → checkpoints/.
      model_names.each do |model_name|
        case model_name
        when /RealESRGAN/i
          dest_dir = "#{models_dir}/upscale_models"
          url = if model_name =~ /anime/i
                  'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth'
                else
                  'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth'
                end
          dest_file = "#{dest_dir}/#{model_name}.pth"
          script << "mkdir -p #{Shellwords.escape(dest_dir)}"
          script << "[ -f #{Shellwords.escape(dest_file)} ] || wget -q --show-progress -O #{Shellwords.escape(dest_file)} #{Shellwords.escape(url)}"
        when /SUPIR/i
          # SUPIR-v0Q (~5 GB): AI photo restoration backbone (denoising + detail recovery).
          # SDXL base (~7 GB): provides CLIP encoders that SUPIR uses for text conditioning.
          # Both must live in checkpoints/ so SUPIR_Upscale can find them by filename.
          dest_dir = "#{models_dir}/checkpoints"
          hf_file = model_name.end_with?('F') ? 'SUPIR-v0F.ckpt' : 'SUPIR-v0Q.ckpt'
          supir_url = "https://huggingface.co/camenduru/SUPIR/resolve/main/#{hf_file}"
          sdxl_url  = 'https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors'
          script << "mkdir -p #{Shellwords.escape(dest_dir)}"
          script << "[ -f #{Shellwords.escape("#{dest_dir}/#{hf_file}")} ] || wget -q --show-progress -O #{Shellwords.escape("#{dest_dir}/#{hf_file}")} #{Shellwords.escape(supir_url)}"
          script << "[ -f #{Shellwords.escape("#{dest_dir}/sd_xl_base_1.0.safetensors")} ] || wget -q --show-progress -O #{Shellwords.escape("#{dest_dir}/sd_xl_base_1.0.safetensors")} #{Shellwords.escape(sdxl_url)}"
        end
      end

      # Restart ComfyUI so it picks up the new custom nodes and model files.
      script << "sudo systemctl restart #{Shellwords.escape(service)}"
      script << 'echo "Waiting for ComfyUI restart..."'
      script << 'for i in $(seq 1 60); do'
      script << "  if curl -sf http://localhost:#{port}/system_stats >/dev/null 2>&1; then echo comfyui-ready; break; fi"
      script << '  echo "  ComfyUI not ready yet ($i/60)..."; sleep 5'
      script << 'done'

      script << 'echo comfyui-install-ok'
      script.join("\n")
    end

    def litellm_decommission_script
      script = []
      script << 'set -euo pipefail'
      script << 'sudo systemctl stop litellm 2>/dev/null || true'
      script << 'sudo systemctl disable litellm 2>/dev/null || true'
      script << 'sudo rm -f /etc/systemd/system/litellm.service'
      script << 'sudo systemctl daemon-reload'
      script << 'sudo rm -f /ephemeral/litellm-config.yaml'
      script << 'sudo rm -rf /ephemeral/litellm-env'
      script << 'sudo rm -f /ephemeral/litellm.log'
      script << "sudo ufw --force delete allow from #{Shellwords.escape(@config.wireguard_subnet)} to any port 4000 proto tcp >/dev/null 2>&1 || true"
      script << 'echo litellm-decommission-ok'
      script.join("\n")
    end

    private

    def normalized_model_list(models)
      Array(models).each_with_object([]) do |model, ordered|
        normalized = model.to_s.strip
        next if normalized.empty? || ordered.include?(normalized)

        ordered << normalized
      end
    end
  end

  class RemoteProvisioner
    def initialize(config:, scripts:, out:, ssh_command_runner:, ssh_stream_runner:)
      @config = config
      @scripts = scripts
      @out = out
      @ssh_command_runner = ssh_command_runner
      @ssh_stream_runner = ssh_stream_runner
    end

    def bootstrap_guest(host)
      info 'Bootstrapping Ubuntu guest over SSH...'
      retries = 3
      retries.times do |attempt|
        # Stream output so apt-lock waits and individual bootstrap steps are visible in real time.
        output, status = @ssh_stream_runner.call(host, @scripts.guest_bootstrap_script)
        return if status.success?

        msg = output.lines.last&.strip || output.strip
        raise Error, "Guest bootstrap failed after #{retries} attempts: #{msg}" if attempt == retries - 1

        warn "Bootstrap attempt #{attempt + 1}/#{retries} failed (#{msg}), retrying in 15s..."
        sleep 15
      end
    end

    def install_ollama_service(host)
      info "Installing and configuring Ollama on #{host}..."
      output, status = @ssh_stream_runner.call(host, @scripts.ollama_install_script)
      raise Error, "Ollama install failed: #{output.strip}" unless status.success?
    end

    def pull_ollama_models(host)
      info "Pulling Ollama models on #{host}..."
      output, status = @ssh_stream_runner.call(host, @scripts.ollama_pull_script)
      raise Error, "Ollama model pull failed: #{output.strip}" unless status.success?

      verify_remote_models(host)
    end

    def stop_vllm_container(host, container_name)
      info "Stopping old vLLM container #{container_name}..."
      output, status = @ssh_stream_runner.call(host, @scripts.vllm_stop_script(container_name))
      raise Error, "Failed to stop container #{container_name}: #{output.strip}" unless status.success?
    end

    def install_vllm(host, preset_config: nil, pull_image: true)
      info "Setting up vLLM Docker container on #{host}..."
      output, status = @ssh_stream_runner.call(host, @scripts.vllm_install_script(preset_config: preset_config,
                                                                                  pull_image: pull_image))
      raise Error, "vLLM install failed: #{output.strip}" unless status.success?
    end

    def decommission_litellm(host)
      info "Removing deprecated LiteLLM service from #{host} if present..."
      output, status = @ssh_stream_runner.call(host, @scripts.litellm_decommission_script)
      raise Error, "LiteLLM decommission failed: #{output.strip}" unless status.success?
    end

    def setup_vllm_stack(host, preset_config: nil)
      install_vllm(host, preset_config: preset_config)
    end

    def install_comfyui(host)
      info "Setting up ComfyUI Docker container on #{host}..."
      output, status = @ssh_stream_runner.call(host, @scripts.comfyui_install_script)
      raise Error, "ComfyUI install failed: #{output.strip}" unless status.success?
    end

    private

    def verify_remote_models(host)
      stdout, _stderr, status = @ssh_command_runner.call(host, 'ollama list')
      return unless status.success?

      remote_models = stdout.lines.drop(1).map { |line| line.split.first }.compact
      missing = @scripts.desired_ollama_models.reject do |model|
        remote_models.any? do |remote|
          remote.start_with?(model)
        end
      end
      return if missing.empty?

      raise Error, "Models missing after setup: #{missing.join(', ')}. Remote has: #{remote_models.join(', ')}"
    end

    def info(message)
      @out.puts(message)
    end

    def warn(message)
      @out.puts("WARNING: #{message}")
    end
  end

end
