# typed: strict
# frozen_string_literal: true

require "formula"
require "tab"
require "utils"
require "utils/output"
require_relative "after"
require_relative "build_log"
require_relative "command"
require_relative "planner"
require_relative "receipts"

module Timed
  # Runs the batches and reads what brew printed while running each.
  module Runner
    extend Utils::Output::Mixin

    # What `run` logs for a formula brew installed.
    DONE = %w[built poured].freeze

    # What came of `run`: the formulae (by full name) brew didn't install, as
    # they failed, were skipped or never ran, those of the calls after the
    # batches included, and whether, with `stops_at_failure`, a call stopped
    # early, which ends the whole brew command.
    class Outcome < T::Struct
      const :unfinished, T::Array[String]
      const :stopped_early, T::Boolean
    end

    # Whether brew installed a formula, from when its call started.
    Succeeded = T.type_alias { T.proc.params(formula: Formula).returns(T.proc.params(since: Time).returns(T::Boolean)) }

    # Whether brew installed a formula: its version is installed.
    INSTALLED = T.let(->(formula) { ->(_since) { formula.latest_version_installed? } }.freeze, Succeeded)

    # Whether brew reinstalled a formula: a failed reinstall leaves the old
    # keg, and its receipt, in place.
    REINSTALLED = T.let(lambda do |formula|
      before = Receipts.receipt_stat(formula)
      ->(since) { Receipts.installed_since?(formula, since, before:) }
    end.freeze, Succeeded)

    # Runs each of `batches` of `formulae` (by full name) with
    # `brew <verb> --formula --yes --display-times <flags> <names>`, each name
    # given as its argument in `arguments` if it has one, keeping
    # its output, without colours, in a log in `logs` named after the run's
    # start and process. With `pour_flags`, a batch is split into runs of
    # formulae in `pours` or not, in its order, and each run of `pours` gets
    # `pour_flags` instead of `flags`, one call per run. `succeeded` is called
    # for each formula a call is given before the call, and what it returns
    # after, with when the call started: a formula failed unless that says
    # brew installed it (by default, if its version is installed). Each
    # formula brew worked on is logged in `database` with the
    # verb, the batch's label and its log, and each keg brew installed gets
    # its times in its receipt unless not `stamp`. A formula that `deps` says
    # needs one that failed or was skipped is skipped and logged as such.
    # With `stops_at_failure` (brew stops a call at a failed build), brew
    # finished a failed call that printed the installation times, and
    # otherwise stopped it early if it never started more of its formulae
    # than downloads it couldn't tie to a formula failed (a formula left out
    # for a failed download is never started), or if it printed a failed build
    # before it turned to dependents and not a failed post-install; the
    # formulae it never started are then logged as skipped, not failed, with
    # a warning. With `dependencies_only` (`brew
    # install --only-dependencies`), the calls install only what the formulae
    # need, so `succeeded` checks that, and the formulae are never logged for
    # themselves, failed or skipped, only what brew's output shows it did,
    # which includes one brew installs as another one's dependency.
    # With `after`, every call runs without brew's installed-dependents check,
    # which only knows its own call's formulae and so would upgrade those of
    # later calls without their options, and the `after` calls follow the
    # batches, in order, each like a batch of its own.
    # Ctrl-C reaches brew too: once it has stopped, only the formulae brew
    # finished in the batch it was running are logged, and `Interrupt` is
    # raised, even if brew finished that batch.
    sig {
      params(
        batches:           T::Array[Planner::Batch],
        verb:              String,
        flags:             T::Array[String],
        formulae:          T::Hash[String, Formula],
        deps:              T::Hash[String, T::Array[String]],
        pours:             T::Array[String],
        pour_flags:        T.nilable(T::Array[String]),
        stamp:             T::Boolean,
        succeeded:         Succeeded,
        stops_at_failure:  T::Boolean,
        dependencies_only: T::Boolean,
        arguments:         T::Hash[String, String],
        after:             T.nilable(T::Array[After]),
        database:          Pathname,
        logs:              Pathname,
        clock:             T.proc.returns(Float),
        now:               T.proc.returns(Time),
      ).returns(Outcome)
    }
    def self.run(batches, verb:, flags:, formulae:, deps:, pours: [], pour_flags: nil, stamp: true,
                 succeeded: INSTALLED, stops_at_failure: false,
                 dependencies_only: false, arguments: {}, after: nil, database: BuildLog.default_path,
                 logs: HOMEBREW_LOGS/"timed",
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f }, now: -> { Time.now })
      # Runs started in the same second are separate processes.
      prefix = "#{now.call.strftime("%Y%m%d-%H%M%S")}-#{Process.pid}"
      logs.mkpath
      failed = T.let([], T::Array[String])
      skipped = T.let([], T::Array[String])
      # What each call after the batches failed to install, by label.
      failed_after = T.let({}, T::Hash[String, T::Array[String]])
      # The formulae the run installed, by short name, with how.
      installed = T.let({}, T::Hash[String, String])
      # The formulae left when Ctrl-C stopped the run, and what each call
      # after the batches had left: `:pending` if it hadn't worked that out
      # yet, `:stopped` if Ctrl-C stopped it doing so.
      not_finished = T.let(nil, T.nilable(T::Array[String]))
      after_left = T.let([], T::Array[[After, T.any(T::Array[String], Symbol)]])
      # What brew never started in a call it stopped early, e.g. at a failed
      # build, by verb.
      not_run = T.let({}, T::Hash[String, T::Array[String]])
      stopped_early = T.let(false, T::Boolean)
      # The run set the variable, not the user, so no hint about it.
      no_check = after ? { "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" => "1", "HOMEBREW_NO_ENV_HINTS" => "1" } : {}
      steps = T.let([*batches, *after], T::Array[T.any(Planner::Batch, After)])
      left = lambda do |rest|
        rest.each do |step|
          next not_finished&.concat(step.names) if step.is_a?(Planner::Batch)

          after_left << [step, :pending]
        end
      end
      # The child brew is in this process group, so it gets Ctrl-C too.
      interrupts = T.let([], T::Array[Integer])
      old_trap = Signal.trap(:INT) { |signal| interrupts << signal }
      begin
        steps.each.with_index(1) do |step, index|
          if interrupts.any?
            not_finished = []
            left.call(steps.drop(index - 1))
            break
          end

          call = step if step.is_a?(After)
          step_verb = call&.verb || verb
          only_dependencies = dependencies_only && call.nil?
          check = if call.nil?
            succeeded
          else
            call.reinstall? ? REINSTALLED : INSTALLED
          end
          # Each reinstall has a call of its own.
          stops = call.nil? && stops_at_failure
          candidates = case step
          when After
            chosen = choose(step, installed, failed + skipped + failed_after.values.flatten)
            if chosen.nil?
              # Ctrl-C stopped it; the rest is only worked out.
              interrupts << Signal.list.fetch("INT")
              not_finished ||= []
              after_left << [step, :stopped]
            end
            chosen ||= []
            formulae = formulae.merge(chosen.to_h { |formula| [formula.full_name, formula] })
            deps = deps.merge(chosen.to_h { |formula| [formula.full_name, step.deps.call(formula)] })
            chosen.map(&:full_name)
          else
            step.names
          end
          started = now.call
          entries = T.let({}, T::Hash[String, BuildLog::Build])
          # With `dependencies_only`, the formulae whose dependencies brew
          # finished, which aren't logged for themselves.
          finished = T.let([], T::Array[String])
          # Calls in a batch are separate processes, so brew doesn't know
          # what failed in an earlier one.
          failed_in_batch = T.let([], T::Array[String])
          # Whether brew installed each formula in its call.
          done = T.let({}, T::Hash[String, T::Boolean])
          skipped_before = skipped.length
          skip, names = skips(candidates, failed + skipped, deps, verb, dependencies_only, finish: call&.finish)
          skipped.concat(skip)

          stopped = T.let(false, T::Boolean)
          if names.any?
            heading = if call
              "#{call.verb.capitalize.delete_suffix("e")}ing #{call.what.downcase}"
            else
              "Running batch #{index} of #{batches.length}"
            end
            oh1 "#{heading}: #{names.join(" ")}"
            log = logs/"#{prefix}-batch#{index}.log"
            lines = T.let([], T::Array[Line])
            start = clock.call
            # In the batch's order, dependencies first, so brew never pours
            # a formula as a dependency before its call to build it.
            runs = if call&.reinstall?
              names.zip
            elsif pour_flags && call.nil?
              names.chunk_while { |a, b| pours.include?(a) == pours.include?(b) }
            else
              [names]
            end
            calls = runs.map do |run_names|
              next [call.flags, run_names] if call
              next [pour_flags, run_names] if pour_flags && pours.include?(run_names.fetch(0))

              [flags, run_names]
            end
            results = T.let([], T::Array[T.nilable(T::Boolean)])
            log.open("w") do |file|
              calls.each do |call_flags, call_names|
                if interrupts.any?
                  stopped = true
                  break
                end

                skip, kept = skips(call_names, failed + failed_in_batch + skipped, deps, verb, dependencies_only,
                                   finish: call&.finish)
                skipped.concat(skip)
                names -= skip
                next if kept.empty?

                argv = [step_verb, "--formula", "--yes", "--display-times", *call_flags].uniq
                checks = kept.to_h { |name| [name, check.call(formulae.fetch(name))] }
                call_started = now.call
                first_line = lines.length
                results << stream([*argv, *kept.map { |name| arguments.fetch(name, name) }], env: no_check) do |line|
                  file.write(line.gsub(ANSI, ""))
                  lines << [line, clock.call - start]
                end
                checks.each { |name, installed_since| done[name] = installed_since.call(call_started) }
                failed_in_batch.concat(kept.reject { |name| done.fetch(name) })
                next if !stops || results.last || interrupts.any?

                output = lines.drop(first_line).map { |line, _| line.chomp.gsub(ANSI, "") }
                # Brew prints the times (`--display-times`) as it finishes, if
                # it installed anything, which it never reaches once stopped.
                next if output.include?(INSTALL_TIMES)

                # Brew names each formula it starts on, or whose download fails,
                # but for some downloads only the file.
                begun = parse(lines.drop(first_line)).keys
                unstarted = kept.reject { |name| begun.include?(Utils.name_from_full_name(name)) }
                if unstarted.length <= output.grep(UNNAMED_FETCH_FAILED).length
                  stopped_early ||= stopped_at_build?(output)
                  next
                end

                stopped_early = true
                (not_run[step_verb] ||= []).concat(unstarted)
                skipped.concat(unstarted)
                names -= unstarted
              end
            end
            success = results.all?
            # Brew didn't finish the batch, so a formula it didn't get to
            # hasn't failed.
            stopped ||= interrupts.any? && !success
            Homebrew.failed = true unless success
            builds = parse(lines, started:)
            names.each do |name|
              formula = formulae.fetch(name)
              # A formula whose call Ctrl-C stopped before it ran wasn't
              # checked: checked now, from the batch's start, though a check
              # that compares with how it was before the call can't tell. Only
              # what brew finished in the stopped batch is logged anyway.
              formula_installed = done.fetch(name) { check.call(formula).call(started) }
              if only_dependencies
                (formula_installed ? finished : failed) << name
                next
              end

              short = Utils.name_from_full_name(name)
              build = builds.delete(short) || {}
              if formula_installed && DONE.include?(build["status"])
                builds[short] = build
              elsif !formula_installed
                (call ? (failed_after[call.label] ||= []) : failed) << name
                builds[short] = build.merge("status"  => "failed",
                                            "version" => build["version"] || formula.pkg_version.to_s)
              end
            end
            builds.select! { |_, build| DONE.include?(build["status"]) } if stopped
            entries.merge!(builds.transform_values { |build| build.merge("log" => log.to_s) })
          end
          # By short name, as the log keys formulae; what brew did with a
          # formula it tried anyway is kept instead.
          (only_dependencies ? [] : skipped.drop(skipped_before)).each do |name|
            entries[Utils.name_from_full_name(name)] ||= {
              "status" => "skipped", "version" => formulae.fetch(name).pkg_version.to_s, "started" => started.iso8601
            }
          end

          entries.transform_values! { |entry| entry.merge("verb" => step_verb, "batch" => step.label) }
          entries.each { |name, entry| installed[name] = entry.fetch("status") if DONE.include?(entry["status"]) }
          BuildLog.update(database) { |build_log| entries.each { |name, entry| build_log.record(name, entry) } }
          if stamp
            entries.each do |name, entry|
              next unless DONE.include?(entry["status"])

              receipt = HOMEBREW_CELLAR/Utils.name_from_full_name(name)/entry.fetch("version")/AbstractTab::FILENAME
              next unless receipt.exist?

              begin
                Receipts.stamp(receipt, entry)
              rescue => e
                opoo "Couldn't stamp #{receipt}: #{e}"
              end
            end
          end
          next unless stopped

          # Of a call after the batches, only what it was giving brew.
          unfinished = (call ? names : candidates).reject do |name|
            finished.include?(name) || entries.key?(Utils.name_from_full_name(name))
          end
          not_finished = call ? [] : unfinished
          after_left << [call, unfinished] if call
          left.call(steps.drop(index))
          break
        end
      ensure
        Signal.trap(:INT, old_trap)
      end
      if not_finished
        if not_finished.any?
          opoo "Interrupted; not finished or logged: #{"the dependencies of " if dependencies_only}" \
               "#{not_finished.join(" ")}"
        end
        # What the commands it gives must leave alone.
        blocked = failed + skipped + failed_after.values.flatten + not_finished
        stopped_again = T.let(false, T::Boolean)
        after_left.each do |call, state|
          # Only worked out, not done; a second Ctrl-C stops that too.
          if state == :pending && !stopped_again
            chosen = choose(call, installed, blocked)
            deps = deps.merge(chosen.to_h { |formula| [formula.full_name, call.deps.call(formula)] }) if chosen
            state = chosen&.map(&:full_name) || :stopped
            stopped_again = state == :stopped
          end
          if state.is_a?(Array)
            report_left(call, state, deps, blocked)
            next
          end

          # Those it might have chosen that are still to do.
          maybe = call.candidates&.reject(&:latest_version_installed?) || []
          deps = deps.merge(maybe.to_h { |formula| [formula.full_name, call.deps.call(formula)] })
          ready = maybe.map(&:full_name).reject { |name| deps.fetch(name, []).intersect?(blocked) }
          finish = "; to finish what may be left, run:\n  #{call.finish.call(ready)}" if ready.any?
          opoo "#{call.what} not worked out, as Ctrl-C stopped that#{finish || "."}"
          report_left(call, maybe.map(&:full_name) - ready, deps, blocked)
        end
      else
        not_run.each do |not_run_verb, names|
          opoo "`brew #{not_run_verb}` stopped early; not run: #{names.join(" ")}"
        end
        if failed.any?
          count = Utils.pluralize("formula", failed.length, include_count: true)
          ofail "#{dependencies_only ? "The dependencies of #{count}" : count} did not #{verb}: #{failed.join(" ")}"
        end
        (after || []).each do |call|
          names = failed_after.fetch(call.label, [])
          next if names.empty?

          ofail "#{Utils.pluralize(call.noun, names.length, include_count: true)} did not #{call.verb}: " \
                "#{names.join(" ")}\nTo finish, run:\n  #{call.finish.call(names)}"
        end
      end
      # Even if brew finished anyway, so that whatever runs this stops too.
      raise Interrupt if interrupts.any?

      Outcome.new(unfinished: failed | skipped | failed_after.values.flatten, stopped_early:)
    end

    # A failed download that brew names by its file, not its formula
    # (`Resource::Patch`, `Homebrew::API::SourceDownload`).
    UNNAMED_FETCH_FAILED = /\A✘ (?:Patch|API Source) /

    # What brew prints for a failed build (`BuildError`): the end of the
    # build's log (`Formula#system`), or, when verbose, its error
    # (`BuildError#dump`). A failed post-install prints the same log tail
    # first and carries on (`FormulaInstaller#post_install`), as does a failed
    # build of a dependent, which comes after brew's dependents heading
    # (`Upgrade.upgrade_dependents`).
    BUILD_FAILED = /\A(?:Last \d+ lines from .+:|Error: \S+ \S+ did not build)\z/
    POST_INSTALL_FAILED = "Warning: The post-install step did not complete successfully"
    DEPENDENTS = /
      \A==>\s(?:Upgrading\s\d+\sdependents?\sof\supgraded\sformulae?:
      |Checking\sfor\sdependents\sof\supgraded\sformulae\.\.\.)\z
    /x

    # Whether `output`, without colours, shows brew stopped at a failed build:
    # the last such build before the dependents isn't a post-install's.
    sig { params(output: T::Array[String]).returns(T::Boolean) }
    def self.stopped_at_build?(output)
      failed = T.let(false, T::Boolean)
      output.take_while { |line| !DEPENDENTS.match?(line) }.each do |line|
        failed = BUILD_FAILED.match?(line) || (failed && line != POST_INSTALL_FAILED)
      end
      failed
    end
    private_class_method :stopped_at_build?

    # Says what `call` left of `names`, with the command that finishes it,
    # apart from those that `deps` says need one of `blocked`, which aren't
    # finished, so that command waits until they are.
    sig {
      params(call: After, names: T::Array[String], deps: T::Hash[String, T::Array[String]],
             blocked: T::Array[String]).void
    }
    def self.report_left(call, names, deps, blocked)
      waiting, ready = names.partition { |name| deps.fetch(name, []).intersect?(blocked) }
      opoo call.left_message(ready) if ready.any?
      return if waiting.empty?

      needed = waiting.flat_map { |name| deps.fetch(name, []) & blocked }.uniq
      opoo "#{call.what} not #{call.done}: #{waiting.join(" ")}, as they need #{needed.join(" ")}, which this run " \
           "didn't finish; once those are installed, run:\n  #{call.finish.call(waiting)}"
    end
    private_class_method :report_left

    # What `call` chooses from `installed` and `blocked`, with Ctrl-C's usual
    # effect, as it may take minutes: nil if it stopped it. If it fails, says
    # so, and that the call does nothing.
    sig {
      params(call: After, installed: T::Hash[String, String], blocked: T::Array[String])
        .returns(T.nilable(T::Array[Formula]))
    }
    def self.choose(call, installed, blocked)
      handler = Signal.trap(:INT, "DEFAULT")
      begin
        call.choose.call(installed.dup, blocked)
      rescue Interrupt
        nil
      rescue => e
        ofail "Couldn't work out the #{call.what.downcase}, so none were #{call.done}: #{e}"
        []
      ensure
        Signal.trap(:INT, handler)
      end
    end
    private_class_method :choose

    # `candidates` split into those `deps` says need one of `blocked`, which
    # are skipped with a warning, with the command `finish` gives to run once
    # those install, and the rest. With `dependencies_only`, what failed for
    # those was installing what they need.
    sig {
      params(candidates: T::Array[String], blocked: T::Array[String], deps: T::Hash[String, T::Array[String]],
             verb: String, dependencies_only: T::Boolean,
             finish: T.nilable(T.proc.params(left: T::Array[String]).returns(String)))
        .returns([T::Array[String], T::Array[String]])
    }
    def self.skips(candidates, blocked, deps, verb, dependencies_only, finish: nil)
      candidates.partition do |name|
        missing = deps.fetch(name, []) & blocked
        next false if missing.empty?

        whose = dependencies_only ? "the dependencies of" : Utils.pluralize("dependency", missing.length)
        then_run = "\nOnce #{(missing.length == 1) ? "it does" : "they do"}, run:\n  #{finish.call([name])}" if finish
        opoo "Skipping #{name}: #{whose} #{missing.join(", ")} did not #{verb}#{then_run}"
        true
      end
    end
    private_class_method :skips

    # Runs `brew <verb> --cask --yes <flags> <casks>` once, from the home
    # directory, with its output straight to the terminal, as casks are
    # neither timed nor logged. A failure is reported and the run carries on.
    # Ctrl-C reaches brew too: once it has stopped, `Interrupt` is raised.
    sig {
      params(verb: String, casks: T::Array[String], flags: T::Array[String], label: String, brew: Command::Brew)
        .void
    }
    def self.run_casks(verb, casks, flags:, label:, brew: ->(env, argv) { Command.brew(env, argv) })
      return if casks.empty?

      oh1 "Running the #{label} #{Utils.pluralize("cask", casks.length)}: #{casks.join(" ")}"
      interrupts = T.let([], T::Array[Integer])
      old_trap = Signal.trap(:INT) { |signal| interrupts << signal }
      argv = [verb, "--cask", "--yes", *flags].uniq + casks
      begin
        success = brew.call({}, argv)
      ensure
        Signal.trap(:INT, old_trap)
      end
      raise Interrupt if interrupts.any?

      ofail "`#{Shellwords.join(["brew", *argv])}` failed." unless success
    end

    # Runs `brew` with `argv` from the home directory (source builds that
    # clone a repository fail from some directories), with its output and
    # errors through one pipe, not a terminal, and `env` added to its
    # environment. Turns off brew's interactive debugger, as nobody would see
    # its prompt, and asks brew for colours if the output is a terminal
    # (unless `HOMEBREW_NO_COLOR` is set). Echoes each line as it arrives,
    # with any bytes that aren't UTF-8 replaced, and yields it. Returns
    # whether brew succeeded, as `Kernel.system` does.
    # rubocop:disable Naming/PredicateMethod
    sig {
      params(argv: T::Array[String], env: T::Hash[String, String], _block: T.proc.params(line: String).void)
        .returns(T.nilable(T::Boolean))
    }
    def self.stream(argv, env: {}, &_block)
      env = { "HOMEBREW_DISABLE_DEBREW" => "1" }.merge(env)
      env = { "HOMEBREW_COLOR" => "1" }.merge(env) if $stdout.tty?
      IO.popen(env, [HOMEBREW_BREW_FILE.to_s, *argv], err: [:child, :out], chdir: Dir.home) do |io|
        io.each_line do |raw|
          line = raw.scrub
          $stdout.print line
          $stdout.flush
          yield line
        end
      end
      Process.last_status&.success?
    end
    # rubocop:enable Naming/PredicateMethod

    # The heading of `brew upgrade --dry-run`'s list of what it would upgrade
    # when given no names (`UpgradeCmd#show_final_upgrade_summary`).
    WOULD_UPGRADE = /\A==> Would upgrade \d+ outdated packages?\z/

    # The names listed under `WOULD_UPGRADE` in `brew upgrade --dry-run`'s
    # output, formulae and casks alike.
    sig { params(lines: T::Array[String]).returns(T::Array[String]) }
    def self.would_upgrade(lines)
      lines.map { |line| line.chomp.gsub(ANSI, "") }
           .drop_while { |line| !WOULD_UPGRADE.match?(line) }.drop(1)
           .take_while { |line| line.present? && !line.start_with?("==>") }
           .map { |line| line.split.fetch(0) }
    end

    # A line of a batch's output and when it arrived, in seconds since the
    # batch started on a monotonic clock; nil when unknown, e.g. in a saved log.
    Line = T.type_alias { [String, T.nilable(Float)] }

    # Colours, which brew adds with `HOMEBREW_COLOR` and builds add anyway.
    ANSI = /\e\[[\d;]*[A-Za-z]/

    # Where brew starts on a formula, with any options after the name: each
    # upgrade (`Upgrade.print_upgrade_message`), each reinstall
    # (`Reinstall.reinstall_formula`), each install of a tap formula
    # (`Formula#print_tap_action`), and an install once its dependencies are
    # installed (`FormulaInstaller#install`); and where it starts on a
    # dependency (`FormulaInstaller#install_dependency`). An install of a core
    # formula with no dependencies to install has no heading.
    HEADING = /\A==> (?:Upgrading|Installing|Reinstalling) (?<name>[^\s:]+)(?: from \S+| --\S.*| *)\z/
    DEPENDENCY_HEADING = /\A==> (?:Upgrading|Installing) \S+ dependency: (?<name>\S+)\z/

    # Where brew pours a bottle, named `<name>--<version>…`
    # (`FormulaInstaller#pour`, `Bottle::Filename`).
    POURING = /\A==> Pouring (?<name>.+?)--/

    # A download failed (`DownloadQueue`). A bottle's version is the keg's
    # (`pkg_version`), a source download's has no revision, so it isn't kept.
    FETCH_FAILED = /\A✘ (?<kind>Formula|Bottle) (?<name>\S+) \((?<version>[^)]+)\)\z/
    # A resource is named after its formula, then `--` and its own name, if it
    # has one (`Resource#download_name`).
    RESOURCE_FAILED = /\A✘ (?<kind>Resource) (?<name>\S+?)(?:--\S+)?\z/

    # `FormulaInstaller#summary`: the install badge, unless turned off, then
    # the keg, its size and, for a source build, `built in <duration>`.
    SUMMARY = %r{
      \A(?:.*\s)?/\S*/(?<name>[^/\s]+)/(?<version>[^/\s:]+):
      \s(?:[\d,]+\sfiles,\s)?[\d.]+[KMGTP]?B(?:,\sbuilt\sin\s(?<built>.+))?\z
    }x

    INSTALL_TIMES = "==> Installation times"

    # `Messages#display_install_times` rows.
    INSTALL_TIME = /\A(?<name>\S+)\s+(?<seconds>\d+\.\d+) s\z/

    # An error, kept with up to `PROBLEM_LINES - 1` lines after it, until a
    # blank line, brew's next status line or the next error. Brew's own
    # errors all start with `Error:`. A failed build prints the end of its
    # log under a line naming the log and how many lines follow (unless
    # verbose); that line is kept with the last `PROBLEM_LINES - 1` of those
    # lines, blank ones and errors included but trailing blank ones dropped,
    # stopping early at brew's next status line. The log is in a directory
    # named after the formula (`Formula#logs`), which names the formula when
    # nothing else has, and brew is done with the formula after it. A verbose
    # build prints its output as it goes instead, and its failure ends with
    # an error naming the formula (`BuildError#dump`), which does the same.
    PROBLEM = %r{
      \A(?:Error:(?:\s(?<failed>\S+)\s\S+\sdid\snot\sbuild\z)?
      |Last\s(?<tail>\d+)\slines\sfrom\s(?:.*/(?<log_name>[^/]+)/[^/]+:\z)?)
    }x
    STATUS = /\A(?:==>|✔︎|✘|🍺)/
    PROBLEM_LINES = 6

    # A log no longer than the lines brew prints is printed whole, starting
    # with the time it was written (`Formula#system`), and brew's own text
    # may follow within the count (`BuildError#dump`): its first line, or two
    # blank lines in a row, end such a log.
    LOG_START = /\A\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}\z/
    AFTER_LOG = /
      \A(?:#{Regexp.union("READ THIS: ", "If reporting this issue please do so ", "These open issues may also help:")}
      |This\sis\sa\sTier\s\d\sconfiguration:)
    /x

    # Builds by formula name from a batch's output, as the build log records
    # them: every formula brew started on, including those it installed or
    # upgraded alongside the batch. `version` is the keg's, from brew's last
    # summary line for the formula or a failed bottle download; `status` is
    # `built` or `poured` from that summary line, else `failed`;
    # `install_seconds` from the `Installation times` table
    # (`--display-times`); `build_seconds` from that summary's `built in`;
    # `problems` from errors printed while brew was working on the formula,
    # from where it names it to its summary line. `started` is the batch's
    # `started` plus when the formula was first named (the batch's start
    # without a time for that), and `wall_seconds` the time from then to its
    # summary line (nil without both times).
    sig { params(lines: T::Array[Line], started: T.nilable(Time)).returns(T::Hash[String, BuildLog::Build]) }
    def self.parse(lines, started: nil)
      parser = Parser.new
      lines.each { |line, time| parser.feed(line, time) }
      parser.builds(started)
    end

    # The state `parse` needs between lines.
    class Parser
      sig { void }
      def initialize
        @builds = T.let({}, T::Hash[String, BuildLog::Build])
        @first_seen = T.let({}, T::Hash[String, Float])
        @finished = T.let({}, T::Hash[String, Float])
        @current = T.let(nil, T.nilable(String))
        @problem = T.let(nil, T.nilable(T::Array[String]))
        # Lines of a failed build's log still to come, while reading them.
        @tail = T.let(nil, T.nilable(Integer))
        # Whether that log is printed whole, known from its first line.
        @whole_log = T.let(false, T::Boolean)
        @in_times = T.let(false, T::Boolean)
        # When the first line of a formula brew names late arrived.
        @unclaimed = T.let(nil, T.nilable(Float))
        # Whether brew is done with the current formula once its problem ends.
        @release = T.let(false, T::Boolean)
      end

      sig { params(raw: String, time: T.nilable(Float)).void }
      def feed(raw, time)
        line = raw.chomp.gsub(ANSI, "")
        return if (problem = @problem) && took_problem_line?(problem, line)

        if @in_times && (row = INSTALL_TIME.match(line))
          build(row[:name].to_s)["install_seconds"] = row[:seconds].to_f
          return
        end

        @in_times = line == INSTALL_TIMES
        # A formula brew names only once it has started on it, or at its
        # summary line, started with the first line after brew was last busy
        # with a formula or a download.
        @unclaimed ||= time if @current.nil? && line.present?
        if (match = HEADING.match(line) || DEPENDENCY_HEADING.match(line))
          @current = seen(match[:name].to_s, time)
          @release = false
        elsif (match = POURING.match(line))
          @current = seen(match[:name].to_s, @unclaimed || time)
          @release = false
        elsif (match = FETCH_FAILED.match(line) || RESOURCE_FAILED.match(line))
          @current = seen(match[:name].to_s, time)
          build(@current)["version"] = match[:version] if match[:kind] == "Bottle"
          # Brew won't install it, so it is done with it after its error.
          @release = true
        elsif (match = SUMMARY.match(line))
          name = seen(match[:name].to_s, @unclaimed || time)
          @finished[name] = time if time
          built = match[:built]
          build(name).merge!("version"       => match[:version], "status" => built ? "built" : "poured",
                             "build_seconds" => (duration(built) if built))
          # Brew is done with it: anything printed before it names another
          # formula is about the run.
          @current = nil if @current == name
          @unclaimed = nil
        elsif (match = PROBLEM.match(line)) && (named = match[:log_name] || match[:failed] || @current)
          @current = seen(named, @unclaimed || time)
          @problem = [line]
          @tail = match[:tail]&.to_i
          @release = true if @tail || match[:failed]
        end
        @unclaimed = nil if @current || line.start_with?("✔︎")
      end

      sig { params(started: T.nilable(Time)).returns(T::Hash[String, BuildLog::Build]) }
      def builds(started)
        close_problem
        @builds.to_h do |name, build|
          first = @first_seen[name]
          finished = @finished[name]
          timing = {
            "started"      => (started + (first || 0) if started)&.iso8601,
            "wall_seconds" => ((finished - first).round(1) if first && finished),
          }
          result = build.merge(timing).compact
          result["status"] ||= "failed"
          [name, result]
        end
      end

      private

      sig { params(name: String).returns(BuildLog::Build) }
      def build(name) = @builds[name] ||= {}

      # `name` as brew's summary and times name it, noting when it was first
      # named.
      sig { params(name: String, time: T.nilable(Float)).returns(String) }
      def seen(name, time)
        short = Utils.name_from_full_name(name)
        build(short)
        @first_seen[short] ||= time if time
        short
      end

      # Adds `line` to `problem` and returns true, or closes `problem` and
      # returns false if `line` isn't part of it.
      sig { params(problem: T::Array[String], line: String).returns(T::Boolean) }
      def took_problem_line?(problem, line)
        tail = @tail
        if tail
          @whole_log = LOG_START.match?(line) if problem.length == 1
          log_ended = @whole_log &&
                      (AFTER_LOG.match?(line) || (line.blank? && problem.length > 1 && problem.fetch(-1).blank?))
          if tail.positive? && !STATUS.match?(line) && !log_ended
            @tail = tail - 1
            problem << line
            return true
          end
        elsif !STATUS.match?(line) && line.present? && !PROBLEM.match?(line) && problem.length < PROBLEM_LINES
          problem << line
          return true
        end

        close_problem
        false
      end

      sig { void }
      def close_problem
        problem = @problem
        current = @current
        tail = @tail
        @problem = nil
        @tail = nil
        @current = nil if @release
        @release = false
        return if problem.nil? || current.nil?

        if tail
          log = problem.drop(1)
          log.pop while (last = log.last) && last.blank?
          problem = [problem.fetch(0), *log.last(PROBLEM_LINES - 1)]
        end
        problems = build(current)["problems"] ||= []
        text = problem.join("\n")
        problems << text unless problems.include?(text)
      end

      # Seconds in a duration as `pretty_duration` prints it, e.g.
      # `1 hour 26 minutes`.
      sig { params(text: String).returns(Float) }
      def duration(text)
        { "hour" => 3600, "minute" => 60, "second" => 1 }.sum do |unit, seconds|
          text[/(\d+) #{unit}/, 1].to_f * seconds
        end
      end
    end
    private_constant :Parser
  end
end
