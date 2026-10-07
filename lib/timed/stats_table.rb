# typed: strict
# frozen_string_literal: true

require "date"
require "time"
require "utils/tty"
require_relative "build_log"
require_relative "plot"

module Timed
  # The tables of `brew build-times stats`: one row per kind of build of each
  # formula, with a trend of its latest builds, optionally sorted and painted.
  #
  # Columns are padded by their visible text, so painting does not shift them.
  module StatsTable
    SORT_KEYS = %w[name estimate median mean n last].freeze

    KIND_STYLES = T.let({ "built" => :cyan, "poured" => :magenta }.freeze, T::Hash[String, Symbol])

    NAME_WIDTH = 28

    # One row of the table, with the values it is sorted by.
    class Row < T::Struct
      const :name, String
      const :kind, T.nilable(String)
      const :n, Integer
      # Median, mean, most common minute and stdev as shown, `-` without history.
      const :statistics, T::Array[String]
      const :median, Float
      const :mean, Float
      const :estimate, Float
      # Whether the estimate is a fallback rather than from history.
      const :guess, T::Boolean
      const :last, String
      const :last_failed, T::Boolean
      # Seconds since the epoch of the latest build's start, 0 if unknown.
      const :last_time, Float
      # Seconds of the latest builds of this kind, nil for a failed build.
      const :trend, T::Array[T.nilable(Float)]
    end

    # Paints `text` in `style`, one of the bands of `Plot.band`, the kinds'
    # colours, `:italic`, `:bold` or `:underline`, through Homebrew's `Tty`, so
    # colour is on only when Homebrew's own output would be coloured.
    PAINT = T.let(
      lambda do |text, style|
        next text unless Tty.color?

        "#{Tty.public_send(style)}#{text}#{Tty.reset}"
      end.freeze,
      Plot::Paint,
    )

    # One row per kind of build the formula has (source builds, then pours),
    # each with statistics from that kind only. `last` is always the formula's
    # latest build, whatever its kind or outcome. A failed build is of no kind,
    # so it is in the trend of every row of the formula, as `×`.
    #
    # A row without usable history (no builds, only failed ones, or zero
    # durations) shows the estimate the planner would use, marked with `?`.
    sig { params(log: BuildLog, name: String).returns(T::Array[Row]) }
    def self.rows(log, name)
      builds = log.builds(name)
      kinds = %w[built poured].select { |kind| builds.any? { |build| build["status"] == kind } }
      (kinds.empty? ? [nil] : kinds).map { |kind| row(log, name, kind) }
    end

    sig { params(log: BuildLog, name: String, kind: T.nilable(String)).returns(Row) }
    def self.row(log, name, kind)
      latest = log.builds(name).last || {}
      summary = BuildLog.summarise(log.durations(name, status: kind))
      times = summary ? [summary.median, summary.mean, summary.mode, summary.stdev] : []
      Row.new(
        name:,
        kind:,
        n:            summary&.n || 0,
        statistics:   times.empty? ? %w[- - - -] : times.map { |seconds| BuildLog.format_duration(seconds.to_f) },
        median:       summary&.median || 0.0,
        mean:         summary&.mean || 0.0,
        estimate:     log.estimate(name, pour: kind == "poured") || log.fallback_estimate,
        guess:        summary.nil?,
        last:         [latest.fetch("version", "?"), latest.fetch("status", ""), latest.fetch("started", "")[0, 10]]
                      .join(" ").strip,
        last_failed:  latest["status"] == "failed",
        last_time:    started_at(latest.fetch("started", "")),
        trend:        trend(log, name, kind),
      )
    end
    private_class_method :row

    sig { params(log: BuildLog, name: String, kind: T.nilable(String)).returns(T::Array[T.nilable(Float)]) }
    def self.trend(log, name, kind)
      log.builds(name).flat_map do |build|
        status = build["status"]
        if status == "failed" then [nil]
        elsif kind && status == kind then [BuildLog.duration(build)].compact
        else []
        end
      end
    end
    private_class_method :trend

    # When a build started, as a timestamp or a date (midnight UTC), in
    # seconds since the epoch; 0 if it is neither.
    sig { params(started: String).returns(Float) }
    def self.started_at(started)
      Time.iso8601(started).to_f
    rescue ArgumentError
      begin
        date = Date.iso8601(started)
        Time.utc(date.year, date.month, date.day).to_f
      rescue ArgumentError
        0.0
      end
    end
    private_class_method :started_at

    # `rows` ordered by `key` (one of `SORT_KEYS`; kept as given when nil):
    # largest first for numbers and newest first for `last`, ties by name. The
    # rows of a formula stay together, ordered by its first row.
    sig { params(rows: T::Array[Row], key: T.nilable(String), reverse: T::Boolean).returns(T::Array[Row]) }
    def self.sort(rows, key, reverse:)
      groups = rows.slice_when { |before, after| before.name != after.name }.to_a
      groups = groups.sort { |a, b| compare(a.fetch(0), b.fetch(0), key) } if key
      (reverse ? groups.reverse : groups).flatten(1)
    end

    sig { params(first: Row, second: Row, key: String).returns(Integer) }
    def self.compare(first, second, key)
      by_value = case key
      when "estimate" then second.estimate <=> first.estimate
      when "median" then second.median <=> first.median
      when "mean" then second.mean <=> first.mean
      when "n" then second.n <=> first.n
      when "last" then second.last_time <=> first.last_time
      end
      (by_value || 0).nonzero? || (first.name <=> second.name) || 0
    end
    private_class_method :compare

    # The header and a line for each row. `paint` is how the colour is added.
    sig { params(rows: T::Array[Row], paint: Plot::Paint).returns(T::Array[String]) }
    def self.lines(rows, paint: PAINT)
      last_width = rows.map { |row| row.last.length }.push(4).max.to_i
      columns = [
        heading("formula", NAME_WIDTH, paint),
        heading("kind", 6, paint),
        heading("n", 3, paint, right: true),
        *%w[median mean mode stdev].map { |name| heading(name, 8, paint, right: true) },
        heading("estimate", 9, paint, right: true),
      ]
      header = "#{columns.join(" ")}  #{heading("last", last_width, paint)}  #{heading("trend", 5, paint)}"
      [header] + rows.map { |row| line(row, last_width, paint) }
    end

    sig { params(row: Row, last_width: Integer, paint: Plot::Paint).returns(String) }
    def self.line(row, last_width, paint)
      estimate = "#{BuildLog.format_duration(row.estimate)}#{"?" if row.guess}"
      kind = row.kind
      columns = [
        row.name.ljust(NAME_WIDTH),
        pad(kind || "-", 6, paint, style: kind && KIND_STYLES[kind]),
        row.n.to_s.rjust(3),
        *row.statistics.map { |text| text.rjust(8) },
        pad(estimate, 9, paint, style: Plot.band(row.estimate), right: true, italic: row.guess),
      ]
      last = pad(row.last, last_width, paint, style: row.last_failed ? :red : nil)
      "#{columns.join(" ")}  #{last}  #{Plot.sparkline(row.trend, paint:)}"
    end
    private_class_method :line

    # The LLM estimates and the source builds of the same version, each in the
    # band of its time.
    sig {
      params(log: BuildLog, estimates: T::Hash[String, T::Hash[String, T.untyped]], paint: Plot::Paint)
        .returns(T::Array[String])
    }
    def self.estimate_lines(log, estimates, paint: PAINT)
      header = "#{heading("formula", NAME_WIDTH, paint)} #{heading("version", 12, paint)} " \
               "#{heading("estimate", 9, paint, right: true)} #{heading("actual", 9, paint, right: true)}  " \
               "#{heading("model", 5, paint)} #{heading("date", 4, paint)}"
      rows = estimates.map do |name, estimate|
        version = estimate.fetch("version")
        actual = log.durations(name, status: "built", version:).last
        "#{name.ljust(NAME_WIDTH)} #{version.ljust(12)} #{seconds_cell(estimate.fetch("seconds").to_f, paint)} " \
          "#{seconds_cell(actual, paint)}  #{estimate["model"]} #{estimate["date"]}"
      end
      [header, *rows]
    end

    sig { params(seconds: T.nilable(Float), paint: Plot::Paint).returns(String) }
    def self.seconds_cell(seconds, paint)
      return "-".rjust(9) if seconds.nil?

      pad(BuildLog.format_duration(seconds), 9, paint, style: Plot.band(seconds), right: true)
    end
    private_class_method :seconds_cell

    # A column name, bold and underlined, padded to `width` visible characters;
    # the padding is not underlined, so the columns stand apart.
    sig { params(text: String, width: Integer, paint: Plot::Paint, right: T::Boolean).returns(String) }
    def self.heading(text, width, paint, right: false)
      gap = " " * [width - text.length, 0].max
      painted = paint.call(paint.call(text, :bold), :underline)
      right ? "#{gap}#{painted}" : "#{painted}#{gap}"
    end
    private_class_method :heading

    # `text` padded to `width` visible characters; only the text is painted,
    # in `style` and also in italics if `italic`.
    sig {
      params(text: String, width: Integer, paint: Plot::Paint, style: T.nilable(Symbol), right: T::Boolean,
             italic: T::Boolean).returns(String)
    }
    def self.pad(text, width, paint, style: nil, right: false, italic: false)
      gap = " " * [width - text.length, 0].max
      painted = style ? paint.call(text, style) : text
      painted = paint.call(painted, :italic) if italic
      right ? "#{gap}#{painted}" : "#{painted}#{gap}"
    end
    private_class_method :pad
  end
end
