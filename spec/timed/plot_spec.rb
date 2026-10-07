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

  describe ".histogram" do
    # Two builds of 10 s and one of 1000 s at 40 columns: 3 bins of 12 columns
    # over 10 s to 1000 s, after a gutter of 3 for the counts and the axis.
    let(:three) do
      [
        "2 ┤████████████   ┊",
        *["  │████████████   ┊"] * 4,
        *["  │████████████   ┊        ████████████"] * 5,
        "0 └┬─────────────┬┊────────────────┬───",
        "   10s           1m                10m",
      ]
    end

    it "draws a bar per log-spaced bin, the count up, ticks within the range and the 75 s mark" do
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40)).to eq(three)
    end

    it "draws no wider than 40 columns, however narrow the terminal" do
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 10)).to eq(three)
    end

    it "widens the bins to fill a wide terminal" do
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 80).fetch(-3))
        .to eq("  │█████████████████████████       ┊                 █████████████████████████")
    end

    # 10 values: 5 bins (2 per cube root of the number of values) of 7 columns.
    it "draws a bar's top in eighths of a row" do
      lines = described_class.histogram([*[10.0] * 9, 1000.0], width: 40)
      expect(lines.values_at(-4, -3))
        .to eq(["   │███████        ┊            ▁▁▁▁▁▁▁",
                "   │███████        ┊            ███████"])
    end

    # 200 values: at least 12 bins, so 17 of 2 columns.
    it "draws more bins than that when they fill the width evenly, and a bar for any count" do
      lines = described_class.histogram([*[10.0] * 199, 1000.0], width: 40)
      expect(lines.fetch(-3)).to eq("    │██            ┊                 ▁▁")
    end

    it "marks 75 s in the axis too, under a bar as high as the plot" do
      expect(described_class.histogram([70.0, 75.0, 75.0, 80.0], width: 40).values_at(0, -1))
        .to eq(["2 ┤                  █████████", "0 └──────────────────┊─────────────────"])
    end

    # 75 s is in the same column as the 1m tick here.
    it "labels every tick in the range, skipping a label that would touch the one before" do
      expect(described_class.histogram([0.01, 600_000.0], width: 40).last(2))
        .to eq(["0 └─────────┬───┬───┬────┬──┬────┬─────",
                "            1s  10s 1m   10m     10h"])
    end

    it "widens the range of equal values to twice and half of them" do
      expect(described_class.histogram([30.0, 30.0], width: 40)).to eq(
        [
          "2 ┤            ████████████",
          *["  │            ████████████"] * 9,
          "0 └───────────────────────────────────┬",
          "                                     1m",
        ],
      )
    end

    it "ticks either edge of the range, as equal values widen it to them" do
      axes = [5.0, 20.0].to_h { |time| [time, described_class.histogram([time, time], width: 40).last(2)] }
      expect(axes).to eq(
        5.0  => ["0 └───────────────────────────────────┬", "                                    10s"],
        20.0 => ["0 └┬───────────────────────────────────", "   10s"],
      )
    end

    it "leaves out the line of labels with no tick in the range" do
      expect(described_class.histogram([1.5, 2.0], width: 40).last).to eq("0 └────────────────────────────────────")
    end

    it "draws nothing without values" do
      expect(described_class.histogram([], width: 40)).to eq([])
    end

    # The middle of the last bin, 316 s, is yellow; its value is red.
    it "paints each bar by the band of the median of its values, and nothing else" do
      paint = ->(text, style) { "<#{style}:#{text}>" }
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40, paint:).fetch(-3))
        .to eq("  │<green:████████████>   ┊        <red:████████████>")
    end

    describe "with `smooth`" do
      # How many rows up the curve reaches in `columns` of the plot, 0 if it
      # is not drawn there.
      def curve_height(lines, columns)
        rows = lines.first(Timed::Plot::HEIGHT).map { |line| line.sub(/\A *\d* [┤│]/, "")[columns].to_s }
        row = rows.index { |cells| cells.match?(/[⠁-⣿]/) }
        row ? Timed::Plot::HEIGHT - row : 0
      end

      # 5 in the first bin of 4, and 1 in the last: the curve is no higher
      # than either bar, so it is all behind them.
      it "draws a tight cluster no higher than its count, and a lone value no higher than 1" do
        values = [100.0, 101.0, 102.0, 103.0, 104.0, 3600.0]
        expect(described_class.histogram(values, width: 80, smooth: true))
          .to eq(described_class.histogram(values, width: 80))
      end

      # 50 of 10 s in the first bin of 4 columns, which the curve crosses.
      it "draws the curve behind the full cells of a bar, so the bar keeps its height" do
        lines = described_class.histogram([*[10.0] * 50, 299.0, 300.0], width: 40, smooth: true)
        expect(lines.first(Timed::Plot::HEIGHT).map { |line| line.sub(/\A *\d* [┤│]/, "")[0, 4] })
          .to eq(["████"] * Timed::Plot::HEIGHT)
      end

      # 20 values of 21.44 s to 21.63 s, either side of the edge of the 2nd
      # and 3rd of 6 bins at 21.54 s, so each bar is about 10 high.
      it "draws a cluster narrower than a braille dot" do
        values = [1.0, *(-10..9).map { |hundredths| 21.54 + (hundredths / 100.0) }, 10_000.0]
        expect(curve_height(described_class.histogram(values, width: 40, smooth: true), 6...18)).to eq(10)
      end

      it "draws the kernel density estimate in braille, behind the bars' full cells, scaled to the counts" do
        expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40, smooth: true)).to eq(
          [
            "2 ┤████████████   ┊",
            *["  │████████████   ┊"] * 4,
            *["  │████████████   ┊        ████████████"] * 2,
            "  │████████████⢄⣀ ┊        ████████████",
            "  │████████████  ⠉⠒⠒⠤⠤⠤⠤⠤⠤⠤████████████",
            "  │████████████   ┊        ████████████",
            "0 └┬─────────────┬┊────────────────┬───",
            "   10s           1m                10m",
          ],
        )
      end

      it "leaves the curve unpainted" do
        paint = ->(text, style) { "<#{style}:#{text}>" }
        expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40, smooth: true, paint:).fetch(-4))
          .to eq("  │<green:████████████>  ⠉⠒⠒⠤⠤⠤⠤⠤⠤⠤<red:████████████>")
      end

      it "smooths equal values over the width of a bin" do
        expect(described_class.histogram([30.0, 30.0], width: 40, smooth: true).values_at(6, 7, 8)).to eq(
          ["  │          ⣀⡠████████████⢄⣀",
           "  │    ⢀⣀⠤⠒⠊⠉  ████████████  ⠉⠑⠒⠤⣀⡀",
           "  │⠤⠔⠒⠉⠁       ████████████       ⠈⠉⠒⠢⠤"],
        )
      end

      # 9 s and 11 s are either side of the edge of two bins, at 10 s.
      it "raises the top of the y axis to the curve's peak, which can be above every bar" do
        values = [1.0, 9.0, 11.0, 100.0]
        tops = [false, true].map { |smooth| described_class.histogram(values, width: 40, smooth:).fetch(0)[0, 3] }
        expect(tops).to eq(["1 ┤", "2 ┤"])
      end
    end
  end

  describe ".bandwidth" do
    it "is Silverman's rule of thumb, from the standard deviation or the interquartile range" do
      bandwidths = { "spread" => [1.0, 2.0, 3.0, 4.0, 5.0], "no IQR" => [*[1.0] * 7, 5.0], "equal" => [3.0, 3.0] }
                   .transform_values { |values| described_class.bandwidth(values)&.round(5) }
      expect(bandwidths).to eq("spread" => 0.97358, "no IQR" => 0.83973, "equal" => nil)
    end
  end

  describe ".count_between" do
    it "is how many of the values a Gaussian kernel density estimate puts between two points" do
      counts = {
        "one, within a bandwidth"               => described_class.count_between([0.0], 1.0, -1.0, 1.0),
        "two, 2 bandwidths to one side of each" => described_class.count_between([0.0, 2.0], 1.0, 0.0, 2.0),
        "three, all of them"                    => described_class.count_between([0.0, 1.0, 2.0], 0.5, -10.0, 10.0),
      }.transform_values { |count| count.round(6) }
      expect(counts).to eq("one, within a bandwidth" => 0.682689, "two, 2 bandwidths to one side of each" => 0.9545,
                           "three, all of them" => 3.0)
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
