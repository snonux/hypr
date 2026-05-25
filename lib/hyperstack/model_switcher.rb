# frozen_string_literal: true

module HyperstackVM
  # Hot-switches the running vLLM model on a provisioned VM.
  class ModelSwitcher
    def initialize(config:, provisioner:, state_store:, out:)
      @config = config
      @provisioner = provisioner
      @state_store = state_store
      @out = out
    end

    def switch(preset_name:, dry_run: false)
      preset = @config.vllm_preset(preset_name)
      state  = @state_store.load

      old_container = state&.dig('vllm_container_name') || @config.vllm_container_name
      new_container = preset['container_name']
      current_model = state&.dig('vllm_model')

      if dry_run
        print_dry_run(preset_name, preset, current_model, old_container, new_container)
        return
      end

      raise Error, "No tracked VM. Run 'create' first." unless state&.dig('vm_id')
      host = state['public_ip']
      raise Error, 'No public IP in state file.' if host.nil? || host.empty?

      @provisioner.stop_vllm_container(host, old_container) if old_container != new_container

      info "Starting vLLM with preset '#{preset_name}' (#{preset['model']})..."
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

    private

    def print_dry_run(preset_name, preset, current_model, old_container, new_container)
      info "DRY RUN: model switch to preset '#{preset_name}'"
      info "  #{current_model || 'none'} → #{preset['model']}"
      info "  container: #{old_container} → #{new_container}"
      trust_note  = preset['trust_remote_code'] ? ', trust_remote_code: true' : ''
      parser_note = preset['tool_call_parser'].to_s.empty? ? 'none' : preset['tool_call_parser']
      extra_note  = preset['extra_vllm_args']&.any? ? ", extra_args: #{preset['extra_vllm_args'].join(' ')}" : ''
      info "  max_model_len: #{preset['max_model_len']}, tool_call_parser: #{parser_note}#{trust_note}#{extra_note}"
    end

    def state_ollama_enabled?(state)
      recorded = state&.dig('services', 'ollama_enabled')
      return recorded unless recorded.nil?
      return true if state&.key?('ollama_installed_at') || state&.key?('ollama_setup_at')
      @config.ollama_install_enabled?
    end

    def info(msg)
      @out.puts(msg)
    end
  end
end
