# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "abstract_subcommand"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/receipts"

module Homebrew
  module Cmd
    class BuildTimes < AbstractCommand
      # Brew lists subcommands in reverse order of definition, so `stats`,
      # defined last, comes first.
      class RestampSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          usage_banner <<~EOS
            `brew build-times restamp` [<formula> ...]:
            Add the logged build times to the install receipts of installed formulae that lack them.
            Stamps each installed keg of <formula>, or of every logged formula, whose receipt has no `build_times`,
            from the latest logged build of the keg's version of the same kind: a pour for a keg poured from a bottle,
            a source build otherwise.
          EOS
          named_args :formula
        end

        sig { override.void }
        def run
          log = Timed::BuildLog.load(Timed::BuildLog.default_path)
          receipts = Timed::Receipts.restamp(log, args.named.empty? ? log.package_names : args.named)
          ohai "No receipts to restamp" if receipts.empty?
          receipts.each { |receipt| ohai "Restamped #{receipt.dirname}" }
        end
      end

      class NoteSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          usage_banner <<~EOS
            `brew build-times note` <formula> <text>:
            Append <text> to the problems recorded for the latest logged build of <formula>.
          EOS
          named_args [:formula, :text], number: 2
        end

        sig { override.void }
        def run
          name, text = args.named
          noted = Timed::BuildLog.update(Timed::BuildLog.default_path) { |log| log.add_note(name.to_s, text.to_s) }
          odie "no builds logged for #{name}" if noted.nil?
        end
      end

      class StatsSubcommand < Homebrew::AbstractSubcommand
        subcommand_args default: true do
          usage_banner <<~EOS
            `brew build-times stats` [<formula> ...]:
            Show build time statistics and estimates for <formula> or every logged formula.
            Builds that poured a bottle and builds from source are never mixed.
            The estimate of a source build is its mean plus 1.5 standard deviations, and of a pour its mean.
            A formula with both kinds gets a row for each, with the estimate used to order its next build of that kind.
            An estimate ending in `?` is a guess, as the formula has no usable history of that kind.
          EOS
          named_args :formula
        end

        sig { override.void }
        def run
          log = Timed::BuildLog.load(Timed::BuildLog.default_path)
          names = args.named.empty? ? log.package_names : args.named.map { |name| Utils.name_from_full_name(name) }
          puts "formula                      kind     n   median     mean     mode    stdev  estimate  last"
          names.flat_map { |name| rows(log, name) }.each { |line| puts line }
          puts "fallback for unknown formulae (median of per-package means): " \
               "#{Timed::BuildLog.format_duration(log.fallback_estimate)}"
        end

        private

        # One row per kind of build the formula has (source builds, then
        # pours), each with statistics from that kind only. `last` is always
        # the formula's latest build, whatever its kind or outcome.
        sig { params(log: Timed::BuildLog, name: String).returns(T::Array[String]) }
        def rows(log, name)
          builds = log.builds(name)
          kinds = %w[built poured].select { |kind| builds.any? { |build| build["status"] == kind } }
          (kinds.empty? ? [nil] : kinds).map { |kind| row(log, name, kind) }
        end

        # A row without usable history (no builds, only failed ones, or zero
        # durations) shows the estimate the planner would use, marked with `?`.
        sig { params(log: Timed::BuildLog, name: String, kind: T.nilable(String)).returns(String) }
        def row(log, name, kind)
          latest = log.builds(name).last || {}
          last_text = [latest.fetch("version", "?"), latest.fetch("status", ""), latest.fetch("started", "")[0, 10]]
                      .join(" ")
          summary = Timed::BuildLog.summarise(log.durations(name, status: kind))
          durations = if summary
            times = [summary.median, summary.mean, summary.mode, summary.stdev]
            [summary.n, *times.map { |seconds| Timed::BuildLog.format_duration(seconds.to_f) }]
          else
            [0, "-", "-", "-", "-"]
          end
          seconds = log.estimate(name, pour: kind == "poured") || log.fallback_estimate
          estimate = "#{Timed::BuildLog.format_duration(seconds)}#{"?" if summary.nil?}"
          format("%<name>-28s %<kind>-6s %<n>3s %<median>8s %<mean>8s %<mode>8s %<stdev>8s %<estimate>9s  %<last>s",
                 name:, kind: kind || "-", n: durations[0], median: durations[1], mean: durations[2],
                 mode: durations[3], stdev: durations[4], estimate:, last: last_text)
        end
      end

      cmd_args do
        usage_banner <<~EOS
          `build-times` [<subcommand>]

          Show and annotate the log of how long formulae took to build from source or to pour a bottle.
          `brew upgrade-timed` and `brew reinstall-timed` use it to order the formulae they run.
          The log is `build-log.json` in `$HOMEBREW_USER_CONFIG_HOME` (`~/.homebrew` by default).
        EOS

        Homebrew::AbstractSubcommand.define_all(self, command: Homebrew::Cmd::BuildTimes)
      end

      sig { override.void }
      def run
        Homebrew::Cmd::BuildTimes.dispatch(args)
      end

      class << self
        sig { params(args: T.untyped).void }
        def dispatch(args)
          subcommand_class = Homebrew::AbstractSubcommand
                             .subcommands_for(Homebrew::Cmd::BuildTimes)
                             .find { |candidate| candidate.subcommand_name == args.subcommand }
          raise UsageError, "Unknown `brew build-times` subcommand: #{args.subcommand}" if subcommand_class.nil?

          subcommand_class.new(args).run
        end
      end
    end
  end
end
