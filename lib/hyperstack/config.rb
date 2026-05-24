# frozen_string_literal: true

require 'fileutils'
require 'ipaddr'
require 'json'
require 'toml-rb'

module HyperstackVM
  class ConfigLoader
    attr_reader :path

    def self.load(path)
      expanded = File.expand_path(path)
      raise Error, "Config file not found: #{expanded}" unless File.exist?(expanded)

      raw = TomlRB.load_file(expanded)
      new(raw, expanded)
    rescue TomlRB::ParseError => e
      raise Error, "Failed to parse TOML config #{expanded}: #{e.message}"
    end

    def initialize(raw, path)
      @path = path
      @data = deep_merge(DEFAULTS, raw || {})
      validate!
    end

    def config
      Config.new(@data, @path)
    end

    private

    DEFAULTS = {
      'auth' => {
        'api_key_file' => '~/.hyperstack'
      },
      'hyperstack' => {
        'base_url' => 'https://infrahub-api.nexgencloud.com/v1'
      },
      'state' => {
        'file' => '.hyperstack-vm-state.json'
      },
      'vm' => {
        'name_prefix' => 'hyperstack',
        'hostname' => 'hyperstack',
        'flavor_name' => 'n3-A100x1',
        'image_name' => 'Ubuntu Server 24.04 LTS R570 CUDA 12.8 with Docker',
        'assign_floating_ip' => true,
        'create_bootable_volume' => false,
        'enable_port_randomization' => false,
        'labels' => %w[gpt-oss-120b wireguard]
      },
      'ssh' => {
        'username' => 'ubuntu',
        'private_key_path' => '~/.ssh/id_rsa',
        'hyperstack_key_name' => 'earth',
        'port' => 22,
        'connect_timeout_sec' => 10
      },
      'network' => {
        'wireguard_udp_port' => 56_710,
        'wireguard_subnet' => '192.168.3.0/24',
        # Optional: explicit server-side WireGuard IP. When nil, derived as subnet + 1 (i.e. .1).
        # Set to a different address (e.g. 192.168.3.3) for a second VM sharing the same wg1 tunnel.
        'wireguard_server_ip' => nil,
        'ollama_port' => 11_434,
        'allowed_ssh_cidrs' => ['auto'],
        'allowed_wireguard_cidrs' => ['auto']
      },
      'bootstrap' => {
        'enable_guest_bootstrap' => true,
        'install_wireguard' => true,
        'configure_ufw' => true,
        'configure_ollama_host' => false
      },
      'ollama' => {
        'install' => false,
        'models_dir' => '/ephemeral/ollama/models',
        'listen_host' => '0.0.0.0:11434',
        'gpu_overhead_mb' => 2000,
        'num_parallel' => 1,
        'context_length' => 32_768,
        'pull_models' => ['qwen3-coder:30b', 'gpt-oss:20b', 'gpt-oss:120b', 'nemotron-3-super']
      },
      'vllm' => {
        'install' => true,
        'model' => 'Qwen/Qwen3.6-27B-FP8',
        'hug_cache_dir' => '/ephemeral/hug',
        'container_name' => 'vllm_qwen36_27b',
        'max_model_len' => 262_144,
        'gpu_memory_utilization' => 0.92,
        'tensor_parallel_size' => 1,
        'tool_call_parser' => 'qwen3_coder'
      },
      'local_client' => {
        'check_wg1_service' => true,
        'interface_name' => 'wg1',
        'config_path' => '/etc/wireguard/wg1.conf'
      }
    }.freeze

    def validate!
      %w[auth hyperstack state vm ssh network bootstrap ollama vllm wireguard local_client].each do |section|
        raise Error, "Missing config section [#{section}]" unless @data.key?(section)
      end

      %w[environment_name flavor_name image_name].each do |key|
        raise Error, "Missing [vm].#{key} in config #{path}" if blank?(dig('vm', key))
      end

      if fetch('vm', 'hostname') && fetch('vm', 'hostname') !~ /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
        raise Error,
              "Invalid [vm].hostname #{fetch('vm',
                                             'hostname').inspect}; use lowercase letters, digits, and hyphens only."
      end

      %w[username hyperstack_key_name].each do |key|
        raise Error, "Missing [ssh].#{key} in config #{path}" if blank?(dig('ssh', key))
      end

      ssh_cidrs = normalized_cidrs(fetch('network', 'allowed_ssh_cidrs'))
      wireguard_cidrs = normalized_cidrs(fetch('network', 'allowed_wireguard_cidrs'))

      raise Error, missing_cidr_message('allowed_ssh_cidrs') if ssh_cidrs.empty?
      raise Error, missing_cidr_message('allowed_wireguard_cidrs') if wireguard_cidrs.empty?

      [fetch('network', 'wireguard_subnet'), *ssh_cidrs, *wireguard_cidrs].each do |cidr|
        next if cidr == 'auto'

        IPAddr.new(cidr)
      rescue IPAddr::InvalidAddressError => e
        raise Error, "Invalid CIDR #{cidr.inspect}: #{e.message}"
      end

      server_ip = fetch('network', 'wireguard_server_ip')
      return unless server_ip

      # Validate that the explicit server WireGuard IP is within the configured subnet.
      begin
        subnet = IPAddr.new(fetch('network', 'wireguard_subnet'))
        unless subnet.include?(IPAddr.new(server_ip))
          raise Error,
                "wireguard_server_ip #{server_ip.inspect} is not in wireguard_subnet #{fetch('network',
                                                                                             'wireguard_subnet')}"
        end
      rescue IPAddr::InvalidAddressError => e
        raise Error, "Invalid wireguard_server_ip #{server_ip.inspect}: #{e.message}"
      end
    end

    def fetch(section, key)
      dig(section, key)
    end

    def dig(*keys)
      keys.reduce(@data) do |memo, key|
        memo.is_a?(Hash) ? memo[key] : nil
      end
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def truthy?(value)
      value == true
    end

    def normalized_cidrs(values)
      Array(values).map { |value| value.to_s.strip }.reject(&:empty?)
    end

    def missing_cidr_message(key)
      "Missing [network].#{key} in config #{path}; set it to one or more CIDRs, or ['auto'] to restrict access to the current public operator IP."
    end

    def deep_merge(left, right)
      left.merge(right) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end
  end

  class Config
    attr_reader :path

    def initialize(data, path = nil)
      @data = data
      @path = path
    end

    def api_key
      key_path = expand_path(fetch('auth', 'api_key_file'))
      raise Error, "API key file not found: #{key_path}" unless File.exist?(key_path)

      token = File.readlines(key_path, chomp: true).find { |line| !line.strip.empty? }&.strip
      raise Error, "API key file is empty: #{key_path}" if token.nil? || token.empty?

      token
    rescue Errno::EACCES => e
      raise Error, "Cannot read API key file #{key_path}: #{e.message}"
    end

    def api_base_url
      fetch('hyperstack', 'base_url')
    end

    def state_file
      expand_path(fetch('state', 'file'))
    end

    def environment_name
      fetch('vm', 'environment_name')
    end

    def flavor_name
      fetch('vm', 'flavor_name')
    end

    def image_name
      fetch('vm', 'image_name')
    end

    def vm_name_prefix
      fetch('vm', 'name_prefix')
    end

    def generated_vm_name
      "#{vm_name_prefix}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
    end

    def vm_hostname
      value = fetch('vm', 'hostname')
      return nil if blank?(value)

      value.to_s.downcase
    end

    def assign_floating_ip?
      truthy?(fetch('vm', 'assign_floating_ip'))
    end

    def create_bootable_volume?
      truthy?(fetch('vm', 'create_bootable_volume'))
    end

    def enable_port_randomization?
      truthy?(fetch('vm', 'enable_port_randomization'))
    end

    def labels
      Array(fetch('vm', 'labels')).map(&:to_s)
    end

    def user_data
      custom = custom_user_data
      return custom unless custom.nil? || custom.empty?
      return nil if vm_hostname.nil?

      default_hostname_cloud_init
    rescue Errno::ENOENT => e
      raise Error, "User data file not found: #{e.message}"
    rescue Errno::EACCES => e
      raise Error, "Cannot read user data file: #{e.message}"
    end

    def ssh_username
      fetch('ssh', 'username')
    end

    def ssh_private_key_path
      expand_path(fetch('ssh', 'private_key_path'))
    end

    def ssh_known_hosts_path
      "#{state_file}.known_hosts"
    end

    def ssh_key_name
      fetch('ssh', 'hyperstack_key_name')
    end

    def ssh_port
      Integer(fetch('ssh', 'port'))
    end

    def ssh_connect_timeout
      Integer(fetch('ssh', 'connect_timeout_sec'))
    end

    def wireguard_udp_port
      Integer(fetch('network', 'wireguard_udp_port'))
    end

    def wireguard_subnet
      fetch('network', 'wireguard_subnet')
    end

    def ollama_port
      Integer(fetch('network', 'ollama_port'))
    end

    # Returns the server-side WireGuard IP for this VM.
    # Uses the explicitly configured address when set; otherwise derives it as subnet_base + 1.
    # Example: 192.168.3.0/24 → 192.168.3.1 (default VM1); VM2 sets wireguard_server_ip=192.168.3.3.
    def wireguard_gateway_ip
      configured = fetch('network', 'wireguard_server_ip')
      return configured.to_s if configured && !configured.to_s.strip.empty?

      # Fall back to first usable address in the subnet.
      base = IPAddr.new(wireguard_subnet).to_s
      parts = base.split('.').map(&:to_i)
      parts[-1] += 1
      parts.join('.')
    end

    # Returns the WireGuard hostname for this VM: e.g. hyperstack1.wg1 or hyperstack2.wg1.
    # Used as the DNS name to reach the VM over the tunnel (must be in /etc/hosts on the client).
    def wireguard_gateway_hostname
      host = vm_hostname || 'hyperstack'
      "#{host}.#{local_interface_name}"
    end

    def allowed_ssh_cidrs
      resolved_allowed_cidrs('allowed_ssh_cidrs')
    end

    def allowed_wireguard_cidrs
      resolved_allowed_cidrs('allowed_wireguard_cidrs')
    end

    def guest_bootstrap_enabled?
      truthy?(fetch('bootstrap', 'enable_guest_bootstrap'))
    end

    def install_wireguard?
      truthy?(fetch('bootstrap', 'install_wireguard'))
    end

    def configure_ufw?
      truthy?(fetch('bootstrap', 'configure_ufw'))
    end

    def configure_ollama_host?
      truthy?(fetch('bootstrap', 'configure_ollama_host'))
    end

    def ollama_install_enabled?
      truthy?(fetch('ollama', 'install'))
    end

    def ollama_models_dir
      fetch('ollama', 'models_dir')
    end

    def ollama_listen_host
      fetch('ollama', 'listen_host')
    end

    def ollama_gpu_overhead_mb
      Integer(fetch('ollama', 'gpu_overhead_mb'))
    end

    def ollama_num_parallel
      Integer(fetch('ollama', 'num_parallel'))
    end

    def ollama_context_length
      Integer(fetch('ollama', 'context_length'))
    end

    def ollama_pull_models
      Array(fetch('ollama', 'pull_models')).map(&:to_s)
    end

    def vllm_install_enabled?
      truthy?(fetch('vllm', 'install'))
    end

    def vllm_model
      fetch('vllm', 'model')
    end

    def vllm_hug_cache_dir
      fetch('vllm', 'hug_cache_dir')
    end

    # Derived from hug_cache_dir: sibling directory for torch.compile artifacts.
    # Persisted across container restarts so recompilation is skipped on warm switches.
    def vllm_compile_cache_dir
      File.join(File.dirname(fetch('vllm', 'hug_cache_dir')), 'vllm_cache')
    end

    def vllm_container_name
      fetch('vllm', 'container_name')
    end

    def vllm_max_model_len
      Integer(fetch('vllm', 'max_model_len'))
    end

    def vllm_gpu_memory_utilization
      Float(fetch('vllm', 'gpu_memory_utilization'))
    end

    def vllm_tensor_parallel_size
      Integer(fetch('vllm', 'tensor_parallel_size'))
    end

    def vllm_tool_call_parser
      fetch('vllm', 'tool_call_parser')
    end

    # Whether to pass --trust-remote-code to vLLM for the default model.
    # Required for architectures not yet in the vLLM upstream registry (e.g. nemotron_h).
    def vllm_trust_remote_code
      truthy?(fetch('vllm', 'trust_remote_code'))
    end

    # Extra vLLM CLI flags for the default model (e.g. reasoning-parser args).
    def vllm_extra_args
      Array(fetch('vllm', 'extra_vllm_args')).map(&:to_s)
    end

    # Extra Docker -e KEY=VALUE env vars for the vLLM container (e.g. VLLM_ALLOW_LONG_MAX_MODEL_LEN=1).
    def vllm_extra_docker_env
      Array(fetch('vllm', 'extra_docker_env')).map(&:to_s)
    end

    # Docker image for vLLM. Defaults to the stable release.
    # Override to 'vllm/vllm-openai:nightly' for models not yet supported by stable vLLM.
    def vllm_docker_image
      fetch('vllm', 'docker_image') || 'vllm/vllm-openai:latest'
    end

    # Shell command to run inside the container before starting vLLM (via --entrypoint bash).
    # Used to patch dependencies at startup, e.g. upgrading transformers for new model architectures.
    # nil means no pre-start command — vLLM is started directly (default entrypoint).
    def vllm_pre_start_cmd
      fetch('vllm', 'pre_start_cmd')
    end

    # Whether to pass --enable-prefix-caching to vLLM. Defaults to true.
    # Disable for hybrid Mamba models (NemotronH): prefix caching forces Mamba into "all" cache
    # mode which pre-allocates states for all sequences, consuming extra VRAM on startup.
    def vllm_prefix_caching_enabled?
      val = dig('vllm', 'enable_prefix_caching')
      val.nil? || truthy?(val)
    end

    def vllm_presets
      Hash(dig('vllm', 'presets')).transform_keys(&:to_s)
    end

    def vllm_preset_names
      vllm_presets.keys
    end

    def vllm_preset(name)
      raw = vllm_presets[name.to_s]
      unless raw
        available = vllm_preset_names.empty? ? 'none configured' : vllm_preset_names.join(', ')
        raise Error, "Unknown vLLM preset #{name.inspect}. Available: #{available}"
      end
      {
        'model' => raw['model'] || vllm_model,
        'container_name' => raw['container_name'] || vllm_container_name,
        'max_model_len' => Integer(raw['max_model_len'] || vllm_max_model_len),
        'gpu_memory_utilization' => Float(raw['gpu_memory_utilization'] || vllm_gpu_memory_utilization),
        'tensor_parallel_size' => Integer(raw['tensor_parallel_size'] || vllm_tensor_parallel_size),
        'tool_call_parser' => raw.key?('tool_call_parser') ? raw['tool_call_parser'] : vllm_tool_call_parser,
        'trust_remote_code' => raw.key?('trust_remote_code') ? raw['trust_remote_code'] : false,
        'extra_vllm_args' => raw.key?('extra_vllm_args') ? Array(raw['extra_vllm_args']) : [],
        'extra_docker_env' => raw.key?('extra_docker_env') ? Array(raw['extra_docker_env']) : [],
        # docker_image / pre_start_cmd: nil means "not set in preset" — fall back to [vllm] defaults.
        'docker_image' => raw.key?('docker_image') ? raw['docker_image'] : nil,
        'pre_start_cmd' => raw.key?('pre_start_cmd') ? raw['pre_start_cmd'] : nil,
        # nil means "not set in preset" — fall back to the top-level [vllm] value in the script.
        'enable_prefix_caching' => raw.key?('enable_prefix_caching') ? raw['enable_prefix_caching'] : nil
      }
    end

    def local_client_checks_enabled?
      truthy?(fetch('local_client', 'check_wg1_service'))
    end

    def local_interface_name
      fetch('local_client', 'interface_name')
    end

    def local_wg_config_path
      fetch('local_client', 'config_path')
    end

    def wireguard_auto_setup?
      truthy?(fetch('wireguard', 'auto_setup'))
    end

    def wireguard_setup_script
      expand_path(fetch('wireguard', 'setup_script'))
    end

    def desired_security_rules(include_ollama: ollama_install_enabled?, include_vllm: vllm_install_enabled?)
      rules = []

      allowed_ssh_cidrs.each do |cidr|
        rules << firewall_rule('tcp', ssh_port, cidr)
      end

      allowed_wireguard_cidrs.each do |cidr|
        rules << firewall_rule('udp', wireguard_udp_port, cidr)
      end

      rules << firewall_rule('tcp', ollama_port, wireguard_subnet) if include_ollama || include_vllm
      rules.uniq
    end

    private

    def fetch(section, key)
      dig(section, key)
    end

    def dig(*keys)
      keys.reduce(@data) do |memo, key|
        memo.is_a?(Hash) ? memo[key] : nil
      end
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def truthy?(value)
      value == true
    end

    def resolved_allowed_cidrs(key)
      values = Array(fetch('network', key)).map { |value| value.to_s.strip }.reject(&:empty?)
      values.flat_map { |value| value == 'auto' ? [detected_operator_cidr] : [value] }.uniq
    end

    def detected_operator_cidr
      return @detected_operator_cidr if defined?(@detected_operator_cidr)
      raise @detected_operator_cidr_error if defined?(@detected_operator_cidr_error)

      configured = ENV['HYPERSTACK_OPERATOR_CIDR'].to_s.strip
      @detected_operator_cidr = normalize_operator_cidr(configured) unless configured.empty?
      return @detected_operator_cidr if defined?(@detected_operator_cidr)

      @detected_operator_cidr = detect_public_operator_cidr
    rescue Error => e
      @detected_operator_cidr_error = e
      raise
    end

    def normalize_operator_cidr(value)
      ip = IPAddr.new(value)
      suffix = ip.ipv4? ? 32 : 128
      value.include?('/') ? value : "#{ip}/#{suffix}"
    rescue IPAddr::InvalidAddressError => e
      raise Error, "Invalid HYPERSTACK_OPERATOR_CIDR #{value.inspect}: #{e.message}"
    end

    def detect_public_operator_cidr
      [
        'https://api.ipify.org',
        'https://ifconfig.me/ip',
        'https://ipv4.icanhazip.com'
      ].each do |url|
        cidr = fetch_public_cidr(url)
        return cidr if cidr
      end

      source = path || 'the active config'
      raise Error,
            "Unable to detect the current public operator IP for [network].allowed_*_cidrs = ['auto']. Set HYPERSTACK_OPERATOR_CIDR or replace 'auto' with explicit CIDRs in #{source}."
    end

    def fetch_public_cidr(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5,
                                                     read_timeout: 5) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      body = response.body.to_s.strip
      return nil if body.empty?

      ip = IPAddr.new(body)
      suffix = ip.ipv4? ? 32 : 128
      "#{ip}/#{suffix}"
    rescue IPAddr::InvalidAddressError, SocketError, SystemCallError, Timeout::Error, Net::OpenTimeout,
           Net::ReadTimeout, OpenSSL::SSL::SSLError
      nil
    end

    def custom_user_data
      inline = dig('vm', 'user_data')
      return inline unless inline.nil? || inline.empty?

      file = dig('vm', 'user_data_file')
      return nil if file.nil? || file.empty?

      File.read(expand_path(file))
    end

    def default_hostname_cloud_init
      <<~CLOUD_INIT
        #cloud-config
        preserve_hostname: false
        hostname: #{vm_hostname}
      CLOUD_INIT
    end

    def expand_path(value)
      return nil if value.nil?

      string = value.to_s
      return File.expand_path(string) if string.start_with?('~')
      return string if string.start_with?('/')

      File.expand_path(string, File.dirname(@path)) if @path
    end

    def firewall_rule(protocol, port, cidr)
      ip = IPAddr.new(cidr)
      {
        'direction' => 'ingress',
        'ethertype' => ip.ipv4? ? 'IPv4' : 'IPv6',
        'protocol' => protocol,
        'port_range_min' => port,
        'port_range_max' => port,
        'remote_ip_prefix' => cidr
      }
    end
  end
end
