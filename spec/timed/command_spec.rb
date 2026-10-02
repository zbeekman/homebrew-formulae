# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/upgrade"
require_relative "../../lib/timed/command"
require_relative "../support/casks"

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

    it "takes `--no-…` of a `--[no-]…` switch as that switch", :aggregate_failures do
      forwarded = described_class.forward(%w[--no-binaries --no-quit], conflicts:)
      expect(forwarded.formula).to eq([])
      expect(forwarded.cask).to eq(%w[--no-binaries --no-quit])
    end
  end

  describe ".options" do
    it "adds a `--[no-]…` switch, which `args.options_only` leaves out, as `--…` or `--no-…` when it differs " \
       "from what a sub-call would take from the environment" do
      command = described_class.builtin("upgrade")
      runs = { [nil, %w[--no-bin --verbose]] => %w[--verbose --no-binaries], [nil, %w[--binaries]] => [],
               [nil, []] => [], ["--no-binaries", %w[--binaries]] => %w[--binaries],
               ["--no-binaries", []] => [], ["--no-binaries", %w[--formula]] => [] }
      options = runs.keys.to_h do |cask_opts, argv|
        ENV["HOMEBREW_CASK_OPTS"] = cask_opts
        [[cask_opts, argv], described_class.options(command.new(argv).args, command.parser)
                                           .grep(/\A--(?:no-)?(?:binaries|verbose)\z/)]
      end
      expect(options).to eq(runs)
    end
  end

  describe "casks" do
    include TimedCaskHelper

    before { allow(Cask::CaskLoader).to receive(:for).and_call_original }

    describe ".installed_cask" do
      it "loads the installed caskfile, as brew does before it uninstalls the cask, and nothing when not installed" do
        expect([described_class.installed_cask(stub_cask("foo", installed_stanzas: 'pkg "Old.pkg"'))&.version,
                described_class.installed_cask(stub_cask("bar", nil))]).to eq(["1.0", nil])
      end

      it "leaves the installed caskfile of a cask from a tap that isn't trusted unloaded for a reinstall only, " \
         "as brew does, while tap trust is on" do
        cask = stub_cask("foo", installed_stanzas: 'pkg "Old.pkg"')
        allow(cask).to receive(:tap).and_return(Tap.fetch("user", "tap"))
        # `[tap trust on, cask trusted, reinstall]`
        runs = [[true, true, true], [true, true, false], [true, false, true], [true, false, false],
                [false, false, true]]
        loaded = runs.to_h do |trust_on, trusted, reinstall|
          allow(Homebrew::EnvConfig).to receive(:require_tap_trust?).and_return(trust_on)
          allow(Homebrew::Trust).to receive(:trusted?).with(:cask, "user/tap/foo").and_return(trusted)
          [[trust_on, trusted, reinstall], described_class.installed_cask(cask, reinstall:)&.version]
        end
        expect(loaded).to eq(runs.to_h { |run| [run, (run == [true, false, true]) ? nil : "1.0"] })
      end

      it "rebuilds the installed version from the new cask when brew can't load its caskfile, as brew does" do
        cask = stub_cask("foo", stanzas: 'app "Foo.app"', installed_stanzas: "no_such_stanza")
        installed = described_class.installed_cask(cask)
        expect([installed&.version, installed&.artifacts&.map { |artifact| artifact.class.dsl_key }])
          .to eq(["1.0", [:app]])
      end
    end

    describe ".cask_plan" do
      def plan(casks, in_run: [], tty: true, **options)
        described_class.cask_plan(casks, in_run:, facts: Timed::Casks::DiskFacts.new, tty: -> { tty }, **options)
      end

      def placed(result)
        { first: result.first, last: result.last, skipped: result.skipped }.transform_values do |entries|
          entries.to_h { |entry| [entry.cask.token, entry.reasons.map(&:message)] }
        end
      end

      it "classifies each cask by the verb brew acts on it with, judging the uninstall side on its installed " \
         "cask and counting the casks and formulae of the run as in it" do
        casks = { install: [stub_cask("new", nil, stanzas: 'depends_on cask: "old"'),
                            stub_cask("tool", nil, stanzas: 'depends_on formula: "llvm"')],
                  upgrade: [stub_cask("old", installed_stanzas: 'uninstall quit: "com.old"')] }
        expect(placed(plan(casks, in_run: %w[llvm])))
          .to eq(first: {}, skipped: {},
                 last:  { "new"  => ["depends on `old`, which is in this run"],
                          "tool" => ["depends on `llvm`, which is in this run"],
                          "old"  => ["`uninstall quit` may raise a dialog"] })
      end

      it "passes `zap` on to a reinstall and `force` to an install, reading the disk" do
        target = mktmpdir/"Foo.app"
        target.mkpath
        target.chmod(0555)
        casks = { reinstall: [stub_cask("old", installed_stanzas: 'zap signal: ["TERM", "com.old"]')],
                  install:   [stub_cask("new", nil, stanzas: "app \"Foo.app\", target: \"#{target}\"")] }
        expect([true, false].to_h { |given| [given, placed(plan(casks, zap: given, force: given))[:last]] })
          .to eq(true  => { "old" => ["`zap signal` may raise a dialog"],
                            "new" => ["`app` target `#{target}` is not writable"] },
                 false => {})
      ensure
        target&.chmod(0755)
      end

      it "judges a reinstall of a cask from a tap that isn't trusted on the new cask, but an upgrade on the " \
         "installed one, as brew does" do
        allow(Homebrew::EnvConfig).to receive(:require_tap_trust?).and_return(true)
        allow(Homebrew::Trust).to receive(:trusted?).and_return(false)
        placed = [:reinstall, :upgrade].to_h do |verb|
          cask = stub_cask("old", installed_stanzas: 'uninstall quit: "com.old"')
          allow(cask).to receive(:tap).and_return(Tap.fetch("user", "tap"))
          [verb, placed(plan({ verb => [cask] }))[:last]]
        end
        expect(placed).to eq(reinstall: {}, upgrade: { "old" => ["`uninstall quit` may raise a dialog"] })
      end

      it "skips the casks that need sudo without a terminal" do
        casks = { upgrade: [stub_cask("old", stanzas: 'pkg "Old.pkg"', installed_stanzas: "")] }
        expect(placed(plan(casks, tty: false)))
          .to eq(first: {}, last: {}, skipped: { "old" => ["`pkg` requires sudo"] })
      end
    end

    describe ".show_casks" do
      def entry(token, *messages)
        reasons = messages.map { |message| Timed::Casks::Reason.new(kind: :sudo, message:) }
        Timed::Casks::Entry.new(cask: Cask::Cask.new(token), reasons:)
      end

      it "lists the casks to run first, and those to run last with why", :aggregate_failures do
        last = [entry("baz", "`pkg` requires sudo", "`postflight` block may call sudo")]
        plan = Timed::Casks::Plan.new(first: [entry("foo"), entry("bar")], last:, skipped: [])
        expect { described_class.show_casks("upgrade", plan, named: []) }
          .to output(<<~EOS).to_stdout.and not_to_output.to_stderr
            ==> Would upgrade 2 casks first
            foo bar
            ==> Would upgrade 1 cask last
            baz: `pkg` requires sudo; `postflight` block may call sudo
          EOS
      end

      it "warns once about the casks skipped without a terminal, with the command to run them later" do
        plan = Timed::Casks::Plan.new(first: [], last: [],
                                      skipped: [entry("foo", "`pkg` requires sudo"), entry("bar", "`kext` x")])
        expect { described_class.show_casks("install", plan, named: []) }.to output(<<~EOS).to_stderr
          Warning: Skipping 2 casks, as sudo can't ask for a password without a terminal:
          foo: `pkg` requires sudo
          bar: `kext` x
          Install them later with `brew install --cask foo bar`.
        EOS
      end

      it "names a skipped cask given as a path by that path, made absolute, in the command to run it later" do
        dir = mktmpdir
        (dir/"foo.rb").write(cask_source("foo", "2.0"))
        Dir.chdir(dir) do
          reasons = [Timed::Casks::Reason.new(kind: :sudo, message: "`pkg` requires sudo")]
          skipped = [Timed::Casks::Entry.new(cask: Cask::CaskLoader.load("foo.rb"), reasons:)]
          plan = Timed::Casks::Plan.new(first: [], last: [], skipped:)
          path = Regexp.escape((dir/"foo.rb").realpath.to_s)
          expect { described_class.show_casks("install", plan, named: %w[foo.rb]) }
            .to output(/^Install it later with `brew install --cask #{path}`\.$/).to_stderr
        end
      end

      it "prints nothing without casks" do
        plan = Timed::Casks::Plan.new(first: [], last: [], skipped: [])
        expect { described_class.show_casks("upgrade", plan, named: []) }.not_to output.to_stdout
      end
    end

    describe ".cask_arguments" do
      it "gives each cask named by a path that path, made absolute, and the others their full names" do
        dir = mktmpdir
        (dir/"foo.rb").write(cask_source("foo", "2.0"))
        bar = Cask::Cask.new("bar", tap: Tap.fetch("user", "tap"))
        Dir.chdir(dir) do
          foo = Cask::CaskLoader.load("foo.rb")
          expect(described_class.cask_arguments(%w[foo.rb user/tap/bar], [foo, bar]))
            .to eq([(dir/"foo.rb").realpath.to_s, "user/tap/bar"])
        end
      end
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

    it "shows the dependencies of each formula, without estimates, with `dependencies_only`" do
      result = Timed::Planner::Result.new(batches:  [batch("main", nil, "a", "b"), batch("last", "--last", "c")],
                                          warnings: [])
      expect { described_class.show_plan("install", result, estimates, excluded: [], dependencies_only: true) }
        .to output(<<~EOS).to_stdout
          ==> Would install the dependencies of 3 formulae in 2 batches
          ==> Batch 1 of 2
          dependencies of a
          dependencies of b
          ==> Batch 2 of 2 (--last)
          dependencies of c
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
