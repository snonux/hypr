# frozen_string_literal: true

require 'json'
require 'optparse'
require 'socket'

module HyperstackVM
  class CLI
    # Repo root is two levels above this file (lib/hyperstack/ → lib/ → repo root).
    # All TOML config files live at the repo root, not alongside this library file.
    REPO_ROOT = File.expand_path(File.join(__dir__, '..', '..'))

    def initialize(argv)
      @argv = argv.dup
      @vm = '1'
    end

    def show_help
      puts @global_parser
      puts
      puts 'Commands:'
      puts '  create   [--replace] [--dry-run] [--vllm|--no-vllm] [--ollama|--no-ollama] [--flavor NAME] [--model PRESET]'
      puts '  delete   [--vm-id ID] [--dry-run]'
      puts '  status'
      puts '  watch'
      puts '           Poll active VMs for vLLM and GPU stats every 60 s.'
      puts '  test'
      puts '  model list'
      puts '  model switch PRESET [--dry-run]'
      puts
      puts 'All commands accept --vm 1|2|both (default: 1).'
    end

    def run
      @global_parser = OptionParser.new do |opts|
        opts.banner = 'Usage: ruby hyperstack.rb [--vm 1|2|both] <create|delete|status|watch|test|model> [options]'
        opts.on('--vm 1|2|both', 'Target VM (default: 1)') do |value|
          raise Error, "Invalid --vm value #{value.inspect}. Use 1, 2, or both." unless %w[1 2 both].include?(value)
          @vm = value
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

      case command
      when 'create'
        if @vm == 'both'
          opts = parse_create_options(@argv, include_model_preset: false)
          run_create_both(**opts)
        else
          opts = parse_create_options(@argv)
          build_manager_for_vm(@vm).create(**opts)
        end
      when 'delete'
        if @vm == 'both'
          opts = parse_delete_options(@argv)
          run_delete_both(**opts)
        else
          vm_id = nil
          dry_run = false
          parser = OptionParser.new do |opts|
            opts.on('--vm-id ID', Integer, 'Delete a VM by ID instead of using the local state file') do |value|
              vm_id = value
            end
            opts.on('--dry-run', 'Show which VM would be deleted without deleting it') { dry_run = true }
          end
          parser.parse!(@argv)
          build_manager_for_vm(@vm).delete(vm_id: vm_id, dry_run: dry_run)
        end
      when 'status'
        run_status
      when 'watch'
        run_watch
      when 'test'
        run_test
      when 'model'
        run_model
      else
        raise Error,
              "Unknown command #{command.inspect}. Use create, delete, status, watch, test, or model."
      end
    end

    private

    def vm_config_path(vm)
      File.join(REPO_ROOT, "hyperstack-vm#{vm}.toml")
    end

    def build_manager_for_vm(vm)
      loader = ConfigLoader.load(vm_config_path(vm))
      build_manager(loader.config)
    end

    def selected_config_loaders
      case @vm
      when 'both'
        pair_config_loaders
      else
        [ConfigLoader.load(vm_config_path(@vm))]
      end
    end

    # Returns only the config loaders whose state files exist and have a tracked VM.
    # Used by watch/status/test when the user wants to see whatever is currently
    # up without specifying --vm explicitly.
    def active_config_loaders
      pair_config_loaders.filter_map do |loader|
        next unless File.exist?(loader.config.state_file)

        state = JSON.parse(File.read(loader.config.state_file))
        state['public_ip'] && state['vm_id'] ? loader : nil
      rescue JSON::ParserError, Errno::ENOENT
        nil
      end
    end

    # True when VM1 has a state file with a tracked VM ID and public IP.
    def vm1_alive?
      path = ConfigLoader.load(vm_config_path('1')).config.state_file
      return false unless File.exist?(path)

      state = JSON.parse(File.read(path))
      state['public_ip'] && state['vm_id']
    rescue JSON::ParserError, Errno::ENOENT
      false
    end

    # When the user runs a command with the default --vm 1 but VM1 has not yet been
    # provisioned (or its tracked VM is dead), fall back to whichever VMs actually
    # have active state files so the command is useful even with only VM2 running.
    def default_or_active_loaders
      if @vm == '1' && !vm1_alive?
        active_config_loaders
      else
        selected_config_loaders
      end
    end

    # Parses the shared --replace / --dry-run / --vllm / --ollama / --model flags
    # used by 'create' and by 'create --vm both'.  When include_model_preset is false
    # (both), the --model flag is not registered because each VM uses its own
    # TOML default.  Returns a hash suitable for splatting into Manager#create.
    def parse_create_options(argv, include_model_preset: true)
      opts = { replace: false, dry_run: false, install_vllm: nil, install_ollama: nil,
               vllm_preset: nil, flavor_name: nil }
      OptionParser.new do |o|
        o.on('--replace',      'Delete the tracked VM before creating a new one')    { opts[:replace] = true }
        o.on('--dry-run',      'Print the create plan without creating a VM')        { opts[:dry_run] = true }
        o.on('--vllm',         'Enable vLLM setup (overrides config)')               { opts[:install_vllm] = true }
        o.on('--no-vllm',      'Disable vLLM setup (overrides config)')              { opts[:install_vllm] = false }
        o.on('--ollama',       'Enable Ollama setup (overrides config)')             { opts[:install_ollama] = true }
        o.on('--no-ollama',    'Disable Ollama setup (overrides config)')            { opts[:install_ollama] = false }
        o.on('--flavor NAME',  'Override GPU flavor (e.g. n3-H100x1)')             { |v| opts[:flavor_name] = v }
        if include_model_preset
          o.on('--model PRESET', 'Use a named vLLM preset at create time') do |v|
            opts[:vllm_preset] = v
          end
        end
      end.parse!(argv)
      opts
    end

    def parse_delete_options(argv)
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

    def run_test
      loaders = default_or_active_loaders
      loaders.each do |loader|
        if loaders.size > 1
          puts
          puts "[#{File.basename(loader.path)}]"
        end
        build_manager(loader.config).test
      end
    end

    def run_model
      sub = @argv.shift
      raise Error, 'Missing model subcommand. Use: model list | model switch PRESET [--dry-run]' if sub.nil?

      case sub
      when 'list'
        loaders = default_or_active_loaders
        loaders = selected_config_loaders if loaders.empty?
        loaders.each do |loader|
          if loaders.size > 1
            puts
            puts "[#{File.basename(loader.path)}]"
          end
          build_manager(loader.config).list_models
        end
      when 'switch'
        preset = @argv.shift
        raise Error, 'Missing preset name. Usage: model switch PRESET [--dry-run]' if preset.nil?

        dry_run = false
        OptionParser.new { |o| o.on('--dry-run') { dry_run = true } }.parse!(@argv)
        loaders = selected_config_loaders
        loaders.each do |loader|
          if loaders.size > 1
            puts
            puts "[#{File.basename(loader.path)}]"
          end
          build_manager(loader.config).switch_model(preset_name: preset, dry_run: dry_run)
        end
      else
        raise Error, "Unknown model subcommand #{sub.inspect}. Use list or switch."
      end
    end

    # Starts the VllmWatcher dashboard for the selected VMs.
    # When --vm is omitted (defaults to 1) and VM1 has not been provisioned yet,
    # automatically falls back to whatever VMs are actually active so the watch
    # dashboard is useful even with only VM2 running.
    def run_watch
      loaders = default_or_active_loaders
      raise Error, 'No active VMs found. Run `create --vm 1|2|both` first.' if loaders.empty?
      VllmWatcher.new(config_loaders: loaders).run
    end

    def run_status
      loaders = default_or_active_loaders
      if loaders.empty?
        puts 'No active VMs found. Run `create --vm 1|2|both` first.'
        puts
        puts '[local-wireguard]'
        build_manager(ConfigLoader.load(vm_config_path('1')).config).show_local_wireguard(nil)
        return
      end
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
    def run_create_both(replace:, dry_run:, install_vllm:, install_ollama:, vllm_preset: nil, flavor_name: nil) # rubocop:disable Lint/UnusedMethodArgument
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
      errors_mutex = Mutex.new
      create_opts = { replace: replace, dry_run: dry_run,
                      install_vllm: install_vllm, install_ollama: install_ollama,
                      flavor_name: flavor_name }

      vm1_thread = Thread.new do
        manager1.create(**create_opts)
      rescue Error => e
        errors_mutex.synchronize { errors[:vm1] = e.message }
        # Unblock VM2 even if VM1 failed so the process doesn't hang.
        # Only set the error flag if the WireGuard step itself failed.
        # If WG already succeeded (:done is true), VM2 should proceed.
        wg_mutex.synchronize do
          vm1_wg_state[:error] = e.message unless vm1_wg_state[:done]
          wg_cv.broadcast
        end
      end

      vm2_thread = Thread.new do
        manager2.create(**create_opts)
      rescue Error => e
        errors_mutex.synchronize { errors[:vm2] = e.message }
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
          cleanup = local_manager.cleanup_local_access(dry_run: dry_run, hostnames: hostnames,
                                                              allowed_ips: allowed_ips)
          local_manager.report_local_cleanup(local_wg_out, cleanup, dry_run: dry_run)
        rescue Error => e
          errors[:local_wireguard] = e.message
        end
      end

      errors.each { |vm, msg| warn("ERROR [#{vm}]: #{msg}") }
      exit 1 unless errors.empty?
    end
  end
end
