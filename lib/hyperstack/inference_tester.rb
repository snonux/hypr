# frozen_string_literal: true

require 'json'
require 'net/http'

module HyperstackVM
  # End-to-end inference tests over WireGuard.
  class InferenceTester
    def initialize(config:, out:)
      @config = config
      @out = out
    end

    def test(state)
      wg_ip = @config.wireguard_gateway_hostname
      vllm_enabled = state_vllm_enabled?(state)
      ollama_enabled = state_ollama_enabled?(state)
      info "Running end-to-end inference tests via WireGuard (#{wg_ip})..."
      test_vllm(wg_ip) if vllm_enabled
      info "  Ollama test: connect via SSH and run 'ollama list' to verify models." if ollama_enabled
      info 'All inference tests passed.'
    end

    private

    def test_vllm(wg_ip)
      port = @config.ollama_port
      info "  Testing vLLM models list at http://#{wg_ip}:#{port}/v1/models..."
      uri  = URI("http://#{wg_ip}:#{port}/v1/models")
      resp = Net::HTTP.get_response(uri)
      raise Error, "vLLM /v1/models returned HTTP #{resp.code}" unless resp.code == '200'

      models = JSON.parse(resp.body).fetch('data', []).map { |m| m['id'] }
      raise Error, 'vLLM returned an empty model list' if models.empty?

      model = models.first
      info "    Models loaded: #{models.join(', ')}"
      info '  Testing vLLM inference...'
      reply = chat(wg_ip, port, model, 'Say hello in five words.')
      info "    vLLM response: #{reply}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      raise Error, "Cannot reach vLLM at #{wg_ip}:#{port} — is WireGuard (wg1) active? (#{e.message})"
    end

    def chat(host, port, model, prompt)
      uri = URI("http://#{host}:#{port}/v1/chat/completions")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = 'Bearer EMPTY'
      req.body = JSON.generate(
        'model' => model,
        'messages' => [{ 'role' => 'user', 'content' => prompt }],
        'max_tokens' => 500
      )

      retries = 3
      retries.times do |attempt|
        begin
          resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 120) { |h| h.request(req) }
          raise Error, "vLLM inference returned HTTP #{resp.code}" unless resp.code == '200'

          return JSON.parse(resp.body).dig('choices', 0, 'message', 'content').to_s.strip
        rescue Error, Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNREFUSED,
               Errno::EHOSTUNREACH, SocketError, JSON::ParserError => e
          raise Error, "vLLM inference failed after #{retries} attempts: #{e.message}" if attempt == retries - 1

          delay = (attempt + 1) * 15
          info "  vLLM inference attempt #{attempt + 1}/#{retries} failed (#{e.message}), retrying in #{delay}s..."
          sleep delay
        end
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

    def info(message)
      @out.puts(message)
    end
  end
end
