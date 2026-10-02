# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "cask/cask_loader"
require "cask/download"
require "formulary"
require "shellwords"
require "trust"
require "unpack_strategy"
require "utils/output"
require_relative "build_log"
require_relative "casks"
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
      parser.comma_array "--exclude",
                         description: "Comma-separated formulae to leave out of the run. Homebrew may still " \
                                      "install or upgrade them as dependencies of the others."
      parser.switch "--no-stamp-receipts",
                    description: "Don't add the build times to the install receipts of the formulae it installs; " \
                                 "they are still logged.",
                    env:         :timed_no_stamp_receipts
      (last ? PLAN_FLAGS : PLAN_FLAGS - ["last"]).each { |name| parser.conflicts "--cask", "--#{name}" }
    end

    PLAN_FLAGS = %w[guess estimator last exclude].freeze
    OWN_FLAGS = T.let([*PLAN_FLAGS, "no_stamp_receipts"].freeze, T::Array[String])

    # Handled by the `-timed` command itself, once for the whole run.
    ASK_FLAGS = %w[ask no_ask dry_run].freeze

    # Each sub-call names its own kind.
    KIND_FLAGS = %w[formula formulae cask casks].freeze

    # The wrapped command's flags to pass on: all of them in `preview`, for the
    # one `--dry-run` sub-call; common and formula flags in `formula`, common
    # and cask flags in `cask`, for the sub-calls that each add their kind.
    class Forwarded < T::Struct
      const :preview, T::Array[String]
      const :formula, T::Array[String]
      const :cask, T::Array[String]
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
      Forwarded.new(
        preview:,
        formula: split.reject { |option| cask_only.intersect?(names.call(option)) },
        cask:    split.reject { |option| formula_only.intersect?(names.call(option)) },
      )
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

    # The full names of the formulae `formula` needs, to run those first:
    # brew's expansion, which names each by its formula's full name and
    # leaves out optional and recommended dependencies the formula isn't
    # built with, also leaving out those that can't be loaded (and what only
    # they need).
    sig { params(formula: Formula).returns(T::Array[String]) }
    def self.dependency_names(formula)
      formula.recursive_dependencies do |dependent, dependency|
        dependency.to_formula
        Dependency.action(dependent, dependency)
      rescue FormulaUnavailableError
        Dependable::PRUNE
      end.map(&:name)
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
      # No history of this kind of build and no `--guess`.
      const :fallback, T::Boolean
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
      Estimate.new(seconds:, pour:, fallback: !history && guess.nil?)
    end

    # Prints the batches with their estimates, why each starts where it does,
    # and the planner's warnings. Estimates ending in `?` are fallbacks, as in
    # `brew build-times stats`. With `dependencies_only` (`brew install
    # --only-dependencies`), each row is the dependencies of a formula, which
    # have no estimates yet. Without batches, it says so only if the run has no
    # `casks` (named, planned or `--cask`), whose lists say what it does.
    sig {
      params(verb: String, result: Planner::Result, estimates: T::Hash[String, Estimate], excluded: T::Array[String],
             dependencies_only: T::Boolean, casks: T::Boolean).void
    }
    def self.show_plan(verb, result, estimates, excluded:, dependencies_only: false, casks: false)
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
          ohai "Batch #{index} of #{batches.length}#{" (--last)" if batch.label == "last"}" \
               "#{": #{time}" if time}#{", #{reason}" if reason}"
          batch.names.each do |name|
            next puts "dependencies of #{name}" if dependencies_only

            estimate = estimates.fetch(name)
            puts format("%<name>-28s %<kind>-5s %<estimate>9s", name:, kind: estimate.pour ? "pour" : "build",
                        estimate: "#{BuildLog.format_duration(estimate.seconds)}#{"?" if estimate.fallback}")
          end
        end
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
    # run, by full name; the casks are in it too. Each cask counts what brew
    # may install before it that is in the run (see `cask_needs` and
    # `Needs#among`), handed to `Casks.plan` by full name, and what installing
    # its missing cask
    # dependencies needs, unless `skip_cask_deps` (`--skip-cask-deps`), with
    # which brew installs only formula dependencies, those of skipped casks
    # included. `zap` and `force` are the wrapped command's.
    sig {
      params(casks: T::Hash[Symbol, T::Array[Cask::Cask]], in_run: T::Array[String], zap: T::Boolean,
             force: T::Boolean, skip_cask_deps: T::Boolean, facts: Casks::Facts, tty: T.proc.returns(T::Boolean))
        .returns(Casks::Plan)
    }
    def self.cask_plan(casks, in_run:, zap: false, force: false, skip_cask_deps: false, facts: Casks::DiskFacts.new,
                       tty: -> { Casks.terminal? })
      in_run += casks.values.flatten.map(&:full_name)
      plans = casks.map do |verb, list|
        installed = list.filter_map do |cask|
          installed_cask(cask, reinstall: verb == :reinstall)&.then { |old| [cask.token, old] }
        end.to_h
        all_needs = list.to_h { |cask| [cask.token, cask_needs(cask)] }
        needs = all_needs.transform_values { |needed| needed.among(in_run, casks: !skip_cask_deps) }
        missing = all_needs.transform_values { |needed| skip_cask_deps ? [] : needed.casks.reject(&:installed?) }
        Casks.plan(list, verb:, in_run:, facts:, tty:, installed:, zap:, force:, needs:, missing:)
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
      const :unresolved, T::Array[String], default: []

      # Those of `names` (full names, e.g. of formulae in the run) this needs:
      # by full name, or, for what can't be loaded, by name alone, which may
      # match another tap's formula of that name, to be safe. Only formulae
      # without `casks`.
      sig { params(names: T::Array[String], casks: T::Boolean).returns(T::Array[String]) }
      def among(names, casks: true)
        full = formulae + (casks ? self.casks.map(&:full_name) : [])
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
      unresolved = T.let([], T::Array[String])
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
            unresolved << name unless unresolved.include?(name)
          end
        else
          begin
            dependency = Cask::CaskLoader.load(name, warn: false)
          rescue Cask::CaskError, Homebrew::UntrustedTapError
            unresolved << name unless unresolved.include?(name)
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
      Needs.new(formulae:, casks:, unresolved:)
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

    # The arguments for the `casks` to run after the formulae, as
    # `cask_arguments` names them for the `named` arguments, leaving out, with
    # one warning (see `later`), those that need (see `cask_needs`) one of the
    # `unfinished` formulae (by full name) brew didn't install that isn't
    # installed and linked into `opt` either: brew's cask installer would
    # install it for them, without the formula options given for it, e.g.
    # pour a bottle of a formula whose source build failed. One left installed
    # (e.g. by a failed upgrade) brew leaves alone.
    sig {
      params(verb: String, casks: T::Array[Cask::Cask], named: T::Array[String], flags: T::Array[String],
             unfinished: T::Array[String]).returns(T::Array[String])
    }
    def self.last_casks(verb, casks, named:, flags:, unfinished:)
      # Loaded by full name, so another tap's formula of the same name isn't.
      missing = lambda do |name|
        formula = Formulary.factory(name)
        !(formula.any_version_installed? && formula.optlinked?)
      rescue FormulaUnavailableError, Homebrew::UntrustedTapError
        true
      end
      needs = casks.to_h do |cask|
        # Brew installs formula dependencies even with `--skip-cask-deps`.
        [cask, cask_needs(cask).among(unfinished, casks: false).select { |name| missing.call(name) }]
      end
      blocked = needs.select { |_, needed| needed.any? }
      if blocked.any?
        opoo <<~EOS
          Not #{verb.delete_suffix("e")}ing #{Utils.pluralize("cask", blocked.length, include_count: true)}, which #{(blocked.length == 1) ? "needs" : "need"} formulae that didn't #{verb} and aren't installed:
          #{blocked.map { |cask, needed| "#{cask.full_name}: needs #{needed.join(", ")}" }.join("\n")}
          #{later(verb, blocked.keys, named:, flags:)}
        EOS
      end
      cask_arguments(named, casks - blocked.keys)
    end

    # How to run `casks` later, with the cask `flags` their call was given,
    # naming each as `cask_arguments` does for the `named` arguments, each
    # argument escaped for the shell.
    sig { params(verb: String, casks: T::Array[Cask::Cask], named: T::Array[String], flags: T::Array[String]).returns(String) }
    def self.later(verb, casks, named:, flags:)
      command = Shellwords.join(["brew", verb, "--cask", *flags, *cask_arguments(named, casks)])
      "#{verb.capitalize} #{(casks.length == 1) ? "it" : "them"} later with `#{command}`."
    end

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
