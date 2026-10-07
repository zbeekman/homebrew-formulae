# typed: strict
# frozen_string_literal: true

module Timed
  # Plain-text drawing for `brew build-times`: data and options in, a string
  # out. It does no I/O and never touches the terminal; a caller that wants
  # colour passes a `paint` proc.
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
  end
end
