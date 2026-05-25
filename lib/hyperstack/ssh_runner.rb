# frozen_string_literal: true

require 'open3'
require 'socket'

module HyperstackVM
  # Executes commands over SSH and manages host-key trust.
  class SshRunner
    def initialize(config:, out:)
      @config = config
      @out = out
    end

    def run(host, remote_script)
      Open3.capture3(*command(host), stdin_data: remote_script)
    end

    def run_streaming(host, remote_script)
      combined = +''
      Open3.popen2e(*command(host)) do |stdin, output, wait_thr|
        stdin.write(remote_script)
        stdin.close
        output.each do |line|
          combined << line
          @out.print(line)
        end
        return [combined, wait_thr.value]
      end
    end

    def tcp_open?(host, port)
      Socket.tcp(host, port, connect_timeout: @config.ssh_connect_timeout) do |sock|
        sock.close
        true
      end
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
           Errno::ENETUNREACH, SocketError, IOError
      false
    end

    def command(host)
      cmd = [
        'ssh',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', "UserKnownHostsFile=#{@config.ssh_known_hosts_path}",
        '-o', "ConnectTimeout=#{@config.ssh_connect_timeout}",
        '-p', @config.ssh_port.to_s
      ]
      if File.exist?(@config.ssh_private_key_path)
        cmd.concat(['-i', @config.ssh_private_key_path])
      else
        warn_out("SSH private key #{@config.ssh_private_key_path} does not exist; falling back to default ssh-agent identity.")
      end
      cmd << "#{@config.ssh_username}@#{host}"
      cmd << 'bash -se'
      cmd
    end

    # Trust / known-hosts management

    def ensure_trusted_host(host)
      scanned = scan_host_keys(host)
      return false if scanned.empty?

      existing = known_host_entries
      if existing.empty?
        write_known_host_entries(scanned)
        puts "Pinned SSH host key for #{host} in #{@config.ssh_known_hosts_path}."
        return true
      end

      return true if existing == scanned

      warn_out("SSH host key mismatch for #{host}. Replacing cached key (VM was likely recreated).")
      write_known_host_entries(scanned)
      true
    end

    def scan_host_keys(host)
      stdout, stderr, status = Open3.capture3(
        'ssh-keyscan', '-T', @config.ssh_connect_timeout.to_s,
        '-p', @config.ssh_port.to_s, host
      )
      unless status.success?
        warn_out("ssh-keyscan not ready yet: #{stderr.strip}") unless stderr.to_s.strip.empty?
        return []
      end
      stdout.lines.map(&:strip).reject { |l| l.empty? || l.start_with?('#') }.sort.uniq
    rescue Errno::ENOENT
      raise Error, 'ssh-keyscan is required to pin SSH host keys but was not found in PATH.'
    end

    def delete_known_hosts_file
      File.delete(@config.ssh_known_hosts_path) if File.exist?(@config.ssh_known_hosts_path)
    rescue Errno::EACCES => e
      raise Error, "Cannot delete SSH known_hosts file #{@config.ssh_known_hosts_path}: #{e.message}"
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
      temp = "#{path}.tmp"
      File.write(temp, "#{entries.join("\n")}\n")
      File.chmod(0o600, temp)
      File.rename(temp, path)
    rescue Errno::EACCES => e
      raise Error, "Cannot write SSH known_hosts file #{path}: #{e.message}"
    end

    private

    def warn_out(msg)
      @out.puts("WARN: #{msg}")
    end
  end
end
