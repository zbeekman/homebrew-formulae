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

  describe ".quartile_cuts" do
    it "is the first, second and third quartiles, interpolated between the values" do
      cuts = { "four" => [1.0, 2.0, 3.0, 4.0], "unsorted" => [40.0, 10.0, 30.0, 20.0, 50.0] }
             .transform_values { |values| described_class.quartile_cuts(values) }
      expect(cuts).to eq("four" => [1.75, 2.5, 3.25], "unsorted" => [20.0, 30.0, 40.0])
    end

    it "is nil for fewer than 4 values" do
      cuts = [[], [1.0], [1.0, 2.0], [1.0, 2.0, 3.0]].map { |values| described_class.quartile_cuts(values) }
      expect(cuts).to eq([nil] * 4)
    end

    it "is the value repeated for equal values" do
      expect(described_class.quartile_cuts([5.0] * 4)).to eq([5.0, 5.0, 5.0])
    end
  end

  describe ".band with cuts" do
    let(:cuts) { [10.0, 20.0, 30.0] }

    it "is blue up to the first cut, green, yellow, then red above the third, ignoring the fixed bands" do
      bands = [1.0, 10.0, 10.1, 20.0, 20.1, 30.0, 30.1, 86_400.0]
              .to_h { |seconds| [seconds, described_class.band(seconds, cuts:)] }
      expect(bands).to eq(1.0 => :blue, 10.0 => :blue, 10.1 => :green, 20.0 => :green, 20.1 => :yellow,
                          30.0 => :yellow, 30.1 => :red, 86_400.0 => :red)
    end

    it "uses the fixed bands with nil cuts" do
      expect(described_class.band(100.0, cuts: nil)).to eq(:yellow)
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

    it "paints each block by the quartile of its build with `cuts`, and × red" do
      paint = ->(text, style) { "<#{style}:#{text}>" }
      expect(spark(10.0, nil, 100.0, 700.0, 1000.0, paint:, cuts: [20.0, 500.0, 900.0]))
        .to eq("<blue:▁><red:×><green:▅><yellow:▇><red:█>")
    end
  end

  describe ".histogram" do
    # Two builds of 10 s and one of 1000 s at 40 columns: 3 bins of 12 columns
    # over 10 s to 1000 s, after a gutter of 3 for the counts and the axis.
    let(:three) do
      [
        "2 ┤████████████",
        *["  │████████████"] * 4,
        *["  │████████████            ████████████"] * 5,
        "0 └┬─────────────┬┴────────────────┬───",
        "   10s           1m                10m",
        "                  └ 75s batch split",
      ]
    end

    it "draws a bar per log-spaced bin, the count up, ticks within the range and the 75 s mark" do
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40)).to eq(three)
    end

    it "draws no wider than 40 columns, however narrow the terminal" do
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 10)).to eq(three)
    end

    it "widens the bins to fill a wide terminal" do
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 80).fetch(9))
        .to eq("  │█████████████████████████                         █████████████████████████")
    end

    # 10 values: 5 bins (2 per cube root of the number of values) of 7 columns.
    it "draws a bar's top in eighths of a row" do
      lines = described_class.histogram([*[10.0] * 9, 1000.0], width: 40)
      expect(lines.values_at(8, 9))
        .to eq(["   │███████                     ▁▁▁▁▁▁▁",
                "   │███████                     ███████"])
    end

    # 200 values: at least 12 bins, so 17 of 2 columns.
    it "draws more bins than that when they fill the width evenly, and a bar for any count" do
      lines = described_class.histogram([*[10.0] * 199, 1000.0], width: 40)
      expect(lines.fetch(9)).to eq("    │██                              ▁▁")
    end

    it "marks 75 s with `┴` in the axis only, under a bar as high as the plot, and labels it on a row of its own" do
      expect(described_class.histogram([70.0, 75.0, 75.0, 80.0], width: 40).values_at(0, -2, -1))
        .to eq(["2 ┤                  █████████",
                "0 └──────────────────┴─────────────────",
                "                     └ 75s batch split"])
    end

    # 75 s is in the same column as the 1m tick here.
    it "labels every tick in the range, skipping a label that would touch the one before, and `┼` a tick at 75 s" do
      expect(described_class.histogram([0.01, 600_000.0], width: 40).last(3))
        .to eq(["0 └─────────┬───┬───┼────┬──┬────┬─────",
                "            1s  10s 1m   10m     10h",
                "                    └ 75s batch split"])
    end

    # 75 s is in the 35th of 36 columns, too far right for the label to go
    # right of it.
    it "ends the label of the mark at it when it does not fit to the right" do
      expect(described_class.histogram([10.0, 80.0], width: 40).last(3))
        .to eq(["0 └┬──────────────────────────────┬──┴─",
                "   10s                            1m",
                "                     75s batch split ┘"])
    end

    it "adds no row for the mark when 75 s is out of the range" do
      rows = { "ticks" => [5.0, 20.0], "no ticks" => [1.5, 2.0] }.transform_values do |values|
        described_class.histogram(values, width: 40).length - Timed::Plot::HEIGHT
      end
      expect(rows).to eq("ticks" => 2, "no ticks" => 1)
    end

    it "draws nothing but bars or the curve in the plot, not the mark" do
      plots = [[false, false], [true, false], [false, true], [true, true]].to_h do |smooth, linear|
        lines = described_class.histogram([10.0, 1000.0, 1000.0], width: 40, smooth:, linear:)
        [{ smooth:, linear: }, lines.first(Timed::Plot::HEIGHT).join.scan(/[^ \d┤│▁▂▃▄▅▆▇█⠀-⣿]/).uniq]
      end
      expect(plots).to eq(plots.transform_values { [] })
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
      expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40, paint:).fetch(9))
        .to eq("  │<green:████████████>            <red:████████████>")
    end

    context "with `quartiles`" do
      let(:paint) { ->(text, style) { "<#{style}:#{text}>" } }
      # One value in each of four bins, so each bar is the quartile of its own
      # value (`bar_styles` joins neighbouring bars of one style).
      let(:values) { [10.0, 40.0, 200.0, 1000.0] }

      def bar_styles(lines) = lines.fetch(9).scan(/<(\w+):/).flatten

      it "paints each bar by the quartile of the median of its values" do
        expect(bar_styles(described_class.histogram(values, width: 40, paint:, quartiles: true)))
          .to eq(%w[blue green yellow red])
      end

      it "paints by the fixed bands without it" do
        expect(bar_styles(described_class.histogram(values, width: 40, paint:))).to eq(%w[green yellow red])
      end

      it "falls back to the fixed bands for fewer than 4 values" do
        few = [10.0, 40.0, 1000.0]
        expect(described_class.histogram(few, width: 40, paint:, quartiles: true))
          .to eq(described_class.histogram(few, width: 40, paint:))
      end

      it "paints linear bars too" do
        lines = described_class.histogram([10.0, 20.0, 700.0, 3000.0], width: 40, paint:, quartiles: true,
                                          linear: true)
        expect(bar_styles(lines)).to eq(%w[blue yellow red])
      end

      it "leaves the layout alone, and the curve unpainted" do
        plain = described_class.histogram(values, width: 40, smooth: true)
        expect(described_class.histogram(values, width: 40, smooth: true, paint:, quartiles: true)).to eq(plain)
      end
    end

    # How many rows up the curve reaches in `columns` of the plot, 0 if it is
    # not drawn there.
    def curve_height(lines, columns)
      rows = lines.first(Timed::Plot::HEIGHT).map { |line| line.sub(/\A *\d* [┤│]/, "")[columns].to_s }
      row = rows.index { |cells| cells.match?(/[⠁-⣿]/) }
      row ? Timed::Plot::HEIGHT - row : 0
    end

    describe "with `smooth`" do
      it "draws the curve alone, with no bars" do
        blocks = { "log" => false, "linear" => true }.transform_values do |linear|
          described_class.histogram([*[10.0] * 50, 299.0, 300.0], width: 40, smooth: true, linear:).join[/[▁▂▃▄▅▆▇█]/]
        end
        expect(blocks).to eq("log" => nil, "linear" => nil)
      end

      # 5 in the first of 4 bins, 19 columns wide, and 1 in the last: the
      # curve's peak is the cluster's count, and a lone value takes 2 rows of
      # 10, a count of 1.
      it "draws a tight cluster as high as its count, and a lone value no higher than 1" do
        lines = described_class.histogram([100.0, 101.0, 102.0, 103.0, 104.0, 3600.0], width: 80, smooth: true)
        expect("top" => lines.fetch(0)[0, 3], "cluster" => curve_height(lines, 0...19),
               "lone" => curve_height(lines, 57..))
          .to eq("top" => "5 ┤", "cluster" => 10, "lone" => 2)
      end

      # 20 values of 21.44 s to 21.63 s, either side of the edge of the 2nd
      # and 3rd of 6 bins at 21.54 s.
      it "draws a cluster narrower than a braille dot, as high as its count" do
        values = [1.0, *(-10..9).map { |hundredths| 21.54 + (hundredths / 100.0) }, 10_000.0]
        lines = described_class.histogram(values, width: 40, smooth: true)
        expect("top" => lines.fetch(0)[0, 4], "cluster" => curve_height(lines, 6...18))
          .to eq("top" => "20 ┤", "cluster" => 10)
      end

      # Each of 10 s and 1000 s is at an edge, so a bin's width centred there
      # holds about half of each of them.
      it "draws the kernel density estimate in braille, scaled to the counts, on the axes of the bars" do
        expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40, smooth: true)).to eq(
          [
            "1 ┤⣀⣀",
            "  │  ⠉⠒⠤⡀",
            "  │     ⠈⠢⡀",
            "  │       ⠈⠢⢄",
            "  │          ⠑⢄",
            "  │            ⠑⢄                ⢀⣀⠤⠤⠔⠒",
            "  │              ⠉⠢⢄⡀       ⣀⡠⠤⠒⠉⠁",
            "  │                 ⠈⠉⠒⠒⠒⠒⠉⠉",
            *["  │"] * 2,
            "0 └┬─────────────┬┴────────────────┬───",
            "   10s           1m                10m",
            "                  └ 75s batch split",
          ],
        )
      end

      it "leaves the curve unpainted" do
        paint = ->(text, style) { "<#{style}:#{text}>" }
        expect(described_class.histogram([10.0, 10.0, 1000.0], width: 40, smooth: true, paint:))
          .to eq(described_class.histogram([10.0, 10.0, 1000.0], width: 40, smooth: true))
      end

      it "smooths equal values over the width of a bin" do
        expect(described_class.histogram([30.0, 30.0], width: 40, smooth: true)).to eq(
          [
            "1 ┤",
            "  │",
            "  │             ⣀⡠⠤⠤⠒⠒⠤⠤⢄⣀",
            "  │         ⢀⡠⠔⠉          ⠉⠢⢄⡀",
            "  │       ⡠⠒⠁                ⠈⠒⢄",
            "  │    ⣀⠔⠉                      ⠉⠢⣀",
            "  │ ⢀⠔⠊                            ⠑⠢⡀",
            "  │⠊⠁                                ⠈⠑",
            *["  │"] * 2,
            "0 └───────────────────────────────────┬",
            "                                     1m",
          ],
        )
      end

      # 9 s and 11 s are either side of the edge of two bins, at 10 s; the
      # two of 10 s are at the edge of the plot, so a bin's width centred on
      # them holds about half of each.
      it "tops the y axis at the curve's peak, rounded up, above or below the highest bar" do
        tops = { "straddling" => [1.0, 9.0, 11.0, 100.0], "at the edge" => [10.0, 10.0, 1000.0] }
               .transform_values do |values|
          [false, true].map { |smooth| described_class.histogram(values, width: 40, smooth:).fetch(0)[0, 3] }
        end
        expect(tops).to eq("straddling" => ["1 ┤", "2 ┤"], "at the edge" => ["2 ┤", "1 ┤"])
      end
    end

    describe "with `linear`" do
      def linear(values, width: 40, **options) = described_class.histogram(values, width:, linear: true, **options)

      # The Freedman–Diaconis width, 11m26s, rounds to 10m, but 10m gives 2
      # bins and the Rice rule at least 3, so they are 5m: 4 of 9 columns.
      it "draws equal round-width bins from 0, ticks at round values and the 75 s mark" do
        expect(linear([10.0, 10.0, 1000.0])).to eq(
          [
            "2 ┤█████████",
            *["  │█████████"] * 4,
            *["  │█████████                  █████████"] * 5,
            "0 └┬─┴──────┬────────┬────────┬───────┬",
            "   0        5m       10m      15m   20m",
            "     └ 75s batch split",
          ],
        )
      end

      # Freedman–Diaconis: 1m39s, rounded to 2m; 3000 s is in the 26th bin.
      # 75 s is in the first column, with the 0 tick.
      it "rounds the Freedman–Diaconis width to 1, 2 or 5 seconds, minutes or hours, or 10 or 20" do
        expect(linear([60.0, 60.0, 120.0, 120.0, 180.0, 3000.0]).last(4))
          .to eq(["  │██                       █",
                  "0 └┼────┬────┬────┬────┬────┬",
                  "   0    10m  20m  30m  40m",
                  "   └ 75s batch split"])
      end

      # Freedman–Diaconis: 2 s, but 1801 bins of 2 s do not fit in 37
      # columns; 31 of 2m do.
      it "widens the bins to fit the width" do
        expect(linear([10.0, 11.0, 12.0, 13.0, 3600.0]).last(4))
          .to eq(["  │█                             █",
                  "0 └┼────┬────┬────┬────┬────┬────┬",
                  "   0    10m  20m  30m  40m  50m 1h",
                  "   └ 75s batch split"])
      end

      it "gives values with no interquartile range the Rice rule's number of bins" do
        expect(linear([30.0, 30.0])).to eq(
          [
            "2 ┤                           █████████",
            *["  │                           █████████"] * 9,
            "0 └┬────────┬────────┬────────┬───────┬",
            "   0        10s      20s      30s   40s",
          ],
        )
      end

      it "labels ticks with the parts of the time that are not 0, at a step a multiple of the bin width" do
        labels = {
          "seconds" => [5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 100.0],
          "minutes" => [600.0, 1500.0, 2400.0, 3000.0, 4000.0, 5400.0, 9000.0],
          "hours"   => [3600.0, 7200.0, 36_000.0, 72_000.0],
        }.transform_values { |values| linear(values, width: 80).fetch(-2) }
        expect(labels).to eq(
          "seconds" => "   0        15s      30s      45s      1m       1m15s    1m30s",
          "minutes" => "   0        20m      40m      1h       1h20m    1h40m    2h       2h20m",
          "hours"   => "   0              5h             10h            15h            20h         25h",
        )
      end

      # The first bin, of 0 to 5m, holds two of 10 s.
      it "paints each bar by the band of the median of its values" do
        paint = ->(text, style) { "<#{style}:#{text}>" }
        expect(linear([10.0, 10.0, 1000.0], paint:).fetch(9))
          .to eq("  │<green:█████████>                  <red:█████████>")
      end

      describe "and `smooth`" do
        # The estimate of 10 s, on log seconds, is all within the first 5m,
        # which the curve shows from 0 to 2m30s; beyond, 10 s leaves the bin's
        # width centred on the dot and the curve drops.
        it "fits the estimate on log seconds, so nothing is below 0 s, and shows each bin's expected count" do
          expect(linear([10.0, 10.0, 1000.0], smooth: true)).to eq(
            [
              "3 ┤",
              "  │",
              "  │   ⢀⡀",
              "  │⠒⠉⠉⠁⢸",
              *["  │    ⢸"] * 2,
              *["  │     ⡇"] * 2,
              "  │     ⠱⡀",
              "  │      ⠈⠑⠒⠒⠒⠒⠢⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⢄⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀",
              "0 └┬─┴──────┬────────┬────────┬───────┬",
              "   0        5m       10m      15m   20m",
              "     └ 75s batch split",
            ],
          )
        end

        # 5 in the bin of 1m to 2m, and 1 in the bin of 1h; its estimate is
        # wider than that bin, so about half of it is drawn in one row (of 2
        # for a count of 1).
        it "draws a tight cluster as high as its count, and a lone value no higher than 1" do
          lines = linear([100.0, 101.0, 102.0, 103.0, 104.0, 3600.0], width: 80, smooth: true)
          expect("top" => lines.fetch(0)[0, 3], "cluster" => curve_height(lines, 0...10),
                 "lone" => curve_height(lines, 10..))
            .to eq("top" => "5 ┤", "cluster" => 10, "lone" => 1)
        end

        it "smooths equal values over about the width of a bin at them" do
          expect(linear([30.0, 30.0], smooth: true)).to eq(
            [
              "1 ┤",
              "  │",
              "  │                    ⢀⡠⠒⠉⠉⠉⠒⠢⣀",
              "  │                   ⡠⠃        ⠑⠢⡀",
              "  │                 ⢀⠎            ⠈⠢⣀",
              "  │                ⡠⠃                ⠑⢄",
              "  │               ⡔⠁",
              "  │             ⢠⠊",
              "  │           ⢀⠔⠁",
              "  │       ⣀⣀⠤⠒⠁",
              "0 └┬────────┬────────┬────────┬───────┬",
              "   0        10s      20s      30s   40s",
            ],
          )
        end
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

  describe ".timeline_bar" do
    def bar(from, to, span: 100.0, columns: 10, **options)
      described_class.timeline_bar(from, to, span:, columns:, **options)
    end

    it "scales a bar from its start to its end on a linear axis, the columns it touches filled" do
      bars = { "whole span" => bar(0.0, 100.0), "a quarter in" => bar(25.0, 50.0),
               "on column edges" => bar(20.0, 50.0), "wider axis" => bar(25.0, 50.0, columns: 40) }
      expect(bars).to eq("whole span" => "██████████", "a quarter in" => "  ███", "on column edges" => "  ███",
                         "wider axis" => "#{" " * 10}#{"█" * 10}")
    end

    it "draws a bar shorter than a column, or of no length, as one column, the last one at the end" do
      bars = { "short" => bar(50.0, 50.1), "none" => bar(30.0, 30.0), "at the end" => bar(100.0, 100.0),
               "no span" => bar(0.0, 0.0, span: 0.0) }
      expect(bars).to eq("short" => "     █", "none" => "   █", "at the end" => "         █", "no span" => "█")
    end

    it "draws with another character, and paints only the bar, not the space before it" do
      paint = ->(text, style) { "<#{style}:#{text}>" }
      expect(bar(40.0, 40.0, char: "×", style: :red, paint:)).to eq("    <red:×>")
    end

    it "fits a single column" do
      expect([bar(0.0, 10.0, columns: 1), bar(90.0, 100.0, columns: 1)]).to eq(["█", "█"])
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
