# typed: strict
# frozen_string_literal: true

require "utils/tty"
require_relative "plot"

module Timed
  # The columns of the tables of `brew build-times`, for a module to `extend`:
  # padded by their visible text, so painting does not shift them, and painted
  # through Homebrew's `Tty`.
  module Columns
    # The colour of each status of a build: `built` and `poured`, which are
    # also the kinds of `stats`, and `failed`.
    STATUS_STYLES = T.let({ "built" => :cyan, "poured" => :magenta, "failed" => :red }.freeze,
                          T::Hash[String, Symbol])

    # Paints `text` in `style`, one of the bands of `Plot.band`, the colours of
    # `STATUS_STYLES`, `:italic`, `:bold` or `:underline`, through Homebrew's
    # `Tty`, so colour is on only when Homebrew's own output would be coloured.
    PAINT = T.let(
      lambda do |text, style|
        next text unless Tty.color?

        "#{Tty.public_send(style)}#{text}#{Tty.reset}"
      end.freeze,
      Plot::Paint,
    )

    private

    # A column name, bold and underlined, padded to `width` visible characters;
    # the padding is not underlined, so the columns stand apart.
    sig { params(text: String, width: Integer, paint: Plot::Paint, right: T::Boolean).returns(String) }
    def heading(text, width, paint, right: false)
      gap = " " * [width - text.length, 0].max
      painted = paint.call(paint.call(text, :bold), :underline)
      right ? "#{gap}#{painted}" : "#{painted}#{gap}"
    end

    # `text` padded to `width` visible characters; only the text is painted,
    # in `style` and also in italics if `italic`.
    sig {
      params(text: String, width: Integer, paint: Plot::Paint, style: T.nilable(Symbol), right: T::Boolean,
             italic: T::Boolean).returns(String)
    }
    def pad(text, width, paint, style: nil, right: false, italic: false)
      gap = " " * [width - text.length, 0].max
      painted = style ? paint.call(text, style) : text
      painted = paint.call(painted, :italic) if italic
      right ? "#{gap}#{painted}" : "#{painted}#{gap}"
    end
  end
end
