# typed: strict
# frozen_string_literal: true

# Brew's spec teardown deletes `trust.json` from the user config home, so only
# run inside `spec/run.rb`'s sandboxed environment.
raise "Run the specs with `brew ruby -- spec/run.rb`." unless ENV["HOMEBREW_TESTS"]

require "simplecov"
require "sorbet-runtime"
tap_root = File.expand_path("..", __dir__)
SimpleCov.start do
  T.bind(self, SimpleCov::Configuration)
  root tap_root
  enable_coverage :branch
  primary_coverage :line
  cover "{cmd,lib}/**/*.rb"
end

# Brew's own harness: prefix, cache and logs in a temporary directory, `ENV`
# restored and output silenced around each example, `rspec-sorbet` doubles.
require File.join(ENV.fetch("HOMEBREW_LIBRARY"), "Homebrew/test/spec_helper")

require "ipaddr"

# Keeps the specs off the network. Brew's harness stops `Utils::Curl`'s own
# `curl_executable`, but not the copy download strategies include, nor Ruby
# connections (`TCPSocket.open`, as `Net::HTTP` uses, `TCPSocket.new` and
# `Socket.tcp`). Only loopback and local files are allowed, and GitHub for an
# example tagged `:needs_github`. A request from a thread that outlives its
# example fails the example running then.
module NetworkGuard
  # An `Exception`, so no `rescue` of a `StandardError` in brew hides it.
  class Blocked < Exception; end # rubocop:disable Lint/InheritException

  GITHUB_HOST = /\A(?:github\.com|api\.github\.com|ghcr\.io|(?:[a-z0-9-]+\.)+githubusercontent\.com)\z/i

  sig { params(host: T.nilable(String), github: T::Boolean).returns(T::Boolean) }
  def self.allowed?(host, github:)
    return true if host.blank? || host == "localhost"
    return true if github && host.match?(GITHUB_HOST)

    IPAddr.new(host).loopback?
  rescue IPAddr::Error
    false
  end

  # The URLs among `curl`'s `args` on hosts it may not reach; a URL that
  # can't be parsed counts, as does an empty host other than a file's, which
  # curl reads from the path (`https:///host/`).
  sig { params(args: T::Array[T.any(String, Integer, Float, Pathname)], github: T::Boolean).returns(T::Array[String]) }
  def self.remote_urls(args, github:)
    args.map(&:to_s).grep(%r{\A[a-z][a-z0-9+.-]*://}i).reject do |url|
      uri = URI.parse(url)
      uri.scheme&.casecmp?("file") || (uri.hostname.present? && allowed?(uri.hostname, github:))
    rescue URI::InvalidURIError
      false
    end
  end

  # Fails a request to `target` and keeps it in `requests`.
  sig { params(requests: T::Array[Blocked], target: String).returns(T.noreturn) }
  def self.stop(requests, target)
    error = Blocked.new(<<~EOS)
      The specs never reach the network, but this example asked for #{target}.
      Stub the brew call in the backtrace that makes the request, as near to it
      as the spec allows (e.g. `Bottle#fetch_tab` for a bottle manifest).
    EOS
    error.set_backtrace(caller.reject { |line| line.start_with?(__FILE__) })
    requests << error
    raise error
  end

  # Sets the guard up for every example `config` runs.
  sig { params(config: RSpec::Core::Configuration).void }
  def self.install(config)
    # Brew's harness stops `Utils::Curl.curl_executable` unless this is set;
    # the guard below then still allows only GitHub.
    config.define_derived_metadata(:needs_github) { |metadata| metadata[:needs_utils_curl] = true }

    # A request fails at once, and is kept to fail the example after it runs,
    # if brew rescued it or made it on another thread (e.g. a download queue).
    config.before do |example|
      T.bind(self, RSpec::Mocks::ExampleMethods)
      requests = example.metadata[:network_requests] = []
      github = example.metadata.key?(:needs_github)
      allow(SystemCommand).to receive(:run).and_wrap_original do |run, executable, **options|
        if File.basename(executable.to_s) == "curl"
          NetworkGuard.remote_urls(options.fetch(:args, []), github:).each { |url| NetworkGuard.stop(requests, url) }
        end
        run.call(executable, **options)
      end
      # Else `TCPServer.new` and `TCPServer.open` would reach the stubs of
      # `TCPSocket.new` and `TCPSocket.open` below, which they inherit, and
      # connect instead of listening.
      [:new, :open].each { |method| allow(TCPServer).to receive(method).and_call_original }
      [[TCPSocket, :open], [TCPSocket, :new], [Socket, :tcp]].each do |klass, method|
        allow(klass).to receive(method).and_wrap_original do |connect, host, port, *args, **options, &block|
          NetworkGuard.stop(requests, "#{host}:#{port}") unless NetworkGuard.allowed?(host.to_s, github:)
          connect.call(host, port, *args, **options, &block)
        end
      end
    end

    config.after do |example|
      failure = example.exception
      failures = failure.respond_to?(:all_exceptions) ? failure.all_exceptions : [failure]
      # None when an earlier hook failed before the guard was set up.
      hidden = example.metadata.fetch(:network_requests, []).reject { |error| failures.include?(error) }
      raise hidden.fetch(0) if hidden.any?
    end
  end
end

RSpec.configure do |config|
  # Brew retries for its network specs; ours are offline, so a retry would
  # only hide a flaky spec.
  config.default_retry_count = 0

  NetworkGuard.install(config)
end
