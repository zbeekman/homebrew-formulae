# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "cache_store"
require "cask/cask_loader"
require "cask/download"
require "formulary"
require "linkage_checker"
require "shellwords"
require "trust"
require "unpack_strategy"
require "upgrade"
require "utils/output"
require_relative "after"
require_relative "build_log"
require_relative "casks"
require_relative "llm"
require_relative "machine"
require_relative "planner"

module Timed
  # What the `-timed` commands share: flags, auto-update, estimates and the
  # plan they print.
  module Command
    extend Utils::Output::Mixin

    # The loaded built-in command `name`, e.g. `upgrade`. Looked up by name:
    # RuboCop's project index only sees this tap, so it takes a constant such
    # as `Homebrew::Cmd::UpgradeCmd` for a typo of a `-timed` command.
    sig { params(name: String).returns(T.class_of(Homebrew::AbstractCommand)) }
    def self.builtin(name)
      Homebrew::AbstractCommand.command(name) || raise("no `brew #{name}` command is loaded")
    end

    # The `cmd_args` block of the built-in `command`, so a `-timed` command
    # takes exactly its flags.
    sig { params(command: T.class_of(Homebrew::AbstractCommand)).returns(T.proc.void) }
    def self.parser_block(command)
      block = command.instance_variable_get(:@parser_block)
      raise "#{command.name} has no `cmd_args` block" if block.nil?

      block
    end

    # The flags every `-timed` command adds to the wrapped command's, and
    # `--last` unless not `last`. Those that plan formulae conflict with
    # `--cask`.
    sig { params(parser: Homebrew::CLI::Parser, last: T::Boolean).void }
    def self.define_flags(parser, last: true)
      parser.comma_array "--guess",
                         description: "Comma-separated `name=duration` estimates for source builds with no " \
                                      "history, e.g. `llvm=1h30m`: hours, minutes and seconds, as " \
                                      "`brew build-times` prints them."
      parser.flag "--estimator=",
                  description: "How to estimate a source build from its history: `mean` (the default: " \
                               "the mean plus 1.5 standard deviations) or `median`."
      if last
        parser.comma_array "--last",
                           description: "Comma-separated formulae to run in a final batch, with their dependents."
      end
      # The run does brew's installed-dependents check itself (see `after`),
      # which leaves them alone.
      parser.comma_array "--exclude",
                         description: "Comma-separated formulae to leave out of the run. Homebrew may still " \
                                      "install or upgrade them as dependencies of the others."
      parser.switch "--no-stamp-receipts",
                    description: "Don't add the build times to the install receipts of the formulae it installs; " \
                                 "they are still logged.",
                    env:         :timed_no_stamp_receipts
      parser.switch "--[no-]llm-estimates",
                    description: "Ask an LLM for estimates of source builds with no history, no `--guess` and " \
                                 "not `--exclude`d, sending it their names, descriptions, versions and build " \
                                 "dependencies, and this machine's hardware and build setup, e.g. CPU, cores, " \
                                 "model, memory, OS and make jobs. Off by default.",
                    env:         :timed_llm_estimates
      parser.flag "--llm-api-key-file=",
                  description: "File holding the LLM API key, needed unless `--llm-url` is set. " \
                               "Defaults to `$HOMEBREW_TIMED_LLM_API_KEY_FILE`.",
                  depends_on:  "--llm-estimates"
      parser.flag "--llm-provider=",
                  description: "The LLM API: `anthropic` or `openai`. Defaults to `$HOMEBREW_TIMED_LLM_PROVIDER`, " \
                               "else `anthropic` for keys starting `sk-ant-` and `openai` otherwise.",
                  depends_on:  "--llm-estimates"
      parser.flag "--llm-url=",
                  description: "Endpoint to send the request to, e.g. a local server that speaks OpenAI's API, " \
                               "instead of the provider's own. It receives the API key. " \
                               "Defaults to `$HOMEBREW_TIMED_LLM_URL`.",
                  depends_on:  "--llm-estimates"
      parser.flag "--llm-model=",
                  description: "The model to ask, needed with `--llm-url`. " \
                               "Defaults to `$HOMEBREW_TIMED_LLM_MODEL`, else a model of the provider.",
                  depends_on:  "--llm-estimates"
      parser.flag "--llm-timeout=",
                  description: "Seconds to wait for the LLM's answer, including one retry, e.g. longer for a slow " \
                               "local server. Defaults to `$HOMEBREW_TIMED_LLM_TIMEOUT`, else 45.",
                  depends_on:  "--llm-estimates"
      parser.flag "--llm-effort=",
                  description: "How hard the model works on its answer, e.g. `low` or `high`: lowercase letters, " \
                               "sent as given to any model. Defaults to `$HOMEBREW_TIMED_LLM_EFFORT`, else, on the " \
                               "provider's API, `low` for `claude-haiku-5-5`, `claude-sonnet-5-5` and " \
                               "`claude-opus-5-5`, `minimal` for `gpt-5-mini` and none for other models.",
                  depends_on:  "--llm-estimates"
      (last ? PLAN_FLAGS : PLAN_FLAGS - ["last"]).each { |name| parser.conflicts "--cask", "--#{name}" }
    end

    LLM_FLAGS = %w[llm_estimates llm_api_key_file llm_provider llm_url llm_model llm_timeout llm_effort].freeze
    PLAN_FLAGS = T.let(["guess", "estimator", "last", "exclude", *LLM_FLAGS].freeze, T::Array[String])
    # `--no-llm-estimates` too, as `options` adds it.
    OWN_FLAGS = T.let([*PLAN_FLAGS, "no_llm_estimates", "no_stamp_receipts"].freeze, T::Array[String])

    # The LLM settings from the `--llm-*` flags of `args` of a `-timed`
    # command, as `LLM.settings` resolves them; none without
    # `--llm-estimates`.
    sig { params(args: Homebrew::CLI::Args).returns(T.nilable(LLM::Settings)) }
    def self.llm_settings(args)
      # `Homebrew::CLI::Args` only gets these methods when a command parses
      # its flags, so Sorbet can't see them on it.
      # rubocop:disable Style/SendWithLiteralMethodName
      return unless args.public_send(:llm_estimates?)

      LLM.settings(key_file: args.public_send(:llm_api_key_file), provider: args.public_send(:llm_provider),
                   url: args.public_send(:llm_url), model: args.public_send(:llm_model),
                   timeout: args.public_send(:llm_timeout), effort: args.public_send(:llm_effort))
      # rubocop:enable Style/SendWithLiteralMethodName
    end

    # Handled by the `-timed` command itself, once for the whole run.
    ASK_FLAGS = %w[ask no_ask dry_run].freeze

    # Of the own flags, those that change what a run installs or how, which a
    # `-timed` command it suggests keeps; the others only shape the plan.
    # Brew has disabled `--ask`, and without `--yes` that command asks.
    KEPT_FLAGS = %w[exclude no_stamp_receipts].freeze

    # Each sub-call names its own kind.
    KIND_FLAGS = %w[formula formulae cask casks].freeze

    # The wrapped command's flags to pass on: all of them in `preview`, for the
    # one `--dry-run` sub-call; common and formula flags in `formula`, common
    # and cask flags in `cask`, for the sub-calls that each add their kind.
    # `own`: the `KEPT_FLAGS` given, for a `-timed` command the run suggests.
    class Forwarded < T::Struct
      const :preview, T::Array[String]
      const :formula, T::Array[String]
      const :cask, T::Array[String]
      const :own, T::Array[String]
    end

    # `options` as in `args.options_only`; `conflicts` as in the wrapped
    # parser's, where formula flags conflict with `--cask` and cask flags with
    # `--formula`.
    sig { params(options: T::Array[String], conflicts: T::Array[T::Array[String]]).returns(Forwarded) }
    def self.forward(options, conflicts:)
      preview = options.reject { |option| (OWN_FLAGS + ASK_FLAGS).include?(option_name(option)) }
      only_with = lambda do |kind|
        conflicts.select { |group| group.intersect?(kind) }.flatten - kind
      end
      formula_only = only_with.call(%w[cask casks])
      cask_only = only_with.call(%w[formula formulae])
      # A `--[no-]…` switch is named without `no_` in the conflicts.
      names = ->(option) { [option_name(option), option_name(option).delete_prefix("no_")] }
      split = preview.reject { |option| KIND_FLAGS.include?(option_name(option)) }
      own = options.select { |option| KEPT_FLAGS.include?(option_name(option)) }.map do |option|
        name, value = option.split("=", 2)
        # A file, made absolute, as for the named arguments.
        value ? "#{name}=#{named_argv(value.split(",")).join(",")}" : option
      end
      Forwarded.new(
        preview:,
        formula: split.reject { |option| cask_only.intersect?(names.call(option)) },
        cask:    split.reject { |option| formula_only.intersect?(names.call(option)) },
        own:,
      )
    end

    # The options brew gives the installers of the outdated dependents its
    # installed-dependents check upgrades (`Upgrade.upgrade_dependents`) that
    # `brew upgrade` takes. `--build-from-source` and `--HEAD` are only for
    # the named formulae, and `--debug-symbols` needs `--build-from-source`.
    DEPENDENT_FLAGS = %w[force_bottle keep_tmp force debug quiet verbose].freeze

    # Of `options`, the formula flags as `forward` gives them, those for the
    # `brew upgrade` call that upgrades the outdated dependents.
    sig { params(options: T::Array[String]).returns(T::Array[String]) }
    def self.dependent_flags(options) = options.select { |option| DEPENDENT_FLAGS.include?(option_name(option)) }

    # The switches `brew install`, `brew upgrade` and `brew reinstall` give
    # their installers and installed-dependents check, other than those every
    # command has.
    INSTALLER_SWITCHES = %w[force_bottle interactive keep_tmp debug_symbols force].freeze

    # The options `brew install`, `brew upgrade` and `brew reinstall` give
    # their installers and installed-dependents check, from `args` of a
    # `-timed` command, which take every flag of the command they wrap.
    sig { params(args: Homebrew::CLI::Args).returns(T::Hash[Symbol, T.any(T::Boolean, T::Array[String])]) }
    def self.installer_options(args)
      INSTALLER_SWITCHES.to_h { |name| [name.to_sym, args.public_send(:"#{name}?") == true] }.merge(
        build_from_source_formulae: args.build_from_source_formulae,
        debug:                      args.debug?,
        quiet:                      args.quiet?,
        verbose:                    args.verbose?,
      )
    end

    # The options brew gives the dependents with broken linkage it reinstalls
    # from source (`Upgrade.upgrade_dependents`), besides
    # `--build-from-source`, with which `--force-bottle` conflicts.
    LINKAGE_FLAGS = %w[keep_tmp debug_symbols force debug quiet verbose].freeze

    # The calls `Runner.run` makes after the batches, for what brew's
    # installed-dependents check does after the formulae it installs:
    # upgrading the outdated `dependents` it found for `checked`, then
    # reinstalling the dependents with broken linkage. `flags` are the formula
    # flags as `forward` gives them, and `own` its `own`; `excluded`, the full
    # names of formulae left out of the run, which neither call touches, nor
    # the commands they give to finish what they leave. None, and the check
    # left to brew, if the user has turned it off.
    sig {
      params(dependents: T::Array[Formula], checked: T::Array[Formula], args: Homebrew::CLI::Args,
             flags: T::Array[String], excluded: T::Array[String], own: T::Array[String])
        .returns(T.nilable(T::Array[Runner::After]))
    }
    def self.after(dependents, checked, args:, flags:, excluded:, own:)
      return if Homebrew::EnvConfig.no_installed_dependents_check?

      [dependents_call(dependents, checked, args:, flags:, own:), linkage_call(flags:, excluded:, own:)]
    end

    # The command that upgrades `names`: `brew upgrade-timed` with the run's
    # `own` flags, as brew's own installed-dependents check in a plain `brew
    # upgrade` would upgrade outdated dependents the run excluded, but without
    # `names` (full names) in its `--exclude`, which would leave them out.
    sig { params(names: T::Array[String], own: T::Array[String]).returns(String) }
    def self.upgrade_command(names, own:)
      flags = own.filter_map do |option|
        next option if option_name(option) != "exclude"

        kept = option.delete_prefix("--exclude=").split(",").reject do |name|
          names.include?(Formulary.factory(name).full_name)
        rescue FormulaUnavailableError, TapFormulaAmbiguityError, Homebrew::UntrustedTapError
          false
        end
        "--exclude=#{kept.join(",")}" if kept.any?
      end
      shell_command(["brew", "upgrade-timed", *flags, *names])
    end
    private_class_method :upgrade_command

    # `argv` as a command to run, each argument escaped for the shell, but
    # only the value of an option with one, as `=` needs no escaping.
    sig { params(argv: T::Array[String]).returns(String) }
    def self.shell_command(argv)
      argv.map do |arg|
        option, value = arg.split("=", 2) if arg.match?(/\A--[\w-]+=/)
        value ? "#{option}=#{Shellwords.escape(value)}" : Shellwords.escape(arg)
      end.join(" ")
    end
    private_class_method :shell_command

    # The command that reinstalls the dependents with broken linkage `names`
    # from source, as the run's call does: with brew's own installed-dependents
    # check off, as the run's call has it, so it upgrades or reinstalls nothing
    # else. With the note that says so, to print after the commands, so they
    # can be copied as they are.
    sig { params(names: T::Array[String]).returns([String, String]) }
    def self.reinstall_command(names)
      ["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source #{names.join(" ")}",
       "The reinstall skips Homebrew's installed-dependents check, as this run's own call did."]
    end
    private_class_method :reinstall_command

    # Upgrades the outdated `dependents` of `checked`. As brew does before
    # installing anything, leaves out those whose bottles the installed
    # versions of their dependencies already satisfy, and does that again
    # once the batches are done, for those still outdated.
    sig {
      params(dependents: T::Array[Formula], checked: T::Array[Formula], args: Homebrew::CLI::Args,
             flags: T::Array[String], own: T::Array[String]).returns(Runner::After)
    }
    def self.dependents_call(dependents, checked, args:, flags:, own:)
      installers = if dependents.any?
        Homebrew::Upgrade.dependent_formula_installers(
          Homebrew::Upgrade::Dependents.new(upgradeable: dependents, pinned: [], skipped: []), checked,
          flags: args.flags_only, **installer_options(args)
        )
      else
        []
      end
      Runner::After.new(
        label: Runner::After::DEPENDENTS, verb: "upgrade", flags: dependent_flags(flags),
        noun: "outdated dependent",
        candidates: installers.map(&:formula), deps: ->(formula) { dependency_names(formula) },
        choose: lambda do |_installed, _blocked|
          # Brew installed the batches in other processes.
          Formula.clear_cache
          outdated = installers.reject { |installer| installer.formula.latest_version_installed? }
          outdated.empty? ? [] : Homebrew::Upgrade.filter_dependent_formula_installers(outdated).map(&:formula)
        end,
        finish: ->(left) { upgrade_command(left, own:) }
      )
    end
    private_class_method :dependents_call

    # Reinstalls from source, as brew does, the dependents with broken linkage
    # of the formulae the run installed, each loaded from the tap its receipt
    # names: all those of formulae built from source or from other taps (brew
    # checks non-core formulae only), but of the core bottles, whose linkage
    # brew takes as checked, only those built from source. Leaves out pinned
    # and outdated ones, as brew does, those the run failed, skipped, didn't
    # finish or left out (`excluded`), and those that need one of those,
    # naming them with the command to run.
    sig { params(flags: T::Array[String], excluded: T::Array[String], own: T::Array[String]).returns(Runner::After) }
    def self.linkage_call(flags:, excluded:, own:)
      Runner::After.new(
        label: Runner::After::LINKAGE, verb: "reinstall", noun: "broken dependent", candidates: nil,
        deps: ->(formula) { dependency_names(formula) },
        flags: ["--build-from-source", *flags.select { |option| LINKAGE_FLAGS.include?(option_name(option)) }],
        choose: lambda do |installed, blocked|
          # Brew installed the batches in other processes.
          Formula.clear_cache
          loaded = installed.filter_map do |name, how|
            # As `Formulary.keg_only?` does.
            [Formulary.from_rack(HOMEBREW_CELLAR/name), how]
          rescue FormulaUnavailableError, TapFormulaAmbiguityError, Homebrew::UntrustedTapError => e
            unchecked(name, e, blocked:, excluded:)
            nil
          end
          next [] if loaded.empty?

          poured, all = loaded.partition { |formula, how| formula.core_formula? && how == "poured" }
                              .map { |formulae| formulae.map(&:first) }
          oh1 "Checking for dependents of upgraded formulae..."
          broken = begin
            broken_dependents(dependents_to_check(all, poured:))
          rescue Interrupt
            opoo "The check for broken linkage didn't finish; not all the dependents of " \
                 "#{(all + poured).map(&:full_name).join(" ")} were checked."
            raise
          end
          ohai "No broken dependents found!" if broken.empty?
          repairable(broken, blocked:, excluded:, own:)
        end,
        finish: ->(left) { reinstall_command(left).join("\n") }
      )
    end
    private_class_method :linkage_call

    # Says that the dependents of the installed formula `name`, which can't be
    # loaded (`error`), weren't checked for broken linkage, with how to
    # reinstall those that can be found (by the tap its receipt names), but
    # not those `fixable` leaves out.
    sig { params(name: String, error: Exception, blocked: T::Array[String], excluded: T::Array[String]).void }
    def self.unchecked(name, error, blocked:, excluded:)
      tab = Keg.from_rack(HOMEBREW_CELLAR/name)&.tab
      tap = tab&.tap&.name || CoreTap.instance.name
      dependents = begin
        Formula.installed.select do |formula|
          formula.any_installed_keg&.runtime_dependencies&.any? do |dependency|
            full_name = dependency["full_name"].to_s
            dependency_tap = full_name.include?("/") ? full_name.rpartition("/").first : CoreTap.instance.name
            Utils.name_from_full_name(full_name) == name && dependency_tap == tap
          end
        end
      rescue
        []
      end
      ready, others = dependents.partition { |dependent| fixable?(dependent, blocked:, excluded:) }
      how = if ready.any?
        "\nTo check them, reinstall them from source:\n  #{reinstall_command(ready.map(&:full_name)).join("\n")}"
      end
      if others.any?
        how = "#{how}\nNot counting #{others.map(&:full_name).join(" ")}, which " \
              "#{(others.length == 1) ? "is" : "are"} pinned, outdated, left out of the run or " \
              "#{(others.length == 1) ? "needs" : "need"} what this run didn't install."
      end
      opoo "Couldn't check the dependents of #{name} for broken linkage: #{error}#{how}"
    end
    private_class_method :unchecked

    # Whether `formula` can be reinstalled from source now: it isn't pinned,
    # outdated, `excluded` or `blocked` (failed, skipped or not finished), nor
    # needs one of `blocked`.
    sig { params(formula: Formula, blocked: T::Array[String], excluded: T::Array[String]).returns(T::Boolean) }
    def self.fixable?(formula, blocked:, excluded:)
      !formula.pinned? && !formula.outdated? && (excluded + blocked).exclude?(formula.full_name) &&
        !dependency_names(formula).intersect?(blocked)
    end
    private_class_method :fixable?

    # The installed dependents to check for broken linkage: all those of
    # `formulae`, and those of `poured` built from source.
    sig { params(formulae: T::Array[Formula], poured: T::Array[Formula]).returns(T::Array[Formula]) }
    def self.dependents_to_check(formulae, poured:)
      built = poured.flat_map(&:runtime_installed_formula_dependents).reject do |dependent|
        dependent.any_installed_keg&.tab&.poured_from_bottle
      end
      (formulae.flat_map(&:runtime_installed_formula_dependents) + built).uniq
    end

    # Of the `broken` dependents, those to reinstall, dependencies first, as
    # brew does: not pinned or outdated, as brew does, nor `excluded` or
    # `blocked` (failed, skipped or not finished), nor needing one of
    # `blocked`, which a command for them would install as a dependency.
    # Names the others with how to fix them (`own` as for `after`).
    sig {
      params(broken: T::Array[Formula], blocked: T::Array[String], excluded: T::Array[String],
             own: T::Array[String]).returns(T::Array[Formula])
    }
    def self.repairable(broken, blocked:, excluded:, own:)
      needs = broken.to_h { |formula| [formula, dependency_names(formula) & blocked] }
      # First, as `brew upgrade` of one, outdated as it is, would pour it.
      untouched, rest = broken.partition { |formula| blocked.include?(formula.full_name) }
      waiting, rest = rest.partition { |formula| needs.fetch(formula).any? }
      pinned, rest = rest.partition(&:pinned?)
      outdated, rest = rest.partition(&:outdated?)
      left_out, rest = rest.partition { |formula| excluded.include?(formula.full_name) }
      names = ->(formulae) { formulae.map(&:full_name).join(" ") }
      what = lambda do |formulae, kind = nil|
        count = Utils.pluralize("dependent", formulae.length, include_count: true)
        "Not reinstalling #{count.sub(" ", " #{kind} ".squeeze(" "))} with broken linkage"
      end
      reinstall = ->(formulae) { reinstall_command(formulae.map(&:full_name)).join("\n") }
      upgrade = ->(formulae) { upgrade_command(formulae.map(&:full_name), own:) }
      # The commands for `formulae`, each after its heading: the outdated ones
      # upgraded, as `brew reinstall` would upgrade them, from source. Then
      # any note, so the commands can be copied as they are.
      fixes = lambda do |formulae, reinstall_with, upgrade_with|
        stale, current = formulae.partition(&:outdated?)
        command, note = reinstall_command(current.map(&:full_name)) if current.any?
        [("#{reinstall_with}  #{command}" if command), ("#{upgrade_with}  #{upgrade.call(stale)}" if stale.any?),
         note].compact.join("\n")
      end
      if waiting.any?
        held = waiting.select(&:pinned?)
        needing = waiting.map { |formula| "#{formula.full_name} (needs #{needs.fetch(formula).join(" ")})" }
        opoo "#{what.call(waiting)}, as they need what this run didn't install: #{needing.join(", ")}\n" \
             "#{"Unpin #{names.call(held)} first. " if held.any?}Once that installs, run:\n" \
             "#{fixes.call(waiting, "", "")}"
      end
      if pinned.any?
        onoe "#{what.call(pinned, "pinned")}: #{names.call(pinned)}\n" \
             "#{fixes.call(pinned, "Once unpinned, reinstall with:\n",
                           "Once unpinned, upgrade, which reinstalls, with:\n")}"
      end
      if outdated.any?
        opoo "#{what.call(outdated, "outdated")}: #{names.call(outdated)}\n" \
             "Upgrade, which reinstalls, with:\n  #{upgrade.call(outdated)}"
      end
      if left_out.any?
        opoo "#{what.call(left_out)} given to `--exclude`: #{names.call(left_out)}\n" \
             "Reinstall with:\n  #{reinstall.call(left_out)}"
      end
      if untouched.any?
        they = (untouched.length == 1) ? "it installs" : "they install"
        opoo "#{what.call(untouched)} that this run didn't finish: #{names.call(untouched)}\n" \
             "Once #{they}, reinstall with:\n  #{reinstall.call(untouched)}"
      end
      rest.sort { |one, two| depends_on(one, two) }
    end
    private_class_method :repairable

    # Brew's order for the dependents it reinstalls (`Upgrade.depends_on`,
    # which is private): after those they depend on, otherwise by name.
    sig { params(one: Formula, two: Formula).returns(Integer) }
    def self.depends_on(one, two)
      if one.any_installed_keg
            &.runtime_dependencies
            &.any? { |dependency| dependency["full_name"] == two.full_name }
        return 1
      end

      comparison = one <=> two
      raise ArgumentError, "Cannot compare #{one.full_name} with #{two.full_name}" if comparison.nil?

      comparison
    end
    private_class_method :depends_on

    # Those of the installed `dependents` with broken library linkage, as
    # brew finds them after upgrading (`Upgrade.check_broken_dependents`,
    # which is private).
    sig { params(dependents: T::Array[Formula]).returns(T::Array[Formula]) }
    def self.broken_dependents(dependents)
      CacheStoreDatabase.use(:linkage) do |db|
        dependents.select do |dependent|
          keg = dependent.any_installed_keg
          next false if keg.nil? || !keg.directory?

          # As brew does.
          cache_db = T.cast(db, CacheStoreDatabase[String, T::Hash[T.any(String, Symbol), T.anything]])
          LinkageChecker.new(keg, cache_db:).broken_library_linkage?
        end
      end
    end

    # Runs `brew` with `argv` from the home directory (source builds that
    # clone a repository fail from some directories), adding `env` to the
    # environment (`nil` removes a variable). Returns what `Kernel.system`
    # does: whether it succeeded, or nil if it couldn't run.
    Brew = T.type_alias do
      T.proc.params(env: T::Hash[String, T.nilable(String)], argv: T::Array[String]).returns(T.nilable(T::Boolean))
    end

    sig { params(env: T::Hash[String, T.nilable(String)], argv: T::Array[String]).returns(T.nilable(T::Boolean)) }
    def self.brew(env, argv) = Kernel.system(env, HOMEBREW_BREW_FILE.to_s, *argv, chdir: Dir.home)

    # Named arguments for the sub-calls, which run from another directory:
    # paths brew would load a formula (`.rb`) or cask (`.rb`, `.json`) from
    # made absolute.
    sig { params(names: T::Array[String]).returns(T::Array[String]) }
    def self.named_argv(names)
      names.map { |name| (name.end_with?(".rb", ".json") && File.exist?(name)) ? File.expand_path(name) : name }
    end

    # The argument for each of `formulae` (by full name) that `names` gave as
    # a path, as `named_argv` makes it. Brew loads such a formula from that
    # file only: by name, a sub-call would load another formula, or the one
    # stored in its installed keg.
    sig { params(names: T::Array[String], formulae: T::Hash[String, Formula]).returns(T::Hash[String, String]) }
    def self.path_arguments(names, formulae)
      paths = named_argv(names)
      formulae.filter_map { |name, formula| [name, formula.path.to_s] if paths.include?(formula.path.to_s) }.to_h
    end

    # Set in the command re-run after an update, so it never updates again.
    AUTO_UPDATED_ENV = "HOMEBREW_TIMED_AUTO_UPDATED"

    # Auto-updates as `brew install` and `brew upgrade` do, which brew only
    # does itself for its own commands. `brew update-if-needed` makes the same
    # checks (`HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_AUTO_UPDATE_SECS`), but is
    # a no-op with `HOMEBREW_AUTO_UPDATE_CHECKED`, which brew sets before
    # running any command, so it runs without that. Like brew before a
    # `brew upgrade` without named arguments (`auto-update` in
    # `utils/auto-update.sh`), it skips the count of outdated packages, which
    # the plan lists. If it fetched, re-runs the command with its original
    # `argv`, as brew does, so neither brew's code nor formula data are stale.
    sig {
      params(
        command:    String,
        argv:       T::Array[String],
        fetch_head: Pathname,
        brew:       Brew,
        exec:       T.proc.params(env: T::Hash[String, String], argv: T::Array[String]).void,
      ).void
    }
    def self.auto_update(command:, argv:, fetch_head: HOMEBREW_REPOSITORY/".git/FETCH_HEAD",
                         brew: ->(env, brew_argv) { self.brew(env, brew_argv) },
                         exec: ->(env, exec_argv) { Kernel.exec(env, HOMEBREW_BREW_FILE.to_s, *exec_argv) })
      return if ENV.key?(AUTO_UPDATED_ENV)

      fetched_at = -> { fetch_head.mtime if fetch_head.exist? }
      before = fetched_at.call
      skip_outdated = "1" if argv.all? { |arg| arg.start_with?("-") }
      brew.call({ "HOMEBREW_AUTO_UPDATE_CHECKED" => nil, "HOMEBREW_AUTO_UPDATE_SKIP_OUTDATED" => skip_outdated },
                ["update-if-needed"])
      return if fetched_at.call == before

      exec.call({ AUTO_UPDATED_ENV => "1" }, [command, *argv])
    end

    # The full names of the formulae `formula` needs, to run those first, as
    # every caller compares them with full names: brew's expansion, which
    # leaves out optional and recommended dependencies the formula isn't
    # built with, also leaving out those that can't be loaded, e.g. from a tap
    # that isn't trusted (and what only they need). It already renames each dependency it keeps to its
    # formula's full name, whatever name `depends_on` gave it
    # (`dup_with_formula_name` in `Dependency.expand`).
    sig { params(formula: Formula).returns(T::Array[String]) }
    def self.dependency_names(formula)
      formula.recursive_dependencies do |dependent, dependency|
        dependency.to_formula
        Dependency.action(dependent, dependency)
      rescue FormulaUnavailableError, Homebrew::UntrustedTapError
        Dependable::PRUNE
      end.map(&:name)
    end

    # What brew installs or upgrades as dependencies in the call for each of
    # `installers`' formulae, by full name, keyed by the formula's
    # (`FormulaInstaller#compute_dependencies`, which brew's plan has worked
    # out); nothing with `--ignore-dependencies`. Where brew can't work them
    # out (e.g. a dependency can't be loaded, for brew to report), every
    # dependency that loads, also by full name (see `dependency_names`), to be
    # safe.
    sig { params(installers: T::Array[FormulaInstaller]).returns(T::Hash[String, T::Array[String]]) }
    def self.run_dependencies(installers)
      installers.to_h do |installer|
        dependencies = if installer.ignore_deps?
          []
        else
          begin
            installer.compute_dependencies.map { |dependency| dependency.to_formula.full_name }
          rescue
            dependency_names(installer.formula)
          end
        end
        [installer.formula.full_name, dependencies]
      end
    end

    # The lookahead asks for at least one of hours, minutes or seconds.
    GUESS = /\A(?<name>[^=]+)=(?=\d)(?:(?<h>\d+)h)?(?:(?<m>\d+)m)?(?:(?<s>\d+)s)?\z/

    # Seconds by name from `--guess`'s `name=duration` pairs, each name
    # passed through `resolve`.
    sig {
      params(pairs: T::Array[String], resolve: T.proc.params(name: String).returns(String))
        .returns(T::Hash[String, Float])
    }
    def self.guesses(pairs, resolve: ->(name) { name })
      pairs.each_with_object({}) do |pair, guesses|
        match = GUESS.match(pair)
        raise UsageError, "`--guess` needs `name=duration`, e.g. `llvm=1h30m`, not `#{pair}`." if match.nil?

        seconds = (match[:h].to_i * 3600.0) + (match[:m].to_i * 60) + match[:s].to_i
        raise UsageError, "`--guess` needs a duration over zero, not `#{pair}`." if seconds.zero?

        name = resolve.call(match[:name].to_s)
        raise UsageError, "`--guess` gives `#{name}` more than once." if guesses.key?(name)

        guesses[name] = seconds
      end
    end

    # The full name of the formula `name` given to `flag`.
    sig { params(flag: String, name: String).returns(String) }
    def self.resolve(flag, name)
      Formulary.factory(name).full_name
    rescue FormulaUnavailableError => e
      raise UsageError, "`#{flag}`: #{e}"
    end

    # `--estimator`'s value, `:mean` by default.
    sig { params(value: T.nilable(String)).returns(Symbol) }
    def self.estimator(value)
      return :mean if value.nil?
      return value.to_sym if %w[mean median].include?(value)

      raise UsageError, "`--estimator` must be `mean` or `median`, not `#{value}`."
    end

    # How long a formula is expected to take, and how that was worked out.
    class Estimate < T::Struct
      const :seconds, Float
      const :pour, T::Boolean
      # No history of this kind of build, no `--guess` and no LLM estimate.
      const :fallback, T::Boolean
      # From `--guess` or an LLM, for a build without history.
      const :guessed, T::Boolean, default: false

      # How the plan marks it: `?` for a fallback, `*` for a guess.
      sig { returns(T.nilable(String)) }
      def mark
        if fallback
          "?"
        elsif guessed
          "*"
        end
      end
    end

    # From the formula's own history of the same kind (pour or build) only;
    # for a build without history, its `--guess`; otherwise the log's
    # fallback for that kind.
    sig {
      params(log: BuildLog, name: String, pour: T::Boolean, estimator: Symbol, guesses: T::Hash[String, Float])
        .returns(Estimate)
    }
    def self.estimate(log, name, pour:, estimator:, guesses:)
      history = log.durations(name, status: pour ? "poured" : "built").any?
      guess = guesses[name] if !pour && !history
      seconds = guess || log.estimate(name, pour:, estimator:) || log.fallback_estimate
      Estimate.new(seconds:, pour:, fallback: !history && guess.nil?, guessed: !guess.nil?)
    end

    # The estimate of each of `formulae` (by full name), as `estimate` makes
    # it, from the log at `database`. With `llm` settings, the source builds
    # left to the fallback get an LLM's estimate instead: the one the log
    # keeps for their version, else one asked for in one request and kept.
    # If that fails, they keep the fallback, as do those in `exclude` (by
    # full name), which the run leaves out.
    sig {
      params(formulae: T::Hash[String, Formula], pour: T.proc.params(formula: Formula).returns(T::Boolean),
             estimator: Symbol, guesses: T::Hash[String, Float], llm: T.nilable(LLM::Settings), database: Pathname,
             exclude: T::Array[String])
        .returns(T::Hash[String, Estimate])
    }
    def self.estimates(formulae, pour:, estimator:, guesses:, llm: nil, database: BuildLog.default_path,
                       exclude: [])
      log = BuildLog.load(database)
      estimates = formulae.to_h do |name, formula|
        [name, estimate(log, name, pour: pour.call(formula), estimator:, guesses:)]
      end
      return estimates if llm.nil?

      versions = formulae.filter_map do |name, formula|
        next if exclude.include?(name) || !estimates.fetch(name).fallback || estimates.fetch(name).pour

        [name, formula.pkg_version.to_s]
      end.to_h
      kept = versions.filter_map { |name, version| log.cached_estimate(name, version)&.then { [name, it] } }.to_h
      subjects = versions.except(*kept.keys).map do |name, version|
        formula = formulae.fetch(name)
        LLM::Subject.new(name:, version:, desc: formula.desc,
                         build_dependencies: formula.deps.select(&:build?).map(&:name))
      end
      answers = if subjects.any?
        count = Utils.pluralize("estimate", subjects.length, include_count: true)
        ohai "Asking #{llm.target} for #{count}"
        LLM.estimates(llm, subjects, machine: Machine.facts)
      else
        {}
      end
      if answers.any?
        date = Time.now.strftime("%F")
        begin
          BuildLog.update(database) do |updated|
            answers.each do |name, seconds|
              updated.cache_estimate(name, version: versions.fetch(name), seconds:, model: llm.model, date:)
            end
          end
        rescue => e
          opoo "Couldn't keep the LLM estimates in #{database}: #{e}"
        end
      end
      estimates.merge(kept.merge(answers).transform_values do |seconds|
        Estimate.new(seconds:, pour: false, fallback: false, guessed: true)
      end)
    end

    # How `show_plan` marks a batch of dependencies (`Planner::Batch#verb`).
    BATCH_VERB_TAGS = T.let({ dependency: "--as-dependency", upgrade: "upgrade" }.freeze, T::Hash[Symbol, String])

    # Prints the batches with their estimates, why each starts where it does,
    # the outdated `dependents` upgraded after them, the check for broken
    # linkage that follows if there are either (as brew checks after
    # installing or upgrading anything), unless the user has turned off
    # brew's installed-dependents check, and the planner's warnings.
    # Estimates ending in `?` are fallbacks, as in `brew build-times stats`.
    # With `dependencies_only` (`brew install --only-dependencies`), each row
    # is the dependencies of a formula, which have no estimates yet. Without
    # batches, it says so only if the run has no `casks` (named, planned or
    # `--cask`), whose lists say what it does.
    sig {
      params(verb: String, result: Planner::Result, estimates: T::Hash[String, Estimate], excluded: T::Array[String],
             dependencies_only: T::Boolean, casks: T::Boolean, dependents: T::Array[String]).void
    }
    def self.show_plan(verb, result, estimates, excluded:, dependencies_only: false, casks: false, dependents: [])
      result.warnings.each { |warning| opoo warning }
      batches = result.batches
      if batches.empty?
        ohai "No formulae to #{verb}" unless casks
      else
        duration = lambda do |names|
          BuildLog.format_duration(names.sum { |name| estimates.fetch(name).seconds }) unless dependencies_only
        end
        count = Utils.pluralize("formula", batches.sum { |batch| batch.names.length }, include_count: true)
        total = duration.call(batches.flat_map(&:names))
        oh1 "Would #{verb} #{"the dependencies of " if dependencies_only}#{count} in " \
            "#{Utils.pluralize("batch", batches.length, plural: "es", include_count: true)}" \
            "#{", estimated #{total}" if total}"
        batches.each.with_index(1) do |batch, index|
          reason = batch.reason if batch.reason != "--last"
          time = duration.call(batch.names)
          own_verb = batch.verb
          tags = [("--last" if batch.label == "last"), (BATCH_VERB_TAGS[own_verb] if own_verb)].compact
          ohai "Batch #{index} of #{batches.length}#{" (#{tags.join(", ")})" if tags.any?}" \
               "#{": #{time}" if time}#{", #{reason}" if reason}"
          batch.names.each do |name|
            next puts "dependencies of #{name}" if dependencies_only

            estimate = estimates.fetch(name)
            puts format("%<name>-28s %<kind>-5s %<estimate>9s", name:, kind: estimate.pour ? "pour" : "build",
                        estimate: "#{BuildLog.format_duration(estimate.seconds)}#{estimate.mark}")
          end
        end
      end
      if dependents.any?
        ohai Runner::After::HEADINGS.fetch(Runner::After::DEPENDENTS)
        puts dependents.join(" ")
      end
      if (batches.any? || dependents.any?) && !Homebrew::EnvConfig.no_installed_dependents_check?
        ohai Runner::After::HEADINGS.fetch(Runner::After::LINKAGE)
      end
      return if excluded.empty?

      ohai "Excluded"
      puts excluded.join(" ")
    end

    # `args.options_only`, with each `--[no-]…` switch, which brew leaves out
    # of it, added as `--…` or `--no-…` (e.g. `--no-binaries`) where `args`
    # differs from what `parser` takes from the environment alone, as a
    # sub-call would.
    sig { params(args: Homebrew::CLI::Args, parser: Homebrew::CLI::Parser).returns(T::Array[String]) }
    def self.options(args, parser)
      defaults = T.let(nil, T.nilable(Homebrew::CLI::Args))
      switches = parser.processed_options.filter_map do |_short, long|
        next if long.nil? || !long.start_with?("--[no-]")

        name = long.delete_prefix("--[no-]")
        method = :"#{option_name(name)}?"
        value = args.public_send(method)
        defaults ||= parser.parse(["--", *args.named])
        "--#{"no-" unless value}#{name}" if !value.nil? && value != defaults.public_send(method)
      end
      args.options_only + switches
    end

    # The cask brew uninstalls before it upgrades or reinstalls `cask`: the one
    # its installed caskfile defines, or one rebuilt from that file's version
    # and `cask`'s artifacts if that can't be loaded, as `Cask::Upgrade` does;
    # nil if that fails too or `cask` isn't installed. To `reinstall`, with tap
    # trust on, brew loads a Ruby caskfile only for a trusted cask, and
    # otherwise uninstalls the artifacts the cask recorded and zaps with
    # `cask`'s `zap` stanza (`Installer#load_installed_caskfile!`): see
    # `recorded_cask` then.
    sig { params(cask: Cask::Cask, reinstall: T::Boolean).returns(T.nilable(Cask::Cask)) }
    def self.installed_cask(cask, reinstall: false)
      return unless (caskfile = cask.installed_caskfile)

      tab = Cask::CaskLoader.load_installed_tab(cask)
      if reinstall && caskfile.extname == ".rb" && Homebrew::EnvConfig.require_tap_trust? &&
         (tap = tab.tap || cask.tap) && !Homebrew::Trust.trusted?(:cask, "#{tap.name}/#{cask.token}")
        begin
          return recorded_cask(cask, tab)
        rescue
          # `cask` stands in.
          return
        end
      end

      begin
        Cask::CaskLoader.load_from_installed_caskfile(caskfile)
      rescue Cask::CaskInvalidError, Cask::CaskUnavailableError, MethodDeprecatedError
        Cask::CaskLoader.recover_from_installed_caskfile(caskfile, fallback_cask: cask)
      end
    end

    # `cask` with the uninstall artifacts its `tab` recorded, as brew replays
    # them to uninstall a cask it won't load (`Installer#load_installed_caskfile!`
    # without its migration and warning): only the artifact kinds that have an
    # uninstall phase, other than `uninstall` and `zap`. Brew never runs the
    # new cask's `uninstall` stanza then, but this keeps it, to be safe, and its
    # `zap`, which brew does run for `--zap`.
    sig { params(cask: Cask::Cask, tab: Cask::Tab).returns(Cask::Cask) }
    def self.recorded_cask(cask, tab)
      keys = Cask::DSL::ACTIVATABLE_ARTIFACT_CLASSES.filter_map do |klass|
        next if [Cask::Artifact::Uninstall, Cask::Artifact::Zap].include?(klass)
        next if !klass.method_defined?(:uninstall_phase) && !klass.method_defined?(:post_uninstall_phase)

        klass.dsl_key
      end
      entries = Array(tab.uninstall_artifacts).grep(Hash)
      kept = cask.artifacts.grep(Cask::Artifact::AbstractUninstall)
      version = cask.version.to_s
      Cask::Cask.new(cask.token, tap: cask.tap, config: cask.config) do
        T.bind(self, Cask::DSL)
        self.version version
        entries.each do |entry|
          entry.each do |raw_key, raw_args|
            dsl_key = raw_key.to_sym
            next unless keys.include?(dsl_key)

            args = Array(raw_args)
            last = args.last
            if last.is_a?(Hash)
              public_send(dsl_key, *args[...-1], **last.transform_keys(&:to_sym))
            else
              public_send(dsl_key, *args)
            end
          end
        end
        kept.each { |artifact| artifacts.add(artifact) }
      end
    end

    # Sorts the casks of a run, given by the verb brew acts on each with, into
    # those to run before the formulae, after them and not at all, by what is
    # on disk and whether sudo can prompt. `in_run` names the formulae in the
    # run, by full name; the casks are in it too, kept apart, as a formula and
    # a cask may share a name. Each cask counts what brew may install before
    # it that is in the run (see `cask_needs`, `Needs#formulae_among` and
    # `Needs#casks_among`), handed to `Casks.plan` by full name, and what installing
    # its missing cask
    # dependencies needs, unless `skip_cask_deps` (`--skip-cask-deps`), with
    # which brew installs only formula dependencies, those of skipped casks
    # included, so a cask isn't skipped for a skipped cask it depends on.
    # The run includes what brew installs for its formulae as dependencies,
    # given by `run_dependencies` (see `run_dependencies`). `zap` and `force`
    # are the wrapped command's.
    sig {
      params(casks: T::Hash[Symbol, T::Array[Cask::Cask]], in_run: T::Array[String],
             run_dependencies: T::Hash[String, T::Array[String]], zap: T::Boolean, force: T::Boolean,
             skip_cask_deps: T::Boolean, facts: Casks::Facts, tty: T.proc.returns(T::Boolean))
        .returns(Casks::Plan)
    }
    def self.cask_plan(casks, in_run:, run_dependencies: {}, zap: false, force: false, skip_cask_deps: false,
                       facts: Casks::DiskFacts.new, tty: -> { Casks.terminal? })
      installed_for = T.let({}, T::Hash[String, T::Array[String]])
      run_dependencies.each do |formula, dependencies|
        (dependencies - in_run).each { |dependency| (installed_for[dependency] ||= []) << formula }
      end
      in_run += installed_for.keys
      casks_in_run = casks.values.flatten.map(&:full_name)
      plans = casks.map do |verb, list|
        installed = list.filter_map do |cask|
          installed_cask(cask, reinstall: verb == :reinstall)&.then { |old| [cask.full_name, old] }
        end.to_h
        # Keyed by full name, as casks from different taps may share a token.
        all_needs = list.to_h { |cask| [cask.full_name, cask_needs(cask)] }
        needs = all_needs.transform_values do |needed|
          [needed.formulae_among(in_run), skip_cask_deps ? [] : needed.casks_among(casks_in_run)]
        end
        missing = all_needs.transform_values { |needed| skip_cask_deps ? [] : needed.casks.reject(&:installed?) }
        # Only a cask dependency runs a skipped cask's sudo, and none with
        # `--skip-cask-deps`, when brew fails a cask whose dependency can't
        # be loaded with its own error.
        cask_dependencies = all_needs.transform_values do |needed|
          skip_cask_deps ? [[], []] : [needed.casks.map(&:full_name), needed.unresolved_casks]
        end
        Casks.plan(list, verb:, in_run:, casks_in_run:, facts:, tty:, installed:, zap:, force:, needs:, missing:,
                         cask_dependencies:, installed_for:)
      end
      Casks::Plan.new(first:   plans.flat_map(&:first), last: plans.flat_map(&:last),
                      skipped: plans.flat_map(&:skipped))
    end

    # Lists the casks to run before the formulae and those to run after them,
    # with why, and warns about those skipped for want of a terminal, with the
    # command to run them later (see `later`).
    sig { params(verb: String, plan: Casks::Plan, named: T::Array[String], flags: T::Array[String]).void }
    def self.show_casks(verb, plan, named:, flags:)
      rows = lambda do |entries|
        entries.map { |entry| "#{entry.cask.full_name}: #{entry.reasons.map(&:message).join("; ")}" }
      end
      { "first" => plan.first, "last" => plan.last }.each do |label, entries|
        next if entries.empty?

        ohai "Would #{verb} #{Utils.pluralize("cask", entries.length, include_count: true)} #{label}"
        puts((label == "first") ? entries.map { |entry| entry.cask.full_name }.join(" ") : rows.call(entries))
      end
      return if plan.skipped.empty?

      casks = plan.skipped.map(&:cask)
      opoo <<~EOS
        Skipping #{Utils.pluralize("cask", casks.length, include_count: true)}, as sudo can't ask for a password without a terminal:
        #{rows.call(plan.skipped).join("\n")}
        #{later(verb, casks, named:, flags:)}
      EOS
    end

    # Everything brew may install before a cask: formulae by full name and
    # casks, by name if they can't be loaded (e.g. from a tap that isn't
    # trusted).
    class Needs < T::Struct
      # Formulae by full name, so aliases and renames are resolved.
      const :formulae, T::Array[String], default: []
      const :casks, T::Array[Cask::Cask], default: []
      # Formulae and casks that can't be loaded, as named.
      const :unresolved_formulae, T::Array[String], default: []
      const :unresolved_casks, T::Array[String], default: []

      # Those of the formulae `names` (full names, e.g. of formulae in the run)
      # this needs: by full name, or, for one that can't be loaded, by name
      # alone, which may match another tap's formula of that name, to be safe.
      sig { params(names: T::Array[String]).returns(T::Array[String]) }
      def formulae_among(names) = Needs.among(names, formulae, unresolved_formulae)

      # Those of the casks `names` this needs, as `formulae_among` matches
      # formulae, as a formula and a cask may share a name.
      sig { params(names: T::Array[String]).returns(T::Array[String]) }
      def casks_among(names) = Needs.among(names, casks.map(&:full_name), unresolved_casks)

      sig { params(names: T::Array[String], full: T::Array[String], unresolved: T::Array[String]).returns(T::Array[String]) }
      def self.among(names, full, unresolved)
        loose = unresolved.map { |name| ::Utils.name_from_full_name(name) }
        names.select { |name| full.include?(name) || loose.include?(::Utils.name_from_full_name(name)) }
      end
    end

    # What brew's cask installer may install before `cask`
    # (`Cask::Installer#cask_and_formula_dependencies`): what it and its
    # download's container (see `container_needs`) depend on, following
    # formulae through their dependencies other than build and test ones, and
    # the casks those require, and casks through what they and their
    # containers depend on.
    sig { params(cask: Cask::Cask).returns(Needs) }
    def self.cask_needs(cask)
      formulae = T.let([], T::Array[String])
      casks = T.let([], T::Array[Cask::Cask])
      unresolved_formulae = T.let([], T::Array[String])
      unresolved_casks = T.let([], T::Array[String])
      seen = [cask.full_name]
      pending = cask.depends_on.formula.map { |name| [:formula, name] } +
                cask.depends_on.cask.map { |name| [:cask, name] } + container_needs(cask)
      while (kind, name = pending.shift)
        if kind == :formula
          begin
            formula = Formulary.factory(name)
            next if formulae.include?(formula.full_name)

            formulae << formula.full_name
            pending.concat(formula.deps.reject { |dep| dep.build? || dep.test? }.map { |dep| [:formula, dep.name] })
            pending.concat(formula.requirements.filter_map(&:cask).map { |token| [:cask, token] })
          rescue FormulaUnavailableError, Homebrew::UntrustedTapError
            unresolved_formulae |= [name]
          end
        else
          begin
            dependency = Cask::CaskLoader.load(name, warn: false)
          rescue Cask::CaskError, Homebrew::UntrustedTapError
            unresolved_casks |= [name]
            next
          end
          # By full name, as another tap's cask may share a token.
          next if seen.include?(dependency.full_name)

          seen << dependency.full_name
          casks << dependency
          pending.concat(dependency.depends_on.formula.map { |formula_name| [:formula, formula_name] } +
                         dependency.depends_on.cask.map { |cask_name| [:cask, cask_name] } +
                         container_needs(dependency))
        end
      end
      Needs.new(formulae:, casks:, unresolved_formulae:, unresolved_casks:)
    end

    # What brew needs to unpack `cask`'s download (`UnpackStrategy#dependencies`,
    # e.g. `xz`), as `[:formula, name]` and `[:cask, name]`. Brew only knows the
    # container once it has the download, so, without downloading, this goes
    # by the cask's `container type:`, else its download if already cached,
    # else the extension of the file it would download to, as brew reads it
    # (`.tar.xz` is a tarball, which needs nothing); nothing if none of those
    # works out.
    sig { params(cask: Cask::Cask).returns(T::Array[[Symbol, String]]) }
    def self.container_needs(cask)
      cached = Cask::Download.new(cask).cached_download
      strategy = if (type = cask.container&.type)
        UnpackStrategy.from_type(type)&.new(cached)
      elsif cached.exist?
        UnpackStrategy.detect(cached)
      else
        # Under-counts a tarball the system `tar` can't list (e.g. some
        # `.tar.zst`), which brew unpacks by its compressor.
        UnpackStrategy.from_extension(cached.extname)&.new(cached)
      end
      Array(strategy&.dependencies).map do |dependency|
        dependency.is_a?(Formula) ? [:formula, dependency.full_name] : [:cask, dependency.full_name]
      end
    rescue
      []
    end

    # The formulae a `-timed` command runs, to finish them later: `command`,
    # the `-timed` command with the formula flags its calls were given;
    # `roots`, the formulae (by full name) it was given that it runs, each
    # with its argument (the file given, see `path_arguments`, or its name),
    # so that flags only for those given (e.g. `--build-from-source`) stay
    # theirs; `needs`, what brew installs or upgrades for each of `roots`, by
    # full name.
    class Run < T::Struct
      const :command, T::Array[String]
      const :roots, T::Hash[String, String]
      const :needs, T::Hash[String, T::Array[String]]
    end

    # Returns what the block, which runs the formulae, returns, given what
    # `after` returns: the calls after the batches, worked out first. If
    # Ctrl-C stops either, the `casks` to run after the formulae don't run
    # either: says so (see `casks_not_run`) and stops too, saying first that
    # the batches didn't run if it stopped `after`. `merged` says whether the
    # commands that finish the formulae, then the casks, were given already.
    sig {
      type_parameters(:U).params(verb: String, casks: T::Array[Cask::Cask], named: T::Array[String],
                                 flags: T::Array[String], run: Run,
                                 after: T.proc.returns(T.nilable(T::Array[Runner::After])),
                                 merged: T.proc.returns(T::Boolean),
                                 _block: T.proc.params(after: T.nilable(T::Array[Runner::After]))
                                          .returns(T.type_parameter(:U)))
                         .returns(T.type_parameter(:U))
    }
    def self.before_last_casks(verb, casks, named:, flags:, run:, after: -> {}, merged: -> { false }, &_block)
      calls = begin
        after.call
      rescue Interrupt
        opoo "Interrupted, so the batches didn't run."
        raise
      end
      yield calls
    rescue Interrupt
      casks_not_run("Interrupted", verb, casks, named:, flags:, run:, merged: merged.call) if casks.any?
      raise
    end

    # Says that the `casks` to run after the formulae didn't run, and why
    # (`reason`), naming them as `cask_arguments` does for the `named`
    # arguments, with how to run them later (see `later`), but those that
    # need a formula of the `run` that isn't installed (see `blocked_casks`)
    # with how to finish that first (see `finish_first`, given `merged`).
    sig {
      params(reason: String, verb: String, casks: T::Array[Cask::Cask], named: T::Array[String],
             flags: T::Array[String], run: Run, merged: T::Boolean).void
    }
    def self.casks_not_run(reason, verb, casks, named:, flags:, run:, merged: false)
      message = "#{reason}, so the #{Utils.pluralize("cask", casks.length)} to #{verb} after the formulae " \
                "didn't run: #{cask_arguments(named, casks).join(" ")}"
      blocked = blocked_casks(casks, run.roots.keys | run.needs.values.flatten)
      if blocked.empty?
        opoo "#{message}\n#{later(verb, casks, named:, flags:)}"
        return
      end

      one = blocked.length == 1
      ready = casks - blocked.keys
      lines = [
        message,
        "#{Utils.pluralize("cask", blocked.length, include_count: true)} #{one ? "needs" : "need"} formulae of " \
        "this run that aren't installed, which brew would\n" \
        "install for #{one ? "it" : "them"}, but not as this run would:",
        *finish_first(verb, blocked, named:, flags:, run:, merged:),
      ]
      if ready.any?
        lines << "#{verb.capitalize} the #{(ready.length == 1) ? "other" : "others"} later with " \
                 "`#{cask_command(verb, ready, named:, flags:)}`."
      end
      opoo lines.join("\n")
    end

    # Of `casks`, those that need (see `cask_needs`) one of the formulae
    # `candidates` (by full name) that isn't installed and linked into
    # `opt`, with those formulae: brew's cask installer would install them
    # for the cask, without the formula options given for them. One that is
    # installed, even an old version, brew leaves alone.
    sig {
      params(casks: T::Array[Cask::Cask], candidates: T::Array[String])
        .returns(T::Hash[Cask::Cask, T::Array[String]])
    }
    def self.blocked_casks(casks, candidates)
      # Loaded by full name, so another tap's formula of the same name isn't.
      missing = lambda do |name|
        formula = Formulary.factory(name)
        !(formula.any_version_installed? && formula.optlinked?)
      rescue FormulaUnavailableError, Homebrew::UntrustedTapError
        true
      end
      needs = casks.to_h do |cask|
        # Brew installs formula dependencies even with `--skip-cask-deps`.
        [cask, cask_needs(cask).formulae_among(candidates).select { |name| missing.call(name) }]
      end
      needs.select { |_, needed| needed.any? }
    end
    private_class_method :blocked_casks

    # Names what each of the `blocked` casks needs (see `blocked_casks`),
    # then how to finish that first: the `run`'s command for the formulae
    # given to it that bring those in, then the casks' own command. With no
    # such formula (e.g. an outdated dependency of one given to `--exclude`),
    # only the casks' command, for once those are installed. With `merged`,
    # those commands were given already (see `finish_command`).
    sig {
      params(verb: String, blocked: T::Hash[Cask::Cask, T::Array[String]], named: T::Array[String],
             flags: T::Array[String], run: Run, merged: T::Boolean).returns(T::Array[String])
    }
    def self.finish_first(verb, blocked, named:, flags:, run:, merged: false)
      command = finish_run(run, blocked.values.flatten)
      them = (blocked.length == 1) ? "it" : "them"
      casks = "#{verb} #{them} with `#{cask_command(verb, blocked.keys, named:, flags:)}`."
      finish = if command.nil?
        "Once those are installed, #{casks}"
      elsif merged
        "The commands above finish those, then #{verb} #{them}."
      else
        "Finish those first with `#{command}`, then #{casks}"
      end
      [*blocked.map { |cask, needed| "#{cask.full_name}: needs #{needed.join(", ")}" }, finish]
    end
    private_class_method :finish_first

    # The `run`'s command for the formulae given to it that are among `left`
    # (full names) or bring one in (see `finish_run`), followed, on its own
    # line, by the command for those of `casks` to run after the formulae
    # that need one of `left` or what brew installs for them
    # (`run_dependencies`), as `last_casks` leaves those out; nil without
    # such a formula. `last_casks` given `merged` then points to it.
    sig {
      params(verb: String, run: Run, left: T::Array[String], casks: T::Array[Cask::Cask], named: T::Array[String],
             flags: T::Array[String], run_dependencies: T::Hash[String, T::Array[String]]).returns(T.nilable(String))
    }
    def self.finish_command(verb, run, left, casks:, named:, flags:, run_dependencies:)
      command = finish_run(run, left)
      return if command.nil?

      blocked = blocked_casks(casks, left | left.flat_map { |name| run_dependencies.fetch(name, []) })
      return command if blocked.empty?

      "#{command}\n  #{cask_command(verb, blocked.keys, named:, flags:)}"
    end

    # The `run`'s command for the formulae given to it that are among
    # `missing` (full names) or bring one in, or nil if none do.
    sig { params(run: Run, missing: T::Array[String]).returns(T.nilable(String)) }
    def self.finish_run(run, missing)
      roots = run.roots.select { |name, _| [name, *run.needs.fetch(name, [])].intersect?(missing) }.values
      shell_command(["brew", *run.command, *roots]) if roots.any?
    end

    # The arguments for the `casks` to run after the formulae, as
    # `cask_arguments` names them for the `named` arguments, leaving out, with
    # one warning (see `finish_first`), those that need one of the
    # `unfinished` formulae (by full name) brew didn't install that isn't
    # installed either (see `blocked_casks`), e.g. a formula whose source
    # build failed, which brew's cask installer would pour. What brew
    # installs for an unfinished formula (`run_dependencies`, as for
    # `cask_plan`) counts as unfinished too, as its call may have failed at
    # one of those. With `merged`, the run's error already gave the commands
    # that finish those formulae, then the casks (see `finish_command`), so
    # the warning points to them.
    sig {
      params(verb: String, casks: T::Array[Cask::Cask], named: T::Array[String], flags: T::Array[String],
             unfinished: T::Array[String], run: Run, run_dependencies: T::Hash[String, T::Array[String]],
             merged: T::Boolean).returns(T::Array[String])
    }
    def self.last_casks(verb, casks, named:, flags:, unfinished:, run:, run_dependencies: {}, merged: false)
      unfinished |= unfinished.flat_map { |name| run_dependencies.fetch(name, []) }
      blocked = blocked_casks(casks, unfinished)
      if blocked.any?
        opoo <<~EOS
          Not #{verb.delete_suffix("e")}ing #{Utils.pluralize("cask", blocked.length, include_count: true)}, which #{(blocked.length == 1) ? "needs" : "need"} formulae that didn't #{verb} and aren't installed:
          #{finish_first(verb, blocked, named:, flags:, run:, merged:).join("\n")}
        EOS
      end
      cask_arguments(named, casks - blocked.keys)
    end

    # How to run `casks` later, with the cask `flags` their call was given
    # (see `cask_command`).
    sig { params(verb: String, casks: T::Array[Cask::Cask], named: T::Array[String], flags: T::Array[String]).returns(String) }
    def self.later(verb, casks, named:, flags:)
      "#{verb.capitalize} #{(casks.length == 1) ? "it" : "them"} later with " \
        "`#{cask_command(verb, casks, named:, flags:)}`."
    end

    # The command that runs `casks` with the cask `flags` their call was
    # given, naming each as `cask_arguments` does for the `named` arguments,
    # each argument escaped for the shell.
    sig { params(verb: String, casks: T::Array[Cask::Cask], named: T::Array[String], flags: T::Array[String]).returns(String) }
    def self.cask_command(verb, casks, named:, flags:)
      shell_command(["brew", verb, "--cask", *flags, *cask_arguments(named, casks)])
    end
    private_class_method :cask_command

    # The argument that names each of `casks` in a sub-call: the file it was
    # loaded from if `names` gave it as a path, as `named_argv` makes it,
    # otherwise its full name.
    sig { params(names: T::Array[String], casks: T::Array[Cask::Cask]).returns(T::Array[String]) }
    def self.cask_arguments(names, casks)
      paths = named_argv(names)
      casks.map { |cask| paths.find { |path| path == cask.sourcefile_path.to_s } || cask.full_name }
    end

    sig { params(option: String).returns(String) }
    def self.option_name(option) = Homebrew::CLI::Parser.option_to_name(option.split("=", 2).fetch(0))
    private_class_method :option_name
  end
end
