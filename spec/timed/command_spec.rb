# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/upgrade"
require_relative "../../lib/timed/command"

RSpec.describe Timed::Command do
  describe ".builtin" do
    it "fails clearly for a command that isn't loaded" do
      expect { described_class.builtin("nope") }.to raise_error(RuntimeError, "no `brew nope` command is loaded")
    end
  end

  describe ".parser_block" do
    it "fails clearly for a command without a `cmd_args` block" do
      command = Class.new(Homebrew::AbstractCommand)
      stub_const("Homebrew::Cmd::NoArgs", command)
      expect { described_class.parser_block(command) }
        .to raise_error(RuntimeError, "Homebrew::Cmd::NoArgs has no `cmd_args` block")
    end
  end

  describe ".forward" do
    let(:conflicts) { described_class.builtin("upgrade").parser.conflicts }

    it "forwards everything but its own and the ask flags to the preview" do
      options = %w[--debug --dry-run --ask --no-ask --formula --build-from-source --guess=llvm=1h --estimator=median
                   --last=llvm --exclude=go --no-stamp-receipts --minimum-version=1.0]
      expect(described_class.forward(options, conflicts:).preview)
        .to eq(%w[--debug --formula --build-from-source --minimum-version=1.0])
    end

    it "splits the rest into formula and cask flags by `brew upgrade`'s conflicts, without `--formula` or `--cask`",
       :aggregate_failures do
      options = %w[--verbose --formula --cask --force --build-from-source --keep-tmp --greedy --appdir=/Apps
                   --language=en,de --display-times]
      forwarded = described_class.forward(options, conflicts:)
      expect(forwarded.formula).to eq(%w[--verbose --force --build-from-source --keep-tmp --display-times])
      expect(forwarded.cask).to eq(%w[--verbose --force --greedy --appdir=/Apps --language=en,de --display-times])
    end
  end

  describe ".brew" do
    it "runs `HOMEBREW_BREW_FILE` from the home directory with the extra environment" do
      expect(Kernel).to receive(:system)
        .with({ "HOMEBREW_X" => nil }, HOMEBREW_BREW_FILE.to_s, "upgrade", "--dry-run", chdir: Dir.home)
        .and_return(true)
      described_class.brew({ "HOMEBREW_X" => nil }, %w[upgrade --dry-run])
    end
  end

  describe ".named_argv" do
    it "makes paths brew would load a formula or cask from absolute, as the sub-calls run elsewhere" do
      dir = mktmpdir
      (dir/"foo.rb").write("")
      (dir/"bar.json").write("")
      Dir.chdir(dir) do
        expect(described_class.named_argv(%w[foo.rb bar.json missing.rb foo]))
          .to eq([(dir/"foo.rb").realpath.to_s, (dir/"bar.json").realpath.to_s, "missing.rb", "foo"])
      end
    end
  end

  describe ".path_arguments" do
    it "gives each formula named by a path that path, made absolute, and leaves the others to their names" do
      dir = mktmpdir
      (dir/"foo.rb").write("class Foo < Formula\n  url \"https://brew.sh/foo-1.0.tgz\"\nend\n")
      bar = formula("bar") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/bar-1.0.tgz"
      end
      Dir.chdir(dir) do
        foo = Formulary.factory("foo.rb")
        expect(described_class.path_arguments(%w[foo.rb bar], { "foo" => foo, "bar" => bar }))
          .to eq("foo" => (dir/"foo.rb").realpath.to_s)
      end
    end
  end

  describe ".auto_update" do
    let(:fetch_head) { mktmpdir/"FETCH_HEAD" }
    let(:calls) { [] }
    let(:execs) { [] }

    def auto_update(touch: false, argv: %w[--dry-run llvm])
      brew = lambda do |env, brew_argv|
        calls << [env, brew_argv]
        FileUtils.touch fetch_head, mtime: Time.now + 60 if touch
        true
      end
      described_class.auto_update(command: "upgrade-timed", argv:, fetch_head:, brew:,
                                  exec: ->(env, exec_argv) { execs << [env, exec_argv] })
    end

    it "runs `brew update-if-needed` without `HOMEBREW_AUTO_UPDATE_CHECKED`, which brew set for this command" do
      ENV["HOMEBREW_AUTO_UPDATE_CHECKED"] = "1"
      auto_update
      expect(calls).to eq([[{ "HOMEBREW_AUTO_UPDATE_CHECKED" => nil, "HOMEBREW_AUTO_UPDATE_SKIP_OUTDATED" => nil },
                            %w[update-if-needed]]])
    end

    it "skips the outdated count without named arguments, which the plan lists, as for `brew upgrade`" do
      auto_update(argv: %w[--dry-run --last=llvm])
      expect(calls.map { |env, _| env["HOMEBREW_AUTO_UPDATE_SKIP_OUTDATED"] }).to eq(["1"])
    end

    it "doesn't re-run the command when `FETCH_HEAD` is unchanged" do
      FileUtils.touch fetch_head
      auto_update
      expect(execs).to eq([])
    end

    it "re-runs the command once, marked as updated, when `FETCH_HEAD` changed" do
      FileUtils.touch fetch_head, mtime: Time.now - 86_400
      auto_update(touch: true)
      expect(execs).to eq([[{ "HOMEBREW_TIMED_AUTO_UPDATED" => "1" }, %w[upgrade-timed --dry-run llvm]]])
    end

    it "re-runs the command when `FETCH_HEAD` appeared" do
      auto_update(touch: true)
      expect(execs.length).to eq(1)
    end

    it "does nothing in the re-run command", :aggregate_failures do
      ENV["HOMEBREW_TIMED_AUTO_UPDATED"] = "1"
      auto_update(touch: true)
      expect(calls).to eq([])
      expect(execs).to eq([])
    end
  end

  describe ".estimate" do
    let(:log) do
      builds = lambda do |status, *seconds|
        seconds.map { |value| { "status" => status, "install_seconds" => value } }
      end
      Timed::BuildLog.new("schema_version" => 1, "packages" => {
        "llvm" => { "builds" => builds.call("built", 100.0, 200.0, 600.0) },
        "wget" => { "builds" => builds.call("poured", 4.0) },
        "curl" => { "builds" => builds.call("poured", 8.0) },
      })
    end

    def estimate(name, pour:, estimator: :mean, guesses: {})
      estimate = described_class.estimate(log, name, pour:, estimator:, guesses:)
      [estimate.seconds.round(1), estimate.fallback]
    end

    it "uses history of the same kind only, ignoring `--guess`, with the chosen estimator" do
      estimates = [estimate("llvm", pour: false, guesses: { "llvm" => 1.0 }),
                   estimate("llvm", pour: false, estimator: :median), estimate("wget", pour: true)]
      expect(estimates).to eq([[696.9, false], [200.0, false], [4.0, false]])
    end

    it "uses `--guess` for a source build without history" do
      expect(estimate("wget", pour: false, guesses: { "wget" => 90.0 })).to eq([90.0, false])
    end

    it "falls back to the log's estimate of that kind otherwise, marked as a fallback" do
      expect([estimate("go", pour: false), estimate("llvm", pour: true, guesses: { "llvm" => 1.0 })])
        .to eq([[300.0, true], [6.0, true]])
    end
  end

  describe ".show_plan" do
    let(:estimates) do
      { "a" => 10.0, "b" => 100.0, "c" => 200.0 }.transform_values do |seconds|
        Timed::Command::Estimate.new(seconds:, pour: false, fallback: false)
      end
    end

    def batch(label, reason, *names) = Timed::Planner::Batch.new(label:, reason:, names:)

    it "marks `--last` batches, gives split reasons and lists `--exclude`d formulae" do
      result = Timed::Planner::Result.new(batches:  [batch("main", nil, "a"), batch("last", "--last", "b"),
                                                     batch("last", "slow c needs slow b", "c")],
                                          warnings: [])
      expect { described_class.show_plan("upgrade", result, estimates, excluded: %w[x y]) }
        .to output(<<~EOS).to_stdout
          ==> Would upgrade 3 formulae in 3 batches, estimated 5m10s
          ==> Batch 1 of 3: 0m10s
          a                            build     0m10s
          ==> Batch 2 of 3 (--last): 1m40s
          b                            build     1m40s
          ==> Batch 3 of 3 (--last): 3m20s, slow c needs slow b
          c                            build     3m20s
          ==> Excluded
          x y
        EOS
    end

    it "prints the planner's warnings" do
      result = Timed::Planner::Result.new(batches: [batch("main", nil, "a")], warnings: ["dependency cycle among a"])
      expect { described_class.show_plan("upgrade", result, estimates, excluded: []) }
        .to output("Warning: dependency cycle among a\n").to_stderr
    end
  end

  describe ".guesses" do
    it "reads `name=duration` pairs in hours, minutes and seconds, as `brew build-times` prints them" do
      expect(described_class.guesses(%w[llvm=1h26m lld=3m15s go=45s gcc=2h rust=1h02m03s]))
        .to eq("llvm" => 5160.0, "lld" => 195.0, "go" => 45.0, "gcc" => 7200.0, "rust" => 3723.0)
    end

    it "rejects anything else, naming it" do
      bad = %w[llvm llvm= =20m llvm=20 llvm=m llvm=1.5h llvm=20m1h llvm=-3m]
      errors = bad.to_h do |guess|
        described_class.guesses([guess])
        [guess, nil]
      rescue UsageError => e
        [guess, e.message]
      end
      expect(errors).to eq(bad.to_h do |guess|
        [guess, "Invalid usage: `--guess` needs `name=duration`, e.g. `llvm=1h30m`, not `#{guess}`."]
      end)
    end

    it "rejects zero durations" do
      expect { described_class.guesses(%w[llvm=0h0m]) }
        .to raise_error(UsageError, "Invalid usage: `--guess` needs a duration over zero, not `llvm=0h0m`.")
    end

    it "rejects a formula guessed twice, also under another name" do
      resolve = ->(name) { (name == "llvm@21") ? "llvm" : name }
      expect { described_class.guesses(%w[llvm=1h llvm@21=2h], resolve:) }
        .to raise_error(UsageError, "Invalid usage: `--guess` gives `llvm` more than once.")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
