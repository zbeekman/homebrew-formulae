# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/upgrade"
require "linkage_checker"
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

    it "forwards none of the LLM flags, nor keeps them for the `-timed` commands it suggests" do
      options = %w[--llm-estimates --no-llm-estimates --llm-api-key-file=/key --llm-provider=openai
                   --llm-url=https://example.com --llm-model=m --verbose]
      forwarded = described_class.forward(options, conflicts:)
      expect([forwarded.preview, forwarded.formula, forwarded.cask, forwarded.own]).to eq([*[%w[--verbose]] * 3, []])
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

    it "keeps for the `-timed` commands it suggests `--exclude`, a file given to it made absolute, and " \
       "`--no-stamp-receipts`, but not the ask flags or those that only shape the plan" do
      dir = mktmpdir
      FileUtils.touch dir/"lib.rb"
      options = %w[--debug --yes --no-ask --dry-run --guess=llvm=1h --estimator=median --last=llvm
                   --exclude=go,lib.rb --no-stamp-receipts]
      forwarded = Dir.chdir(dir) { described_class.forward(options, conflicts:) }
      expect(forwarded.own).to eq(["--exclude=go,#{(dir/"lib.rb").realpath}", "--no-stamp-receipts"])
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

  describe ".llm_settings" do
    it "is none without `--llm-estimates`, else the settings from the `--llm-*` flags or their variables, " \
       "raising `UsageError` for settings that can't work" do
      key_file = mktmpdir/"key"
      key_file.write("sk-proj-FAKEOPENAIKEY0123456789\n")
      key_file.chmod(0600)
      url = "http://127.0.0.1:11434/v1/chat/completions"
      runs = {
        "off"      => [{ "HOMEBREW_TIMED_LLM_URL" => url, "HOMEBREW_TIMED_LLM_MODEL" => "m" }, []],
        "variable" => [{ "HOMEBREW_TIMED_LLM_ESTIMATES" => "1", "HOMEBREW_TIMED_LLM_URL" => url,
                         "HOMEBREW_TIMED_LLM_MODEL" => "m" }, []],
        "flags"    => [{}, ["--llm-estimates", "--llm-api-key-file=#{key_file}", "--llm-provider=anthropic",
                            "--llm-url=#{url}", "--llm-model=qwen2.5:7b"]],
        "unusable" => [{}, ["--llm-estimates"]],
      }
      settings_by_run = runs.to_h do |label, (env, argv)|
        ENV.delete_if { |name, _| name.start_with?("HOMEBREW_TIMED_LLM_") }
        ENV.update(env)
        parser = Homebrew::CLI::Parser.new(described_class.builtin("upgrade"))
        described_class.define_flags(parser)
        settings = begin
          described_class.llm_settings(parser.parse(argv))&.then do |found|
            [found.provider, found.url.to_s, found.model, found.key&.value]
          end
        rescue UsageError => e
          e.message
        end
        [label, settings]
      end
      expect(settings_by_run).to eq(
        "off"      => nil,
        "variable" => ["openai", url, "m", nil],
        "flags"    => ["anthropic", url, "qwen2.5:7b", "sk-proj-FAKEOPENAIKEY0123456789"],
        "unusable" => "Invalid usage: LLM estimates need `--llm-api-key-file` unless `--llm-url` is set.",
      )
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
        # The cask brew uninstalls then is the new cask with the artifacts its
        # install recorded.
        expect(loaded).to eq(runs.to_h { |run| [run, (run == [true, false, true]) ? "2.0" : "1.0"] })
      end

      it "gives a reinstall of a cask that isn't trusted the artifacts its install recorded, with the new " \
         "cask's `uninstall` and `zap`, as brew uninstalls the recorded ones and zaps with the new cask's",
         :aggregate_failures do
        allow(Homebrew::EnvConfig).to receive(:require_tap_trust?).and_return(true)
        allow(Homebrew::Trust).to receive(:trusted?).and_return(false)
        dir = mktmpdir
        dir.chmod(0555)
        cask = stub_cask("foo", stanzas:           "uninstall quit: \"com.new\"\nzap trash: \"~/x\"",
                                installed_stanzas: 'pkg "Old.pkg"')
        allow(cask).to receive(:tap).and_return(Tap.fetch("user", "tap"))
        recorded = [{ "app" => ["Old.app", { "target" => "#{dir}/Old.app" }] },
                    { "uninstall" => [{ "pkgutil" => "com.old" }] }]
        (HOMEBREW_PREFIX/"Caskroom/foo/.metadata/INSTALL_RECEIPT.json")
          .write(JSON.generate("uninstall_artifacts" => recorded))
        installed = described_class.installed_cask(cask, reinstall: true)
        expect(installed&.artifacts&.map { |artifact| [artifact.class.dsl_key, artifact.to_args] })
          .to contain_exactly([:app, ["Old.app", { target: "#{dir}/Old.app" }]], [:uninstall, [{ quit: "com.new" }]],
                              [:zap, [{ trash: "~/x" }]])
        plan = described_class.cask_plan({ reinstall: [cask] }, in_run: [], facts: Timed::Casks::DiskFacts.new,
                                                                tty: -> { true })
        expect(plan.last.flat_map { |entry| entry.reasons.map(&:message) })
          .to include("`app` needs `#{dir}` writable", "`uninstall quit` may raise a dialog")
      ensure
        dir&.chmod(0755)
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
                 last:  { "new"  => ["depends on the `old` cask, which is in this run"],
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

      it "judges a reinstall of a cask from a tap that isn't trusted on what its install recorded, not its " \
         "installed caskfile, but an upgrade on the installed one, as brew does" do
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
        expect { described_class.show_casks("upgrade", plan, named: [], flags: []) }
          .to output(<<~EOS).to_stdout.and not_to_output.to_stderr
            ==> Would upgrade 2 casks first
            foo bar
            ==> Would upgrade 1 cask last
            baz: `pkg` requires sudo; `postflight` block may call sudo
          EOS
      end

      it "warns once about the casks skipped without a terminal, with the command to run them later with the " \
         "cask flags" do
        plan = Timed::Casks::Plan.new(first: [], last: [],
                                      skipped: [entry("foo", "`pkg` requires sudo"), entry("bar", "`kext` x")])
        expect { described_class.show_casks("install", plan, named: [], flags: %w[--force --no-binaries]) }
          .to output(<<~EOS).to_stderr
            Warning: Skipping 2 casks, as sudo can't ask for a password without a terminal:
            foo: `pkg` requires sudo
            bar: `kext` x
            Install them later with `brew install --cask --force --no-binaries foo bar`.
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
          expect { described_class.show_casks("install", plan, named: %w[foo.rb], flags: []) }
            .to output(/^Install it later with `brew install --cask #{path}`\.$/).to_stderr
        end
      end

      it "prints nothing without casks" do
        plan = Timed::Casks::Plan.new(first: [], last: [], skipped: [])
        expect { described_class.show_casks("upgrade", plan, named: [], flags: []) }.not_to output.to_stdout
      end
    end

    # A run of `install-timed --build-from-source`, given `roots` (by full
    # name, with their arguments), which bring in `needs`.
    def timed_run(roots = {}, needs = {})
      Timed::Command::Run.new(command: %w[install-timed --build-from-source], roots:, needs:)
    end

    # Formulae lib and app, which needs lib, at 1.0, loadable by name; lib
    # installed, with a receipt, and linked into `opt` if `installed_lib`.
    def stub_lib_and_app(installed_lib: false)
      allow(Formulary).to receive(:loader_for).and_call_original
      %w[lib app].each do |name|
        stub_formula_loader(formula(name) do
          T.bind(self, T.class_of(Formula))
          url "https://brew.sh/#{name}-1.0.tgz"
          depends_on "lib" if name == "app"
        end)
      end
      return unless installed_lib

      (HOMEBREW_CELLAR/"lib/1.0").mkpath
      (HOMEBREW_CELLAR/"lib/1.0"/AbstractTab::FILENAME).write("{}")
      (HOMEBREW_PREFIX/"opt").mkpath
      FileUtils.ln_s HOMEBREW_CELLAR/"lib/1.0", HOMEBREW_PREFIX/"opt/lib"
    end

    # The formula `xz`, loadable by name.
    def stub_xz
      allow(Formulary).to receive(:loader_for).and_call_original
      stub_formula_loader(formula("xz") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/xz-1.0.tgz"
      end)
    end

    # A core formula `foo`, also loadable as `foo-alias`, and a tap formula
    # `user/tap/foo`, neither installed.
    def stub_two_foos
      allow(Formulary).to receive(:loader_for).and_call_original
      core = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
      end
      stub_formula_loader(core)
      stub_formula_loader(core, "foo-alias")
      stub_formula_loader(formula("foo", tap: Tap.fetch("user", "tap")) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-2.0.tgz"
      end, "user/tap/foo")
    end

    # A core formula `docker`, not installed, sharing its name with a cask.
    def stub_docker_formula
      allow(Formulary).to receive(:loader_for).and_call_original
      stub_formula_loader(formula("docker") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/docker-1.0.tgz"
      end)
    end

    describe "a formula and a cask with the same name" do
      it "match only what in the run is of their own kind, both ways, the reason saying which" do
        stub_docker_formula
        docker = stub_cask("docker", nil)
        dependents = [stub_cask("needs-formula", nil, stanzas: 'depends_on formula: "docker"'),
                      stub_cask("needs-cask", nil, stanzas: 'depends_on cask: "docker"')]
        runs = { formula: [%w[docker], dependents], cask: [[], [docker, *dependents]] }
        placed = runs.transform_values do |(in_run, casks)|
          result = described_class.cask_plan({ install: casks }, in_run:, facts: Timed::Casks::DiskFacts.new,
                                                                 tty: -> { true })
          result.last.to_h { |entry| [entry.cask.token, entry.reasons.map(&:message)] }
        end
        expect(placed).to eq(formula: { "needs-formula" => ["depends on `docker`, which is in this run"] },
                             cask:    { "needs-cask" => ["depends on the `docker` cask, which is in this run"] })
      end
    end

    describe "casks with the same token from different taps" do
      it "skips, without a terminal, only the casks that need the skipped one by its full name" do
        other = Cask::Cask.new("sudo-app", tap: Tap.fetch("user", "tap")) do
          T.bind(self, Cask::DSL)
          version "1.0"
          sha256 :no_check
          url "file:///dev/null"
        end
        stub_cask_loader(other, "user/tap/sudo-app")
        casks = [stub_cask("sudo-app", nil, stanzas: 'pkg "Sudo.pkg"'),
                 stub_cask("other-tap-app", nil, stanzas: 'depends_on cask: "user/tap/sudo-app"'),
                 stub_cask("same-tap-app", nil, stanzas: 'depends_on cask: "sudo-app"')]
        result = described_class.cask_plan({ install: casks }, in_run: [], facts: Timed::Casks::DiskFacts.new,
                                                               tty: -> { false })
        expect({ first:   result.first.map { |entry| entry.cask.full_name },
                 skipped: result.skipped.map { |entry| entry.cask.full_name } })
          .to eq(first: %w[other-tap-app], skipped: %w[sudo-app same-tap-app])
      end

      it "classifies each on its own needs" do
        stub_lib_and_app
        tap_foo = Cask::Cask.new("foo", tap: Tap.fetch("user", "tap")) do
          T.bind(self, Cask::DSL)
          version "1.0"
          sha256 :no_check
          url "file:///dev/null"
        end
        casks = [stub_cask("foo", nil, stanzas: 'depends_on formula: "lib"'), tap_foo]
        result = described_class.cask_plan({ install: casks }, in_run: %w[lib], facts: Timed::Casks::DiskFacts.new,
                                                               tty: -> { true })
        expect([result.first.map { |entry| entry.cask.full_name }, result.last.map { |entry| entry.cask.full_name }])
          .to eq([%w[user/tap/foo], %w[foo]])
      end
    end

    describe "matching casks' needs with the run" do
      it "matches a formula a cask needs by its full name, after aliases, and by name only if it can't be " \
         "loaded, so a formula of the same name in another tap doesn't count" do
        stub_two_foos
        casks = { "tap"     => stub_cask("tap-app", nil, stanzas: 'depends_on formula: "user/tap/foo"'),
                  "alias"   => stub_cask("alias-app", nil, stanzas: 'depends_on formula: "foo-alias"'),
                  "missing" => stub_cask("gone-app", nil, stanzas: 'depends_on formula: "gone/tap/foo"') }
        placed = [%w[foo], %w[user/tap/foo]].to_h do |in_run|
          result = described_class.cask_plan({ install: casks.values }, in_run:, facts: Timed::Casks::DiskFacts.new,
                                                                        tty: -> { true })
          [in_run, result.last.to_h { |entry| [entry.cask.token, entry.reasons.map(&:message)] }]
        end
        expect(placed).to eq(
          %w[foo]          => { "alias-app" => ["depends on `foo`, which is in this run"],
                                "gone-app"  => ["depends on `foo`, which is in this run"] },
          %w[user/tap/foo] => { "tap-app"  => ["depends on `user/tap/foo`, which is in this run"],
                                "gone-app" => ["depends on `user/tap/foo`, which is in this run"] },
        )
      end

      it "holds back a cask only for the formula it needs that didn't install, by full name" do
        stub_two_foos
        casks = [stub_cask("tap-app", nil, stanzas: 'depends_on formula: "user/tap/foo"')]
        kept = [%w[foo], %w[user/tap/foo]].to_h do |unfinished|
          kept_casks = described_class.last_casks("install", casks, named: [], flags: [], unfinished:, run: timed_run)
          [unfinished, kept_casks]
        end
        expect(kept).to eq(%w[foo] => %w[tap-app], %w[user/tap/foo] => [])
      end
    end

    describe ".cask_plan's needs" do
      it "puts a cask whose download needs a formula in the run to unpack last, and holds it back when that " \
         "formula didn't install and isn't installed", :aggregate_failures do
        stub_xz
        cask = stub_cask("xz-app", nil, url: "https://brew.sh/xz-app.xz")
        result = described_class.cask_plan({ install: [cask] }, in_run: %w[xz], facts: Timed::Casks::DiskFacts.new,
                                                                tty: -> { true })
        expect(result.last.map { |entry| entry.reasons.map(&:message) })
          .to eq([["depends on `xz`, which is in this run"]])
        expect do
          described_class.last_casks("install", [cask], named: [], flags: [], unfinished: %w[xz], run: timed_run)
        end.to output(/^xz-app: needs xz$/).to_stderr
      end

      it "puts a cask last when it needs a formula brew installs for one in the run, saying for which" do
        stub_lib_and_app
        cask = stub_cask("lib-app", nil, stanzas: 'depends_on formula: "lib"')
        result = described_class.cask_plan({ install: [cask] }, in_run:           %w[app],
                                                                run_dependencies: { "app" => %w[lib] },
                                                                facts:            Timed::Casks::DiskFacts.new,
                                                                tty:              -> { true })
        expect(result.last.map { |entry| entry.reasons.map(&:message) })
          .to eq([["depends on `lib`, which this run installs for `app`"]])
      end

      it "takes what brew installs in each formula's call from its installer, and nothing with " \
         "`--ignore-dependencies`" do
        stub_lib_and_app
        app = Formulary.factory("app")
        dependencies = [false, true].to_h do |ignore_deps|
          [ignore_deps, described_class.run_dependencies([FormulaInstaller.new(app, ignore_deps:)])]
        end
        expect(dependencies).to eq(false => { "app" => %w[lib] }, true => { "app" => [] })
      end

      it "takes every dependency that loads, by full name, when brew can't work out what it installs" do
        stub_lib_and_app
        broken = formula("broken") do
          T.bind(self, T.class_of(Formula))
          url "https://brew.sh/broken-1.0.tgz"
          depends_on "app"
          depends_on "gone"
        end
        expect(described_class.run_dependencies([FormulaInstaller.new(broken)])).to eq("broken" => %w[lib app])
      end

      it "holds back a last cask for what brew would have installed for a formula that didn't install" do
        stub_lib_and_app
        cask = stub_cask("lib-app", nil, stanzas: 'depends_on formula: "lib"')
        expect do
          described_class.last_casks("install", [cask], named: [], flags: [], unfinished: %w[app],
                                                        run_dependencies: { "app" => %w[lib] }, run: timed_run)
        end.to output(/^lib-app: needs lib$/).to_stderr
      end

      it "puts a cask last when what it needs through its formulae's dependencies or other casks is in the run" do
        stub_lib_and_app
        stub_cask("dep-app", nil, stanzas: 'depends_on formula: "app"')
        casks = [stub_cask("via-formula", nil, stanzas: 'depends_on formula: "app"'),
                 stub_cask("via-cask", nil, stanzas: 'depends_on cask: "dep-app"')]
        result = described_class.cask_plan({ install: casks }, in_run: %w[lib], facts: Timed::Casks::DiskFacts.new,
                                                               tty: -> { true })
        expect(result.last.to_h { |entry| [entry.cask.token, entry.reasons.map(&:message)] })
          .to eq("via-formula" => ["depends on `lib`, which is in this run"],
                 "via-cask"    => ["depends on `lib`, which is in this run"])
      end

      it "counts what the cask dependencies brew would install need, but no cask dependency with " \
         "`--skip-cask-deps`, though the formulae those need still count, as brew installs them anyway" do
        stub_lib_and_app
        stub_cask("helper", nil, stanzas: "pkg \"Helper.pkg\"\ndepends_on formula: \"app\"")
        stub_cask("old", installed_stanzas: "")
        casks = { install: [stub_cask("needs-helper", nil, stanzas: 'depends_on cask: "helper"'),
                            stub_cask("needs-old", nil, stanzas: 'depends_on cask: "old"')],
                  upgrade: [stub_cask("old", installed_stanzas: "")] }
        placed = [false, true].to_h do |skip_cask_deps|
          result = described_class.cask_plan(casks, in_run: %w[lib], skip_cask_deps:,
                                                    facts: Timed::Casks::DiskFacts.new, tty: -> { true })
          entries = result.first + result.last
          [skip_cask_deps, entries.to_h { |entry| [entry.cask.token, entry.reasons.map(&:message)] }]
        end
        expect(placed).to eq(
          false => { "old"          => [],
                     "needs-helper" => ["depends on `lib`, which is in this run",
                                        "dependency `helper`: `pkg` requires sudo"],
                     "needs-old"    => ["depends on the `old` cask, which is in this run"] },
          true  => { "old" => [], "needs-helper" => ["depends on `lib`, which is in this run"], "needs-old" => [] },
        )
      end

      it "skips, without a terminal, the casks that need a skipped one, by name for a cask that can't be " \
         "loaded, but not for a formula, nor with `--skip-cask-deps`, as brew installs no cask dependency then" do
        casks = [stub_cask("sudo-app", nil, stanzas: 'pkg "Sudo.pkg"'),
                 stub_cask("needs-sudo", nil, stanzas: 'depends_on cask: "sudo-app"'),
                 stub_cask("needs-gone-cask", nil, stanzas: 'depends_on cask: "gone/tap/sudo-app"'),
                 stub_cask("needs-gone-formula", nil, stanzas: 'depends_on formula: "gone/tap/sudo-app"')]
        skipped = [false, true].to_h do |skip_cask_deps|
          result = described_class.cask_plan({ install: casks }, in_run: [], skip_cask_deps:,
                                                                 facts:  Timed::Casks::DiskFacts.new,
                                                                 tty:    -> { false })
          [skip_cask_deps, result.skipped.map { |entry| entry.cask.token }]
        end
        expect(skipped).to eq(false => %w[sudo-app needs-sudo needs-gone-cask], true => %w[sudo-app])
      end
    end

    describe ".cask_needs" do
      it "follows another tap's cask with the same token as the cask, by full name, but not the cask itself" do
        stub_lib_and_app
        other = Cask::Cask.new("foo", tap: Tap.fetch("user", "tap")) do
          T.bind(self, Cask::DSL)
          version "1.0"
          sha256 :no_check
          url "file:///dev/null"
          depends_on formula: "lib"
        end
        stub_cask_loader(other, "user/tap/foo")
        cask = stub_cask("foo", nil, stanzas: 'depends_on cask: ["user/tap/foo", "foo"]')
        needs = described_class.cask_needs(cask)
        expect([needs.casks.map(&:full_name), needs.formulae]).to eq([%w[user/tap/foo], %w[lib]])
      end

      it "follows casks through a cycle once and takes one it can't load, missing or invalid, by its name" do
        allow(Cask::CaskLoader).to receive(:load).and_call_original
        allow(Cask::CaskLoader).to receive(:load).with("bad-app", any_args)
                                                 .and_raise(Cask::CaskInvalidError.new("bad-app", "nope"))
        stub_cask("loop-b", nil, stanzas: 'depends_on cask: ["loop-a", "gone-app", "bad-app"]')
        loop_a = stub_cask("loop-a", nil, stanzas: 'depends_on cask: "loop-b"')
        needs = described_class.cask_needs(loop_a)
        expect([needs.formulae, needs.casks.map(&:token), needs.unresolved_casks])
          .to eq([[], %w[loop-b], %w[gone-app bad-app]])
      end

      it "adds what brew needs to unpack the download, by its container type, its cached file or its " \
         "extension as brew reads it, without downloading, and nothing if that can't be worked out" do
        stub_xz
        cached = stub_cask("cached-app", nil, url: "https://brew.sh/cached-app")
        cached_file = Cask::Download.new(cached).cached_download
        cached_file.dirname.mkpath
        cached_file.binwrite("\xFD7zXZ\x00rest".b)
        casks = { "type"    => stub_cask("typed-app", nil, stanzas: "container type: :xz"),
                  "cached"  => cached,
                  "xz"      => stub_cask("xz-app", nil, url: "https://brew.sh/xz-app.xz?download=1"),
                  "tarball" => stub_cask("tar-app", nil, url: "https://brew.sh/tar-app.tar.xz"),
                  "plain"   => stub_cask("plain-app", nil, url: "https://brew.sh/plain-app.zip") }
        casks["dependency"] = stub_cask("via-app", nil, stanzas: 'depends_on cask: "typed-app"',
                                                        url:     "https://brew.sh/via-app.zip")
        expect(casks.transform_values { |cask| described_class.cask_needs(cask).formulae })
          .to eq("type" => %w[xz], "cached" => %w[xz], "xz" => %w[xz], "tarball" => [], "plain" => [],
                 "dependency" => %w[xz])
      end

      it "adds nothing for the download when working out its container fails" do
        cask = stub_cask("typed-app", nil, stanzas: "container type: :xz")
        allow(UnpackStrategy).to receive(:from_type).and_raise(RuntimeError, "boom")
        expect(described_class.cask_needs(cask).formulae).to eq([])
      end

      it "follows formulae through their runtime dependencies only, as brew does, and the casks they require" do
        allow(Formulary).to receive(:loader_for).and_call_original
        { "lib" => {}, "tool" => {}, "app" => { "lib" => [], "tool" => [:build] } }.each do |name, deps|
          stub_formula_loader(formula(name) do
            T.bind(self, T.class_of(Formula))
            url "https://brew.sh/#{name}-1.0.tgz"
            deps.each { |dep, tags| depends_on dep => tags }
          end)
        end
        needs = described_class.cask_needs(stub_cask("needs-app", nil, stanzas: 'depends_on formula: "app"'))
        expect([needs.formulae, needs.casks]).to eq([%w[app lib], []])
      end
    end

    describe ".last_casks" do
      it "leaves out, with one warning, the casks that need a formula brew didn't install and isn't installed, " \
         "directly, through their formulae or through other casks, as brew would install it for them without " \
         "the options given for it, with the run's command to finish that first", :aggregate_failures do
        stub_lib_and_app
        stub_cask("dep-app", nil, stanzas: 'depends_on formula: "lib"')
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "lib"'),
                 stub_cask("through-app", nil, stanzas: 'depends_on formula: "app"'),
                 stub_cask("via-cask", nil, stanzas: 'depends_on cask: "dep-app"'), stub_cask("free-app", nil)]
        run = timed_run({ "lib" => "lib", "other" => "other" }, { "lib" => [], "other" => [] })
        kept = T.let(nil, T.nilable(T::Array[String]))
        expect do
          kept = described_class.last_casks("install", casks, named: [], flags: %w[--force], unfinished: %w[lib],
                                                              run:)
        end.to output(<<~EOS).to_stderr
          Warning: Not installing 3 casks, which need formulae that didn't install and aren't installed:
          direct-app: needs lib
          through-app: needs lib
          via-cask: needs lib
          Finish those first with `brew install-timed --build-from-source lib`, then install them with `brew install --cask --force direct-app through-app via-cask`.
        EOS
        expect(kept).to eq(%w[free-app])
      end

      it "names no command for what a cask needs when no formula given to the run brings it in" do
        stub_lib_and_app
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "lib"')]
        expect do
          described_class.last_casks("upgrade", casks, named: [], flags: [], unfinished: %w[lib], run: timed_run)
        end.to output(<<~EOS).to_stderr
          Warning: Not upgrading 1 cask, which needs formulae that didn't upgrade and aren't installed:
          direct-app: needs lib
          Once those are installed, upgrade it with `brew upgrade --cask direct-app`.
        EOS
      end

      it "keeps a cask that needs a formula brew didn't upgrade but left installed, as brew won't touch it" do
        stub_lib_and_app(installed_lib: true)
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "lib"')]
        expect do
          described_class.last_casks("upgrade", casks, named: [], flags: [], unfinished: %w[lib], run: timed_run)
        end.not_to output.to_stderr
      end

      it "takes a formula it can't load, e.g. from a tap that isn't trusted, as needed by name only" do
        allow(Formulary).to receive(:factory).and_call_original
        allow(Formulary).to receive(:factory).with("user/tap/evil").and_raise(Homebrew::UntrustedTapError, "no")
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "user/tap/evil"')]
        expect(described_class.last_casks("upgrade", casks, named: [], flags: [], unfinished: [], run: timed_run))
          .to eq(%w[direct-app])
      end

      it "doesn't take a cask it can't load as a formula of the same name that didn't install" do
        casks = [stub_cask("gone-dep-app", nil, stanzas: 'depends_on cask: "gone/tap/foo"')]
        expect do
          described_class.last_casks("install", casks, named: [], flags: [], unfinished: %w[foo], run: timed_run)
        end.not_to output.to_stderr
      end
    end

    describe ".later" do
      it "shell-escapes every argument of the command, e.g. a path or flag value with a space, but not an " \
         "option's `=`, which needs none" do
        dir = mktmpdir/"My Casks"
        dir.mkpath
        (dir/"foo.rb").write(cask_source("foo", "2.0"))
        Dir.chdir(dir) do
          casks = [Cask::CaskLoader.load("foo.rb")]
          command = described_class.later("install", casks, named: %w[foo.rb], flags: ["--appdir=/My Apps"])
          expect(command).to eq("Install it later with `brew install --cask --appdir=/My\\ Apps " \
                                "#{(dir/"foo.rb").realpath.to_s.gsub(" ", "\\ ")}`.")
        end
      end
    end

    describe ".before_last_casks" do
      let(:run) { Timed::Command::Run.new(command: %w[install-timed], roots: { "app" => "app" }, needs: {}) }

      it "returns what running the formulae, given the calls after them, returns" do
        casks = [stub_cask("iterm2", nil)]
        calls = [instance_double(Timed::Runner::After)]
        returned = described_class.before_last_casks("upgrade", casks, named: [], flags: [], run:,
                                                                      after: -> { calls }) do |after|
          [after, :outcome]
        end
        expect(returned).to eq([calls, :outcome])
      end

      it "names the casks to run after the formulae, with how to run them later, when Ctrl-C stops the formulae, " \
         "and stops too" do
        casks = [stub_cask("iterm2", nil), stub_cask("firefox", nil)]
        expect do
          described_class.before_last_casks("install", casks, named: [], flags: %w[--force], run:) { raise Interrupt }
        end.to raise_error(Interrupt).and output(<<~EOS).to_stderr
          Warning: Interrupted, so the casks to install after the formulae didn't run: iterm2 firefox
          Install them later with `brew install --cask --force iterm2 firefox`.
        EOS
      end

      it "says the batches didn't run when Ctrl-C stops working out the calls after them, before the batches" do
        interrupt = -> { raise Interrupt }
        expect do
          described_class.before_last_casks("install", [], named: [], flags: [], run:, after: interrupt) do
            raise "the batches ran"
          end
        end.to raise_error(Interrupt).and output("Warning: Interrupted, so the batches didn't run.\n").to_stderr
      end

      it "says nothing more on Ctrl-C without such casks" do
        expect do
          described_class.before_last_casks("install", [], named: [], flags: [], run:) { raise Interrupt }
        end.to raise_error(Interrupt).and not_to_output.to_stderr
      end
    end

    describe ".casks_not_run" do
      it "names a cask's formulae of the run that aren't installed, with the run's command for the formulae that " \
         "bring them in, to run first, as brew's cask installer would install them otherwise, and the other casks " \
         "with the plain command" do
        stub_lib_and_app
        casks = [stub_cask("lib-app", nil, stanzas: 'depends_on formula: "lib"'), stub_cask("free-app", nil)]
        run = Timed::Command::Run.new(command: %w[install-timed --build-from-source],
                                      roots:   { "app" => "/My Formulae/app.rb", "other" => "other" },
                                      needs:   { "app" => %w[lib], "other" => [] })
        expect do
          described_class.casks_not_run("Interrupted", "install", casks, named: [], flags: %w[--force], run:)
        end.to output(<<~EOS).to_stderr
          Warning: Interrupted, so the casks to install after the formulae didn't run: lib-app free-app
          1 cask needs formulae of this run that aren't installed, which brew would
          install for it, but not as this run would:
          lib-app: needs lib
          Finish those first with `brew install-timed --build-from-source /My\\ Formulae/app.rb`, then install it with `brew install --cask --force lib-app`.
          Install the other later with `brew install --cask --force free-app`.
        EOS
      end

      it "escapes an argument with `=` that isn't an option whole, leaving only an option's `=` as it is" do
        stub_lib_and_app
        casks = [stub_cask("lib-app", nil, stanzas: 'depends_on formula: "lib"')]
        run = Timed::Command::Run.new(command: %w[install-timed --exclude=x], roots: { "app" => "/f/a=b.rb" },
                                      needs: { "app" => %w[lib] })
        expect do
          described_class.casks_not_run("Interrupted", "install", casks, named: [], flags: [], run:)
        end.to output(%r{^Finish those first with `brew install-timed --exclude=x /f/a\\=b\.rb`, }).to_stderr
      end

      it "gives the plain command for a cask whose formulae of the run are installed and linked into `opt`" do
        stub_lib_and_app(installed_lib: true)
        casks = [stub_cask("lib-app", nil, stanzas: 'depends_on formula: "lib"')]
        run = Timed::Command::Run.new(command: %w[upgrade-timed], roots: { "app" => "app" },
                                      needs: { "app" => %w[lib] })
        expect do
          described_class.casks_not_run("`brew upgrade` stopped early", "upgrade", casks, named: [], flags: [], run:)
        end.to output(<<~EOS).to_stderr
          Warning: `brew upgrade` stopped early, so the cask to upgrade after the formulae didn't run: lib-app
          Upgrade it later with `brew upgrade --cask lib-app`.
        EOS
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

  describe ".dependent_flags" do
    it "keeps the forwarded formula flags brew gives the outdated dependents it upgrades, which `brew upgrade` " \
       "takes" do
      options = %w[--verbose --force --build-from-source --keep-tmp --debug-symbols --force-bottle --overwrite
                   --display-times --fetch-HEAD --quiet --debug --as-dependency --cc=clang --with-foo]
      expect(described_class.dependent_flags(options))
        .to eq(%w[--verbose --force --keep-tmp --force-bottle --quiet --debug])
    end
  end

  describe "the calls after the batches" do
    let(:args) { described_class.builtin("upgrade").new(%w[--keep-tmp]).args }
    let(:flags) { %w[--keep-tmp --force-bottle --build-from-source --debug-symbols --verbose] }
    let(:receipt) { JSON.parse((Pathname(__FILE__).dirname.parent/"fixtures/receipts/built.json").read) }

    def after(dependents = [], checked = [], excluded: [], own: [])
      calls = described_class.after(dependents, checked, args:, flags:, excluded:, own:)
      calls || raise("no calls after the batches")
    end

    before { allow(Formulary).to receive(:loader_for).and_call_original }

    # A formula at 2.0 needing `deps`, from `tap` if given, loadable by its
    # full name, with `installed` in the Cellar (from `tap` as its receipt
    # says, built from source unless `poured`) and linked into `opt` (neither
    # when nil).
    def stub_formula(name, installed = nil, tap: nil, poured: false, deps: [])
      stub = formula(name, tap:) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/#{name}-2.0.tgz"
        deps.each { |dep| depends_on dep }
      end
      stub_formula_loader(stub)
      if installed
        keg = HOMEBREW_CELLAR/name/installed
        keg.mkpath
        source = receipt.fetch("source").merge("tap" => tap&.name || "homebrew/core")
        (keg/AbstractTab::FILENAME).write(JSON.generate(receipt.merge("source"             => source,
                                                                      "poured_from_bottle" => poured)))
        (HOMEBREW_PREFIX/"opt").mkpath
        FileUtils.ln_sf keg, HOMEBREW_PREFIX/"opt"/name
      end
      stub
    end

    it "makes none, leaving the check to brew, when the user has turned it off, as brew then does neither" do
      ENV["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
      expect(described_class.after([], [], args:, flags:, excluded: [], own: [])).to be_nil
    end

    describe "the outdated dependents' call" do
      it "upgrades with the flags brew gives them those brew's bottle check keeps, checking those still outdated " \
         "again once the batches are done, as brew does, and finishes them with `brew upgrade-timed` and the run's " \
         "`--exclude`, so brew's own check there leaves excluded outdated dependents alone", :aggregate_failures do
        lib = stub_formula("lib")
        dependents = %w[user other done].map { |name| stub_formula(name, "1.0") }
        installers = dependents.map { |dependent| instance_double(FormulaInstaller, formula: dependent) }
        expect(Homebrew::Upgrade).to receive(:dependent_formula_installers)
          .with(having_attributes(upgradeable: dependents), [lib], hash_including(keep_tmp: true))
          .and_return(installers)
        call = after(dependents, [lib], excluded: %w[gone], own: %w[--exclude=gone --no-stamp-receipts]).fetch(0)
        FileUtils.touch (HOMEBREW_CELLAR/"done/2.0").tap(&:mkpath)/"file"
        expect(Homebrew::Upgrade).to receive(:filter_dependent_formula_installers)
          .with(installers.take(2)).and_return(installers.take(1))
        app = stub_formula("app", deps: %w[lib])
        expect([call.label, call.verb, call.flags, call.candidates, call.choose.call({}, []), call.deps.call(app),
                call.finish.call(%w[user])])
          .to eq(["dependents", "upgrade", %w[--keep-tmp --force-bottle --verbose], dependents, dependents.take(1),
                  %w[lib], "brew upgrade-timed --exclude=gone --no-stamp-receipts user"])
      end

      it "finishes one given to `--exclude` without `--exclude`, which would leave it out" do
        stub_formula("user", "1.0")
        own = %w[--exclude=user --no-stamp-receipts]
        expect(after(excluded: %w[user], own:).fetch(0).finish.call(%w[user]))
          .to eq("brew upgrade-timed --no-stamp-receipts user")
      end

      it "keeps in `--exclude` one it can no longer load, e.g. from a tap untrusted during the run" do
        stub_formula("user", "1.0")
        allow(Formulary).to receive(:factory).and_call_original
        allow(Formulary).to receive(:factory).with("user/tap/evil")
                                             .and_raise(Homebrew::UntrustedTapError, "untrusted")
        own = %w[--exclude=user/tap/evil,user]
        expect(after(excluded: %w[user/tap/evil user], own:).fetch(0).finish.call(%w[user]))
          .to eq("brew upgrade-timed --exclude=user/tap/evil user")
      end

      it "doesn't ask brew's bottle check about no dependents" do
        expect(Homebrew::Upgrade).not_to receive(:dependent_formula_installers)
        expect(Homebrew::Upgrade).not_to receive(:filter_dependent_formula_installers)
        expect(after.fetch(0).choose.call({}, [])).to eq([])
      end
    end

    describe "the broken dependents' call" do
      let(:call) { after(excluded: %w[left], own: %w[--exclude=left]).fetch(1) }

      it "reinstalls from source with the flags brew gives them, after what each needs", :aggregate_failures do
        stub_formula("lib")
        app = stub_formula("app", deps: %w[lib])
        expect([call.label, call.verb, call.flags, call.candidates, call.deps.call(app)])
          .to eq(["linkage", "reinstall", %w[--build-from-source --keep-tmp --debug-symbols --verbose], nil, %w[lib]])
      end

      it "finishes them with brew's own installed-dependents check off, as the run's call has it, saying so" do
        expect(call.finish.call(%w[lib app]))
          .to eq("HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source lib app\n" \
                 "The reinstall skips Homebrew's installed-dependents check, as this run's own call did.")
      end

      it "checks all the dependents of the formulae the run installed, from the tap their receipts name, but " \
         "only those built from source of core bottles, which brew takes as checked", :aggregate_failures do
        stub_formula("poured", "2.0")
        stub_formula("built", "2.0")
        stub_formula("clash")
        stub_formula("clash", "2.0", tap: Tap.fetch("user", "tap"))
        expect(described_class).to receive(:dependents_to_check)
          .with(contain_exactly(having_attributes(full_name: "built"),
                                having_attributes(full_name: "user/tap/clash")),
                poured: [having_attributes(full_name: "poured")])
          .and_return([])
        expect(described_class).to receive(:broken_dependents).with([]).and_return([])
        installed = { "poured" => "poured", "built" => "built", "clash" => "poured" }
        expect { call.choose.call(installed, []) }
          .to output("==> Checking for dependents of upgraded formulae...\n==> No broken dependents found!\n")
          .to_stdout
      end

      it "names a formula it can't load, e.g. in several taps or from a tap that isn't trusted, with how to " \
         "reinstall its dependents from the tap its receipt names, where it finds them and can, and checks the rest",
         :aggregate_failures do
        tapped = stub_formula("tapped", "2.0", tap: Tap.fetch("user", "tap"))
        stub_formula("twice", "1.0", tap: Tap.fetch("user", "a"))
        needing = ->(full_name) { instance_double(Keg, runtime_dependencies: [{ "full_name" => full_name }]) }
        dependents = { "user" => "user/a/twice", "other" => "user/b/twice", "held" => "user/a/twice" }
                     .to_h do |name, needs|
          dependent = stub_formula(name, "2.0")
          allow(dependent).to receive(:any_installed_keg).and_return(needing.call(needs))
          [name, dependent]
        end
        allow(dependents.fetch("held")).to receive(:pinned?).and_return(true)
        allow(Formula).to receive(:installed).and_return([*dependents.values, tapped])
        allow(Formulary).to receive(:from_rack).and_call_original
        allow(Formulary).to receive(:from_rack).with(HOMEBREW_CELLAR/"twice")
                                               .and_raise(TapFormulaAmbiguityError.new("twice", []))
        allow(Formulary).to receive(:from_rack).with(HOMEBREW_CELLAR/"gone")
                                               .and_raise(Homebrew::UntrustedTapError, "untrusted")
        expect(described_class).to receive(:dependents_to_check)
          .with([having_attributes(full_name: "user/tap/tapped")], poured: []).and_return([])
        allow(described_class).to receive(:broken_dependents).and_return([])
        warnings = []
        allow(described_class).to receive(:opoo) { |warning| warnings << warning }
        call.choose.call({ "twice" => "poured", "gone" => "built", "tapped" => "poured" }, [])
        expect(warnings.map { |warning| warning.sub(/(?<=linkage): .*?(?=\nTo check them|\z)/m, ": …") })
          .to eq(["Couldn't check the dependents of twice for broken linkage: …\n" \
                  "To check them, reinstall them from source:\n  " \
                  "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source user\n" \
                  "The reinstall skips Homebrew's installed-dependents check, as this run's own call did.\n" \
                  "Not counting held, which is pinned, outdated, left out of the run or needs what this run " \
                  "didn't install.",
                  "Couldn't check the dependents of gone for broken linkage: …"])
      end

      it "says which dependents it hadn't checked when Ctrl-C stops the check" do
        stub_formula("built", "2.0")
        allow(described_class).to receive(:dependents_to_check).and_return([])
        allow(described_class).to receive(:broken_dependents).and_raise(Interrupt)
        expect { call.choose.call({ "built" => "built" }, []) }
          .to raise_error(Interrupt)
          .and output("Warning: The check for broken linkage didn't finish; not all the dependents of built " \
                      "were checked.\n").to_stderr
      end

      it "checks nothing when the run installed nothing" do
        expect(described_class).not_to receive(:broken_dependents)
        expect { call.choose.call({}, []) }.not_to output.to_stdout
      end

      it "reinstalls the broken dependents dependencies first, but not pinned or outdated ones or those the run " \
         "failed, skipped or left out, naming each kind with the command to fix it", :aggregate_failures do
        stub_formula("built", "2.0")
        good = stub_formula("good", "2.0")
        base = stub_formula("base", "2.0")
        allow(good).to receive(:any_installed_keg)
          .and_return(instance_double(Keg, runtime_dependencies: [{ "full_name" => "base", "version" => "2.0" }]))
        pinned = stub_formula("pinned", "2.0")
        allow(pinned).to receive(:pinned?).and_return(true)
        # `brew reinstall` would install 2.0, from source, losing the pin.
        held = stub_formula("held", "1.0")
        allow(held).to receive(:pinned?).and_return(true)
        outdated = stub_formula("outdated", "1.0")
        failed = stub_formula("failed", "2.0")
        left = stub_formula("left", "2.0")
        needy = stub_formula("needy", "2.0", deps: %w[failed])
        stale = stub_formula("stale", "1.0", deps: %w[failed])
        # Outdated, but planned for a batch Ctrl-C stopped, perhaps to build
        # from source, so `brew upgrade` won't do.
        late = stub_formula("late", "1.0")
        allow(described_class).to receive_messages(
          dependents_to_check: [],
          broken_dependents:   [good, pinned, held, outdated, failed, left, base, needy, stale, late],
        )
        chosen = T.let([], T::Array[Formula])
        skips = "The reinstall skips Homebrew's installed-dependents check, as this run's own call did."
        expect { chosen = call.choose.call({ "built" => "built" }, %w[failed late]) }.to output(<<~EOS).to_stderr
          Warning: Not reinstalling 2 dependents with broken linkage, as they need what this run didn't install: needy (needs failed), stale (needs failed)
          Once that installs, run:
            HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source needy
            brew upgrade-timed --exclude=left stale
          #{skips}
          Error: Not reinstalling 2 pinned dependents with broken linkage: pinned held
          Once unpinned, reinstall with:
            HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source pinned
          Once unpinned, upgrade, which reinstalls, with:
            brew upgrade-timed --exclude=left held
          #{skips}
          Warning: Not reinstalling 1 outdated dependent with broken linkage: outdated
          Upgrade, which reinstalls, with:
            brew upgrade-timed --exclude=left outdated
          Warning: Not reinstalling 1 dependent with broken linkage given to `--exclude`: left
          Reinstall with:
            HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source left
          #{skips}
          Warning: Not reinstalling 2 dependents with broken linkage that this run didn't finish: failed late
          Once they install, reinstall with:
            HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source failed late
          #{skips}
        EOS
        expect(chosen).to eq([base, good])
      end

      it "drops from the `--exclude` of an upgrade command the outdated, or pinned and outdated, broken dependent " \
         "it names, which that would leave out, keeping the rest" do
        stub_formula("built", "2.0")
        stub_formula("other")
        outdated = stub_formula("outdated", "1.0")
        held = stub_formula("held", "1.0")
        allow(held).to receive(:pinned?).and_return(true)
        allow(described_class).to receive_messages(dependents_to_check: [], broken_dependents: [outdated, held])
        excluded = after(excluded: %w[outdated held other], own: %w[--exclude=outdated,held,other]).fetch(1)
        expect { excluded.choose.call({ "built" => "built" }, []) }.to output(<<~EOS).to_stderr
          Error: Not reinstalling 1 pinned dependent with broken linkage: held
          Once unpinned, upgrade, which reinstalls, with:
            brew upgrade-timed --exclude=outdated,other held
          Warning: Not reinstalling 1 outdated dependent with broken linkage: outdated
          Upgrade, which reinstalls, with:
            brew upgrade-timed --exclude=held,other outdated
        EOS
      end
    end

    it "takes every installed dependent of some formulae, but only those built from source of others" do
      lib = stub_formula("lib")
      core = stub_formula("core")
      dependents = { "any" => false, "built" => false, "poured" => true }
                   .to_h { |name, poured| [name, stub_formula(name, "2.0", poured:)] }
      allow(lib).to receive(:runtime_installed_formula_dependents).and_return([dependents.fetch("any")])
      allow(core).to receive(:runtime_installed_formula_dependents)
        .and_return(dependents.values_at("built", "poured", "any"))
      expect(described_class.dependents_to_check([lib], poured: [core]).map(&:name)).to eq(%w[any built])
    end

    it "finds the installed dependents with broken library linkage, as brew does after upgrading dependents" do
      ok = stub_formula("ok", "2.0")
      broken = stub_formula("broken", "2.0")
      allow(LinkageChecker).to receive(:new) do |keg, cache_db:|
        instance_double(LinkageChecker,
                        broken_library_linkage?: keg.name == "broken" && cache_db.is_a?(CacheStoreDatabase))
      end
      expect(described_class.broken_dependents([ok, broken, stub_formula("gone")])).to eq([broken])
    end
  end

  describe ".dependency_names" do
    it "gives each formula a formula needs by its full name, even one a tap formula names by its short name" do
      tap = Tap.fetch("user", "tap")
      lib = formula("lib", tap:) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/lib-1.0.tgz"
      end
      app = formula("app", tap:) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/app-1.0.tgz"
        depends_on "lib"
      end
      allow(Formulary).to receive(:loader_for).and_call_original
      stub_formula_loader(lib)
      stub_formula_loader(lib, "lib")
      expect(described_class.dependency_names(app)).to eq(%w[user/tap/lib])
    end

    it "leaves out a dependency it can't load from a tap that isn't trusted, as one that can't be found" do
      app = formula("app") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/app-1.0.tgz"
        depends_on "user/tap/evil"
      end
      allow(Formulary).to receive(:factory).and_call_original
      allow(Formulary).to receive(:factory).with("user/tap/evil", warn: false)
                                           .and_raise(Homebrew::UntrustedTapError, "untrusted")
      expect(described_class.dependency_names(app)).to eq([])
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
      [estimate.seconds.round(1), estimate.fallback, estimate.guessed]
    end

    it "uses history of the same kind only, ignoring `--guess`, with the chosen estimator" do
      estimates = [estimate("llvm", pour: false, guesses: { "llvm" => 1.0 }),
                   estimate("llvm", pour: false, estimator: :median), estimate("wget", pour: true)]
      expect(estimates).to eq([[696.9, false, false], [200.0, false, false], [4.0, false, false]])
    end

    it "uses `--guess` for a source build without history, marked as guessed" do
      expect(estimate("wget", pour: false, guesses: { "wget" => 90.0 })).to eq([90.0, false, true])
    end

    it "falls back to the log's estimate of that kind otherwise, marked as a fallback" do
      expect([estimate("go", pour: false), estimate("llvm", pour: true, guesses: { "llvm" => 1.0 })])
        .to eq([[300.0, true, false], [6.0, true, false]])
    end
  end

  describe ".estimates" do
    let(:database) { mktmpdir/"build-log.json" }
    let(:llm) do
      Timed::LLM.settings(url: "http://127.0.0.1:11434/v1/chat/completions", model: "qwen2.5:7b",
                          resolver: ->(_host) { ["127.0.0.1"] })
    end
    let(:machine) { { "cpu" => "x86_64 kabylake", "cores" => 8, "memory_gb" => 32, "os" => "macOS 15.7" } }
    let(:requests) { [] }

    # `history` has a source build, `cached` an LLM estimate of version 1.0
    # and `stale` one of another version.
    before do
      database.write(JSON.generate(
                       "schema_version" => 1,
                       "packages"       => { "history" => { "builds" => [{ "status" => "built", "version" => "0.9",
                                                                           "install_seconds" => 30.0 }] } },
                       "estimates"      => { "cached" => { "version" => "1.0", "seconds" => 600, "model" => "old",
                                                           "date" => "2026-10-01" },
                                             "stale"  => { "version" => "0.9", "seconds" => 60, "model" => "old",
                                                           "date" => "2026-10-01" } },
                     ))
    end

    # Formulae at `version`: `history`, `guessed` (given to `--guess`),
    # `poured` (a pour), `cached`, `stale` and `new`; the LLM answers with
    # `answers` (by name), as OpenAI does, or raises it. `exclude` is
    # `--exclude`'s.
    def estimates(answers: { "stale" => 120, "new" => 7200 }, llm: self.llm, version: "1.0", exclude: [])
      formulae = %w[history guessed poured cached stale new].to_h do |name|
        [name, formula(name) do
          T.bind(self, T.class_of(Formula))
          url "https://brew.sh/#{name}-#{version}.tgz"
          desc "The #{name} formula"
          depends_on "cmake" => :build
          depends_on "zlib"
        end]
      end
      allow(described_class).to receive(:machine).and_return(machine)
      allow(Timed::LLM).to receive(:post) do |request, _timeout|
        requests << request
        raise answers if answers.is_a?(Exception)

        content = { estimates: answers.map { |name, seconds| { name:, seconds: } } }.to_json
        Timed::LLM::Response.new(code: 200, body: { choices: [{ message: { content: } }] }.to_json)
      end
      described_class.estimates(formulae, pour: ->(formula) { formula.name == "poured" }, estimator: :mean,
                                          guesses: { "guessed" => 90.0 }, llm:, database:, exclude:)
                     .transform_values { |estimate| [estimate.seconds, estimate.fallback, estimate.guessed] }
    end

    def prompt = JSON.parse(JSON.parse(requests.fetch(0).body).dig("messages", 1, "content"))

    it "asks for the source builds with no history, no `--guess` and no estimate of their version kept, in " \
       "one request, marking every guess" do
      expect(estimates).to eq("history" => [30.0, false, false], "guessed" => [90.0, false, true],
                              "poured" => [15.0, true, false], "cached" => [600.0, false, true],
                              "stale" => [120.0, false, true], "new" => [7200.0, false, true])
    end

    it "sends the machine and each formula's name, version, description and build dependencies only" do
      estimates
      expect(prompt).to eq(
        "machine"  => machine,
        "formulae" => %w[stale new].map do |name|
          { "name" => name, "version" => "1.0", "desc" => "The #{name} formula", "build_dependencies" => ["cmake"] }
        end,
      )
    end

    it "says what it asks: the provider for its own API, and only the host and port of any other URL" do
      key_file = mktmpdir/"key"
      key_file.write("sk-proj-FAKEOPENAIKEY0123456789\n")
      key_file.chmod(0600)
      urls = {
        "default"                                                        => "openai gpt-5-mini",
        "http://127.0.0.1:11434/v1/chat/completions"                     => "qwen2.5:7b at 127.0.0.1:11434",
        "http://user:secret@[::1]:8080/v1/chat/completions?token=secret" => "qwen2.5:7b at [::1]:8080",
        "https://gateway.example.com/v1/chat/completions"                => "qwen2.5:7b at gateway.example.com:443",
      }
      original = database.read
      asked = urls.to_h do |url, _|
        database.write(original)
        said = []
        allow(described_class).to receive(:ohai) { |text| said << text }
        settings = if url == "default"
          Timed::LLM.settings(key_file: key_file.to_s)
        else
          Timed::LLM.settings(key_file: key_file.to_s, url:, model: "qwen2.5:7b", resolver: ->(_host) { ["::1"] })
        end
        estimates(llm: settings)
        [url, said]
      end
      expect(asked).to eq(urls.transform_values { |name| ["Asking #{name} for 2 estimates"] })
    end

    it "keeps each answer for its version, with the model and date, leaving the others" do
      estimates
      expect(JSON.parse(database.read).fetch("estimates").transform_values { |entry| entry.except("date") })
        .to eq("cached" => { "version" => "1.0", "seconds" => 600, "model" => "old" },
               "stale"  => { "version" => "1.0", "seconds" => 120.0, "model" => "qwen2.5:7b" },
               "new"    => { "version" => "1.0", "seconds" => 7200.0, "model" => "qwen2.5:7b" })
    end

    it "dates each answer it keeps" do
      estimates
      expect(JSON.parse(database.read).dig("estimates", "new", "date")).to match(/\A\d{4}-\d{2}-\d{2}\z/)
    end

    it "asks again for a new version, as the estimates it kept are of another" do
      estimates(version: "2.0")
      expect(prompt.fetch("formulae").map { |subject| subject.fetch("name") }).to eq(%w[cached stale new])
    end

    it "leaves `--exclude`d formulae to the median, out of the request and the log" do
      result = estimates(exclude: %w[stale new])
      expect([requests, result.values_at("stale", "new"), JSON.parse(database.read).fetch("estimates").keys])
        .to eq([[], [[30.0, true, false]] * 2, %w[cached stale]])
    end

    it "makes no request when it has every estimate it needs" do
      estimates
      requests.clear
      estimates
      expect(requests).to eq([])
    end

    it "leaves the rest to the median, marked as a fallback, for the names the answer leaves out" do
      expect(estimates(answers: { "new" => 7200, "history" => 1 }).values_at("stale", "history"))
        .to eq([[30.0, true, false], [30.0, false, false]])
    end

    it "falls back to the median, with a warning, and keeps nothing, when the request fails", :aggregate_failures do
      result = T.let(nil, T.nilable(T::Hash[String, T::Array[T.untyped]]))
      expect { result = estimates(answers: Errno::ECONNREFUSED.new) }
        .to output(/Warning: LLM build time estimates failed \(qwen2.5:7b at 127.0.0.1:11434\), using median/)
        .to_stderr
      expect(result&.values_at("stale", "new")).to eq([[30.0, true, false]] * 2)
      expect(JSON.parse(database.read).fetch("estimates").keys).to eq(%w[cached stale])
    end

    it "uses the answers it can't keep, with a warning, rather than stopping the run", :aggregate_failures do
      allow(Timed::BuildLog).to receive(:update).and_raise(Errno::EACCES, database.to_s)
      result = T.let(nil, T.nilable(T::Hash[String, T::Array[T.untyped]]))
      expect { result = estimates }
        .to output(/Warning: Couldn't keep the LLM estimates in #{Regexp.escape(database.to_s)}: Permission denied/)
        .to_stderr
      expect(result&.fetch("new")).to eq([7200.0, false, true])
    end

    it "uses no kept estimate and asks nothing without LLM settings" do
      expect(estimates(llm: nil).values_at("cached", "new")).to eq([[30.0, true, false]] * 2)
    end

    it "makes no request without LLM settings" do
      estimates(llm: nil)
      expect(requests).to eq([])
    end
  end

  describe ".machine" do
    it "gives the CPU, cores, memory and OS" do
      machine = described_class.machine
      expect(machine.transform_values(&:class))
        .to eq("cpu" => String, "cores" => Integer, "memory_gb" => Integer, "os" => String)
    end

    it "leaves out any fact that can't be read, however it fails, rather than stopping the run" do
      failing = T.let(nil, T.nilable(String))
      # Raises `error` while `fact` is the one failing.
      fail_for = lambda do |fact, error|
        lambda do |original, *args|
          raise error if failing == fact

          original.call(*args)
        end
      end
      allow(Hardware::CPU).to receive(:family).and_wrap_original(&fail_for.call("cpu", RuntimeError.new("no CPU")))
      allow(Hardware::CPU).to receive(:cores).and_wrap_original(&fail_for.call("cores", ArgumentError.new("none")))
      allow(Utils).to receive(:popen_read).and_call_original
      allow(Utils).to receive(:popen_read).with("/usr/sbin/sysctl", "-n", "hw.memsize")
                                          .and_wrap_original(&fail_for.call("memory_gb", IOError.new("closed")))
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/meminfo")
                                   .and_wrap_original(&fail_for.call("memory_gb", IOError.new("closed")))
      facts = %w[cpu cores memory_gb os]
      left = facts.first(3).to_h do |fact|
        failing = fact
        [fact, described_class.machine.keys]
      end
      expect(left).to eq(facts.first(3).to_h { |fact| [fact, facts - [fact]] })
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
                                                     batch("last", "c needs b", "c")],
                                          warnings: [])
      expect { described_class.show_plan("upgrade", result, estimates, excluded: %w[x y]) }
        .to output(<<~EOS).to_stdout
          ==> Would upgrade 3 formulae in 3 batches, estimated 5m10s
          ==> Batch 1 of 3: 0m10s
          a                            build     0m10s
          ==> Batch 2 of 3 (--last): 1m40s
          b                            build     1m40s
          ==> Batch 3 of 3 (--last): 3m20s, c needs b
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

    it "says there are no formulae only for a run without casks, as brew says nothing like it",
       :aggregate_failures do
      result = Timed::Planner::Result.new(batches: [], warnings: [])
      expect { described_class.show_plan("upgrade", result, estimates, excluded: []) }
        .to output("==> No formulae to upgrade\n").to_stdout
      expect { described_class.show_plan("upgrade", result, estimates, excluded: [], casks: true) }
        .not_to output.to_stdout
    end

    it "says what it does after the batches, the outdated dependents it upgrades and the check for broken " \
       "linkage, before the `--exclude`d formulae" do
      result = Timed::Planner::Result.new(batches: [batch("main", nil, "a")], warnings: [])
      expect do
        described_class.show_plan("install", result, estimates, excluded: %w[x], dependents: %w[d e], linkage: true)
      end.to output(<<~EOS).to_stdout
        ==> Would install 1 formula in 1 batch, estimated 0m10s
        ==> Batch 1 of 1: 0m10s
        a                            build     0m10s
        ==> Then upgrade outdated dependents
        d e
        ==> Then check dependents for broken linkage, and reinstall broken ones from source
        ==> Excluded
        x
      EOS
    end

    it "marks guessed estimates with `*` and fallbacks with `?`" do
      marks = { "a" => [true, false], "b" => [false, true], "c" => [false, false] }
      estimates = marks.to_h do |name, (guessed, fallback)|
        [name, Timed::Command::Estimate.new(seconds: 60.0, pour: false, fallback:, guessed:)]
      end
      result = Timed::Planner::Result.new(batches: [batch("main", nil, "a", "b", "c")], warnings: [])
      expect { described_class.show_plan("upgrade", result, estimates, excluded: []) }
        .to output(<<~EOS).to_stdout
          ==> Would upgrade 3 formulae in 1 batch, estimated 3m00s
          ==> Batch 1 of 1: 3m00s
          a                            build    1m00s*
          b                            build    1m00s?
          c                            build     1m00s
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
