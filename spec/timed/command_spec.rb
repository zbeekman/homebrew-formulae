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

    describe ".cask_plan's needs" do
      it "puts a cask whose download needs a formula in the run to unpack last, and holds it back when that " \
         "formula didn't install and isn't installed", :aggregate_failures do
        stub_xz
        cask = stub_cask("xz-app", nil, url: "https://brew.sh/xz-app.xz")
        result = described_class.cask_plan({ install: [cask] }, in_run: %w[xz], facts: Timed::Casks::DiskFacts.new,
                                                                tty: -> { true })
        expect(result.last.map { |entry| entry.reasons.map(&:message) })
          .to eq([["depends on `xz`, which is in this run"]])
        expect { described_class.last_casks("install", [cask], named: [], flags: [], unfinished: %w[xz]) }
          .to output(/^xz-app: needs xz$/).to_stderr
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
                     "needs-old"    => ["depends on `old`, which is in this run"] },
          true  => { "old" => [], "needs-helper" => ["depends on `lib`, which is in this run"], "needs-old" => [] },
        )
      end
    end

    describe ".cask_needs" do
      it "follows casks through a cycle once and takes one it can't load, missing or invalid, by its name" do
        allow(Cask::CaskLoader).to receive(:load).and_call_original
        allow(Cask::CaskLoader).to receive(:load).with("bad-app", any_args)
                                                 .and_raise(Cask::CaskInvalidError.new("bad-app", "nope"))
        stub_cask("loop-b", nil, stanzas: 'depends_on cask: ["loop-a", "gone-app", "bad-app"]')
        loop_a = stub_cask("loop-a", nil, stanzas: 'depends_on cask: "loop-b"')
        needs = described_class.cask_needs(loop_a)
        expect([needs.formulae, needs.casks.map { |cask| cask.is_a?(Cask::Cask) ? cask.token : cask }])
          .to eq([[], %w[loop-b gone-app bad-app]])
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
         "the options given for it", :aggregate_failures do
        stub_lib_and_app
        stub_cask("dep-app", nil, stanzas: 'depends_on formula: "lib"')
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "lib"'),
                 stub_cask("through-app", nil, stanzas: 'depends_on formula: "app"'),
                 stub_cask("via-cask", nil, stanzas: 'depends_on cask: "dep-app"'), stub_cask("free-app", nil)]
        kept = T.let(nil, T.nilable(T::Array[String]))
        expect do
          kept = described_class.last_casks("install", casks, named: [], flags: %w[--force], unfinished: %w[lib])
        end.to output(<<~EOS).to_stderr
          Warning: Not installing 3 casks, which need formulae that didn't install and aren't installed:
          direct-app: needs lib
          through-app: needs lib
          via-cask: needs lib
          Install them later with `brew install --cask --force direct-app through-app via-cask`.
        EOS
        expect(kept).to eq(%w[free-app])
      end

      it "keeps a cask that needs a formula brew didn't upgrade but left installed, as brew won't touch it" do
        stub_lib_and_app(installed_lib: true)
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "lib"')]
        expect { described_class.last_casks("upgrade", casks, named: [], flags: [], unfinished: %w[lib]) }
          .not_to output.to_stderr
      end

      it "takes a formula it can't load, e.g. from a tap that isn't trusted, as needed by name only" do
        allow(Formulary).to receive(:factory).and_call_original
        allow(Formulary).to receive(:factory).with("user/tap/evil").and_raise(Homebrew::UntrustedTapError, "no")
        casks = [stub_cask("direct-app", nil, stanzas: 'depends_on formula: "user/tap/evil"')]
        expect(described_class.last_casks("upgrade", casks, named: [], flags: [], unfinished: []))
          .to eq(%w[direct-app])
      end
    end

    describe ".later" do
      it "shell-escapes every argument of the command, e.g. a path or flag value with a space" do
        dir = mktmpdir/"My Casks"
        dir.mkpath
        (dir/"foo.rb").write(cask_source("foo", "2.0"))
        Dir.chdir(dir) do
          casks = [Cask::CaskLoader.load("foo.rb")]
          command = described_class.later("install", casks, named: %w[foo.rb], flags: ["--appdir=/My Apps"])
          expect(command).to eq("Install it later with `brew install --cask --appdir\\=/My\\ Apps " \
                                "#{(dir/"foo.rb").realpath.to_s.gsub(" ", "\\ ")}`.")
        end
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

    it "says there are no formulae only for a run without casks, as brew says nothing like it",
       :aggregate_failures do
      result = Timed::Planner::Result.new(batches: [], warnings: [])
      expect { described_class.show_plan("upgrade", result, estimates, excluded: []) }
        .to output("==> No formulae to upgrade\n").to_stdout
      expect { described_class.show_plan("upgrade", result, estimates, excluded: [], casks: true) }
        .not_to output.to_stdout
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
