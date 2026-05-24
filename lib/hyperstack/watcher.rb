# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'socket'

module HyperstackVM
  class VllmWatcher
    REFRESH_INTERVAL = 5

    # ANSI escape helpers
    BOLD   = "\033[1m"
    DIM    = "\033[2m"
    GREEN  = "\033[32m"
    YELLOW = "\033[33m"
    CYAN   = "\033[36m"
    RED    = "\033[31m"
    RESET  = "\033[0m"
    CLEAR  = "\033[2J\033[H"

    # Snapshot of one VM's stats at a point in time.
    # loading_status holds the last meaningful log line while vLLM is still initialising;
    # it is nil once the Engine 0 stats line starts appearing.
    VmSnapshot = Struct.new(
      :label, :wg_host, :service_type,
      :vllm_model, :container_name,
      :metrics, :gpus,
      :vllm_error, :gpu_error,
      :loading_status,
      :fetched_at,
      keyword_init: true
    )

    # Parsed per-GPU row from nvidia-smi.
    GpuInfo = Struct.new(
      :index, :name, :temp_c, :util_pct, :power_w,
      :mem_used_mib, :mem_total_mib,
      keyword_init: true
    )

    def initialize(config_loaders:)
      @config_loaders = config_loaders
    end

    # Runs the watch loop until the user presses Ctrl-C.
    def run
      $stdout.print "\033[?25l" # hide cursor
      loop do
        snapshots = fetch_all_parallel
        draw(snapshots)
        sleep REFRESH_INTERVAL
      end
    rescue Interrupt
      nil
    ensure
      $stdout.print "\033[?25h\n" # restore cursor
    end

    private

    # Fetches stats for every VM concurrently and returns an array of VmSnapshot.
    def fetch_all_parallel
      threads = @config_loaders.map { |loader| Thread.new { fetch_vm(loader) } }
      threads.map(&:value)
    end

    # Fetches GPU stats and vLLM container stats for a single VM via one SSH session.
    def fetch_vm(loader)
      config  = loader.config
      label   = File.basename(loader.path, '.toml')
      wg_host = config.wireguard_gateway_hostname
      state   = load_state(config.state_file)

      unless state
        return VmSnapshot.new(label: label, wg_host: wg_host, service_type: :vllm,
                              vllm_model: nil, container_name: nil,
                              metrics: nil, gpus: nil,
                              vllm_error: 'no state file', gpu_error: nil,
                              loading_status: nil, fetched_at: Time.now)
      end

      fetch_vllm_vm(config, label, wg_host, state)
    rescue StandardError => e
      VmSnapshot.new(label: label || '?', wg_host: wg_host || '?', service_type: :vllm,
                     vllm_model: nil, container_name: nil,
                     metrics: nil, gpus: nil,
                     vllm_error: e.message, gpu_error: nil,
                     loading_status: nil, fetched_at: Time.now)
    end

    # Fetches GPU + vLLM container stats for a vLLM VM.
    def fetch_vllm_vm(config, label, wg_host, state)
      vllm_model     = state['vllm_model'] || config.vllm_model
      container_name = state['vllm_container_name'] || config.vllm_container_name

      gpus, metrics, loading_status, ssh_error = fetch_vm_stats(config, wg_host, container_name)

      VmSnapshot.new(label: label, wg_host: wg_host, service_type: :vllm,
                     vllm_model: vllm_model, container_name: container_name,
                     metrics: metrics, gpus: gpus,
                     vllm_error: ssh_error, gpu_error: ssh_error,
                     loading_status: loading_status, fetched_at: Time.now)
    end

    def load_state(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # Single SSH call that runs nvidia-smi and tails the vLLM container logs.
    # Captures the Engine 0 stats line (present once the model is running) and,
    # when that line is absent, the last relevant loading-phase log line so the
    # watch display can show model-download / weight-load progress.
    # Returns [gpus, metrics, loading_status, error_or_nil].
    def fetch_vm_stats(config, wg_host, container_name)
      gpu_query = 'index,name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total'
      # Capture logs once into a shell variable to avoid two docker calls.
      # --tail 300 instead of --since N so we always get the last stats line
      # even when the VM has been idle for longer than the refresh interval.
      # grep exit 1 (no match) is swallowed by the pipeline tail -1, which
      # always succeeds, so bash -se does not abort on an empty grep result.
      script = <<~BASH
        nvidia-smi --query-gpu=#{gpu_query} --format=csv,noheader,nounits
        echo ===VLLM===
        _logs=$(docker logs --tail 300 #{container_name} 2>&1)
        echo "$_logs" | grep 'Engine 0' | tail -1
        echo ===LOADING===
        echo "$_logs" | grep -E 'Starting to load|Loading model|model weight|Downloading|GPU block|Profil|shard|Initializ|quantiz|AWQ' | tail -1
      BASH

      ssh = build_ssh_command(config, wg_host)
      stdout, stderr, status = Open3.capture3(*ssh, stdin_data: script)
      return [nil, nil, nil, "exit #{status.exitstatus}: #{stderr.strip}"] unless status.success?

      gpu_section, rest       = stdout.split("===VLLM===\n", 2)
      vllm_section, load_section = rest.to_s.split("===LOADING===\n", 2)
      gpus    = parse_nvidia_smi(gpu_section.to_s)
      metrics = parse_engine_log_line(vllm_section.to_s.strip)
      # Only surface the loading line while the engine stats aren't available yet.
      loading_status = metrics.empty? ? clean_log_line(load_section.to_s.strip) : nil
      [gpus, metrics, loading_status, nil]
    end

    # Parse a vLLM "Engine 0" log line into a plain Hash.
    # Actual log format (loggers.py):
    #   (APIServer pid=1) INFO ... [loggers.py:259] Engine 000:
    #     Avg prompt throughput: 6154.6 tokens/s,
    #     Avg generation throughput: 27.4 tokens/s,
    #     Running: 1 reqs, Waiting: 0 reqs,
    #     GPU KV cache usage: 0.7%, Prefix cache hit rate: 0.0%
    # Returns an empty hash when no matching line was found (container still loading).
    def parse_engine_log_line(line)
      return {} if line.empty?

      {
        'avg_prompt_throughput' => extract_float(line, /Avg prompt throughput:\s*([\d.]+)/),
        'avg_generation_throughput' => extract_float(line, /Avg generation throughput:\s*([\d.]+)/),
        'running' => extract_float(line, /Running:\s*(\d+)\s*reqs/),
        'pending' => extract_float(line, /Waiting:\s*(\d+)\s*reqs/),
        'swapped' => extract_float(line, /Swapped:\s*(\d+)\s*reqs/),
        'gpu_cache_usage_pct' => extract_float(line, /GPU KV cache usage:\s*([\d.]+)%/),
        'gpu_prefix_cache_hit_rate_pct' => extract_float(line, /Prefix cache hit rate:\s*([\d.]+)%/)
      }.compact
    end

    def extract_float(text, pattern)
      m = text.match(pattern)
      m ? m[1].to_f : nil
    end

    # Strips the vLLM log prefix "(EngineCore pid=N) INFO YYYY-MM-DD HH:MM:SS [file.py:NN]"
    # so only the human-readable message is shown in the watch display.
    def clean_log_line(line)
      return line if line.empty?

      line.sub(/^\(.*?pid=\d+\)\s+\w+\s+[\d-]+\s+[\d:]+\s+\[[\w.]+:\d+\]\s*/, '').strip
    end

    # Build an SSH command array for the watcher.
    # Uses accept-new rather than yes because the known-hosts file was populated
    # with the VM's public IP during provisioning; the WireGuard hostname
    # (hyperstack1.wg1 etc.) won't be in it yet. accept-new auto-trusts the first
    # connection and caches the key — safe here because we're connecting over the
    # already-authenticated WireGuard tunnel.
    def build_ssh_command(config, host)
      cmd = [
        'ssh',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', "UserKnownHostsFile=#{config.ssh_known_hosts_path}",
        '-o', "ConnectTimeout=#{config.ssh_connect_timeout}",
        '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=3',
        '-p', config.ssh_port.to_s
      ]
      key = config.ssh_private_key_path
      cmd.concat(['-i', key]) if File.exist?(key)
      cmd << "#{config.ssh_username}@#{host}"
      cmd << 'bash -se'
      cmd
    end

    def parse_nvidia_smi(text)
      text.lines.filter_map do |line|
        parts = line.strip.split(',').map(&:strip)
        next if parts.length < 7

        GpuInfo.new(
          index: parts[0].to_i,
          name: parts[1],
          temp_c: parts[2].to_f,
          util_pct: parts[3].to_f,
          power_w: parts[4].to_f,
          mem_used_mib: parts[5].to_f,
          mem_total_mib: parts[6].to_f
        )
      end
    end

    # ── Rendering ────────────────────────────────────────────────────────────

    # Clears the screen and redraws the full dashboard for all VMs.
    def draw(snapshots)
      time_str = Time.now.strftime('%H:%M:%S')
      header   = "#{BOLD}#{CYAN}VM watch#{RESET}    " \
                 "#{DIM}#{time_str}  Ctrl-C to stop  " \
                 "refreshing every #{REFRESH_INTERVAL}s#{RESET}"

      panels = snapshots.map { |snap| render_vm(snap) }

      if panels.size >= 2
        # Lay out VM panels side-by-side, padding each to its own visible width
        # so the separator column stays aligned regardless of content length.
        panel_widths = panels.map { |p| p.map { |l| strip_ansi(l).length }.max.to_i }
        max_rows     = panels.map(&:size).max
        panels.each { |p| p.fill('', p.size...max_rows) }
        sep = "  #{DIM}│#{RESET}  "

        panel_lines = (0...max_rows).map do |i|
          panels.each_with_index.map do |panel, j|
            cell = panel[i] || ''
            # Pad every column except the last so the separator stays in column.
            next cell if j == panels.size - 1

            visible_len = strip_ansi(cell).length
            cell + ' ' * [panel_widths[j] - visible_len, 0].max
          end.join(sep)
        end

        rule_w = [strip_ansi(panel_lines.first || '').length, 72].max
        rule   = DIM + ('─' * rule_w) + RESET
        lines  = [header, rule, *panel_lines, '']
      else
        # Single VM: simple vertical layout.
        rule  = DIM + ('─' * 72) + RESET
        lines = [header, rule]
        panels.each do |p|
          lines << ''
          lines.concat(p)
        end
        lines << ''
      end

      $stdout.write(CLEAR + lines.join("\n"))
      $stdout.flush
    end

    # Width of the label column used in every metric row, keeping bars aligned.
    LABEL_W = 10

    # Renders a single VM panel as an array of strings (one per display line).
    def render_vm(snap)
      lines = []

      model_label = snap.vllm_model ? DIM + snap.vllm_model.split('/').last + RESET : ''
      lines << "#{BOLD}#{snap.label}#{RESET}  #{DIM}#{snap.wg_host}#{RESET}  #{model_label}"

      # Both GPU and service stats come from the same SSH call; show one error if it failed.
      if snap.gpu_error
        lines << "  #{RED}#{snap.gpu_error}#{RESET}"
      else
        snap.gpus&.each do |gpu|
          mem_pct = gpu.mem_total_mib > 0 ? (gpu.mem_used_mib / gpu.mem_total_mib * 100.0) : 0.0
          lines << format('  GPU%-2d  %-26s  %3.0f°C  %5.0fW',
                          gpu.index, gpu.name, gpu.temp_c, gpu.power_w)
          lines << bar_row('util', gpu.util_pct)
          lines << bar_row('VRAM', mem_pct)
        end
        if snap.metrics&.any?
          lines.concat(render_vllm_metrics(snap.metrics))
        elsif snap.metrics
          # Engine stats not yet available — model is still loading.
          if snap.loading_status && !snap.loading_status.empty?
            lines << row('loading', "#{YELLOW}#{snap.loading_status}#{RESET}")
          else
            lines << "  #{DIM}(container starting…)#{RESET}"
          end
        end
      end

      lines
    end

    # Formats the vLLM engine log stats into display lines.
    # All values come directly from the "Engine 0" log line that vLLM emits
    # every few seconds, so tok/s figures are the rolling averages vLLM computes
    # internally — no client-side rate derivation needed.
    def render_vllm_metrics(m)
      lines = []

      # Throughput: rolling averages already computed by vLLM
      prefill_tps = m['avg_prompt_throughput']
      decode_tps  = m['avg_generation_throughput']
      tput_parts  = []
      tput_parts << "prefill #{format('%.1f', prefill_tps)} tok/s" if prefill_tps
      tput_parts << "decode #{format('%.1f', decode_tps)} tok/s"   if decode_tps
      lines << row('throughput', tput_parts.empty? ? 'n/a' : tput_parts.join('  '))

      # Request queue depth
      running = m['running']
      swapped = m['swapped']
      pending = m['pending']
      q_parts = []
      q_parts << "#{running.to_i} running" if running
      q_parts << "#{pending.to_i} waiting" if pending
      q_parts << "#{swapped.to_i} swapped" if swapped && swapped > 0
      lines << row('requests', q_parts.empty? ? 'n/a' : q_parts.join('  '))

      # KV-cache fill and prefix-cache hit rate, each with an aligned bar
      gpu_cache    = m['gpu_cache_usage_pct']
      hit_rate_gpu = m['gpu_prefix_cache_hit_rate_pct']
      lines << bar_row('KV cache',   gpu_cache)    if gpu_cache
      lines << bar_row('cache hits', hit_rate_gpu) if hit_rate_gpu

      lines
    end

    # Formats one metric row: fixed-width label then value, giving all rows the same indent.
    def row(label, value)
      "  #{label.ljust(LABEL_W)}  #{value}"
    end

    # Formats one bar row: fixed-width label, proportional bar, percentage number.
    # All bar rows share the same column for '[', aligning bars across GPU and vLLM sections.
    def bar_row(label, pct)
      row(label, "#{pct_bar(pct, 10)}  #{format('%5.1f', pct)}%")
    end

    # Renders a proportional bar for any percentage (0–100).
    # Colour: green below 50%, yellow 50–79%, red 80%+.
    def pct_bar(pct, width)
      filled = [(pct / 100.0 * width).round, width].min
      color  = if pct >= 80
                 RED
               else
                 pct >= 50 ? YELLOW : GREEN
               end
      "[#{color}#{'█' * filled}#{RESET}#{' ' * (width - filled)}]"
    end

    # Strips ANSI escape sequences to measure the visible length of a string.
    def strip_ansi(str)
      str.gsub(/\033\[[0-9;]*m/, '')
    end

    # Formats an integer with thousands separators, e.g. 1234567 → "1,234,567".
    def fmt_num(n)
      n.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
    end
  end

end
