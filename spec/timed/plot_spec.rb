# typed: true
# frozen_string_literal: true

# Homebrew's own specs turn this cop off ("RSpec helper methods typecheck better
# as regular methods"); the tap's style config does not inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/plot"

RSpec.describe Timed::Plot do
  describe ".band" do
    it "is green up to 75 s, yellow up to 10 min and red above" do
      bands = [1.0, 75.0, 75.1, 600.0, 600.1, 86_400.0].to_h { |seconds| [seconds, described_class.band(seconds)] }
      expect(bands).to eq(1.0 => :green, 75.0 => :green, 75.1 => :yellow, 600.0 => :yellow, 600.1 => :red,
                          86_400.0 => :red)
    end
  end

  describe ".sparkline" do
    def spark(*builds, **options) = described_class.sparkline(builds, **options)

    it "scales each value on a log scale between the smallest and the largest" do
      expect(spark(1.0, 10.0, 100.0, 1000.0, 10_000.0)).to eq("▁▃▅▆█")
    end

    it "uses every block for a span of 7 decades" do
      expect(spark(*(0..7).map { |decade| 10.0**decade })).to eq("▁▂▃▄▅▆▇█")
    end

    it "draws builds that differ by under 10 % flat" do
      expect(spark(100.0, 105.0, 109.0)).to eq("▄▄▄")
    end

    it "draws builds that differ by 10 % or more with their range" do
      expect(spark(100.0, 110.0)).to eq("▁█")
    end

    it "draws a single build flat" do
      expect(spark(42.0)).to eq("▄")
    end

    it "draws a failed build as ×, outside the range" do
      expect(spark(10.0, nil, 1000.0)).to eq("▁×█")
    end

    it "draws only failed builds as ×" do
      expect(spark(nil, nil)).to eq("××")
    end

    it "is `-` with no builds" do
      expect(spark).to eq("-")
    end

    it "keeps the latest 8 builds, oldest first, and scales them alone" do
      expect(spark(*(0..10).map { |decade| 10.0**(10 - decade) })).to eq("█▇▆▅▄▃▂▁")
    end

    it "paints each block by the band of its build, and × red" do
      paint = ->(text, style) { "<#{style}:#{text}>" }
      expect(spark(10.0, nil, 100.0, 1000.0, paint:)).to eq("<green:▁><red:×><yellow:▅><red:█>")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
