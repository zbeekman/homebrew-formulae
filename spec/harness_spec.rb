# typed: true
# frozen_string_literal: true

require "net/http"
require "rspec/core/sandbox"

module HarnessSpec
  class SigProbe
    sig { params(number: Integer).returns(Integer) }
    def double(number) = number * 2
  end
end

RSpec.describe "the spec harness", type: :system do
  it "loads Homebrew with its prefix in a temporary directory" do
    expect(HOMEBREW_PREFIX.to_s).to start_with(TEST_TMPDIR)
  end

  it "runs with a throwaway home directory" do
    expect(File.basename(Dir.home)).to start_with("homebrew-tap-specs-")
  end

  it "runs without the proxy variables of the shell, which curl would send even a `localhost` request to" do
    expect(ENV.keys.grep(/\A(?:http|https|ftp|all)_proxy\z/i)).to be_empty
  end

  it "checks Sorbet signatures at runtime" do
    not_a_number = T.let("1", T.untyped) # hides the mistake from the static check
    expect { HarnessSpec::SigProbe.new.double(not_a_number) }.to raise_error(TypeError)
  end

  describe "network guard" do
    # RSpec helper methods typecheck better as regular methods.
    # rubocop:disable Sorbet/BlockMethodDefinition

    # A `curl` that succeeds without connecting, so only the guard stops it.
    def fake_curl
      curl = mktmpdir/"curl"
      curl.write("#!/bin/sh\n")
      curl.chmod(0755)
      curl
    end

    def curl(*operands) = SystemCommand.run(fake_curl, args: ["--head", *operands])

    # The requests the guard stopped in this example, which fail it after it
    # runs unless cleared.
    def network_requests = RSpec.current_example.metadata.fetch(:network_requests)

    # rubocop:enable Sorbet/BlockMethodDefinition

    it "stops curl reaching a host at once, naming the URL, even one it can't parse" do
      urls = %w[https://ghcr.io/v2/homebrew/core/lib/manifests/2.0 http://192.0.2.1/ http://[2001:db8::1]/
                https://bad|host/ https:///ghcr.io/v2/]
      stopped = urls.to_h do |url|
        curl(url)
        [url, false]
      rescue NetworkGuard::Blocked => e
        [url, e.message.include?(url)]
      end
      network_requests.clear
      expect(stopped).to eq(urls.to_h { |url| [url, true] })
    end

    it "stops curl reaching a host given without a scheme or by `--url`, as curl reads them" do
      commands = [%w[example.com], %w[example.com:8080/path], %w[--url example.com], %w[-oout.txt example.com],
                  %w[--max-time 10 -o out.txt example.com], %w[-fsSLo out.txt example.com], %w[-- example.com],
                  %w[192.0.2.1], %w[user@example.com], %w[ghcr.io/v2/], %w[-x proxy.example.com localhost],
                  %w[-xproxy.example.com localhost],
                  %w[--socks5 proxy.example.com:1080 localhost]]
      stopped = commands.to_h do |command|
        curl(*command)
        [command.join(" "), false]
      rescue NetworkGuard::Blocked
        [command.join(" "), true]
      end
      network_requests.clear
      expect(stopped).to eq(commands.to_h { |command| [command.join(" "), true] })
    end

    it "lets curl read the options and values brew passes, and reach loopback without a scheme" do
      commands = [["--max-time", "10", "--user-agent", "Homebrew/5.1", "--header", "Accept: text/html", "-o",
                   "out.part", "localhost"],
                  ["--retry", "3", "--output", "out.txt", "--write-out", "%<code>s", "127.0.0.1:8080/x"],
                  %w[-fsSL [::1]:80],
                  %w[--url localhost --connect-timeout 5], %w[-o out.txt -- file:///dev/null], %w[--head],
                  %w[--referer https://example.org/ file:///dev/null]]
      allowed = commands.to_h { |command| [command.join(" "), curl(*command).success?] }
      expect(allowed).to eq(commands.to_h { |command| [command.join(" "), true] })
    end

    it "lets curl read local files and reach loopback servers" do
      urls = %w[file:///dev/null http://127.0.0.1:1/ http://[::1]:1/ http://localhost:1/]
      expect(urls.to_h { |url| [url, curl(url).success?] }).to eq(urls.to_h { |url| [url, true] })
    end

    it "stops a Ruby connection to a host other than loopback at once, naming it" do
      connects = { "TCPSocket.open" => -> { Net::HTTP.start("192.0.2.1", 443, open_timeout: 1) { nil } },
                   "TCPSocket.new"  => -> { TCPSocket.new("192.0.2.1", 443, connect_timeout: 1) },
                   "Socket.tcp"     => -> { Socket.tcp("192.0.2.1", 443, connect_timeout: 1) } }
      stopped = connects.transform_values do |connect|
        connect.call
        false
      rescue NetworkGuard::Blocked => e
        e.message.include?("192.0.2.1:443")
      rescue SystemCallError, IO::TimeoutError, Net::OpenTimeout
        false
      end
      network_requests.clear
      expect(stopped).to eq(connects.transform_values { true })
    end

    it "lets Ruby listen on loopback and connect to it" do
      server = TCPServer.new("127.0.0.1", 0)
      opened = TCPServer.open("127.0.0.1", 0)
      port = server.addr[1]
      sockets = [TCPSocket.open("127.0.0.1", port), TCPSocket.new("localhost", port), Socket.tcp("127.0.0.1", port)]
      expect([server, opened, *sockets].map(&:class)).to eq([TCPServer, TCPServer, TCPSocket, TCPSocket, Socket])
    ensure
      [server, opened, *sockets].compact.each(&:close)
    end

    it "fails an example after it runs, once, for a request brew rescued or made on another thread" do
      url = "https://brew.sh/"
      curl = fake_curl
      results = RSpec::Core::Sandbox.sandboxed do |config|
        # A hook that runs before the guard's and fails.
        config.before { |example| raise "not set up" if example.metadata[:broken] }
        NetworkGuard.install(config)
        # Examples whose outcome, not expectations, is under test.
        # rubocop:disable RSpec/NoExpectationExample
        group = RSpec::Core::ExampleGroup.describe("an example") do
          T.bind(self, T.class_of(RSpec::Core::ExampleGroup))
          it "rescued" do
            SystemCommand.run(curl, args: [url])
          rescue NetworkGuard::Blocked
            nil
          end

          it "on another thread" do
            Thread.new do
              SystemCommand.run(curl, args: [url])
            rescue NetworkGuard::Blocked
              nil
            end.join
          end

          it("not rescued") { SystemCommand.run(curl, args: [url]) }
          it("broken", :broken) { nil }
          it("offline") { nil }
        end
        # rubocop:enable RSpec/NoExpectationExample
        group.run(RSpec::Core::NullReporter)
        group.examples.to_h do |example|
          result = example.execution_result
          [example.description, [result.status, result.exception&.class, result.exception&.message&.include?(url)]]
        end
      end
      blocked = [:failed, NetworkGuard::Blocked, true]
      expect(results).to eq("rescued" => blocked, "on another thread" => blocked, "not rescued" => blocked,
                            "broken" => [:failed, RuntimeError, false], "offline" => [:passed, nil, nil])
    end

    it "lets an example tagged `:needs_github` reach only GitHub", :needs_github do
      reached = %w[https://github.com/ https://api.github.com/ https://ghcr.io/v2/
                   https://raw.githubusercontent.com/ https://brew.sh/ https://github.com.example/].to_h do |url|
        curl(url)
        [url, true]
      rescue NetworkGuard::Blocked
        [url, false]
      end
      network_requests.clear
      expect(reached).to eq("https://github.com/" => true, "https://api.github.com/" => true,
                            "https://ghcr.io/v2/" => true, "https://raw.githubusercontent.com/" => true,
                            "https://brew.sh/" => false, "https://github.com.example/" => false)
    end

    it "stops GitHub for an example that sets `needs_github: false`, as one nested in a tagged group may",
       needs_github: false do
      expect { curl("https://github.com/") }.to raise_error(NetworkGuard::Blocked)
      network_requests.clear
    end

    it "lets an example tagged `:needs_github` run curl through brew's `Utils::Curl`", :needs_github do
      expect { Utils::Curl.curl_executable }.not_to raise_error
    end
  end
end
