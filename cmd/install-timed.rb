# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "ask"
require "cask/upgrade"
require "cmd/install"
require "development_tools"
require "diagnostic"
require "download_queue"
require "formula_installer"
require "install"
require "trust"
require "upgrade"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/command"
require_relative "../lib/timed/planner"
require_relative "../lib/timed/receipts"
require_relative "../lib/timed/runner"

module Homebrew
  module Cmd
    class InstallTimed < AbstractCommand
      cmd_args do
        instance_exec(&Timed::Command.parser_block(Timed::Command.builtin("install")))
        description <<~EOS
          Install formulae like `brew install`, in timed batches: dependencies first, then pours, then the
          quickest builds, so quick installs finish early and slow builds never hold them up.
          Estimates come from the log shown by `brew build-times`.

          Takes every `brew install` option. Prints what `brew install` would install, as `brew install --dry-run`
          does, and the batches with their estimates, then asks for confirmation once for the whole run, as
          `brew install` does. With `--dry-run`, stops after printing the plan. Otherwise runs
          `brew install` for each batch and logs how long each formula took. The dependencies it would install
          or upgrade get batches of their own, run with `brew install --as-dependency` or `brew upgrade`.
          Installs casks with
          `brew install --cask` before the batches, or after them if they may prompt or need the run.
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
        raise UsageError, "`--interactive` needs a terminal; use `brew install --interactive` instead." if
          args.interactive?

        estimator = Timed::Command.estimator(args.estimator)
        llm = Timed::Command.llm_settings(args)
        Timed::Command.auto_update(command: self.class.command_name, argv: @argv)

        # As `brew install` does, which has disabled it.
        odisabled "`brew install --env`", "`env :std` in specific formula files" if args.env.present?

        # As `brew install` does, even with `--dry-run`.
        args.named.each do |name|
          (Tap.with_formula_name(name) || Tap.with_cask_token(name))&.first&.ensure_installed!
        end
        Homebrew::Trust.trust_fully_qualified_items!(args.named, type: args.only_formula_or_cask)
        # As `brew install` warns, with its text.
        if args.ignore_dependencies?
          opoo <<~EOS
            #{Tty.bold}`--ignore-dependencies` is an unsupported Homebrew developer option!#{Tty.reset}
            Adjust your PATH to put any preferred versions of applications earlier in the
            PATH rather than using this unsupported option!

          EOS
        end
        # Brew loads every name before it installs anything, so an unknown one
        # stops it.
        items = args.named.to_formulae_and_casks(warn: false)
        casks = items.grep(Cask::Cask)
        new_casks = casks.reject(&:installed?)
        # As `brew install` does, it upgrades the installed, outdated ones,
        # reporting those it won't upgrade as it runs, pinned ones included.
        unpinned = casks.reject(&:pinned?)
        upgrading = if unpinned.empty? || Homebrew::EnvConfig.no_install_upgrade?
          []
        else
          Cask::Upgrade.outdated_casks(unpinned, args:, force: true, quiet: true)
        end
        # What `brew install --dry-run` prints about the casks, and `brew
        # install` before it asks about them: the dependencies it would install.
        cask_dependencies = Install.print_dry_run_casks(args.dry_run? ? casks : new_casks | upgrading,
                                                        skip_cask_deps:    args.skip_cask_deps?,
                                                        include_installed: !args.dry_run?)

        guesses = Timed::Command.guesses(args.guess || [],
                                         resolve: ->(name) { Timed::Command.resolve("--guess", name) })
        last = (args.last || []).map { |name| Timed::Command.resolve("--last", name) }
        exclude = (args.exclude || []).map { |name| Timed::Command.resolve("--exclude", name) }

        named = items.grep(Formula)
        # Where `brew install` stops before it installs anything.
        unless DevelopmentTools.installed?
          build_flags = { "--HEAD" => args.HEAD?, "--build-bottle" => args.build_bottle?,
                          "--build-from-source" => args.build_from_source? }.select { |_, given| given }.keys
          raise BuildFlagsError.new(build_flags, bottled: named.all?(&:bottled?)) if build_flags.present?
        end
        # Brew's own check of each named formula, as `brew install` makes it:
        # it says why it won't install one, stops at some (e.g. a HEAD-only
        # formula without `--HEAD`), and marks an installed one as installed on
        # request, even with `--dry-run`. That rewrites its receipt without the
        # build times, which are put back as they were unless receipts are left
        # alone.
        build_times = if args.no_stamp_receipts?
          {}
        else
          named.to_h { |formula| [formula, Timed::Receipts.build_times(formula)] }.compact
        end
        begin
          selected = named.select do |formula|
            Install.install_formula?(formula, head: args.HEAD?, fetch_head: args.fetch_HEAD?,
                                              only_dependencies: args.only_dependencies?, force: args.force?,
                                              quiet: args.quiet?, skip_link: args.skip_link?,
                                              overwrite: args.overwrite?)
          end
        ensure
          # Whatever happens, as brew may be stopping the command.
          build_times.each do |formula, times|
            receipt = Timed::Receipts.receipt(formula)
            begin
              Timed::Receipts.stamp(receipt, times, exact: true) unless Timed::Receipts.build_times(formula)
            rescue => e
              opoo "Couldn't stamp #{receipt}: #{e}"
            end
          end
        end

        # What `brew install` does before it prints its plan (and, after it,
        # under `--yes`), in its order. The installers it would use say which
        # formulae it would migrate, as `brew install --dry-run` does. Its
        # first checks of each formula (deprecated, disabled, forbidden) fetch
        # the bottle manifests of pours, but no bottles.
        installers = Install.formula_installers(
          selected,
          installed_on_request:  !args.as_dependency?,
          build_bottle:          args.build_bottle?,
          bottle_arch:           args.bottle_arch,
          ignore_deps:           args.ignore_dependencies?,
          only_deps:             args.only_dependencies?,
          include_test_formulae: args.include_test_formulae,
          cc:                    args.cc,
          git:                   args.git?,
          overwrite:             args.overwrite?,
          skip_post_install:     args.skip_post_install?,
          skip_link:             args.skip_link?,
          dry_run:               true,
          **installer_options,
        )
        if installers.any?
          download_queue = Homebrew::DownloadQueue.new(pour: true)
          begin
            installers = Install.prelude_fetch_formulae(installers, download_queue:, metadata_only: true)
            Install.perform_preinstall_checks_once
            Install.check_cc_argv(args.cc)
            download_queue.fetch(only: Resource::BottleManifest, heading: "Downloading bottle manifests",
                                 allow_failures: true)
          ensure
            download_queue.shutdown
          end
        end
        # Then, as `brew install --yes` does, a formula it can't install (e.g.
        # one needing a dependency that can't be loaded or isn't supported here,
        # or a newer pinned one) is reported and left out, and the rest go on:
        # `FormulaInstaller#prelude`, without its downloads. Brew works out the
        # dependencies it prints and asks about before it reads the bottle
        # manifests, and those it installs after, so they are checked
        # (`verify_deps_exist`, which keeps them) first.
        installers = Install.select_formula_installers(installers, action: lambda do |installer|
          installer.verify_deps_exist unless installer.ignore_deps?
          installer.determine_bottle_tab_attributes
          installer.forbidden_license_check
          installer.forbidden_tap_check
          installer.forbidden_formula_check
          installer.check_install_sanity
        end).to_h { |installer| [installer.formula.full_name, installer] }
        # The dependencies brew would install or upgrade in the calls of the
        # named formulae get batches of their own. None with
        # `--ignore-dependencies` or `--only-dependencies`, nor with
        # `--build-bottle` or without the developer tools, where brew checks
        # that every dependency has a bottle before it installs any, nor with
        # `--debug-symbols`, which brew gives those it builds from source.
        dependencies = if args.ignore_dependencies? || args.only_dependencies? || args.build_bottle? ||
                          args.debug_symbols? || !DevelopmentTools.installed?
          {}
        else
          leave = named.map(&:full_name) + exclude
          installers.except(*exclude).transform_values { |installer| dependency_verbs(installer, leave:) }
        end
        scheduled = dependencies.values.flatten(1).to_h { |formula, own| [formula.full_name, [formula, own]] }
        verbs = scheduled.transform_values(&:last)
        formulae = installers.transform_values(&:formula).merge(scheduled.transform_values(&:first))
        set = formulae.keys
        # A formula whose latest version is installed now (e.g. with `--HEAD`
        # and that stable version unlinked, or `--overwrite`) will count as
        # installed only with a new receipt. One upgraded alongside an earlier
        # batch (as a dependency) isn't, so its own call may do nothing.
        current = formulae.select { |_, formula| formula.latest_version_installed? }
                          .transform_values { |formula| Timed::Receipts.receipt_stat(formula) }
        # A dependency's installer has the options brew would give it.
        all_installers = installers.merge(scheduled.transform_values do |formula, _|
          FormulaInstaller.new(formula, options: Tab.for_formula(formula).used_options & formula.options)
        end)
        # What brew would install for each (build dependencies only where it
        # builds), as it works it out, or where it can't, every dependency
        # that loads.
        deps = all_installers.transform_values do |installer|
          installer.expand_dependencies.map(&:name)
        rescue
          Timed::Command.dependency_names(installer.formula)
        end
        estimates = if args.only_dependencies?
          # What a formula needs has no estimate yet, so isn't slow.
          set.to_h { |name| [name, Timed::Command::Estimate.new(seconds: 0.0, pour: false, fallback: true)] }
        else
          pour = ->(formula) { all_installers.fetch(formula.full_name).pour_bottle? }
          Timed::Command.estimates(formulae, pour:, estimator:, guesses:, llm:, exclude:)
        end
        result = Timed::Planner.plan(verb: :install, names: set, deps:,
                                     estimates: estimates.transform_values(&:seconds),
                                     keg_only: formulae.select { |_, formula| formula.keg_only? }.keys,
                                     last:, exclude:, verbs:,
                                     pours: estimates.select { |_, estimate| estimate.pour }.keys)
        planned = result.batches.flat_map(&:names)
        # Each dependency is logged as one of the first named formula in the
        # batches that needs it, whose call brew would have installed it in.
        dependency_of = T.let({}, T::Hash[String, String])
        planned.each do |name|
          dependencies.fetch(name, []).map(&:first).each { |formula| dependency_of[formula.full_name] ||= name }
        end

        # What `brew install --dry-run` prints, and `brew install` before
        # asking, then the batches.
        planned_installers = planned.filter_map { |name| installers[name] }
        dependants = Upgrade.dependants(planned_installers.map(&:formula),
                                        flags:                args.flags_only,
                                        ask:                  !args.no_ask? && !args.dry_run?,
                                        installed_on_request: !args.as_dependency?,
                                        dry_run:              args.dry_run?,
                                        **installer_options)
        Install.ask_formulae(planned_installers, dependants, prompt: false, flags: args.flags_only,
                                                             **installer_options)
        # The outdated dependents brew's check finds are upgraded after the
        # batches, but never a named formula, as brew installs those itself
        # or not at all.
        left_out = set + named.map(&:full_name) + exclude
        dependents = dependants.upgradeable.reject { |formula| left_out.include?(formula.full_name) }
        Timed::Command.show_plan("install", result, estimates, excluded:          set & exclude,
                                                               dependencies_only: args.only_dependencies?,
                                                               casks:             args.cask? || casks.any?,
                                                               dependents:        dependents.map(&:full_name))
        forwarded = Timed::Command.forward(Timed::Command.options(args, self.class.parser),
                                           conflicts: self.class.parser.conflicts)
        run_dependencies = Timed::Command.run_dependencies(planned_installers)
        cask_plan = Timed::Command.cask_plan({ install: new_casks, upgrade: upgrading },
                                             in_run: planned, run_dependencies:, force: args.force?,
                                             skip_cask_deps: args.skip_cask_deps?)
        Timed::Command.show_casks("install", cask_plan, named: args.named, flags: forwarded.cask)
        # The installed casks brew won't upgrade, which it only reports on.
        first_casks = cask_plan.first.map(&:cask) + (casks - new_casks - upgrading)
        last_casks = cask_plan.last.map(&:cask)
        return if args.dry_run? || (planned.empty? && first_casks.empty? && last_casks.empty?)

        # Once for the whole run, by brew's rules: if brew would install or
        # upgrade dependencies of the formulae, or upgrade outdated dependents
        # of them, or install dependencies of the casks. Exits on "n"; returns
        # false without a terminal, where brew carries on unasked.
        cask_names = (new_casks | upgrading).map(&:full_name)
        if !args.no_ask? && (Install.formulae_ask_prompt_needed?(planned_installers, dependants) ||
           Install.ask_prompt_needed?(planned_names: cask_names + cask_dependencies, requested_names: cask_names))
          Homebrew::Ask.confirm?(action: "installation")
        end

        succeeded = lambda do |formula|
          # With `--only-dependencies`, brew installs what each formula needs,
          # as it would before the formula, not the formula itself (unless
          # another named formula needs it, when it is logged as installed).
          if args.only_dependencies?
            needed = installers.fetch(formula.full_name).compute_dependencies(use_cache: false).map(&:to_formula)
            return ->(_since) { needed.all?(&:latest_version_installed?) }
          end
          return ->(_since) { formula.latest_version_installed? } unless current.key?(formula.full_name)

          ->(since) { Timed::Receipts.installed_since?(formula, since, before: current.fetch(formula.full_name)) }
        end
        # Each batch's `brew install` notes the support tier of the run and
        # says it as it exits, so this command doesn't say it again.
        Homebrew::Diagnostic.support_tiers.clear
        Timed::Runner.run_casks("install", Timed::Command.cask_arguments(args.named, first_casks),
                                flags: forwarded.cask, label: "first")
        arguments = Timed::Command.path_arguments(args.named, formulae)
        run = Timed::Command::Run.new(command: [self.class.command_name, *forwarded.formula, *forwarded.own],
                                      roots:   planned_installers.to_h do |installer|
                                        name = installer.formula.full_name
                                        [name, arguments.fetch(name, name)]
                                      end,
                                      needs:   run_dependencies)
        outcome = if result.batches.any?
          # The outdated dependents and broken linkage are seen to before the
          # last casks, which may need them.
          after = lambda do
            Timed::Command.after(dependents, selected, args:, excluded: exclude, flags: forwarded.formula,
                                                       own: forwarded.own)
          end
          # The options brew gives the installers of the dependencies it
          # installs or upgrades for a formula, without the cleanup it gives
          # only the formulae it is given, which would remove their old
          # versions.
          dependency_flags = Timed::Command.dependent_flags(forwarded.formula) - ["--force-bottle"]
          no_cleanup = { "HOMEBREW_NO_INSTALL_CLEANUP" => "1" }
          dependency_calls = { dependency: ["install", ["--as-dependency", *dependency_flags], no_cleanup],
                               upgrade:    ["upgrade", dependency_flags, no_cleanup] }
          # One command finishes what the batches left, then the last casks
          # that need it; once the run gives it on Ctrl-C, the warning about
          # the last casks points to it.
          finish_given = T.let(false, T::Boolean)
          finish = lambda do |names|
            command = Timed::Command.finish_command("install", run, names, casks: last_casks, named: args.named,
                                                                           flags: forwarded.cask, run_dependencies:)
            finish_given ||= !command.nil?
            command
          end
          Timed::Command.before_last_casks("install", last_casks, named: args.named, flags: forwarded.cask, run:,
                                                                  after:, merged: -> { finish_given }) do |calls|
            Timed::Runner.run(result.batches, verb: "install", flags: forwarded.formula, formulae:, deps:,
                                              stamp: !args.no_stamp_receipts?, succeeded:,
                                              dependencies_only: args.only_dependencies?, apart: true, arguments:,
                                              verbs: dependency_calls, dependency_of:, finish:, after: calls)
          end
        end
        last = Timed::Command.last_casks("install", last_casks, named: args.named, flags: forwarded.cask,
                                                                unfinished: outcome&.unfinished || [], run:,
                                                                run_dependencies:, merged: true)
        Timed::Runner.run_casks("install", last, flags: forwarded.cask, label: "last")
      end

      private

      sig { returns(T::Hash[Symbol, T.any(T::Boolean, T::Array[String])]) }
      def installer_options = Timed::Command.installer_options(args)

      # The dependencies brew would install or upgrade in `installer`'s call,
      # as it works them out again before installing, once the bottle
      # manifests are read (`FormulaInstaller#compute_dependencies`), each
      # with the verb of the call that does the same apart (see
      # `Planner.plan`'s `verbs`): a missing one, which brew installs as a
      # dependency, and an outdated one, which brew upgrades keeping how it
      # was installed (on request or not). Those in
      # `leave` (full names), and any other brew installs differently on its
      # own, are left for brew to install in `installer`'s call: one with
      # options, one whose installed version isn't linked into `opt` or is
      # the latest, one built as a bottle, which `brew upgrade` would
      # build again, one installed from another tap and one installed through
      # an alias whose target has changed, which `brew upgrade` would replace
      # with that target. Brew upgrades an outdated one even with
      # `$HOMEBREW_NO_INSTALL_UPGRADE` set, as does `brew upgrade`.
      sig { params(installer: FormulaInstaller, leave: T::Array[String]).returns(T::Array[[Formula, Symbol]]) }
      def dependency_verbs(installer, leave:)
        installer.expand_dependencies.filter_map do |dependency|
          formula = dependency.to_formula
          next if leave.include?(formula.full_name) || !dependency.options.empty?
          next [formula, :dependency] unless formula.any_version_installed?
          next if !formula.optlinked? || formula.latest_version_installed?

          tab = Tab.for_formula(formula)
          next if tab.built_bottle? || (formula.tap && tab.tap && tab.tap != formula.tap)
          # Loaded through its keg, as `brew upgrade` loads it.
          next if Formulary.resolve(formula.full_name).installed_alias_target_changed?

          [formula, :upgrade]
        end
      end
    end
  end
end
