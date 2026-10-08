# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "abstract_subcommand"
require_relative "../lib/timed/build_log"
require_relative "../lib/timed/plot"
require_relative "../lib/timed/receipts"
require_relative "../lib/timed/runs"
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
          formula = Timed::BuildLog.formula_names([name.to_s]).fetch(0)
          noted = Timed::BuildLog.update(Timed::BuildLog.default_path) { |log| log.add_note(formula, text.to_s) }
          odie "no builds logged for #{formula}" if noted.nil?
        end
      end

      class RunSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          usage_banner <<~EOS
            `brew build-times run` [<number>]:
            Draw a timeline of run <number>, as `brew build-times runs` numbers them, or of the latest run.
            A heading for each batch, `Batch` and its number, with `(--last)` for the last, and for each call after
            the batches, then a row for each formula with its status, its time and a bar from when brew first named
            it to when it finished, on a linear time axis shared by the whole run. A failed formula with no time is
            drawn as `×` where it started. A call's skipped formulae follow its bars, and those of the batches come
            last, under `Skipped`, with no bar. The gaps between the bars are brew's own work, such as downloads and
            checks, and failed builds with no time; the last lines give the total. With colour, each status and its
            bar are painted: built cyan, poured magenta and failed red.
          EOS
          named_args :number, max: 1
        end

        sig { override.void }
        def run
          named = args.named.first || "1"
          unless named.match?(/\A0*[1-9]\d*\z/)
            raise UsageError, "`run` takes the number of a run, as `brew build-times runs` lists them, not #{named}."
          end

          runs = Timed::Runs.all(Timed::BuildLog.load(Timed::BuildLog.default_path))
          return ohai "No runs logged" if runs.empty?

          number = named.to_i
          chosen = runs[number - 1]
          odie "no run #{number}: #{Utils.pluralize("run", runs.length, include_count: true)} logged" if chosen.nil?
          Timed::Runs.timeline(chosen, number, width: Tty.width).each { |heading, lines| ohai heading, *lines }
          puts Timed::Runs.total(chosen)
        end
      end

      class RunsSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          usage_banner <<~EOS
            `brew build-times runs`:
            List the runs of `brew install-timed`, `brew upgrade-timed` and `brew reinstall-timed` in the log, newest first.
            Each line has the run's number (1 for the latest), when it started, the verbs of its calls, how many
            builds it logged as built, poured, failed and skipped, and its length, from the first start to the last
            finish. Builds logged with a date alone, before the runs were kept, or, other than skipped formulae, with
            no log of a run are left out.
            Casks are never in the log. With colour, a number of failed builds other than 0 is red.
          EOS
          named_args :none
        end

        sig { override.void }
        def run
          runs = Timed::Runs.all(Timed::BuildLog.load(Timed::BuildLog.default_path))
          return ohai "No runs logged" if runs.empty?

          Timed::Runs.lines(runs).each { |line| puts line }
        end
      end

      class HistogramSubcommand < Homebrew::AbstractSubcommand
        subcommand_args do
          usage_banner <<~EOS
            `brew build-times histogram` [`--poured`] [`--builds`] [`--smooth`] [`--linear`] [<formula> ...]:
            Plot a histogram of the source build times of <formula> or every logged formula.
            Each formula counts once, with the mean of its times. Time is on a log scale, from the shortest to the longest,
            with ticks at 1s, 10s, 1m, 10m, 1h and 10h, or with `--linear` on a linear scale from 0; `┴` in the axis,
            labelled `75s batch split`, marks 75 seconds, where the `-timed` commands start to split batches.
            With colour, each bar is green up to 75 seconds, yellow up to 10 minutes and red above, by the median of
            its times. It needs at least 2 times to plot.
          EOS
          switch "--poured",
                 description: "Plot the times of pours instead of source builds."
          switch "--builds",
                 description: "Count every build, not one mean for each formula."
          switch "--smooth",
                 description: "Draw a smoothed curve instead of the bars, on the same axes and scale: a Gaussian " \
                              "kernel density estimate of the log times, with Silverman's bandwidth."
          switch "--linear",
                 description: "Plot time on a linear scale from 0 instead, in bins of a round width near the " \
                              "Freedman–Diaconis width, such as 20s, 5m or 2h, with ticks on their edges."
          named_args :formula
        end

        sig { override.void }
        def run
          log = Timed::BuildLog.load(Timed::BuildLog.default_path)
          names = args.named.empty? ? log.package_names : Timed::BuildLog.formula_names(args.named)
          times = names.map { |name| log.durations(name, status: args.poured? ? "poured" : "built") }.reject(&:empty?)
          what = args.poured? ? "pour" : "source build"
          values = args.builds? ? times.flatten : times.map { |durations| Timed::BuildLog.mean(durations) }
          counted = Utils.pluralize(args.builds? ? what : "formula", values.length, include_count: true)
          if values.length < 2
            return ohai "No histogram: #{counted}#{" with a #{what} time" unless args.builds?}, at least 2 are needed"
          end

          title = args.builds? ? "Time of #{counted}" : "Mean #{what} time of #{counted}"
          ohai "#{title}, from #{Timed::BuildLog.format_duration(values.min)} to " \
               "#{Timed::BuildLog.format_duration(values.max)}",
               *Timed::Plot.histogram(values, width: Tty.width, smooth: args.smooth?, linear: args.linear?,
                                                paint: Timed::Columns::PAINT)
        end
      end

      class StatsSubcommand < Homebrew::AbstractSubcommand
        subcommand_args default: true do
          usage_banner <<~EOS
            `brew build-times stats` [`--sort=`<key>] [`--reverse`] [`--json`[`=`<version>]] [<formula> ...]:
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
            With `--json`, print a JSON array instead, never coloured: for each row `name`, `kind`, `n`, `median`,
            `mean` and `stdev` (seconds) and its `builds`, each with `seconds`, `date`, `version` and `status`.
          EOS
          flag "--sort=",
               description: "Order the rows by <key>: `name`, `estimate`, `median`, `mean`, `n` or `last` " \
                            "(largest first for numbers, newest first for `last`). " \
                            "Without it the rows are in the order of the log, or of the formulae named."
          switch "--reverse",
                 description: "Reverse the order of the rows."
          flag "--json",
               description: "Print the build history as JSON instead of the tables. Currently the default and " \
                            "only accepted value for <version> is `v1`."
          named_args :formula
        end

        sig { override.void }
        def run
          key = args.sort
          if key && Timed::StatsTable::SORT_KEYS.exclude?(key)
            raise UsageError, "`--sort` must be one of #{Timed::StatsTable::SORT_KEYS.join(", ")}."
          end

          json = args.json
          raise UsageError, "invalid JSON version: #{json} (use `v1`)." unless [nil, "v1", true].include?(json)

          log = Timed::BuildLog.load(Timed::BuildLog.default_path)
          names = args.named.empty? ? log.package_names : Timed::BuildLog.formula_names(args.named)
          rows = Timed::StatsTable.sort(names.flat_map { |name| Timed::StatsTable.rows(log, name) }, key,
                                        reverse: args.reverse? || false)
          return puts JSON.pretty_generate(Timed::StatsTable.json_rows(log, rows)) if json

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
