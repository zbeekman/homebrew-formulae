# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/estimates_table"

RSpec.describe Timed::EstimatesTable do
  let(:plain) { ->(text, _style) { text } }

  def estimate(seconds, pour: false, fallback: false, guessed: false)
    Timed::Command::Estimate.new(seconds:, pour:, fallback:, guessed:)
  end

  # The table's lines, each of a name, an estimate, a time and an error.
  def lines(*rows)
    rows.map do |name, estimate, actual, error|
      format("%<name>-28s %<estimate>9s %<actual>9s %<error>7s\n", name:, estimate:, actual:, error:)
    end.join
  end

  def show(estimates, durations, paint: plain)
    described_class.show(estimates.keys, estimates, durations, paint:)
  end

  it "prints, under a heading, each formula's estimate, in the plan's order, with its install time and the " \
     "error, signed, as a share of that time, so an overestimate is positive" do
    estimates = { "over" => estimate(600.0), "under" => estimate(15.0, pour: true), "exact" => estimate(90.0),
                  "near" => estimate(100.0) }
    table = lines(%w[formula estimate actual error], %w[over 10m00s 8m20s +20%], %w[under 0m15s 0m20s -25%],
                  %w[exact 1m30s 1m30s 0%], %w[near 1m40s 1m40s 0%])
    expect { show(estimates, { "under" => 20.0, "over" => 500.0, "exact" => 90.0, "near" => 100.4 }) }
      .to output("==> Estimated and actual times\n#{table}").to_stdout
  end

  it "marks an estimate as the plan does: `?` for a fallback, `*` for `--guess` or an LLM" do
    estimates = { "fallback" => estimate(600.0, fallback: true), "guessed" => estimate(5400.0, guessed: true) }
    expect { show(estimates, { "fallback" => 600.0, "guessed" => 5400.0 }) }
      .to output(end_with(lines(%w[fallback 10m00s? 10m00s 0%], %w[guessed 1h30m* 1h30m 0%]))).to_stdout
  end

  it "shows `-` for the time and error of a formula without one, as it failed, was skipped or brew reported " \
     "none, and for the error of a time shown as `0m00s`, of which a share means nothing" do
    estimates = { "failed" => estimate(100.0), "instant" => estimate(15.0, pour: true),
                  "zero" => estimate(15.0, pour: true) }
    expect { show(estimates, { "instant" => 0.4, "zero" => 0.0 }) }
      .to output(end_with(lines(%w[failed 1m40s - -], %w[instant 0m15s 0m00s -], %w[zero 0m15s 0m00s -])))
      .to_stdout
  end

  it "paints the column names bold and underlined, each time in the band of its seconds, and an estimate not " \
     "from the formula's history also in italics, as `brew build-times stats` does" do
    paint = ->(text, style) { "<#{style}:#{text}>" }
    estimates = { "quick" => estimate(60.0), "slow" => estimate(700.0, fallback: true),
                  "guessed" => estimate(300.0, guessed: true), "failed" => estimate(60.0) }
    expect { show(estimates, { "quick" => 80.0, "slow" => 700.0, "guessed" => 300.0 }, paint:) }
      .to output(<<~EOS).to_stdout
        ==> Estimated and actual times
        <underline:<bold:formula>>                       <underline:<bold:estimate>>    <underline:<bold:actual>>   <underline:<bold:error>>
        quick                            <green:1m00s>     <yellow:1m20s>    -25%
        slow                           <italic:<red:11m40s?>>    <red:11m40s>      0%
        guessed                         <italic:<yellow:5m00s*>>     <yellow:5m00s>      0%
        failed                           <green:1m00s>         -       -
      EOS
  end

  it "prints nothing without formulae" do
    expect { show({}, {}) }.not_to output.to_stdout
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
