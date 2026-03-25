# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'socket'
require 'timeout'

module HyperstackVM
  # HTTP client for the Hyperstack (NexGenCloud) REST API.
  # Handles authentication, JSON encoding/decoding, and retry logic with exponential back-off.
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
end
