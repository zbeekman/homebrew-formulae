# typed: strict
# frozen_string_literal: true

require_relative "build_log"

module Timed
  # Plain-text drawing for `brew build-times`: data, options and a width in,
  # a string or lines out. It does no I/O and never touches the terminal; a
  # caller that wants colour passes a `paint` proc.
  module Plot
    # Paints `text` in a style: `:blue`, `:green`, `:yellow` or `:red`.
    Paint = T.type_alias { T.proc.params(text: String, style: Symbol).returns(String) }

    BLOCKS = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █].freeze
    FAILED = "×"
    # What a row with nothing to compare is drawn as, in the middle.
    FLAT = "▄"
    # Builds whose longest is under this multiple of the shortest are flat.
    FLAT_RATIO = 1.1
    SPARKLINE_LENGTH = 8

    # Where the planner starts splitting batches.
    GREEN_UP_TO = 75.0
    YELLOW_UP_TO = 600.0

    # The colours of the first to the fourth quartile.
    QUARTILE_STYLES = [:blue, :green, :yellow, :red].freeze

    # The colour of `seconds`: the fixed bands, or, with `cuts` (the quartiles
    # of the values shown, from `quartile_cuts`), the first quartile blue, the
    # second green, the third yellow and the fourth red; a value on a cut is
    # in the lower quartile.
    sig { params(seconds: Float, cuts: T.nilable(T::Array[Float])).returns(Symbol) }
    def self.band(seconds, cuts: nil)
      if cuts
        QUARTILE_STYLES.fetch(cuts.count { |cut| seconds > cut })
      elsif seconds <= GREEN_UP_TO then :green
      elsif seconds <= YELLOW_UP_TO then :yellow
      else :red
      end
    end

    # The first, second and third quartiles of `values`, interpolated between
    # the nearest values; nil for fewer than 4 values, which `band` then
    # paints by the fixed bands.
    sig { params(values: T::Array[Float]).returns(T.nilable(T::Array[Float])) }
    def self.quartile_cuts(values)
      return if values.length < 4

      sorted = values.sort
      [0.25, 0.5, 0.75].map { |fraction| quantile(sorted, fraction) }
    end

    # `fraction` of the way through `sorted`, interpolated.
    sig { params(sorted: T::Array[Float], fraction: Float).returns(Float) }
    def self.quantile(sorted, fraction)
      position = (sorted.length - 1) * fraction
      lower = sorted.fetch(position.floor)
      lower + ((position - position.floor) * (sorted.fetch(position.ceil) - lower))
    end
    private_class_method :quantile

    # One block for each of the latest builds (oldest first), `×` for a failed
    # one (nil), and `-` for none. The blocks are scaled to the range of the
    # builds themselves on a log scale, and a range under 10 % is flat, so
    # noise does not look like a trend. With `paint`, each is painted in the
    # band of its time (or quartile, with `cuts`), and `×` red.
    sig {
      params(builds: T::Array[T.nilable(Float)], paint: T.nilable(Paint), cuts: T.nilable(T::Array[Float]))
        .returns(String)
    }
    def self.sparkline(builds, paint: nil, cuts: nil)
      latest = builds.last(SPARKLINE_LENGTH)
      return "-" if latest.empty?

      times = latest.compact
      low = times.min || 1.0
      high = times.max || 1.0
      cells = latest.map do |seconds|
        next [FAILED, :red] if seconds.nil?

        [block(seconds, low, high), band(seconds, cuts:)]
      end
      cells.map { |text, style| paint ? paint.call(text, style) : text }.join
    end

    sig { params(seconds: Float, low: Float, high: Float).returns(String) }
    def self.block(seconds, low, high)
      return FLAT if high / low < FLAT_RATIO

      position = (Math.log(seconds) - Math.log(low)) / (Math.log(high) - Math.log(low))
      BLOCKS.fetch((position * (BLOCKS.length - 1)).round)
    end
    private_class_method :block

    HEIGHT = 10
    MIN_WIDTH = 40
    TICKS = T.let(
      { "1s" => 1.0, "10s" => 10.0, "1m" => 60.0, "10m" => 600.0, "1h" => 3600.0, "10h" => 36_000.0 }.freeze,
      T::Hash[String, Float],
    )
    # The widths of the bins of a linear histogram, in seconds: 1, 2, 5, 10 or
    # 20 seconds or minutes, so bin edges fall on whole minutes and hours, or
    # 1, 2 or 5 times a power of ten of hours.
    LINEAR_WIDTHS = T.let(
      [1, 2, 5, 10, 20, 60, 120, 300, 600, 1200, 3600, 7200, 18_000, 36_000, 72_000, 180_000, 360_000, 720_000,
       1_800_000, 3_600_000, 7_200_000, 18_000_000].map(&:to_f).freeze,
      T::Array[Float],
    )
    # The steps between the ticks of a linear axis, the smallest of them that
    # is a multiple of the bin width and leaves room for the labels.
    LINEAR_TICK_STEPS = T.let(
      (LINEAR_WIDTHS + [15.0, 30.0, 900.0, 1800.0, 10_800.0, 21_600.0, 43_200.0]).sort.freeze,
      T::Array[Float],
    )
    # The label of the mark at `GREEN_UP_TO` in the x axis.
    MARK_LABEL = "75s batch split"
    # The bit of each dot of a braille character, by row from the top, then
    # by column.
    BRAILLE_BITS = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]].freeze
    BRAILLE_BLANK = 0x2800

    # A character of a plot and the style it is painted in, if any.
    Cell = T.type_alias { [String, T.nilable(Symbol)] }

    # The x axis of a histogram: positions from `low` to `high` across
    # `columns`, in `bins` of equal width. A position is a time in seconds on
    # a `linear` axis and its natural log otherwise.
    class Axis < T::Struct
      const :low, Float
      const :high, Float
      const :columns, Integer
      const :bins, Integer
      const :linear, T::Boolean, default: false

      sig { returns(Float) }
      def span = high - low

      sig { returns(Integer) }
      def per_bin = columns / bins

      sig { params(seconds: Float).returns(Float) }
      def position(seconds) = linear ? seconds : Math.log(seconds)

      # The natural log of the seconds at `position`, minus infinity at or
      # below 0 s.
      sig { params(position: Float).returns(Float) }
      def log_seconds(position) = linear ? Math.log([position, 0.0].max) : position

      # Within rounding error of either edge counts, so a tick exactly at an
      # edge is drawn whichever way the edge was rounded.
      sig { params(seconds: Float).returns(T::Boolean) }
      def cover?(seconds) = position(seconds).between?(low - 1e-9, high + 1e-9)

      # Multiplied before it is divided, so a whole number of seconds on a bin
      # edge of a linear axis is exactly there.
      sig { params(seconds: Float).returns(Integer) }
      def column(seconds) = ((position(seconds) - low) * columns / span).floor.clamp(0, columns - 1)
    end
    private_constant :Axis

    # A histogram of `values` (seconds) on a log scale, `width` columns wide
    # (at least `MIN_WIDTH`) and `HEIGHT` rows high, from the shortest value to
    # the longest. There are at least 2 bins per cube root of the number of
    # values, sometimes a few more so the bins fill the width evenly, so a bar
    # is one or more columns wide. The y axis is labelled with the highest
    # count, the x axis with `TICKS` in the range (or at its edges) and a
    # labelled mark at `GREEN_UP_TO`, in the axis only. With `smooth`, a
    # Gaussian kernel density estimate of the log values, on the scale of the
    # bars, is drawn in braille instead of them, on the same axes, with the y
    # axis up to its peak. With `paint`, each bar is painted in the band of the
    # median of its values; the curve never is. With `quartiles`, the bands are
    # the quartiles of `values` instead of the fixed ones (see `band`).
    #
    # With `linear`, the x axis is linear from 0 instead, in bins of a width
    # from `LINEAR_WIDTHS`: the nearest to the Freedman–Diaconis width (the
    # largest with no interquartile range), narrowed to give at least as many
    # bins as on a log axis and widened to fit the width, with ticks at the
    # multiples of a step from `LINEAR_TICK_STEPS`.
    sig {
      params(values: T::Array[Float], width: Integer, smooth: T::Boolean, linear: T::Boolean,
             paint: T.nilable(Paint), quartiles: T::Boolean)
        .returns(T::Array[String])
    }
    def self.histogram(values, width:, smooth: false, linear: false, paint: nil, quartiles: false)
      shortest, longest = values.minmax
      return [] if shortest.nil? || longest.nil?

      label_width = values.length.to_s.length
      columns = [width, MIN_WIDTH].max - label_width - 2
      axis = linear ? linear_axis(values, longest, columns) : log_axis(shortest, longest, values.length, columns)
      if smooth
        curve = curve(values.map { |seconds| Math.log(seconds) }, axis)
        # Rounded first, so a peak of 1 plus rounding error is not 2.
        top = (curve.max&.round(6)&.ceil || 0).clamp(1, values.length)
        grid = curve_cells(curve, top)
      else
        binned = Array.new(axis.bins) { [] }
        values.each { |seconds| binned.fetch(axis.column(seconds) / axis.per_bin) << seconds }
        top = binned.map(&:length).max || 1
        grid = bars(binned, axis.per_bin, top, quartiles ? quartile_cuts(values) : nil)
      end

      rows = grid.each_with_index.map do |cells, row|
        gutter = row.zero? ? "#{top.to_s.rjust(label_width)} ┤" : "#{" " * label_width} │"
        "#{gutter}#{paint_cells(cells, paint)}".rstrip
      end
      rows + x_axis(axis, label_width, columns)
    end

    # At least 2 bins per cube root of `count` values, as the Rice rule gives.
    sig { params(count: Integer).returns(Integer) }
    def self.least_bins(count) = (2 * Math.cbrt(count)).ceil
    private_class_method :least_bins

    # From the shortest value to the longest, or half and twice them if they
    # are equal, in as many bins of a whole number of columns as fill them.
    sig { params(shortest: Float, longest: Float, count: Integer, columns: Integer).returns(Axis) }
    def self.log_axis(shortest, longest, count, columns)
      low = Math.log(shortest)
      high = Math.log(longest)
      if low == high
        low -= Math.log(2)
        high += Math.log(2)
      end
      per_bin = [columns / least_bins(count), 1].max
      Axis.new(low:, high:, columns: columns - (columns % per_bin), bins: columns / per_bin)
    end
    private_class_method :log_axis

    # From 0 to the end of the bin of the longest value.
    sig { params(values: T::Array[Float], longest: Float, columns: Integer).returns(Axis) }
    def self.linear_axis(values, longest, columns)
      bins = ->(bin_width) { (longest / bin_width).floor + 1 }
      freedman_diaconis = 2 * interquartile_range(values) / Math.cbrt(values.length)
      index = if freedman_diaconis.positive?
        LINEAR_WIDTHS.each_index.min_by { |each| Math.log(LINEAR_WIDTHS.fetch(each) / freedman_diaconis).abs } || 0
      else
        LINEAR_WIDTHS.length - 1
      end
      index -= 1 while index.positive? && bins.call(LINEAR_WIDTHS.fetch(index)) < least_bins(values.length)
      index += 1 while index < LINEAR_WIDTHS.length - 1 && bins.call(LINEAR_WIDTHS.fetch(index)) > columns
      bin_width = LINEAR_WIDTHS.fetch(index)
      count = bins.call(bin_width)
      Axis.new(low: 0.0, high: count * bin_width, columns: count * [columns / count, 1].max, bins: count,
               linear: true)
    end
    private_class_method :linear_axis

    # Silverman's rule of thumb for the bandwidth of a Gaussian kernel density
    # estimate of `values`: 0.9 times the smaller of their standard deviation
    # and their interquartile range divided by 1.34, or the one that is not
    # zero, times the number of values to the power -1/5. Nil when both are
    # zero, as all the values are equal.
    sig { params(values: T::Array[Float]).returns(T.nilable(Float)) }
    def self.bandwidth(values)
      spreads = [BuildLog.stdev(values), interquartile_range(values) / 1.34]
      spread = spreads.select(&:positive?).min
      0.9 * spread * (values.length.to_f**-0.2) if spread
    end

    sig { params(values: T::Array[Float]).returns(Float) }
    def self.interquartile_range(values)
      sorted = values.sort
      quantile(sorted, 0.75) - quantile(sorted, 0.25)
    end
    private_class_method :interquartile_range

    # How many of `values` the Gaussian kernel density estimate of them with
    # `bandwidth` puts between `from` and `to`.
    sig { params(values: T::Array[Float], bandwidth: Float, from: Float, to: Float).returns(Float) }
    def self.count_between(values, bandwidth, from, to)
      scale = bandwidth * Math.sqrt(2)
      values.sum(0.0) { |value| 0.5 * (Math.erf((to - value) / scale) - Math.erf((from - value) / scale)) }
    end

    # The count the kernel density estimate of `logs` (natural logs of
    # seconds) puts in a bin's width centred on each braille dot across the
    # axis (two per column), so the curve is on the scale of the bars: a lone
    # value is never higher than 1, and a cluster narrower than a dot is still
    # drawn. Equal values are smoothed over a bin's width at them.
    sig { params(logs: T::Array[Float], axis: Axis).returns(T::Array[Float]) }
    def self.curve(logs, axis)
      bin_width = axis.span / axis.bins
      bandwidth = bandwidth(logs) || (axis.linear ? bin_width / Math.exp(logs.fetch(0)) : bin_width)
      dots = axis.columns * 2
      (0...dots).map do |dot|
        middle = axis.low + ((dot + 0.5) * axis.span / dots)
        count_between(logs, bandwidth, axis.log_seconds(middle - (bin_width / 2)),
                      axis.log_seconds(middle + (bin_width / 2)))
      end
    end
    private_class_method :curve

    # The bars as rows of cells, from the top: each bin of `binned` values
    # `per_bin` columns wide and its count over `top` of the height, in eighths
    # of a row, at least one for any count, in the band of the median value
    # (see `band` for `cuts`).
    sig {
      params(binned: T::Array[T::Array[Float]], per_bin: Integer, top: Integer, cuts: T.nilable(T::Array[Float]))
        .returns(T::Array[T::Array[Cell]])
    }
    def self.bars(binned, per_bin, top, cuts)
      columns = binned.flat_map do |bin|
        eighths = bin.empty? ? 0 : [(bin.length * HEIGHT * 8.0 / top).round, 1].max
        style = band(BuildLog.median(bin), cuts:) unless bin.empty?
        column = (0...HEIGHT).map do |row|
          filled = (eighths - ((HEIGHT - 1 - row) * 8)).clamp(0, 8)
          filled.zero? ? [" ", nil] : [BLOCKS.fetch(filled - 1), style]
        end
        [column] * per_bin
      end
      columns.transpose
    end
    private_class_method :bars

    # `curve` (counts at each dot, two per column) over `top` of the height as
    # rows of braille cells, from the top, each dot column joined to the one
    # before by a vertical run of dots.
    sig { params(curve: T::Array[Float], top: Integer).returns(T::Array[T::Array[Cell]]) }
    def self.curve_cells(curve, top)
      grid = Array.new(HEIGHT) { Array.new(curve.length / 2) { [" ", nil] } }
      levels = curve.map { |count| (count * HEIGHT * 4 / top).round.clamp(0, HEIGHT * 4) }
      bits = Hash.new(0)
      levels.each_with_index do |level, dot|
        previous = dot.zero? ? level : levels.fetch(dot - 1)
        heights = (level > previous) ? (previous + 1)..level : level..[previous - 1, level].max
        heights.each do |height|
          next if height < 1

          row, from_bottom = (height - 1).divmod(4)
          bits[[HEIGHT - 1 - row, dot / 2]] |= BRAILLE_BITS.fetch(3 - from_bottom).fetch(dot % 2)
        end
      end
      bits.each { |(row, column), value| grid.fetch(row)[column] = [(BRAILLE_BLANK + value).chr(Encoding::UTF_8), nil] }
      grid
    end
    private_class_method :curve_cells

    # The axis line, with a tick at each of `TICKS` (or `linear_ticks`) in the
    # range, the line of their labels, if any: each at its tick or as far
    # right as fits, left out if it would touch the label before, and, if
    # `GREEN_UP_TO` is in the range, a `┴` there (`┼` on a tick) and a line
    # with `MARK_LABEL` from it to the right, or ending at it if that would
    # not fit in `room` columns.
    sig { params(axis: Axis, label_width: Integer, room: Integer).returns(T::Array[String]) }
    def self.x_axis(axis, label_width, room)
      line = Array.new(axis.columns, "─")
      labels = " " * axis.columns
      label_end = -2
      (axis.linear ? linear_ticks(axis) : TICKS).each do |label, seconds|
        next unless axis.cover?(seconds)

        column = axis.column(seconds)
        line[column] = "┬"
        start = [column, axis.columns - label.length].min
        next if start <= label_end + 1

        labels[start, label.length] = label
        label_end = start + label.length - 1
      end
      if axis.cover?(GREEN_UP_TO)
        mark = axis.column(GREEN_UP_TO)
        line[mark] = (line.fetch(mark) == "┬") ? "┼" : "┴"
        rightwards = "└ #{MARK_LABEL}"
        mark_label = if mark + rightwards.length <= room
          (" " * mark) + rightwards
        else
          "#{MARK_LABEL} ┘".rjust(mark + 1)
        end
      end
      texts = [labels.rstrip, mark_label].compact.reject(&:empty?)
      ["#{"0".rjust(label_width)} └#{line.join}", *texts.map { |text| "#{" " * (label_width + 2)}#{text}" }]
    end
    private_class_method :x_axis

    # Ticks at the multiples of the first of `LINEAR_TICK_STEPS` that is a
    # multiple of the bin width and puts them at least an eighth of the axis
    # apart, with 2 columns more than the longest label.
    sig { params(axis: Axis).returns(T::Hash[String, Float]) }
    def self.linear_ticks(axis)
      bin_width = axis.span / axis.bins
      LINEAR_TICK_STEPS.each do |step|
        next unless (step % bin_width).zero?

        ticks = (0..(axis.high / step).floor).to_h { |multiple| [tick_label(multiple * step), multiple * step] }
        apart = step / bin_width * axis.per_bin
        return ticks if apart >= [(ticks.keys.map(&:length).max || 0) + 2, axis.columns / 8.0].max
      end
      { "0" => 0.0 }
    end
    private_class_method :linear_ticks

    # `BuildLog.format_duration` without the parts that are 0: `30s`, `1m15s`,
    # `10m`, `1h`, `1h30m`.
    sig { params(seconds: Float).returns(String) }
    def self.tick_label(seconds)
      return "0" if seconds.zero?

      BuildLog.format_duration(seconds).sub(/\A0m0?/, "").delete_suffix("00s").delete_suffix("00m")
    end
    private_class_method :tick_label

    # A bar of a timeline from `from` to `to` seconds on a linear axis of
    # `span` seconds across `columns`: the spaces before it, then `char` in
    # every column it touches, at least one, so a bar too short to see, or a
    # mark with no length, is still drawn. With `paint`, the bar is painted
    # in `style`.
    sig {
      params(from: Float, to: Float, span: Float, columns: Integer, char: String, style: T.nilable(Symbol),
             paint: T.nilable(Paint)).returns(String)
    }
    def self.timeline_bar(from, to, span:, columns:, char: "█", style: nil, paint: nil)
      scale = span.positive? ? columns / span : 0.0
      first = (from * scale).floor.clamp(0, columns - 1)
      last = (to * scale).ceil.clamp(first + 1, columns)
      bar = char * (last - first)
      "#{" " * first}#{(style && paint) ? paint.call(bar, style) : bar}"
    end

    sig { params(cells: T::Array[Cell], paint: T.nilable(Paint)).returns(String) }
    def self.paint_cells(cells, paint)
      cells.chunk_while { |before, after| before.last == after.last }.map do |run|
        text = run.map(&:first).join
        style = run.fetch(0).last
        (style && paint) ? paint.call(text, style) : text
      end.join
    end
    private_class_method :paint_cells
  end
end
