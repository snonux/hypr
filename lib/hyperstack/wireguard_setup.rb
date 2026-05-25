# frozen_string_literal: true

require 'ipaddr'
require 'open3'

module HyperstackVM
  # Validates and runs the local WireGuard setup script for a VM.
  class WireGuardSetup
    def initialize(config:, ssh_runner:, local_wireguard:, out:, wg_setup_pre: nil, wg_setup_post: nil)
      @config = config
      @ssh_runner = ssh_runner
      @local_wireguard = local_wireguard
      @out = out
      @wg_setup_pre  = wg_setup_pre
      @wg_setup_post = wg_setup_post
    end

    def run(state)
      @wg_setup_pre&.call
      if setup_needed?(state)
        execute(state['public_ip'])
        state['wireguard_setup_at'] = Time.now.utc.iso8601
      end
      @wg_setup_post&.call
    end

    def setup_needed?(state)
      return false unless @config.wireguard_auto_setup?
      public_ip = state['public_ip'].to_s.strip
      return true if public_ip.empty?
      expected = "#{public_ip}:#{@config.wireguard_udp_port}"
      !endpoints.include?(expected)
    end

    private

    def endpoints
      Array(@local_wireguard.status['endpoints']).compact.uniq
    end

    def execute(host)
      validate_script!
      retries = 3
      retries.times do |attempt|
        info "Running WireGuard auto-setup via #{@config.wireguard_setup_script} #{host}..."
        status = run_script(host)
        return if status.success?
        if attempt == retries - 1
          raise Error, "WireGuard setup failed after #{retries} attempts (exit #{status.exitstatus})."
        end
        delay = (attempt + 1) * 15
        warn_out "WireGuard setup attempt #{attempt + 1}/#{retries} failed (exit #{status.exitstatus}), retrying in #{delay}s..."
        sleep delay
      end
    end

    def run_script(host)
      env = {
        'HYPERSTACK_SSH_PORT' => @config.ssh_port.to_s,
        'HYPERSTACK_SSH_CONNECT_TIMEOUT' => @config.ssh_connect_timeout.to_s,
        'HYPERSTACK_SSH_KNOWN_HOSTS_PATH' => @config.ssh_known_hosts_path,
        'HYPERSTACK_SSH_PRIVATE_KEY_PATH' => (File.exist?(@config.ssh_private_key_path) ? @config.ssh_private_key_path : '')
      }
      Open3.popen2e(env, 'bash', @config.wireguard_setup_script, host,
                    @config.wireguard_gateway_ip,
                    @config.wireguard_gateway_hostname) do |stdin, output, wait_thr|
        stdin.sync = true
        stdin.puts
        stdin.close
        output.each { |line| @out.print(line) }
        wait_thr.value
      end
    end

    def validate_script!
      script_path = @config.wireguard_setup_script
      raise Error, "WireGuard setup script not found: #{script_path}" unless File.exist?(script_path)

      mismatches = []
      mismatches << "ssh.username must be 'ubuntu'" unless @config.ssh_username == 'ubuntu'
      mismatches << "local_client.interface_name must be 'wg1'" unless @config.local_interface_name == 'wg1'
      mismatches << 'network.wireguard_udp_port must be 56710' unless @config.wireguard_udp_port == 56_710
      unless @config.wireguard_subnet == '192.168.3.0/24'
        mismatches << "network.wireguard_subnet must be '192.168.3.0/24'"
      end

      begin
        subnet = IPAddr.new(@config.wireguard_subnet)
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

    def info(msg)
      @out.puts(msg)
    end

    def warn_out(msg)
      @out.puts("WARN: #{msg}")
    end
  end
end
