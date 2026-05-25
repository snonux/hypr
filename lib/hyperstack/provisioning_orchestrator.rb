# frozen_string_literal: true

module HyperstackVM
  # Orchestrates the post-creation provisioning steps: bootstrap, Ollama, WireGuard, vLLM.
  class ProvisioningOrchestrator
    def initialize(config:, client:, state_store:, scripts:, provisioner:, ssh_runner:,
                   wireguard_setup:, inference_tester:, out:)
      @config = config
      @client = client
      @state_store = state_store
      @scripts = scripts
      @provisioner = provisioner
      @ssh_runner = ssh_runner
      @wireguard_setup = wireguard_setup
      @inference_tester = inference_tester
      @out = out
    end

    attr_reader :config

    def run(state, vllm_preset: nil, install_vllm: nil, install_ollama: nil)
      @install_vllm   = install_vllm
      @install_ollama = install_ollama
      vm_id = state['vm_id']
      vm = wait_for_ready(vm_id)
      ensure_rules(vm)
      vm = wait_for_connect_ip(vm_id)
      state['public_ip'] = connect_host_for(vm)
      state['security_rules'] = Array(vm['security_rules']).map { |r| normalize_rule(r) }
      @state_store.save(state)

      @ssh_runner.ensure_trusted_host(state['public_ip'])

      if @config.guest_bootstrap_enabled? && state['bootstrapped_at'].nil?
        @provisioner.bootstrap_guest(state['public_ip'])
        state['bootstrapped_at'] = Time.now.utc.iso8601
        @state_store.save(state)
      end

      if effective_ollama? && state['ollama_installed_at'].nil?
        @provisioner.install_ollama_service(state['public_ip'])
        state['ollama_installed_at'] = Time.now.utc.iso8601
        @state_store.save(state)
      end

      @wireguard_setup.run(state)
      if state['wireguard_setup_at']
        @state_store.save(state)
      end

      if ollama_needed?(state)
        @provisioner.pull_ollama_models(state['public_ip'])
        state['ollama_setup_at'] = Time.now.utc.iso8601
        state['ollama_models_dir'] = @config.ollama_models_dir
        state['ollama_pulled_models'] = @scripts.desired_ollama_models
        @state_store.save(state)
      end

      if vllm_needed?(state, vllm_preset)
        preset_cfg = resolve_preset(vllm_preset)
        @provisioner.setup_vllm_stack(state['public_ip'], preset_config: preset_cfg)
        state['vllm_setup_at']       = Time.now.utc.iso8601
        state['vllm_model']          = preset_cfg&.dig('model')          || @config.vllm_model
        state['vllm_container_name'] = preset_cfg&.dig('container_name') || @config.vllm_container_name
        state['vllm_preset']         = vllm_preset
        @state_store.save(state)
      end

      vm = @client.get_vm(vm_id)
      state['security_rules'] = Array(vm['security_rules']).map { |r| normalize_rule(r) }
      state['status'] = vm['status']
      state['vm_state'] = vm['vm_state']
      state['provisioned_at'] = Time.now.utc.iso8601
      @state_store.save(state)

      info "VM ready: #{state['public_ip']} (id=#{state['vm_id']})"
      @inference_tester.test(state)
      state
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

    def ensure_rules(vm)
      existing = Array(vm['security_rules'])
      existing_norm = existing.map { |r| normalize_rule(r) }
      desired = desired_rules.map { |r| normalize_rule(r) }
      (desired - existing_norm).each do |rule|
        info "Adding Hyperstack firewall rule #{rule['protocol']} #{rule['remote_ip_prefix']} #{rule['port_range_min']}..."
        @client.create_vm_rule(vm['id'], rule)
      end

      legacy_litellm_rules(existing).each do |rule|
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

    def effective_ollama?
      @install_ollama.nil? ? @config.ollama_install_enabled? : @install_ollama
    end

    def effective_vllm?
      @install_vllm.nil? ? @config.vllm_install_enabled? : @install_vllm
    end

    def ollama_needed?(state)
      return false unless effective_ollama?
      return true if state['ollama_setup_at'].nil?
      current = state['ollama_pulled_models'] || []
      @scripts.model_list_signature(@scripts.desired_ollama_models) != @scripts.model_list_signature(current)
    end

    def vllm_needed?(state, vllm_preset)
      return false unless effective_vllm?
      return true if state['vllm_setup_at'].nil?
      desired = resolve_preset(vllm_preset)&.dig('model') || @config.vllm_model
      state['vllm_model'] != desired
    end

    def resolve_preset(vllm_preset)
      return nil unless vllm_preset
      @config.vllm_preset(vllm_preset)
    end

    def connect_host_for(vm)
      return vm['floating_ip'] if @config.assign_floating_ip?
      vm['floating_ip'] || vm['fixed_ip']
    end

    def desired_rules
      @config.desired_security_rules(include_vllm: effective_vllm?, include_ollama: effective_ollama?)
    end

    def normalize_rule(rule)
      {
        'direction' => rule['direction'].to_s.downcase,
        'ethertype' => rule['ethertype'].to_s,
        'protocol' => rule['protocol'].to_s.downcase,
        'port_range_min' => rule['port_range_min'].nil? ? nil : Integer(rule['port_range_min']),
        'port_range_max' => rule['port_range_max'].nil? ? nil : Integer(rule['port_range_max']),
        'remote_ip_prefix' => rule['remote_ip_prefix'].to_s
      }
    end

    def failed_vm?(vm)
      [vm['status'], vm['vm_state'], vm['power_state']].compact.any? do |v|
        v.to_s.downcase.match?(/error|failed|deleted|shelved/)
      end
    end

    def vm_ready?(vm)
      %w[ACTIVE SHUTOFF HIBERNATED].include?(vm['status'].to_s.upcase)
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

    private

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

    def info(msg)
      @out.puts(msg)
    end

    def warn_out(msg)
      @out.puts("WARN: #{msg}")
    end
  end
end
