# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/runner"

RSpec.describe Timed::Runner do
  # A batch's output as the runner reads it: each line with when it arrived,
  # unknown for a saved log.
  def fixture_lines(name)
    (Pathname(__FILE__).dirname.parent/"fixtures/batch-logs/#{name}").readlines.map { |line| [line, nil] }
  end

  def built(version, install_seconds, build_seconds)
    { "version" => version, "status" => "built", "install_seconds" => install_seconds,
      "build_seconds" => build_seconds }
  end

  def poured(version, install_seconds)
    { "version" => version, "status" => "poured", "install_seconds" => install_seconds }
  end

  # `HOMEBREW_BREW_FILE` as a shell script running `body`.
  def brew_script(body)
    brew = mktmpdir/"brew"
    brew.write("#!/bin/sh\n#{body}")
    brew.chmod(0755)
    stub_const("HOMEBREW_BREW_FILE", brew)
  end

  describe ".stream" do
    def stream(argv = [], env: {})
      lines = []
      described_class.stream(argv, env:) { |line| lines << line }
      lines
    end

    it "runs brew from the home directory, echoing and yielding each line of its output and errors",
       :aggregate_failures do
      brew_script(<<~SH)
        echo "in $(pwd -P)"
        echo "error: $*" >&2
        exit 3
      SH
      lines = []
      success = T.let(nil, T.nilable(T::Boolean))
      output = "in #{File.realpath(Dir.home)}\nerror: upgrade --yes\n"
      expect { success = described_class.stream(%w[upgrade --yes]) { |line| lines << line } }
        .to output(output).to_stdout
      expect([success, lines.join]).to eq([false, output])
    end

    it "replaces bytes that aren't UTF-8" do
      brew_script("printf 'caf\\351\\n'\n")
      expect(stream).to eq(["caf�\n"])
    end

    it "adds `env` to brew's environment, turns off its interactive debugger, which would wait on a prompt " \
       "nobody sees, and asks brew for colour when the output is a terminal" do
      brew_script("echo \"${HOMEBREW_COLOR-plain} ${HOMEBREW_X-} ${HOMEBREW_DISABLE_DEBREW-}\"\n")
      tty = [false, true].to_h do |terminal|
        allow($stdout).to receive(:tty?).and_return(terminal)
        [terminal, stream(env: { "HOMEBREW_X" => "x" })]
      end
      expect(tty).to eq(false => ["plain x 1\n"], true => ["1 x 1\n"])
    end

    it "lets `env` override what it sets" do
      brew_script("echo \"${HOMEBREW_DISABLE_DEBREW-}\"\n")
      expect(stream(env: { "HOMEBREW_DISABLE_DEBREW" => "" })).to eq(["\n"])
    end
  end

  describe ".run" do
    let(:database) { mktmpdir/"build-log.json" }
    let(:logs) { mktmpdir/"logs" }
    let(:receipt) { Pathname(__FILE__).dirname.parent/"fixtures/receipts/built.json" }
    let(:calls) { [] }
    let(:envs) { [] }
    # A monotonic clock that fake brew moves on.
    let(:clock) { [100.0] }
    let(:formulae) { {} }

    # A formula at version 2.0, not yet installed, by full name.
    def stub_formula(name, tap: nil)
      stub = formula(name, tap:) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/#{name}-2.0.tgz"
      end
      formulae[stub.full_name] = stub
    end

    def batch(*names, label: "main") = Timed::Planner::Batch.new(label:, reason: nil, names:)

    # Brew as it upgrades each name or file it is given that isn't installed yet,
    # taking 10 seconds for each: installs a keg with a receipt and prints its
    # summary line, except for `failing` names, and `silent` ones, which it
    # doesn't mention either, then the formulae `alongside` the names it was
    # given; then prints the installation times. With `stop_at_failure`, it
    # stops at the first failing name instead, as `brew reinstall` does at a
    # failed build, without the installation times. Yields the names before
    # it returns.
    def fake_brew(failing: [], silent: [], alongside: {}, stop_at_failure: false, &block)
      allow(described_class).to receive(:stream) do |argv, env: {}, &on_line|
        calls << argv
        envs << env
        names = argv.drop(1).reject { |arg| arg.start_with?("-") }.map { |arg| File.basename(arg, ".rb") }
        installed = []
        stopped = T.let(false, T::Boolean)
        (names + alongside.fetch(names, [])).each do |name|
          if (HOMEBREW_CELLAR/name/"2.0").exist?
            on_line.call("Warning: #{name} 2.0 already installed\n")
            next
          end
          next if silent.include?(name)

          on_line.call("\e[34m==>\e[0m \e[1mUpgrading #{name}\e[0m\n")
          clock[0] += 10
          if failing.include?(name)
            on_line.call("Error: #{name}: it failed\n")
            stopped = stop_at_failure
            break if stopped

            next
          end

          keg = HOMEBREW_CELLAR/name/"2.0"
          keg.mkpath
          FileUtils.cp receipt, keg/"INSTALL_RECEIPT.json"
          on_line.call("🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n")
          installed << name
        end
        unless stopped
          on_line.call("==> Installation times\n")
          installed.each { |name| on_line.call(format("%<name>-20s %<seconds>.3f s\n", name:, seconds: 9.5)) }
        end
        block&.call(names)
        !(names + alongside.fetch(names, [])).intersect?(failing + silent)
      end
    end

    def run(batches, verb: "upgrade", stamp: true, deps: {}, flags: %w[--verbose --display-times], pours: [],
            pour_flags: nil, now: -> { Time.new(2026, 9, 30, 10, 0, 0, "-04:00") }, **options)
      described_class.run(batches, verb:, flags:, pours:, pour_flags:, formulae:, deps:, stamp:,
                                   database:, logs:, clock: -> { clock.fetch(0) }, now:, **options)
    end

    def builds = JSON.parse(database.read)["packages"].transform_values { |package| package["builds"] }

    def log(index, pid: Process.pid) = (logs/"20260930-100000-#{pid}-batch#{index}.log").to_s

    it "runs `brew upgrade --formula --yes --display-times` with the flags for each batch, and nothing else" do
      %w[lib app tool].each { |name| stub_formula(name) }
      fake_brew
      run([batch("lib", "tool"), batch("app", label: "last")])
      expect(calls).to eq([%w[upgrade --formula --yes --display-times --verbose lib tool],
                           %w[upgrade --formula --yes --display-times --verbose app]])
    end

    it "returns the formulae brew didn't install: those that failed, and those skipped as they need one" do
      %w[lib app tool].each { |name| stub_formula(name) }
      fake_brew(failing: %w[lib])
      outcome = run([batch("lib", "tool"), batch("app")], deps: { "app" => %w[lib] })
      expect([outcome.unfinished, outcome.stopped_early]).to eq([%w[lib app], false])
    end

    it "names a formula to brew by its argument in `arguments`, and logs it by its name", :aggregate_failures do
      stub_formula("lib")
      fake_brew
      run([batch("lib")], arguments: { "lib" => "/work/lib.rb" })
      expect(calls).to eq([%w[upgrade --formula --yes --display-times --verbose /work/lib.rb]])
      expect(builds.keys).to eq(%w[lib])
    end

    it "gives each run its own logs, even when two start in the same second" do
      %w[lib app].each { |name| stub_formula(name) }
      fake_brew
      allow(Process).to receive(:pid).and_return(101, 202)
      run([batch("lib")])
      run([batch("app")])
      expect([log(1, pid: 101), log(1, pid: 202)].to_h { |path| [path, Pathname(path).read[/Upgrading \w+/]] })
        .to eq(log(1, pid: 101) => "Upgrading lib", log(1, pid: 202) => "Upgrading app")
    end

    describe "with `pour_flags`" do
      let(:source) { %w[--build-from-source --debug-symbols] }

      it "upgrades the batch's `pours` first, with `pour_flags`, then the rest, into one log", :aggregate_failures do
        %w[dep app tool].each { |name| stub_formula(name) }
        fake_brew
        run([batch("dep", "app", "tool")], flags: source, pours: %w[dep], pour_flags: [])
        expect(calls).to eq([%w[upgrade --formula --yes --display-times dep],
                             %w[upgrade --formula --yes --display-times --build-from-source --debug-symbols app
                                tool]])
        expect(builds.transform_values { |entries| entries.map { |entry| entry["log"] } })
          .to eq("dep" => [log(1)], "app" => [log(1)], "tool" => [log(1)])
      end

      it "keeps the batch's order, one call for each run of pours or source builds" do
        %w[lib dep app].each { |name| stub_formula(name) }
        fake_brew
        run([batch("lib", "dep", "app")], flags: source, pours: %w[dep], pour_flags: [])
        expect(calls).to eq([%w[upgrade --formula --yes --display-times --build-from-source --debug-symbols lib],
                             %w[upgrade --formula --yes --display-times dep],
                             %w[upgrade --formula --yes --display-times --build-from-source --debug-symbols app]])
      end

      it "turns off brew's installed-dependents check, and its hint, for runs of pours only" do
        %w[lib dep app].each { |name| stub_formula(name) }
        fake_brew
        run([batch("lib", "dep", "app")], flags: source, pours: %w[dep], pour_flags: [])
        no_check = { "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" => "1", "HOMEBREW_NO_ENV_HINTS" => "1" }
        expect(envs).to eq([{}, no_check, {}])
      end

      it "skips a run's formulae that need one that failed in an earlier run of the batch", :aggregate_failures do
        %w[b p].each { |name| stub_formula(name) }
        fake_brew(failing: %w[b])
        expect { run([batch("b", "p")], flags: source, pours: %w[p], pour_flags: [], deps: { "p" => %w[b] }) }
          .to output(<<~EOS).to_stderr
            Warning: Skipping p: dependency b did not upgrade
            Error: 1 formula did not upgrade: b
          EOS
        expect(calls).to eq([%w[upgrade --formula --yes --display-times --build-from-source --debug-symbols b]])
        expect(builds["p"]).to eq([{ "version" => "2.0", "status" => "skipped",
                                     "started" => "2026-09-30T10:00:00-04:00", "verb" => "upgrade",
                                     "batch" => "main" }])
      end

      it "keeps only the failed record of a skipped formula brew tried alongside an earlier run",
         :aggregate_failures do
        stub_formula("b")
        stub_formula("p", tap: Tap.fetch("user", "tap"))
        fake_brew(failing: %w[b user/tap/p], alongside: { %w[b] => %w[user/tap/p] })
        expect do
          run([batch("b", "user/tap/p")], flags: source, pours: %w[user/tap/p], pour_flags: [],
                                          deps: { "user/tap/p" => %w[b] })
        end.to output(%r{Skipping user/tap/p:}).to_stderr
        expect(builds["p"].map { |entry| entry["status"] }).to eq(%w[failed])
      end

      it "still runs the other formulae of a later run", :aggregate_failures do
        %w[b p q].each { |name| stub_formula(name) }
        fake_brew(failing: %w[b])
        expect { run([batch("b", "p", "q")], flags: source, pours: %w[p q], pour_flags: [], deps: { "p" => %w[b] }) }
          .to output(/Skipping p:/).to_stderr
        expect(calls.map(&:last)).to eq(%w[b q])
      end

      it "makes one call for a batch without `pours`" do
        %w[app tool].each { |name| stub_formula(name) }
        fake_brew
        run([batch("app", "tool")], flags: source, pours: %w[dep], pour_flags: [])
        expect(calls).to eq([%w[upgrade --formula --yes --display-times --build-from-source --debug-symbols app
                                tool]])
      end

      it "doesn't split without `pour_flags`" do
        %w[dep app].each { |name| stub_formula(name) }
        fake_brew
        run([batch("dep", "app")], pours: %w[dep])
        expect(calls).to eq([%w[upgrade --formula --yes --display-times --verbose dep app]])
      end
    end

    it "keeps going after output that isn't UTF-8" do
      %w[lib app].each { |name| stub_formula(name) }
      brew_script(<<~SH)
        shift
        for name in "$@"; do
          case "$name" in -*) continue;; esac
          mkdir -p "#{HOMEBREW_CELLAR}/$name/2.0"
          cp "#{receipt}" "#{HOMEBREW_CELLAR}/$name/2.0/INSTALL_RECEIPT.json"
          printf '==> Upgrading %s\\ncaf\\351\\n🍺  #{HOMEBREW_CELLAR}/%s/2.0: 3 files, 12KB\\n' "$name" "$name"
        done
      SH
      run([batch("lib"), batch("app")])
      expect(builds.transform_values { |entries| entries.map { |entry| entry["status"] } })
        .to eq("lib" => ["poured"], "app" => ["poured"])
    end

    it "keeps each batch's output in a log, without colours" do
      stub_formula("lib")
      fake_brew
      run([batch("lib")])
      expect(Pathname(log(1)).read).to eq(<<~EOS)
        ==> Upgrading lib
        🍺  #{HOMEBREW_CELLAR}/lib/2.0: 3 files, 12KB, built in 9 seconds
        ==> Installation times
        lib                  9.500 s
      EOS
    end

    it "logs each build with the verb, the batch and its log, timed from each line" do
      %w[lib app].each { |name| stub_formula(name) }
      fake_brew
      run([batch("lib"), batch("app", label: "last")])
      build = { "version" => "2.0", "status" => "built", "install_seconds" => 9.5, "build_seconds" => 9.0,
                "started" => "2026-09-30T10:00:00-04:00", "wall_seconds" => 10.0, "verb" => "upgrade" }
      expect(builds).to eq("lib" => [build.merge("batch" => "main", "log" => log(1))],
                           "app" => [build.merge("batch" => "last", "log" => log(2))])
    end

    it "logs formulae brew upgraded alongside a batch" do
      stub_formula("lib")
      fake_brew(alongside: { %w[lib] => %w[dependent] })
      run([batch("lib")])
      expect(builds.keys).to eq(%w[dependent lib])
    end

    it "adds the build times to the receipts of the kegs it installed" do
      stub_formula("lib")
      fake_brew(alongside: { %w[lib] => %w[dependent] })
      run([batch("lib")])
      stamped = %w[lib dependent].to_h do |name|
        [name, JSON.parse((HOMEBREW_CELLAR/name/"2.0/INSTALL_RECEIPT.json").read)["build_times"]]
      end
      times = { "verb" => "upgrade", "started" => "2026-09-30T10:00:00-04:00", "install_seconds" => 9.5,
                "build_seconds" => 9.0, "wall_seconds" => 10.0 }
      expect(stamped).to eq("lib" => times, "dependent" => times.merge("started" => "2026-09-30T10:00:10-04:00"))
    end

    it "leaves every receipt as it is without stamping, but still logs the builds", :aggregate_failures do
      stub_formula("lib")
      fake_brew
      run([batch("lib")], stamp: false)
      expect((HOMEBREW_CELLAR/"lib/2.0/INSTALL_RECEIPT.json").read).to eq(receipt.read)
      expect(builds.keys).to eq(%w[lib])
    end

    it "warns about a receipt it can't stamp and carries on", :aggregate_failures do
      %w[lib app].each { |name| stub_formula(name) }
      broken = HOMEBREW_CELLAR/"lib/2.0/INSTALL_RECEIPT.json"
      fake_brew { |names| broken.write("{") if names == %w[lib] }
      expect { run([batch("lib"), batch("app")]) }
        .to output(a_string_starting_with("Warning: Couldn't stamp #{broken}: ")).to_stderr
      expect(calls.length).to eq(2)
    end

    it "logs a formula whose version isn't installed after its batch as failed, with its planned version, " \
       "and fails the run", :aggregate_failures do
      %w[lib tool].each { |name| stub_formula(name) }
      fake_brew(failing: %w[lib])
      expect { run([batch("lib", "tool")]) }.to output("Error: 1 formula did not upgrade: lib\n").to_stderr
      expect([builds["lib"], Homebrew.failed?])
        .to eq([[{ "version" => "2.0", "status" => "failed", "problems" => ["Error: lib: it failed"],
                   "started" => "2026-09-30T10:00:00-04:00", "verb" => "upgrade", "batch" => "main",
                   "log" => log(1) }], true])
    end

    it "fails the run when brew fails, even if every formula upgraded" do
      stub_formula("lib")
      allow(described_class).to receive(:stream) do
        (HOMEBREW_CELLAR/"lib/2.0").mkpath
        FileUtils.cp receipt, HOMEBREW_CELLAR/"lib/2.0/INSTALL_RECEIPT.json"
        false
      end
      run([batch("lib")])
      expect(Homebrew).to be_failed
    end

    it "doesn't log a formula brew printed nothing for, e.g. one upgraded in an earlier batch" do
      %w[lib app].each { |name| stub_formula(name) }
      fake_brew(alongside: { %w[lib] => %w[app] })
      run([batch("lib"), batch("app")])
      expect(builds.transform_values(&:length)).to eq("lib" => 1, "app" => 1)
    end

    it "skips formulae in later batches that need a failed one, logging them, and runs the rest",
       :aggregate_failures do
      %w[lib app top other].each { |name| stub_formula(name) }
      fake_brew(failing: %w[lib])
      deps = { "app" => %w[lib], "top" => %w[app] }
      expect { run([batch("lib"), batch("app", "other"), batch("top")], deps:) }.to output(<<~EOS).to_stderr
        Warning: Skipping app: dependency lib did not upgrade
        Warning: Skipping top: dependency app did not upgrade
        Error: 1 formula did not upgrade: lib
      EOS
      expect(calls.map(&:last)).to eq(%w[lib other])
      skipped = { "version" => "2.0", "status" => "skipped", "started" => "2026-09-30T10:00:00-04:00",
                  "verb" => "upgrade", "batch" => "main" }
      expect(builds.slice("app", "top")).to eq("app" => [skipped], "top" => [skipped])
    end

    it "takes a formula brew didn't get to, e.g. after one it needs failed in the same call, as failed",
       :aggregate_failures do
      %w[lib app top].each { |name| stub_formula(name) }
      fake_brew(failing: %w[lib], silent: %w[app])
      expect { run([batch("lib", "app"), batch("top")], deps: { "app" => %w[lib], "top" => %w[app] }) }
        .to output(/Skipping top: dependency app did not upgrade\n.*did not upgrade: lib app\n/m).to_stderr
      expect(builds["app"].map { |entry| entry.slice("status", "version") })
        .to eq([{ "status" => "failed", "version" => "2.0" }])
    end

    describe "with `succeeded`" do
      it "starts it for each formula before its call, and finishes it after, with when the call started",
         :aggregate_failures do
        %w[lib app tool].each { |name| stub_formula(name) }
        events = []
        fake_brew { |names| events << "call #{names.join(" ")}" }
        times = [0, 0, 60, 120, 180].map { |seconds| Time.new(2026, 9, 30, 10, 0, 0, "-04:00") + seconds }
        succeeded = lambda do |formula|
          events << "before #{formula.name}"
          lambda do |since|
            events << "after #{formula.name} #{since.strftime("%T")}"
            true
          end
        end
        run([batch("lib", "app"), batch("tool")], succeeded:, now: -> { times.shift || raise("no time left") })
        expect(events).to eq(["before lib", "before app", "call lib app", "after lib 10:01:00",
                              "after app 10:01:00", "before tool", "call tool", "after tool 10:03:00"])
        expect(builds.keys).to contain_exactly("lib", "app", "tool")
      end

      it "takes a formula it says brew didn't install as failed, even if its version is installed",
         :aggregate_failures do
        %w[lib app].each { |name| stub_formula(name) }
        (HOMEBREW_CELLAR/"lib/2.0").mkpath
        fake_brew
        succeeded = ->(formula) { ->(_since) { formula.name != "lib" } }
        expect { run([batch("lib", "app")], verb: "reinstall", succeeded:) }
          .to output("Error: 1 formula did not reinstall: lib\n").to_stderr
        expect(builds.transform_values { |entries| entries.map { |entry| entry["status"] } })
          .to eq("lib" => ["failed"], "app" => ["built"])
      end
    end

    describe "with `dependencies_only`" do
      it "logs only what brew installed for the formulae, never them, failed or skipped, and says whose " \
         "dependencies failed", :aggregate_failures do
        %w[lib app other].each { |name| stub_formula(name) }
        fake_brew(failing: %w[zlib], silent: %w[lib app other],
                  alongside: { %w[lib] => %w[zlib], %w[other] => %w[pcre] })
        succeeded = ->(formula) { ->(_since) { formula.name != "lib" } }
        expect do
          run([batch("lib"), batch("app", "other")], verb: "install", deps: { "app" => %w[lib] }, succeeded:,
              dependencies_only: true)
        end.to output(<<~EOS).to_stderr
          Warning: Skipping app: the dependencies of lib did not install
          Error: The dependencies of 1 formula did not install: lib
        EOS
        expect(builds.transform_values { |entries| entries.map { |entry| entry["status"] } })
          .to eq("zlib" => ["failed"], "pcre" => ["built"])
        expect(calls.map(&:last)).to eq(%w[lib other])
      end

      it "logs and stamps a formula brew installs as another one's dependency, but not that one",
         :aggregate_failures do
        %w[lib app].each { |name| stub_formula(name) }
        allow(described_class).to receive(:stream) do |_argv, &on_line|
          on_line.call("==> Installing app dependency: lib\n")
          keg = HOMEBREW_CELLAR/"lib/2.0"
          keg.mkpath
          FileUtils.cp receipt, keg/"INSTALL_RECEIPT.json"
          on_line.call("🍺  #{keg}: 3 files, 12KB, built in 9 seconds\n")
          true
        end
        succeeded = ->(_formula) { ->(_since) { true } }
        expect { run([batch("lib", "app")], verb: "install", succeeded:, dependencies_only: true) }
          .not_to output.to_stderr
        expect(builds.transform_values { |entries| entries.map { |entry| entry.slice("status", "build_seconds") } })
          .to eq("lib" => [{ "status" => "built", "build_seconds" => 9.0 }])
        expect(JSON.parse((HOMEBREW_CELLAR/"lib/2.0/INSTALL_RECEIPT.json").read)["build_times"])
          .to include("verb" => "install", "build_seconds" => 9.0)
      end
    end

    describe "with `stops_at_failure`" do
      it "logs the formulae of a failed call that brew never started as skipped, not failed, warns and says " \
         "brew stopped early", :aggregate_failures do
        %w[lib app tool].each { |name| stub_formula(name) }
        fake_brew(failing: %w[app], stop_at_failure: true)
        outcome = T.let(nil, T.nilable(Timed::Runner::Outcome))
        expect { outcome = run([batch("lib", "app", "tool")], verb: "reinstall", stops_at_failure: true) }
          .to output(<<~EOS).to_stderr
            Warning: `brew reinstall` stopped early; not run: tool
            Error: 1 formula did not reinstall: app
          EOS
        expect(builds.transform_values { |entries| entries.map { |entry| entry["status"] } })
          .to eq("lib" => ["built"], "app" => ["failed"], "tool" => ["skipped"])
        expect([outcome&.stopped_early, outcome&.unfinished, Homebrew.failed?]).to eq([true, %w[app tool], true])
      end

      # Brew fetches everything first, then installs what downloaded:
      # `failures` are the download failures it prints, then it reinstalls
      # lib, and with `times` prints the installation times as it finishes.
      def failed_downloads(failures, times: false)
        allow(described_class).to receive(:stream) do |_argv, &on_line|
          [*failures, "==> Reinstalling lib\n"].each(&on_line)
          (HOMEBREW_CELLAR/"lib/2.0").mkpath
          FileUtils.cp receipt, HOMEBREW_CELLAR/"lib/2.0/INSTALL_RECEIPT.json"
          on_line.call("🍺  #{HOMEBREW_CELLAR}/lib/2.0: 3 files, 12KB, built in 9 seconds\n")
          ["==> Installation times\n", "lib                     9.500 s\n"].each(&on_line) if times
          false
        end
      end

      it "takes brew as finished when it printed the installation times, though it never started a formula it " \
         "left out with an error, which is failed, not not run", :aggregate_failures do
        %w[app lib].each { |name| stub_formula(name) }
        failed_downloads(["Error: app: no bottle available!\n"], times: true)
        outcome = T.let(nil, T.nilable(Timed::Runner::Outcome))
        expect { outcome = run([batch("app", "lib")], verb: "reinstall", stops_at_failure: true) }
          .to output("Error: 1 formula did not reinstall: app\n").to_stderr
        expect([outcome&.stopped_early,
                builds.transform_values { |entries| entries.map { |entry| entry["status"] } }])
          .to eq([false, { "app" => ["failed"], "lib" => ["built"] }])
      end

      it "takes a formula whose download failed as failed, not as not run" do
        %w[lib app].each { |name| stub_formula(name) }
        failed_downloads(["✘ Formula app (2.0)\n", "Error: app: download failed\n"])
        expect { run([batch("app", "lib")], verb: "reinstall", stops_at_failure: true) }
          .to output("Error: 1 formula did not reinstall: app\n").to_stderr
      end

      it "takes formulae whose resource or patch failed to download, which brew leaves out and carries on " \
         "without, as failed, not as not run", :aggregate_failures do
        %w[app tool lib].each { |name| stub_formula(name) }
        failed_downloads(["✘ Resource app--libfoo\n", "Error: libfoo: download failed\n", "✘ Patch fix.diff\n",
                          "Error: fix.diff: download failed\n"])
        outcome = T.let(nil, T.nilable(Timed::Runner::Outcome))
        expect { outcome = run([batch("app", "tool", "lib")], verb: "reinstall", stops_at_failure: true) }
          .to output("Error: 2 formulae did not reinstall: app tool\n").to_stderr
        expect([outcome&.stopped_early,
                builds.transform_values { |entries| entries.map { |entry| entry["status"] } }])
          .to eq([false, { "app" => ["failed"], "tool" => ["failed"], "lib" => ["built"] }])
      end

      it "says whether brew stopped at a failed build of the call's last formula, by the log tail or the " \
         "verbose error it prints for one, but not of a dependent it rebuilt or a failed post-install" do
        stub_formula("app")
        started = "==> Reinstalling app\n"
        tail = "Last 15 lines from #{HOMEBREW_LOGS}/app/01.make.log:\n"
        outputs = {
          "log tail"      => [started, tail, "make: *** [all] Error 1\n"],
          "verbose error" => [started, "\e[31mError:\e[0m app 2.0 did not build\n"],
          "other error"   => [started, "Error: app: it failed\n"],
          "post-install"  => [started, tail, "Warning: The post-install step did not complete successfully\n"],
          "dependent"     => [started, "==> Checking for dependents of upgraded formulae...\n",
                              "==> Reinstalling dep\n", "Last 15 lines from #{HOMEBREW_LOGS}/dep/01.make.log:\n"],
          "outdated"      => [started, "==> Upgrading 1 dependent of upgraded formula:\n",
                              "Error: dep 2.0 did not build\n"],
        }
        stopped = outputs.transform_values do |lines|
          allow(described_class).to receive(:stream) do |_argv, &on_line|
            lines.each(&on_line)
            false
          end
          run([batch("app")], verb: "reinstall", stops_at_failure: true).stopped_early
        end
        expect(stopped).to eq("log tail" => true, "verbose error" => true, "other error" => false,
                              "post-install" => false, "dependent" => false, "outdated" => false)
      end
    end

    describe "Ctrl-C" do
      def interrupt = Process.kill("INT", Process.pid)

      it "waits for brew, logs the finished batches, says what didn't run and raises `Interrupt`",
         :aggregate_failures do
        %w[lib app tool].each { |name| stub_formula(name) }
        fake_brew(failing: %w[app]) { |names| interrupt if names == %w[app] }
        expect { run([batch("lib"), batch("app"), batch("tool")]) }
          .to raise_error(Interrupt).and output("Warning: Interrupted; not finished or logged: app tool\n").to_stderr
        expect(builds.keys).to eq(%w[lib])
        File.open("#{database}.lock") { |lock| expect(lock.flock(File::LOCK_EX | File::LOCK_NB)).to eq(0) }
      end

      it "says whose dependencies didn't finish with `dependencies_only`, logging what brew finished",
         :aggregate_failures do
        %w[lib app].each { |name| stub_formula(name) }
        fake_brew(silent: %w[lib], alongside: { %w[lib] => %w[zlib] }) { |names| interrupt if names == %w[lib] }
        expect { run([batch("lib"), batch("app")], verb: "install", dependencies_only: true) }
          .to raise_error(Interrupt)
          .and output("Warning: Interrupted; not finished or logged: the dependencies of lib app\n").to_stderr
        expect(builds.keys).to eq(%w[zlib])
      end

      it "leaves out a formula whose dependencies brew finished in the stopped batch, with `dependencies_only`" do
        %w[lib app tool].each { |name| stub_formula(name) }
        fake_brew(silent: %w[lib app], alongside: { %w[lib app] => %w[zlib] }) { interrupt }
        succeeded = ->(formula) { ->(_since) { formula.name == "lib" } }
        expect { run([batch("lib", "app"), batch("tool")], verb: "install", succeeded:, dependencies_only: true) }
          .to raise_error(Interrupt)
          .and output("Warning: Interrupted; not finished or logged: the dependencies of app tool\n").to_stderr
      end

      it "logs and stamps the formulae of the stopped batch that brew finished", :aggregate_failures do
        %w[lib app tool].each { |name| stub_formula(name) }
        fake_brew(failing: %w[app]) { interrupt }
        expect { run([batch("lib", "app"), batch("tool")]) }
          .to raise_error(Interrupt).and output(/not finished or logged: app tool$/).to_stderr
        expect(builds.keys).to eq(%w[lib])
        expect(JSON.parse((HOMEBREW_CELLAR/"lib/2.0/INSTALL_RECEIPT.json").read)).to have_key("build_times")
      end

      it "doesn't log a formula brew was upgrading alongside the stopped batch" do
        stub_formula("lib")
        fake_brew(failing: %w[dependent], alongside: { %w[lib] => %w[dependent] }) { interrupt }
        expect { run([batch("lib")]) }.to raise_error(Interrupt).and not_to_output.to_stderr
        expect(builds.keys).to eq(%w[lib])
      end

      it "doesn't make a batch's next call once stopped" do
        %w[dep app].each { |name| stub_formula(name) }
        fake_brew { interrupt }
        expect { run([batch("dep", "app")], pours: %w[dep], pour_flags: []) }
          .to raise_error(Interrupt).and output(/not finished or logged: app$/).to_stderr
        expect([calls.length, builds.keys]).to eq([1, %w[dep]])
      end

      it "logs a batch that finished anyway and runs no more" do
        %w[lib app].each { |name| stub_formula(name) }
        fake_brew { interrupt }
        expect { run([batch("lib"), batch("app")]) }
          .to raise_error(Interrupt).and output(/not finished or logged: app$/).to_stderr
        expect([calls.length, builds.keys]).to eq([1, %w[lib]])
      end

      it "still raises `Interrupt` when brew finished the last batch anyway, with nothing to list",
         :aggregate_failures do
        stub_formula("lib")
        fake_brew { interrupt }
        expect { run([batch("lib")]) }.to raise_error(Interrupt).and not_to_output.to_stderr
        expect(builds.keys).to eq(%w[lib])
      end

      it "restores the interrupt handler" do
        stub_formula("lib")
        fake_brew
        handler = proc {}
        previous = Signal.trap(:INT, handler)
        run([batch("lib")])
        expect(Signal.trap(:INT, previous)).to be(handler)
      end
    end
  end

  describe ".run_casks" do
    let(:calls) { [] }
    # The calls brew returned from, by their last argument.
    let(:returned) { [] }

    # Brew as `Timed::Command.brew` runs it, succeeding unless `success` is
    # false, after `block`.
    def run_casks(casks, success: true, &block)
      brew = lambda do |env, argv|
        calls << [env, argv]
        block&.call
        returned << argv.last
        success
      end
      described_class.run_casks("upgrade", casks, flags: %w[--verbose --force], label: "first", brew:)
    end

    it "runs `brew <verb> --cask --yes` with the flags and the casks, once, under a heading", :aggregate_failures do
      expect { run_casks(%w[foo user/tap/bar]) }
        .to output("==> Running the first casks: foo user/tap/bar\n").to_stdout
      expect(calls).to eq([[{}, %w[upgrade --cask --yes --verbose --force foo user/tap/bar]]])
    end

    it "runs nothing without casks" do
      expect { run_casks([]) }.not_to output.to_stdout
      expect(calls).to eq([])
    end

    it "reports a failed call, shell-escaping its arguments, and carries on", :aggregate_failures do
      expect { run_casks(["foo", "/My Casks/bar.rb"], success: false) }
        .to output("Error: `brew upgrade --cask foo /My\\ Casks/bar.rb` failed.\n").to_stderr
      expect(Homebrew).to be_failed
    end

    it "waits for brew on Ctrl-C, then raises `Interrupt` and restores the interrupt handler", :aggregate_failures do
      handler = proc {}
      previous = Signal.trap(:INT, handler)
      expect { run_casks(%w[foo], success: false) { Process.kill("INT", Process.pid) } }
        .to raise_error(Interrupt).and not_to_output.to_stderr
      expect([returned, Signal.trap(:INT, previous)]).to eq([%w[foo], handler])
    end
  end

  describe ".would_upgrade" do
    it "reads the packages in `brew upgrade --dry-run`'s summary without named arguments" do
      previews = {
        "several" => ["Warning: Not upgrading 1 pinned package:", "pinned 1.0",
                      "==> Would upgrade 3 outdated packages", "cmake              3.0 -> 3.1",
                      "zbeekman/tap/cgns  4.4 -> 4.5_1", "firefox            1 -> 2",
                      "==> 1 Pinned formula", "pinned 1.0"],
        "one"     => ["\e[1;32m==>\e[0m \e[1mWould upgrade 1 outdated package\e[0m", "cmake 3.0 -> 3.1"],
        "none"    => ["==> No packages to upgrade"],
        "named"   => ["==> Would upgrade 1 requested outdated package", "cmake 3.0 -> 3.1"],
      }
      expect(previews.transform_values { |lines| described_class.would_upgrade(lines.map { |line| "#{line}\n" }) })
        .to eq("several" => %w[cmake zbeekman/tap/cgns firefox], "one" => %w[cmake], "none" => [], "named" => [])
    end
  end

  describe ".parse" do
    it "reads a source build's install time, `built in` time and version" do
      expect(described_class.parse(fixture_lines("upgrade-llvm.log"))).to eq(
        "llvm" => { "version" => "23.1.2", "status" => "built", "install_seconds" => 5169.797,
                    "build_seconds" => 5160.0 },
      )
    end

    it "reads every formula of a batch, including those brew installed alongside, from real logs" do
      expected = {
        "upgrade-pour-and-builds.log" => {
          "python-markdown" => poured("3.11", 1.549),
          "virtualenv"      => built("21.12.1", 97.091, 97.0),
          "openexr"         => built("3.5.1", 69.609, 71.0),
        },
        "upgrade-dependencies.log"    => {
          "gumbo-parser" => built("0.14.1", 39.0, 40.0),
          "virtualenv"   => built("21.13.0", 87.201, 88.0),
          "glances"      => built("4.5.7", 212.655, 214.0),
          "asciidoctor"  => poured("2.0.26", 1.411),
          "cpp-httplib"  => poured("0.58.0", 1.091),
          "doctest"      => poured("2.5.3", 1.233),
          "span-lite"    => poured("0.11.0", 1.046),
          "tl-expected"  => poured("1.3.1", 1.08),
          "ccache"       => built("4.14.1", 96.435, 89.0),
          "hunspell"     => built("1.7.4", 67.421, 68.0),
          "liquid-dsp"   => built("1.8.3", 37.721, 38.0),
          "qpdf"         => built("12.4.2", 106.434, 108.0),
          "tcl-tk"       => built("9.0.4_1", 355.928, 360.0),
          "imagemagick"  => built("7.1.2-32", 164.016, 166.0),
        },
        "upgrade-versioned.log"       => {
          "openssl@3" => built("3.6.4_1", 229.274, 237.0),
          "openssl@4" => built("4.0.2_1", 232.797, 242.0),
        },
      }
      expect(expected.to_h { |name, _| [name, described_class.parse(fixture_lines(name))] }).to eq(expected)
    end

    # The failure logs are made up in the format of brew's output, as no real
    # log has a failure.
    it "marks formulae that never finished as failed, with the errors printed while they were running" do
      curl = "`/usr/bin/curl --location https://example.com/tool-2.0.tar.gz`"
      fetch_error = <<~EOS.chomp
        Error: curl: (22) The requested URL returned error: 404
        Failure while executing; #{curl} exited with 22. Here's the output:
        curl: (22) The requested URL returned error: 404
      EOS
      checksum_error = <<~EOS.chomp
        Error: Bottle reports different checksum:   #{"a" * 64}
               SHA-256 checksum of downloaded file: #{"b" * 64}
      EOS
      # The end of the failed build's log, as the start of brew's 15 lines is
      # rarely the error.
      build_error = <<~EOS.chomp
        Last 15 lines from /Users/user/Library/Logs/Homebrew/lib/02.make:
        lib.c:1:10: fatal error: 'missing.h' file not found
            1 | #include <missing.h>
              |          ^~~~~~~~~~~
        1 error generated.
        make: *** [lib.o] Error 1
      EOS
      # A log shorter than brew's 15 lines is printed whole, from its header,
      # and followed by brew's own text, which isn't kept.
      short_build_error = <<~EOS.chomp
        Last 15 lines from /Users/user/Library/Logs/Homebrew/short/01.make:

        make
        install

        make: *** No rule to make target `install`.  Stop.
      EOS
      expect(described_class.parse(fixture_lines("upgrade-failures.log"))).to eq(
        "tool"  => { "status" => "failed", "problems" => [fetch_error] },
        "other" => { "version" => "3.0_1", "status" => "failed", "problems" => [checksum_error] },
        "lib"   => { "status" => "failed", "problems" => [build_error] },
        "short" => { "status" => "failed", "problems" => [short_build_error] },
        "app"   => built("2.0", 125.25, 125.0),
      )
    end

    it "ends a whole short log where brew's own text starts, whatever the tier" do
      log = ["Last 15 lines from /logs/foo/01.make:", "2026-09-30 10:00:00 +0000", "", "make", "",
             "make: *** No rule to make target `install`.  Stop."]
      after = {
        "official tap" => ["", "READ THIS: https://docs.brew.sh/Troubleshooting", "",
                           "These open issues may also help:"],
        "other tap"    => ["", "If reporting this issue please do so to (not Homebrew/* repositories):", "  a/tap"],
        "open issues"  => ["", "", "These open issues may also help:", "foo fails https://github.com/a/tap/issues/1"],
        # Tier 2 or 3 with `HOMEBREW_DEVELOPER`, where the tier notice is left out.
        "no notice"    => ["", "", "Warning: Your Xcode (26.3) is outdated.",
                           "Please update to Xcode 26.6 (or delete it).", "Xcode can be updated from the App Store."],
      }
      problems = after.transform_values do |lines|
        described_class.parse(["==> Upgrading foo", *log, *lines].map { |line| ["#{line}\n", nil] })
                       .dig("foo", "problems")
      end
      expect(problems).to eq(after.transform_values { [[log.fetch(0), *log.last(5)].join("\n")] })
    end

    it "doesn't take other programs' `fatal:` lines for brew's errors" do
      lines = [
        "==> Upgrading app",
        "fatal: not a git repository (or any of the parent directories): .git",
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB, built in 5 seconds",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq("app" => { "version" => "2.0", "status" => "built",
                                                             "build_seconds" => 5.0 })
    end

    it "keeps the error of a failed verbose build, which names its logs" do
      logs = %w[00.options.out 01.configure 01.configure.cc 02.make].map do |log|
        "     /Users/user/Library/Logs/Homebrew/lib/#{log}"
      end
      problem = ["Error: lib 2.0 did not build", "Logs:", *logs].join("\n")
      expect(described_class.parse(fixture_lines("upgrade-verbose-failure.log")))
        .to eq("lib" => { "status" => "failed", "problems" => [problem] })
    end

    it "doesn't blame a formula for errors after its summary line" do
      lines = [
        "==> Upgrading app",
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB, built in 5 seconds",
        "==> Checking for dependents of upgraded formulae...",
        "Error: Not reinstalling 1 broken and outdated, but pinned dependent:",
        "pinned 1.0",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq("app" => { "version" => "2.0", "status" => "built",
                                                             "build_seconds" => 5.0 })
    end

    it "takes a formula's status and build time from its last summary line in the batch" do
      lines = [
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB, built in 5 seconds",
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq("app" => { "version" => "2.0", "status" => "poured" })
    end

    it "times each formula from when brew first names it to its summary line, from the batch's start" do
      lines = [
        ["==> Upgrading lib\n", 0.5],
        ["  1.0 -> 2.0\n", 0.6],
        ["==> Installing lib dependency: dep\n", 2.0],
        ["🍺  /prefix/Cellar/dep/1.0: 4KB\n", 5.5],
        ["🍺  /prefix/Cellar/lib/2.0: 12 files, 1.1MB, built in 1 minute 1 second\n", 62.25],
        ["==> Installation times\n", 62.5],
        ["dep                       3.200 s\n", 62.5],
        ["lib                      58.100 s\n", 62.5],
      ]
      expect(described_class.parse(lines, started: Time.new(2026, 9, 25, 11, 23, 0, "-04:00"))).to eq(
        "lib" => { "version" => "2.0", "status" => "built", "install_seconds" => 58.1, "build_seconds" => 61.0,
                   "started" => "2026-09-25T11:23:00-04:00", "wall_seconds" => 61.8 },
        "dep" => { "version" => "1.0", "status" => "poured", "install_seconds" => 3.2,
                   "started" => "2026-09-25T11:23:02-04:00", "wall_seconds" => 3.5 },
      )
    end

    it "reads coloured output, tap formulae, options and summaries without the install badge" do
      lines = [
        "==> Upgrading zbeekman/tap/cgns@3.4",
        "/prefix/Cellar/cgns@3.4/3.4.1: 3 files, 12KB, built in 5 seconds",
        "\e[32m==>\e[0m \e[1mReinstalling \e[32mfoo\e[39m \e[0m",
        "==> Installing bar --HEAD",
        "Error: bar: something went wrong",
        "Error: bar: something went wrong",
        "==> Installing qux from user/tap",
        "Error: qux: it went wrong too",
        "\e[32m==>\e[0m \e[1mInstallation times\e[0m",
        "baz                       1.500 s",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq(
        "cgns@3.4" => { "version" => "3.4.1", "status" => "built", "build_seconds" => 5.0 },
        "foo"      => { "status" => "failed" },
        "bar"      => { "status" => "failed", "problems" => ["Error: bar: something went wrong"] },
        "qux"      => { "status" => "failed", "problems" => ["Error: qux: it went wrong too"] },
        "baz"      => { "status" => "failed", "install_seconds" => 1.5 },
      )
    end

    # Made up in the format of brew's output, from its source.
    it "reads formulae `brew install` gives no heading of their own, and a tap formula's heading" do
      problem = <<~EOS.chomp
        Last 15 lines from /Users/user/Library/Logs/Homebrew/broken/01.configure.log:
        checking for cc... no
        checking for cl.exe... no
        checking for clang... no
        configure: error: in '/private/tmp/broken-20261001-1234-abcdef/broken-2.0':
        configure: error: no acceptable C compiler found in $PATH
      EOS
      expect(described_class.parse(fixture_lines("install-headingless.log"))).to eq(
        "pour"   => poured("1.2.3", 1.402),
        "build"  => built("4.5", 127.311, 125.0),
        "tapped" => built("0.9", 46.802, 45.0),
        "broken" => { "status" => "failed", "problems" => [problem] },
      )
    end

    it "reads a verbose `brew install`'s failed build of a formula with no heading of its own" do
      logs = %w[00.options.out 01.configure.log 01.configure.cc].map do |log|
        "     /Users/user/Library/Logs/Homebrew/broken/#{log}"
      end
      expect(described_class.parse(fixture_lines("install-verbose-headingless.log"))).to eq(
        "pour"   => poured("1.2.3", 1.402),
        "broken" => { "status"   => "failed",
                      "problems" => [["Error: broken 2.0 did not build", "Logs:", *logs].join("\n")] },
      )
    end

    it "times a verbose failed build with no heading from the first line after the formula before" do
      lines = [["🍺  /prefix/Cellar/pour/1.0: 4KB\n", 1.0], ["==> make\n", 2.0],
               ["Error: user/tap/broken 2.0 did not build\n", 30.0]]
      expect(described_class.parse(lines, started: Time.new(2026, 10, 1, 10, 0, 0, "-04:00"))["broken"])
        .to include("started" => "2026-10-01T10:00:02-04:00")
    end

    it "blames a pour brew gives no heading for the error it hits" do
      lines = ["==> Pouring foo--1.0.sonoma.bottle.tar.gz", "Error: foo: Failed to extract the bottle"]
      expect(described_class.parse(lines.map { |line| ["#{line}\n", nil] }))
        .to eq("foo" => { "status" => "failed", "problems" => ["Error: foo: Failed to extract the bottle"] })
    end

    it "reads a `brew reinstall` that a failed build stopped, leaving out the formulae it never started" do
      problem = <<~EOS.chomp
        Last 15 lines from /Users/user/Library/Logs/Homebrew/app/02.make.log:
        app.c:1:10: fatal error: 'missing.h' file not found
            1 | #include <missing.h>
              |          ^~~~~~~~~~~
        1 error generated.
        make: *** [app.o] Error 1
      EOS
      expect(described_class.parse(fixture_lines("reinstall-failure.log"))).to eq(
        "lib" => { "version" => "1.0", "status" => "poured" },
        "app" => { "status" => "failed", "problems" => [problem] },
      )
    end

    it "times a formula without a heading from the first line after the one before it, or after the downloads" do
      lines = [
        ["==> Fetching downloads for: build, pour, broken, next and gone\n", 0.0],
        ["✔︎ Formula build (2.0)\n", 3.0],
        ["✘ Formula gone (2.0)\n", 4.0],
        ["Error: gone: download failed\n", 4.5],
        ["==> ./configure\n", 7.0],
        ["🍺  /prefix/Cellar/build/2.0: 12 files, 1.1MB, built in 50 seconds\n", 57.5],
        ["\n", 57.6],
        ["==> Pouring pour--1.0.sonoma.bottle.tar.gz\n", 58.0],
        ["🍺  /prefix/Cellar/pour/1.0: 4KB\n", 59.5],
        ["==> make\n", 60.0],
        ["Last 1 lines from /logs/broken/01.make.log:\n", 61.0],
        ["make: *** [all] Error 1\n", 61.0],
        ["\n", 61.1],
        ["==> ./configure\n", 62.0],
        ["🍺  /prefix/Cellar/next/3.0: 2 files, 8KB, built in 9 seconds\n", 71.5],
      ]
      times = described_class.parse(lines, started: Time.new(2026, 10, 1, 10, 0, 0, "-04:00"))
                             .transform_values { |build| build.slice("started", "wall_seconds") }
      expect(times).to eq(
        "gone"   => { "started" => "2026-10-01T10:00:04-04:00" },
        "build"  => { "started" => "2026-10-01T10:00:07-04:00", "wall_seconds" => 50.5 },
        "pour"   => { "started" => "2026-10-01T10:00:58-04:00", "wall_seconds" => 1.5 },
        "broken" => { "started" => "2026-10-01T10:01:00-04:00" },
        "next"   => { "started" => "2026-10-01T10:01:02-04:00", "wall_seconds" => 9.5 },
      )
    end

    it "starts a formula it has no time for at the batch's start, and has no wall time for it" do
      lines = fixture_lines("upgrade-llvm.log")
      build = described_class.parse(lines, started: Time.new(2026, 9, 25, 11, 23, 0, "-04:00")).fetch("llvm")
      expect(build.slice("started", "wall_seconds")).to eq("started" => "2026-09-25T11:23:00-04:00")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
