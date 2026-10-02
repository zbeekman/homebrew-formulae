# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/upgrade"
require_relative "../../cmd/upgrade-timed"
require_relative "../support/casks"

RSpec.describe Homebrew::Cmd::UpgradeTimed do
  include TimedCaskHelper

  let(:database) { Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json" }
  let(:receipt) { Pathname(__FILE__).dirname.parent/"fixtures/receipts/built.json" }
  let(:brew_calls) { [] }
  let(:installed) { [] }
  # What `brew upgrade --dry-run` prints.
  let(:preview) { [] }

  # A formula at version `latest`, with `installed_version` in the Cellar and
  # linked into `opt` (neither when nil), loadable by name. A bottled one's
  # bottle manifest is never downloaded; its tab lists `bottle_deps`, with
  # the version each needs at least.
  def stub_formula(name, installed_version = "1.0", latest: "2.0", deps: [], build_deps: [], keg_only: false,
                   bottled: false, bottle_deps: {})
    formula = formula(name) do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/#{name}-#{latest}.tgz"
      deps.each { |dep| depends_on dep }
      build_deps.each { |dep| depends_on dep => :build }
      keg_only "it is a test" if keg_only
      if bottled
        bottle do
          T.bind(self, BottleSpecification)
          sha256 cellar: :any, Utils::Bottles.tag.to_sym => "a" * 64
        end
      end
    end
    stub_formula_loader(formula)
    if bottled
      runtime_dependencies = bottle_deps.map do |dep, version|
        { "full_name" => dep, "version" => version, "revision" => 0 }
      end
      # Like brew's, the tab is empty until the manifest has been fetched.
      fetches = []
      allow(formula.bottle).to receive(:fetch_tab) { fetches << :fetched }
      allow(formula.bottle).to receive(:tab_attributes) do
        fetches.empty? ? {} : { "runtime_dependencies" => runtime_dependencies }
      end
    end
    if installed_version
      keg = HOMEBREW_CELLAR/name/installed_version
      (keg/"bin").mkpath
      (HOMEBREW_PREFIX/"opt").mkpath
      FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt"/name
      installed << formula
    end
    formula
  end

  def build(seconds) = { "status" => "built", "install_seconds" => seconds, "version" => "1.0" }

  def run_command(*argv) = described_class.new(argv).run

  # Brew: `brew upgrade --dry-run` prints `preview`; a batch installs each
  # formula, by name or file, at 2.0, with a receipt, and prints its summary
  # line; a cask call succeeds. There is a terminal for sudo.
  before do
    allow(Formulary).to receive(:loader_for).and_call_original
    allow(Cask::CaskLoader).to receive(:for).and_call_original
    allow(Formula).to receive(:installed) { installed }
    allow(Timed::Command).to receive(:auto_update)
    allow(Timed::Command).to receive(:brew) do |_env, argv|
      brew_calls << argv
      true
    end
    allow(Timed::Casks).to receive(:terminal?).and_return(true)
    allow(Timed::Runner).to receive(:stream) do |argv, &block|
      brew_calls << argv
      if argv.include?("--dry-run")
        preview.each { |line| block.call("#{line}\n") }
      else
        argv.drop(1).reject { |arg| arg.start_with?("-") }.each do |arg|
          keg = HOMEBREW_CELLAR/File.basename(arg, ".rb")/"2.0"
          keg.mkpath
          FileUtils.cp receipt, keg/"INSTALL_RECEIPT.json"
          block.call("🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n")
        end
      end
      true
    end
    database.dirname.mkpath
    database.write(JSON.generate("schema_version" => 1,
                                 "packages"       => { "cmake" => { "builds" => [build(200.0)] },
                                                       "llvm"  => { "builds" => [build(5000.0)] },
                                                       "gcc"   => { "builds" => [build(3000.0)] } }))
  end

  describe "flags" do
    it "accepts every `brew upgrade` option" do
      upgrade_options = Timed::Command.builtin("upgrade").parser.processed_options.map { |short, long| long || short }
      options = described_class.parser.processed_options.map { |short, long| long || short }
      expect(upgrade_options - options).to eq([])
    end

    it "keeps `brew upgrade`'s conflicts" do
      expect(Timed::Command.builtin("upgrade").parser.conflicts - described_class.parser.conflicts).to eq([])
    end

    it "adds its own flags, none of them but `--no-stamp-receipts` with `--cask`", :aggregate_failures do
      argv = %w[--guess=llvm=1h30m,lld=20m --estimator=median --last=llvm --exclude=gcc,go --no-stamp-receipts]
      args = described_class.new(argv).args
      expect([args.guess, args.estimator, args.last, args.exclude, args.no_stamp_receipts?])
        .to eq([%w[llvm=1h30m lld=20m], "median", %w[llvm], %w[gcc go], true])
      expect { described_class.new(%w[--cask --last=llvm]) }.to raise_error(Homebrew::CLI::OptionConflictError)
      expect(described_class.new(%w[--cask --no-stamp-receipts]).args.no_stamp_receipts?).to be(true)
    end

    it "takes `--no-stamp-receipts` from `HOMEBREW_TIMED_NO_STAMP_RECEIPTS` set to anything" do
      ENV["HOMEBREW_TIMED_NO_STAMP_RECEIPTS"] = "0"
      expect(described_class.new([]).args.no_stamp_receipts?).to be(true)
    end

    it "keeps `--` as the end of options" do
      expect(described_class.new(%w[--formula -- --last]).args.named).to eq(%w[--last])
    end

    it "rejects an unknown `--estimator`" do
      expect { run_command("--estimator=mode") }
        .to raise_error(UsageError, "Invalid usage: `--estimator` must be `mean` or `median`, not `mode`.")
    end

    it "requires a named formula for `--build-from-source`, as `brew upgrade` does" do
      expect { run_command("--build-from-source") }
        .to raise_error(ArgumentError, "`--build-from-source` requires at least one formula")
    end

    it "requires exactly one named formula for `--minimum-version`, as `brew upgrade` does" do
      expect { run_command("--minimum-version=1.0") }
        .to raise_error(UsageError, /`--minimum-version` requires exactly one formula or cask argument/)
    end

    it "fails on unknown `--last`, `--exclude` and `--guess` names, naming the flag" do
      errors = %w[--last=nope --exclude=nope --guess=nope=1m].to_h do |flag|
        run_command("--dry-run", flag)
        [flag, nil]
      rescue UsageError => e
        [flag, e.message]
      end
      expect(errors.transform_values { |message| message&.sub(/(?<=\.) Did you mean .*/, "") })
        .to eq(%w[--last=nope --exclude=nope --guess=nope=1m].to_h do |flag|
          [flag, "Invalid usage: `#{flag[/--\w+/]}`: No available formula with the name \"nope\"."]
        end)
    end
  end

  describe "help" do
    let(:help) { described_class.parser.generate_help_text(remaining_args: []).gsub(/\s+/, " ") }

    it "shows the usage, its own description and the variable that turns on `--no-stamp-receipts`",
       :aggregate_failures do
      expect(help).to start_with("Usage: brew upgrade-timed [options] [installed_formula|installed_cask ...] ")
      expect(help).to include("Upgrade outdated, unpinned formulae like brew upgrade, in timed batches:")
      expect(help).to include("Enabled by default if $HOMEBREW_TIMED_NO_STAMP_RECEIPTS is set.")
    end
  end

  describe "--dry-run" do
    it "auto-updates first, with the original arguments" do
      expect(Timed::Command).to receive(:auto_update).with(command: "upgrade-timed", argv: %w[--dry-run --formula])
      run_command("--dry-run", "--formula")
    end

    it "prints `brew upgrade --dry-run` with the forwarded flags and named arguments" do
      stub_formula("cmake")
      run_command("--dry-run", "--verbose", "--last=cmake", "cmake")
      expect(brew_calls).to eq([%w[upgrade --dry-run --verbose cmake]])
    end

    it "passes the named arguments to the preview as the sub-calls need them" do
      stub_formula("cmake")
      allow(Timed::Command).to receive(:named_argv).with(%w[cmake]).and_return(%w[/work/cmake])
      run_command("--dry-run", "cmake")
      expect(brew_calls).to eq([%w[upgrade --dry-run /work/cmake]])
    end

    it "plans every outdated, unpinned formula, dependencies first, then the quickest" do
      stub_formula("cmake")
      stub_formula("lib", bottled: true)
      stub_formula("app", deps: %w[lib], build_deps: %w[cmake])
      stub_formula("current", "2.0")
      allow(stub_formula("pinned")).to receive(:pinned?).and_return(true)
      expect { run_command("--dry-run") }.to output(<<~EOS).to_stdout
        ==> Would upgrade 3 formulae in 2 batches, estimated 53m35s
        ==> Batch 1 of 2: 3m35s
        lib                          pour     0m15s?
        cmake                        build     3m20s
        ==> Batch 2 of 2: 50m00s, slow app needs slow cmake
        app                          build   50m00s?
      EOS
    end

    it "splits batches and gives the reasons" do
      stub_formula("cmake")
      stub_formula("llvm", keg_only: true, build_deps: %w[cmake])
      stub_formula("gcc")
      expect { run_command("--dry-run", "--last=gcc") }.to output(<<~EOS).to_stdout
        ==> Would upgrade 3 formulae in 3 batches, estimated 2h16m
        ==> Batch 1 of 3: 3m20s
        cmake                        build     3m20s
        ==> Batch 2 of 3: 1h23m, slow keg-only llvm
        llvm                         build     1h23m
        ==> Batch 3 of 3 (--last): 50m00s
        gcc                          build    50m00s
      EOS
    end

    it "uses `--guess` and `--estimator`, and leaves out `--exclude`d formulae" do
      stub_formula("new")
      stub_formula("gcc")
      stub_formula("cmake")
      expect { run_command("--dry-run", "--guess=new=1m", "--estimator=median", "--exclude=gcc") }
        .to output(<<~EOS).to_stdout
          ==> Would upgrade 2 formulae in 1 batch, estimated 4m20s
          ==> Batch 1 of 1: 4m20s
          new                          build     1m00s
          cmake                        build     3m20s
          ==> Excluded
          gcc
        EOS
    end

    it "plans named formulae and their outdated dependencies only" do
      stub_formula("lib")
      stub_formula("other")
      stub_formula("app", deps: %w[lib])
      expect { run_command("--dry-run", "app") }
        .to output(/\A==> Would upgrade 2 formulae in 2 batches.*^lib .*^app /m).to_stdout
    end

    it "plans a source build's outdated dependencies through current ones, but not their build dependencies" do
      stub_formula("tool")
      stub_formula("lib")
      stub_formula("mid", "2.0", deps: %w[lib], build_deps: %w[tool])
      stub_formula("app", deps: %w[mid])
      expect { run_command("--dry-run", "app") }
        .to output(/\A==> Would upgrade 2 formulae in 2 batches.*^lib .*^app /m).to_stdout
    end

    it "doesn't plan a poured formula's outdated dependency that its bottle's manifest is satisfied with" do
      stub_formula("lib")
      stub_formula("app", bottled: true, deps: %w[lib], bottle_deps: { "lib" => "1.0" })
      expect { run_command("--dry-run", "app") }.to output(/\A==> Would upgrade 1 formula in 1 batch/).to_stdout
    end

    it "plans a poured formula's outdated dependencies when its bottle's manifest can't be downloaded" do
      stub_formula("lib")
      app = stub_formula("app", bottled: true, deps: %w[lib], bottle_deps: { "lib" => "1.0" })
      manifest = app.bottle&.github_packages_manifest_resource || raise("no bottle manifest")
      allow(app.bottle).to receive(:fetch_tab).and_raise(DownloadError.new(manifest, RuntimeError.new("offline")))
      expect { run_command("--dry-run", "app") }.to output(/\A==> Would upgrade 2 formulae/).to_stdout
    end

    it "doesn't plan a formula brew can't expand the dependencies of, which the preview reports" do
      stub_formula("lib", build_deps: %w[gone])
      stub_formula("app", bottled: true, deps: %w[lib])
      stub_formula("other")
      expect { run_command("--dry-run", "app", "other") }
        .to output(/\A==> Would upgrade 1 formula in 1 batch.*^other /m).to_stdout
    end

    it "doesn't plan a formula that needs a newer version of a pinned dependency, which the preview reports" do
      allow(stub_formula("lib")).to receive(:pinned?).and_return(true)
      stub_formula("app", deps: %w[lib])
      expect { run_command("--dry-run", "app") }.to output("==> No formulae to upgrade\n").to_stdout
    end

    it "doesn't plan the outdated build dependencies of a poured formula" do
      stub_formula("cmake")
      stub_formula("app", bottled: true, build_deps: %w[cmake])
      expect { run_command("--dry-run", "app") }.to output(/\A==> Would upgrade 1 formula in 1 batch/).to_stdout
    end

    it "leaves messages about named formulae it won't upgrade to brew's preview", :aggregate_failures do
      stub_formula("current", "2.0")
      stub_formula("missing", nil)
      allow(stub_formula("pinned")).to receive(:pinned?).and_return(true)
      expect { run_command("--dry-run", "current", "missing", "pinned", "nope") }
        .to output("==> No formulae to upgrade\n").to_stdout.and output("").to_stderr
      expect(Homebrew).not_to be_failed
    end

    it "fails when brew's preview fails" do
      allow(Timed::Runner).to receive(:stream).and_return(false)
      run_command("--dry-run")
      expect(Homebrew).to be_failed
    end

    it "plans no formulae with `--cask`, and doesn't say so, as brew doesn't" do
      stub_formula("cmake")
      expect { run_command("--dry-run", "--cask") }.not_to output.to_stdout
    end

    it "checks HEAD formulae against upstream with `--fetch-HEAD`, as `brew upgrade` does" do
      allow(stub_formula("app", "2.0")).to receive(:outdated?) { |fetch_head: false| fetch_head }
      expect { run_command("--dry-run", "--fetch-HEAD") }.to output(/^app +build /).to_stdout
    end

    it "doesn't plan a HEAD formula whose installed HEAD is upstream's with `--fetch-HEAD`" do
      app = formula("app", spec: :head) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/app-2.0.tgz"
        head "https://brew.sh/app.git"
      end
      keg = HOMEBREW_CELLAR/"app/HEAD-abc1234"
      keg.mkpath
      (HOMEBREW_PREFIX/"opt").mkpath
      FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt/app"
      installed << app
      allow(app).to receive(:outdated?).and_return(true)
      allow(app).to receive(:latest_head_pkg_version).with(fetch_head: true)
                                                     .and_return(PkgVersion.parse("HEAD-abc1234"))
      expect { run_command("--dry-run", "--fetch-HEAD") }.to output("==> No formulae to upgrade\n").to_stdout
    end

    it "doesn't plan a formula with a dependency that can't be loaded, which the preview reports" do
      stub_formula("app", deps: %w[gone])
      expect { run_command("--dry-run") }.to output("==> No formulae to upgrade\n").to_stdout
    end

    it "plans the new target of the alias a formula was installed with, as `brew upgrade` does" do
      stub_formula("lib")
      target = stub_formula("cmake", nil, deps: %w[lib])
      allow(stub_formula("old")).to receive(:latest_formula).and_return(target)
      expect { run_command("--dry-run", "old") }
        .to output(/\A==> Would upgrade 2 formulae.*^lib .*^cmake +build +3m20s$/m).to_stdout
    end

    it "keeps a formula whose alias's new target is already installed" do
      target = stub_formula("cmake", "2.0")
      allow(stub_formula("old")).to receive(:latest_formula).and_return(target)
      expect { run_command("--dry-run", "old") }.to output(/\A==> Would upgrade 1 formula.*^old +build /m).to_stdout
    end

    it "doesn't plan a named formula not below `--minimum-version`" do
      stub_formula("cmake", "1.5")
      expect { run_command("--dry-run", "--minimum-version=1.2", "cmake") }
        .to output("==> No formulae to upgrade\n").to_stdout
    end

    it "estimates a named bottled formula as a source build with `--build-from-source`" do
      stub_formula("lib", bottled: true)
      expect { run_command("--dry-run", "--build-from-source", "lib") }.to output(/^lib +build /).to_stdout
    end

    it "doesn't ask for confirmation" do
      stub_formula("cmake")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_command("--dry-run")
    end
  end

  describe "confirmation" do
    def run_to_end(*argv)
      run_command(*argv)
    rescue SystemExit
      nil
    end

    it "asks once when there is anything to upgrade and nothing is named" do
      stub_formula("cmake")
      expect(Homebrew::Ask).to receive(:confirm?).with(action: "upgrade").once.and_return(true)
      run_to_end
    end

    it "asks when the plan includes formulae that are not named" do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("app")
    end

    it "doesn't count a refused named formula when deciding to ask" do
      allow(stub_formula("lib")).to receive(:pinned?).and_return(true)
      stub_formula("app", deps: %w[lib])
      stub_formula("other")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_command("app", "other")
    end

    it "checks the dependents of a refused named formula too, as `brew upgrade` does, and asks" do
      allow(stub_formula("lib")).to receive(:pinned?).and_return(true)
      app = stub_formula("app", deps: %w[lib])
      other = stub_formula("other")
      dependent = stub_formula("dependent", bottled: true, deps: %w[app])
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [dependent], pinned: [], skipped: [])
      expect(Homebrew::Upgrade).to receive(:dependants)
        .with([app, other], hash_including(dry_run: true))
        .and_return(dependents)
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("app", "other")
    end

    it "asks when a named formula needs a dependency brew would install, as `brew upgrade` does" do
      stub_formula("new", nil)
      stub_formula("app", deps: %w[new])
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("app")
    end

    it "asks when brew would also upgrade outdated dependents of the named formulae, as `brew upgrade` does" do
      app = stub_formula("app")
      dependent = stub_formula("dependent", bottled: true, deps: %w[app])
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [dependent], pinned: [], skipped: [])
      expect(Homebrew::Upgrade).to receive(:dependants)
        .with([app], hash_including(dry_run: true))
        .and_return(dependents)
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("app")
    end

    it "compares the plan with the named arguments as given, as `brew upgrade` does" do
      stub_formula_loader(stub_formula("app"), "homebrew/core/app")
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("homebrew/core/app")
    end

    it "checks the dependents of an alias's new target, which brew upgrades instead" do
      target = stub_formula("cmake", nil)
      allow(stub_formula("old")).to receive(:latest_formula).and_return(target)
      expect(Homebrew::Upgrade).to receive(:dependants).with([target], hash_including(dry_run: true))
                                                       .and_call_original
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("old")
    end

    it "doesn't check dependents with `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`, which the preview warns about" do
      ENV["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
      stub_formula("app")
      expect(Homebrew::Upgrade).not_to receive(:dependants)
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_to_end("app")
    end

    it "doesn't ask when only the named formulae would be upgraded" do
      stub_formula("app")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_to_end("app")
    end

    it "doesn't ask with `--yes` or `HOMEBREW_NO_ASK`" do
      stub_formula("cmake")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_to_end("--yes")
      ENV["HOMEBREW_NO_ASK"] = "1"
      run_to_end
    end

    it "carries on without a terminal, where brew doesn't ask" do
      allow(Homebrew::Ask).to receive(:confirm?).and_return(false)
      stub_formula("cmake")
      run_command
      expect(brew_calls.last).to eq(%w[upgrade --formula --yes --display-times cmake])
    end
  end

  describe "running the batches" do
    def builds = JSON.parse(database.read)["packages"].transform_values { |package| package["builds"] }

    it "runs each batch with the forwarded formula flags, but not `--minimum-version`, after the preview" do
      stub_formula("cmake")
      run_command("--yes", "--verbose", "--minimum-version=1.5", "--greedy", "cmake")
      expect(brew_calls).to eq([%w[upgrade --dry-run --verbose --minimum-version=1.5 --greedy cmake],
                                %w[upgrade --formula --yes --display-times --verbose cmake]])
    end

    it "names a formula given as a file to `brew upgrade` by that file, made absolute, and logs it by name",
       :aggregate_failures do
      dir = mktmpdir
      (dir/"foo.rb").write("class Foo < Formula\n  url \"https://brew.sh/foo-2.0.tgz\"\nend\n")
      keg = HOMEBREW_CELLAR/"foo/1.0"
      (keg/"bin").mkpath
      (HOMEBREW_PREFIX/"opt").mkpath
      FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt/foo"
      Dir.chdir(dir) { run_command("--yes", "foo.rb") }
      expect(brew_calls.last).to eq(["upgrade", "--formula", "--yes", "--display-times",
                                     (dir/"foo.rb").realpath.to_s])
      expect(builds.fetch("foo").last).to include("version" => "2.0", "status" => "built", "verb" => "upgrade")
    end

    it "logs each upgrade and stamps its receipt", :aggregate_failures do
      stub_formula("cmake")
      run_command("--yes")
      expect(builds.fetch("cmake").last).to include("version" => "2.0", "status" => "built", "verb" => "upgrade")
      expect(JSON.parse((HOMEBREW_CELLAR/"cmake/2.0/INSTALL_RECEIPT.json").read)["build_times"])
        .to include("verb" => "upgrade", "build_seconds" => 9.0)
    end

    it "leaves receipts as they are with `--no-stamp-receipts` or `HOMEBREW_TIMED_NO_STAMP_RECEIPTS`, " \
       "but still logs the upgrades" do
      stub_formula("cmake")
      ways = %w[--no-stamp-receipts HOMEBREW_TIMED_NO_STAMP_RECEIPTS]
      results = ways.to_h do |way|
        database.write(JSON.generate("schema_version" => 1, "packages" => {}))
        ENV["HOMEBREW_TIMED_NO_STAMP_RECEIPTS"] = "1" if way.start_with?("HOMEBREW_")
        run_command("--yes", *("--no-stamp-receipts" if way.start_with?("--")))
        keg = HOMEBREW_CELLAR/"cmake/2.0"
        result = [(keg/"INSTALL_RECEIPT.json").read == receipt.read,
                  builds.fetch("cmake").map { |build| build["verb"] }]
        keg.rmtree
        [way, result]
      end
      expect(results).to eq(ways.to_h { |way| [way, [true, ["upgrade"]]] })
    end

    it "upgrades a batch's poured dependencies without `--build-from-source` or `--debug-symbols`, first" do
      stub_formula("lib", bottled: true)
      stub_formula("app", deps: %w[lib])
      run_command("--yes", "--build-from-source", "--debug-symbols", "app")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times lib],
                                        %w[upgrade --formula --yes --display-times --build-from-source
                                           --debug-symbols app]])
    end

    it "keeps a named source build ahead of a pour that needs it, so brew doesn't pour it as a dependency" do
      stub_formula("lib", bottled: true)
      stub_formula("dep", bottled: true, deps: %w[lib])
      stub_formula("app", deps: %w[dep])
      run_command("--yes", "--build-from-source", "lib", "app")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times --build-from-source lib],
                                        %w[upgrade --formula --yes --display-times dep],
                                        %w[upgrade --formula --yes --display-times --build-from-source app]])
    end

    it "upgrades a batch of source builds with `--build-from-source` in one call" do
      stub_formula("app")
      stub_formula("other")
      run_command("--yes", "--build-from-source", "app", "other")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times --build-from-source app other]])
    end

    it "upgrades pours and source builds together without `--build-from-source`" do
      stub_formula("lib", bottled: true)
      stub_formula("app", deps: %w[lib])
      run_command("--yes", "app")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times lib app]])
    end

    it "passes `--debug` on" do
      stub_formula("cmake")
      run_command("--yes", "--debug", "cmake")
      expect(brew_calls.last).to eq(%w[upgrade --formula --yes --display-times --debug cmake])
    end

    it "refuses `--interactive`, which needs a terminal" do
      expect { run_command("--dry-run", "--interactive", "cmake") }
        .to raise_error(UsageError, "Invalid usage: `--interactive` needs a terminal; " \
                                    "use `brew upgrade --interactive` instead.")
    end

    it "doesn't run anything with nothing to upgrade" do
      stub_formula("cmake", "2.0")
      run_command("--yes")
      expect(brew_calls).to eq([%w[upgrade --dry-run]])
    end
  end

  describe "casks" do
    def run_to_end(*argv)
      run_command(*argv)
    rescue SystemExit
      nil
    end

    it "lists the outdated casks to upgrade first, and last with why, with no names, as brew picks them" do
      stub_cask("firefox")
      stub_cask("iterm2", stanzas: 'pkg "Bar.pkg"')
      stub_cask("current-app", "2.0")
      stub_cask("manual-app", stanzas: 'installer manual: "Manual.app"')
      expect { run_command("--dry-run") }.to output(<<~EOS).to_stdout
        ==> Would upgrade 1 cask first
        firefox
        ==> Would upgrade 1 cask last
        iterm2: `pkg` requires sudo
      EOS
    end

    it "prints nothing of its own for a named cask brew won't upgrade, as brew's preview says why" do
      stub_cask("current-app", "2.0")
      expect { run_command("--dry-run", "current-app") }.not_to output.to_stdout
    end

    it "runs only the preview with `--dry-run`" do
      stub_cask("firefox")
      run_command("--dry-run")
      expect(brew_calls).to eq([%w[upgrade --dry-run]])
    end

    it "upgrades casks first and last around the batches, with the cask flags but not `--minimum-version`" do
      stub_formula("cmake")
      stub_cask("firefox")
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      run_command("--yes", "--verbose", "--no-binaries", "--greedy")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes --verbose --greedy --no-binaries firefox],
                                        %w[upgrade --formula --yes --display-times --verbose cmake],
                                        %w[upgrade --cask --yes --verbose --greedy --no-binaries iterm2]])
    end

    it "reports a failed first cask call and still runs the batches and the last call", :aggregate_failures do
      stub_formula("cmake")
      stub_cask("firefox")
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Command).to receive(:brew) do |_env, argv|
        brew_calls << argv
        argv.last != "firefox"
      end
      expect { run_command("--yes", "cmake", "firefox", "iterm2") }
        .to output("Error: `brew upgrade --cask firefox` failed.\n").to_stderr
      expect(brew_calls.drop(1).map(&:last)).to eq(%w[firefox cmake iterm2])
      expect(Homebrew).to be_failed
    end

    it "upgrades a last cask that needs a formula that failed to upgrade, which brew leaves installed and alone",
       :aggregate_failures do
      stub_formula("cmake")
      FileUtils.cp receipt, HOMEBREW_CELLAR/"cmake/1.0/INSTALL_RECEIPT.json"
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Runner).to receive(:run)
        .and_return(Timed::Runner::Outcome.new(unfinished: %w[cmake], stopped_early: false))
      expect { run_command("--yes", "--greedy", "cmake", "iterm2") }.not_to output.to_stderr
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes --greedy iterm2]])
    end

    it "upgrades a cask named with `--minimum-version`, without it, as planning applied it" do
      stub_cask("firefox")
      run_command("--yes", "--minimum-version=1.5", "firefox")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes firefox]])
    end

    it "asks once, counting the casks, with no names" do
      stub_cask("firefox")
      expect(Homebrew::Ask).to receive(:confirm?).with(action: "upgrade").once.and_return(true)
      run_to_end
      expect(brew_calls.last).to eq(%w[upgrade --cask --yes firefox])
    end

    it "doesn't ask when only the named casks would be upgraded" do
      stub_cask("firefox")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_command("firefox")
    end

    it "upgrades only the named casks, and none when only formulae are named or with `--formula`",
       :aggregate_failures do
      stub_formula("cmake")
      stub_cask("firefox")
      stub_cask("iterm2")
      upgraded = [%w[--yes iterm2], %w[--yes cmake], %w[--yes --formula]].to_h do |argv|
        brew_calls.clear
        run_command(*argv)
        [argv, brew_calls.select { |call| call.include?("--cask") }.map(&:last)]
      end
      expect(upgraded).to eq(%w[--yes iterm2] => %w[iterm2], %w[--yes cmake] => [], %w[--yes --formula] => [])
    end

    it "leaves named casks it won't upgrade to brew's preview: pinned, not installed or not below " \
       "`--minimum-version`", :aggregate_failures do
      allow(stub_cask("pinned-app")).to receive(:pinned?).and_return(true)
      stub_cask("missing-app", nil)
      stub_cask("current-app", "1.5")
      runs = [%w[pinned-app], %w[missing-app], %w[--minimum-version=1.2 current-app]]
      expect { runs.each { |argv| run_command("--yes", *argv) } }.not_to output.to_stderr
      expect([brew_calls.reject { |call| call.include?("--dry-run") }, Homebrew.failed?]).to eq([[], false])
    end

    it "skips the casks that need sudo without a terminal, with a warning giving the cask flags, but not " \
       "`--minimum-version`, in the command to upgrade them later", :aggregate_failures do
      allow(Timed::Casks).to receive(:terminal?).and_return(false)
      stub_cask("iterm2", stanzas: 'pkg "Bar.pkg"')
      expect { run_command("--yes", "--no-binaries", "--minimum-version=1.5", "iterm2") }.to output(<<~EOS).to_stderr
        Warning: Skipping 1 cask, as sudo can't ask for a password without a terminal:
        iterm2: `pkg` requires sudo
        Upgrade it later with `brew upgrade --cask --no-binaries iterm2`.
      EOS
      expect(brew_calls.drop(1)).to eq([])
    end
  end

  describe "checking the plan against brew's" do
    it "warns about formulae brew's preview lists but the batches don't, and the other way round" do
      stub_formula("cmake")
      stub_formula("gcc", "2.0")
      preview.push("==> Would upgrade 2 outdated packages", "gcc      1.0 -> 2.0", "firefox  1 -> 2")
      expect { run_command("--dry-run") }.to output(<<~EOS).to_stderr
        Warning: The batches leave out gcc, which `brew upgrade` would upgrade.
        Warning: The batches include cmake, which `brew upgrade` wouldn't upgrade.
      EOS
    end

    it "counts `--exclude`d formulae as planned and ignores casks" do
      stub_formula("cmake")
      stub_formula("gcc")
      preview.push("==> Would upgrade 3 outdated packages", "cmake    1.0 -> 2.0", "gcc      1.0 -> 2.0",
                   "firefox  1 -> 2")
      expect { run_command("--dry-run", "--exclude=gcc") }.not_to output.to_stderr
    end

    it "doesn't take an installed cask for a formula of the same name, or the other way round" do
      stub_formula("gcc", "2.0")
      stub_formula("cmake")
      (HOMEBREW_PREFIX/"Caskroom").mkpath
      %w[gcc cmake].each { |token| (HOMEBREW_PREFIX/"Caskroom"/token).mkpath }
      preview.push("==> Would upgrade 2 outdated packages", "gcc    1 -> 2", "cmake  1.0 -> 2.0")
      expect { run_command("--dry-run") }.not_to output.to_stderr
    end

    it "only checks without named arguments, where brew's preview lists everything it would upgrade" do
      stub_formula("cmake")
      preview.push("==> Would upgrade 1 requested outdated package", "cmake    1.0 -> 2.0")
      expect { run_command("--dry-run", "cmake") }.not_to output.to_stderr
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
