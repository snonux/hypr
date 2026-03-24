#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  require 'bundler/setup'
rescue LoadError, Gem::GemNotFoundException, Gem::LoadError, Errno::ENOENT
  nil
end

require 'json'
require 'fileutils'
require 'net/http'
require 'open3'
require 'optparse'
require 'ipaddr'
require 'shellwords'
require 'socket'
require 'time'
require 'timeout'

begin
  require 'toml-rb'
rescue LoadError
  warn "Missing dependency: toml-rb. Run `bundle install` in #{__dir__} first."
  exit 2
end

module HyperstackVM
  class Error < StandardError; end

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
        'model' => 'bullpoint/Qwen3-Coder-Next-AWQ-4bit',
        'hug_cache_dir' => '/ephemeral/hug',
        'container_name' => 'vllm_qwen3',
        'max_model_len' => 262_144,
        'gpu_memory_utilization' => 0.92,
        'tensor_parallel_size' => 1,
        'tool_call_parser' => 'qwen3_coder'
      },
      'comfyui' => {
        'install' => false,
        'port' => 8188,
        'models_dir' => '/ephemeral/comfyui/models',
        'output_dir' => '/ephemeral/comfyui/output',
        'container_name' => 'comfyui',
        # Models to pre-download: Real-ESRGAN for fast upscaling, SUPIR for deep restoration.
        'models' => []
      },
      'wireguard' => {
        'auto_setup' => true,
        'setup_script' => './wg1-setup.sh'
      },
      'local_client' => {
        'check_wg1_service' => true,
        'interface_name' => 'wg1',
        'config_path' => '/etc/wireguard/wg1.conf'
      }
    }.freeze

    def validate!
      %w[auth hyperstack state vm ssh network bootstrap ollama vllm comfyui wireguard local_client].each do |section|
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
        # nil means "not set in preset" — fall back to the top-level [vllm] value in the script.
        'enable_prefix_caching' => raw.key?('enable_prefix_caching') ? raw['enable_prefix_caching'] : nil
      }
    end

    def comfyui_install_enabled?
      truthy?(fetch('comfyui', 'install'))
    end

    def comfyui_port
      Integer(fetch('comfyui', 'port'))
    end

    def comfyui_models_dir
      fetch('comfyui', 'models_dir')
    end

    def comfyui_output_dir
      fetch('comfyui', 'output_dir')
    end

    def comfyui_container_name
      fetch('comfyui', 'container_name')
    end

    # Models to pre-download during provisioning (e.g. RealESRGAN_x4plus, SUPIR-v0Q).
    def comfyui_models
      Array(fetch('comfyui', 'models')).map(&:to_s)
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

    def desired_security_rules(include_ollama: ollama_install_enabled?, include_vllm: vllm_install_enabled?,
                               include_comfyui: comfyui_install_enabled?)
      rules = []

      allowed_ssh_cidrs.each do |cidr|
        rules << firewall_rule('tcp', ssh_port, cidr)
      end

      allowed_wireguard_cidrs.each do |cidr|
        rules << firewall_rule('udp', wireguard_udp_port, cidr)
      end

      rules << firewall_rule('tcp', ollama_port, wireguard_subnet) if include_ollama || include_vllm
      # ComfyUI REST API on its own port, restricted to the WireGuard subnet.
      rules << firewall_rule('tcp', comfyui_port, wireguard_subnet) if include_comfyui
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

      configured = ENV['HYPERSTACK_OPERATOR_CIDR'].to_s.strip
      @detected_operator_cidr = normalize_operator_cidr(configured) unless configured.empty?
      return @detected_operator_cidr if defined?(@detected_operator_cidr)

      @detected_operator_cidr = detect_public_operator_cidr
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

  class StateStore
    def initialize(path)
      @path = path
    end

    attr_reader :path

    def load
      return nil unless File.exist?(@path)

      JSON.parse(File.read(@path))
    rescue JSON::ParserError => e
      raise Error, "Failed to parse state file #{@path}: #{e.message}"
    end

    def save(payload)
      temp_path = "#{@path}.tmp"
      File.write(temp_path, JSON.pretty_generate(payload))
      File.rename(temp_path, @path)
    end

    def delete
      File.delete(@path) if File.exist?(@path)
    end
  end

  class HyperstackClient
    def initialize(base_url:, api_key:)
      @base_uri = URI(base_url)
      @api_key = api_key
    end

    def list_environments
      response = request(:get, '/core/environments')
      response.fetch('environments', [])
    end

    def list_keypairs
      response = request(:get, '/core/keypairs')
      response.fetch('keypairs', [])
    end

    def list_flavors
      response = request(:get, '/core/flavors')
      Array(response['data']).flat_map do |entry|
        Array(entry['flavors']).map do |flavor|
          flavor.merge(
            'region_name' => flavor['region_name'] || entry['region_name'],
            'gpu' => flavor['gpu'] || entry['gpu']
          )
        end
      end
    end

    def list_images
      response = request(:get, '/core/images')
      Array(response['images']).flat_map do |entry|
        Array(entry['images']).map do |image|
          image.merge(
            'region_name' => image['region_name'] || entry['region_name'],
            'type' => image['type'] || entry['type']
          )
        end
      end
    end

    def list_vms
      response = request(:get, '/core/virtual-machines')
      response.fetch('instances', [])
    end

    def get_vm(vm_id)
      response = request(:get, "/core/virtual-machines/#{vm_id}")
      response.fetch('instance', nil)
    end

    def create_vm(payload)
      request(:post, '/core/virtual-machines', payload)
    end

    def delete_vm(vm_id)
      request(:delete, "/core/virtual-machines/#{vm_id}")
    end

    def create_vm_rule(vm_id, payload)
      request(:post, "/core/virtual-machines/#{vm_id}/sg-rules", payload)
    end

    def delete_vm_rule(vm_id, rule_id)
      request(:delete, "/core/virtual-machines/#{vm_id}/sg-rules/#{rule_id}")
    end

    private

    def request(method, path, payload = nil)
      uri = @base_uri.dup
      uri.path = "#{@base_uri.path}#{path}"

      request = case method
                when :get
                  Net::HTTP::Get.new(uri)
                when :post
                  Net::HTTP::Post.new(uri)
                when :delete
                  Net::HTTP::Delete.new(uri)
                else
                  raise Error, "Unsupported HTTP method: #{method}"
                end

      request['accept'] = 'application/json'
      request['api_key'] = @api_key
      if payload
        request['content-type'] = 'application/json'
        request.body = JSON.generate(payload)
      end

      retries_left = 4
      begin
        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == 'https',
          open_timeout: 30,
          read_timeout: 120
        ) { |http| http.request(request) }

        parse_response(response)
      rescue Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET,
             Errno::EHOSTUNREACH, Errno::ENETUNREACH,
             SocketError, OpenSSL::SSL::SSLError, Net::OpenTimeout => e
        raise Error, "Hyperstack API request failed for #{path}: #{e.message}" if retries_left <= 0

        retries_left -= 1
        delay = (4 - retries_left) * 5
        warn "API request to #{path} failed (#{e.class}: #{e.message}), retrying in #{delay}s (#{retries_left} left)..."
        sleep delay
        retry
      end
    end

    def parse_response(response)
      body = response.body.to_s
      payload = body.empty? ? {} : JSON.parse(body)

      if response.code.to_i >= 400 || payload['status'] == false
        message = payload['message'] || payload['error_reason'] || response.message
        raise Error, "Hyperstack API error (HTTP #{response.code}): #{message}"
      end

      payload
    rescue JSON::ParserError => e
      raise Error, "Failed to parse Hyperstack API response: #{e.message}"
    end
  end

  class LocalWireGuard
    def initialize(interface_name:, config_path:)
      @interface_name = interface_name
      @config_path = config_path
    end

    def status
      endpoints = configured_endpoints
      {
        'service_state' => service_state,
        'config_path' => @config_path,
        'endpoint' => endpoints.last,
        'endpoints' => endpoints,
        'config_readable' => !config_contents.nil?
      }
    end

    def remove_peers_by_allowed_ips(allowed_ips, dry_run: false)
      targets = Array(allowed_ips).map(&:to_s).map(&:strip).reject(&:empty?).uniq
      return [] if targets.empty?

      content = config_contents
      raise Error, "Unable to read #{@config_path} for peer cleanup." if content.nil?

      updated, removed = prune_peer_blocks(content, targets)
      return [] if removed.empty?
      return removed if dry_run

      write_config(updated)
      restart_service_if_active
      @config_contents = updated
      removed
    end

    def remove_hostnames(hostnames, dry_run: false)
      targets = Array(hostnames).map(&:to_s).map(&:strip).reject(&:empty?).uniq
      return [] if targets.empty?

      content = hosts_contents
      raise Error, 'Unable to read /etc/hosts for hostname cleanup.' if content.nil?

      updated, removed = prune_hosts_entries(content, targets)
      return [] if removed.empty?
      return removed if dry_run

      write_hosts(updated)
      @hosts_contents = updated
      removed
    end

    private

    def service_state
      stdout, _stderr, status = Open3.capture3('systemctl', 'is-active', "wg-quick@#{@interface_name}")
      value = stdout.to_s.strip
      return value unless value.empty?
      return 'active' if status.success?

      'unknown'
    end

    def configured_endpoint
      configured_endpoints.last
    end

    def configured_endpoints
      content = config_contents
      return [] if content.nil?

      parse_wireguard_peers(content).filter_map { |peer| peer['Endpoint'] }.uniq
    end

    def parse_wireguard_peers(content)
      current_section = nil
      current_peer = nil
      peers = []

      content.each_line do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#')

        if stripped.start_with?('[') && stripped.end_with?(']')
          peers << current_peer if current_section == 'Peer' && current_peer && !current_peer.empty?
          current_section = stripped[1..-2]
          current_peer = current_section == 'Peer' ? {} : nil
          next
        end

        key, value = stripped.split('=', 2).map { |part| part&.strip }
        next unless current_section == 'Peer' && key && value

        current_peer[key] = value
      end

      peers << current_peer if current_section == 'Peer' && current_peer && !current_peer.empty?
      peers
    end

    def prune_peer_blocks(content, allowed_ips)
      kept = []
      removed = []

      parse_wireguard_blocks(content).each do |block|
        if block[:section] == 'Peer' && allowed_ips.include?(block[:values]['AllowedIPs'].to_s.strip)
          removed << block[:values]
        else
          kept << block[:lines].join
        end
      end

      [kept.join, removed]
    end

    def parse_wireguard_blocks(content)
      blocks = []
      current_section = nil
      current_lines = []

      content.each_line do |line|
        stripped = line.strip
        if stripped.start_with?('[') && stripped.end_with?(']')
          blocks << wireguard_block(current_section, current_lines) unless current_lines.empty?
          current_section = stripped[1..-2]
          current_lines = [line]
        else
          current_lines << line
        end
      end

      blocks << wireguard_block(current_section, current_lines) unless current_lines.empty?
      blocks
    end

    def wireguard_block(section, lines)
      {
        section: section,
        lines: lines.dup,
        values: parse_wireguard_section_values(section, lines)
      }
    end

    def parse_wireguard_section_values(section, lines)
      return {} unless section == 'Peer'

      lines.each_with_object({}) do |line, values|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?('#') || stripped.start_with?('[')

        key, value = stripped.split('=', 2).map { |part| part&.strip }
        values[key] = value if key && value
      end
    end

    def write_config(content)
      File.write(@config_path, content)
    rescue Errno::EACCES
      _stdout, stderr, status = Open3.capture3('sudo', '-n', 'tee', @config_path, stdin_data: content)
      raise Error, "Failed to update #{@config_path}: #{stderr.to_s.strip}" unless status.success?

      _stdout, stderr, status = Open3.capture3('sudo', '-n', 'chmod', '600', @config_path)
      raise Error, "Failed to chmod #{@config_path}: #{stderr.to_s.strip}" unless status.success?
    end

    def restart_service_if_active
      return unless service_state == 'active'

      _stdout, stderr, status = Open3.capture3('sudo', '-n', 'systemctl', 'restart', "wg-quick@#{@interface_name}")
      raise Error, "Failed to restart wg-quick@#{@interface_name}: #{stderr.to_s.strip}" unless status.success?
    end

    def config_contents
      return @config_contents if defined?(@config_contents)

      @config_contents = File.read(@config_path)
    rescue Errno::EACCES, Errno::ENOENT
      stdout, _stderr, status = Open3.capture3('sudo', '-n', 'cat', @config_path)
      @config_contents = status.success? ? stdout : nil
    end

    def hosts_contents
      return @hosts_contents if defined?(@hosts_contents)

      @hosts_contents = File.read('/etc/hosts')
    rescue Errno::EACCES, Errno::ENOENT
      stdout, _stderr, status = Open3.capture3('sudo', '-n', 'cat', '/etc/hosts')
      @hosts_contents = status.success? ? stdout : nil
    end

    def prune_hosts_entries(content, hostnames)
      removed = []
      updated = content.each_line.filter_map do |line|
        rewritten, line_removed = prune_host_line(line, hostnames)
        removed.concat(line_removed)
        rewritten
      end
      [updated.join, removed.uniq]
    end

    def prune_host_line(line, hostnames)
      stripped = line.strip
      return [line, []] if stripped.empty? || stripped.start_with?('#')

      body, comment = line.split('#', 2)
      tokens = body.split(/\s+/)
      return [line, []] if tokens.empty?

      ip = tokens.shift
      removed = tokens & hostnames
      return [line, []] if removed.empty?

      remaining = tokens - hostnames
      return [nil, removed] if remaining.empty?

      rewritten = ([ip] + remaining).join("\t")
      rewritten = "#{rewritten}  # #{comment.strip}" if comment && !comment.strip.empty?
      ["#{rewritten}\n", removed]
    end

    def write_hosts(content)
      File.write('/etc/hosts', content)
    rescue Errno::EACCES
      _stdout, stderr, status = Open3.capture3('sudo', '-n', 'tee', '/etc/hosts', stdin_data: content)
      raise Error, "Failed to update /etc/hosts: #{stderr.to_s.strip}" unless status.success?
    end
  end

  # Thread-safe output wrapper that prepends a fixed prefix to each line.
  # Used by create-both so interleaved output from VM1 and VM2 threads is distinguishable.
  # #print buffers partial lines until a newline is received, then flushes with the prefix.
  class PrefixedOutput
    def initialize(prefix, delegate, mutex)
      @prefix   = prefix
      @delegate = delegate
      @mutex    = mutex
      @buffer   = +''
    end

    def puts(msg = '')
      @mutex.synchronize { @delegate.puts("#{@prefix}#{msg}") }
    end

    def print(msg)
      @buffer << msg.to_s
      while (idx = @buffer.index("\n"))
        line = @buffer.slice!(0, idx + 1)
        @mutex.synchronize { @delegate.print("#{@prefix}#{line}") }
      end
    end
  end

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
        # ComfyUI REST API on port 8188; only open when ComfyUI is enabled.
        if @config.comfyui_install_enabled?
          script << "sudo ufw allow from #{Shellwords.escape(@config.wireguard_subnet)} to any port #{@config.comfyui_port} proto tcp comment 'ComfyUI API via #{@config.local_interface_name}' >/dev/null 2>&1 || true"
        end
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
      script << "sudo chown -R ollama:ollama #{Shellwords.escape(File.dirname(models_dir))}"
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
      # empty string means "disable tool calling" (e.g. gpt-oss reasoning models).
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
      # Extra Docker env vars (e.g. VLLM_ALLOW_LONG_MAX_MODEL_LEN=1) injected before the image name.
      extra_env.each { |kv| docker_args << "-e #{Shellwords.escape(kv)}" }
      docker_args += [
        'vllm/vllm-openai:latest',
        "--model #{Shellwords.escape(model)}",
        "--tensor-parallel-size #{tp_size}",
        "--gpu-memory-utilization #{gpu_util}",
        "--max-model-len #{max_len}",
        '--host 0.0.0.0',
        "--port #{port}"
      ]
      # Prefix caching is beneficial for most models but forces Mamba "all" cache mode on
      # NemotronH, which pre-allocates states for all sequences and can OOM on startup.
      docker_args << '--enable-prefix-caching' if prefix_cache
      # Tool calling is optional: empty/nil parser disables it.
      unless parser.nil? || parser.empty?
        docker_args << '--enable-auto-tool-choice'
        docker_args << "--tool-call-parser #{Shellwords.escape(parser)}"
      end
      docker_args << '--trust-remote-code' if trust_remote
      extra_args = cfg.key?('extra_vllm_args') ? Array(cfg['extra_vllm_args']) : @config.vllm_extra_args
      extra_args.each { |arg| docker_args << arg }
      docker_run = docker_args.join(' ')

      script = []
      script << 'set -euo pipefail'
      script << "sudo mkdir -p #{Shellwords.escape(cache_dir)} #{Shellwords.escape(compile_cache)}"
      script << "sudo chmod -R 0777 #{Shellwords.escape(cache_dir)} #{Shellwords.escape(compile_cache)}"
      script << "docker stop #{Shellwords.escape(container)} 2>/dev/null || true"
      script << "docker rm #{Shellwords.escape(container)} 2>/dev/null || true"
      script << 'docker pull vllm/vllm-openai:latest' if pull_image
      script << docker_run
      script << 'echo "Waiting for vLLM to become ready (up to 10 min for first model download)..."'
      script << 'for i in $(seq 1 240); do'
      script << "  if curl -sf http://localhost:#{port}/v1/models >/dev/null 2>&1; then echo vllm-ready; break; fi"
      script << "  state=$(docker inspect --format='{{.State.Status}}' #{Shellwords.escape(container)} 2>/dev/null || echo unknown)"
      script << '  echo "  vLLM not ready yet ($i/240, container=$state)..."'
      script << '  sleep 5'
      script << 'done'
      script << "curl -sf http://localhost:#{port}/v1/models >/dev/null || { echo 'FATAL: vLLM did not become ready within 20 minutes'; exit 1; }"
      script << 'echo vllm-install-ok'
      script.join("\n")
    end

    def comfyui_install_script
      models_dir  = @config.comfyui_models_dir
      output_dir  = @config.comfyui_output_dir
      port        = @config.comfyui_port
      model_names = @config.comfyui_models
      # Use ubuntu home dir to avoid /opt permission issues when running as the SSH user.
      install_dir = '/home/ubuntu/ComfyUI'
      venv_dir    = '/home/ubuntu/comfyui-venv'
      service     = 'comfyui'

      script = []
      script << 'set -euo pipefail'

      # Wait for apt locks released by unattended-upgrades before touching packages.
      script << 'for i in $(seq 1 30); do'
      script << '  if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then break; fi'
      script << '  echo "  apt lock held, waiting ($i/30)..."; sleep 10'
      script << 'done'
      script << 'sudo pkill -f unattended-upgrade >/dev/null 2>&1 || true'

      # Install system deps: git, python venv, wget.
      script << 'sudo apt-get update -qq'
      script << 'sudo apt-get install -y -qq git python3-venv python3-pip wget'

      # Ephemeral NVMe dirs for models and output.
      script << "sudo mkdir -p #{Shellwords.escape(models_dir)} #{Shellwords.escape(output_dir)}"
      script << "sudo chmod -R 0777 #{Shellwords.escape(File.dirname(models_dir))}"

      # Clone or update ComfyUI from the official repo (no sudo needed in ubuntu home).
      script << "if [ ! -d #{Shellwords.escape(install_dir)} ]; then"
      script << "  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI #{Shellwords.escape(install_dir)}"
      script << 'else'
      script << "  git -C #{Shellwords.escape(install_dir)} pull --ff-only"
      script << 'fi'

      # Create Python venv and install PyTorch + ComfyUI deps.
      # CUDA 12.8 is installed on the VM; cu128 wheel index covers it.
      script << "[ -d #{Shellwords.escape(venv_dir)} ] || python3 -m venv #{Shellwords.escape(venv_dir)}"
      script << "#{venv_dir}/bin/pip install --quiet --upgrade pip"
      script << "#{venv_dir}/bin/pip install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128"
      script << "#{venv_dir}/bin/pip install --quiet -r #{Shellwords.escape("#{install_dir}/requirements.txt")}"

      # Symlink ephemeral model/output dirs into the ComfyUI directory tree.
      script << "rm -rf #{Shellwords.escape("#{install_dir}/models")} && ln -sfn #{Shellwords.escape(models_dir)} #{Shellwords.escape("#{install_dir}/models")}"
      script << "rm -rf #{Shellwords.escape("#{install_dir}/output")} && ln -sfn #{Shellwords.escape(output_dir)} #{Shellwords.escape("#{install_dir}/output")}"

      # Systemd service so ComfyUI starts on reboot.
      script << "cat <<'UNIT' | sudo tee /etc/systemd/system/#{Shellwords.escape(service)}.service >/dev/null"
      script << '[Unit]'
      script << 'Description=ComfyUI photo enhancement server'
      script << 'After=network.target'
      script << '[Service]'
      script << "ExecStart=#{venv_dir}/bin/python #{install_dir}/main.py --listen 0.0.0.0 --port #{port} --output-directory #{output_dir}"
      script << 'Restart=on-failure'
      script << 'RestartSec=5'
      script << "WorkingDirectory=#{install_dir}"
      script << 'Environment=HOME=/root'
      script << '[Install]'
      script << 'WantedBy=multi-user.target'
      script << 'UNIT'
      script << 'sudo systemctl daemon-reload'
      script << "sudo systemctl enable --now #{Shellwords.escape(service)}"
      script << "sudo systemctl restart #{Shellwords.escape(service)}"

      # Wait for ComfyUI API to respond (model loading and CUDA init can take ~60s).
      script << 'echo "Waiting for ComfyUI to become ready (up to 5 min)..."'
      script << 'for i in $(seq 1 60); do'
      script << "  if curl -sf http://localhost:#{port}/system_stats >/dev/null 2>&1; then echo comfyui-ready; break; fi"
      script << '  echo "  ComfyUI not ready yet ($i/60)..."; sleep 5'
      script << 'done'
      script << "curl -sf http://localhost:#{port}/system_stats >/dev/null || { echo 'FATAL: ComfyUI did not become ready within 5 minutes'; exit 1; }"

      # Install ComfyUI-SUPIR custom node (provides SUPIR_Upscale and related nodes).
      supir_node_dir = "#{install_dir}/custom_nodes/ComfyUI-SUPIR"
      script << "if [ ! -d #{Shellwords.escape(supir_node_dir)} ]; then"
      script << "  git clone --depth 1 https://github.com/kijai/ComfyUI-SUPIR #{Shellwords.escape(supir_node_dir)}"
      script << "  #{venv_dir}/bin/pip install --quiet -r #{Shellwords.escape("#{supir_node_dir}/requirements.txt")}"
      script << 'fi'

      # Download model weights into the ComfyUI subdirectories.
      # Real-ESRGAN → upscale_models/; SUPIR → checkpoints/; SDXL base → checkpoints/.
      model_names.each do |model_name|
        case model_name
        when /RealESRGAN/i
          dest_dir = "#{models_dir}/upscale_models"
          url = if model_name =~ /anime/i
                  'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth'
                else
                  'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth'
                end
          dest_file = "#{dest_dir}/#{model_name}.pth"
          script << "mkdir -p #{Shellwords.escape(dest_dir)}"
          script << "[ -f #{Shellwords.escape(dest_file)} ] || wget -q --show-progress -O #{Shellwords.escape(dest_file)} #{Shellwords.escape(url)}"
        when /SUPIR/i
          # SUPIR-v0Q (~5 GB): AI photo restoration backbone (denoising + detail recovery).
          # SDXL base (~7 GB): provides CLIP encoders that SUPIR uses for text conditioning.
          # Both must live in checkpoints/ so SUPIR_Upscale can find them by filename.
          dest_dir = "#{models_dir}/checkpoints"
          hf_file = model_name.end_with?('F') ? 'SUPIR-v0F.ckpt' : 'SUPIR-v0Q.ckpt'
          supir_url = "https://huggingface.co/camenduru/SUPIR/resolve/main/#{hf_file}"
          sdxl_url  = 'https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors'
          script << "mkdir -p #{Shellwords.escape(dest_dir)}"
          script << "[ -f #{Shellwords.escape("#{dest_dir}/#{hf_file}")} ] || wget -q --show-progress -O #{Shellwords.escape("#{dest_dir}/#{hf_file}")} #{Shellwords.escape(supir_url)}"
          script << "[ -f #{Shellwords.escape("#{dest_dir}/sd_xl_base_1.0.safetensors")} ] || wget -q --show-progress -O #{Shellwords.escape("#{dest_dir}/sd_xl_base_1.0.safetensors")} #{Shellwords.escape(sdxl_url)}"
        end
      end

      # Restart ComfyUI so it picks up the new custom nodes and model files.
      script << "sudo systemctl restart #{Shellwords.escape(service)}"
      script << 'echo "Waiting for ComfyUI restart..."'
      script << 'for i in $(seq 1 60); do'
      script << "  if curl -sf http://localhost:#{port}/system_stats >/dev/null 2>&1; then echo comfyui-ready; break; fi"
      script << '  echo "  ComfyUI not ready yet ($i/60)..."; sleep 5'
      script << 'done'

      script << 'echo comfyui-install-ok'
      script.join("\n")
    end

    def litellm_decommission_script
      script = []
      script << 'set -euo pipefail'
      script << 'sudo systemctl stop litellm 2>/dev/null || true'
      script << 'sudo systemctl disable litellm 2>/dev/null || true'
      script << 'sudo rm -f /etc/systemd/system/litellm.service'
      script << 'sudo systemctl daemon-reload'
      script << 'sudo rm -f /ephemeral/litellm-config.yaml'
      script << 'sudo rm -rf /ephemeral/litellm-env'
      script << 'sudo rm -f /ephemeral/litellm.log'
      script << "sudo ufw --force delete allow from #{Shellwords.escape(@config.wireguard_subnet)} to any port 4000 proto tcp >/dev/null 2>&1 || true"
      script << 'echo litellm-decommission-ok'
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
        stdout, stderr, status = @ssh_command_runner.call(host, @scripts.guest_bootstrap_script)
        return if status.success?

        msg = stderr.strip.empty? ? stdout : stderr
        raise Error, "Guest bootstrap failed after #{retries} attempts: #{msg}" if attempt == retries - 1

        warn "Bootstrap attempt #{attempt + 1}/#{retries} failed (#{msg.lines.last&.strip}), retrying in 15s..."
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

    def decommission_litellm(host)
      info "Removing deprecated LiteLLM service from #{host} if present..."
      output, status = @ssh_stream_runner.call(host, @scripts.litellm_decommission_script)
      raise Error, "LiteLLM decommission failed: #{output.strip}" unless status.success?
    end

    def setup_vllm_stack(host, preset_config: nil)
      install_vllm(host, preset_config: preset_config)
    end

    def install_comfyui(host)
      info "Setting up ComfyUI Docker container on #{host}..."
      output, status = @ssh_stream_runner.call(host, @scripts.comfyui_install_script)
      raise Error, "ComfyUI install failed: #{output.strip}" unless status.success?
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

    def create(replace: false, dry_run: false, install_vllm: nil, install_ollama: nil, install_comfyui: nil,
               vllm_preset: nil)
      # CLI flags override config; nil means "use config default".
      @effective_vllm = install_vllm.nil? ? @config.vllm_install_enabled? : install_vllm
      @effective_ollama = install_ollama.nil? ? @config.ollama_install_enabled? : install_ollama
      @effective_comfyui = install_comfyui.nil? ? @config.comfyui_install_enabled? : install_comfyui
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
    rescue Error
      raise if preserve_state_on_failure

      @state_store.delete
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
          comfyui_enabled = state_comfyui_enabled?(state)

          info "Tracked VM: #{state['vm_id']} #{vm['name']}"
          info "Status: #{vm['status']} / #{vm['vm_state']}"
          info "Public IP: #{connect_host_for(vm) || 'none'}"
          info "Service mode: #{service_mode_summary(vllm_enabled: vllm_enabled, ollama_enabled: ollama_enabled,
                                                     comfyui_enabled: comfyui_enabled)}"
          info "Active model: #{state['vllm_model'] || @config.vllm_model}" if vllm_enabled
          if comfyui_enabled
            wg_ip = @config.wireguard_gateway_hostname
            info "ComfyUI: http://#{wg_ip}:#{@config.comfyui_port}"
          end
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
        comfyui_setup_needed?(state) ||
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

      # Set up ComfyUI after the tunnel is up so model downloads are visible locally.
      if comfyui_setup_needed?(state)
        @provisioner.install_comfyui(state['public_ip'])
        state['comfyui_setup_at']       = Time.now.utc.iso8601
        state['comfyui_container_name'] = @config.comfyui_container_name
        state['comfyui_models']         = @config.comfyui_models
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
      wg_ip = @config.wireguard_gateway_hostname
      if effective_vllm?
        info "Run 'ruby hyperstack.rb test' to verify vLLM."
        info "  vLLM:    http://#{wg_ip}:#{@config.ollama_port}/v1/models"
      end
      return unless effective_comfyui?

      info "Run 'ruby hyperstack.rb test' to verify ComfyUI."
      info "  ComfyUI: http://#{wg_ip}:#{@config.comfyui_port}/system_stats"
      info "  Enhance: ruby photo-enhance.rb --config #{File.basename(@config.path)} --indir ~/Pictures --outdir ~/Pictures/enhanced"
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
      loop do
        result = yield
        return result if result

        raise Error, "Timed out waiting for #{description}." if Time.now >= deadline

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
        'ollama_enabled' => effective_ollama?,
        'comfyui_enabled' => effective_comfyui?
      }
    end

    def desired_security_rules(include_vllm: effective_vllm?, include_ollama: effective_ollama?,
                               include_comfyui: effective_comfyui?)
      @config.desired_security_rules(include_vllm: include_vllm, include_ollama: include_ollama,
                                     include_comfyui: include_comfyui)
    end

    def desired_security_rules_for_state(state)
      desired_security_rules(include_vllm: state_vllm_enabled?(state),
                             include_ollama: state_ollama_enabled?(state),
                             include_comfyui: state_comfyui_enabled?(state))
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

    def state_comfyui_enabled?(state)
      recorded = state&.dig('services', 'comfyui_enabled')
      return recorded unless recorded.nil?

      return true if state&.key?('comfyui_setup_at')

      @config.comfyui_install_enabled?
    end

    def service_mode_summary(vllm_enabled:, ollama_enabled:, comfyui_enabled: false)
      parts = []
      parts << 'vLLM' if vllm_enabled
      parts << 'Ollama' if ollama_enabled
      parts << 'ComfyUI' if comfyui_enabled
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

    # Returns the effective ComfyUI flag: CLI override if set, else config default.
    def effective_comfyui?
      defined?(@effective_comfyui) ? @effective_comfyui : @config.comfyui_install_enabled?
    end

    def comfyui_setup_needed?(state)
      return false unless effective_comfyui?
      return true if state['comfyui_setup_at'].nil?

      # Re-run if the desired model list changed since last provision.
      (@config.comfyui_models.sort != Array(state['comfyui_models']).sort)
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
        # 500 tokens: reasoning models (e.g. gpt-oss) use tokens for chain-of-thought
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
    # service_type is :vllm or :comfyui — controls which metrics section is rendered.
    VmSnapshot = Struct.new(
      :label, :wg_host, :service_type,
      :vllm_model, :container_name,
      :metrics, :gpus,
      :vllm_error, :gpu_error,
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

    # Fetches GPU stats and service stats for a single VM via one SSH session.
    # Routes to fetch_comfyui_vm or fetch_vllm_vm based on config.
    def fetch_vm(loader)
      config  = loader.config
      label   = File.basename(loader.path, '.toml')
      wg_host = config.wireguard_gateway_hostname
      state   = load_state(config.state_file)

      unless state
        svc = config.comfyui_install_enabled? ? :comfyui : :vllm
        return VmSnapshot.new(label: label, wg_host: wg_host, service_type: svc,
                              vllm_model: nil, container_name: nil,
                              metrics: nil, gpus: nil,
                              vllm_error: 'no state file', gpu_error: nil,
                              fetched_at: Time.now)
      end

      if config.comfyui_install_enabled?
        fetch_comfyui_vm(config, label, wg_host)
      else
        fetch_vllm_vm(config, label, wg_host, state)
      end
    rescue StandardError => e
      VmSnapshot.new(label: label || '?', wg_host: wg_host || '?', service_type: :vllm,
                     vllm_model: nil, container_name: nil,
                     metrics: nil, gpus: nil,
                     vllm_error: e.message, gpu_error: nil,
                     fetched_at: Time.now)
    end

    # Fetches GPU + vLLM container stats for a vLLM VM.
    def fetch_vllm_vm(config, label, wg_host, state)
      vllm_model     = state['vllm_model'] || config.vllm_model
      container_name = state['vllm_container_name'] || config.vllm_container_name

      gpus, metrics, ssh_error = fetch_vm_stats(config, wg_host, container_name)

      VmSnapshot.new(label: label, wg_host: wg_host, service_type: :vllm,
                     vllm_model: vllm_model, container_name: container_name,
                     metrics: metrics, gpus: gpus,
                     vllm_error: ssh_error, gpu_error: ssh_error,
                     fetched_at: Time.now)
    end

    # Fetches GPU + ComfyUI queue stats for a ComfyUI VM.
    # Returns queue running/pending counts and total outputs produced so far.
    def fetch_comfyui_vm(config, label, wg_host)
      gpus, metrics, ssh_error = fetch_comfyui_stats(config, wg_host, config.comfyui_port)

      VmSnapshot.new(label: label, wg_host: wg_host, service_type: :comfyui,
                     vllm_model: nil, container_name: nil,
                     metrics: metrics, gpus: gpus,
                     vllm_error: ssh_error, gpu_error: ssh_error,
                     fetched_at: Time.now)
    end

    def load_state(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    # Single SSH call: nvidia-smi + ComfyUI queue + output file count.
    # Sections separated by sentinel lines so we can split the output cleanly.
    # Returns [gpus, metrics_hash, error_or_nil].
    def fetch_comfyui_stats(config, wg_host, port)
      gpu_query = 'index,name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total'
      script    = <<~BASH
        nvidia-smi --query-gpu=#{gpu_query} --format=csv,noheader,nounits
        echo ===COMFYUI===
        curl -s http://localhost:#{port}/queue 2>/dev/null
        echo
        echo ===HISTORY===
        curl -s http://localhost:#{port}/history 2>/dev/null | python3 -c \
          "import json,sys; h=json.load(sys.stdin); print(len(h))" 2>/dev/null || echo 0
      BASH

      ssh = build_ssh_command(config, wg_host)
      stdout, stderr, status = Timeout.timeout(15) { Open3.capture3(*ssh, stdin_data: script) }
      return [nil, nil, "exit #{status.exitstatus}: #{stderr.strip}"] unless status.success?

      gpu_section, rest = stdout.split("===COMFYUI===\n", 2)
      queue_section, hist_section = rest.to_s.split("===HISTORY===\n", 2)
      gpus    = parse_nvidia_smi(gpu_section.to_s)
      metrics = parse_comfyui_queue(queue_section.to_s.strip, hist_section.to_s.strip)
      [gpus, metrics, nil]
    end

    # Parse ComfyUI /queue JSON into a plain Hash.
    def parse_comfyui_queue(queue_json, history_count_str)
      q = begin
        JSON.parse(queue_json)
      rescue StandardError
        {}
      end
      {
        'queue_running' => Array(q['queue_running']).size,
        'queue_pending' => Array(q['queue_pending']).size,
        'history_count' => history_count_str.to_i
      }
    end

    # Single SSH call that runs nvidia-smi and tails the vLLM container logs.
    # The two sections are separated by a sentinel line so we can split them.
    # Returns [gpus, metrics, error_or_nil].
    def fetch_vm_stats(config, wg_host, container_name)
      gpu_query = 'index,name,temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total'
      # --tail 200 instead of --since N so we always get the last stats line
      # even when the VM has been idle for longer than the refresh interval.
      script    = <<~BASH
        nvidia-smi --query-gpu=#{gpu_query} --format=csv,noheader,nounits
        echo ===VLLM===
        docker logs --tail 200 #{container_name} 2>&1 | grep 'Engine 0' | tail -1
      BASH

      ssh = build_ssh_command(config, wg_host)
      stdout, stderr, status = Timeout.timeout(15) { Open3.capture3(*ssh, stdin_data: script) }
      return [nil, nil, "exit #{status.exitstatus}: #{stderr.strip}"] unless status.success?

      gpu_section, vllm_section = stdout.split("===VLLM===\n", 2)
      gpus    = parse_nvidia_smi(gpu_section.to_s)
      metrics = parse_engine_log_line(vllm_section.to_s.strip)
      [gpus, metrics, nil]
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
    # Routes the service-specific metrics section based on service_type.
    def render_vm(snap)
      lines = []

      svc_label = snap.service_type == :comfyui ? "#{DIM}ComfyUI#{RESET}" : ''
      model_label = snap.vllm_model ? DIM + snap.vllm_model.split('/').last + RESET : svc_label
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
        if snap.service_type == :comfyui
          lines.concat(render_comfyui_metrics(snap.metrics))
        elsif snap.metrics&.any?
          lines.concat(render_vllm_metrics(snap.metrics))
        elsif snap.metrics && snap.metrics.empty?
          lines << "  #{DIM}(no Engine log line yet — container may still be loading)#{RESET}"
        end
      end

      lines
    end

    # Formats ComfyUI queue stats into display lines.
    def render_comfyui_metrics(m)
      return ["  #{DIM}(no ComfyUI stats)#{RESET}"] unless m&.any?

      running = m['queue_running'].to_i
      pending = m['queue_pending'].to_i
      history = m['history_count'].to_i

      q_str = running > 0 ? "#{GREEN}#{running} running#{RESET}" : "#{DIM}idle#{RESET}"
      q_str += "  #{pending} queued" if pending > 0
      [
        row('queue', q_str),
        row('completed', "#{history} jobs total")
      ]
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

  class CLI
    def initialize(argv)
      @argv = argv.dup
      @config_path = File.join(__dir__, 'hyperstack-vm.toml')
      @config_explicit = false
    end

    def show_help
      puts @global_parser
      puts
      puts 'Commands:'
      puts '  create [--replace] [--dry-run] [--vllm|--no-vllm] [--ollama|--no-ollama] [--model PRESET]'
      puts '  create-both [--replace] [--dry-run] [--vllm|--no-vllm] [--ollama|--no-ollama]'
      puts '               Provision hyperstack-vm1-gptoss.toml and hyperstack-vm2.toml concurrently.'
      puts '               WireGuard setup is serialized: VM1 writes the base wg1.conf first,'
      puts '               then VM2 adds its peer. Requires both TOML files next to the script.'
      puts '  delete [--vm-id ID] [--dry-run]'
      puts '  delete-both [--dry-run]'
      puts '               Delete the VMs tracked by hyperstack-vm1-gptoss.toml and hyperstack-vm2.toml.'
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

    # Starts the VllmWatcher dashboard for all active VMs.
    # Reuses status_config_loaders so it auto-discovers the same set of VMs
    # that `status` would show (honours --config if given explicitly).
    def run_watch
      loaders = status_config_loaders
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

    def status_config_loaders
      return [ConfigLoader.load(@config_path)] if @config_explicit

      candidates = [
        @config_path,
        File.join(__dir__, 'hyperstack-vm1-gptoss.toml'),
        File.join(__dir__, 'hyperstack-vm2.toml'),
        File.join(__dir__, 'hyperstack-vm-photo.toml')
      ].uniq.select { |path| File.exist?(path) }

      loaders = candidates.map { |path| ConfigLoader.load(path) }
      tracked = loaders.select { |loader| File.exist?(loader.config.state_file) }
      tracked.empty? ? [ConfigLoader.load(@config_path)] : tracked
    end

    def pair_config_loaders
      [
        ConfigLoader.load(File.join(__dir__, 'hyperstack-vm1-gptoss.toml')),
        ConfigLoader.load(File.join(__dir__, 'hyperstack-vm2.toml'))
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

begin
  HyperstackVM::CLI.new(ARGV).run
rescue HyperstackVM::Error => e
  warn "ERROR: #{e.message}"
  exit 1
end
