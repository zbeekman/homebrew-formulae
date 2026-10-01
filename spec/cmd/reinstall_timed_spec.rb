# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "cmd/reinstall"
require_relative "../../cmd/reinstall-timed"

RSpec.describe Homebrew::Cmd::ReinstallTimed do
  let(:database) { Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json" }
  let(:receipt) { Pathname(__FILE__).dirname.parent/"fixtures/receipts/built.json" }
  let(:brew_calls) { [] }
  # Names brew fails to reinstall, leaving their kegs as they were.
  let(:failing) { [] }

  # A formula at version 2.0, in `tap` if given, installed at 2.0 (unless not
  # `installed`) and linked into `opt`, with a receipt from long ago, loadable
  # by name and full name.
  def stub_formula(name, installed: true, deps: [], bottled: false, tap: nil)
    formula = formula(name, tap:) do
      T.bind(self, T.class_of(Formula))
      url "https://brew.sh/#{name}-2.0.tgz"
      deps.each { |dep| depends_on dep }
      if bottled
        bottle do
          T.bind(self, BottleSpecification)
          sha256 cellar: :any, Utils::Bottles.tag.to_sym => "a" * 64
        end
      end
    end
    # Brew loads an installed formula by its receipt's tap too.
    stub_formula_loader(formula)
    stub_formula_loader(formula, "homebrew/core/#{name}")
    stub_formula_loader(formula, name) if tap
    if installed
      keg = HOMEBREW_CELLAR/name/"2.0"
      keg.mkpath
      FileUtils.cp receipt, keg/"INSTALL_RECEIPT.json"
      (HOMEBREW_PREFIX/"opt").mkpath
      FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt"/name
    end
    formula
  end

  def build(seconds) = { "status" => "built", "install_seconds" => seconds, "version" => "2.0" }

  def builds = JSON.parse(database.read)["packages"].transform_values { |package| package["builds"] }

  def run_command(*argv) = described_class.new(argv).run

  def run_to_end(*argv)
    run_command(*argv)
  rescue SystemExit
    nil
  end

  # Brew: a call reinstalls each formula it is given, by name or file,
  # writing a new receipt and printing its summary line, except `failing`
  # ones, where it stops.
  before do
    allow(Formulary).to receive(:loader_for).and_call_original
    allow(Timed::Runner).to receive(:stream) do |argv, &block|
      brew_calls << argv
      success = argv.drop(1).reject { |arg| arg.start_with?("-") }.all? do |arg|
        name = File.basename(arg, ".rb")
        block.call("==> Reinstalling #{name} \n")
        next false if failing.include?(name)

        keg = HOMEBREW_CELLAR/name/"2.0"
        keg.mkpath
        (keg/"INSTALL_RECEIPT.json").write(JSON.pretty_generate(JSON.parse(receipt.read)
                                                                    .merge("time" => Time.now.to_i)))
        block.call("🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n")
        true
      end
      block.call("==> Installation times\n") if success
      success
    end
    database.dirname.mkpath
    database.write(JSON.generate("schema_version" => 1,
                                 "packages"       => { "cmake" => { "builds" => [build(200.0)] },
                                                       "llvm"  => { "builds" => [build(5000.0)] },
                                                       "gcc"   => { "builds" => [build(3000.0)] } }))
  end

  describe "flags" do
    it "accepts every `brew reinstall` option" do
      options = ->(command) { command.parser.processed_options.map { |short, long| long || short } }
      expect(options.call(Timed::Command.builtin("reinstall")) - options.call(described_class)).to eq([])
    end

    it "keeps `brew reinstall`'s conflicts" do
      expect(Timed::Command.builtin("reinstall").parser.conflicts - described_class.parser.conflicts).to eq([])
    end

    it "adds `--dry-run` and its own flags" do
      args = described_class.new(%w[-n --guess=llvm=1h --estimator=median --exclude=gcc --no-stamp-receipts
                                    llvm]).args
      expect([args.dry_run?, args.guess, args.estimator, args.exclude, args.no_stamp_receipts?])
        .to eq([true, %w[llvm=1h], "median", %w[gcc], true])
    end

    it "has no `--last`, as it reinstalls in one call" do
      expect { described_class.new(%w[--last=llvm llvm]) }.to raise_error(OptionParser::InvalidOption, /--last/)
    end

    it "shows the usage and its own description" do
      help = described_class.parser.generate_help_text(remaining_args: []).gsub(/\s+/, " ")
      expect(help).to start_with("Usage: brew reinstall-timed [options] formula|cask [...] Reinstall formulae " \
                                 "like brew reinstall, in one call ordered by their estimates:")
    end

    it "refuses `--interactive`, which needs a terminal" do
      expect { run_command("--interactive", "cmake") }
        .to raise_error(UsageError, "Invalid usage: `--interactive` needs a terminal; " \
                                    "use `brew reinstall --interactive` instead.")
    end

    it "refuses casks, naming them" do
      stub_cask_loader(Cask::Cask.new("firefox"))
      expect { run_command("--dry-run", "--cask", "firefox") }
        .to raise_error(UsageError, "Invalid usage: `brew reinstall-timed` doesn't reinstall casks yet; " \
                                    "use `brew reinstall --cask firefox` instead.")
    end

    it "fails on unknown `--exclude` and `--guess` names, naming the flag" do
      stub_formula("cmake")
      errors = %w[--exclude=nope --guess=nope=1m].to_h do |flag|
        run_command("--dry-run", flag, "cmake")
        [flag, nil]
      rescue UsageError => e
        [flag, e.message.sub(/(?<=\.) Did you mean .*/, "")]
      end
      expect(errors).to eq(%w[--exclude=nope --guess=nope=1m].to_h do |flag|
        [flag, "Invalid usage: `#{flag[/--\w+/]}`: No available formula with the name \"nope\"."]
      end)
    end
  end

  describe "--dry-run" do
    before { allow(Homebrew::Install).to receive(:ask_formulae) }

    it "doesn't auto-update, as `brew reinstall` doesn't" do
      stub_formula("cmake")
      expect(Timed::Command).not_to receive(:auto_update)
      run_command("--dry-run", "cmake")
    end

    it "prints what `brew reinstall` would reinstall, as it prints it before asking, then the batches" do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      installer = ->(name) { an_object_having_attributes(formula: an_object_having_attributes(full_name: name)) }
      expect(Homebrew::Install).to receive(:ask_formulae)
        .with(contain_exactly(installer.call("lib"), installer.call("app")),
              an_instance_of(Homebrew::Upgrade::Dependents),
              hash_including(action: "reinstallation", prompt: false, verbose: true))
        .ordered
      expect(Timed::Command).to receive(:show_plan).ordered.and_call_original
      expect { run_command("--dry-run", "--verbose", "app", "lib") }.to output(<<~EOS).to_stdout
        ==> Would reinstall 2 formulae in 1 batch, estimated 1h40m
        ==> Batch 1 of 1: 1h40m
        lib                          build   50m00s?
        app                          build   50m00s?
      EOS
    end

    it "orders dependencies first, then the quickest, in one batch" do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      %w[cmake llvm gcc].each { |name| stub_formula(name) }
      expect { run_command("--dry-run", "--guess=lib=1h", "llvm", "app", "lib", "cmake", "gcc") }
        .to output(<<~EOS).to_stdout
          ==> Would reinstall 5 formulae in 1 batch, estimated 4h06m
          ==> Batch 1 of 1: 4h06m
          cmake                        build     3m20s
          gcc                          build    50m00s
          lib                          build     1h00m
          app                          build   50m00s?
          llvm                         build     1h23m
        EOS
    end

    it "estimates a bottled formula as a pour, unless built from source" do
      stub_formula("lib", bottled: true)
      pours = {}
      [[], %w[--build-from-source]].each do |flags|
        allow(Timed::Command).to receive(:show_plan) { |_, _, estimates| pours[flags] = estimates.fetch("lib").pour }
        run_command("--dry-run", *flags, "lib")
      end
      expect(pours).to eq([] => true, %w[--build-from-source] => false)
    end

    it "orders a tap formula after a named dependency it declares by its bare name" do
      tap = Tap.fetch("user", "tap")
      stub_formula("lib", tap:)
      stub_formula("app", deps: %w[lib], tap:)
      expect { run_command("--dry-run", "user/tap/app", "user/tap/lib") }
        .to output(%r{^user/tap/lib +build .*^user/tap/app +build }m).to_stdout
    end

    it "orders a formula after the named dependencies that load, even if another doesn't" do
      stub_formula("lib")
      stub_formula("app", deps: %w[gone lib])
      expect { run_command("--dry-run", "app", "lib") }.to output(/^lib +build .*^app +build /m).to_stdout
    end

    it "doesn't order a formula after an optional dependency it wasn't built with, as brew leaves it out" do
      stub_formula("lib")
      stub_formula("app", deps: [{ "lib" => :optional }])
      expect { run_command("--dry-run", "app", "lib") }.to output(/^app +build .*^lib +build /m).to_stdout
    end

    it "still plans a formula with a dependency that can't be loaded, for brew to report" do
      stub_formula("app", deps: %w[gone])
      expect { run_command("--dry-run", "app") }.to output(/^app +build /).to_stdout
    end

    it "reinstalls a formula that isn't installed, as `brew reinstall` does" do
      stub_formula("new", installed: false)
      expect { run_command("--dry-run", "new") }.to output(/^==> Would reinstall 1 formula/).to_stdout
    end

    it "reports pinned formulae as `brew reinstall` does, leaving them out", :aggregate_failures do
      allow(stub_formula("pinned")).to receive(:pinned?).and_return(true)
      stub_formula("cmake")
      expect { run_command("--dry-run", "pinned", "cmake") }
        .to output("Error: pinned is pinned. You must unpin it to reinstall.\n").to_stderr
        .and output(/^==> Would reinstall 1 formula.*^cmake /m).to_stdout
      expect(Homebrew).not_to be_failed
    end

    it "reports unknown names last, as `brew reinstall` does, and fails" do
      stub_formula("cmake")
      expect { run_command("--dry-run", "cmake", "nope") }
        .to output(/\AError: No available formula with the name "nope"\./).to_stderr
      expect(Homebrew).to be_failed
    end

    it "reinstalls the new target of the alias a formula was installed with, as `brew reinstall` does" do
      target = stub_formula("cmake", installed: false)
      allow(stub_formula("old")).to receive(:latest_formula).and_return(target)
      expect { run_command("--dry-run", "old") }.to output(/^cmake +build +3m20s$/).to_stdout
    end

    it "doesn't ask for confirmation" do
      stub_formula("cmake")
      allow(Homebrew::Install).to receive(:formulae_ask_prompt_needed?).and_return(true)
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_command("--dry-run", "cmake")
    end
  end

  describe "confirmation" do
    before { allow(Homebrew::Install).to receive(:ask_formulae) }

    it "asks once, by `brew reinstall`'s rule for its formulae and their dependents" do
      stub_formula("cmake")
      expect(Homebrew::Install).to receive(:formulae_ask_prompt_needed?)
        .with([an_object_having_attributes(formula: an_object_having_attributes(full_name: "cmake"))],
              an_instance_of(Homebrew::Upgrade::Dependents))
        .and_return(true)
      expect(Homebrew::Ask).to receive(:confirm?).with(action: "reinstallation").once.and_return(true)
      run_to_end("cmake")
    end

    it "doesn't ask when `brew reinstall` wouldn't" do
      stub_formula("cmake")
      allow(Homebrew::Install).to receive(:formulae_ask_prompt_needed?).and_return(false)
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_to_end("cmake")
    end

    it "doesn't ask with `--yes` or `HOMEBREW_NO_ASK`" do
      stub_formula("cmake")
      allow(Homebrew::Install).to receive(:formulae_ask_prompt_needed?).and_return(true)
      expect(Homebrew::Ask).not_to receive(:confirm?)
      run_to_end("--yes", "cmake")
      ENV["HOMEBREW_NO_ASK"] = "1"
      run_to_end("cmake")
    end
  end

  describe "running the batches" do
    before { allow(Homebrew::Install).to receive(:ask_formulae) }

    it "reinstalls every formula in one call, in its order, with the forwarded formula flags but not its own" do
      %w[cmake gcc llvm].each { |name| stub_formula(name) }
      run_command("--yes", "--verbose", "--force", "--keep-tmp", "--build-from-source", "--debug-symbols",
                  "--git", "--debug", "--zap", "--guess=gcc=1m", "--exclude=llvm", "--no-stamp-receipts",
                  "gcc", "llvm", "cmake")
      flags = %w[--debug --force --verbose --build-from-source --keep-tmp --debug-symbols --git]
      expect(brew_calls).to eq([["reinstall", "--formula", "--yes", "--display-times", *flags, "cmake", "gcc"]])
    end

    it "names a formula given as a file to `brew reinstall` by that file, made absolute, and logs it by name",
       :aggregate_failures do
      dir = mktmpdir
      (dir/"foo.rb").write("class Foo < Formula\n  url \"https://brew.sh/foo-2.0.tgz\"\nend\n")
      keg = HOMEBREW_CELLAR/"foo/2.0"
      keg.mkpath
      FileUtils.cp receipt, keg/"INSTALL_RECEIPT.json"
      (HOMEBREW_PREFIX/"opt").mkpath
      FileUtils.ln_s keg, HOMEBREW_PREFIX/"opt/foo"
      Dir.chdir(dir) { run_command("--yes", "foo.rb") }
      expect(brew_calls.last.last).to eq((dir/"foo.rb").realpath.to_s)
      expect(builds.fetch("foo").last).to include("status" => "built", "verb" => "reinstall")
    end

    it "logs each reinstall and stamps its receipt", :aggregate_failures do
      stub_formula("cmake")
      run_command("--yes", "cmake")
      expect(builds.fetch("cmake").last).to include("version" => "2.0", "status" => "built", "verb" => "reinstall")
      expect(JSON.parse((HOMEBREW_CELLAR/"cmake/2.0/INSTALL_RECEIPT.json").read)["build_times"])
        .to include("verb" => "reinstall", "build_seconds" => 9.0)
    end

    it "takes a formula whose old keg brew put back as failed, and those after it as not run, as brew stops there",
       :aggregate_failures do
      %w[cmake gcc llvm].each { |name| stub_formula(name) }
      failing << "gcc"
      expect { run_command("--yes", "llvm", "gcc", "cmake") }.to output(<<~EOS).to_stderr
        Warning: `brew reinstall` stopped early; not run: llvm
        Error: 1 formula did not reinstall: gcc
      EOS
      expect(builds.transform_values { |entries| entries.last["status"] })
        .to eq("cmake" => "built", "gcc" => "failed", "llvm" => "skipped")
    end

    it "doesn't skip the dependents of a formula that failed, whose old keg is still there" do
      stub_formula("lib")
      stub_formula("app", deps: %w[lib])
      expect(Timed::Runner).to receive(:run).with(anything, hash_including(deps: {}))
      run_command("--yes", "app", "lib")
    end

    it "leaves receipts as brew wrote them with `--no-stamp-receipts`, but still logs the reinstalls",
       :aggregate_failures do
      stub_formula("cmake")
      run_command("--yes", "--no-stamp-receipts", "cmake")
      expect(JSON.parse((HOMEBREW_CELLAR/"cmake/2.0/INSTALL_RECEIPT.json").read)).not_to have_key("build_times")
      expect(builds.fetch("cmake").last).to include("status" => "built", "verb" => "reinstall")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
