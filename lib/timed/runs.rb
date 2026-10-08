# typed: strict
# frozen_string_literal: true

require "time"
require_relative "after"
require_relative "build_log"
require_relative "columns"
require_relative "plot"

module Timed
  # The `-timed` runs in the build log, for `brew build-times runs` and `run`.
  # `Runner.run` logs each build with its run (`run`), and names the log of
  # each of its batches after the run's start, in local time, and its
  # process, so every build logged with the same `run`, or, logged before
  # `run` was, with a log of the same run, is of that run. A skipped formula
  # logged with no `run` has no log either, so it is put in the latest run
  # that started at or before it, by the local time logged. Other builds
  # with no such log, and those with a date alone (logged before the
  # runner), are of no run.
  module Runs
    extend Columns

    # `<YYYYmmdd-HHMMSS>-<pid>-batch<n>.log`, as `Runner.run` names it.
    LOG_NAME = /\A(?<run>\d{8}-\d{6}-\d+)-batch(?<batch>\d+)\.log\z/

    # Bars are never narrower than this, however narrow the terminal.
    MIN_COLUMNS = 10

    # The statuses counted in the list of runs.
    COUNTED = %w[built poured failed skipped].freeze

    # A build of a run.
    class Build < T::Struct
      const :name, String
      const :status, String
      const :verb, T.nilable(String)
      # The batch's label: `main`, `last` or that of a call after the batches.
      const :label, T.nilable(String)
      # The number of the batch in the run, from its log; nil for a skipped
      # formula.
      const :batch, T.nilable(Integer)
      const :started, Time
      const :seconds, T.nilable(Float)

      sig { returns(T::Boolean) }
      def skipped? = status == "skipped"

      # When it finished, or started if that is not logged, as for a failed
      # build.
      sig { returns(Time) }
      def finished = started + (seconds || 0.0)
    end

    # A run: its id, the prefix of its logs, and its builds, in the order of
    # its batches and calls after the batches, each call's skipped formulae
    # after its builds, then the skipped formulae of the batches.
    class Run < T::Struct
      const :id, String
      const :builds, T::Array[Build]

      # The builds that ran, not the skipped formulae, or all of them if none
      # ran.
      sig { returns(T::Array[Build]) }
      def ran = builds.reject(&:skipped?).presence || builds

      sig { returns(Time) }
      def started = ran.map(&:started).min || Time.at(0)

      sig { returns(Time) }
      def finished = ran.map(&:finished).max || Time.at(0)

      # Seconds from the first start to the last finish.
      sig { returns(Float) }
      def length = finished - started

      # Seconds of the run that no build covers: brew's own work, such as
      # downloads and checks, between the builds, and failed builds, which
      # have no logged finish.
      sig { returns(Float) }
      def between
        # How far the builds so far reach, so overlaps count once. Not `sum`,
        # which can call its block twice for an element.
        reach = started
        covered = 0.0
        ran.sort_by(&:started).each do |build|
          from = build.started
          from = reach if reach > from
          to = build.finished
          next if to <= from

          covered += to - from
          reach = to
        end
        length - covered
      end

      # The verbs of its calls, in order.
      sig { returns(T::Array[String]) }
      def verbs = builds.filter_map(&:verb).uniq

      sig { params(status: String).returns(Integer) }
      def count(status) = builds.count { |build| build.status == status }

      # Whether it only skipped formulae, so nothing has a bar.
      sig { returns(T::Boolean) }
      def skipped_only? = builds.all?(&:skipped?)
    end

    # The runs in `log`, newest first.
    sig { params(log: BuildLog).returns(T::Array[Run]) }
    def self.all(log)
      runs = T.let({}, T::Hash[String, T::Array[Build]])
      skipped = T.let([], T::Array[Build])
      log.package_names.each do |name|
        log.builds(name).each do |entry|
          started = timestamp(entry["started"])
          next if started.nil?

          match = LOG_NAME.match(File.basename(entry["log"].to_s))
          seconds = entry["wall_seconds"]&.to_f
          # The runner once missed brew's dependency heading with a version,
          # and so logged a dependency's wall time as 0.
          seconds = nil if seconds&.zero? && entry["install_seconds"].to_f.positive?
          build = Build.new(name:, status: entry["status"].to_s, verb: entry["verb"]&.to_s,
                            label: entry["batch"]&.to_s, batch: match && match[:batch].to_i, started:, seconds:)
          id = text(entry["run"])
          if match
            (runs[id || match[:run].to_s] ||= []) << build
          elsif build.skipped? && entry["log"].nil?
            id ? (runs[id] ||= []) << build : skipped << build
          end
        end
      end
      skipped.each do |build|
        local = build.started.strftime("%Y%m%d-%H%M%S")
        id = runs.keys.select { |run| run[0, 15].to_s <= local }.max_by { |run| run[0, 15].to_s }
        runs.fetch(id) << build if id
      end
      runs.map { |id, builds| Run.new(id:, builds: builds.sort_by { |build| order(build) }) }
          .sort_by { |run| [run.started, run.id] }.reverse
    end

    # The header and a line for each of `runs`, numbered from 1, with when it
    # started (as logged), its verbs, how many builds it logged as built,
    # poured, failed and skipped, a number of failed ones other than 0 in red,
    # and its length.
    sig { params(runs: T::Array[Run], paint: Plot::Paint).returns(T::Array[String]) }
    def self.lines(runs, paint: Columns::PAINT)
      # At least as wide as `verbs`.
      verbs_width = runs.map { |run| run.verbs.join(",").length }.push(5).max.to_i
      header = [heading("run", 3, paint, right: true), heading("started", 16, paint),
                heading("verbs", verbs_width, paint), *COUNTED.map { |status| heading(status, status.length, paint) },
                heading("length", 7, paint, right: true)]
      rows = runs.each.with_index(1).map do |run, number|
        counts = COUNTED.map do |status|
          count = run.count(status)
          pad(count.to_s, status.length, paint, style: (:red if status == "failed" && count.positive?), right: true)
        end
        [number.to_s.rjust(3), run.started.strftime("%Y-%m-%d %H:%M"), run.verbs.join(",").ljust(verbs_width),
         *counts, BuildLog.format_duration(run.length).rjust(7)]
      end
      [header, *rows].map { |columns| columns.join("  ") }
    end

    # The timeline of `run`, number `number`, `width` columns wide (at least
    # `Plot::MIN_WIDTH`), as headings, each with its lines: the run's, with
    # the header, which has the time axis from 0 to the run's length, unless
    # the run only skipped formulae, then one for each batch and call after
    # the batches, with a row for each formula: its name, its status, its
    # time and its bar on the axis, painted by status, the call's skipped
    # formulae last, with no bar, then the skipped formulae of the batches.
    sig {
      params(run: Run, number: Integer, width: Integer, paint: Plot::Paint)
        .returns(T::Array[[String, T::Array[String]]])
    }
    def self.timeline(run, number, width:, paint: Columns::PAINT)
      # At least as wide as `formula`.
      name_width = run.builds.map { |build| build.name.length }.push(7).max.to_i
      columns = [[width, Plot::MIN_WIDTH].max - name_width - 20, MIN_COLUMNS].max
      length = BuildLog.format_duration(run.length)
      axis = "  0#{length.rjust(columns - 1)}" unless run.skipped_only?
      header = "#{heading("formula", name_width, paint)}  #{heading("status", 7, paint)}  " \
               "#{heading("time", 7, paint, right: true)}#{axis}"
      sections = run.builds.chunk_while { |previous, build| section(previous) == section(build) }.map do |builds|
        first = builds.fetch(0)
        rows = builds.map do |build|
          style = Columns::STATUS_STYLES[build.status]
          seconds = build.seconds
          time = seconds ? BuildLog.format_duration(seconds) : "-"
          row = "#{build.name.ljust(name_width)}  #{pad(build.status, 7, paint, style:)}  #{time.rjust(7)}"
          next row.rstrip if build.skipped?

          from = build.started - run.started
          bar = Plot.timeline_bar(from, from + (seconds || 0.0), span: run.length, columns:,
                                  char: (build.status == "failed") ? Plot::FAILED : "█", style:, paint:)
          "#{row}  #{bar}"
        end
        [batch_heading(first), rows]
      end
      [["Run #{number}, started #{run.started.strftime("%Y-%m-%d %H:%M")}: #{run.verbs.join(", ")}", [header]],
       *sections]
    end

    # The run's length, the time between its bars and what that is: brew's
    # own work, and builds with no time, such as failed ones, whose end isn't
    # logged; or, if it only skipped formulae, that nothing ran.
    sig { params(run: Run).returns(T::Array[String]) }
    def self.total(run)
      return ["Nothing ran: every formula was skipped."] if run.skipped_only?

      unfinished = run.ran.any? { |build| build.seconds.nil? }
      ["Total #{BuildLog.format_duration(run.length)}, #{BuildLog.format_duration(run.between)} of it between the " \
       "bars.",
       "The gaps between the bars are brew's own work, such as downloads and checks.",
       *("The gaps also include builds with no logged end, such as failed builds." if unfinished)]
    end

    # What a call after the batches does, as the plan heads it; `Batch <n>`,
    # with `(--last)` for the last batch; `Skipped` for the skipped formulae
    # of the batches.
    sig { params(build: Build).returns(String) }
    def self.batch_heading(build)
      label = build.label
      after = Runner::After::HEADINGS[label.to_s]
      return after if after

      batch = build.batch
      return "Skipped" if batch.nil?
      return "Batch #{batch} (--last)" if label == "last"

      "Batch #{batch}#{" (#{label})" if label && label != "main"}"
    end
    private_class_method :batch_heading

    # Where a build goes in a timeline, in order: its batch, by number, its
    # call after the batches, even if skipped, or else, skipped in a batch,
    # with no number, the skipped formulae at the end.
    sig { params(build: Build).returns([Integer, Integer]) }
    def self.section(build)
      after = Runner::After::HEADINGS.keys.index(build.label)
      return [1, after] if after

      batch = build.batch
      batch ? [0, batch] : [2, 0]
    end
    private_class_method :section

    # By section, its skipped formulae last, then by start.
    sig { params(build: Build).returns([Integer, Integer, Integer, Time, String]) }
    def self.order(build)
      [*section(build), build.skipped? ? 1 : 0, build.started, build.name]
    end
    private_class_method :order

    # A string that isn't empty, or nil.
    sig { params(value: T.anything).returns(T.nilable(String)) }
    def self.text(value)
      case value
      when String then value.presence
      end
    end
    private_class_method :text

    # A full timestamp, with its UTC offset kept, or nil for a date alone or
    # anything else.
    sig { params(value: T.anything).returns(T.nilable(Time)) }
    def self.timestamp(value)
      case value
      when String then Time.iso8601(value)
      end
    rescue ArgumentError
      nil
    end
    private_class_method :timestamp
  end
end
