# typed: true
# frozen_string_literal: true

require "json"
require "stringio"

# A fake LLM provider and a check that its API key never gets out, for the
# specs of the `-timed` commands that `include` this.
module TimedLLMHelper
  extend T::Helpers

  requires_ancestor { RSpec::Mocks::ExampleMethods }
  requires_ancestor { Test::Helper::MkTmpDir }

  # An Anthropic key, as the provider is worked out from it.
  KEY = "sk-ant-api03-FAKEKEY0123456789abcdef"

  # A file holding `KEY`, readable by its owner only.
  sig { returns(Pathname) }
  def llm_key_file
    file = mktmpdir/"key"
    file.write("#{KEY}\n")
    file.chmod(0600)
    file
  end

  # The provider answers each request, added to `requests`, with `answer`'s
  # estimates by name, as `provider`'s API does, or with `answer` as the
  # error status and a body echoing the key, or raises `answer`. The machine
  # is always the same.
  sig {
    params(answer: T.any(T::Hash[String, Integer], Integer, Exception), requests: T::Array[Timed::LLM::Request],
           provider: String).void
  }
  def answer_with(answer, requests, provider: "anthropic")
    allow(Timed::Machine).to receive(:facts).and_return("cpu" => "Apple M2 Pro", "threads" => 12,
                                                        "os" => "macOS 15.7")
    allow(Timed::LLM).to receive(:post) do |request, _timeout|
      requests << request
      case answer
      when Exception then Kernel.raise answer
      when Integer then Timed::LLM::Response.new(code: answer, body: { error: "bad key #{KEY}" }.to_json)
      else
        estimates = answer.map { |name, seconds| { name:, seconds: } }
        body = if provider == "openai"
          { choices: [{ message: { content: { estimates: }.to_json } }] }
        else
          { content: [{ type: "tool_use", input: { estimates: } }] }
        end
        Timed::LLM::Response.new(code: 200, body: body.to_json)
      end
    end
  end

  # What `block` prints to stdout and stderr together.
  sig { params(_block: T.proc.void).returns(String) }
  def printed(&_block)
    stdout = $stdout
    stderr = $stderr
    output = StringIO.new
    $stdout = $stderr = output
    yield
    output.string
  ensure
    $stdout = stdout
    $stderr = stderr
  end

  # Runs the block, given the arguments that turn LLM estimates on with `KEY`,
  # `--yes` and `--debug`, once for each way the provider can answer: with
  # an estimate for `new`, refusing the key or unreachable, each with the
  # build log at `database` as it was. Brew installs each formula a sub-call
  # names (other than `--dry-run`'s) at 2.0, with `receipt`. Gives, by way,
  # the number of requests made; where the key turned up: output, the log,
  # batch logs or receipts, any sub-call's arguments or environment, or this
  # process's environment, and whether any sub-call was given an LLM flag;
  # and the sub-calls, each as its verb and names.
  sig {
    params(database: Pathname, receipt: Pathname, _run: T.proc.params(argv: T::Array[String]).void)
      .returns(T::Hash[String, [Integer, T::Array[String], T::Array[String]]])
  }
  def key_leaks(database, receipt, &_run)
    sub_calls = []
    allow(Timed::Command).to receive(:brew) do |env, argv|
      sub_calls << [env, argv]
      true
    end
    allow(Timed::Runner).to receive(:stream) do |argv, env: {}, &block|
      sub_calls << [env, argv]
      next true if argv.include?("--dry-run")

      argv.drop(1).reject { |arg| arg.start_with?("-") }.each do |arg|
        name = File.basename(arg, ".rb")
        keg = HOMEBREW_CELLAR/name/"2.0"
        keg.mkpath
        data = JSON.parse(receipt.read).merge("time" => Time.now.to_i, "arch" => Hardware::CPU.arch.to_s)
        (keg/"INSTALL_RECEIPT.json").write(JSON.generate(data))
        (HOMEBREW_PREFIX/"opt").mkpath
        FileUtils.rm_f HOMEBREW_PREFIX/"opt"/name
        FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt"/name
        block.call("🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n")
      end
      true
    end
    original = database.read
    key_file = llm_key_file
    answers = { "answered" => { "new" => 300 }, "refused" => 401, "unreachable" => RuntimeError.new("lost #{KEY}") }
    answers.to_h do |label, answer|
      database.write(original)
      sub_calls.clear
      requests = []
      answer_with(answer, requests)
      output = printed { yield ["--yes", "--debug", "--llm-estimates", "--llm-api-key-file=#{key_file}"] }
      files = [database, *(HOMEBREW_LOGS/"timed").glob("*"), *HOMEBREW_CELLAR.glob("*/*/INSTALL_RECEIPT.json")]
      places = { "output" => output, "files" => files.map(&:read).join, "sub-calls" => sub_calls.inspect,
                 "ENV" => ENV.to_h.inspect }
      leaks = places.select { |_, text| text.include?("FAKEKEY") }.keys
      leaks << "sub-call LLM flags" if sub_calls.any? { |_, argv| argv.any? { |arg| arg.match?(/\A--(?:no-)?llm-/) } }
      [label, [requests.length, leaks, sub_calls.map { |_, argv| argv.grep_v(/\A-/).join(" ") }]]
    end
  end
end
