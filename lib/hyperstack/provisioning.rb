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
      # empty string means "disable tool calling" (e.g. reasoning models).
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
      # vLLM nightly images may be missing pytest which cupy imports during engine init.
      # Prepend a quiet install so any pre_start_cmd also satisfies this dependency.
      pre_cmd = "pip install -q pytest 2>/dev/null; #{pre_cmd}" if pre_cmd
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
      # If the container is already running and serving the correct model, skip
      # the stop/pull/start cycle entirely — just wait for it to become ready.
      # This recovers gracefully from a previous create that timed out during the
      # readiness poll but left the container running successfully.
      script << "if docker inspect --format='{{.State.Status}}' #{Shellwords.escape(container)} 2>/dev/null | grep -q '^running$'; then"
      script << "  if curl -sf http://localhost:#{Shellwords.escape(port.to_s)}/v1/models 2>/dev/null | grep -q #{Shellwords.escape(model)}; then"
      script << "    echo 'vLLM container already running with #{model}; skipping restart.'"
      script << '    echo vllm-install-ok'
      script << '    exit 0'
      script << '  fi'
      script << "  echo 'Container #{container} is running but not serving #{model}; restarting.'"
      script << "  docker stop #{Shellwords.escape(container)} 2>/dev/null || true"
      script << "  docker rm #{Shellwords.escape(container)} 2>/dev/null || true"
      script << 'fi'
      script << "sudo mkdir -p #{Shellwords.escape(cache_dir)} #{Shellwords.escape(compile_cache)}"
      script << "sudo chmod -R 0777 #{Shellwords.escape(cache_dir)} #{Shellwords.escape(compile_cache)}"
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
      script << 'for i in $(seq 1 360); do'
      script << "  if curl -sf http://localhost:#{port}/v1/models >/dev/null 2>&1; then echo vllm-ready; break; fi"
      script << "  state=$(docker inspect --format='{{.State.Status}}' #{Shellwords.escape(container)} 2>/dev/null || echo unknown)"
      script << "  progress=$(docker logs --tail 100 #{Shellwords.escape(container)} 2>&1 | grep -E \"$stage_pat\" | tail -1 | sed -E \"$strip_pfx\" | cut -c1-100)"
      script << '  if [ -n "$progress" ]; then'
      script << '    echo "  vLLM ($i/360, $state): $progress"'
      script << '  else'
      script << '    echo "  vLLM not ready yet ($i/360, container=$state)..."'
      script << '  fi'
      script << '  sleep 5'
      script << 'done'
      script << "curl -sf http://localhost:#{port}/v1/models >/dev/null || { echo 'FATAL: vLLM did not become ready within 30 minutes'; exit 1; }"
      script << 'echo vllm-install-ok'
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

    def setup_vllm_stack(host, preset_config: nil)
      install_vllm(host, preset_config: preset_config)
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
