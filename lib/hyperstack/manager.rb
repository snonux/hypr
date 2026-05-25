# frozen_string_literal: true

require_relative 'ssh_runner'
require_relative 'vm_lifecycle'
require_relative 'wireguard_setup'
require_relative 'model_switcher'
require_relative 'inference_tester'
require_relative 'provisioning_orchestrator'

module HyperstackVM
  # Thin facade that coordinates focused collaborators.
  class Manager
    def initialize(config:, client:, state_store:, local_wireguard:, out: $stdout,
                   local_wg_config_path: nil, wg_setup_pre: nil, wg_setup_post: nil)
      @config = config
      @client = client
      @state_store = state_store
      @local_wireguard = local_wireguard
      @out = out
      @wg_setup_pre = wg_setup_pre
      @wg_setup_post = wg_setup_post

      @scripts = ProvisioningScripts.new(config: config)
      @ssh_runner = SshRunner.new(config: config, out: out)
      @vm_lifecycle = VmLifecycle.new(
        config: config,
        client: client,
        state_store: state_store,
        local_wireguard: local_wireguard,
        out: out
      )
      @wireguard_setup = WireGuardSetup.new(
        config: config,
        ssh_runner: @ssh_runner,
        local_wireguard: local_wireguard,
        out: out,
        wg_setup_pre: wg_setup_pre,
        wg_setup_post: wg_setup_post
      )
      @provisioner = RemoteProvisioner.new(
        config: config,
        scripts: @scripts,
        out: out,
        ssh_command_runner: @ssh_runner.method(:run),
        ssh_stream_runner: @ssh_runner.method(:run_streaming)
      )
      @inference_tester = InferenceTester.new(
        config: config,
        out: out
      )
      @orchestrator = ProvisioningOrchestrator.new(
        config: config,
        client: client,
        state_store: state_store,
        scripts: @scripts,
        provisioner: @provisioner,
        ssh_runner: @ssh_runner,
        wireguard_setup: @wireguard_setup,
        inference_tester: @inference_tester,
        out: out
      )
      @model_switcher = ModelSwitcher.new(
        config: config,
        provisioner: @provisioner,
        state_store: state_store,
        out: out
      )
    end

    def create(replace: false, dry_run: false, install_vllm: nil, install_ollama: nil,
               flavor_name: nil, vllm_preset: nil)
      raise Error, "DRY RUN is not supported." if dry_run

      if replace
        existing = @state_store.load
        if existing && existing['vm_id']
          @vm_lifecycle.delete(vm_id: existing['vm_id'])
        end
      end

      install_vllm   = @config.vllm_install_enabled?   if install_vllm.nil?
      install_ollama = @config.ollama_install_enabled? if install_ollama.nil?

      state = @vm_lifecycle.create(
        flavor_name: flavor_name,
        vllm_preset: vllm_preset,
        install_vllm: install_vllm,
        install_ollama: install_ollama
      ) do |s|
        @local_wireguard.show_local_wireguard(s['public_ip'])
      end

      @orchestrator.run(
        state,
        vllm_preset: vllm_preset,
        install_vllm: install_vllm,
        install_ollama: install_ollama
      )
    rescue Error => e
      @state_store.save(state) if state
      raise
    end

    def delete(vm_id: nil, preserve_state_on_failure: false, dry_run: false, skip_local_cleanup: false)
      @vm_lifecycle.delete(
        vm_id: vm_id,
        preserve_state_on_failure: preserve_state_on_failure,
        dry_run: dry_run,
        skip_local_cleanup: skip_local_cleanup
      )
    end

    def status(include_local_wireguard: true)
      ip = @vm_lifecycle.status
      @local_wireguard.show_local_wireguard(ip) if include_local_wireguard
      ip
    end

    def show_local_wireguard(expected_ips)
      @vm_lifecycle.show_local_wireguard(expected_ips)
    end

    def switch_model(preset_name:, dry_run: false)
      @model_switcher.switch(preset_name: preset_name, dry_run: dry_run)
    end

    def test
      state = @state_store.load
      @inference_tester.test(state)
    end

    def list_models
      @vm_lifecycle.list_models
    end
  end
end
