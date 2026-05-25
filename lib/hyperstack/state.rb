# frozen_string_literal: true

require 'json'

module HyperstackVM
  # Persists VM state to a JSON file with atomic writes (write-to-tmp + rename).
  # Used to track provisioned VM ID, IP, WireGuard keys, and related metadata.
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

    def flush
      return if @buffer.empty?

      @mutex.synchronize { @delegate.print("#{@prefix}#{@buffer}") }
      @buffer = +''
    end
  end
end
