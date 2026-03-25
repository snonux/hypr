# frozen_string_literal: true

require 'open3'

module HyperstackVM
  # Manages the local WireGuard interface config and /etc/hosts entries.
  # Reads and writes the wg1.conf peer blocks and restarts the service when needed.
  # Uses sudo for privileged file operations when direct write access is unavailable.
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
end
