# frozen_string_literal: true

require 'optparse'
require 'socket'

module HyperstackVM
  class CLI
    # Repo root is two levels above this file (lib/hyperstack/ → lib/ → repo root).
    # All TOML config files live at the repo root, not alongside this library file.
    REPO_ROOT = File.expand_path(File.join(__dir__, '..', '..'))

    def initialize(argv)
      @argv = argv.dup
      @config_path = File.join(REPO_ROOT, 'hyperstack-vm.toml')
      @config_explicit = false
    end

    def show_help
      puts @global_parser
      puts
      puts 'Commands:'
      puts '  create [--replace] [--dry-run] [--vllm|--no-vllm] [--ollama|--no-ollama] [--model PRESET]'
      puts '  create-both [--replace] [--dry-run] [--vllm|--no-vllm] [--ollama|--no-ollama]'
      puts '               Provision hyperstack-vm1.toml and hyperstack-vm2.toml concurrently.'
      puts '               WireGuard setup is serialized: VM1 writes the base wg1.conf first,'
      puts '               then VM2 adds its peer. Requires both TOML files next to the script.'
      puts '  delete [--vm-id ID] [--dry-run]'
      puts '  delete-both [--dry-run]'
      puts '               Delete the VMs tracked by hyperstack-vm1.toml and hyperstack-vm2.toml.'
      puts '  status'
      puts '  watch'
      puts '               Poll all active VMs for vLLM and GPU stats every 60 s.'
      puts '  test'
      puts '  model list'
      puts '  model switch PRESET [--dry-run]'
    end

    def run
      @global_parser = OptionParser.new do |opts|
        opts.banner = 'Usage: ruby hyperstack.rb [--config path] <create|delete|status> [options]'
        opts.on('--config PATH', "Path to TOML config (default: #{@config_path})") do |value|
          @config_path = value
          @config_explicit = true
        end
        opts.on('-h', '--help', 'Show help') do
          show_help
          exit 0
        end
      end
      @global_parser.order!(@argv)

      command = @argv.shift
      if command.nil?
        show_help
        exit 0
      end

      # create-both loads its own config files and does not use the default config path.
      # Parse it before building the manager so we avoid loading the default config needlessly.
      if command == 'create-both'
        opts = parse_create_options(@argv, include_model_preset: false)
        run_create_both(**opts)
        return
      end

      if command == 'delete-both'
        opts = parse_delete_both_options(@argv)
        run_delete_both(**opts)
        return
      end

      if command == 'status'
        run_status
        return
      end

      if command == 'watch'
        run_watch
        return
      end

      # All other commands operate on a single VM defined by the --config path.
      config_loader = ConfigLoader.load(@config_path)
      manager       = build_manager(config_loader.config)

      case command
      when 'create'
        opts = parse_create_options(@argv)
        manager.create(**opts)
      when 'delete'
        vm_id = nil
        dry_run = false
        parser = OptionParser.new do |opts|
          opts.on('--vm-id ID', Integer, 'Delete a VM by ID instead of using the local state file') do |value|
            vm_id = value
          end
          opts.on('--dry-run', 'Show which VM would be deleted without deleting it') { dry_run = true }
        end
        parser.parse!(@argv)
        manager.delete(vm_id: vm_id, dry_run: dry_run)
      when 'test'
        manager.test
      when 'model'
        sub = @argv.shift
        raise Error, 'Missing model subcommand. Use: model list | model switch PRESET [--dry-run]' if sub.nil?

        case sub
        when 'list'
          manager.list_models
        when 'switch'
          preset = @argv.shift
          raise Error, 'Missing preset name. Usage: model switch PRESET [--dry-run]' if preset.nil?

          dry_run = false
          OptionParser.new { |o| o.on('--dry-run') { dry_run = true } }.parse!(@argv)
          manager.switch_model(preset_name: preset, dry_run: dry_run)
        else
          raise Error, "Unknown model subcommand #{sub.inspect}. Use list or switch."
        end
      else
        raise Error,
              "Unknown command #{command.inspect}. Use create, create-both, delete, delete-both, status, watch, test, or model."
      end
    end

    private

    # Parses the shared --replace / --dry-run / --vllm / --ollama / --model flags
    # used by both 'create' and 'create-both'.  When include_model_preset is false
    # (create-both), the --model flag is not registered because each VM uses its own
    # TOML default.  Returns a hash suitable for splatting into Manager#create.
    def parse_create_options(argv, include_model_preset: true)
      opts = { replace: false, dry_run: false, install_vllm: nil, install_ollama: nil, install_comfyui: nil,
               vllm_preset: nil }
      OptionParser.new do |o|
        o.on('--replace',      'Delete the tracked VM before creating a new one')    { opts[:replace] = true }
        o.on('--dry-run',      'Print the create plan without creating a VM')        { opts[:dry_run] = true }
        o.on('--vllm',         'Enable vLLM setup (overrides config)')               { opts[:install_vllm] = true }
        o.on('--no-vllm',      'Disable vLLM setup (overrides config)')              { opts[:install_vllm] = false }
        o.on('--ollama',       'Enable Ollama setup (overrides config)')             { opts[:install_ollama] = true }
        o.on('--no-ollama',    'Disable Ollama setup (overrides config)')            { opts[:install_ollama] = false }
        o.on('--comfyui',      'Enable ComfyUI setup (overrides config)')            { opts[:install_comfyui] = true }
        o.on('--no-comfyui',   'Disable ComfyUI setup (overrides config)')           { opts[:install_comfyui] = false }
        if include_model_preset
          o.on('--model PRESET', 'Use a named vLLM preset at create time') do |v|
            opts[:vllm_preset] = v
          end
        end
      end.parse!(argv)
      opts
    end

    def parse_delete_both_options(argv)
      opts = { dry_run: false }
      OptionParser.new do |o|
        o.on('--dry-run', 'Show which VMs would be deleted without deleting them') { opts[:dry_run] = true }
      end.parse!(argv)
      opts
    end

    # Constructs a Manager and all its dependencies from a Config object.
    # Accepts optional output destination and WireGuard concurrency hooks.
    def build_manager(config, out: $stdout, wg_setup_pre: nil, wg_setup_post: nil)
      state_store     = StateStore.new(config.state_file)
      client          = HyperstackClient.new(base_url: config.api_base_url, api_key: config.api_key)
      local_wireguard = build_local_wireguard(config)
      Manager.new(
        config: config,
        client: client,
        state_store: state_store,
        local_wireguard: local_wireguard,
        out: out,
        wg_setup_pre: wg_setup_pre,
        wg_setup_post: wg_setup_post
      )
    end

    def build_local_wireguard(config)
      LocalWireGuard.new(
        interface_name: config.local_interface_name,
        config_path: config.local_wg_config_path
      )
    end

    # Starts the VllmWatcher dashboard restricted to VMs that are currently reachable.
    # Uses watch_config_loaders instead of status_config_loaders so VMs whose state
    # files are stale (e.g. deleted from the console without `delete`) are excluded.
    def run_watch
      loaders = watch_config_loaders
      raise Error, 'No active VMs found. Run `create` or `create-both` first.' if loaders.empty?

      VllmWatcher.new(config_loaders: loaders).run
    end

    def run_status
      loaders = status_config_loaders
      if loaders.one?
        build_manager(loaders.first.config).status
        return
      end

      expected_ips = []
      loaders.each_with_index do |loader, index|
        puts if index.positive?
        puts "[#{File.basename(loader.path)}]"
        expected_ip = build_manager(loader.config).status(include_local_wireguard: false)
        expected_ips << expected_ip if expected_ip
      end

      puts
      puts '[local-wireguard]'
      build_manager(loaders.first.config).show_local_wireguard(expected_ips)
    end

    # Returns only the loaders for VMs whose inference API port is currently reachable.
    # Falls back to all state-tracked loaders when none are reachable (e.g. WireGuard down),
    # so the watcher can still render meaningful error output instead of raising.
    def watch_config_loaders
      loaders   = status_config_loaders
      reachable = loaders.select { |l| vm_api_reachable?(l.config) }
      reachable.empty? ? loaders : reachable
    end

    # Quick TCP probe on the VM's inference port via WireGuard.
    # A successful connect (immediately closed) means the API is up; any network
    # error means the VM is down or unreachable — exclude it from the watch loop.
    def vm_api_reachable?(config)
      TCPSocket.new(config.wireguard_gateway_hostname, config.ollama_port).close
      true
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
           Errno::ENETUNREACH, SocketError
      false
    end

    def status_config_loaders
      return [ConfigLoader.load(@config_path)] if @config_explicit

      candidates = [
        @config_path,
        File.join(REPO_ROOT, 'hyperstack-vm1.toml'),
        File.join(REPO_ROOT, 'hyperstack-vm2.toml'),
        File.join(REPO_ROOT, 'hyperstack-vm-photo.toml')
      ].uniq.select { |path| File.exist?(path) }

      loaders = candidates.map { |path| ConfigLoader.load(path) }
      tracked = loaders.select { |loader| File.exist?(loader.config.state_file) }
      tracked.empty? ? [ConfigLoader.load(@config_path)] : tracked
    end

    def pair_config_loaders
      [
        ConfigLoader.load(File.join(REPO_ROOT, 'hyperstack-vm1.toml')),
        ConfigLoader.load(File.join(REPO_ROOT, 'hyperstack-vm2.toml'))
      ]
    end

    # Provisions hyperstack-vm1 and hyperstack-vm2 concurrently in separate threads.
    # WireGuard setup is serialized: VM1 runs first (replacing the base wg1.conf), then
    # VM2 adds its peer. A Mutex+ConditionVariable acts as a one-shot latch between threads.
    # If VM1 fails before reaching the WG step the latch is still released so VM2 doesn't hang.
    # vllm_preset is accepted but ignored — each VM uses its own TOML default preset.
    def run_create_both(replace:, dry_run:, install_vllm:, install_ollama:, install_comfyui: nil, vllm_preset: nil) # rubocop:disable Lint/UnusedMethodArgument
      vm1_loader, vm2_loader = pair_config_loaders
      vm1_config = vm1_loader.config
      vm2_config = vm2_loader.config

      out_mutex    = Mutex.new
      wg_mutex     = Mutex.new
      wg_cv        = ConditionVariable.new
      vm1_wg_state = { done: false, error: nil }

      # VM1 signals the latch after its WG step (whether WG ran or was already done).
      vm1_wg_post = proc do
        wg_mutex.synchronize do
          vm1_wg_state[:done] = true
          wg_cv.broadcast
        end
      end

      # VM2 blocks here until VM1's WG step resolves, then raises if VM1 failed.
      vm2_wg_pre = proc do
        wg_mutex.synchronize { wg_cv.wait(wg_mutex) until vm1_wg_state[:done] || vm1_wg_state[:error] }
        raise Error, 'VM1 WireGuard setup failed; cannot add VM2 peer.' if vm1_wg_state[:error]
      end

      manager1 = build_manager(vm1_config,
                               out: PrefixedOutput.new('[vm1] ', $stdout, out_mutex),
                               wg_setup_post: vm1_wg_post)
      manager2 = build_manager(vm2_config,
                               out: PrefixedOutput.new('[vm2] ', $stdout, out_mutex),
                               wg_setup_pre: vm2_wg_pre)

      errors = {}
      create_opts = { replace: replace, dry_run: dry_run,
                      install_vllm: install_vllm, install_ollama: install_ollama, install_comfyui: install_comfyui }

      vm1_thread = Thread.new do
        manager1.create(**create_opts)
      rescue Error => e
        errors[:vm1] = e.message
        # Unblock VM2 even if VM1 failed so the process doesn't hang.
        wg_mutex.synchronize do
          vm1_wg_state[:error] = e.message
          wg_cv.broadcast
        end
      end

      vm2_thread = Thread.new do
        manager2.create(**create_opts)
      rescue Error => e
        errors[:vm2] = e.message
      end

      [vm1_thread, vm2_thread].each(&:join)

      errors.each { |vm, msg| warn("ERROR [#{vm}]: #{msg}") }
      exit 1 unless errors.empty?
    end

    def run_delete_both(dry_run:)
      out_mutex = Mutex.new
      errors_mutex = Mutex.new
      errors = {}
      loaders = pair_config_loaders
      local_wg_out = PrefixedOutput.new('[local-wireguard] ', $stdout, out_mutex)
      threads = loaders.each_with_index.map do |loader, index|
        label = "vm#{index + 1}"
        manager = build_manager(loader.config, out: PrefixedOutput.new("[#{label}] ", $stdout, out_mutex))

        Thread.new do
          manager.delete(dry_run: dry_run, skip_local_cleanup: true)
        rescue Error => e
          errors_mutex.synchronize { errors[label.to_sym] = e.message }
        end
      end
      threads.each(&:join)

      if errors.empty?
        allowed_ips = loaders.map { |loader| "#{loader.config.wireguard_gateway_ip}/32" }
        hostnames = loaders.map { |loader| loader.config.wireguard_gateway_hostname }
        begin
          local_manager = build_manager(loaders.first.config, out: local_wg_out)
          cleanup = local_manager.send(:cleanup_local_access, dry_run: dry_run, hostnames: hostnames,
                                                              allowed_ips: allowed_ips)
          local_manager.send(:report_local_cleanup, local_wg_out, cleanup, dry_run: dry_run)
        rescue Error => e
          errors[:local_wireguard] = e.message
        end
      end

      errors.each { |vm, msg| warn("ERROR [#{vm}]: #{msg}") }
      exit 1 unless errors.empty?
    end
  end
end
