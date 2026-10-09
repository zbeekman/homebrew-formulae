# typed: strict
# frozen_string_literal: true

require "utils/output"
require_relative "build_log"
require_relative "columns"
require_relative "command"
require_relative "plot"

module Timed
  # The table a `-timed` command prints once its run is done, to show how
  # good the plan's estimates were.
  module EstimatesTable
    extend Columns
    extend Utils::Output::Mixin

    NAME_WIDTH = 28

    # Prints, under a heading, a line for each of `names` (full names, in the
    # plan's order): its estimate, marked as the plan marks it; how long it
    # took (`durations`, by full name), `-` without that; and the error as a
    # share of that time, signed, so an overestimate is positive, `-`
    # without a time or for one shown as `0m00s`. Times are painted in the
    # band of their seconds, and an estimate not from the formula's history
    # also in italics, as `brew build-times stats` paints estimates. Prints
    # nothing without names.
    sig {
      params(names: T::Array[String], estimates: T::Hash[String, Command::Estimate],
             durations: T::Hash[String, Float], paint: Plot::Paint).void
    }
    def self.show(names, estimates, durations, paint: Columns::PAINT)
      return if names.empty?

      oh1 "Estimated and actual times"
      puts [heading("formula", NAME_WIDTH, paint), heading("estimate", 9, paint, right: true),
            heading("actual", 9, paint, right: true), heading("error", 7, paint, right: true)].join(" ")
      names.each do |name|
        estimate = estimates.fetch(name)
        mark = estimate.mark
        actual = durations[name]
        # Rounded as `BuildLog.format_duration` rounds it.
        error = if actual.nil? || actual.round(half: :even).zero?
          "-"
        else
          percent = ((estimate.seconds - actual) / actual * 100).round
          percent.zero? ? "0%" : format("%+d%%", percent)
        end
        puts [
          name.ljust(NAME_WIDTH),
          pad("#{BuildLog.format_duration(estimate.seconds)}#{mark}", 9, paint,
              style: Plot.band(estimate.seconds), right: true, italic: !mark.nil?),
          seconds_cell(actual, paint),
          error.rjust(7),
        ].join(" ")
      end
    end
  end
end
