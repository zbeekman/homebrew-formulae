# typed: true
# frozen_string_literal: true

require_relative "../../lib/timed/llm"

RSpec.describe Timed::LLM do
  let(:key) { "sk-ant-api03-FAKEKEY0123456789abcdef" }
  let(:key_file) { write_key_file("  #{key}\n") }
  let(:openai_key) { "sk-proj-FAKEOPENAIKEY0123456789" }
  let(:local_url) { "http://127.0.0.1:11434/v1/chat/completions" }
  let(:subjects) do
    [
      Timed::LLM::Subject.new(name: "llvm", version: "21.1.2", desc: "Next-gen compiler infrastructure",
                              build_dependencies: ["cmake", "ninja"]),
      Timed::LLM::Subject.new(name: "lld", version: "21.1.2", desc: "LLVM Project Linker",
                              build_dependencies: ["cmake"]),
    ]
  end
  let(:machine) { { "cpu" => "Intel Core i9-9980HK", "cores" => 8, "memory_gb" => 32, "os" => "macOS 15.7.5" } }
  let(:anthropic) { described_class.settings(key_file: key_file.to_s) }
  let(:openai) { described_class.settings(key_file: write_key_file(openai_key).to_s) }
  let(:local) { described_class.settings(url: local_url, model: "qwen2.5:7b") }
  let(:requests) { [] }
  let(:timeouts) { [] }
  let(:now) { [0.0] }
  let(:clock) { -> { now.fetch(0) } }

  # RSpec helper methods typecheck better as regular methods, as in brew's
  # own `test/.rubocop.yml`.
  # rubocop:disable Sorbet/BlockMethodDefinition
  def write_key_file(content, mode: 0600)
    file = mktmpdir/"key"
    file.write(content)
    file.chmod(mode)
    file
  end

  def usage_error(**options)
    described_class.settings(**options)
    raise "no UsageError"
  rescue UsageError => e
    e.message
  end

  def exclude(*items)
    satisfy("exclude #{items.join(", ")}") { |actual| items.none? { |item| actual.include?(item) } }
  end

  # Answers each request with the next response, or raises it, after
  # `seconds` pass on the fake clock.
  def fake_http(*responses, seconds: 1.0)
    lambda do |request, timeout|
      requests << request
      timeouts << timeout
      now[0] += seconds
      response = responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  def response(body, code: 200)
    Timed::LLM::Response.new(code:, body:)
  end

  def anthropic_response(estimates)
    response({ content: [{ type: "text", text: "Here you go." },
                         { type: "tool_use", name: "build_estimates", input: { estimates: } }] }.to_json)
  end

  def openai_response(estimates)
    response({ choices: [{ message: { role: "assistant", content: { estimates: }.to_json } }] }.to_json)
  end

  def estimates(settings, *responses, seconds: 1.0)
    described_class.estimates(settings, subjects, machine:, http: fake_http(*responses, seconds:), clock:)
  end

  def sent
    JSON.parse(requests.fetch(0).body)
  end

  def prompt
    JSON.parse(sent.dig("messages", 0, "content"))
  end

  def resolving(*addresses)
    ->(_host) { addresses }
  end
  # rubocop:enable Sorbet/BlockMethodDefinition

  describe "key secrecy" do
    it "never shows the key when settings are inspected" do
      expect([anthropic.inspect, anthropic.to_s, anthropic.pretty_inspect].join).to exclude(key)
    end

    it "refuses to write the key out as YAML" do
      expect { anthropic.to_yaml }.to raise_error(TypeError, /can't be serialized/)
    end

    it "refuses to write the key out with Marshal" do
      expect { Marshal.dump(anthropic) }.to raise_error(TypeError, /can't be serialized/)
    end

    it "names the path, never the contents, when the key file doesn't hold just a key" do
      ["", " \n\t\n", "#{key} second-word\n", "#{key}\nsecond-line\n", "#{key}é\n"].each do |content|
        file = write_key_file(content)
        expect(usage_error(key_file: file.to_s)).to include(file.to_s).and exclude("FAKEKEY", "second")
      end
    end

    it "names the path, never the contents, when the key has characters outside RFC 6750's `b64token`" do
      ["sk-FAKEKEY\"quoted", "sk-FAKEKEY\\escaped", "sk-FAKEKEY=padded-too-soon", "sk-FAKEKEY!"].each do |content|
        file = write_key_file(content)
        expect(usage_error(key_file: file.to_s)).to include(file.to_s).and exclude("FAKEKEY")
      end
    end

    it "accepts every RFC 6750 `b64token` character, then trailing `=`" do
      token = "AZaz09-._~+/sk=="
      expect(described_class.settings(key_file: write_key_file(token).to_s).key&.value).to eq(token)
    end

    it "never shows an error body, however it echoes the key" do
      slashed = "sk-proj-FAKE/SLASHED/KEY0123456789=="
      settings = described_class.settings(key_file: write_key_file(slashed).to_s)
      escaped = slashed.gsub(%r{[a-z/]}) { format("\\u%04x", it.ord) }
      upstream = { error: "invalid key #{slashed}" }.to_json.gsub("/", "\\/")
      [
        "invalid key #{slashed}",
        upstream,
        %Q({"error":"invalid key #{escaped}"}),
        { error: { message: "upstream said #{upstream}" } }.to_json.gsub("/", "\\/"),
        %Q({"error":"invalid key #{escaped}","retry":NaN}),
        "{\"error\":\"invalid key \xff#{slashed}\"}".b,
      ].each do |body|
        expect do
          described_class.estimates(settings, subjects, machine:, clock:, http: fake_http(response(body, code: 401)))
        end.to output("Warning: LLM build time estimates failed (openai gpt-5-mini), using median build times: " \
                      "HTTP 401; check `--llm-api-key-file`\n").to_stderr
      end
    end

    it "names the path when the key file is missing" do
      file = mktmpdir/"missing"
      expect(usage_error(key_file: file.to_s)).to include(file.to_s)
    end

    it "names the path when the key file is a directory" do
      directory = mktmpdir
      expect(usage_error(key_file: directory.to_s)).to include(directory.to_s)
    end

    it "names the path, never the contents, when the key file is unreadable" do
      skip "root reads any file" if Process.euid.zero?
      file = write_key_file(key, mode: 0200)
      expect(usage_error(key_file: file.to_s)).to include(file.to_s).and exclude(key)
    end

    it "warns, naming the path but not the key, when the key file is readable by others" do
      file = write_key_file(key, mode: 0644)
      expect { described_class.settings(key_file: file.to_s) }
        .to output(a_string_including(file.to_s).and(exclude(key))).to_stderr
    end

    it "warns when only the group or only the world can read the key file" do
      [0640, 0604].each do |mode|
        file = write_key_file(key, mode:)
        expect { described_class.settings(key_file: file.to_s) }.to output(/is readable by other users/).to_stderr
      end
    end

    it "doesn't warn when only the owner can read the key file" do
      expect { described_class.settings(key_file: key_file.to_s) }.not_to output.to_stderr
    end

    it "sends the Anthropic key only in its header" do
      estimates(anthropic, anthropic_response([]))
      request = requests.fetch(0)
      expect([request.headers["x-api-key"], request.uri.to_s, request.body])
        .to match([key, exclude(key), exclude(key)])
    end

    it "sends the OpenAI key only in its header" do
      estimates(openai, openai_response([]))
      request = requests.fetch(0)
      expect([request.headers["Authorization"], request.uri.to_s, request.body])
        .to match(["Bearer #{openai_key}", exclude(openai_key), exclude(openai_key)])
    end

    it "never shows the key when a request is inspected" do
      estimates(anthropic, anthropic_response([]))
      expect([requests.fetch(0).inspect, requests.fetch(0).pretty_inspect].join).to exclude(key)
    end

    it "prints nothing on success" do
      expect { estimates(anthropic, anthropic_response([{ name: "llvm", seconds: 3000 }])) }
        .to not_to_output.to_stdout.and not_to_output.to_stderr
    end

    it "redacts the key from the warning on every failure" do
      settings = described_class.settings(key_file: key_file.to_s, provider: "openai")
      [
        response({ error: { message: "invalid x-api-key #{key}" } }.to_json, code: 401),
        response("bad key #{key}", code: 500),
        SocketError.new("failed with #{key}"),
        response("#{key} oops"),
        response({ choices: [{ message: { content: "#{key} {" } }] }.to_json),
      ].each do |failure|
        expect do
          described_class.estimates(settings, subjects, machine:, clock:, http: fake_http(failure, failure))
        end.to output(a_string_including("LLM build time estimates failed").and(exclude(key[0, 16]))).to_stderr
      end
    end

    it "never puts the key in the environment sub-calls inherit" do
      estimates(anthropic, anthropic_response([{ name: "llvm", seconds: 3000 }]))
      expect(ENV.to_h.to_a.flatten.join("\n")).to exclude(key)
    end
  end

  describe ".settings" do
    let(:openai_key_file) { write_key_file("sk-proj-FAKEOPENAIKEY") }
    let(:no_lookup) { ->(host) { raise "looked up #{host}" } }

    it "reads the key from the key file, stripped" do
      expect(anthropic.key&.value).to eq(key)
    end

    it "reads the key file from `HOMEBREW_TIMED_LLM_API_KEY_FILE`" do
      ENV["HOMEBREW_TIMED_LLM_API_KEY_FILE"] = key_file.to_s
      expect(described_class.settings.key&.value).to eq(key)
    end

    it "prefers `--llm-api-key-file` to its environment variable" do
      ENV["HOMEBREW_TIMED_LLM_API_KEY_FILE"] = key_file.to_s
      expect(described_class.settings(key_file: openai_key_file.to_s).key&.value).to eq("sk-proj-FAKEOPENAIKEY")
    end

    it "treats empty values as unset" do
      ENV["HOMEBREW_TIMED_LLM_MODEL"] = ""
      expect(described_class.settings(key_file: key_file.to_s, model: "").model).to eq("claude-haiku-4-5")
    end

    it "needs a key file without a custom URL" do
      expect(usage_error(model: "claude-haiku-4-5")).to include("--llm-api-key-file")
    end

    it "uses Anthropic's API and pinned model for an `sk-ant-` key" do
      expect([anthropic.provider, anthropic.url.to_s, anthropic.model])
        .to eq(["anthropic", "https://api.anthropic.com/v1/messages", "claude-haiku-4-5"])
    end

    it "uses OpenAI's API and pinned model for any other key" do
      expect([openai.provider, openai.url.to_s, openai.model])
        .to eq(["openai", "https://api.openai.com/v1/chat/completions", "gpt-5-mini"])
    end

    it "prefers `--llm-provider` to the key prefix" do
      settings = described_class.settings(key_file: key_file.to_s, provider: "openai")
      expect(settings.provider).to eq("openai")
    end

    it "reads the provider from `HOMEBREW_TIMED_LLM_PROVIDER`" do
      ENV["HOMEBREW_TIMED_LLM_PROVIDER"] = "anthropic"
      expect(described_class.settings(key_file: openai_key_file.to_s).provider).to eq("anthropic")
    end

    it "prefers `--llm-provider` to its environment variable" do
      ENV["HOMEBREW_TIMED_LLM_PROVIDER"] = "anthropic"
      expect(described_class.settings(key_file: key_file.to_s, provider: "openai").provider).to eq("openai")
    end

    it "rejects an unknown provider" do
      expect(usage_error(key_file: key_file.to_s, provider: "gemini")).to include("--llm-provider")
    end

    it "reads the model from `HOMEBREW_TIMED_LLM_MODEL`" do
      ENV["HOMEBREW_TIMED_LLM_MODEL"] = "claude-sonnet-4-5"
      expect(described_class.settings(key_file: key_file.to_s).model).to eq("claude-sonnet-4-5")
    end

    it "prefers `--llm-model` to its environment variable" do
      ENV["HOMEBREW_TIMED_LLM_MODEL"] = "claude-sonnet-4-5"
      expect(described_class.settings(key_file: key_file.to_s, model: "claude-opus-4-1").model)
        .to eq("claude-opus-4-1")
    end

    it "reads the URL from `HOMEBREW_TIMED_LLM_URL`" do
      ENV["HOMEBREW_TIMED_LLM_URL"] = "https://gateway.example/v1/messages"
      expect(described_class.settings(key_file: key_file.to_s, model: "m").url.to_s)
        .to eq("https://gateway.example/v1/messages")
    end

    it "prefers `--llm-url` to its environment variable" do
      ENV["HOMEBREW_TIMED_LLM_URL"] = "https://gateway.example/v1/messages"
      expect(local.url.to_s).to eq(local_url)
    end

    it "uses OpenAI's API format with a custom URL and no key" do
      expect([local.provider, local.model, local.key]).to eq(["openai", "qwen2.5:7b", nil])
    end

    it "still infers Anthropic from an `sk-ant-` key with a custom URL" do
      settings = described_class.settings(key_file: key_file.to_s, url: "https://gateway.example/v1/messages",
                                          model: "claude-haiku-4-5")
      expect(settings.provider).to eq("anthropic")
    end

    it "needs a model with a custom URL" do
      expect(usage_error(url: local_url)).to include("--llm-model")
    end

    it "accepts `https://` anywhere without looking the host up" do
      settings = described_class.settings(key_file: key_file.to_s, url: "https://llm.example/v1/messages",
                                          model: "m", resolver: no_lookup)
      expect(settings.addresses).to be_empty
    end

    it "rejects a URL with another scheme, no host or bad syntax" do
      ["ftp://llm.example/v1", "https:///v1/messages", "http://[::1"].each do |url|
        expect(usage_error(url:, model: "m", resolver: no_lookup)).to include("--llm-url")
      end
    end

    it "pins plain `http://` to the loopback address it names" do
      expect(local.addresses).to eq(["127.0.0.1"])
    end

    it "pins plain `http://` to an IPv6 loopback address" do
      settings = described_class.settings(url: "http://[::1]:8080/v1/chat/completions", model: "m")
      expect(settings.addresses).to eq(["::1"])
    end

    it "judges plain `http://` by the resolved addresses, not the host name, and keeps them all" do
      settings = described_class.settings(url: "http://gpu.lan:8000/v1/chat/completions", model: "m",
                                          resolver: resolving("192.168.1.5", "fd00::5"))
      expect(settings.addresses).to eq(["192.168.1.5", "fd00::5"])
    end

    it "refuses plain `http://` to a host resolving to any public, link-local or unspecified address" do
      [["8.8.8.8"], ["192.168.1.5", "8.8.8.8"], ["169.254.169.254"], ["0.0.0.0"], []].each do |addresses|
        expect(usage_error(key_file: key_file.to_s, url: "http://llm.example/v1/messages", model: "m",
                           resolver: resolving(*addresses)))
          .to include("--llm-url").and include("llm.example")
      end
    end

    it "refuses plain `http://` to a public address even without a key" do
      expect(usage_error(url: "http://llm.example/v1/chat/completions", model: "m", resolver: resolving("8.8.8.8")))
        .to include("--llm-url")
    end

    it "rejects a plain `http://` host that doesn't resolve" do
      expect(usage_error(url: "http://gpu.lan/v1/chat/completions", model: "m",
                         resolver: ->(_host) { raise SocketError, "nodename nor servname provided" }))
        .to include("gpu.lan")
    end
  end

  describe ".estimates" do
    it "sends nothing when there is nothing to estimate" do
      described_class.estimates(anthropic, [], machine:, http: fake_http, clock:)
      expect(requests).to be_empty
    end

    it "posts to the settings' URL, pinned to their address" do
      estimates(local, openai_response([]))
      expect([requests.fetch(0).uri.to_s, requests.fetch(0).addresses]).to eq([local_url, ["127.0.0.1"]])
    end

    it "describes only the machine and each formula, not measured build times" do
      estimates(anthropic, anthropic_response([]))
      expect(prompt).to eq(
        "machine"  => machine,
        "formulae" => [
          { "name" => "llvm", "version" => "21.1.2", "desc" => "Next-gen compiler infrastructure",
            "build_dependencies" => ["cmake", "ninja"] },
          { "name" => "lld", "version" => "21.1.2", "desc" => "LLVM Project Linker",
            "build_dependencies" => ["cmake"] },
        ],
      )
    end

    it "asks Anthropic for the estimates through a forced tool call" do
      estimates(anthropic, anthropic_response([]))
      expect([sent["model"], sent["tool_choice"],
              sent.dig("tools", 0, "input_schema", "properties", "estimates", "items", "properties", "name", "enum")])
        .to eq(["claude-haiku-4-5", { "type" => "tool", "name" => "build_estimates" }, ["llvm", "lld"]])
    end

    it "sends Anthropic's API version and no extended thinking" do
      estimates(anthropic, anthropic_response([]))
      expect([requests.fetch(0).headers["anthropic-version"], sent.key?("thinking")]).to eq(["2023-06-01", false])
    end

    it "asks OpenAI for the estimates as strict structured output" do
      estimates(openai, openai_response([]))
      format = sent["response_format"]
      expect([sent["model"], format["type"], format.dig("json_schema", "strict"), sent.dig("messages", 1, "role")])
        .to eq(["gpt-5-mini", "json_schema", true, "user"])
    end

    it "asks OpenAI's pinned model for the lowest reasoning effort" do
      estimates(openai, openai_response([]))
      expect(sent["reasoning_effort"]).to eq("minimal")
    end

    it "sends no reasoning effort to other OpenAI models" do
      estimates(local, openai_response([]))
      expect(sent.key?("reasoning_effort")).to be(false)
    end

    it "sends no key header without a key" do
      estimates(local, openai_response([]))
      expect(requests.fetch(0).headers.keys).to eq(["Content-Type"])
    end

    it "reads Anthropic's estimates" do
      answer = anthropic_response([{ name: "llvm", seconds: 3000 }, { name: "lld", seconds: 600 }])
      expect(estimates(anthropic, answer)).to eq("llvm" => 3000.0, "lld" => 600.0)
    end

    it "reads OpenAI's estimates" do
      expect(estimates(openai, openai_response([{ name: "llvm", seconds: 3000.5 }]))).to eq("llvm" => 3000.5)
    end

    it "keeps only names it asked about, with numeric seconds" do
      expect(estimates(anthropic, anthropic_response([
        { name: "gcc", seconds: 5000 }, { name: "llvm", seconds: "3000" }, { name: "llvm", seconds: nil },
        { name: "llvm", seconds: true }, { name: ["lld"], seconds: 1 }, "lld", { name: "lld", seconds: 600, extra: 1 }
      ]))).to eq("lld" => 600.0)
    end

    it "keeps the first estimate for a name" do
      expect(estimates(anthropic, anthropic_response([{ name: "llvm", seconds: 30 }, { name: "llvm", seconds: 60 }])))
        .to eq("llvm" => 30.0)
    end

    it "clamps estimates to between 1 second and 48 hours" do
      answer = anthropic_response([{ name: "llvm", seconds: 10**30 }, { name: "lld", seconds: -5 }])
      expect(estimates(anthropic, answer)).to eq("llvm" => 172_800.0, "lld" => 1.0)
    end

    it "clamps an estimate too large for a float" do
      body = { choices: [{ message: { content: '{"estimates":[{"name":"llvm","seconds":1e400}]}' } }] }.to_json
      expect(estimates(openai, response(body))).to eq("llvm" => 172_800.0)
    end

    it "warns for a reply without estimates" do
      [
        [anthropic, { content: [{ type: "text", text: "llvm: 1h" }] }],
        [anthropic, { content: [{ type: "tool_use", input: { estimates: { llvm: 1 } } }] }],
        [openai, { choices: [{ message: { refusal: "no" } }] }],
        [openai, []],
      ].each do |settings, body|
        expect { estimates(settings, response(body.to_json)) }
          .to output(/estimates failed \(#{settings.provider} .*\), .*: the response has no estimates$/).to_stderr
      end
    end

    it "warns that a response isn't JSON" do
      expect { estimates(anthropic, response("<html>")) }.to output(/: the response is not JSON$/).to_stderr
    end

    it "warns that OpenAI's estimates aren't JSON" do
      body = { choices: [{ message: { content: "llvm: 1h" } }] }.to_json
      expect { estimates(openai, response(body)) }.to output(/: the response is not JSON$/).to_stderr
    end

    it "returns no estimates on failure" do
      expect(estimates(anthropic, response("<html>"))).to eq({})
    end

    it "warns with just the status on an error" do
      body = { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }.to_json
      expect { estimates(anthropic, response(body, code: 529), response(body, code: 529)) }
        .to output(/failed \(anthropic claude-haiku-4-5\), using median build times: HTTP 529$/).to_stderr
    end

    it "names `--llm-model` on HTTP 400" do
      body = { error: { message: "model 'qwen9' not found", code: "model_not_found" } }.to_json
      expect { estimates(openai, response(body, code: 400)) }.to output(/: HTTP 400; check `--llm-model`$/).to_stderr
    end

    it "names `--llm-api-key-file` on HTTP 401 and 403" do
      [401, 403].each do |code|
        expect { estimates(openai, response("", code:)) }
          .to output(/: HTTP #{code}; check `--llm-api-key-file`$/).to_stderr
      end
    end

    it "names `--llm-url` and `--llm-model` on HTTP 404" do
      body = { error: { message: "model 'qwen9' not found", code: "model_not_found" } }.to_json
      expect { estimates(openai, response(body, code: 404)) }
        .to output(/: HTTP 404; check `--llm-url` and `--llm-model`$/).to_stderr
    end

    it "says it was rate-limited on HTTP 429" do
      expect { estimates(openai, response("slow down", code: 429), response("slow down", code: 429)) }
        .to output(/: HTTP 429; rate-limited$/).to_stderr
    end

    it "calls a successful answer that isn't valid UTF-8 JSON not JSON" do
      expect { estimates(openai, response("{\"\xff\":1}".b)) }.to output(/: the response is not JSON$/).to_stderr
    end

    it "treats a redirect as a failure" do
      expect { estimates(openai, response("", code: 302)) }.to output(/HTTP 302$/).to_stderr
    end

    it "warns when the request fails" do
      expect { estimates(openai, Net::OpenTimeout.new("execution expired")) }
        .to output(/using median build times: execution expired$/).to_stderr
    end

    it "gives the first request the whole 45 seconds" do
      estimates(anthropic, anthropic_response([]))
      expect(timeouts).to eq([45.0])
    end

    it "retries once on HTTP 429 and 5xx" do
      [429, 500, 503, 529].each do |code|
        expect(estimates(anthropic, response("", code:), anthropic_response([{ name: "llvm", seconds: 60 }])))
          .to eq("llvm" => 60.0)
      end
    end

    it "gives the retry only the time left" do
      estimates(anthropic, response("", code: 429), anthropic_response([]), seconds: 20.0)
      expect(timeouts).to eq([45.0, 25.0])
    end

    it "retries only once" do
      estimates(anthropic, response("", code: 500), response("", code: 500), anthropic_response([]))
      expect(requests.size).to eq(2)
    end

    it "doesn't retry once the time is up" do
      estimates(anthropic, response("", code: 429), anthropic_response([]), seconds: 45.0)
      expect(requests.size).to eq(1)
    end

    it "doesn't retry on other HTTP errors" do
      [401, 403, 404].each do |code|
        requests.clear
        estimates(anthropic, response("", code:), anthropic_response([]))
        expect(requests.size).to eq(1)
      end
    end

    it "doesn't retry a request that failed" do
      estimates(anthropic, SocketError.new("offline"), anthropic_response([]))
      expect(requests.size).to eq(1)
    end
  end

  # Real `Net::HTTP` against servers on 127.0.0.1 in this process.
  describe ".post" do
    let(:servers) { [] }
    let(:threads) { [] }
    let(:received) { Queue.new }
    # A literal address, so nothing looks it up; only fakes connect to it.
    let(:secure_uri) { URI::HTTPS.build(host: "192.0.2.1", path: "/v1/messages") }
    let(:ok) { "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}" }
    let(:request) do
      port = serve { |client| client.write(ok) }
      Timed::LLM::Request.new(uri: URI::HTTP.build(host: "llm.invalid", port:, path: "/v1/messages"),
                              addresses: ["127.0.0.1"], body: '{"model":"m"}',
                              headers: { "Content-Type" => "application/json", "x-api-key" => key })
    end

    after do
      threads.each(&:kill)
      servers.each(&:close)
    end

    # RSpec helper methods typecheck better as regular methods.
    # rubocop:disable Sorbet/BlockMethodDefinition

    # Serves one request on a free port, puts what it read on `received`,
    # then yields the client to answer.
    def serve
      server = TCPServer.new("127.0.0.1", 0)
      servers << server
      threads << Thread.new do
        client = server.accept
        head = +""
        head << (client.gets || break) until head.end_with?("\r\n\r\n")
        received << (head + client.read(head[/^content-length: (\d+)/i, 1].to_i).to_s)
        yield client
      ensure
        client&.close
      end
      server.addr[1]
    end

    def local_request(port)
      Timed::LLM::Request.new(uri: URI::HTTP.build(host: "127.0.0.1", port:, path: "/"), addresses: ["127.0.0.1"],
                              headers: {}, body: "{}")
    end

    # Answers with an endless chunked body, gzip-encoded if asked, until the
    # client hangs up.
    def endless(client, gzip: false)
      deflate = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS + 16) if gzip
      client.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n#{"Content-Encoding: gzip\r\n" if gzip}\r\n")
      loop do
        chunk = "x" * 65_536
        chunk = deflate.deflate(chunk, Zlib::SYNC_FLUSH) if deflate
        client.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end
    # rubocop:enable Sorbet/BlockMethodDefinition

    it "posts the headers and body and returns the answer" do
      response = described_class.post(request, 5.0)
      expect([response.code, response.body, received.pop])
        .to match([200, "{}", a_string_starting_with("POST /v1/messages HTTP/1.1\r\n")
                                .and(a_string_including("\r\nX-Api-Key: #{key}\r\n"))
                                .and(a_string_ending_with("\r\n\r\n{\"model\":\"m\"}"))])
    end

    it "connects to the pinned address, not the host name" do
      expect(described_class.post(request, 5.0).code).to eq(200)
    end

    it "sends plain `http://` past any proxy" do
      ENV["http_proxy"] = "http://127.0.0.1:#{serve { |client| client.write("HTTP/1.1 502 Proxy\r\n\r\n") }}"
      described_class.post(request, 5.0)
      expect(received.pop).to start_with("POST /v1/messages ")
    end

    it "tunnels `https://` through `https_proxy` without showing it the key" do
      ENV["https_proxy"] = "http://127.0.0.1:#{serve { |client| client.write("HTTP/1.1 403 Forbidden\r\n\r\n") }}"
      secure = Timed::LLM::Request.new(uri: secure_uri, addresses: [],
                                       headers: { "x-api-key" => key }, body: "{}")
      expect { described_class.post(secure, 5.0) }.to raise_error(Timed::LLM::Error)
      expect(received.pop(timeout: 5).to_s).to start_with("CONNECT 192.0.2.1:443 HTTP/1.1\r\n").and exclude(key)
    end

    it "logs in to `https_proxy` with its decoded user name and password" do
      port = serve { |client| client.write("HTTP/1.1 403 Forbidden\r\n\r\n") }
      ENV["https_proxy"] = "http://me%40home:p%3Ass@127.0.0.1:#{port}"
      secure = Timed::LLM::Request.new(uri: secure_uri, addresses: [],
                                       headers: {}, body: "{}")
      expect { described_class.post(secure, 5.0) }.to raise_error(Timed::LLM::Error)
      expect(received.pop(timeout: 5).to_s)
        .to include("\r\nProxy-Authorization: Basic #{["me@home:p:ss"].pack("m0")}\r\n")
    end

    it "never quotes the reason `https_proxy` gives for refusing" do
      ENV["https_proxy"] = "http://127.0.0.1:#{serve { |client| client.write("HTTP/1.1 407 sk-SLY-KNOTS\r\n\r\n") }}"
      secure = Timed::LLM::Request.new(uri: secure_uri, addresses: [], headers: {}, body: "{}")
      expect { described_class.post(secure, 5.0) }
        .to raise_error(Timed::LLM::Error, "`https_proxy` answered HTTP 407")
    end

    it "never quotes a malformed status or chunk-size line" do
      [
        "HTTP/1.1 2xx sk-SLY-KNOTS\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nsk-SLY-KNOTS\r\n",
      ].each do |answer|
        malformed = local_request(serve { |client| client.write(answer) })
        expect { described_class.post(malformed, 5.0) }
          .to raise_error(Timed::LLM::Error, "the response is not valid HTTP")
      end
    end

    it "connects `https://` directly to hosts in `no_proxy`" do
      ENV["https_proxy"] = "http://127.0.0.1:#{serve { |client| client.write("HTTP/1.1 403 Forbidden\r\n\r\n") }}"
      ENV["no_proxy"] = "192.0.2.1"
      expect(TCPSocket).to receive(:open).with("192.0.2.1", 443, any_args).and_raise(Errno::ECONNREFUSED)
      secure = Timed::LLM::Request.new(uri: secure_uri, addresses: [], headers: {}, body: "{}")
      expect { described_class.post(secure, 5.0) }.to raise_error(Errno::ECONNREFUSED)
    end

    it "refuses a malformed `https_proxy` without quoting it" do
      ENV["https_proxy"] = "http://me:s3cret word@127.0.0.1:1"
      secure = Timed::LLM::Request.new(uri: secure_uri, addresses: [], headers: {}, body: "{}")
      expect { described_class.post(secure, 5.0) }
        .to raise_error(Timed::LLM::Error, a_string_including("`https_proxy`").and(exclude("s3cret")))
    end

    it "refuses plain `http://` without checked addresses, even with `http_proxy` set" do
      ENV["http_proxy"] = "http://127.0.0.1:#{serve { |client| client.write(ok) }}"
      bare = Timed::LLM::Request.new(uri: URI::HTTP.build(host: "192.0.2.1", path: "/"), addresses: [],
                                     headers: { "Authorization" => "Bearer #{key}" }, body: "{}")
      expect { described_class.post(bare, 5.0) }.to raise_error(Timed::LLM::Error)
      expect(received.pop(timeout: 0.5)).to be_nil
    end

    it "refuses plain `http://` to a pinned address that isn't loopback or private" do
      port = serve { |client| client.write(ok) }
      wild = Timed::LLM::Request.new(uri: URI::HTTP.build(host: "llm.invalid", port:, path: "/"),
                                     addresses: ["127.0.0.1", "0.0.0.0"], headers: {}, body: "{}")
      expect { described_class.post(wild, 5.0) }.to raise_error(Timed::LLM::Error)
      expect(received.pop(timeout: 0.5)).to be_nil
    end

    it "doesn't follow redirects" do
      target = serve { |client| client.write(ok) }
      redirect = serve do |client|
        client.write("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:#{target}/\r\n" \
                     "Content-Length: 0\r\n\r\n")
      end
      described_class.post(local_request(redirect), 5.0)
      expect(received.size).to eq(1)
    end

    it "stops at the time limit while a server trickles its answer" do
      trickle = serve do |client|
        client.write("HTTP/1.1 200 OK\r\n")
        loop do
          client.write("X-Wait: 1\r\n")
          sleep 0.05
        end
      end
      slow = local_request(trickle)
      expect { Timeout.timeout(3, RuntimeError, "no time limit") { described_class.post(slow, 0.5) } }
        .to raise_error(Timeout::Error)
    end

    it "asks a local server for estimates end to end" do
      answer = openai_response([{ name: "llvm", seconds: 3600 }]).body
      port = serve { |client| client.write("HTTP/1.1 200 OK\r\nContent-Length: #{answer.bytesize}\r\n\r\n#{answer}") }
      settings = described_class.settings(url: "http://127.0.0.1:#{port}/v1/chat/completions", model: "qwen2.5:7b")
      expect(described_class.estimates(settings, subjects, machine:)).to eq("llvm" => 3600.0)
    end

    it "moves on to the next checked address when one refuses the connection" do
      answer = openai_response([{ name: "llvm", seconds: 3600 }]).body
      port = serve { |client| client.write("HTTP/1.1 200 OK\r\nContent-Length: #{answer.bytesize}\r\n\r\n#{answer}") }
      settings = described_class.settings(url: "http://localhost:#{port}/v1/chat/completions", model: "qwen2.5:7b",
                                          resolver: resolving("::1", "127.0.0.1"))
      expect(described_class.estimates(settings, subjects, machine:)).to eq("llvm" => 3600.0)
    end

    it "gives up with the connection error once every address refused" do
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.addr[1]
      closed.close
      refused = Timed::LLM::Request.new(uri: URI::HTTP.build(host: "llm.invalid", port:, path: "/"),
                                        addresses: ["127.0.0.1", "127.0.0.1"], headers: {}, body: "{}")
      expect { described_class.post(refused, 5.0) }.to raise_error(Errno::ECONNREFUSED)
    end

    it "doesn't move on to the next address once a connection was made" do
      # The listener stays open, so a second attempt would hang until the
      # time limit instead of failing with the first attempt's error.
      port = serve { nil }
      twice = Timed::LLM::Request.new(uri: URI::HTTP.build(host: "llm.invalid", port:, path: "/"),
                                      addresses: ["127.0.0.1", "127.0.0.1"], headers: {}, body: "{}")
      expect { described_class.post(twice, 2.0) }.to raise_error(EOFError)
    end

    it "never sends the request again after a connection error mid-request" do
      posts = 0
      allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap do |http|
          allow(http).to receive(:request) do
            posts += 1
            raise Errno::EHOSTUNREACH
          end
        end
      end
      port = serve { nil }
      twice = Timed::LLM::Request.new(uri: URI::HTTP.build(host: "llm.invalid", port:, path: "/"),
                                      addresses: ["127.0.0.1", "127.0.0.1"], headers: {}, body: "{}")
      expect { described_class.post(twice, 2.0) }.to raise_error(Errno::EHOSTUNREACH)
      expect(posts).to eq(1)
    end

    it "warns and gives up once the 45 seconds are spent" do
      port = serve { sleep }
      settings = described_class.settings(url: "http://127.0.0.1:#{port}/v1/chat/completions", model: "m")
      times = [0.0, 44.7]
      expect { described_class.estimates(settings, subjects, machine:, clock: -> { times.shift || 45.0 }) }
        .to output(/LLM build time estimates failed .*: (execution expired|Net::ReadTimeout)/).to_stderr
    end

    it "warns and gives up on an answer over 1 MiB without reading it all" do
      port = serve { |client| endless(client) }
      settings = described_class.settings(url: "http://127.0.0.1:#{port}/v1/chat/completions", model: "m")
      times = [0.0, 42.0]
      expect { described_class.estimates(settings, subjects, machine:, clock: -> { times.shift || 45.0 }) }
        .to output(/LLM build time estimates failed .*: the response is larger than 1 MiB$/).to_stderr
    end

    it "stops reading a gzip-encoded answer once it decodes to over 1 MiB" do
      port = serve { |client| endless(client, gzip: true) }
      expect { described_class.post(local_request(port), 3.0) }
        .to raise_error(Timed::LLM::Error, "the response is larger than 1 MiB")
    end

    it "gives up at once when a server stalls after passing 1 MiB mid-chunk" do
      stall = serve do |client|
        client.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n200000\r\n#{"x" * ((1024 * 1024) + 1)}")
        sleep
      end
      stalled = local_request(stall)
      # Without an exception class, `Timeout` interrupts with one `post`
      # can't rescue, so it can't pass the wait off as the cap.
      expect { Timeout.timeout(3) { described_class.post(stalled, 10.0) } }
        .to raise_error(Timed::LLM::Error, "the response is larger than 1 MiB")
    end
  end
end
