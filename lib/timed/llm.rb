# typed: strict
# frozen_string_literal: true

require "ipaddr"
require "json"
require "net/http"
require "socket"
require "timeout"
require "uri"
require "utils/formatter"
require "utils/output"

module Timed
  # LLM build time estimates: settings, one request/response adapter per
  # provider, response validation and redaction. HTTP goes through a seam.
  module LLM
    extend Utils::Output::Mixin

    BUDGET_SECONDS = 45.0
    MAX_SECONDS = T.let(48 * 60 * 60, Integer)
    MAX_ERROR_LENGTH = 200
    # Decoded; a real answer for hundreds of formulae is a few KB. Only the
    # body is capped: capping the status, header and chunk-size lines would
    # mean hooking private `Net::HTTP` internals, the endpoint is one the
    # user chose, and the worst case is a failed or crashed run, never a
    # leaked key (see #14).
    MAX_RESPONSE_BYTES = T.let(1024 * 1024, Integer)
    RESOLVE_TIMEOUT_SECONDS = 5
    # Failures to connect to one address, after which the next may work.
    CONNECT_ERRORS = T.let([Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
                            Errno::EAFNOSUPPORT].freeze, T::Array[T.class_of(SystemCallError)])
    TOOL = "build_estimates"
    SYSTEM_PROMPT = "You estimate how long Homebrew takes to build formulae from source on one machine. " \
                    "Give every formula asked about an estimated build time in seconds."

    # A failure worth a warning; the message is shown, redacted.
    class Error < RuntimeError; end

    # An API key that never shows up in `inspect`, `to_s` or error messages,
    # and can't be written out with YAML or `Marshal`.
    class Secret
      sig { returns(String) }
      attr_reader :value

      sig { params(value: String).void }
      def initialize(value)
        @value = value
      end

      sig { returns(String) }
      def inspect = "******"

      alias to_s inspect

      sig { params(_coder: T.anything).returns(T.noreturn) }
      def encode_with(_coder) = raise(TypeError, "API keys can't be serialized")

      sig { returns(T.noreturn) }
      def marshal_dump = raise(TypeError, "API keys can't be serialized")
    end

    # Resolved `--llm-*` settings. `addresses` pins plain `http://` requests
    # to the local addresses checked here, in resolver order, so a second
    # lookup can't redirect them.
    class Settings < T::Struct
      const :provider, String
      const :url, URI::HTTP
      const :model, String
      const :key, T.nilable(Secret)
      const :addresses, T::Array[String]
    end

    # A formula to estimate.
    class Subject < T::Struct
      const :name, String
      const :version, String
      const :desc, T.nilable(String)
      const :build_dependencies, T::Array[String], default: []
    end

    # A `POST` for the HTTP seam. Its headers hold the key, so `inspect`
    # leaves them out.
    class Request
      sig { returns(URI::HTTP) }
      attr_reader :uri

      sig { returns(T::Hash[String, String]) }
      attr_reader :headers

      sig { returns(String) }
      attr_reader :body

      sig { returns(T::Array[String]) }
      attr_reader :addresses

      sig {
        params(uri: URI::HTTP, headers: T::Hash[String, String], body: String, addresses: T::Array[String]).void
      }
      def initialize(uri:, headers:, body:, addresses:)
        @uri = uri
        @headers = headers
        @body = body
        @addresses = addresses
      end

      sig { returns(String) }
      def inspect = "#<#{self.class.name} POST #{uri}>"
    end

    # What the HTTP seam returns.
    class Response < T::Struct
      const :code, Integer
      const :body, String
    end

    # One provider's API: where it is, how to ask it, where its answer is.
    module Adapter
      extend T::Helpers

      interface!

      sig { abstract.returns(String) }
      def url; end

      # A cheap pinned model for the provider's own API.
      sig { abstract.returns(String) }
      def model; end

      sig { abstract.params(key: T.nilable(Secret)).returns(T::Hash[String, String]) }
      def headers(key); end

      sig {
        abstract.params(model: String, prompt: String, schema: T::Hash[Symbol, T.anything])
                .returns(T::Hash[Symbol, T.anything])
      }
      def body(model, prompt, schema); end

      # The estimates list from a parsed response; raises
      # `NoMatchingPatternError` or `JSON::ParserError` without one.
      sig { abstract.params(response: T.anything).returns(T.anything) }
      def estimates(response); end
    end

    # Anthropic's Messages API, answering through a forced tool call.
    module Anthropic
      extend Adapter

      sig { override.returns(String) }
      def self.url = "https://api.anthropic.com/v1/messages"

      sig { override.returns(String) }
      def self.model = "claude-haiku-4-5"

      sig { override.params(key: T.nilable(Secret)).returns(T::Hash[String, String]) }
      def self.headers(key)
        headers = { "anthropic-version" => "2023-06-01" }
        headers["x-api-key"] = key.value if key
        headers
      end

      sig {
        override.params(model: String, prompt: String, schema: T::Hash[Symbol, T.anything])
                .returns(T::Hash[Symbol, T.anything])
      }
      def self.body(model, prompt, schema)
        {
          model:,
          max_tokens:  8192,
          system:      SYSTEM_PROMPT,
          messages:    [{ role: "user", content: prompt }],
          tools:       [{ name: TOOL, description: "Record each formula's estimated build time.",
                          input_schema: schema }],
          tool_choice: { type: "tool", name: TOOL },
        }
      end

      sig { override.params(response: T.anything).returns(T.anything) }
      def self.estimates(response)
        response => { content: [*, { type: "tool_use", input: { estimates: } }, *] }
        estimates
      end
    end

    # OpenAI's Chat Completions API, answering in strict structured output.
    # Local servers (Ollama, `llama-server`, LM Studio, vLLM) speak it too.
    module OpenAI
      extend Adapter

      sig { override.returns(String) }
      def self.url = "https://api.openai.com/v1/chat/completions"

      sig { override.returns(String) }
      def self.model = "gpt-5-mini"

      sig { override.params(key: T.nilable(Secret)).returns(T::Hash[String, String]) }
      def self.headers(key)
        key ? { "Authorization" => "Bearer #{key.value}" } : {}
      end

      sig {
        override.params(model: String, prompt: String, schema: T::Hash[Symbol, T.anything])
                .returns(T::Hash[Symbol, T.anything])
      }
      def self.body(model, prompt, schema)
        body = {
          model:,
          messages:        [{ role: "system", content: SYSTEM_PROMPT }, { role: "user", content: prompt }],
          response_format: { type: "json_schema", json_schema: { name: TOOL, strict: true, schema: } },
        }
        # Other models, e.g. on local servers, may reject it.
        body[:reasoning_effort] = "minimal" if model == self.model
        body
      end

      sig { override.params(response: T.anything).returns(T.anything) }
      def self.estimates(response)
        response => { choices: [{ message: { content: String => content } }, *] }
        JSON.parse(content, symbolize_names: true) => { estimates: }
        estimates
      end
    end

    PROVIDERS = T.let({ "anthropic" => Anthropic, "openai" => OpenAI }.freeze, T::Hash[String, Adapter])

    # Resolves each setting from its `--llm-*` flag, then its
    # `HOMEBREW_TIMED_LLM_*` variable, then its default. Raises `UsageError`
    # for settings that can't work, before any request.
    sig {
      params(
        key_file: T.nilable(String), provider: T.nilable(String), url: T.nilable(String), model: T.nilable(String),
        resolver: T.proc.params(host: String).returns(T::Array[String])
      ).returns(Settings)
    }
    def self.settings(key_file: nil, provider: nil, url: nil, model: nil, resolver: ->(host) { resolve(host) })
      key_file = setting(key_file, "API_KEY_FILE")
      key = read_key(Pathname(key_file)) if key_file
      url = setting(url, "URL")
      raise UsageError, "LLM estimates need `--llm-api-key-file` unless `--llm-url` is set." if key.nil? && url.nil?

      provider = setting(provider, "PROVIDER") || (key&.value&.start_with?("sk-ant-") ? "anthropic" : "openai")
      adapter = PROVIDERS.fetch(provider) do
        raise UsageError, "`--llm-provider` must be one of: #{PROVIDERS.keys.join(", ")}."
      end
      model = setting(model, "MODEL") || (adapter.model unless url)
      raise UsageError, "`--llm-url` needs `--llm-model`: there is no default model for it." unless model

      uri = parse_url(url || adapter.url)
      addresses = (uri.scheme == "http") ? local_addresses(uri, resolver) : []
      Settings.new(provider:, url: uri, model:, key:, addresses:)
    end

    # Asks for build time estimates of `subjects` in one request, within
    # 45 seconds including one retry on HTTP 429 or 5xx. Returns only valid
    # estimates for names asked about; on any failure, warns and returns none.
    sig {
      params(
        settings: Settings, subjects: T::Array[Subject], machine: T::Hash[String, T.any(String, Integer, Float)],
        http: T.proc.params(request: Request, timeout: Float).returns(Response), clock: T.proc.returns(Float)
      ).returns(T::Hash[String, Float])
    }
    def self.estimates(settings, subjects, machine:, http: ->(request, timeout) { post(request, timeout) },
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f })
      return {} if subjects.empty?

      deadline = clock.call + BUDGET_SECONDS
      adapter = PROVIDERS.fetch(settings.provider)
      names = subjects.map(&:name)
      prompt = JSON.generate(machine:, formulae: subjects.map(&:serialize))
      request = Request.new(uri: settings.url, addresses: settings.addresses,
                            headers: { "Content-Type" => "application/json", **adapter.headers(settings.key) },
                            body: JSON.generate(adapter.body(settings.model, prompt, schema(names))))
      response = http.call(request, deadline - clock.call)
      if retry?(response.code) && (time_left = deadline - clock.call).positive?
        response = http.call(request, time_left)
      end
      raise Error, http_error(response, settings) unless (200..299).cover?(response.code)

      valid(response_estimates(adapter, response.body), names)
    rescue => e
      opoo redact("LLM build time estimates failed (#{settings.provider} #{settings.model}), " \
                  "using median build times: #{e.message}", settings)
      {}
    end

    # The real HTTP seam: in-process, so the key never reaches an argv.
    # Never follows redirects, never sends the request twice and never runs
    # past `timeout` in total.
    sig { params(request: Request, timeout: Float).returns(Response) }
    def self.post(request, timeout)
      uri = request.uri
      body = +""
      too_large = "the response is larger than #{MAX_RESPONSE_BYTES / 1024 / 1024} MiB"
      begin
        Timeout.timeout(timeout) do
          http = (uri.scheme == "https") ? https_connection(uri, timeout) : http_connection(request, timeout)
          begin
            # Read in chunks, decoded, to stop at the limit rather than after
            # buffering all of an untrusted answer.
            response = http.request(Net::HTTP::Post.new(uri.request_uri, request.headers), request.body) do |answer|
              answer.read_body do |chunk|
                body << chunk
                next if body.bytesize <= MAX_RESPONSE_BYTES

                # Hanging up first stops `Net::HTTP` waiting for the rest of
                # the chunk; the error that causes is reported as this one.
                http.finish
                raise Error, too_large
              end
            end
            Response.new(code: response.code.to_i, body:)
          ensure
            http.finish if http.started?
          end
        end
      rescue
        raise Error, too_large if body.bytesize > MAX_RESPONSE_BYTES

        raise
      end
    end

    # `https://` honours `https_proxy` and `no_proxy`, which brew keeps;
    # `Net::HTTP` alone would look up `http_proxy` instead.
    sig { params(uri: URI::HTTP, timeout: Float).returns(Net::HTTP) }
    private_class_method def self.https_connection(uri, timeout)
      proxy = begin
        uri.find_proxy
      rescue URI::InvalidURIError
        # Its message quotes the proxy URL, password and all.
        raise Error, "`https_proxy` is not a valid URL"
      end
      # Decoded as `Net::HTTP` decodes `http_proxy` credentials.
      http = Net::HTTP.new(uri.hostname, uri.port, proxy&.hostname, proxy&.port,
                           proxy&.user&.then { URI.decode_www_form_component(it) },
                           proxy&.password&.then { URI.decode_www_form_component(it) })
      http.use_ssl = true
      started(http, timeout)
    end

    # Plain `http://` goes only to its pinned loopback or private addresses,
    # never through a proxy, trying each in order and moving on only when one
    # can't be connected to (e.g. `localhost` resolving to `::1` first for a
    # server on 127.0.0.1 only). One `open_timeout` is shared across the
    # addresses, not split between them, so an address that silently drops
    # the connection can use it all.
    sig { params(request: Request, timeout: Float).returns(Net::HTTP) }
    private_class_method def self.http_connection(request, timeout)
      addresses = request.addresses
      if addresses.empty? || !addresses.all? { |address| local?(address) }
        raise Error, "plain `http://` only goes to checked loopback or private addresses"
      end

      attempt = 0
      begin
        http = Net::HTTP.new(request.uri.hostname, request.uri.port, nil)
                        .tap { |pinned| pinned.ipaddr = addresses.fetch(attempt) }
        started(http, timeout)
      rescue *CONNECT_ERRORS
        attempt += 1
        retry if attempt < addresses.size
        raise
      end
    end

    sig { params(http: Net::HTTP, timeout: Float).returns(Net::HTTP) }
    private_class_method def self.started(http, timeout)
      http.open_timeout = http.read_timeout = timeout
      http.max_retries = 0
      http.start
    end

    sig { params(address: String).returns(T::Boolean) }
    private_class_method def self.local?(address)
      ip = IPAddr.new(address)
      ip.loopback? || ip.private?
    end

    sig { params(flag: T.nilable(String), name: String).returns(T.nilable(String)) }
    private_class_method def self.setting(flag, name)
      flag.presence || ENV.fetch("HOMEBREW_TIMED_LLM_#{name}", nil).presence
    end

    sig { params(url: String).returns(URI::HTTP) }
    private_class_method def self.parse_url(url)
      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      return uri if uri.is_a?(URI::HTTP) && uri.host.present?

      raise UsageError, "`--llm-url` must be an `https://` or `http://` URL with a host."
    end

    # Plain `http://` only reaches loopback or private addresses, judged by
    # every address the host resolves to.
    sig {
      params(uri: URI::HTTP, resolver: T.proc.params(host: String).returns(T::Array[String]))
        .returns(T::Array[String])
    }
    private_class_method def self.local_addresses(uri, resolver)
      host = uri.hostname.to_s
      addresses = begin
        resolver.call(host)
      rescue => e
        raise UsageError, "`--llm-url` host #{host} could not be resolved: #{e.message}"
      end
      return addresses if addresses.any? && addresses.all? { |address| local?(address) }

      raise UsageError, "`--llm-url` host #{host} is not a loopback or private address: use `https://`."
    end

    sig { params(host: String).returns(T::Array[String]) }
    private_class_method def self.resolve(host)
      Addrinfo.getaddrinfo(host, nil, nil, :STREAM, timeout: RESOLVE_TIMEOUT_SECONDS).map(&:ip_address)
    end

    # Errors name the path, never the contents.
    sig { params(path: Pathname).returns(Secret) }
    private_class_method def self.read_key(path)
      raise UsageError, "LLM API key file #{path} does not exist." unless path.exist?
      raise UsageError, "LLM API key file #{path} is not a file." unless path.file?
      raise UsageError, "LLM API key file #{path} is not readable." unless path.readable?

      key = File.binread(path).strip
      raise UsageError, "LLM API key file #{path} is empty." if key.empty?
      unless key.match?(/\A[!-~]+\z/n)
        raise UsageError, "LLM API key file #{path} must hold just the key, on one line, in ASCII."
      end

      if path.stat.mode.anybits?(0044)
        opoo "LLM API key file #{path} is readable by other users; run `chmod 600 #{path}`."
      end
      Secret.new(key.force_encoding(Encoding::UTF_8))
    end

    # A JSON schema for a list of `{name, seconds}` for `names`.
    sig { params(names: T::Array[String]).returns(T::Hash[Symbol, T.anything]) }
    private_class_method def self.schema(names)
      estimate = {
        type:                 "object",
        properties:           { name: { type: "string", enum: names }, seconds: { type: "number" } },
        required:             ["name", "seconds"],
        additionalProperties: false,
      }
      {
        type:                 "object",
        properties:           { estimates: { type: "array", items: estimate } },
        required:             ["estimates"],
        additionalProperties: false,
      }
    end

    sig { params(code: Integer).returns(T::Boolean) }
    private_class_method def self.retry?(code)
      code == 429 || (500..599).cover?(code)
    end

    # The provider's error message, or the body as valid UTF-8, redacted
    # before it is cut short so no part of the key survives.
    sig { params(response: Response, settings: Settings).returns(String) }
    private_class_method def self.http_error(response, settings)
      message = begin
        JSON.parse(response.body, symbolize_names: true) => { error: { message: String => message } }
        message
      rescue JSON::ParserError, NoMatchingPatternError
        String.new(response.body, encoding: Encoding::UTF_8).scrub
      end
      message = redact(message.gsub(/\s+/, " ").strip, settings)
      message = "#{message[0, MAX_ERROR_LENGTH - 3]}..." if message.length > MAX_ERROR_LENGTH
      error = "HTTP #{response.code}"
      error += ": #{message}" if message.present?
      # A retired model name, or a base URL instead of the full endpoint.
      case response.code
      when 400 then error += "; check `--llm-model`"
      when 404 then error += "; check `--llm-url` and `--llm-model`"
      end
      error
    end

    # Parse errors quote the body, which may hold part of the key, so they
    # are replaced rather than passed on.
    sig { params(adapter: Adapter, body: String).returns(T.anything) }
    private_class_method def self.response_estimates(adapter, body)
      adapter.estimates(JSON.parse(body, symbolize_names: true))
    rescue JSON::ParserError
      raise Error, "the response is not JSON"
    rescue NoMatchingPatternError
      raise Error, "the response has no estimates"
    end

    # The response is untrusted: keep the first numeric estimate for each
    # name asked about, clamped to 1 second to 48 hours, and nothing else.
    sig { params(estimates: T.anything, names: T::Array[String]).returns(T::Hash[String, Float]) }
    private_class_method def self.valid(estimates, names)
      case estimates
      when Array
        estimates.each_with_object({}) do |estimate, valid|
          next unless estimate in { name: String => name, seconds: Integer | Float => seconds }
          next if names.exclude?(name) || valid.key?(name)

          valid[name] = seconds.clamp(1, MAX_SECONDS).to_f
        end
      else
        raise Error, "the response has no estimates"
      end
    end

    sig { params(text: String, settings: Settings).returns(String) }
    private_class_method def self.redact(text, settings)
      Formatter.redact_secrets(text, [settings.key&.value].compact)
    end
  end
end
