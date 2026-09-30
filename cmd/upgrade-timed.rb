# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "ask"
require "cmd/upgrade"
require "formula_installer"
require "install"
require "minimum_version"
require "trust"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/command"
require_relative "../lib/timed/planner"

module Homebrew
  module Cmd
    class UpgradeTimed < AbstractCommand
      cmd_args do
        instance_exec(&Timed::Command.parser_block(Timed::Command.builtin("upgrade")))
        description <<~EOS
          Upgrade outdated, unpinned formulae like `brew upgrade`, in timed batches: dependencies first,
          then the quickest, so quick upgrades finish early and slow builds never hold them up.
          Estimates come from the log shown by `brew build-times`.

          Takes every `brew upgrade` option. Prints the plan from `brew upgrade --dry-run` and the
          batches with their estimates, then asks for confirmation once for the whole run, as
          `brew upgrade` does. With `--dry-run`, stops after printing the plan.
        EOS
        Timed::Command.define_flags(self)
      end

      sig { override.params(argv: T::Array[String]).void }
      def initialize(argv = ARGV.freeze)
        super
        @argv = T.let(argv.dup, T::Array[String])
      end

      sig { override.void }
      def run
        # The checks `brew upgrade` makes before doing anything.
        if args.build_from_source? && args.named.empty?
          raise ArgumentError, "`--build-from-source` requires at least one formula"
        end
        raise UsageError, "`--minimum-version` requires exactly one formula or cask argument." if
          minimum_version.present? && args.named.length != 1

        estimator = Timed::Command.estimator(args.estimator)
        Timed::Command.auto_update(command: self.class.command_name, argv: @argv)

        named = named_formulae
        guesses = Timed::Command.guesses(args.guess || [], resolve: ->(name) { resolve("--guess", name) })
        last = (args.last || []).map { |name| resolve("--last", name) }
        exclude = (args.exclude || []).map { |name| resolve("--exclude", name) }

        candidates = if args.cask?
          []
        elsif args.named.present?
          named
        else
          Formula.installed
        end
        # As `brew upgrade` does, unpinned outdated formulae installed through
        # an alias whose target has changed are upgraded to the new target.
        roots = candidates.select { |formula| outdated?(formula) }.reject(&:pinned?).map do |formula|
          latest = formula.latest_formula
          latest.latest_version_installed? ? formula : latest
        end
        needs = dependencies(roots)
        formulae = needs.values.flatten.concat(roots).to_h { |formula| [formula.full_name, formula] }
        set = needs.keys
        log = Timed::BuildLog.load(Timed::BuildLog.default_path)
        estimates = set.to_h do |name|
          pour = installer(formulae.fetch(name)).pour_bottle?
          [name, Timed::Command.estimate(log, name, pour:, estimator:, guesses:)]
        end
        result = Timed::Planner.plan(
          verb:      :upgrade,
          names:     set,
          deps:      needs.transform_values { |dependencies| dependencies.map(&:full_name) },
          estimates: estimates.transform_values(&:seconds),
          keg_only:  set.select { |name| formulae.fetch(name).keg_only? },
          last:,
          exclude:,
        )

        # Brew's own plan, which also reports named formulae it won't upgrade.
        forwarded = Timed::Command.forward(args.options_only, conflicts: self.class.parser.conflicts)
        preview = ["upgrade", "--dry-run", *forwarded.preview, *Timed::Command.named_argv(args.named)]
        Homebrew.failed = true unless Timed::Command.brew({}, preview)
        Timed::Command.show_plan("upgrade", result, estimates, excluded: set & exclude)
        planned = result.batches.flat_map(&:names)
        return if args.dry_run? || planned.empty?

        # Once for the whole run, by brew's rules: with named formulae, only if
        # the plan has others than the names as given, or brew would install
        # dependencies of the named ones it plans, or upgrade dependents of
        # any of them (brew checks those before refusing any).
        upgrading = roots.select { |formula| needs.key?(formula.full_name) }
        force = args.named.present? &&
                (upgrading.any? { |formula| needs.fetch(formula.full_name).any? } || outdated_dependents?(roots))
        ask = !args.no_ask? && Install.ask_prompt_needed?(
          planned_names: planned, requested_names: args.named, force:, named: args.named.present?,
        )
        # Exits on "n"; returns false without a terminal, where brew carries on
        # unasked.
        Homebrew::Ask.confirm?(action: "upgrade") if ask
        odie "Running the batches is not implemented yet."
      end

      private

      sig { returns(T.nilable(String)) }
      def minimum_version = args.minimum_version || args.min_version

      # The named formulae. Brew's preview reports unavailable names, and
      # named casks are left to it.
      sig { returns(T::Array[Formula]) }
      def named_formulae
        return [] if args.named.empty?

        Homebrew::Trust.trust_fully_qualified_items!(args.named, type: args.only_formula_or_cask)
        args.named.to_formulae_and_casks_and_unavailable(method: :resolve).grep(Formula)
      end

      # The full name of the formula `name` given to `flag`.
      sig { params(flag: String, name: String).returns(String) }
      def resolve(flag, name)
        Formulary.factory(name).full_name
      rescue FormulaUnavailableError => e
        raise UsageError, "`#{flag}`: #{e}"
      end

      # What brew would install or upgrade before each formula it upgrades,
      # by full name, from the unpinned `roots` on: brew's own expansion, so build
      # dependencies only count for formulae built from source that aren't
      # current. Outdated dependencies, other than pinned ones, get their own
      # entry, so the keys are the formulae to upgrade. Formulae brew would
      # refuse or fail (e.g. needing a newer pinned dependency or one that
      # can't be loaded) are left out, for its preview to report; brew carries
      # on with the rest.
      sig { params(roots: T::Array[Formula]).returns(T::Hash[String, T::Array[Formula]]) }
      def dependencies(roots)
        needs = T.let({}, T::Hash[String, T::Array[Formula]])
        queue = roots.reject do |root|
          installer(root).check_install_sanity
          false
        rescue CannotInstallFormulaError, FormulaUnavailableError
          true
        end
        while (formula = queue.shift)
          next if needs.key?(formula.full_name)

          dependencies = begin
            installer(formula).expand_dependencies.map(&:to_formula)
          rescue FormulaUnavailableError
            next
          end
          needs[formula.full_name] = dependencies
          queue.concat(dependencies.select { |dependency| dependency.outdated? && !dependency.pinned? })
        end
        needs
      end

      # `brew upgrade`'s check for the formulae it was given, or all installed
      # ones.
      sig { params(formula: Formula).returns(T::Boolean) }
      def outdated?(formula)
        outdated = formula.outdated?(fetch_head: args.fetch_HEAD?)
        return false if outdated && fetched_head_current?(formula)

        version = minimum_version
        return outdated if version.blank?

        outdated && MinimumVersion.formula_outdated_kegs(formula, version, fetch_head: args.fetch_HEAD?).present?
      end

      # Whether `--fetch-HEAD` found the installed HEAD to be upstream's.
      sig { params(formula: Formula).returns(T::Boolean) }
      def fetched_head_current?(formula)
        return false if !args.fetch_HEAD? || !formula.head? || !formula.optlinked?

        old_version = Keg.new(formula.opt_prefix).version
        return false unless old_version.head?

        formula.latest_head_pkg_version(fetch_head: true).to_s == old_version.to_s
      end

      # Whether brew would also upgrade outdated dependents of `formulae`
      # (the installed dependents check), which makes `brew upgrade` ask.
      sig { params(formulae: T::Array[Formula]).returns(T::Boolean) }
      def outdated_dependents?(formulae)
        # Brew's check warns that it's off, as the preview already has.
        return false if Homebrew::EnvConfig.no_installed_dependents_check?

        Upgrade.dependants(
          formulae,
          flags:                      args.flags_only,
          dry_run:                    true,
          ask:                        true,
          force_bottle:               args.force_bottle?,
          build_from_source_formulae: args.build_from_source_formulae,
          interactive:                args.interactive?,
          keep_tmp:                   args.keep_tmp?,
          debug_symbols:              args.debug_symbols?,
          force:                      args.force?,
          debug:                      args.debug?,
          quiet:                      args.quiet?,
          verbose:                    args.verbose?,
        ).upgradeable.present?
      end

      # The installer `brew upgrade` would use, with the options it would use.
      # For a pour, it has read the bottle's manifest first, as brew does: the
      # minimum dependency versions there can leave an outdated dependency
      # alone. If the manifest can't be downloaded, brew (and so this) takes
      # every outdated dependency as needed.
      sig { params(formula: Formula).returns(FormulaInstaller) }
      def installer(formula)
        @installers ||= T.let({}, T.nilable(T::Hash[String, FormulaInstaller]))
        @installers[formula.full_name] ||= begin
          options = BuildOptions.new(Options.create(args.flags_only), formula.options).used_options
          options |= formula.build.used_options
          installer = FormulaInstaller.new(
            formula,
            options:                    options & formula.options,
            build_bottle:               formula.any_installed_keg&.tab&.built_bottle? || false,
            force_bottle:               args.force_bottle?,
            build_from_source_formulae: args.build_from_source_formulae,
            interactive:                args.interactive?,
          )
          if installer.pour_bottle?
            # One at a time, as dependencies turn up while expanding; brew
            # queues the manifests of the formulae it was given and fetches
            # those in parallel.
            installer.fetch_bottle_tab(quiet: true)
            installer.determine_bottle_tab_attributes
          end
          installer
        end
      end
    end
  end
end
