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
require_relative "../lib/timed/planner"
require_relative "../lib/timed/receipts"
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
        Homebrew::Trust.trust_fully_qualified_items!(args.named, type: args.only_formula_or_cask)
        items = args.named.to_formulae_and_casks_and_unavailable(method: :resolve)
        # As `brew reinstall` does, first.
        casks = items.grep(Cask::Cask).reject do |cask|
          next false unless cask.pinned?

          onoe "#{cask.full_name} is pinned. You must unpin it to reinstall."
          true
        end

        guesses = Timed::Command.guesses(args.guess || [],
                                         resolve: ->(name) { Timed::Command.resolve("--guess", name) })
        exclude = (args.exclude || []).map { |name| Timed::Command.resolve("--exclude", name) }

        named = items.grep(Formula)
        reinstall(named, casks, estimator:, guesses:, exclude:)
        # As `brew reinstall` does, last.
        items.each { |item| ofail item if item.is_a?(Exception) }
      end

      private

      # Plans and runs the reinstall of the `named` formulae and the `casks`.
      sig {
        params(named: T::Array[Formula], casks: T::Array[Cask::Cask], estimator: Symbol,
               guesses: T::Hash[String, Float], exclude: T::Array[String]).void
      }
      def reinstall(named, casks, estimator:, guesses:, exclude:)
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
        log = Timed::BuildLog.load(Timed::BuildLog.default_path)
        estimates = set.to_h do |name|
          [name, Timed::Command.estimate(log, name, pour: installers.fetch(name).pour_bottle?, estimator:, guesses:)]
        end
        # One batch: reinstall has no splits.
        result = Timed::Planner.plan(
          verb:      :reinstall,
          names:     set,
          deps:      formulae.transform_values { |formula| Timed::Command.dependency_names(formula) },
          estimates: estimates.transform_values(&:seconds),
          exclude:,
        )

        # What `brew reinstall` prints before asking, whether or not it would.
        dependants = Upgrade.dependants(named, flags: args.flags_only, **installer_options)
        Install.ask_formulae(installers.values, dependants, action: "reinstallation", prompt: false,
                             flags: args.flags_only, **installer_options)
        Timed::Command.show_plan("reinstall", result, estimates, excluded: set & exclude)
        # Brew installs a cask that isn't installed.
        installed, new_casks = casks.partition(&:installed?)
        cask_plan = Timed::Command.cask_plan({ reinstall: installed, install: new_casks },
                                             in_run: result.batches.flat_map(&:names), zap: args.zap?,
                                             force: args.force?)
        Timed::Command.show_casks("reinstall", cask_plan)
        return if args.dry_run? || (result.batches.empty? && cask_plan.first.empty? && cask_plan.last.empty?)

        # Once, by brew's rules: if brew would install or upgrade dependencies
        # of the formulae, or upgrade outdated dependents of them, or install
        # dependencies of the casks. Exits on "n"; returns false without a
        # terminal, where brew carries on unasked.
        cask_names = casks.map(&:full_name)
        if !args.no_ask? && (Install.formulae_ask_prompt_needed?(installers.values, dependants) ||
           Install.ask_prompt_needed?(planned_names: cask_names + cask_dependencies, requested_names: cask_names))
          Homebrew::Ask.confirm?(action: "reinstallation")
        end

        forwarded = Timed::Command.forward(Timed::Command.options(args, self.class.parser),
                                           conflicts: self.class.parser.conflicts)
        Timed::Runner.run_casks("reinstall", Timed::Command.cask_arguments(args.named, cask_plan.first.map(&:cask)),
                                flags: forwarded.cask, label: "first")
        stopped_early = if result.batches.any?
          # A failed reinstall leaves the old version installed, so only a new
          # receipt shows brew reinstalled a formula.
          succeeded = lambda do |formula|
            before = Timed::Receipts.receipt_stat(formula)
            ->(since) { Timed::Receipts.installed_since?(formula, since, before:) }
          end
          # One call, so nothing is skipped for a failure, but a failed build
          # ends `brew reinstall` before the formulae after it.
          Timed::Runner.run(result.batches, verb: "reinstall", flags: forwarded.formula, formulae:, deps: {},
                                            stamp: !args.no_stamp_receipts?, stops_at_failure: true, succeeded:,
                                            arguments: Timed::Command.path_arguments(args.named, formulae))
        end
        last = Timed::Command.cask_arguments(args.named, cask_plan.last.map(&:cask))
        # What stops `brew reinstall` early, such as a failed build, stops it
        # before its casks too.
        if stopped_early && last.any?
          opoo <<~EOS
            `brew reinstall` stopped early, so the last #{Utils.pluralize("cask", last.length)} didn't run: #{last.join(" ")}
            Reinstall #{(last.length == 1) ? "it" : "them"} later with `brew reinstall --cask #{last.join(" ")}`.
          EOS
        else
          Timed::Runner.run_casks("reinstall", last, flags: forwarded.cask, label: "last")
        end
      end

      # The installer `brew reinstall` would use, with the options it would use.
      sig { params(formula: Formula).returns(FormulaInstaller) }
      def installer(formula)
        Homebrew::Reinstall.build_install_context(formula, flags: args.flags_only, git: args.git?,
                                                           **installer_options).formula_installer
      end

      # The options `brew reinstall` gives its installers and dependents check.
      sig { returns(T::Hash[Symbol, T.any(T::Boolean, T::Array[String])]) }
      def installer_options
        {
          force_bottle:               args.force_bottle?,
          build_from_source_formulae: args.build_from_source_formulae,
          interactive:                args.interactive?,
          keep_tmp:                   args.keep_tmp?,
          debug_symbols:              args.debug_symbols?,
          force:                      args.force?,
          debug:                      args.debug?,
          quiet:                      args.quiet?,
          verbose:                    args.verbose?,
        }
      end
    end
  end
end
