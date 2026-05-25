# frozen_string_literal: true

module HyperstackVM
  # Orchestrates the VM lifecycle from creation through deletion.
  class VmLifecycle
    def initialize(config:, client:, state_store:, local_wireguard:, out:)
      @config = config
      @client = client
      @state_store = state_store
      @local_wireguard = local_wireguard
      @out = out
    end

    attr_reader :config, :client, :state_store

    def create(flavor_name: nil, vllm_preset: nil, install_vllm: nil, install_ollama: nil, &block)
      @effective_flavor_name = flavor_name.nil? ? @config.flavor_name : flavor_name
      @state_store.load if defined?(@state_store) # force load
      existing = @state_store.load
      if existing && existing['vm_id']
        raise Error,
              "State file #{@state_store.path} already tracks VM #{existing['vm_id']}. Use --replace or delete first."
      end

      resolved = resolve_dependencies
      vm_name  = @config.generated_vm_name
      info "Creating VM #{vm_name} in #{resolved[:environment]['name']} using #{@effective_flavor_name}..."

      payload = build_payload(vm_name, resolved, install_vllm: install_vllm, install_ollama: install_ollama)
      response = @client.create_vm(payload)
      instance = Array(response['instances']).first
      raise Error, 'Hyperstack create response did not include an instance ID.' unless instance&&['id']

      state = build_state(vm_name, instance, resolved)
      sync_service_mode(state, install_vllm: install_vllm, install_ollama: install_ollama)
      @state_store.save(state)
      yield state if block_given?
      state
    end

    def delete(vm_id: nil, preserve_state_on_failure: false, dry_run: false, skip_local_cleanup: false)
      state = @state_store.load
      target = vm_id || state&.dig('vm_id')
      raise Error, "No VM ID provided and no state file found at #{@state_store.path}." if target.nil?

      cleanup_local = !skip_local_cleanup && state && target == state['vm_id']
      if dry_run
        print_delete_dry_run(target, state, preserve_state_on_failure)
        return
      end

      info "Deleting VM #{target}..."
      @client.delete_vm(target)
      wait_for_deletion(target)
      if cleanup_local
        perform_local_cleanup(dry_run: false)
      end
      delete_ssh_known_hosts
      @state_store.delete unless preserve_state_on_failure
      info "VM #{target} deleted."
    rescue Error => e
      raise if preserve_state_on_failure
      gone = e.message.match?(/not_found|does not exist|does not exists|404/)
      @state_store.delete if gone
      raise
    end

    def status
      state = @state_store.load
      if state.nil?
        info "No tracked VM state file at #{@state_store.path}."
        return nil
      end

      begin
        vm = @client.get_vm(state['vm_id'])
        desired = desired_rules_for_state(state)
        current = Array(vm['security_rules']).map { |r| normalize_rule(r) }
        missing = desired - current
        vllm_e = state_vllm_enabled?(state)
        ollama_e = state_ollama_enabled?(state)
        info "Tracked VM: #{state['vm_id']} #{vm['name']}"
        info "Status: #{vm['status']} / #{vm['vm_state']}"
        info "Public IP: #{connect_host_for(vm) || 'none'}"
        info "Service mode: #{service_summary(vllm: vllm_e, ollama: ollama_e)}"
        info "Active model: #{state['vllm_model'] || @config.vllm_model}" if vllm_e
        info "Missing firewall rules: #{missing.empty? ? 'none' : missing.size}"
      rescue Error => e
        warn_out "Unable to load VM #{state['vm_id']}: #{e.message}"
      end
      connect_host_for(vm)
    end

    def resolve_dependencies
      environment = @client.list_environments.find { |item| item['name'] == @config.environment_name }
      raise Error, "Environment #{@config.environment_name.inspect} was not found in Hyperstack." unless environment

      flavor = @client.list_flavors.find do |item|
        item['name'] == @effective_flavor_name && item['region_name'] == environment['region']
      end
      raise Error, "Flavor #{@effective_flavor_name.inspect} is not available in #{environment['region']}." unless flavor
      if flavor['stock_available'] == false
        raise Error, "Flavor #{@effective_flavor_name.inspect} exists in #{environment['region']} but is out of stock."
      end

      image = @client.list_images.find do |item|
        item['name'] == @config.image_name && item['region_name'] == environment['region']
      end
      raise Error, "Image #{@config.image_name.inspect} is not available in #{environment['region']}." unless image

      keypair = @client.list_keypairs.find do |item|
        item['name'] == @config.ssh_key_name && item.dig('environment', 'name') == environment['name']
      end
      unless keypair
        raise Error, "Keypair #{@config.ssh_key_name.inspect} was not found in environment #{environment['name']}."
      end

      { environment: environment, flavor: flavor, image: image, keypair: keypair }
    end

    def wait_for_ready(vm_id)
      with_polling("VM #{vm_id} to become ready for firewall updates") do
        vm = @client.get_vm(vm_id)
        next nil if vm.nil?
        raise Error, "VM #{vm_id} entered failed state #{vm['status']} / #{vm['vm_state']}." if failed_vm?(vm)
        vm_ready?(vm) ? vm : nil
      end
    end

    def wait_for_connect_ip(vm_id)
      label = @config.assign_floating_ip? ? 'floating IP' : 'reachable IP'
      with_polling("VM #{vm_id} to receive a #{label}") do
        vm = @client.get_vm(vm_id)
        raise Error, "VM #{vm_id} entered failed state #{vm['status']} / #{vm['vm_state']}." if failed_vm?(vm)
        connect_host_for(vm) ? vm : nil
      end
    end

    def wait_for_deletion(vm_id)
      with_polling("VM #{vm_id} deletion", timeout: 300) do
        @client.get_vm(vm_id)
        nil
      rescue Error => e
        raise unless e.message.match?(/not_found|does not exists/)
        true
      end
    end

    def ensure_security_rules(vm)
      existing = Array(vm['security_rules'])
      existing_norm = existing.map { |r| normalize_rule(r) }
      desired = desired_rules.map { |r| normalize_rule(r) }

      (desired - existing_norm).each do |rule|
        info "Adding Hyperstack firewall rule #{rule['protocol']} #{rule['remote_ip_prefix']} #{rule['port_range_min']}..."
        @client.create_vm_rule(vm['id'], rule)
      end

      legacy_litellm(existing).each do |rule|
        rule_id = rule['id'] || rule['rule_id']
        unless rule_id
          warn_out 'Found legacy Hyperstack firewall rule for port 4000, but the API payload has no rule id; remove it manually from the Hyperstack console.'
          next
        end
        info "Removing legacy Hyperstack firewall rule #{rule['protocol']} #{rule['remote_ip_prefix']} #{rule['port_range_min']}..."
        @client.delete_vm_rule(vm['id'], rule_id)
      rescue Error => e
        warn_out "Failed to remove legacy Hyperstack firewall rule #{rule_id}: #{e.message}"
      end
    end

    def connect_host_for(vm)
      return vm['floating_ip'] if @config.assign_floating_ip?
      vm['floating_ip'] || vm['fixed_ip']
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

    def desired_rules(include_vllm: @config.vllm_install_enabled?,
                      include_ollama: @config.ollama_install_enabled?)
      @config.desired_security_rules(include_vllm: include_vllm, include_ollama: include_ollama)
    end

    def desired_rules_for_state(state)
      desired_rules(include_vllm: state_vllm_enabled?(state),
                    include_ollama: state_ollama_enabled?(state))
    end

    def failed_vm?(vm)
      [vm['status'], vm['vm_state'], vm['power_state']].compact.any? do |v|
        v.to_s.downcase.match?(/error|failed|deleted|shelved/)
      end
    end

    def vm_ready?(vm)
      %w[ACTIVE SHUTOFF HIBERNATED].include?(vm['status'].to_s.upcase)
    end

    def format_flavor(flavor)
      gpu = flavor['gpu'].to_s.empty? ? 'CPU-only' : flavor['gpu']
      [flavor['name'], gpu, "#{flavor['gpu_count']} GPU", "#{flavor['ram']} GB RAM", "#{flavor['cpu']} vCPU",
       "stock=#{flavor['stock_available']}"].join(', ')
    end

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

    def show_local_wireguard(expected_ips)
      return unless @config.local_client_checks_enabled?
      wg_status = @local_wireguard.status
      endpoints = Array(wg_status['endpoints']).compact.uniq
      info "Local WireGuard #{@config.local_interface_name}: #{wg_status['service_state']}"
      if endpoints.empty?
        wg_status['config_readable'] ? info('Local WireGuard has no configured peers.') : warn_out("Unable to read #{@config.local_wg_config_path}.")
        return
      end
      label = endpoints.one? ? 'endpoint' : 'endpoints'
      info "Local WireGuard #{label}: #{endpoints.join(', ')}"
      check_endpoints(expected_ips, endpoints)
    end

    private

    def build_payload(vm_name, resolved, install_vllm: nil, install_ollama: nil)
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
        'security_rules' => desired_rules(include_vllm: install_vllm, include_ollama: install_ollama)
      }
      payload['labels'] = @config.labels unless @config.labels.empty?
      payload['user_data'] = @config.user_data if @config.user_data
      payload
    end

    def build_state(vm_name, instance, resolved)
      {
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
    end

    def sync_service_mode(state, install_vllm: nil, install_ollama: nil)
      state['services'] = {
        'vllm_enabled' => install_vllm.nil? ? @config.vllm_install_enabled? : install_vllm,
        'ollama_enabled' => install_ollama.nil? ? @config.ollama_install_enabled? : install_ollama
      }
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

    def service_summary(vllm:, ollama:)
      parts = []
      parts << 'vLLM' if vllm
      parts << 'Ollama' if ollama
      parts.empty? ? 'All inference services disabled' : "#{parts.join(', ')} enabled"
    end

    def legacy_litellm(rules)
      Array(rules).select do |rule|
        normalized = normalize_rule(rule)
        normalized['protocol'] == 'tcp' &&
          normalized['port_range_min'] == 4000 &&
          normalized['port_range_max'] == 4000 &&
          normalized['remote_ip_prefix'] == @config.wireguard_subnet
      end
    end

    def perform_local_cleanup(dry_run:)
      peers = @local_wireguard.remove_peers_by_allowed_ips(
        ["#{@config.wireguard_gateway_ip}/32"], dry_run: dry_run
      )
      hosts = @local_wireguard.remove_hostnames([@config.wireguard_gateway_hostname], dry_run: dry_run)
      report_cleanup(peers, hosts, dry_run)
    end

    def report_cleanup(peers, hosts, dry_run)
      peer_summary = peers.map { |p| p['AllowedIPs'] || p['Endpoint'] }.join(', ')
      host_summary = hosts.join(', ')
      if dry_run
        info 'DRY RUN: no matching local WireGuard peers or host entries would be removed.' if peers.empty? && hosts.empty?
        info "DRY RUN: local WireGuard peers would be removed for #{peer_summary}." unless peers.empty?
        info "DRY RUN: local host entries would be removed for #{host_summary}." unless hosts.empty?
        return
      end
      info 'No matching local WireGuard peers needed removal.' if peers.empty?
      info 'No matching local host entries needed removal.' if hosts.empty?
      info "Local WireGuard peers removed for #{peer_summary}." unless peers.empty?
      info "Local host entries removed for #{host_summary}." unless hosts.empty?
    end

    def delete_ssh_known_hosts
      File.delete(@config.ssh_known_hosts_path) if File.exist?(@config.ssh_known_hosts_path)
    rescue Errno::EACCES => e
      raise Error, "Cannot delete SSH known_hosts file #{@config.ssh_known_hosts_path}: #{e.message}"
    end

    def check_endpoints(expected_ips, endpoints)
      expected = Array(expected_ips).compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
      return if expected.empty?
      expected_endpoints = expected.map { |ip| "#{ip}:#{@config.wireguard_udp_port}" }
      missing = expected_endpoints.reject { |ep| endpoints.include?(ep) }
      if expected_endpoints.one?
        if missing.empty?
          info 'Local WireGuard endpoint matches the managed VM IP.'
        else
          hosts = endpoints.map { |ep| ep.split(':', 2).first }.uniq
          warn_out "Local WireGuard endpoints point to #{hosts.join(', ')}, expected #{expected.first}."
        end
        return
      end
      if missing.empty?
        info 'Local WireGuard has peers for all managed VM IPs.'
      else
        present = expected_endpoints - missing
        info "Local WireGuard has peers for: #{present.map { |ep| ep.split(':', 2).first }.join(', ')}" unless present.empty?
        warn_out "Local WireGuard missing peers for: #{missing.map { |ep| ep.split(':', 2).first }.join(', ')}."
      end
    end

    def with_polling(description, timeout: 900, interval: 5)
      deadline = Time.now + timeout
      attempt = 0
      loop do
        result = yield
        return result if result
        raise Error, "Timed out waiting for #{description}." if Time.now >= deadline
        attempt += 1
        info("  still waiting for #{description}... (#{attempt * interval}s)") if (attempt % 6).zero?
        sleep interval
      end
    end

    def integer_or_nil(value)
      value.nil? ? nil : Integer(value)
    end

    def info(msg)
      @out.puts(msg)
    end

    def warn_out(msg)
      @out.puts("WARN: #{msg}")
    end

    def print_delete_dry_run(target, state, preserve_state_on_failure)
      info 'DRY RUN: no VM will be deleted.'
      begin
        vm = @client.get_vm(target)
        info "Delete target: #{target} #{vm['name']} (#{vm['status']} / #{vm['vm_state']})"
        info "Delete target public IP: #{connect_host_for(vm) || 'none'}"
      rescue Error => e
        warn_out "Unable to inspect VM #{target} before delete: #{e.message}"
      end
      if state && state['vm_id'].to_i == target.to_i
        action = preserve_state_on_failure ? 'would remain unchanged' : 'would be removed'
        info "Tracked state file #{@state_store.path} #{action}."
        perform_local_cleanup(dry_run: true)
      else
        info 'No tracked state entry would be modified.'
      end
    end
  end
end
