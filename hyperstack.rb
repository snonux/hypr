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
end

require_relative 'lib/hyperstack/config'
require_relative 'lib/hyperstack/state'
require_relative 'lib/hyperstack/client'
require_relative 'lib/hyperstack/wireguard'
require_relative 'lib/hyperstack/provisioning'
require_relative 'lib/hyperstack/manager'
require_relative 'lib/hyperstack/watcher'
require_relative 'lib/hyperstack/cli'

begin
  HyperstackVM::CLI.new(ARGV).run
rescue HyperstackVM::Error => e
  warn "ERROR: #{e.message}"
  exit 1
end
