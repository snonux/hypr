# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'socket'
require 'timeout'

module HyperstackVM
  class Manager
    # wg_setup_pre:  optional Proc called just before this VM's WireGuard setup step runs.
    #                Used by create-both to block VM2 until VM1 has written the base wg1.conf.
    # wg_setup_post: optional Proc called after the WireGuard step completes (or is skipped).
    #                Used by create-both to signal that VM1's base config is ready for VM2.
    def initialize(config:, client:, state_store:, local_wireguard:, out: $stdout,
                   wg_setup_pre: nil, wg_setup_post: nil)
      @config = config
      @client = client
      @state_store = state_store
      @local_wireguard = local_wireguard
      @out = out
      @scripts = ProvisioningScripts.new(config: config)
      @provisioner = RemoteProvisioner.new(config: config, scripts: @scripts, out: out,
                                           ssh_command_runner: method(:run_ssh_command),
                                           ssh_stream_runner: method(:run_ssh_command_streaming))
      @wg_setup_pre  = wg_setup_pre
      @wg_setup_post = wg_setup_post
    end

    def create(replace: false, dry_run: false, install_vllm: nil, install_ollama: nil,
               vllm_preset: nil)
      # CLI flags override config; nil means "use config default".
      @effective_vllm = install_vllm.nil? ? @config.vllm_install_enabled? : install_vllm
      @effective_ollama = install_ollama.nil? ? @config.ollama_install_enabled? : install_ollama
      # Validate preset name early so we fail before touching any remote state.
      @effective_vllm_preset = vllm_preset
      @config.vllm_preset(vllm_preset) if vllm_preset
      existing_state = @state_store.load
      if existing_state && existing_state['vm_id']
        if replace
          if dry_run
            info "DRY RUN: would delete tracked VM #{existing_state['vm_id']} before creating a replacement."
          else
            delete(vm_id: existing_state['vm_id'], preserve_state_on_failure: true)
          end
        elsif resumable_state?(existing_state)
          if dry_run
            print_resume_dry_run(existing_state)
            return
          end

          info "Resuming tracked VM #{existing_state['vm_id']} provisioning..."
          continue_create(existing_state)
          return
        else
          raise Error,
                "State file #{@state_store.path} already tracks VM #{existing_state['vm_id']}. Use --replace or delete first."
        end
      end

      resolved = resolve_dependencies
      vm_name = @config.generated_vm_name
      if dry_run
        info "Planning VM #{vm_name} in #{resolved[:environment]['name']} using #{@config.flavor_name}..."
      else
        info "Creating VM #{vm_name} in #{resolved[:environment]['name']} using #{@config.flavor_name}..."
      end

      payload = build_create_payload(vm_name, resolved)
      if dry_run
        print_create_dry_run(vm_name, resolved, payload)
        return
      end

      response = @client.create_vm(payload)
      instance = Array(response['instances']).first
      raise Error, 'Hyperstack create response did not include an instance ID.' unless instance && instance['id']

      state = {
        'vm_id' => instance['id'],
        'vm_name' => vm_name,
        'environment_name' => resolved[:environment]['name'],
        'region' => resolved[:environment]['region'],
        'flavor_name' => resolved[:flavor]['name'],
        'image_name' => resolved[:image]['name'],
        'key_name' => resolved[:keypair]['name'],
        'public_ip' => instance['floating_ip'],
        'created_at' => Time.now.utc.iso8601
      }
      sync_service_mode_state(state)
      @state_store.save(state)
      continue_create(state)
    end

    def delete(vm_id: nil, preserve_state_on_failure: false, dry_run: false, skip_local_cleanup: false)
      state = @state_store.load
      target_vm_id = vm_id || state&.dig('vm_id')
      raise Error, "No VM ID provided and no state file found at #{@state_store.path}." if target_vm_id.nil?

      cleanup_local = !skip_local_cleanup && state && target_vm_id == state['vm_id']

      if dry_run
        print_delete_dry_run(target_vm_id, state, preserve_state_on_failure: preserve_state_on_failure)
        return
      end

      info "Deleting VM #{target_vm_id}..."
      @client.delete_vm(target_vm_id)
      wait_for_deletion(target_vm_id)
      if cleanup_local
        cleanup = cleanup_local_access(dry_run: false, hostnames: [@config.wireguard_gateway_hostname],
                                       allowed_ips: ["#{@config.wireguard_gateway_ip}/32"])
        report_local_cleanup(@out, cleanup, dry_run: false)
      end
      delete_ssh_known_hosts_file
      @state_store.delete unless preserve_state_on_failure
      info "VM #{target_vm_id} deleted."
    rescue Error => e
      raise if preserve_state_on_failure

      gone = e.message.include?('not_found') ||
             e.message.include?('does not exist') ||
             e.message.include?('does not exists') ||
             e.message.include?('404')
      @state_store.delete if gone
      raise
    end

    def status(include_local_wireguard: true)
      state = @state_store.load
      if state.nil?
        info "No tracked VM state file at #{@state_store.path}."
      else
        begin
          vm = @client.get_vm(state['vm_id'])
          desired = desired_security_rules_for_state(state).map { |rule| normalize_rule(rule) }
          current = Array(vm['security_rules']).map { |rule| normalize_rule(rule) }
          missing_rules = desired - current
          vllm_enabled    = state_vllm_enabled?(state)
          ollama_enabled  = state_ollama_enabled?(state)

          info "Tracked VM: #{state['vm_id']} #{vm['name']}"
          info "Status: #{vm['status']} / #{vm['vm_state']}"
          info "Public IP: #{connect_host_for(vm) || 'none'}"
          info "Service mode: #{service_mode_summary(vllm_enabled: vllm_enabled, ollama_enabled: ollama_enabled)}"
          info "Active model: #{state['vllm_model'] || @config.vllm_model}" if vllm_enabled
          info "Missing firewall rules: #{missing_rules.empty? ? 'none' : missing_rules.size}"
        rescue Error => e
          warn "Unable to load VM #{state['vm_id']}: #{e.message}"
        end
      end

      print_local_wireguard_summary(state&.dig('public_ip')) if include_local_wireguard
      state&.dig('public_ip')
    end

    def show_local_wireguard(expected_ips = nil)
      print_local_wireguard_summary(expected_ips)
    end

    # Lists configured model presets and marks the one currently running on the VM.
    def list_models
      presets = @config.vllm_preset_names
      state   = @state_store.load
      current = state&.dig('vllm_model')

      if presets.empty?
        info 'No presets configured in [vllm.presets.*].'
        info "Active model: #{current || @config.vllm_model}"
        return
      end

      info 'Configured vLLM model presets:'
      presets.each do |name|
        p      = @config.vllm_preset(name)
        active = p['model'] == current
        info "  #{active ? '*' : ' '} #{name.ljust(24)} #{p['model']}"
      end
      info ''
      info '  (* = currently loaded on VM)' if current
    end

    # Switches the running VM to a different named model preset.
    # Stops the old container, then starts the new vLLM container in its place.
    def switch_model(preset_name:, dry_run: false)
      preset = @config.vllm_preset(preset_name) # raises if unknown
      state  = @state_store.load

      old_container = state&.dig('vllm_container_name') || @config.vllm_container_name
      new_container = preset['container_name']
      current_model = state&.dig('vllm_model')

      if dry_run
        info "DRY RUN: model switch to preset '#{preset_name}'"
        info "  #{current_model || 'none'} → #{preset['model']}"
        info "  container: #{old_container} → #{new_container}"
        trust_note  = preset['trust_remote_code'] ? ', trust_remote_code: true' : ''
        parser_note = preset['tool_call_parser'].to_s.empty? ? 'none' : preset['tool_call_parser']
        extra_note  = preset['extra_vllm_args']&.any? ? ", extra_args: #{preset['extra_vllm_args'].join(' ')}" : ''
        info "  max_model_len: #{preset['max_model_len']}, tool_call_parser: #{parser_note}#{trust_note}#{extra_note}"
        return
      end

      raise Error, "No tracked VM. Run 'create' first." unless state&.dig('vm_id')

      host = state['public_ip']
      raise Error, 'No public IP in state file.' if host.nil? || host.empty?

      @provisioner.decommission_litellm(host)

      # Stop the old container only when it has a different name from the new one.
      @provisioner.stop_vllm_container(host, old_container) if old_container != new_container

      info "Starting vLLM with preset '#{preset_name}' (#{preset['model']})..."
      # Skip docker pull: image is already present; pulling on every switch risks a
      # surprise multi-GB download if the upstream image was updated.
      @provisioner.install_vllm(host, preset_config: preset, pull_image: false)

      state['vllm_model']          = preset['model']
      state['vllm_container_name'] = new_container
      state['vllm_preset']         = preset_name
      state['vllm_setup_at']       = Time.now.utc.iso8601
      state['services'] ||= {}
      state['services']['vllm_enabled'] = true
      state['services']['ollama_enabled'] = state_ollama_enabled?(state)
      @state_store.save(state)

      info "Model switched to '#{preset_name}' (#{preset['model']})."
      info "Run 'ruby hyperstack.rb test' to verify."
    end

    # Runs end-to-end inference tests against the active inference services over WireGuard.
    # Requires wg1 to be active and the VM to be fully provisioned.
    def test
      state = @state_store.load
      raise Error, "No tracked VM state file found at #{@state_store.path}." if state.nil?

      wg_ip = @config.wireguard_gateway_hostname
      vllm_enabled = state_vllm_enabled?(state)
      ollama_enabled = state_ollama_enabled?(state)
      info "Running end-to-end inference tests via WireGuard (#{wg_ip})..."

      test_vllm(wg_ip) if vllm_enabled

      info "  Ollama test: connect via SSH and run 'ollama list' to verify models." if ollama_enabled

      info 'All inference tests passed.'
    end

    private

    def resumable_state?(state)
      state['vm_id'] && (
        state['bootstrapped_at'].nil? ||
        ollama_setup_needed?(state) ||
        vllm_setup_needed?(state) ||
        wireguard_setup_needed?(state)
      )
    end

    def continue_create(state)
      vm_id = state['vm_id']
      sync_service_mode_state(state)

      vm = wait_for_vm_ready(vm_id)
      ensure_security_rules(vm)
      vm = wait_for_connect_ip(vm_id)
      state['public_ip'] = connect_host_for(vm)
      state['security_rules'] = Array(vm['security_rules']).map { |rule| normalize_rule(rule) }
      @state_store.save(state)

      wait_for_ssh(state['public_ip'])
      @provisioner.decommission_litellm(state['public_ip'])
      if @config.guest_bootstrap_enabled? && state['bootstrapped_at'].nil?
        @provisioner.bootstrap_guest(state['public_ip'])
        state['bootstrapped_at'] = Time.now.utc.iso8601
        @state_store.save(state)
      end

      # Install Ollama binary and configure the service (fast), but defer
      # model pulls until after the WireGuard tunnel is up so that the user
      # can monitor progress over the tunnel.
      if effective_ollama? && state['ollama_installed_at'].nil?
        @provisioner.install_ollama_service(state['public_ip'])
        state['ollama_installed_at'] = Time.now.utc.iso8601
        @state_store.save(state)
      end

      # Call pre-hook before deciding whether WireGuard setup is needed; this allows a concurrent
      # sibling VM (e.g. VM2 in create-both) to block here until the primary VM (VM1) has
      # already written the base wg1.conf, which VM2's setup will then extend with its own peer.
      @wg_setup_pre&.call
      if wireguard_setup_needed?(state)
        run_wireguard_setup(state['public_ip'])
        state['wireguard_setup_at'] = Time.now.utc.iso8601
        @state_store.save(state)
      end
      # Always signal post-hook so that a waiting sibling VM is unblocked even when
      # WireGuard setup was not needed (e.g. already done on a resume).
      @wg_setup_post&.call

      # Pull and verify Ollama models after the tunnel is established.
      if ollama_setup_needed?(state)
        @provisioner.pull_ollama_models(state['public_ip'])
        state['ollama_setup_at'] = Time.now.utc.iso8601
        state['ollama_models_dir'] = @config.ollama_models_dir
        state['ollama_pulled_models'] = @scripts.desired_ollama_models
        @state_store.save(state)
      end

      # Set up vLLM after
      # the tunnel is up so that model-download progress is visible locally.
      if vllm_setup_needed?(state)
        preset_cfg = effective_vllm_preset_config
        @provisioner.setup_vllm_stack(state['public_ip'], preset_config: preset_cfg)
        state['vllm_setup_at']       = Time.now.utc.iso8601
        state['vllm_model']          = preset_cfg&.dig('model')          || @config.vllm_model
        state['vllm_container_name'] = preset_cfg&.dig('container_name') || @config.vllm_container_name
        state['vllm_preset']         = @effective_vllm_preset
        @state_store.save(state)
      end

      vm = @client.get_vm(vm_id)
      state['security_rules'] = Array(vm['security_rules']).map { |rule| normalize_rule(rule) }
      state['status'] = vm['status']
      state['vm_state'] = vm['vm_state']
      state['provisioned_at'] = Time.now.utc.iso8601
      @state_store.save(state)

      info "VM ready: #{state['public_ip']} (id=#{state['vm_id']})"
      print_local_wireguard_summary(state['public_ip'])
      # Run end-to-end tests automatically so the human doesn't need a manual step.
      test
    end

    def build_create_payload(vm_name, resolved)
      payload = {
        'name' => vm_name,
        'count' => 1,
        'environment_name' => resolved[:environment]['name'],
        'flavor_name' => resolved[:flavor]['name'],
        'image_name' => resolved[:image]['name'],
        'key_name' => resolved[:keypair]['name'],
        'assign_floating_ip' => @config.assign_floating_ip?,
        'create_bootable_volume' => @config.create_bootable_volume?,
        'enable_port_randomization' => @config.enable_port_randomization?,
        'security_rules' => desired_security_rules
      }
      payload['labels'] = @config.labels unless @config.labels.empty?
      payload['user_data'] = @config.user_data if @config.user_data
      payload
    end

    def resolve_dependencies
      environment = @client.list_environments.find { |item| item['name'] == @config.environment_name }
      raise Error, "Environment #{@config.environment_name.inspect} was not found in Hyperstack." unless environment

      flavor = @client.list_flavors.find do |item|
        item['name'] == @config.flavor_name && item['region_name'] == environment['region']
      end
      raise Error, "Flavor #{@config.flavor_name.inspect} is not available in #{environment['region']}." unless flavor

      if flavor['stock_available'] == false
        raise Error,
              "Flavor #{@config.flavor_name.inspect} exists in #{environment['region']} but is out of stock."
      end

      image = @client.list_images.find do |item|
        item['name'] == @config.image_name && item['region_name'] == environment['region']
      end
      raise Error, "Image #{@config.image_name.inspect} is not available in #{environment['region']}." unless image

      keypair = @client.list_keypairs.find do |item|
        item['name'] == @config.ssh_key_name && item.dig('environment', 'name') == environment['name']
      end
      unless keypair
        raise Error,
              "Keypair #{@config.ssh_key_name.inspect} was not found in environment #{environment['name']}."
      end

      {
        environment: environment,
        flavor: flavor,
        image: image,
        keypair: keypair
      }
    end

    def wait_for_vm_ready(vm_id)
      with_polling("VM #{vm_id} to become ready for firewall updates") do
        vm = @client.get_vm(vm_id)
        next nil if vm.nil?

        raise Error, "VM #{vm_id} entered failed state #{vm['status']} / #{vm['vm_state']}." if failed_vm?(vm)

        vm_ready_for_updates?(vm) ? vm : nil
      end
    end

    def wait_for_connect_ip(vm_id)
      ip_label = @config.assign_floating_ip? ? 'floating IP' : 'reachable IP'
      with_polling("VM #{vm_id} to receive a #{ip_label}") do
        vm = @client.get_vm(vm_id)
        raise Error, "VM #{vm_id} entered failed state #{vm['status']} / #{vm['vm_state']}." if failed_vm?(vm)

        connect_host_for(vm) ? vm : nil
      end
    end

    def wait_for_ssh(host)
      info "Waiting for SSH on #{host}:#{@config.ssh_port}..."
      with_polling("SSH on #{host}:#{@config.ssh_port}") do
        next nil unless tcp_open?(host, @config.ssh_port)
        next nil unless ensure_trusted_ssh_host(host)

        _, stderr, status = run_ssh_command(host, 'true')
        if status.success?
          true
        else
          warn "SSH not ready yet: #{stderr.strip}" unless stderr.to_s.strip.empty?
          nil
        end
      end
    end

    def ensure_security_rules(vm)
      existing_rules = Array(vm['security_rules'])
      existing = existing_rules.map { |rule| normalize_rule(rule) }
      desired = desired_security_rules.map { |rule| normalize_rule(rule) }

      (desired - existing).each do |rule|
        info "Adding Hyperstack firewall rule #{rule['protocol']} #{rule['remote_ip_prefix']} #{rule['port_range_min']}..."
        @client.create_vm_rule(vm['id'], rule)
      end

      legacy_litellm_rules(existing_rules).each do |rule|
        rule_id = rule['id'] || rule['rule_id']
        unless rule_id
          warn 'Found legacy Hyperstack firewall rule for port 4000, but the API payload has no rule id; remove it manually from the Hyperstack console.'
          next
        end

        info "Removing legacy Hyperstack firewall rule #{rule['protocol']} #{rule['remote_ip_prefix']} #{rule['port_range_min']}..."
        @client.delete_vm_rule(vm['id'], rule_id)
      rescue Error => e
        warn "Failed to remove legacy Hyperstack firewall rule #{rule_id}: #{e.message}"
      end
    end

    def ollama_setup_needed?(state)
      return false unless effective_ollama?
      # Re-run setup if state has no record, or if desired models changed
      return true if state['ollama_setup_at'].nil?

      @scripts.model_list_signature(@scripts.desired_ollama_models) !=
        @scripts.model_list_signature(state['ollama_pulled_models'])
    end

    def wireguard_setup_needed?(state)
      return false unless @config.wireguard_auto_setup?

      public_ip = state['public_ip'].to_s.strip
      return true if public_ip.empty?

      expected_endpoint = "#{public_ip}:#{@config.wireguard_udp_port}"
      !Array(@local_wireguard.status['endpoints']).include?(expected_endpoint)
    end

    def run_wireguard_setup(host)
      validate_wireguard_setup_script!
      retries = 3
      retries.times do |attempt|
        info "Running WireGuard auto-setup via #{@config.wireguard_setup_script} #{host}..."

        status = run_wireguard_script(host)
        return if status.success?

        if attempt == retries - 1
          raise Error, "WireGuard setup failed after #{retries} attempts (exit #{status.exitstatus})."
        end

        delay = (attempt + 1) * 15
        warn "WireGuard setup attempt #{attempt + 1}/#{retries} failed (exit #{status.exitstatus}), retrying in #{delay}s..."
        sleep delay
      end
    end

    def run_wireguard_script(host)
      # Pass server WireGuard IP and WireGuard hostname as positional args so that
      # wg1-setup.sh can configure the correct server-side tunnel address and update
      # /etc/hosts on the client. The Enter keystroke via stdin bypasses the interactive prompt.
      server_ip = @config.wireguard_gateway_ip
      wg_hostname = @config.wireguard_gateway_hostname
      env = {
        'HYPERSTACK_SSH_PORT' => @config.ssh_port.to_s,
        'HYPERSTACK_SSH_CONNECT_TIMEOUT' => @config.ssh_connect_timeout.to_s,
        'HYPERSTACK_SSH_KNOWN_HOSTS_PATH' => @config.ssh_known_hosts_path,
        'HYPERSTACK_SSH_PRIVATE_KEY_PATH' => (File.exist?(@config.ssh_private_key_path) ? @config.ssh_private_key_path : '')
      }

      Open3.popen2e(env, 'bash', @config.wireguard_setup_script, host, server_ip,
                    wg_hostname) do |stdin, output, wait_thr|
        stdin.sync = true
        stdin.puts
        stdin.close

        output.each { |line| @out.print(line) }
        wait_thr.value
      end
    end

    def wait_for_deletion(vm_id)
      info "Waiting for VM #{vm_id} deletion to complete..."
      with_polling("VM #{vm_id} deletion", timeout: 300) do
        @client.get_vm(vm_id)
        nil
      rescue Error => e
        raise unless e.message.include?('not_found') || e.message.include?('does not exists')

        true
      end
    end

    def connect_host_for(vm)
      return vm['floating_ip'] if @config.assign_floating_ip?

      vm['floating_ip'] || vm['fixed_ip']
    end

    def validate_wireguard_setup_script!
      script_path = @config.wireguard_setup_script
      raise Error, "WireGuard setup script not found: #{script_path}" unless File.exist?(script_path)

      mismatches = []
      mismatches << "ssh.username must be 'ubuntu'" unless @config.ssh_username == 'ubuntu'
      mismatches << "local_client.interface_name must be 'wg1'" unless @config.local_interface_name == 'wg1'
      mismatches << 'network.wireguard_udp_port must be 56710' unless @config.wireguard_udp_port == 56_710
      unless @config.wireguard_subnet == '192.168.3.0/24'
        mismatches << "network.wireguard_subnet must be '192.168.3.0/24'"
      end

      # Validate that the resolved server IP is actually within the configured subnet.
      begin
        subnet    = IPAddr.new(@config.wireguard_subnet)
        server_ip = IPAddr.new(@config.wireguard_gateway_ip)
        unless subnet.include?(server_ip)
          mismatches << "wireguard_server_ip #{@config.wireguard_gateway_ip.inspect} is outside #{@config.wireguard_subnet}"
        end
      rescue IPAddr::InvalidAddressError => e
        mismatches << "Invalid wireguard_server_ip: #{e.message}"
      end

      return if mismatches.empty?

      raise Error, "Configured WireGuard settings do not match #{script_path}: #{mismatches.join('; ')}"
    end

    def ensure_trusted_ssh_host(host)
      scanned = scan_ssh_host_keys(host)
      return false if scanned.empty?

      existing = known_host_entries
      if existing.empty?
        write_known_host_entries(scanned)
        info "Pinned SSH host key for #{host} in #{@config.ssh_known_hosts_path}."
        return true
      end

      return true if existing == scanned

      raise Error,
            "SSH host key mismatch for #{host}. Refusing to continue. Delete #{@config.ssh_known_hosts_path} only if you intentionally replaced this VM."
    end

    def scan_ssh_host_keys(host)
      stdout, stderr, status = Open3.capture3('ssh-keyscan', '-T', @config.ssh_connect_timeout.to_s,
                                              '-p', @config.ssh_port.to_s, host)
      unless status.success?
        warn "ssh-keyscan not ready yet: #{stderr.strip}" unless stderr.to_s.strip.empty?
        return []
      end

      stdout.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }.sort.uniq
    rescue Errno::ENOENT
      raise Error, 'ssh-keyscan is required to pin SSH host keys but was not found in PATH.'
    end

    def known_host_entries
      path = @config.ssh_known_hosts_path
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).map(&:strip).reject(&:empty?).sort.uniq
    rescue Errno::EACCES => e
      raise Error, "Cannot read SSH known_hosts file #{path}: #{e.message}"
    end

    def write_known_host_entries(entries)
      path = @config.ssh_known_hosts_path
      FileUtils.mkdir_p(File.dirname(path))
      temp_path = "#{path}.tmp"
      File.write(temp_path, "#{entries.join("\n")}\n")
      File.chmod(0o600, temp_path)
      File.rename(temp_path, path)
    rescue Errno::EACCES => e
      raise Error, "Cannot write SSH known_hosts file #{path}: #{e.message}"
    end

    def delete_ssh_known_hosts_file
      File.delete(@config.ssh_known_hosts_path) if File.exist?(@config.ssh_known_hosts_path)
    rescue Errno::EACCES => e
      raise Error, "Cannot delete SSH known_hosts file #{@config.ssh_known_hosts_path}: #{e.message}"
    end

    def failed_vm?(vm)
      [vm['status'], vm['vm_state'], vm['power_state']].compact.any? do |value|
        value.to_s.downcase.match?(/error|failed|deleted|shelved/)
      end
    end

    def vm_ready_for_updates?(vm)
      %w[ACTIVE SHUTOFF HIBERNATED].include?(vm['status'].to_s.upcase)
    end

    def tcp_open?(host, port)
      Socket.tcp(host, port, connect_timeout: @config.ssh_connect_timeout) do |sock|
        sock.close
        true
      end
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, IOError
      false
    end

    def run_ssh_command(host, remote_script)
      Open3.capture3(*ssh_command(host), stdin_data: remote_script)
    end

    def run_ssh_command_streaming(host, remote_script)
      combined_output = +''
      Open3.popen2e(*ssh_command(host)) do |stdin, output, wait_thr|
        stdin.write(remote_script)
        stdin.close

        output.each do |line|
          combined_output << line
          @out.print(line)
        end

        return [combined_output, wait_thr.value]
      end
    end

    def ssh_command(host)
      command = [
        'ssh',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', "UserKnownHostsFile=#{@config.ssh_known_hosts_path}",
        '-o', "ConnectTimeout=#{@config.ssh_connect_timeout}",
        '-p', @config.ssh_port.to_s
      ]
      if File.exist?(@config.ssh_private_key_path)
        command.concat(['-i', @config.ssh_private_key_path])
      else
        warn "SSH private key #{@config.ssh_private_key_path} does not exist; falling back to default ssh-agent identity."
      end

      command << "#{@config.ssh_username}@#{host}"
      command << 'bash -se'
      command
    end

    def with_polling(description, timeout: 900, interval: 5)
      deadline = Time.now + timeout
      attempt = 0
      loop do
        result = yield
        return result if result

        raise Error, "Timed out waiting for #{description}." if Time.now >= deadline

        attempt += 1
        # Print a heartbeat every 30 seconds so the user can see the script hasn't stalled.
        info("  still waiting for #{description}... (#{attempt * interval}s)") if (attempt % 6).zero?
        sleep interval
      end
    end

    def normalize_rule(rule)
      {
        'direction' => rule['direction'].to_s.downcase,
        'ethertype' => rule['ethertype'].to_s,
        'protocol' => rule['protocol'].to_s.downcase,
        'port_range_min' => integer_or_nil(rule['port_range_min']),
        'port_range_max' => integer_or_nil(rule['port_range_max']),
        'remote_ip_prefix' => rule['remote_ip_prefix'].to_s
      }
    end

    def sync_service_mode_state(state)
      state['services'] = {
        'vllm_enabled' => effective_vllm?,
        'ollama_enabled' => effective_ollama?
      }
    end

    def desired_security_rules(include_vllm: effective_vllm?, include_ollama: effective_ollama?)
      @config.desired_security_rules(include_vllm: include_vllm, include_ollama: include_ollama)
    end

    def desired_security_rules_for_state(state)
      desired_security_rules(include_vllm: state_vllm_enabled?(state),
                             include_ollama: state_ollama_enabled?(state))
    end

    def legacy_litellm_rules(rules)
      Array(rules).select do |rule|
        normalized = normalize_rule(rule)
        normalized['protocol'] == 'tcp' &&
          normalized['port_range_min'] == 4000 &&
          normalized['port_range_max'] == 4000 &&
          normalized['remote_ip_prefix'] == @config.wireguard_subnet
      end
    end

    def state_vllm_enabled?(state)
      recorded = state&.dig('services', 'vllm_enabled')
      return recorded unless recorded.nil?

      return true if state&.key?('vllm_setup_at')

      @config.vllm_install_enabled?
    end

    def state_ollama_enabled?(state)
      recorded = state&.dig('services', 'ollama_enabled')
      return recorded unless recorded.nil?

      return true if state&.key?('ollama_installed_at') || state&.key?('ollama_setup_at')

      @config.ollama_install_enabled?
    end

    def service_mode_summary(vllm_enabled:, ollama_enabled:)
      parts = []
      parts << 'vLLM' if vllm_enabled
      parts << 'Ollama' if ollama_enabled
      return 'All inference services disabled' if parts.empty?

      "#{parts.join(', ')} enabled"
    end

    def cleanup_local_access(dry_run:, hostnames:, allowed_ips:)
      {
        peers: @local_wireguard.remove_peers_by_allowed_ips(allowed_ips, dry_run: dry_run),
        hostnames: @local_wireguard.remove_hostnames(hostnames, dry_run: dry_run)
      }
    end

    def report_local_cleanup(output, cleanup, dry_run:)
      peer_summary = cleanup[:peers].map { |peer| peer['AllowedIPs'] || peer['Endpoint'] }.join(', ')
      host_summary = cleanup[:hostnames].join(', ')

      if dry_run
        if cleanup[:peers].empty? && cleanup[:hostnames].empty?
          output.puts('DRY RUN: no matching local WireGuard peers or host entries would be removed.')
          return
        end

        unless cleanup[:peers].empty?
          output.puts("DRY RUN: local WireGuard peers would be removed for #{peer_summary}.")
        end
        unless cleanup[:hostnames].empty?
          output.puts("DRY RUN: local host entries would be removed for #{host_summary}.")
        end
        return
      end

      output.puts('No matching local WireGuard peers needed removal.') if cleanup[:peers].empty?
      output.puts('No matching local host entries needed removal.') if cleanup[:hostnames].empty?
      output.puts("Local WireGuard peers removed for #{peer_summary}.") unless cleanup[:peers].empty?
      output.puts("Local host entries removed for #{host_summary}.") unless cleanup[:hostnames].empty?
    end

    def print_create_dry_run(vm_name, resolved, payload)
      info 'DRY RUN: no VM or state file will be created.'
      info "State file: #{@state_store.path}"
      info "Resolved environment: #{resolved[:environment]['name']} (region #{resolved[:environment]['region']})"
      info "Resolved flavor: #{format_flavor(resolved[:flavor])}"
      info "Resolved image: #{resolved[:image]['name']}"
      info "Resolved SSH keypair: #{resolved[:keypair]['name']}"
      info "Planned VM name: #{vm_name}"
      info "Allowed SSH CIDRs: #{@config.allowed_ssh_cidrs.join(', ')}"
      info "Allowed WireGuard CIDRs: #{@config.allowed_wireguard_cidrs.join(', ')}"
      info 'Create payload:'
      @out.puts(JSON.pretty_generate(payload))
      if @config.guest_bootstrap_enabled?
        info 'Guest bootstrap script:'
        @out.puts(@scripts.guest_bootstrap_script)
      else
        info 'Guest bootstrap is disabled in config.'
      end
      if effective_ollama?
        info "Ollama will be installed with models stored under #{@config.ollama_models_dir}"
        models = @scripts.desired_ollama_models
        info "Ollama models to pre-pull: #{models.join(', ')}" unless models.empty?
      end
      if effective_vllm?
        preset_cfg  = effective_vllm_preset_config
        vllm_m      = preset_cfg&.dig('model')          || @config.vllm_model
        vllm_cname  = preset_cfg&.dig('container_name') || @config.vllm_container_name
        vllm_maxlen = preset_cfg&.dig('max_model_len')  || @config.vllm_max_model_len
        preset_note = @effective_vllm_preset ? " (preset: #{@effective_vllm_preset})" : ''
        info "vLLM will be installed: #{vllm_m}#{preset_note}"
        info "  Container: #{vllm_cname}, port #{@config.ollama_port}, max_model_len #{vllm_maxlen}"
      end
      if @config.wireguard_auto_setup?
        info "WireGuard auto-setup script: #{@config.wireguard_setup_script} <vm_public_ip>"
      end
      print_local_wireguard_summary(nil)
    end

    def print_resume_dry_run(state)
      info "DRY RUN: would resume provisioning tracked VM #{state['vm_id']}."
      begin
        vm = @client.get_vm(state['vm_id'])
        info "Tracked VM status: #{vm['status']} / #{vm['vm_state']}"
        info "Tracked VM public IP: #{connect_host_for(vm) || 'none'}"
      rescue Error => e
        warn "Unable to inspect tracked VM #{state['vm_id']}: #{e.message}"
      end
      if @config.guest_bootstrap_enabled?
        info 'Guest bootstrap script:'
        @out.puts(@scripts.guest_bootstrap_script)
      end
      if ollama_setup_needed?(state)
        info "Ollama would be installed with models stored under #{@config.ollama_models_dir}"
        models = @scripts.desired_ollama_models
        info "Ollama models to pre-pull: #{models.join(', ')}" unless models.empty?
      end
      info "vLLM would be installed: #{@config.vllm_model}" if vllm_setup_needed?(state)
      if wireguard_setup_needed?(state)
        info "WireGuard auto-setup script would run: #{@config.wireguard_setup_script} #{state['public_ip'] || '<pending-public-ip>'}"
      end
      print_local_wireguard_summary(state['public_ip'])
    end

    def print_delete_dry_run(target_vm_id, state, preserve_state_on_failure:)
      info 'DRY RUN: no VM will be deleted.'
      begin
        vm = @client.get_vm(target_vm_id)
        info "Delete target: #{target_vm_id} #{vm['name']} (#{vm['status']} / #{vm['vm_state']})"
        info "Delete target public IP: #{connect_host_for(vm) || 'none'}"
      rescue Error => e
        warn "Unable to inspect VM #{target_vm_id} before delete: #{e.message}"
      end

      if state && state['vm_id'].to_i == target_vm_id.to_i
        action = preserve_state_on_failure ? 'would remain unchanged' : 'would be removed'
        info "Tracked state file #{@state_store.path} #{action}."
        cleanup = cleanup_local_access(dry_run: true, hostnames: [@config.wireguard_gateway_hostname],
                                       allowed_ips: ["#{@config.wireguard_gateway_ip}/32"])
        report_local_cleanup(@out, cleanup, dry_run: true)
      else
        info 'No tracked state entry would be modified.'
      end
    end

    def format_flavor(flavor)
      gpu = flavor['gpu'].to_s.empty? ? 'CPU-only' : flavor['gpu']
      [
        flavor['name'],
        gpu,
        "#{flavor['gpu_count']} GPU",
        "#{flavor['ram']} GB RAM",
        "#{flavor['cpu']} vCPU",
        "stock=#{flavor['stock_available']}"
      ].join(', ')
    end

    # Returns the effective Ollama flag: CLI override if set, else config default.
    def effective_ollama?
      defined?(@effective_ollama) ? @effective_ollama : @config.ollama_install_enabled?
    end

    # Returns the effective vLLM flag: CLI override if set, else config default.
    def effective_vllm?
      defined?(@effective_vllm) ? @effective_vllm : @config.vllm_install_enabled?
    end

    # Returns the resolved preset config hash when a preset was selected via
    # --model, or nil when using the top-level [vllm] defaults directly.
    def effective_vllm_preset_config
      name = defined?(@effective_vllm_preset) ? @effective_vllm_preset : nil
      return nil unless name

      @config.vllm_preset(name)
    end

    def vllm_setup_needed?(state)
      return false unless effective_vllm?
      return true if state['vllm_setup_at'].nil?

      # Re-run if the active model changed (direct config edit or --model preset flag).
      desired = effective_vllm_preset_config&.dig('model') || @config.vllm_model
      state['vllm_model'] != desired
    end

    # Tests the vLLM OpenAI-compatible API: lists loaded models and runs a
    # short inference request to confirm the model accepts requests.
    def test_vllm(wg_ip)
      port = @config.ollama_port

      info "  Testing vLLM models list at http://#{wg_ip}:#{port}/v1/models..."
      uri  = URI("http://#{wg_ip}:#{port}/v1/models")
      resp = Net::HTTP.get_response(uri)
      raise Error, "vLLM /v1/models returned HTTP #{resp.code}" unless resp.code == '200'

      models = JSON.parse(resp.body).fetch('data', []).map { |m| m['id'] }
      raise Error, 'vLLM returned an empty model list' if models.empty?

      # Use the currently loaded model (may differ from config default after a switch).
      model = models.first
      info "    Models loaded: #{models.join(', ')}"
      info '  Testing vLLM inference...'
      reply = vllm_chat(wg_ip, port, model, 'Say hello in five words.')
      info "    vLLM response: #{reply}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Error, "Cannot reach vLLM at #{wg_ip}:#{port} — is WireGuard (wg1) active? (#{e.message})"
    end

    # Sends a single OpenAI chat completion request and returns the reply text.
    def vllm_chat(host, port, model, prompt)
      uri = URI("http://#{host}:#{port}/v1/chat/completions")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = 'Bearer EMPTY'
      req.body = JSON.generate(
        'model' => model,
        'messages' => [{ 'role' => 'user', 'content' => prompt }],
        # 500 tokens: reasoning models use tokens for chain-of-thought
        # before content; 50 is too small and yields an empty content field.
        'max_tokens' => 500
      )
      resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 120) { |h| h.request(req) }
      raise Error, "vLLM inference returned HTTP #{resp.code}" unless resp.code == '200'

      JSON.parse(resp.body).dig('choices', 0, 'message', 'content').to_s.strip
    end

    def integer_or_nil(value)
      value.nil? ? nil : Integer(value)
    end

    def print_local_wireguard_summary(expected_ips)
      return unless @config.local_client_checks_enabled?

      wg_status = @local_wireguard.status
      endpoints = Array(wg_status['endpoints']).compact.uniq
      info "Local WireGuard #{@config.local_interface_name}: #{wg_status['service_state']}"
      if endpoints.empty?
        if wg_status['config_readable']
          info 'Local WireGuard has no configured peers.'
        else
          warn "Unable to read #{@config.local_wg_config_path} for local WireGuard endpoint validation."
        end
        return
      end

      label = endpoints.one? ? 'endpoint' : 'endpoints'
      info "Local WireGuard #{label}: #{endpoints.join(', ')}"

      expected = Array(expected_ips).compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
      return if expected.empty?

      expected_endpoints = expected.map { |ip| "#{ip}:#{@config.wireguard_udp_port}" }
      missing = expected_endpoints.reject { |endpoint| endpoints.include?(endpoint) }

      if expected_endpoints.one?
        if missing.empty?
          info 'Local WireGuard endpoint matches the managed VM IP.'
        else
          hosts = endpoints.map { |endpoint| endpoint.split(':', 2).first }.uniq
          warn "Local WireGuard endpoints point to #{hosts.join(', ')}, expected #{expected.first}."
        end
        return
      end

      if missing.empty?
        info 'Local WireGuard has peers for all managed VM IPs.'
      else
        present = expected_endpoints - missing
        unless present.empty?
          info "Local WireGuard has peers for: #{present.map do |endpoint|
            endpoint.split(':', 2).first
          end.join(', ')}"
        end
        warn "Local WireGuard missing peers for: #{missing.map { |endpoint| endpoint.split(':', 2).first }.join(', ')}."
      end
    end

    def info(message)
      @out.puts(message)
    end

    def warn(message)
      @out.puts("WARN: #{message}")
    end
  end

  # Continuously polls all active VMs for vLLM Prometheus metrics (over HTTP/WireGuard)
  # and GPU stats (over SSH) and redraws a compact terminal dashboard every 60 seconds.
end
