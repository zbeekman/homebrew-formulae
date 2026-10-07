# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "abstract_subcommand"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/receipts"
require_relative "../lib/timed/stats_table"

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
            `brew build-times stats` [`--sort=`<key>] [`--reverse`] [<formula> ...]:
            Show build time statistics and estimates for <formula> or every logged formula.
            Builds that poured a bottle and builds from source are never mixed.
            The estimate of a source build is its mean plus 1.5 standard deviations, and of a pour its mean.
            A formula with both kinds gets a row for each, with the estimate used to order its next build of that kind.
            An estimate ending in `?` is a guess, as the formula has no usable history of that kind.
            Then the LLM estimates kept by `--llm-estimates`, each with the source build of its version, if any.
            The trend shows the latest 8 builds of that kind, oldest first, each scaled to the row's own range.
            A failed build is shown as `×` in the trend of every row of the formula.
            With colour, the column names of the header are bold and underlined.
            Colour follows Homebrew's own rules (off when not a terminal or with `HOMEBREW_NO_COLOR`).
          EOS
          flag "--sort=",
               description: "Order the rows by <key>: `name`, `estimate`, `median`, `mean`, `n` or `last` " \
                            "(largest first for numbers, newest first for `last`). " \
                            "Without it the rows are in the order of the log, or of the formulae named."
          switch "--reverse",
                 description: "Reverse the order of the rows."
          named_args :formula
        end

        sig { override.void }
        def run
          key = args.sort
          if key && Timed::StatsTable::SORT_KEYS.exclude?(key)
            raise UsageError, "`--sort` must be one of #{Timed::StatsTable::SORT_KEYS.join(", ")}."
          end

          log = Timed::BuildLog.load(Timed::BuildLog.default_path)
          names = args.named.empty? ? log.package_names : args.named.map { |name| Utils.name_from_full_name(name) }
          rows = Timed::StatsTable.sort(names.flat_map { |name| Timed::StatsTable.rows(log, name) }, key,
                                        reverse: args.reverse? || false)
          Timed::StatsTable.lines(rows).each { |line| puts line }
          puts "fallback for unknown formulae (median of per-package means): " \
               "#{Timed::BuildLog.format_duration(log.fallback_estimate)}"
          estimates = args.named.empty? ? log.estimates.sort.to_h : log.estimates.slice(*names)
          return if estimates.empty?

          puts "LLM estimates and the source builds of the same version:"
          Timed::StatsTable.estimate_lines(log, estimates).each { |line| puts line }
        end
      end

      cmd_args do
        usage_banner <<~EOS
          `build-times` [<subcommand>]

          Show and annotate the log of how long formulae took to build from source or to pour a bottle.
          `brew install-timed`, `brew upgrade-timed` and `brew reinstall-timed` use it to order the formulae they run.
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
