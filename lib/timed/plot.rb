# typed: strict
# frozen_string_literal: true

require_relative "build_log"

module Timed
  # Plain-text drawing for `brew build-times`: data, options and a width in,
  # a string or lines out. It does no I/O and never touches the terminal; a
  # caller that wants colour passes a `paint` proc.
  module Plot
    # Paints `text` in a style: `:green`, `:yellow` or `:red`.
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

    sig { params(seconds: Float).returns(Symbol) }
    def self.band(seconds)
      if seconds <= GREEN_UP_TO then :green
      elsif seconds <= YELLOW_UP_TO then :yellow
      else :red
      end
    end

    # One block for each of the latest builds (oldest first), `×` for a failed
    # one (nil), and `-` for none. The blocks are scaled to the range of the
    # builds themselves on a log scale, and a range under 10 % is flat, so
    # noise does not look like a trend. With `paint`, each is painted in the
    # band of its time, and `×` red.
    sig { params(builds: T::Array[T.nilable(Float)], paint: T.nilable(Paint)).returns(String) }
    def self.sparkline(builds, paint: nil)
      latest = builds.last(SPARKLINE_LENGTH)
      return "-" if latest.empty?

      times = latest.compact
      low = times.min || 1.0
      high = times.max || 1.0
      cells = latest.map do |seconds|
        next [FAILED, :red] if seconds.nil?

        [block(seconds, low, high), band(seconds)]
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
    # Drawn at `GREEN_UP_TO` in the cells nothing else is drawn in.
    MARK = "┊"
    # The bit of each dot of a braille character, by row from the top, then
    # by column.
    BRAILLE_BITS = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]].freeze
    BRAILLE_BLANK = 0x2800

    # A character of a plot and the style it is painted in, if any.
    Cell = T.type_alias { [String, T.nilable(Symbol)] }

    # The x axis of a histogram: natural logs of seconds from `low` to `high`
    # across `columns`.
    class Axis < T::Struct
      const :low, Float
      const :high, Float
      const :columns, Integer

      sig { returns(Float) }
      def span = high - low

      # Within rounding error of either edge counts, so a tick exactly at an
      # edge is drawn whichever way the edge was rounded.
      sig { params(log_seconds: Float).returns(T::Boolean) }
      def cover?(log_seconds) = log_seconds.between?(low - 1e-9, high + 1e-9)

      sig { params(log_seconds: Float).returns(Integer) }
      def column(log_seconds) = ((log_seconds - low) / span * columns).floor.clamp(0, columns - 1)
    end
    private_constant :Axis

    # A histogram of `values` (seconds) on a log scale, `width` columns wide
    # (at least `MIN_WIDTH`) and `HEIGHT` rows high, from the shortest value to
    # the longest. There are at least 2 bins per cube root of the number of
    # values, sometimes a few more so the bins fill the width evenly, so a bar
    # is one or more columns wide. The y axis is labelled with the highest
    # count, the x axis with `TICKS` in the range (or at its edges), and
    # `MARK` marks `GREEN_UP_TO`. With `smooth`, a Gaussian kernel density
    # estimate of the log values, on the scale of the bars, is drawn in
    # braille, behind their full cells. With `paint`, each bar is painted in
    # the band of the median of its values.
    sig {
      params(values: T::Array[Float], width: Integer, smooth: T::Boolean, paint: T.nilable(Paint))
        .returns(T::Array[String])
    }
    def self.histogram(values, width:, smooth: false, paint: nil)
      logs = values.map { |seconds| Math.log(seconds) }
      low, high = logs.minmax
      return [] if low.nil? || high.nil?

      if low == high
        low -= Math.log(2)
        high += Math.log(2)
      end
      label_width = values.length.to_s.length
      columns = [width, MIN_WIDTH].max - label_width - 2
      per_bin = [columns / (2 * Math.cbrt(values.length)).ceil, 1].max
      axis = Axis.new(low:, high:, columns: columns - (columns % per_bin))
      binned = Array.new(axis.columns / per_bin) { [] }
      values.each { |seconds| binned.fetch(axis.column(Math.log(seconds)) / per_bin) << seconds }
      curve = smooth ? curve(logs, axis, binned.length) : []
      # Rounded first, so a peak of 1 plus rounding error is not 2.
      top = [*binned.map(&:length), curve.max&.round(6)&.ceil || 0].max.to_i.clamp(1, values.length)

      mark = Math.log(GREEN_UP_TO)
      mark_column = axis.column(mark) if axis.cover?(mark)
      grid = bars(binned, per_bin, top)
      if mark_column
        grid.each { |cells| cells[mark_column] = [MARK, nil] if cells.fetch(mark_column).first == " " }
      end
      draw_curve(grid, curve, top)
      rows = grid.each_with_index.map do |cells, row|
        gutter = row.zero? ? "#{top.to_s.rjust(label_width)} ┤" : "#{" " * label_width} │"
        "#{gutter}#{paint_cells(cells, paint)}".rstrip
      end
      rows + x_axis(axis, label_width, mark_column)
    end

    # Silverman's rule of thumb for the bandwidth of a Gaussian kernel density
    # estimate of `values`: 0.9 times the smaller of their standard deviation
    # and their interquartile range divided by 1.34, or the one that is not
    # zero, times the number of values to the power -1/5. Nil when both are
    # zero, as all the values are equal.
    sig { params(values: T::Array[Float]).returns(T.nilable(Float)) }
    def self.bandwidth(values)
      sorted = values.sort
      quartile = lambda do |fraction|
        position = (sorted.length - 1) * fraction
        lower = sorted.fetch(position.floor)
        lower + ((position - position.floor) * (sorted.fetch(position.ceil) - lower))
      end
      spreads = [BuildLog.stdev(values), (quartile.call(0.75) - quartile.call(0.25)) / 1.34]
      spread = spreads.select(&:positive?).min
      0.9 * spread * (values.length.to_f**-0.2) if spread
    end

    # How many of `values` the Gaussian kernel density estimate of them with
    # `bandwidth` puts between `from` and `to`.
    sig { params(values: T::Array[Float], bandwidth: Float, from: Float, to: Float).returns(Float) }
    def self.count_between(values, bandwidth, from, to)
      scale = bandwidth * Math.sqrt(2)
      values.sum(0.0) { |value| 0.5 * (Math.erf((to - value) / scale) - Math.erf((from - value) / scale)) }
    end

    # The count the kernel density estimate puts in a bin's width centred on
    # each braille dot across the axis (two per column), so the curve is on
    # the scale of the bars: a lone value is never higher than 1, and a
    # cluster narrower than a dot is still drawn.
    sig { params(logs: T::Array[Float], axis: Axis, bins: Integer).returns(T::Array[Float]) }
    def self.curve(logs, axis, bins)
      bin_width = axis.span / bins
      bandwidth = bandwidth(logs) || bin_width
      dots = axis.columns * 2
      (0...dots).map do |dot|
        middle = axis.low + ((dot + 0.5) * axis.span / dots)
        count_between(logs, bandwidth, middle - (bin_width / 2), middle + (bin_width / 2))
      end
    end
    private_class_method :curve

    # The bars as rows of cells, from the top: each bin of `binned` values
    # `per_bin` columns wide and its count over `top` of the height, in eighths
    # of a row, at least one for any count, in the band of the median value.
    sig {
      params(binned: T::Array[T::Array[Float]], per_bin: Integer, top: Integer).returns(T::Array[T::Array[Cell]])
    }
    def self.bars(binned, per_bin, top)
      columns = binned.flat_map do |bin|
        eighths = bin.empty? ? 0 : [(bin.length * HEIGHT * 8.0 / top).round, 1].max
        style = band(BuildLog.median(bin)) unless bin.empty?
        column = (0...HEIGHT).map do |row|
          filled = (eighths - ((HEIGHT - 1 - row) * 8)).clamp(0, 8)
          filled.zero? ? [" ", nil] : [BLOCKS.fetch(filled - 1), style]
        end
        [column] * per_bin
      end
      columns.transpose
    end
    private_class_method :bars

    # Draws `curve` (counts at each dot) in braille over `grid`, each dot
    # column joined to the one before by a vertical run of dots, behind the
    # full cells of the bars, so they keep their height.
    sig { params(grid: T::Array[T::Array[Cell]], curve: T::Array[Float], top: Integer).void }
    def self.draw_curve(grid, curve, top)
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
      bits.each do |(row, column), value|
        cells = grid.fetch(row)
        next if cells.fetch(column).first == BLOCKS.last

        cells[column] = [(BRAILLE_BLANK + value).chr(Encoding::UTF_8), nil]
      end
    end
    private_class_method :draw_curve

    # The axis line, with a tick at each of `TICKS` in the range and `MARK` in
    # `mark_column` unless a tick is there, and the line of their labels, if
    # any: each at its tick or as far right as fits, left out if it would
    # touch the label before.
    sig { params(axis: Axis, label_width: Integer, mark_column: T.nilable(Integer)).returns(T::Array[String]) }
    def self.x_axis(axis, label_width, mark_column)
      line = Array.new(axis.columns, "─")
      line[mark_column] = MARK if mark_column
      labels = " " * axis.columns
      label_end = -2
      TICKS.each do |label, seconds|
        log_seconds = Math.log(seconds)
        next unless axis.cover?(log_seconds)

        column = axis.column(log_seconds)
        line[column] = "┬"
        start = [column, axis.columns - label.length].min
        next if start <= label_end + 1

        labels[start, label.length] = label
        label_end = start + label.length - 1
      end
      axis_line = "#{"0".rjust(label_width)} └#{line.join}"
      labels.strip.empty? ? [axis_line] : [axis_line, "#{" " * (label_width + 2)}#{labels.rstrip}"]
    end
    private_class_method :x_axis

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
