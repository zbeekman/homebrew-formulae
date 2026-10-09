# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "ask"
require "cmd/reinstall"
require "install"
require "reinstall"
require "trust"
require "upgrade"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/command"
require_relative "../lib/timed/estimates_table"
require_relative "../lib/timed/planner"
require_relative "../lib/timed/runner"

module Homebrew
  module Cmd
    class ReinstallTimed < AbstractCommand
      cmd_args do
        instance_exec(&Timed::Command.parser_block(Timed::Command.builtin("reinstall")))
        description <<~EOS
          Reinstall formulae like `brew reinstall`, in one call ordered by their estimates: dependencies first,
          then the quickest, so quick reinstalls finish early and slow builds never hold them up.
          Estimates come from the log shown by `brew build-times`.

          Takes every `brew reinstall` option. Prints what `brew reinstall` would reinstall and the order with
          the estimates, then asks for confirmation once, as `brew reinstall` does. With `--dry-run`, stops after
          printing the plan. Otherwise runs `brew reinstall` with the formulae in that order and logs how long
          each took. Reinstalls casks with `brew reinstall --cask` before the formulae, or after them if they may
          prompt or need the run.
        EOS
        switch "-n", "--dry-run",
               description: "Show what would be reinstalled, but do not actually reinstall anything."
        Timed::Command.define_flags(self, last: false)
      end

      sig { override.void }
      def run
        raise UsageError, "`--interactive` needs a terminal; use `brew reinstall --interactive` instead." if
          args.interactive?

        estimator = Timed::Command.estimator(args.estimator)
        llm = Timed::Command.llm_settings(args)
        Homebrew::Trust.trust_fully_qualified_items!(args.named, type: args.only_formula_or_cask)
        items = args.named.to_formulae_and_casks_and_unavailable(method: :resolve)
        named_casks = items.grep(Cask::Cask)
        # As `brew reinstall` does, first.
        casks = named_casks.reject do |cask|
          next false unless cask.pinned?

          onoe "#{cask.full_name} is pinned. You must unpin it to reinstall."
          true
        end

        guesses = Timed::Command.guesses(args.guess || [],
                                         resolve: ->(name) { Timed::Command.resolve("--guess", name) })
        exclude = (args.exclude || []).map { |name| Timed::Command.resolve("--exclude", name) }

        named = items.grep(Formula)
        reinstall(named, casks, casks_named: args.cask? || named_casks.any?, estimator:, guesses:, exclude:, llm:)
        # As `brew reinstall` does, last.
        items.each { |item| ofail item if item.is_a?(Exception) }
      end

      private

      # Plans and runs the reinstall of the `named` formulae and the `casks`,
      # which pinned ones are left out of: `casks_named` says whether any were
      # named, or `--cask` was given.
      sig {
        params(named: T::Array[Formula], casks: T::Array[Cask::Cask], casks_named: T::Boolean, estimator: Symbol,
               guesses: T::Hash[String, Float], exclude: T::Array[String], llm: T.nilable(Timed::LLM::Settings)).void
      }
      def reinstall(named, casks, casks_named:, estimator:, guesses:, exclude:, llm:)
        # What `brew reinstall` prints about the casks before it asks about
        # them: the dependencies it would install.
        cask_dependencies = Install.print_dry_run_casks(casks, action:         "reinstall",
                                                               skip_cask_deps: args.skip_cask_deps?)
        # Brew reinstalls the new target of the alias a formula was installed
        # with.
        latest = named.filter_map do |formula|
          if formula.pinned?
            onoe "#{formula.full_name} is pinned. You must unpin it to reinstall."
            next
          end
          formula.latest_formula
        end
        formulae = latest.to_h { |formula| [formula.full_name, formula] }
        set = formulae.keys
        installers = formulae.transform_values { |formula| installer(formula) }
        estimates = Timed::Command.estimates(formulae,
                                             pour: ->(formula) { installers.fetch(formula.full_name).pour_bottle? },
                                             estimator:, guesses:, llm:, exclude:)
        # One batch: reinstall has no splits.
        result = Timed::Planner.plan(
          verb:      :reinstall,
          names:     set,
          deps:      formulae.transform_values { |formula| Timed::Command.dependency_names(formula) },
          estimates: estimates.transform_values(&:seconds),
          exclude:,
        )
        planned = result.batches.flat_map(&:names)

        # Brew's installed-dependents check of the named formulae, as named
        # (`Upgrade.dependants`), pinned ones too, as `brew reinstall` checks
        # those it refuses, even if it reinstalls nothing, but not those given
        # to `--exclude`.
        checked = named.select do |formula|
          formula.pinned? ? exclude.exclude?(formula.full_name) : planned.include?(formula.latest_formula.full_name)
        end
        # What `brew reinstall` prints before asking, whether or not it would.
        dependants = Upgrade.dependants(checked, flags: args.flags_only, **installer_options)
        Install.ask_formulae(installers.values, dependants, action: "reinstallation", prompt: false,
                             flags: args.flags_only, **installer_options)
        # The outdated dependents brew's check finds are upgraded after the
        # formulae, but never a named formula, as `brew reinstall` leaves those
        # out (`Upgrade.dependent_formula_installers`), nor an excluded one.
        left_out = set + named.map(&:full_name) + exclude
        dependents = dependants.upgradeable.reject { |formula| left_out.include?(formula.full_name) }
        Timed::Command.show_plan("reinstall", result, estimates, excluded: set & exclude, casks: casks_named,
                                                                 dependents: dependents.map(&:full_name))
        # Brew installs a cask that isn't installed.
        installed, new_casks = casks.partition(&:installed?)
        run_dependencies = Timed::Command.run_dependencies(installers.values_at(*planned))
        cask_plan = Timed::Command.cask_plan({ reinstall: installed, install: new_casks },
                                             in_run: planned, run_dependencies:, zap: args.zap?,
                                             force: args.force?, skip_cask_deps: args.skip_cask_deps?)
        forwarded = Timed::Command.forward(Timed::Command.options(args, self.class.parser),
                                           conflicts: self.class.parser.conflicts)
        Timed::Command.show_casks("reinstall", cask_plan, named: args.named, flags: forwarded.cask)
        return if args.dry_run? || [result.batches, dependents, cask_plan.first, cask_plan.last].all?(&:empty?)

        # Once, by brew's rules: if brew would install or upgrade dependencies
        # of the formulae, or upgrade outdated dependents of them, or install
        # dependencies of the casks. Unlike brew (`Install.ask_formulae`),
        # also when it reinstalls no formula, as the dependents of pinned ones
        # are still upgraded. Exits on "n"; returns false without a terminal,
        # where brew carries on unasked.
        cask_names = casks.map(&:full_name)
        if !args.no_ask? && (Install.formulae_ask_prompt_needed?(installers.values, dependants) ||
           Install.ask_prompt_needed?(planned_names: cask_names + cask_dependencies, requested_names: cask_names))
          Homebrew::Ask.confirm?(action: "reinstallation")
        end

        Timed::Runner.run_casks("reinstall", Timed::Command.cask_arguments(args.named, cask_plan.first.map(&:cask)),
                                flags: forwarded.cask, label: "first")
        last = cask_plan.last.map(&:cask)
        arguments = Timed::Command.path_arguments(args.named, formulae)
        run = Timed::Command::Run.new(command: [self.class.command_name, *forwarded.formula, *forwarded.own],
                                      roots:   planned.to_h { |name| [name, arguments.fetch(name, name)] },
                                      needs:   run_dependencies)
        outcome = if result.batches.any? || dependents.any?
          # The outdated dependents and broken linkage are seen to before the
          # last casks, which may need them, even with no call, as
          # `brew reinstall` upgrades those of pinned formulae it refuses.
          # Unlike `brew reinstall`, also after a failed build has stopped it,
          # as the formulae reinstalled before that may have broken their
          # dependents' linkage.
          after = lambda do
            Timed::Command.after(dependents, checked, args:, excluded: exclude, flags: forwarded.formula,
                                                      own: forwarded.own)
          end
          # One call, so nothing is skipped for a failure, but a failed build
          # ends `brew reinstall` before the formulae after it.
          Timed::Command.before_last_casks("reinstall", last, named: args.named, flags: forwarded.cask, run:,
                                                              after:) do |calls|
            Timed::Runner.run(result.batches, verb: "reinstall", flags: forwarded.formula, formulae:, deps: {},
                                              stamp: !args.no_stamp_receipts?, stops_at_failure: true,
                                              succeeded: Timed::Runner::REINSTALLED, arguments:, after: calls)
          end
        end
        # What stops `brew reinstall` early, such as a failed build, stops it
        # before its casks too.
        if outcome&.stopped_early && last.any?
          Timed::Command.casks_not_run("`brew reinstall` stopped early", "reinstall", last,
                                       named: args.named, flags: forwarded.cask, run:)
        else
          last = Timed::Command.last_casks("reinstall", last, named: args.named, flags: forwarded.cask,
                                                              unfinished: outcome&.unfinished || [], run:,
                                                              run_dependencies:)
          Timed::Runner.run_casks("reinstall", last, flags: forwarded.cask, label: "last")
        end
        Timed::EstimatesTable.show(planned, estimates, outcome.durations) if outcome
      end

      # The installer `brew reinstall` would use, with the options it would use.
      sig { params(formula: Formula).returns(FormulaInstaller) }
      def installer(formula)
        Homebrew::Reinstall.build_install_context(formula, flags: args.flags_only, git: args.git?,
                                                           **installer_options).formula_installer
      end

      sig { returns(T::Hash[Symbol, T.any(T::Boolean, T::Array[String])]) }
      def installer_options = Timed::Command.installer_options(args)
    end
  end
end
