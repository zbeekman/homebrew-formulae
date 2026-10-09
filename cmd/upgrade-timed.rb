# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "ask"
require "cask/caskroom"
require "cmd/upgrade"
require "formula_installer"
require "install"
require "minimum_version"
require "trust"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/command"
require_relative "../lib/timed/estimates_table"
require_relative "../lib/timed/planner"
require_relative "../lib/timed/runner"

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
          `brew upgrade` does. With `--dry-run`, stops after printing the plan. Otherwise runs
          `brew upgrade` for each batch and logs how long each formula took. Upgrades outdated casks with
          `brew upgrade --cask` before the batches, or after them if they may prompt or need the run.
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
        raise UsageError, "`--interactive` needs a terminal; use `brew upgrade --interactive` instead." if
          args.interactive?

        estimator = Timed::Command.estimator(args.estimator)
        llm = Timed::Command.llm_settings(args)
        Timed::Command.auto_update(command: self.class.command_name, argv: @argv)

        items = named_items
        named = items.grep(Formula)
        guesses = Timed::Command.guesses(args.guess || [],
                                         resolve: ->(name) { Timed::Command.resolve("--guess", name) })
        last = (args.last || []).map { |name| Timed::Command.resolve("--last", name) }
        exclude = (args.exclude || []).map { |name| Timed::Command.resolve("--exclude", name) }

        candidates = if args.cask?
          []
        elsif args.named.present?
          named
        else
          Formula.installed
        end
        # As `brew upgrade` does, unpinned outdated formulae installed through
        # an alias whose target has changed are upgraded to the new target.
        upgradeable = candidates.select { |formula| outdated?(formula) }.reject(&:pinned?)
        roots = upgradeable.map do |formula|
          latest = formula.latest_formula
          latest.latest_version_installed? ? formula : latest
        end
        needs = dependencies(roots)
        deps = needs.transform_values { |dependencies| dependencies.map(&:full_name) }
        formulae = needs.values.flatten.concat(roots).to_h { |formula| [formula.full_name, formula] }
        set = needs.keys
        estimates = Timed::Command.estimates(set.to_h { |name| [name, formulae.fetch(name)] },
                                             pour: ->(formula) { installer(formula).pour_bottle? },
                                             estimator:, guesses:, llm:, exclude:)
        result = Timed::Planner.plan(
          verb:      :upgrade,
          names:     set,
          deps:,
          estimates: estimates.transform_values(&:seconds),
          keg_only:  set.select { |name| formulae.fetch(name).keg_only? },
          last:,
          exclude:,
        )

        # Brew's own plan, which also reports named formulae and casks it won't
        # upgrade.
        forwarded = Timed::Command.forward(Timed::Command.options(args, self.class.parser),
                                           conflicts: self.class.parser.conflicts)
        preview_argv = ["upgrade", "--dry-run", *forwarded.preview, *Timed::Command.named_argv(args.named)]
        preview = T.let([], T::Array[String])
        Homebrew.failed = true unless Timed::Runner.stream(preview_argv) { |line| preview << line }
        excluded = set & exclude
        named_casks = items.grep(Cask::Cask)
        outdated = outdated_casks(named_casks)
        any_casks = args.cask? || named_casks.any? || outdated.any?
        planned = result.batches.flat_map(&:names)
        # Brew's installed-dependents check of the formulae it upgrades (and
        # refuses, unless it refuses them all), not of their dependencies. The
        # outdated dependents it finds that the batches don't upgrade are
        # upgraded after them.
        checked = planned.empty? ? [] : roots.reject { |formula| exclude.include?(formula.full_name) }
        dependants = dependants(checked)
        dependents = dependants.upgradeable.reject { |formula| (planned + exclude).include?(formula.full_name) }
        Timed::Command.show_plan("upgrade", result, estimates, excluded:, casks: any_casks,
                                                               dependents: dependents.map(&:full_name))
        # Without names, brew's preview lists every formula and cask it would
        # upgrade, casks by token.
        if args.named.empty?
          listed = Timed::Runner.would_upgrade(preview)
          left_out = ((listed - Cask::Caskroom.tokens) & candidates.map(&:full_name)) - planned - excluded
          opoo "The batches leave out #{left_out.join(", ")}, which `brew upgrade` would upgrade." if left_out.any?
          extra = planned - listed
          opoo "The batches include #{extra.join(", ")}, which `brew upgrade` wouldn't upgrade." if extra.any?
        end
        # `brew upgrade` takes `--minimum-version` with one name only, which
        # planning has already applied to. Brew's parser names it
        # `--minimum-version` in `options_only` either way, but both of its
        # spellings are left out, to be safe.
        without_minimum_version = lambda do |options|
          options.reject { |option| option.start_with?("--minimum-version=", "--min-version=") }
        end
        flags = without_minimum_version.call(forwarded.formula)
        cask_flags = without_minimum_version.call(forwarded.cask)
        # What brew installs or upgrades in each formula's call.
        run_dependencies = deps.slice(*planned)
        cask_plan = Timed::Command.cask_plan({ upgrade: outdated }, in_run: planned, run_dependencies:,
                                                                    skip_cask_deps: args.skip_cask_deps?)
        Timed::Command.show_casks("upgrade", cask_plan, named: args.named, flags: cask_flags)
        casks = (cask_plan.first + cask_plan.last).map(&:cask)
        return if args.dry_run? || (planned.empty? && casks.empty?)

        # Once for the whole run, by brew's rules: with named arguments, only
        # if the plan has others than the names as given, or brew would install
        # dependencies of the named formulae it plans, or upgrade dependents of
        # any of them (brew checks those before refusing any).
        upgrading = roots.select { |formula| needs.key?(formula.full_name) }
        force = args.named.present? &&
                (upgrading.any? { |formula| needs.fetch(formula.full_name).any? } || dependants.upgradeable.present?)
        ask = !args.no_ask? && Install.ask_prompt_needed?(
          planned_names: planned + casks.map(&:full_name), requested_names: args.named, force:,
          named: args.named.present?
        )
        # Exits on "n"; returns false without a terminal, where brew carries on
        # unasked.
        Homebrew::Ask.confirm?(action: "upgrade") if ask

        Timed::Runner.run_casks("upgrade", Timed::Command.cask_arguments(args.named, cask_plan.first.map(&:cask)),
                                flags: cask_flags, label: "first")
        last = cask_plan.last.map(&:cask)
        arguments = Timed::Command.path_arguments(args.named, formulae)
        # To finish them, the formulae given (all the outdated ones with no
        # names), not the outdated dependencies the batches add, each named as
        # given: by the alias's new target, it wouldn't be upgraded.
        given = roots.each_with_index.filter_map do |root, index|
          next unless planned.include?(root.full_name)

          formula = upgradeable.fetch(index)
          [root.full_name, arguments.fetch(formula.full_name, formula.full_name)]
        end.to_h
        run = Timed::Command::Run.new(command: [self.class.command_name, *flags, *forwarded.own], roots: given,
                                      needs:   deps.slice(*given.keys))
        outcome = if result.batches.any?
          # `brew upgrade` builds only the named formulae from source with
          # `--build-from-source`, but gives `--debug-symbols` to every build
          # in a call; formulae planned as pours go in a call without either.
          pour_flags = (flags - %w[--build-from-source --debug-symbols] if args.build_from_source?)
          # The outdated dependents and broken linkage are seen to before the
          # last casks, which may need them.
          after = -> { Timed::Command.after(dependents, checked, args:, flags:, excluded: exclude, own: forwarded.own) }
          Timed::Command.before_last_casks("upgrade", last, named: args.named, flags: cask_flags, run:,
                                                            after:) do |calls|
            Timed::Runner.run(result.batches, verb: "upgrade", flags:, formulae:, deps:,
                                              pours: set.select { |name| estimates.fetch(name).pour }, pour_flags:,
                                              stamp: !args.no_stamp_receipts?, apart: true, arguments:, after: calls)
          end
        end
        last = Timed::Command.last_casks("upgrade", last, named: args.named, flags: cask_flags,
                                                          unfinished: outcome&.unfinished || [], run:,
                                                          run_dependencies:)
        Timed::Runner.run_casks("upgrade", last, flags: cask_flags, label: "last")
        Timed::EstimatesTable.show(planned, estimates, outcome.durations) if outcome
      end

      private

      sig { returns(T.nilable(String)) }
      def minimum_version = args.minimum_version || args.min_version

      # The named formulae and casks. Brew's preview reports unavailable names.
      sig { returns(T::Array[T.any(Formula, Cask::Cask)]) }
      def named_items
        return [] if args.named.empty?

        Homebrew::Trust.trust_fully_qualified_items!(args.named, type: args.only_formula_or_cask)
        items = args.named.to_formulae_and_casks_and_unavailable(method: :resolve)
        items.grep(Formula) + items.grep(Cask::Cask)
      end

      # The casks `brew upgrade` would upgrade, as it works them out: the
      # `named` ones, or every installed one with no names, unless only
      # formulae are named or with `--formula`; not pinned, not below
      # `--minimum-version` or `installer manual`. Brew's preview reports those
      # it won't upgrade.
      sig { params(named: T::Array[Cask::Cask]).returns(T::Array[Cask::Cask]) }
      def outdated_casks(named)
        return [] if args.formula? || (args.named.present? && named.empty?)

        version = minimum_version
        named = named.select { |cask| MinimumVersion.cask_installed_below?(cask, version) } if version.present?
        # Brew reports pinned ones itself.
        named = named.reject(&:pinned?)
        return [] if args.named.present? && named.empty?

        outdated = Cask::Upgrade.outdated_casks(named, args:, force: args.force?, quiet: true, greedy: args.greedy?,
                                                       greedy_latest:       args.greedy_latest?,
                                                       greedy_auto_updates: args.greedy_auto_updates?)
        outdated.reject do |cask|
          cask.artifacts.any? { |artifact| artifact.is_a?(Cask::Artifact::Installer) && artifact.manual_install }
        end
      rescue Cask::CaskError
        # E.g. a named cask that isn't installed.
        []
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

      # The outdated dependents of `formulae` brew would also upgrade (the
      # installed-dependents check), which make `brew upgrade` ask.
      sig { params(formulae: T::Array[Formula]).returns(Upgrade::Dependents) }
      def dependants(formulae)
        # Brew's check warns that it's off, as the preview already has. With
        # nothing to check, brew never works out its options, which
        # `--build-from-source` with a named cask can't.
        if Homebrew::EnvConfig.no_installed_dependents_check? || formulae.empty?
          return Upgrade::Dependents.new(upgradeable: [], pinned: [], skipped: [])
        end

        Upgrade.dependants(formulae, flags: args.flags_only, dry_run: true, ask: true,
                                     **Timed::Command.installer_options(args))
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
