# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/install"
require_relative "../../cmd/install-timed"
require_relative "../support/bottles"
require_relative "../support/casks"
require_relative "../support/llm"

RSpec.describe Homebrew::Cmd::InstallTimed do
  include TimedBottleHelper
  include TimedCaskHelper

  let(:database) { Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json" }
  let(:receipt) { Pathname(__FILE__).dirname.parent/"fixtures/receipts/built.json" }
  let(:brew_calls) { [] }
  let(:brew_envs) { [] }
  # Names brew fails to install.
  let(:failing) { [] }
  # What brew installs for a name, if not that formula.
  let(:installs) { {} }
  # A receipt's build times, other than the log would give them.
  let(:build_times) { { "verb" => "upgrade", "install_seconds" => 1.0, "started" => "2026-09-01T10:00:00-04:00" } }

  # A formula at version 2.0, in `tap` if given, loadable by name, with
  # `installed_version` in the Cellar (none when nil), linked into `opt` and,
  # if `linked` (unless keg-only by default), into the prefix. Its receipt is
  # for this computer's architecture, installed on request unless not
  # `on_request`, with `build_times` if given. `status` is `:deprecated` or
  # `:disabled` if given. A bottled one's manifest is never downloaded; given
  # `bottle_deps`, its tab lists them with the version each needs at least.
  def stub_formula(name, installed_version = nil, deps: [], keg_only: false, linked: !keg_only, bottled: false,
                   bottle_deps: nil, tap: nil, on_request: true, build_times: nil, status: nil)
    formula = formula(name, tap:) do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/#{name}-2.0.tgz"
      head "https://brew.sh/#{name}.git"
      deps.each { |dep| depends_on dep }
      keg_only "it is a test" if keg_only
      deprecate! date: "2020-01-01", because: :unmaintained if status == :deprecated
      disable! date: "2020-01-01", because: :unmaintained if status == :disabled
      TimedBottleHelper.bottle(self) if bottled
    end
    stub_bottle_manifest(formula, bottle_deps:) if bottled
    stub_formula_loader(formula)
    stub_formula_loader(formula, name) if tap
    if installed_version
      keg = HOMEBREW_CELLAR/name/installed_version
      keg.mkpath
      data = JSON.parse(receipt.read).merge("arch" => Hardware::CPU.arch.to_s, "installed_on_request" => on_request,
                                            "build_times" => build_times)
      (keg/"INSTALL_RECEIPT.json").write(JSON.pretty_generate(data.compact))
      [HOMEBREW_PREFIX/"opt", *(HOMEBREW_LINKED_KEGS if linked)].each do |dir|
        dir.mkpath
        FileUtils.ln_s keg, dir/name
      end
    end
    formula
  end

  # Removes `name`'s keg and links, and the receipts brew has read, for
  # another run.
  def remove_keg(name)
    FileUtils.rm_r [HOMEBREW_CELLAR/name, HOMEBREW_PREFIX/"opt"/name, HOMEBREW_LINKED_KEGS/name]
    Tab.clear_cache
  end

  def build(seconds) = { "status" => "built", "install_seconds" => seconds, "version" => "2.0" }

  def builds = JSON.parse(database.read)["packages"].transform_values { |package| package["builds"] }

  def run_command(*argv) = described_class.new(argv).run

  def run_to_end(*argv)
    run_command(*argv)
  rescue SystemExit
    nil
  end

  # Brew: a call installs each formula it is given, by name or file, or what
  # `installs` lists for it, at 2.0, with a new receipt for this computer, in
  # `opt`, printing its summary line, except `failing` ones. Brew's plan and
  # preinstall checks run in-process, so are left out unless a spec asks for
  # them, and the developer tools are installed. What brew notes about the
  # support tier (e.g. for `--cc`), which it prints as the process exits, is
  # dropped after each spec. A cask call succeeds, and there is a terminal for
  # sudo.
  after { Homebrew::Diagnostic.support_tiers.clear }

  before do
    allow(Formulary).to receive(:loader_for).and_call_original
    allow(Cask::CaskLoader).to receive(:for).and_call_original
    allow(Timed::Command).to receive(:auto_update)
    allow(Timed::Command).to receive(:brew) do |_env, argv|
      brew_calls << argv
      true
    end
    allow(Timed::Casks).to receive(:terminal?).and_return(true)
    allow(Timed::Command).to receive(:broken_dependents).and_return([])
    allow(Homebrew::Install).to receive(:ask_formulae)
    allow(Homebrew::Install).to receive(:perform_preinstall_checks_once)
    allow(DevelopmentTools).to receive(:installed?).and_return(true)
    allow(Timed::Runner).to receive(:stream) do |argv, env: {}, &block|
      brew_calls << argv
      brew_envs << env
      names = argv.drop(1).reject { |arg| arg.start_with?("-") }.map { |arg| File.basename(arg, ".rb") }
      names.flat_map { |name| installs.fetch(name, [name]) }.map do |name|
        block.call("==> Installing #{name}\n")
        if failing.include?(name)
          block.call("Error: #{name}: it failed\n")
          next false
        end

        keg = HOMEBREW_CELLAR/name/"2.0"
        keg.mkpath
        data = JSON.parse(receipt.read).merge("time" => Time.now.to_i, "arch" => Hardware::CPU.arch.to_s)
        (keg/"INSTALL_RECEIPT.json").write(JSON.pretty_generate(data))
        (HOMEBREW_PREFIX/"opt").mkpath
        FileUtils.rm_f HOMEBREW_PREFIX/"opt"/name
        FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt"/name
        block.call("🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n")
        true
      end.all?
    end
    database.dirname.mkpath
    database.write(JSON.generate("schema_version" => 1,
                                 "packages"       => { "cmake" => { "builds" => [build(200.0)] },
                                                       "llvm"  => { "builds" => [build(5000.0)] },
                                                       "gcc"   => { "builds" => [build(3000.0)] } }))
  end

  describe "flags" do
    it "accepts every `brew install` option" do
      options = ->(command) { command.parser.processed_options.map { |short, long| long || short } }
      expect(options.call(Timed::Command.builtin("install")) - options.call(described_class)).to eq([])
    end

    it "keeps `brew install`'s conflicts" do
      expect(Timed::Command.builtin("install").parser.conflicts - described_class.parser.conflicts).to eq([])
    end

    it "adds its own flags, none of them but `--no-stamp-receipts` with `--cask`", :aggregate_failures do
      argv = %w[--guess=llvm=1h --estimator=median --last=llvm --exclude=gcc --no-stamp-receipts llvm]
      args = described_class.new(argv).args
      expect([args.guess, args.estimator, args.last, args.exclude, args.no_stamp_receipts?])
        .to eq([%w[llvm=1h], "median", %w[llvm], %w[gcc], true])
      expect { described_class.new(%w[--cask --last=llvm llvm]) }
        .to raise_error(Homebrew::CLI::OptionConflictError)
    end

    it "shows the usage, its own description and what `--exclude` leaves to brew", :aggregate_failures do
      help = described_class.parser.generate_help_text(remaining_args: []).gsub(/\s+/, " ")
      expect(help).to start_with("Usage: brew install-timed [options] formula|cask [...] Install formulae " \
                                 "like brew install, in timed batches:")
      expect(help).to include("Homebrew may still install or upgrade them as dependencies of the others.")
    end

    it "refuses `--interactive`, which needs a terminal" do
      expect { run_command("--interactive", "cmake") }
        .to raise_error(UsageError, "Invalid usage: `--interactive` needs a terminal; " \
                                    "use `brew install --interactive` instead.")
    end

    it "fails on unknown `--last`, `--exclude` and `--guess` names, naming the flag, before running anything",
       :aggregate_failures do
      stub_formula("cmake")
      flags = %w[--last=nope --exclude=nope --guess=nope=1m]
      errors = flags.to_h do |flag|
        run_command("--dry-run", flag, "cmake")
        [flag, nil]
      rescue UsageError => e
        [flag, e.message.sub(/(?<=\.) Did you mean .*/, "")]
      end
      expect(errors).to eq(flags.to_h do |flag|
        [flag, "Invalid usage: `#{flag[/--\w+/]}`: No available formula with the name \"nope\"."]
      end)
      expect(brew_calls).to eq([])
    end
  end

  describe "--dry-run" do
    it "auto-updates first, with the original arguments" do
      stub_formula("cmake")
      expect(Timed::Command).to receive(:auto_update).with(command: "install-timed", argv: %w[--dry-run cmake])
      run_command("--dry-run", "cmake")
    end

    it "installs the taps of the names it is given first, as `brew install` does" do
      tap = Tap.fetch("user", "tap")
      stub_formula("app", tap:)
      expect(tap).to receive(:ensure_installed!)
      run_command("--dry-run", "user/tap/app")
    end

    it "loads the names as `brew install` does, without warnings about renamed or migrated formulae" do
      stub_formula("cmake")
      expect(Formulary).to receive(:factory).with("cmake", hash_including(warn: false)).and_call_original
      run_command("--dry-run", "cmake")
    end

    it "prints brew's plan in-process, as `brew install --dry-run` prints it, then the batches, running no brew",
       :aggregate_failures do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      installer = ->(name) { an_object_having_attributes(formula: an_object_having_attributes(full_name: name)) }
      expect(Homebrew::Install).to receive(:ask_formulae)
        .with(contain_exactly(installer.call("lib"), installer.call("app")),
              an_instance_of(Homebrew::Upgrade::Dependents), hash_including(prompt: false, verbose: true))
        .ordered
      expect(Timed::Command).to receive(:show_plan).ordered.and_call_original
      expect { run_command("--dry-run", "--verbose", "--guess=lib=1h", "--last=lib", "app", "lib") }
        .to output(<<~EOS).to_stdout
          ==> Would install 2 formulae in 2 batches, estimated 1h50m
          ==> Batch 1 of 2 (--last): 1h00m
          lib                          build    1h00m*
          ==> Batch 2 of 2 (--last): 50m00s, app needs lib
          app                          build   50m00s?
          ==> Then check dependents for broken linkage, and reinstall broken ones from source
        EOS
      expect(brew_calls).to eq([])
    end

    it "lists the outdated dependents brew's check finds for the formulae, other than named or excluded ones" do
      lib = stub_formula("lib")
      app = stub_formula("app", deps: %w[lib])
      user = stub_formula("user", "1.0", deps: %w[app], bottled: true)
      gcc = stub_formula("gcc", "1.0")
      # Named, but refused by brew's checks of each formula.
      old = stub_formula("old", "1.0", deps: %w[app], status: :disabled)
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [lib, user, gcc, old], pinned: [], skipped: [])
      expect(Homebrew::Upgrade).to receive(:dependants).with([lib, app], anything).and_return(dependents)
      expect { run_command("--dry-run", "--exclude=gcc", "--guess=lib=1m", "app", "lib", "gcc", "old") }
        .to output(a_string_ending_with(<<~EOS)).to_stdout
          app                          build   50m00s?
          ==> Then upgrade outdated dependents
          user
          ==> Then check dependents for broken linkage, and reinstall broken ones from source
          ==> Excluded
          gcc
        EOS
    end

    it "prints what brew would install, with each formula's dependencies" do
      allow(Homebrew::Install).to receive(:ask_formulae).and_call_original
      stub_formula("dep")
      stub_formula("app", deps: %w[dep])
      expect { run_command("--dry-run", "app") }
        .to output(/\A==> Would install 1 formula:\napp 2\.0\n==> Would install 1 dependency for app:\ndep\n/)
        .to_stdout
    end

    it "plans only the named formulae `brew install` would install or upgrade, with brew's messages about each",
       :aggregate_failures do
      stub_formula("dep")
      stub_formula("new", deps: %w[dep])
      stub_formula("old", "1.0")
      stub_formula("current", "2.0")
      allow(stub_formula("pinned", "1.0")).to receive(:pinned?).and_return(true)
      upgrade = Regexp.escape("old 1.0 is already installed but outdated (so it will be upgraded).")
      current = Regexp.escape("Warning: current 2.0 is already installed and up-to-date.")
      expect { run_command("--dry-run", "current", "pinned", "old", "new") }
        .to output(/\A#{upgrade}\n==> Would install 2 formulae in 1 batch.*^new .*^old /m).to_stdout
        .and output(/\A#{current}.*^Error: pinned 1\.0 is already installed/m).to_stderr
      expect(Homebrew).not_to be_failed
    end

    it "fetches the bottle manifests after the preinstall checks and `--cc` warning, as brew does" do
      stub_formula("cmake")
      queue = instance_double(Homebrew::DownloadQueue, shutdown: nil)
      allow(Homebrew::DownloadQueue).to receive(:new).and_return(queue)
      expect(Homebrew::Install).to receive(:perform_preinstall_checks_once).ordered
      expect(Homebrew::Install).to receive(:check_cc_argv).ordered
      expect(queue).to receive(:fetch)
        .with(only: Resource::BottleManifest, heading: "Downloading bottle manifests", allow_failures: true).ordered
      run_command("--dry-run", "cmake")
    end

    it "shuts down its download queue when a preinstall check stops the command" do
      stub_formula("cmake")
      queue = instance_double(Homebrew::DownloadQueue, fetch: nil)
      allow(Homebrew::DownloadQueue).to receive(:new).and_return(queue)
      allow(Homebrew::Install).to receive(:perform_preinstall_checks_once).and_raise(SystemExit)
      expect(queue).to receive(:shutdown)
      expect { run_command("--dry-run", "cmake") }.to raise_error(SystemExit)
    end

    it "plans the dependencies of each formula with `--only-dependencies`, installed ones too, without estimates, " \
       "so dependencies first, then by name, splitting only for `--last`" do
      stub_formula("current", "2.0")
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      stub_formula("gcc")
      argv = %w[--dry-run --only-dependencies --guess=lib=2h --last=gcc app lib current gcc]
      expect { run_command(*argv) }.to output(<<~EOS).to_stdout
        ==> Would install the dependencies of 4 formulae in 2 batches
        ==> Batch 1 of 2
        dependencies of current
        dependencies of lib
        dependencies of app
        ==> Batch 2 of 2 (--last)
        dependencies of gcc
        ==> Then check dependents for broken linkage, and reinstall broken ones from source
      EOS
    end

    it "doesn't plan an outdated formula with `HOMEBREW_NO_INSTALL_UPGRADE`, as `brew install` doesn't" do
      ENV["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"
      stub_formula("old", "1.0")
      expect { run_command("--dry-run", "old") }.to output("==> No formulae to install\n").to_stdout
    end

    it "splits batches and gives the reasons, leaving out `--exclude`d formulae" do
      stub_formula("cmake")
      stub_formula("llvm", deps: %w[cmake])
      stub_formula("gcc")
      expect { run_command("--dry-run", "--exclude=gcc", "llvm", "cmake", "gcc") }.to output(<<~EOS).to_stdout
        ==> Would install 2 formulae in 2 batches, estimated 1h26m
        ==> Batch 1 of 2: 3m20s
        cmake                        build     3m20s
        ==> Batch 2 of 2: 1h23m, llvm needs cmake
        llvm                         build     1h23m
        ==> Then check dependents for broken linkage, and reinstall broken ones from source
        ==> Excluded
        gcc
      EOS
    end

    it "doesn't split before a slow keg-only formula, which only `brew upgrade` moves first" do
      stub_formula("gcc")
      stub_formula("llvm", "1.0", keg_only: true)
      expect { run_command("--dry-run", "llvm", "gcc") }.to output(/^==> Would install 2 formulae in 1 batch/)
        .to_stdout
    end

    it "estimates a bottled formula as a pour, unless built from source by a flag" do
      stub_formula("lib", bottled: true)
      flags = [[], %w[--build-from-source], %w[--build-bottle], %w[--cc=gcc-9], %w[--HEAD]]
      pours = flags.to_h do |flag|
        pour = T.let(nil, T.nilable(T::Boolean))
        allow(Timed::Command).to receive(:show_plan) { |_, _, estimates| pour = estimates.fetch("lib").pour }
        run_command("--dry-run", *flag, "lib")
        [flag, pour]
      end
      expect(pours).to eq(flags.to_h { |flag| [flag, flag.empty?] })
    end

    it "stops where `brew install` stops before installing anything, running nothing" do
      stub_formula("cmake")
      head_only = formula("headonly") do
        T.bind(self, T.class_of(Formula))
        head "https://brew.sh/headonly.git"
      end
      stub_formula_loader(head_only)
      allow(DevelopmentTools).to receive(:installed?).and_return(false)
      runs = {
        "unknown name"   => %w[cmake nope],
        "HEAD-only"      => %w[cmake headonly],
        "no build tools" => %w[--build-from-source cmake],
        "--env"          => %w[--env=std cmake],
      }
      stopped = runs.transform_values do |argv|
        run_command("--yes", *argv)
        nil
      rescue FormulaOrCaskUnavailableError, BuildFlagsError, MethodDeprecatedError, SystemExit => e
        e.class
      end
      expect([stopped, brew_calls]).to eq([{ "unknown name"   => FormulaUnavailableError,
                                             "HEAD-only"      => SystemExit,
                                             "no build tools" => BuildFlagsError,
                                             "--env"          => MethodDeprecatedError }, []])
    end

    it "fails a formula brew can't install with brew's message, leaving it out, and installs the others",
       :aggregate_failures do
      stub_formula("app", deps: %w[gone])
      allow(stub_formula("lib", "1.0")).to receive(:pinned?).and_return(true)
      stub_formula("tool", deps: %w[lib])
      stub_formula("cmake")
      unavailable = Regexp.escape('Error: app: No available formula with the name "gone" (dependency of app).')
      pinned = Regexp.escape("Error: You must `brew unpin lib` as installing tool requires the latest version of " \
                             "pinned dependencies.")
      # Brew may add a suggestion to the first.
      expect { run_command("--yes", "app", "tool", "cmake") }
        .to output(/\A#{unavailable}[^\n]*\n#{pinned}\n\z/).to_stderr
      expect([brew_calls, Homebrew.failed?]).to eq([[%w[install --formula --yes --display-times cmake]], true])
    end

    it "checks each formula as brew does before its plan: a disabled or forbidden one fails and is left out, " \
       "a deprecated one warns", :aggregate_failures do
      stub_formula("old", status: :disabled)
      stub_formula("dated", status: :deprecated)
      stub_formula("banned")
      stub_formula("cmake")
      ENV["HOMEBREW_FORBIDDEN_FORMULAE"] = "banned"
      expect { run_command("--yes", "old", "dated", "banned", "cmake") }
        .to output(/\AError: old has been disabled .*^Warning: dated has been deprecated .*^Error: .*banned/m)
        .to_stderr
      expect([brew_calls, Homebrew.failed?]).to eq([[%w[install --formula --yes --display-times cmake dated]], true])
    end

    it "warns and makes brew's preinstall checks once, as `brew install` does before its plan, even with " \
       "`--dry-run`" do
      stub_formula("cmake")
      expect(Homebrew::Install).to receive(:perform_preinstall_checks_once).ordered
      expect(Homebrew::Install).to receive(:ask_formulae).ordered
      ignore = Regexp.escape("Warning: `--ignore-dependencies` is an unsupported Homebrew developer option!")
      expect { run_command("--dry-run", "--ignore-dependencies", "--cc=gcc-9", "cmake") }
        .to output(/\A#{ignore}\n.*^Warning: You passed `--cc=gcc-9`\.\n\z/m).to_stderr
    end

    it "doesn't ask for confirmation" do
      stub_formula("cmake")
      allow(Homebrew::Install).to receive(:formulae_ask_prompt_needed?).and_return(true)
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_command("--dry-run", "cmake")
    end
  end

  describe "LLM estimates" do
    include TimedLLMHelper

    let(:requests) { [] }
    let(:local) { %w[--llm-estimates --llm-url=http://127.0.0.1:11434/v1/chat/completions --llm-model=qwen2.5:7b] }

    # A local server answers, as OpenAI does.
    before { answer_with({ "new" => 300 }, requests, provider: "openai") }

    it "asks for the named source builds with no history, without a key for a local server, and marks them `*`" do
      stub_formula("cmake")
      stub_formula("new")
      expect { run_command("--dry-run", *local, "cmake", "new") }.to output(<<~EOS).to_stdout
        ==> Asking qwen2.5:7b at 127.0.0.1:11434 for 1 estimate
        ==> Would install 2 formulae in 1 batch, estimated 8m20s
        ==> Batch 1 of 1: 8m20s
        cmake                        build     3m20s
        new                          build    5m00s*
        ==> Then check dependents for broken linkage, and reinstall broken ones from source
      EOS
    end

    it "asks nothing about `--exclude`d formulae, and keeps nothing for them" do
      stub_formula("cmake")
      stub_formula("new")
      run_command("--dry-run", *local, "--exclude=new", "cmake", "new")
      expect([requests, JSON.parse(database.read).key?("estimates")]).to eq([[], false])
    end

    it "asks nothing with `--only-dependencies`, which has no estimates" do
      stub_formula("new")
      run_command("--dry-run", "--only-dependencies", *local, "new")
      expect(requests).to eq([])
    end

    it "never lets the key out, whether the provider answers, refuses it or can't be reached: not on screen, " \
       "in the log, receipts or batch logs, nor in any sub-call's arguments or environment, the calls after the " \
       "batches' too, which get no LLM flag either" do
      stub_formula("new")
      user = stub_formula("user", "1.0", deps: %w[new], bottled: true)
      broken = stub_formula("broken", "2.0", deps: %w[new])
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user], pinned: [], skipped: []))
      installers = [instance_double(FormulaInstaller, formula: user)]
      allow(Homebrew::Upgrade).to receive_messages(dependent_formula_installers:        installers,
                                                   filter_dependent_formula_installers: installers)
      allow(Timed::Command).to receive(:broken_dependents).and_return([broken])
      results = key_leaks(database, receipt) do |argv|
        # Not installed again, and the dependent outdated again.
        FileUtils.rm_rf [HOMEBREW_CELLAR/"new", HOMEBREW_PREFIX/"opt/new", HOMEBREW_CELLAR/"user/2.0"]
        Tab.clear_cache
        run_to_end(*argv, "new")
      end
      calls = ["install new", "upgrade user", "reinstall broken"]
      expect(results).to eq(%w[answered refused unreachable].to_h { |way| [way, [1, [], calls]] })
    end
  end

  describe "build times brew drops from receipts" do
    it "puts back the build times brew drops when it marks an installed formula as installed on request, " \
       "as they were, and stamps no other receipt", :aggregate_failures do
      stamped = {}
      names = %w[cmake gcc]
      [%w[--dry-run], %w[--yes]].each do |flags|
        stub_formula("cmake", "2.0", on_request: false, build_times:)
        stub_formula("gcc", "2.0", on_request: false)
        run_command(*flags, *names)
        stamped[flags] = names.to_h do |name|
          [name, JSON.parse((HOMEBREW_CELLAR/name/"2.0/INSTALL_RECEIPT.json").read)
                     .slice("installed_on_request", "build_times")]
        end
        names.each { |name| remove_keg(name) }
      end
      after = { "cmake" => { "installed_on_request" => true, "build_times" => build_times },
                "gcc"   => { "installed_on_request" => true } }
      expect([stamped, brew_calls]).to eq([{ %w[--dry-run] => after, %w[--yes] => after }, []])
    end

    it "warns about a receipt it can't put the build times back in, and still stops where brew stops" do
      stub_formula("cmake", "2.0", on_request: false, build_times:)
      head_only = formula("headonly") do
        T.bind(self, T.class_of(Formula))
        head "https://brew.sh/headonly.git"
      end
      stub_formula_loader(head_only)
      allow(Timed::Receipts).to receive(:stamp).and_raise(Errno::EACCES)
      expect { run_command("--yes", "cmake", "headonly") }
        .to raise_error(SystemExit)
        .and output(%r{^Warning: Couldn't stamp \S+/opt/cmake/INSTALL_RECEIPT\.json: Permission denied$}).to_stderr
    end

    it "warns about a receipt it can't read again, and still stops where brew stops" do
      stub_formula("cmake", "2.0", on_request: false, build_times:)
      head_only = formula("headonly") do
        T.bind(self, T.class_of(Formula))
        head "https://brew.sh/headonly.git"
      end
      stub_formula_loader(head_only)
      read = []
      allow(Timed::Receipts).to receive(:build_times) do |formula|
        raise Errno::EACCES if read.include?(formula.name)

        read << formula.name
        build_times if formula.name == "cmake"
      end
      expect { run_command("--yes", "cmake", "headonly") }
        .to raise_error(SystemExit)
        .and output(%r{^Warning: Couldn't stamp \S+/opt/cmake/INSTALL_RECEIPT\.json: Permission denied$}).to_stderr
    end

    it "doesn't read receipts with `--no-stamp-receipts`" do
      stub_formula("cmake", "2.0", on_request: false, build_times:)
      expect(Timed::Receipts).not_to receive(:build_times)
      run_command("--dry-run", "--no-stamp-receipts", "cmake")
    end

    it "puts them back even when brew then stops, but not with `--no-stamp-receipts`" do
      stamped = {}
      [%w[--yes], %w[--yes --no-stamp-receipts]].each do |flags|
        stub_formula("cmake", "2.0", on_request: false, build_times:)
        head_only = formula("headonly") do
          T.bind(self, T.class_of(Formula))
          head "https://brew.sh/headonly.git"
        end
        stub_formula_loader(head_only)
        expect { run_command(*flags, "cmake", "headonly") }.to raise_error(SystemExit)
        stamped[flags] = JSON.parse((HOMEBREW_CELLAR/"cmake/2.0/INSTALL_RECEIPT.json").read)["build_times"]
        remove_keg("cmake")
      end
      expect(stamped).to eq(%w[--yes] => build_times, %w[--yes --no-stamp-receipts] => nil)
    end
  end

  describe "Homebrew's support tier notice" do
    it "is left for brew to print as the command exits, with `--dry-run` or nothing planned, but not when " \
       "batches run, which each print it" do
      stub_formula("cmake")
      runs = { "--dry-run" => %w[--dry-run cmake], "nothing planned" => %w[--yes --exclude=cmake cmake],
               "batches" => %w[--yes cmake] }
      tiers = runs.transform_values do |argv|
        Homebrew::Diagnostic.support_tiers.clear
        run_command("--cc=gcc-9", *argv)
        Homebrew::Diagnostic.support_tiers.dup
      end
      expect(tiers).to eq("--dry-run" => [3], "nothing planned" => [3], "batches" => [])
    end
  end

  describe "confirmation" do
    it "asks once, by `brew install`'s rule for the formulae it runs and their dependents" do
      stub_formula("cmake")
      stub_formula("gcc")
      expect(Homebrew::Install).to receive(:formulae_ask_prompt_needed?)
        .with([an_object_having_attributes(formula: an_object_having_attributes(full_name: "cmake"))],
              an_instance_of(Homebrew::Upgrade::Dependents))
        .and_return(true)
      expect(Homebrew::Ask).to receive(:confirm?).with(action: "installation").once.and_return(true)
      run_to_end("--exclude=gcc", "cmake", "gcc")
    end

    it "prints and asks about an outdated dependency a pour's bottle is fine with, as brew does before reading " \
       "the bottle's manifest" do
      allow(Homebrew::Install).to receive(:ask_formulae).and_call_original
      stub_formula("lib", "1.0")
      stub_formula("app", deps: %w[lib], bottled: true, bottle_deps: { "lib" => "1.0" })
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      expect { run_to_end("app") }.to output(/^==> Would upgrade 1 dependency for app:\nlib\n/).to_stdout
    end

    it "asks when brew would install a dependency of a named formula" do
      stub_formula("dep")
      stub_formula("app", deps: %w[dep])
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("app")
    end

    it "asks when brew would also upgrade outdated dependents of the formulae" do
      app = stub_formula("app", "1.0")
      dependent = stub_formula("dependent", "1.0", deps: %w[app], bottled: true)
      dependents = Homebrew::Upgrade::Dependents.new(upgradeable: [dependent], pinned: [], skipped: [])
      expect(Homebrew::Upgrade).to receive(:dependants).with([app], hash_including(ask: true)).and_return(dependents)
      expect(Homebrew::Ask).to receive(:confirm?).once.and_return(true)
      run_to_end("app")
    end

    it "says once that dependents aren't checked with `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`, as brew does",
       :aggregate_failures do
      ENV["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
      stub_formula("app", "1.0")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      warning = "`$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set: not checking for outdated"
      expect { run_to_end("app") }.to output(satisfy { |text| text.scan(warning).length == 1 }).to_stderr
    end

    it "doesn't ask when brew would install only the named formulae" do
      stub_formula("app")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_to_end("app")
    end

    it "doesn't ask with `--yes` or `HOMEBREW_NO_ASK`" do
      stub_formula("cmake")
      allow(Homebrew::Install).to receive(:formulae_ask_prompt_needed?).and_return(true)
      asks = 0
      allow(Homebrew::Ask).to receive(:confirm?) { asks += 1 }
      ways = { "--yes" => [%w[--yes cmake], nil], "HOMEBREW_NO_ASK" => [%w[cmake], "1"] }
      asked = ways.to_h do |way, (argv, no_ask)|
        ENV["HOMEBREW_NO_ASK"] = no_ask
        before = asks
        run_to_end(*argv)
        [way, asks - before]
      end
      expect(asked).to eq("--yes" => 0, "HOMEBREW_NO_ASK" => 0)
    end

    it "carries on without a terminal, where brew doesn't ask" do
      stub_formula("dep")
      stub_formula("app", deps: %w[dep])
      allow(Homebrew::Ask).to receive(:confirm?).and_return(false)
      run_command("app")
      expect(brew_calls.last).to eq(%w[install --formula --yes --display-times app])
    end
  end

  describe "running the batches" do
    it "runs each batch with the forwarded formula flags but not its own" do
      stub_formula("cmake")
      run_command("--yes", "--verbose", "--force", "--HEAD", "--include-test", "--as-dependency", "--overwrite",
                  "--skip-post-install", "--guess=cmake=1m", "--no-stamp-receipts", "--zap", "cmake")
      flags = %w[--force --verbose --include-test --HEAD --skip-post-install --as-dependency --overwrite]
      expect(brew_calls).to eq([["install", "--formula", "--yes", "--display-times", *flags, "cmake"]])
    end

    it "builds every formula of a batch from source in one call with `--build-from-source`, as each is named" do
      stub_formula("lib", bottled: true)
      stub_formula("app", deps: %w[lib])
      run_command("--yes", "--build-from-source", "--debug-symbols", "--guess=lib=1m", "app", "lib")
      expect(brew_calls).to eq([%w[install --formula --yes --display-times --build-from-source --debug-symbols lib
                                   app]])
    end

    it "runs each batch without brew's installed-dependents check, so an earlier batch's check never upgrades a " \
       "later batch's formula, then upgrades the outdated dependents brew would, with their options only, then " \
       "reinstalls from source the dependents with broken linkage of what the run built", :aggregate_failures do
      lib = stub_formula("lib", bottled: true)
      app = stub_formula("app", "1.0", deps: %w[lib], bottled: true)
      user = stub_formula("user", "1.0", deps: %w[lib], bottled: true)
      other = stub_formula("other", "1.0", deps: %w[lib], bottled: true)
      broken = stub_formula("broken", "2.0", deps: %w[lib])
      expect(Timed::Command).to receive(:dependents_to_check) do |checked, poured:|
        expect([checked.map(&:full_name), poured]).to match([contain_exactly("lib", "app", "user"), []])
        [broken]
      end
      expect(Timed::Command).to receive(:broken_dependents).with([broken]).and_return([broken])
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [app, user, other], pinned: [], skipped: []))
      installers = [user, other].map { |formula| instance_double(FormulaInstaller, formula:) }
      # Brew's check of the bottles' dependencies, as it makes it before
      # installing anything, then again after the formulae, before the call.
      expect(Homebrew::Upgrade).to receive(:dependent_formula_installers)
        .with(having_attributes(upgradeable: [user, other]), [lib, app], hash_including(keep_tmp: true))
        .and_return(installers)
      expect(Homebrew::Upgrade).to receive(:filter_dependent_formula_installers).with(installers) do
        expect(brew_calls.length).to eq(2)
        installers.take(1)
      end
      run_command("--yes", "--build-from-source", "--keep-tmp", "--guess=lib=1h", "--last=app", "lib", "app")
      expect(brew_calls).to eq([%w[install --formula --yes --display-times --build-from-source --keep-tmp lib],
                                %w[install --formula --yes --display-times --build-from-source --keep-tmp app],
                                %w[upgrade --formula --yes --display-times --keep-tmp user],
                                %w[reinstall --formula --yes --display-times --build-from-source --keep-tmp broken]])
      no_check = { "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" => "1", "HOMEBREW_NO_ENV_HINTS" => "1" }
      expect(brew_envs).to eq([no_check] * 4)
      expect([builds.fetch("user").last, builds.fetch("broken").last])
        .to match([include("verb" => "upgrade", "batch" => "dependents"),
                   include("status" => "built", "verb" => "reinstall", "batch" => "linkage")])
    end

    it "gives `brew upgrade-timed` with `--exclude` to finish an outdated dependent that failed, so brew's own " \
       "check there doesn't upgrade an excluded outdated dependent" do
      stub_formula("cmake")
      user = stub_formula("user", "1.0", deps: %w[cmake], bottled: true)
      other = stub_formula("other", "1.0", deps: %w[cmake], bottled: true)
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user, other], pinned: [], skipped: []))
      installers = [instance_double(FormulaInstaller, formula: user)]
      allow(Homebrew::Upgrade).to receive_messages(dependent_formula_installers:        installers,
                                                   filter_dependent_formula_installers: installers)
      failing << "user"
      advice = "1 outdated dependent did not upgrade: user\n" \
               "To finish, run:\n  brew upgrade-timed --exclude=other user\n"
      expect { run_command("--yes", "--exclude=other", "cmake") }
        .to output(/^Error: #{Regexp.escape(advice)}/).to_stderr
    end

    it "makes no calls after the batches when the user has turned off brew's installed-dependents check, " \
       "which then stays off in every call" do
      ENV["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
      stub_formula("cmake")
      expect(Timed::Command).not_to receive(:broken_dependents)
      run_command("--yes", "cmake")
      expect([brew_calls.length, brew_envs]).to eq([1, [{}]])
    end

    it "names a formula given as a file to `brew install` by that file, made absolute, and logs it by name",
       :aggregate_failures do
      dir = mktmpdir
      (dir/"foo.rb").write("class Foo < Formula\n  url \"https://brew.sh/foo-2.0.tgz\"\nend\n")
      Dir.chdir(dir) { run_command("--yes", "foo.rb") }
      expect(brew_calls.last).to eq(["install", "--formula", "--yes", "--display-times",
                                     (dir/"foo.rb").realpath.to_s])
      expect(builds.fetch("foo").last).to include("status" => "built", "verb" => "install")
    end

    it "logs each install and stamps its receipt", :aggregate_failures do
      stub_formula("cmake")
      run_command("--yes", "cmake")
      expect(builds.fetch("cmake").last).to include("version" => "2.0", "status" => "built", "verb" => "install")
      expect(JSON.parse((HOMEBREW_CELLAR/"cmake/2.0/INSTALL_RECEIPT.json").read)["build_times"])
        .to include("verb" => "install", "build_seconds" => 9.0)
    end

    it "leaves receipts as brew wrote them with `--no-stamp-receipts`, but still logs the installs",
       :aggregate_failures do
      stub_formula("cmake")
      run_command("--yes", "--no-stamp-receipts", "cmake")
      expect(JSON.parse((HOMEBREW_CELLAR/"cmake/2.0/INSTALL_RECEIPT.json").read)).not_to have_key("build_times")
      expect(builds.fetch("cmake").last).to include("status" => "built", "verb" => "install")
    end

    it "takes a formula brew didn't install as failed, skips what needs it in later batches and runs the rest",
       :aggregate_failures do
      stub_formula("cmake")
      stub_formula("llvm", deps: %w[cmake])
      stub_formula("gcc")
      failing << "cmake"
      expect { run_command("--yes", "llvm", "cmake", "gcc") }.to output(<<~EOS).to_stderr
        Warning: Skipping llvm: dependency cmake did not install
        Error: 1 formula did not install: cmake
      EOS
      expect(brew_calls).to eq([%w[install --formula --yes --display-times cmake gcc]])
      expect(builds.transform_values { |entries| entries.last["status"] })
        .to include("cmake" => "failed", "gcc" => "built", "llvm" => "skipped")
    end

    it "takes a formula whose latest version was installed when planned as installed only with a new receipt" do
      stub_formula("app", "2.0", linked: false)
      stub_formula("lib", "2.0", linked: false)
      failing << "app"
      expect { run_command("--yes", "--overwrite", "--guess=app=1m,lib=1m", "app", "lib") }
        .to output("Error: 1 formula did not install: app\n").to_stderr
    end

    it "takes a formula an earlier batch upgraded alongside as installed, though its own call did nothing" do
      stub_formula("lib")
      stub_formula("app", "1.0", deps: %w[lib])
      installs.merge!("lib" => %w[lib app], "app" => [])
      expect { run_command("--yes", "lib", "app") }.not_to output.to_stderr
      expect(brew_calls.map(&:last)).to eq(%w[lib app])
    end

    it "takes what a poured formula needs from its bottle's manifest, as brew does, with `--only-dependencies`" do
      stub_formula("lib", "1.0")
      stub_formula("app", deps: %w[lib], bottled: true, bottle_deps: { "lib" => "1.0" })
      installs["app"] = []
      expect { run_command("--yes", "--only-dependencies", "app") }.not_to output.to_stderr
    end

    describe "with `--only-dependencies`" do
      before do
        stub_formula("dep")
        stub_formula("app", deps: %w[dep])
        installs["app"] = %w[dep]
      end

      it "checks that brew installed what each formula needs, and logs that, not the formula", :aggregate_failures do
        expect { run_command("--yes", "--only-dependencies", "app") }.not_to output.to_stderr
        expect(brew_calls.last).to eq(%w[install --formula --yes --display-times --only-dependencies app])
        expect(builds.transform_values { |entries| entries.map { |entry| entry["status"] } })
          .to include("dep" => ["built"]).and(satisfy { |logged| !logged.key?("app") })
      end

      it "fails when brew didn't install what a formula needs, without logging the formula as failed",
         :aggregate_failures do
        failing << "dep"
        expect { run_command("--yes", "--only-dependencies", "app") }
          .to output("Error: The dependencies of 1 formula did not install: app\n").to_stderr
        expect(builds.transform_values { |entries| entries.map { |entry| entry["status"] } })
          .to include("dep" => ["failed"]).and(satisfy { |logged| !logged.key?("app") })
      end
    end
  end

  describe "casks" do
    it "prints what `brew install --dry-run` prints about the casks, then which to run first and last" do
      stub_cask("firefox", nil)
      stub_cask("iterm2", installed_stanzas: 'uninstall quit: "com.iterm2"')
      stub_cask("current-app", "2.0")
      expect { run_command("--dry-run", "firefox", "iterm2", "current-app") }.to output(<<~EOS).to_stdout
        ==> Would install 1 cask:
        firefox
        ==> Would install 1 cask first
        firefox
        ==> Would install 1 cask last
        iterm2: `uninstall quit` may raise a dialog
      EOS
    end

    it "installs and upgrades casks first and last around the batches with the cask flags, as brew would " \
       "upgrade the installed, outdated ones, and passes the others on for brew to report", :aggregate_failures do
      stub_formula("cmake")
      stub_cask("firefox", nil)
      stub_cask("iterm2", installed_stanzas: 'uninstall quit: "com.iterm2"')
      stub_cask("current-app", "2.0")
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_command("--verbose", "--no-binaries", "--adopt", "--keep-tmp", "firefox", "iterm2", "current-app", "cmake")
      expect(brew_calls).to eq([%w[install --cask --yes --verbose --adopt --no-binaries firefox current-app],
                                %w[install --formula --yes --display-times --verbose --keep-tmp cmake],
                                %w[install --cask --yes --verbose --adopt --no-binaries iterm2]])
    end

    it "prints nothing with `--dry-run` for a named cask that is installed and current, as brew doesn't" do
      stub_cask("current-app", "2.0")
      expect { run_command("--dry-run", "current-app") }.not_to output.to_stdout
    end

    it "leaves an installed, outdated cask to install as brew does with `HOMEBREW_NO_INSTALL_UPGRADE`" do
      ENV["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"
      stub_cask("iterm2", installed_stanzas: 'uninstall quit: "com.iterm2"')
      run_command("--yes", "iterm2")
      expect(brew_calls).to eq([%w[install --cask --yes iterm2]])
    end

    it "names a cask skipped without a terminal that was given as a file by that file in the command to " \
       "install it later" do
      allow(Timed::Casks).to receive(:terminal?).and_return(false)
      dir = mktmpdir
      (dir/"firefox.rb").write(cask_source("firefox", "2.0", 'pkg "Firefox.pkg"'))
      path = Regexp.escape((dir/"firefox.rb").realpath.to_s)
      Dir.chdir(dir) do
        expect { run_command("--dry-run", "--cask", "--force", "firefox.rb") }
          .to output(/^Install it later with `brew install --cask --force #{path}`\.$/).to_stderr
      end
    end

    it "doesn't install a last cask that needs a formula that failed, which brew would pour for it, saying so",
       :aggregate_failures do
      stub_formula("cmake")
      stub_cask("app-for-cmake", nil, stanzas: 'depends_on formula: "cmake"')
      failing << "cmake"
      expect { run_command("--yes", "--keep-tmp", "cmake", "app-for-cmake") }.to output(<<~EOS).to_stderr
        Error: 1 formula did not install: cmake
        Warning: Not installing 1 cask, which needs formulae that didn't install and aren't installed:
        app-for-cmake: needs cmake
        Finish those first with `brew install-timed --keep-tmp cmake`, then install it with `brew install --cask app-for-cmake`.
      EOS
      expect(brew_calls).to eq([%w[install --formula --yes --display-times --keep-tmp cmake]])
    end

    it "keeps `--exclude` and `--no-stamp-receipts`, but not `--yes`, in the command to finish what a last cask " \
       "needs first, so its own dependents check leaves an excluded outdated dependent alone" do
      stub_formula("cmake")
      user = stub_formula("user", "1.0", deps: %w[cmake])
      stub_cask("app-for-cmake", nil, stanzas: 'depends_on formula: "cmake"')
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user], pinned: [], skipped: []))
      failing << "cmake"
      argv = %w[--yes --keep-tmp --exclude=user --no-stamp-receipts --guess=cmake=1m cmake app-for-cmake]
      finish = /^Finish those first with `brew install-timed --keep-tmp --exclude=user --no-stamp-receipts cmake`, /
      expect { run_command(*argv) }.to output(finish).to_stderr
    end

    it "doesn't install the last casks when Ctrl-C stops the calls after the batches, naming them with how to " \
       "install them later", :aggregate_failures do
      stub_formula("cmake")
      stub_cask("app-for-cmake", nil, stanzas: 'depends_on formula: "cmake"')
      allow(Timed::Command).to receive(:broken_dependents).and_raise(Interrupt)
      expect { run_command("--yes", "cmake", "app-for-cmake") }.to raise_error(Interrupt).and output(<<~EOS).to_stderr
        Warning: The check for broken linkage didn't finish; not all the dependents of cmake were checked.
        Warning: Broken dependents not worked out, as Ctrl-C stopped that.
        Warning: Interrupted, so the cask to install after the formulae didn't run: app-for-cmake
        Install it later with `brew install --cask app-for-cmake`.
      EOS
      expect(brew_calls).to eq([%w[install --formula --yes --display-times cmake]])
    end

    it "installs the last casks after the outdated dependents and the broken ones, which they may need" do
      stub_formula("cmake")
      user = stub_formula("user", "1.0", deps: %w[cmake], bottled: true)
      broken = stub_formula("broken", "2.0")
      stub_cask("firefox", nil)
      stub_cask("iterm2", nil, stanzas: 'depends_on formula: "cmake"')
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user], pinned: [], skipped: []))
      installers = [instance_double(FormulaInstaller, formula: user)]
      allow(Homebrew::Upgrade).to receive_messages(dependent_formula_installers:        installers,
                                                   filter_dependent_formula_installers: installers)
      allow(Timed::Command).to receive(:broken_dependents).and_return([broken])
      run_command("--yes", "cmake", "firefox", "iterm2")
      expect(brew_calls).to eq([%w[install --cask --yes firefox],
                                %w[install --formula --yes --display-times cmake],
                                %w[upgrade --formula --yes --display-times user],
                                %w[reinstall --formula --yes --display-times --build-from-source broken],
                                %w[install --cask --yes iterm2]])
    end

    it "says neither the batches nor the last casks ran when Ctrl-C stops the download of the outdated " \
       "dependents' bottle manifests, after the first casks", :aggregate_failures do
      stub_formula("cmake")
      user = stub_formula("user", "1.0", deps: %w[cmake], bottled: true)
      stub_cask("firefox", nil)
      stub_cask("iterm2", nil, stanzas: 'depends_on formula: "cmake"')
      allow(Homebrew::Upgrade).to receive(:dependants)
        .and_return(Homebrew::Upgrade::Dependents.new(upgradeable: [user], pinned: [], skipped: []))
      allow(Homebrew::Upgrade).to receive(:dependent_formula_installers).and_raise(Interrupt)
      expect { run_command("--yes", "cmake", "firefox", "iterm2") }
        .to raise_error(Interrupt).and output(<<~EOS).to_stderr
          Warning: Interrupted, so the batches didn't run.
          Warning: Interrupted, so the cask to install after the formulae didn't run: iterm2
          1 cask needs formulae of this run that aren't installed, which brew would
          install for it, but not as this run would:
          iterm2: needs cmake
          Finish those first with `brew install-timed cmake`, then install it with `brew install --cask iterm2`.
        EOS
      expect(brew_calls).to eq([%w[install --cask --yes firefox]])
    end

    it "names, when Ctrl-C stops the formulae, the formulae a last cask needs that aren't installed, with the " \
       "command to finish them as asked first, as brew's cask installer would pour them, and the other last casks " \
       "with the plain command" do
      stub_formula("cmake")
      stub_formula("app")
      stub_cask("app-for-cmake", nil, stanzas: 'depends_on formula: "cmake"')
      stub_cask("iterm2", installed_stanzas: 'uninstall quit: "com.iterm2"')
      allow(Timed::Runner).to receive(:run).and_raise(Interrupt)
      expect { run_command("--yes", "--keep-tmp", "--skip-post-install", "cmake", "app", "app-for-cmake", "iterm2") }
        .to raise_error(Interrupt).and output(<<~EOS).to_stderr
          Warning: Interrupted, so the casks to install after the formulae didn't run: app-for-cmake iterm2
          1 cask needs formulae of this run that aren't installed, which brew would
          install for it, but not as this run would:
          app-for-cmake: needs cmake
          Finish those first with `brew install-timed --keep-tmp --skip-post-install cmake`, then install it with `brew install --cask app-for-cmake`.
          Install the other later with `brew install --cask iterm2`.
        EOS
    end

    it "installs a cask that needs a formula brew installs for one in the batches last, and not when that " \
       "formula didn't install", :aggregate_failures do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      stub_cask("lib-app", nil, stanzas: 'depends_on formula: "lib"')
      installs["app"] = %w[lib]
      failing << "lib"
      expect { run_command("--yes", "app", "lib-app") }.to output(/^lib-app: needs lib$/).to_stderr
      expect(brew_calls).to eq([%w[install --formula --yes --display-times app]])
    end

    it "counts what a missing cask dependency's install needs, but not with `--skip-cask-deps`" do
      stub_cask("helper", nil, stanzas: 'pkg "Helper.pkg"')
      stub_cask("firefox", nil, stanzas: 'depends_on cask: "helper"')
      plans = []
      allow(Timed::Command).to receive(:show_casks) { |_verb, plan, **| plans << plan }
      [[], %w[--skip-cask-deps]].each { |flags| run_command("--dry-run", *flags, "firefox") }
      expect(plans.map { |plan| [plan.first.length, plan.last.flat_map { |entry| entry.reasons.map(&:message) }] })
        .to eq([[0, ["dependency `helper`: `pkg` requires sudo"]], [1, []]])
    end

    it "gives the cask classifier `--force`" do
      stub_cask("firefox", nil)
      expect(Timed::Command).to receive(:cask_plan).with(anything, hash_including(force: true)).and_call_original
      run_command("--yes", "--force", "firefox")
    end

    it "asks, as brew does, when brew would install a cask's dependencies" do
      stub_cask("dep-app", nil)
      stub_cask("firefox", nil, stanzas: 'depends_on cask: "dep-app"')
      expect(Homebrew::Ask).to receive(:confirm?).with(action: "installation").once.and_return(true)
      expect { run_to_end("firefox") }.to output(/^==> Would install 1 dependency for firefox:\ndep-app\n/).to_stdout
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
