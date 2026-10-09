# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/upgrade"
require_relative "../../cmd/upgrade-timed"
require_relative "../support/bottles"
require_relative "../support/casks"
require_relative "../support/llm"

RSpec.describe Homebrew::Cmd::UpgradeTimed do
  include TimedBottleHelper
  include TimedCaskHelper

  let(:database) { Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json" }
  let(:receipt) { Pathname(__FILE__).dirname.parent/"fixtures/receipts/built.json" }
  let(:brew_calls) { [] }
  let(:brew_envs) { [] }
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
      TimedBottleHelper.bottle(self) if bottled
    end
    stub_formula_loader(formula)
    stub_bottle_manifest(formula, bottle_deps:) if bottled
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
    allow(Timed::Command).to receive(:broken_dependents).and_return([])
    allow(Timed::Runner).to receive(:stream) do |argv, env: {}, &block|
      brew_calls << argv
      brew_envs << env
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

    it "adds the LLM flags, which need `--llm-estimates` and can't be used with `--cask`", :aggregate_failures do
      argv = %w[--llm-estimates --llm-api-key-file=/key --llm-provider=openai --llm-url=https://example.com/v1
                --llm-model=m --llm-timeout=300 --llm-effort=low]
      args = described_class.new(argv).args
      expect([args.llm_estimates?, args.llm_api_key_file, args.llm_provider, args.llm_url, args.llm_model,
              args.llm_timeout, args.llm_effort])
        .to eq([true, "/key", "openai", "https://example.com/v1", "m", "300", "low"])
      expect { described_class.new(%w[--llm-model=m]) }.to raise_error(Homebrew::CLI::OptionConstraintError)
      expect { described_class.new(%w[--llm-timeout=300]) }.to raise_error(Homebrew::CLI::OptionConstraintError)
      expect { described_class.new(%w[--llm-effort=low]) }.to raise_error(Homebrew::CLI::OptionConstraintError)
      expect { described_class.new(%w[--cask --llm-effort=low]) }.to raise_error(Homebrew::CLI::OptionConflictError)
      expect { described_class.new(%w[--no-llm-estimates --llm-url=http://localhost]) }
        .to raise_error(Homebrew::CLI::OptionConstraintError)
      expect { described_class.new(%w[--cask --llm-estimates]) }.to raise_error(Homebrew::CLI::OptionConflictError)
    end

    it "takes `--llm-estimates` from `HOMEBREW_TIMED_LLM_ESTIMATES` set to anything, unless overridden or with " \
       "`--cask`" do
      ENV["HOMEBREW_TIMED_LLM_ESTIMATES"] = "0"
      enabled = [[], %w[--no-llm-estimates], %w[--cask], %w[--llm-model=m]].to_h do |argv|
        [argv, described_class.new(argv).args.llm_estimates?]
      end
      expect(enabled).to eq([] => true, %w[--no-llm-estimates] => false, %w[--cask] => false,
                            %w[--llm-model=m] => true)
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

    it "names the variable of every LLM setting", :aggregate_failures do
      expect(help).to include("Enabled by default if $HOMEBREW_TIMED_LLM_ESTIMATES is set.")
      %w[API_KEY_FILE PROVIDER URL MODEL TIMEOUT EFFORT].each do |name|
        expect(help).to include("$HOMEBREW_TIMED_LLM_#{name}"), "no $HOMEBREW_TIMED_LLM_#{name}"
      end
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
        ==> Would upgrade 3 formulae in 1 batch, estimated 53m35s
        ==> Batch 1 of 1: 53m35s
        lib                          pour     0m15s?
        cmake                        build     3m20s
        app                          build   50m00s?
        ==> Then check dependents for broken linkage, and reinstall broken ones from source
      EOS
    end

    it "doesn't say it checks dependents for broken linkage when the user has turned brew's check off" do
      ENV["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
      stub_formula("cmake")
      expect { run_command("--dry-run") }.to output(<<~EOS).to_stdout
        ==> Would upgrade 1 formula in 1 batch, estimated 3m20s
        ==> Batch 1 of 1: 3m20s
        cmake                        build     3m20s
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
        ==> Batch 2 of 3: 1h23m, keg-only llvm
        llvm                         build     1h23m
        ==> Batch 3 of 3 (--last): 50m00s
        gcc                          build    50m00s
        ==> Then check dependents for broken linkage, and reinstall broken ones from source
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
          new                          build    1m00s*
          cmake                        build     3m20s
          ==> Then check dependents for broken linkage, and reinstall broken ones from source
          ==> Excluded
          gcc
        EOS
    end

    it "plans named formulae and their outdated dependencies only" do
      stub_formula("lib")
      stub_formula("other")
      stub_formula("app", deps: %w[lib])
      expect { run_command("--dry-run", "app") }
        .to output(/\A==> Would upgrade 2 formulae in 1 batch.*^lib .*^app/m).to_stdout
    end

    it "plans a source build's outdated dependencies through current ones, but not their build dependencies" do
      stub_formula("tool")
      stub_formula("lib")
      stub_formula("mid", "2.0", deps: %w[lib], build_deps: %w[tool])
      stub_formula("app", deps: %w[mid])
      expect { run_command("--dry-run", "app") }
        .to output(/\A==> Would upgrade 2 formulae in 1 batch.*^lib .*^app/m).to_stdout
    end

    it "doesn't plan a poured formula's outdated dependency that its bottle's manifest is satisfied with" do
      stub_formula("lib")
      stub_formula("app", bottled: true, deps: %w[lib], bottle_deps: { "lib" => "1.0" })
      expect { run_command("--dry-run", "app") }.to output(/\A==> Would upgrade 1 formula in 1 batch/).to_stdout
    end

    it "plans a poured formula's outdated dependencies when its bottle's manifest can't be downloaded" do
      stub_formula("lib")
      app = stub_formula("app", bottled: true, deps: %w[lib], bottle_deps: { "lib" => "1.0" })
      bottle = app.bottle || raise("no bottle")
      allow(bottle).to receive(:fetch_tab).and_raise(DownloadError.new(bottle, RuntimeError.new("offline")))
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

    it "lists the outdated dependents brew's check finds for the formulae it upgrades, but doesn't plan or exclude" do
      lib = stub_formula("lib")
      app = stub_formula("app", deps: %w[lib])
      user = stub_formula("user", bottled: true, deps: %w[app])
      gcc = stub_formula("gcc")
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [lib, user, gcc], pinned: [], skipped: [])
      expect(Homebrew::Upgrade).to receive(:dependants).with([app], hash_including(dry_run: true))
                                                       .and_return(dependents)
      expect { run_command("--dry-run", "--exclude=gcc", "app", "gcc") }
        .to output(a_string_ending_with(<<~EOS)).to_stdout
          app                          build   50m00s?
          ==> Then upgrade outdated dependents
          user
          ==> Then check dependents for broken linkage, and reinstall broken ones from source
          ==> Excluded
          gcc
        EOS
    end

    it "lists no outdated dependents when it refuses every named formula, as brew then checks none" do
      allow(stub_formula("lib")).to receive(:pinned?).and_return(true)
      app = stub_formula("app", deps: %w[lib])
      dependent = stub_formula("dependent", bottled: true, deps: %w[app])
      allow(Homebrew::Upgrade).to receive(:dependants).and_call_original
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [dependent], pinned: [], skipped: [])
      allow(Homebrew::Upgrade).to receive(:dependants).with([app], anything).and_return(dependents)
      expect { run_command("--dry-run", "app") }.to output("==> No formulae to upgrade\n").to_stdout
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

  describe "LLM estimates" do
    include TimedLLMHelper

    let(:key_file) { llm_key_file }
    let(:requests) { [] }

    it "asks for the source builds with no history and no `--guess`, and marks every guess with `*`" do
      stub_formula("cmake")
      stub_formula("new")
      stub_formula("other")
      answer_with({ "new" => 300, "cmake" => 1 }, requests)
      expect { run_command("--dry-run", "--llm-estimates", "--llm-api-key-file=#{key_file}", "--guess=other=1m") }
        .to output(<<~EOS).to_stdout
          ==> Asking anthropic claude-sonnet-5-5 for 1 estimate
          ==> Would upgrade 3 formulae in 1 batch, estimated 9m20s
          ==> Batch 1 of 1: 9m20s
          other                        build    1m00s*
          cmake                        build     3m20s
          new                          build    5m00s*
          ==> Then check dependents for broken linkage, and reinstall broken ones from source
        EOS
    end

    it "falls back to the median, marked `?`, with a warning, when the provider fails", :aggregate_failures do
      stub_formula("new")
      answer_with(500, requests)
      expect { run_command("--dry-run", "--llm-estimates", "--llm-api-key-file=#{key_file}") }
        .to output(/^new +build +50m00s\?$/).to_stdout
        .and output(/estimates failed \(anthropic claude-sonnet-5-5\), using median build times: HTTP 500/).to_stderr
      expect(requests.length).to eq(2)
    end

    it "asks nothing about `--exclude`d formulae, and keeps nothing for them" do
      stub_formula("new")
      answer_with({ "new" => 300 }, requests)
      run_command("--dry-run", "--llm-estimates", "--llm-api-key-file=#{key_file}", "--exclude=new")
      expect([requests, JSON.parse(database.read).key?("estimates")]).to eq([[], false])
    end

    it "is off by default, whatever the other LLM settings" do
      stub_formula("new")
      answer_with({ "new" => 300 }, requests)
      ENV["HOMEBREW_TIMED_LLM_URL"] = "not a URL"
      ENV["HOMEBREW_TIMED_LLM_API_KEY_FILE"] = "/missing"
      run_command("--dry-run")
      expect(requests).to eq([])
    end

    it "stops on a settings error before any work" do
      expect(Timed::Command).not_to receive(:auto_update)
      expect { run_command("--dry-run", "--llm-estimates") }
        .to raise_error(UsageError, /LLM estimates need `--llm-api-key-file` unless `--llm-url` is set/)
    end

    it "never lets the key out, whether the provider answers, refuses it or can't be reached: not on screen, " \
       "in the log, receipts or batch logs, nor in any sub-call's arguments or environment, the calls after the " \
       "batches' too, which get no LLM flag either" do
      stub_formula("new")
      user = stub_formula("user", bottled: true, deps: %w[new])
      broken = stub_formula("broken", "2.0")
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user], pinned: [], skipped: []))
      installers = [instance_double(FormulaInstaller, formula: user)]
      allow(Homebrew::Upgrade).to receive_messages(dependent_formula_installers:        installers,
                                                   filter_dependent_formula_installers: installers)
      allow(Timed::Command).to receive(:broken_dependents).and_return([broken])
      results = key_leaks(database, receipt) do |argv|
        # Outdated again.
        FileUtils.rm_rf [HOMEBREW_CELLAR/"new/2.0", HOMEBREW_CELLAR/"user/2.0"]
        run_command(*argv, "new")
      end
      calls = ["upgrade new", "upgrade new", "upgrade user", "reinstall broken"]
      expect(results).to eq(%w[answered refused unreachable].to_h { |way| [way, [1, [], calls]] })
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
      stub_formula("app")
      run_command("--yes", "--guess=app=1m", "lib", "app")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times lib app]])
    end

    it "upgrades a formula in a call after one of its batch it needs, so brew never links it against the old " \
       "version of one that failed" do
      stub_formula("lib", bottled: true)
      stub_formula("app", deps: %w[lib])
      run_command("--yes", "app")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times lib],
                                        %w[upgrade --formula --yes --display-times app]])
    end

    it "upgrades formulae that need the same outdated dependency it leaves to brew in calls of their own, as " \
       "brew tries that dependency once a call" do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      stub_formula("tool", deps: %w[lib])
      run_command("--yes", "--exclude=lib", "app", "tool")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times app],
                                        %w[upgrade --formula --yes --display-times tool]])
    end

    it "runs each call without brew's installed-dependents check, then upgrades the outdated dependents brew " \
       "would, in a call of their own with their options only", :aggregate_failures do
      stub_formula("lib")
      app = stub_formula("app", deps: %w[lib])
      user = stub_formula("user", bottled: true, deps: %w[app])
      other = stub_formula("other", bottled: true, deps: %w[app])
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user, other], pinned: [], skipped: []))
      installers = [user, other].map { |formula| instance_double(FormulaInstaller, formula:) }
      # Brew's check of the bottles' dependencies, as it makes it before
      # upgrading anything, then again after the formulae, before the call.
      expect(Homebrew::Upgrade).to receive(:dependent_formula_installers)
        .with(having_attributes(upgradeable: [user, other]), [app], hash_including(keep_tmp: true))
        .and_return(installers)
      expect(Homebrew::Upgrade).to receive(:filter_dependent_formula_installers).with(installers) do
        expect(brew_calls.length).to eq(3)
        installers.take(1)
      end
      run_command("--yes", "--keep-tmp", "--fetch-HEAD", "app")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --formula --yes --display-times --fetch-HEAD --keep-tmp lib],
                                        %w[upgrade --formula --yes --display-times --fetch-HEAD --keep-tmp app],
                                        %w[upgrade --formula --yes --display-times --keep-tmp user]])
      no_check = { "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" => "1", "HOMEBREW_NO_ENV_HINTS" => "1" }
      expect(brew_envs.drop(1)).to eq([no_check] * 3)
      expect(builds.fetch("user").last).to include("verb" => "upgrade", "batch" => "dependents")
    end

    it "gives the calls after the batches its `--exclude`, for the commands they give to finish what they leave" do
      stub_formula("lib", "2.0")
      stub_formula("cmake")
      expect(Timed::Command).to receive(:after)
        .with([], [having_attributes(full_name: "cmake")], hash_including(excluded: %w[lib], own: %w[--exclude=lib]))
        .and_call_original
      run_command("--yes", "--exclude=lib", "cmake")
    end

    it "makes no call for outdated dependents, nor checks their bottles, when brew's check finds none" do
      stub_formula("cmake")
      expect(Homebrew::Upgrade).not_to receive(:dependent_formula_installers)
      run_command("--yes", "cmake")
      expect(brew_calls.length).to eq(2)
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

    it "upgrades the last casks after the outdated dependents and the broken ones, which they may need" do
      stub_formula("cmake")
      user = stub_formula("user", bottled: true, deps: %w[cmake])
      broken = stub_formula("broken", "2.0")
      stub_cask("firefox")
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user], pinned: [], skipped: []))
      installers = [instance_double(FormulaInstaller, formula: user)]
      allow(Homebrew::Upgrade).to receive_messages(dependent_formula_installers:        installers,
                                                   filter_dependent_formula_installers: installers)
      allow(Timed::Command).to receive(:broken_dependents).and_return([broken])
      run_command("--yes", "cmake", "firefox", "iterm2")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes firefox],
                                        %w[upgrade --formula --yes --display-times cmake],
                                        %w[upgrade --formula --yes --display-times user],
                                        %w[reinstall --formula --yes --display-times --build-from-source broken],
                                        %w[upgrade --cask --yes iterm2]])
    end

    it "compares each formula's estimate with the install time it logged once the run is done, after the last " \
       "casks, but not with `--dry-run`", :aggregate_failures do
      stub_formula("cmake")
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Runner).to receive(:stream) do |argv, &block|
        next true if argv.include?("--dry-run")

        keg = HOMEBREW_CELLAR/"cmake/2.0"
        keg.mkpath
        FileUtils.cp receipt, keg/"INSTALL_RECEIPT.json"
        ["🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n", "==> Installation times\n", "cmake  250.000 s\n"]
          .each { |line| block.call(line) }
        true
      end
      expect { run_command("--dry-run", "cmake", "iterm2") }.not_to output(/Estimated and actual times/).to_stdout
      expect { run_command("--yes", "cmake", "iterm2") }.to output(/
        ^==>\ Running\ the\ last\ cask:\ iterm2\n
        ==>\ Estimated\ and\ actual\ times\n
        formula\ {23}estimate\ {4}actual\ {3}error\n
        cmake\ {28}3m20s\ {5}4m10s\ {4}-20%\n\z
      /x).to_stdout
    end

    it "doesn't upgrade the last casks when Ctrl-C stops the calls after the batches, naming them with how to " \
       "upgrade them later", :aggregate_failures do
      stub_formula("cmake")
      stub_cask("firefox")
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Command).to receive(:broken_dependents).and_raise(Interrupt)
      expect { run_command("--yes", "cmake", "firefox", "iterm2") }
        .to raise_error(Interrupt).and output(<<~EOS).to_stderr
          Warning: The check for broken linkage didn't finish; not all the dependents of cmake were checked.
          Warning: Broken dependents not worked out, as Ctrl-C stopped that.
          Warning: Interrupted, so the cask to upgrade after the formulae didn't run: iterm2
          Upgrade it later with `brew upgrade --cask iterm2`.
        EOS
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes firefox],
                                        %w[upgrade --formula --yes --display-times cmake]])
    end

    it "names the formulae given to the run, not their outdated dependencies, to finish what a last cask needs " \
       "first when Ctrl-C stops the formulae, as some flags (e.g. `--build-from-source`) are only for those given" do
      stub_formula("newlib", nil)
      stub_formula("lib", deps: %w[newlib])
      stub_formula("app", deps: %w[lib])
      stub_cask("iterm2", stanzas: 'depends_on formula: "newlib"')
      allow(Timed::Runner).to receive(:run).and_raise(Interrupt)
      expect { run_command("--yes", "--keep-tmp", "app", "iterm2") }
        .to raise_error(Interrupt).and output(<<~EOS).to_stderr
          Warning: Interrupted, so the cask to upgrade after the formulae didn't run: iterm2
          1 cask needs formulae of this run that aren't installed, which brew would
          install for it, but not as this run would:
          iterm2: needs newlib
          Finish those first with `brew upgrade-timed --keep-tmp app`, then upgrade it with `brew upgrade --cask iterm2`.
        EOS
    end

    it "names a formula upgraded to its alias's new target as given, with `--exclude`, to finish what a last " \
       "cask needs first, as `brew upgrade-timed` wouldn't upgrade the new target, which isn't installed" do
      stub_formula("lib", "2.0")
      target = stub_formula("cmake", nil)
      allow(stub_formula("old")).to receive(:latest_formula).and_return(target)
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Runner).to receive(:run).and_raise(Interrupt)
      expect { run_command("--yes", "--exclude=lib", "old", "iterm2") }
        .to raise_error(Interrupt)
        .and output(/^Finish those first with `brew upgrade-timed --exclude=lib old`, /).to_stderr
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
        .to output("Error: `brew upgrade --cask --yes firefox` failed.\n").to_stderr
      expect(brew_calls.drop(1).map(&:last)).to eq(%w[firefox cmake iterm2])
      expect(Homebrew).to be_failed
    end

    it "upgrades a last cask that needs a formula that failed to upgrade, which brew leaves installed and alone",
       :aggregate_failures do
      cmake = stub_formula("cmake")
      FileUtils.cp receipt, HOMEBREW_CELLAR/"cmake/1.0/INSTALL_RECEIPT.json"
      # Brew loads an installed formula from its rack by the tap in its receipt,
      # else the real `cmake`, which has a bottle on some platforms.
      stub_formula_loader(cmake, "homebrew/core/cmake")
      stub_cask("iterm2", stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Runner).to receive(:run)
        .and_return(Timed::Runner::Outcome.new(unfinished: %w[cmake], stopped_early: false))
      expect { run_command("--yes", "--greedy", "cmake", "iterm2") }.not_to output.to_stderr
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes --greedy iterm2]])
    end

    it "upgrades a cask that needs a formula brew installs for one in the batches last, and not when that " \
       "formula didn't install", :aggregate_failures do
      stub_formula("lib", nil)
      stub_formula("app", deps: %w[lib])
      stub_cask("lib-app", stanzas: 'depends_on formula: "lib"')
      allow(Timed::Runner).to receive(:run)
        .and_return(Timed::Runner::Outcome.new(unfinished: %w[app], stopped_early: false))
      expect { run_command("--yes", "--keep-tmp", "app", "lib-app") }
        .to output(/^lib-app: needs lib\nFinish those first with `brew upgrade-timed --keep-tmp app`, then /)
        .to_stderr
      expect(brew_calls.drop(1)).to eq([])
    end

    it "upgrades a named cask with `--build-from-source` when no named formula is outdated, as brew does" do
      stub_formula("cmake", "2.0")
      stub_cask("iterm2")
      run_command("--yes", "--build-from-source", "cmake", "iterm2")
      expect(brew_calls.drop(1)).to eq([%w[upgrade --cask --yes iterm2]])
    end

    it "upgrades a cask named with `--minimum-version` or `--min-version`, without it, as planning applied it" do
      stub_cask("firefox")
      flags = %w[--minimum-version=1.5 --min-version=1.5]
      calls = flags.to_h do |flag|
        brew_calls.clear
        run_command("--yes", flag, "firefox")
        [flag, brew_calls.drop(1)]
      end
      expect(calls).to eq(flags.to_h { |flag| [flag, [%w[upgrade --cask --yes firefox]]] })
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
