# typed: true
# frozen_string_literal: true

# Homebrew's own specs turn this cop off ("RSpec helper methods typecheck better
# as regular methods"); the tap's style config does not inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../cmd/build-times"

RSpec.describe Homebrew::Cmd::BuildTimes do
  let(:fixture) { Pathname(__FILE__).dirname.parent/"fixtures/build-log.json" }
  let(:database) { Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json" }

  before do
    database.dirname.mkpath
    FileUtils.cp fixture, database
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe "stats" do
    # `openexr` has built and poured builds, which get a row each and are
    # never mixed.
    let(:table) do
      <<~EOS
        formula                      kind     n   median     mean     mode    stdev  estimate  last                        trend
        asciidoc                     poured   1    0m01s    0m01s    0m00s    0m00s     0m01s  10.2.1_1 poured 2026-09-24  ▄
        awscli                       built    3    3m11s    3m15s    3m00s    0m09s     3m28s  2.37.3 built 2026-09-26     ▄▄▄
        llvm                         built    1    1h26m    1h26m    1h26m    0m00s     1h26m  23.1.2 built 2026-09-25     ▄
        openexr                      built    1    1m06s    1m06s    1m00s    0m00s     1m06s  3.5.1 poured 2026-09-27     ▄
        openexr                      poured   1    0m03s    0m03s    0m00s    0m00s     0m03s  3.5.1 poured 2026-09-27     ▄
        wget                         poured   1    0m20s    0m20s    0m00s    0m00s     0m20s  1.25.1 failed 2026-09-27    ▄×
      EOS
    end

    it "prints a table of every formula, then the fallback estimate, by default" do
      expect { described_class.new(%w[stats]).run }
        .to output("#{table}fallback for unknown formulae (median of per-package means): 3m15s\n").to_stdout
    end

    it "is the default subcommand" do
      expect { described_class.new([]).run }.to output(/^awscli +built +3 /).to_stdout
    end

    it "limits the table to the named formulae, showing unknown ones without history" do
      expect { described_class.new(%w[stats homebrew/core/llvm nope]).run }
        .to output(/\Aformula.*\nllvm .*\nnope +- +0 +- +- +- +- +3m15s\? +\?/).to_stdout
    end

    def stats(*args) = capture_stdout { described_class.new(["stats", *args]).run }

    # Not in alphabetical order, so sorting the names would fail it.
    it "shows a formula named twice, or by its full name too, once, where first named, in the table and in JSON" do
      named = %w[openexr homebrew/core/llvm openexr llvm]
      outputs = [[], %w[--json]].to_h { |json| [json, stats(*json, *named)] }
      rows = JSON.parse(outputs.fetch(%w[--json])).map { |row| row["name"] }
      expect([outputs, rows]).to eq([[[], %w[--json]].to_h { |json| [json, stats(*json, "openexr", "llvm")] },
                                     %w[openexr openexr llvm]])
    end

    it "takes names in any case, as brew does" do
      outputs = [%w[LLVM], %w[homebrew/core/LLVM], %w[--json LLVM]].to_h { |args| [args, stats(*args)] }
      expect(outputs).to eq(%w[LLVM] => stats("llvm"), %w[homebrew/core/LLVM] => stats("llvm"),
                            %w[--json LLVM] => stats("--json", "llvm"))
    end

    it "rejects `--estimator=median` as an invalid option" do
      expect { described_class.new(%w[stats awscli --estimator=median]) }
        .to raise_error(OptionParser::InvalidOption, /estimator/)
    end

    it "marks an estimate that is the fallback with `?`" do
      database.write(JSON.generate(
                       "schema_version" => 1,
                       "packages"       => { "zero" => { "builds" => [{ "status" => "built", "install_seconds" => 0.0,
                                                                        "started" => "2026-09-29",
                                                                        "version" => "1" }] } },
                     ))
      expect { described_class.new(%w[stats]).run }
        .to output(/^zero +built +0 +- +- +- +- +10m00s\? +1 built/).to_stdout
    end

    it "shows the latest build, even a failed one, on the row of each kind" do
      builds = [["built", 60.0, "1"], ["poured", 2.0, "2"], ["failed", nil, "3"]].map do |status, seconds, version|
        { "status" => status, "install_seconds" => seconds, "started" => "2026-09-29", "version" => version }.compact
      end
      database.write(JSON.generate("schema_version" => 1, "packages" => { "mixed" => { "builds" => builds } }))
      expect { described_class.new(%w[stats mixed]).run }
        .to output(/^mixed +built .*  3 failed 2026-09-29  ▄×\nmixed +poured .*  3 failed 2026-09-29  ▄×\n/)
        .to_stdout
    end

    it "marks the estimate of a formula with only failed builds as the fallback" do
      database.write(JSON.generate(
                       "schema_version" => 1,
                       "packages"       => { "bad" => { "builds" => [{ "status"  => "failed",
                                                                       "started" => "2026-09-29",
                                                                       "version" => "1" }] } },
                     ))
      expect { described_class.new(%w[stats]).run }.to output(/^bad +- +0 +- +- +- +- +10m00s\? +1 failed/).to_stdout
    end

    it "draws a formula with only failed builds as `×` in its trend, and one with no builds as `-`" do
      database.write(JSON.generate(
                       "schema_version" => 1,
                       "packages"       => { "bad" => { "builds" => [{ "status" => "failed" }] * 2 } },
                     ))
      expect { described_class.new(%w[stats bad nope]).run }
        .to output(/^bad .*  ××\nnope .*  -\n/).to_stdout
    end

    it "leaves a build with no usable time out of the trend" do
      database.write(JSON.generate(
                       "schema_version" => 1,
                       "packages"       => { "zero" => { "builds" => [{ "status"          => "built",
                                                                        "install_seconds" => 0.0 }] } },
                     ))
      expect { described_class.new(%w[stats]).run }.to output(/^zero .*  -\n/).to_stdout
    end

    describe "colour" do
      def strip(text) = Tty.strip_ansi(text)

      # A column name painted bold and underlined, padded to `width` columns.
      def heading(text, width, right: false)
        gap = " " * (width - text.length)
        painted = "\e[4m\e[1m#{text}\e[0m\e[0m"
        right ? "#{gap}#{painted}" : "#{painted}#{gap}"
      end

      before { ENV["HOMEBREW_COLOR"] = "1" }

      it "makes each column name of the stats header bold and underlined, not the gaps between them" do
        header = capture_stdout { described_class.new(%w[stats wget]).run }.lines.fetch(0)
        columns = [heading("formula", 28), heading("kind", 6), heading("n", 3, right: true),
                   *%w[median mean mode stdev].map { |name| heading(name, 8, right: true) },
                   heading("estimate", 9, right: true)]
        expect(header).to eq("#{columns.join(" ")}  #{heading("last", 24)}  #{heading("trend", 5)}\n")
      end

      it "makes each column name of the LLM estimates header bold and underlined" do
        estimates = { "llvm" => { "version" => "23.1.2", "seconds" => 4800.0, "model" => "m",
                                  "date" => "2026-09-20" } }
        database.write(JSON.generate(JSON.parse(database.read).merge("estimates" => estimates)))
        header = capture_stdout { described_class.new(%w[stats llvm]).run }.lines.fetch(-2)
        expect(header).to eq("#{heading("formula", 28)} #{heading("version", 12)} " \
                             "#{heading("estimate", 9, right: true)} #{heading("actual", 9, right: true)}  " \
                             "#{heading("model", 5)} #{heading("date", 4)}\n")
      end

      it "keeps every column aligned, as the same table without the colour codes" do
        coloured = capture_stdout { described_class.new(%w[stats]).run }
        expect(strip(coloured)).to eq("#{table}fallback for unknown formulae (median of per-package means): 3m15s\n")
      end

      it "paints the kind, the estimate by its band, a failed `last` and the trend" do
        wget = capture_stdout { described_class.new(%w[stats wget]).run }.lines.fetch(1)
        expect(wget).to eq(
          "wget                         \e[35mpoured\e[0m   1    0m20s    0m20s    0m00s    0m00s     " \
          "\e[32m0m20s\e[0m  \e[31m1.25.1 failed 2026-09-27\e[0m  \e[32m▄\e[0m\e[31m×\e[0m\n",
        )
      end

      it "paints built apart from poured, and an estimate in the yellow and red bands" do
        lines = capture_stdout { described_class.new(%w[stats awscli llvm]).run }.lines
        expect(lines.values_at(1, 2).map { |line| [line[/\e\[36mbuilt\e\[0m/], line[/\e\[3[13]m\d\w+\e\[0m  /]] })
          .to eq([["\e[36mbuilt\e[0m", "\e[33m3m28s\e[0m  "], ["\e[36mbuilt\e[0m", "\e[31m1h26m\e[0m  "]])
      end

      it "italicises an estimate that is a guess, keeping the colour of its band" do
        line = capture_stdout { described_class.new(%w[stats nope]).run }.lines.fetch(1)
        expect(line).to include("   \e[3m\e[33m3m15s?\e[0m\e[0m  ?")
      end

      it "paints the `estimate` and `actual` of the LLM estimates by band" do
        estimates = { "llvm" => { "version" => "23.1.2", "seconds" => 4800.0, "model" => "m",
                                  "date" => "2026-09-20" } }
        database.write(JSON.generate(JSON.parse(database.read).merge("estimates" => estimates)))
        line = capture_stdout { described_class.new(%w[stats llvm]).run }.lines.last
        expect(line).to eq("llvm                         23.1.2           \e[31m1h20m\e[0m     \e[31m1h26m\e[0m  " \
                           "m 2026-09-20\n")
      end

      it "stays plain with `HOMEBREW_NO_COLOR`" do
        ENV["HOMEBREW_NO_COLOR"] = "1"
        expect(capture_stdout { described_class.new(%w[stats]).run }).not_to include("\e")
      end
    end

    describe "sorting" do
      def names(*args)
        capture_stdout { described_class.new(["stats", *args]).run }.lines.drop(1).filter_map do |line|
          line[/\A\w+/] unless line.start_with?("fallback")
        end.uniq
      end

      it "keeps the order of the log by default, and of the formulae named" do
        expect([names, names("wget", "awscli")]).to eq([%w[asciidoc awscli llvm openexr wget], %w[wget awscli]])
      end

      it "sorts by name, largest first for numbers and newest first for `last`, with ties by name" do
        keys = %w[name estimate n last]
        expect(keys.to_h { |key| [key, names("--sort=#{key}")] }).to eq(
          "name"     => %w[asciidoc awscli llvm openexr wget],
          "estimate" => %w[llvm awscli openexr wget asciidoc],
          "n"        => %w[awscli asciidoc llvm openexr wget],
          "last"     => %w[openexr wget awscli llvm asciidoc],
        )
      end

      it "sorts by the median and by the mean as well as by the estimate" do
        builds = ->(*seconds) { { "builds" => seconds.map { |s| { "status" => "built", "install_seconds" => s } } } }
        database.write(JSON.generate("schema_version" => 1,
                                     "packages"       => { "x" => builds.call(1.0, 1.0, 100.0),
                                                           "y" => builds.call(30.0, 30.0, 30.0),
                                                           "z" => builds.call(20.0, 20.0, 59.0) }))
        found = %w[median mean estimate].to_h { |key| [key, names("--sort=#{key}")] }
        expect(found).to eq("median" => %w[y z x], "mean" => %w[x z y], "estimate" => %w[x z y])
      end

      it "flips the order with `--reverse`, by name or by any key" do
        expect([names("--reverse"), names("--sort=estimate", "--reverse")])
          .to eq([%w[wget openexr llvm awscli asciidoc], %w[asciidoc wget openexr awscli llvm]])
      end

      it "keeps the built and poured rows of a formula together, in that order" do
        output = capture_stdout { described_class.new(%w[stats --sort=estimate --reverse]).run }
        expect(output.lines.filter_map { |line| line[/\A(openexr) +(\w+)/, 2] }).to eq(%w[built poured])
      end

      it "puts a formula with no history last when sorting by a number, as zero" do
        expect(names("--sort=mean", "nope", "llvm")).to eq(%w[llvm nope])
      end

      it "rejects an unknown key with a usage error naming the valid ones" do
        expect { described_class.new(%w[stats --sort=speed]).run }
          .to raise_error(UsageError, "Invalid usage: `--sort` must be one of name, estimate, median, mean, n, last.")
      end

      it "sorts `last` by the instant of the build, whatever its UTC offset, and date-only values by midnight UTC" do
        stamps = { "a" => "2026-03-01T23:30:00-05:00", "b" => "2026-03-02T01:00:00+00:00", "c" => "2026-03-01" }
        packages = stamps.transform_values do |started|
          { "builds" => [{ "status" => "built", "install_seconds" => 1.0, "started" => started }] }
        end
        database.write(JSON.generate("schema_version" => 1, "packages" => packages))
        expect(names("--sort=last")).to eq(%w[a b c])
      end

      it "does not draw a trend from builds with no status for a row with no kind" do
        builds = [{ "install_seconds" => 100.0 }, { "install_seconds" => 10.0 }]
        database.write(JSON.generate("schema_version" => 1, "packages" => { "a" => { "builds" => builds } }))
        expect { described_class.new(%w[stats]).run }.to output(/^a .*  -\n/).to_stdout
      end
    end

    describe "`--json`" do
      def json(*args) = JSON.parse(capture_stdout { described_class.new(["stats", *args]).run })

      def rows(*args) = json(*args).map { |row| [row["name"], row["kind"]] }

      it "prints a JSON array with a row per row of the table, in `JSON.pretty_generate` form" do
        output = capture_stdout { described_class.new(%w[stats --json wget]).run }
        expect(output).to eq("#{JSON.pretty_generate(JSON.parse(output))}\n")
      end

      it "has the keys, in seconds, and every build of the kind, with the failed build" do
        expect(json("--json", "wget")).to eq(
          [{ "name"   => "wget", "kind" => "poured", "n" => 1, "median" => 20.0, "mean" => 20.0, "stdev" => 0.0,
             "builds" => [
               { "seconds" => 20.0, "date" => "2026-09-27", "version" => "1.25.0", "status" => "poured" },
               { "seconds" => nil, "date" => "2026-09-27", "version" => "1.25.1", "status" => "failed" },
             ] }],
        )
      end

      it "accepts `v1` as the version, as `--json` alone" do
        expect(json("--json=v1", "wget")).to eq(json("--json", "wget"))
      end

      it "rejects any other version with a usage error naming `v1`" do
        expect { described_class.new(%w[stats --json=v2]).run }
          .to raise_error(UsageError, "Invalid usage: invalid JSON version: v2 (use `v1`).")
      end

      it "has a row for every formula and kind, in the order of the table" do
        expect(rows("--json")).to eq([["asciidoc", "poured"], ["awscli", "built"], ["llvm", "built"],
                                      ["openexr", "built"], ["openexr", "poured"], ["wget", "poured"]])
      end

      it "respects the formulae named, `--sort` and `--reverse`" do
        by_flags = [[], ["--sort=n"], ["--reverse"], ["--sort=n", "--reverse"]].to_h do |flags|
          [flags, rows("--json", *flags, "wget", "awscli")]
        end
        wget_first = [["wget", "poured"], ["awscli", "built"]]
        awscli_first = wget_first.reverse
        expected = { [] => wget_first, ["--sort=n"] => awscli_first, ["--reverse"] => awscli_first,
                     ["--sort=n", "--reverse"] => wget_first }
        expect(by_flags).to eq(expected)
      end

      it "sorts as the table does" do
        expect(rows("--json", "--sort=estimate").map(&:first).uniq).to eq(%w[llvm awscli openexr wget asciidoc])
      end

      it "leaves out the fallback line and the LLM estimates, and is never coloured" do
        estimates = { "llvm" => { "version" => "23.1.2", "seconds" => 4800.0, "model" => "m",
                                  "date" => "2026-09-20" } }
        database.write(JSON.generate(JSON.parse(database.read).merge("estimates" => estimates)))
        ENV["HOMEBREW_COLOR"] = "1"
        output = capture_stdout { described_class.new(%w[stats --json llvm]).run }
        expect(output).not_to match(/\e|fallback|LLM|model/)
      end

      it "rejects an unknown `--sort` key as the table does" do
        expect { described_class.new(%w[stats --json --sort=speed]).run }.to raise_error(UsageError, /--sort/)
      end
    end

    describe "LLM estimates" do
      before do
        estimates = {
          "llvm"   => { "version" => "23.1.2", "seconds" => 4800.0, "model" => "claude-haiku-4-5",
                        "date" => "2026-09-20" },
          "awscli" => { "version" => "2.38.0", "seconds" => 120, "model" => "gpt-5-mini", "date" => "2026-09-28" },
          "new"    => { "version" => "1.0", "seconds" => 30, "model" => "qwen2.5:7b", "date" => "2026-09-29" },
        }
        database.write(JSON.generate(JSON.parse(database.read).merge("estimates" => estimates)))
      end

      it "follows the table with each kept estimate and the source build of its version, to compare" do
        expect { described_class.new(%w[stats]).run }.to output(<<~EOS).to_stdout
          #{table.chomp}
          fallback for unknown formulae (median of per-package means): 3m15s
          LLM estimates and the source builds of the same version:
          formula                      version       estimate    actual  model date
          awscli                       2.38.0           2m00s         -  gpt-5-mini 2026-09-28
          llvm                         23.1.2           1h20m     1h26m  claude-haiku-4-5 2026-09-20
          new                          1.0              0m30s         -  qwen2.5:7b 2026-09-29
        EOS
      end

      it "limits the estimates to the named formulae, ending after the fallback when none of them has one",
         :aggregate_failures do
        expect { described_class.new(%w[stats homebrew/core/llvm openexr]).run }
          .to output(/^LLM estimates .*\n.*\nllvm .*\n\z/).to_stdout
        expect { described_class.new(%w[stats openexr]).run }
          .to output(/^fallback for unknown formulae .*\n\z/).to_stdout
      end
    end

    it "handles a missing database" do
      database.delete
      expect { described_class.new(%w[stats]).run }
        .to output("#{table.lines.first.sub(/last +trend/, "last  trend")}" \
                   "fallback for unknown formulae (median of per-package means): 10m00s\n")
        .to_stdout
    end
  end

  describe "histogram" do
    let(:awscli) { [189.52, 190.868, 205.0].sum / 3 }

    before { allow(Tty).to receive(:width).and_return(60) }

    def histogram(*args) = capture_stdout { described_class.new(["histogram", *args]).run }

    def plot(title, values, width: 60, smooth: false, linear: false)
      "#{["==> #{title}", *Timed::Plot.histogram(values, width:, smooth:, linear:)].join("\n")}\n"
    end

    it "plots source builds or pours, by the mean of each formula or every build, under a title" do
      outputs = [[], %w[--builds], %w[--poured], %w[--poured --builds]].to_h { |args| [args, histogram(*args)] }
      expect(outputs).to eq(
        []                    => plot("Mean source build time of 3 formulae, from 1m06s to 1h26m",
                                      [awscli, 5163.1, 66.5]),
        %w[--builds]          => plot("Time of 5 source builds, from 1m06s to 1h26m",
                                      [189.52, 190.868, 205.0, 5163.1, 66.5]),
        %w[--poured]          => plot("Mean pour time of 3 formulae, from 0m01s to 0m20s", [1.408, 3.0, 20.0]),
        %w[--poured --builds] => plot("Time of 3 pours, from 0m01s to 0m20s", [1.408, 3.0, 20.0]),
      )
    end

    it "plots only the formulae named" do
      expect(histogram("awscli", "homebrew/core/llvm", "nope"))
        .to eq(plot("Mean source build time of 2 formulae, from 3m15s to 1h26m", [awscli, 5163.1]))
    end

    it "counts a formula named twice, or by its full name too, once" do
      outputs = [%w[awscli awscli llvm], %w[awscli homebrew/core/awscli llvm], %w[--builds awscli awscli llvm],
                 %w[--builds awscli homebrew/core/awscli llvm]].to_h { |args| [args, histogram(*args)] }
      mean = plot("Mean source build time of 2 formulae, from 3m15s to 1h26m", [awscli, 5163.1])
      builds = plot("Time of 4 source builds, from 3m10s to 1h26m", [189.52, 190.868, 205.0, 5163.1])
      expect(outputs).to eq(
        %w[awscli awscli llvm]                        => mean,
        %w[awscli homebrew/core/awscli llvm]          => mean,
        %w[--builds awscli awscli llvm]               => builds,
        %w[--builds awscli homebrew/core/awscli llvm] => builds,
      )
    end

    it "takes names in any case, as brew does, counting each formula once" do
      outputs = [%w[AwsCli llvm LLVM], %w[--builds AwsCli llvm homebrew/core/LLVM]]
                .to_h { |args| [args, histogram(*args)] }
      mean = plot("Mean source build time of 2 formulae, from 3m15s to 1h26m", [awscli, 5163.1])
      builds = plot("Time of 4 source builds, from 3m10s to 1h26m", [189.52, 190.868, 205.0, 5163.1])
      expect(outputs).to eq(%w[AwsCli llvm LLVM] => mean, %w[--builds AwsCli llvm homebrew/core/LLVM] => builds)
    end

    it "draws the smoothed curve with `--smooth`" do
      expect(histogram("--smooth")).to eq(plot("Mean source build time of 3 formulae, from 1m06s to 1h26m",
                                               [awscli, 5163.1, 66.5], smooth: true))
    end

    it "plots on a linear axis with `--linear`, with the other options" do
      outputs = [%w[--linear], %w[--linear --smooth], %w[--linear --poured --builds]]
                .to_h { |args| [args, histogram(*args)] }
      expect(outputs).to eq(
        %w[--linear]                   => plot("Mean source build time of 3 formulae, from 1m06s to 1h26m",
                                               [awscli, 5163.1, 66.5], linear: true),
        %w[--linear --smooth]          => plot("Mean source build time of 3 formulae, from 1m06s to 1h26m",
                                               [awscli, 5163.1, 66.5], smooth: true, linear: true),
        %w[--linear --poured --builds] => plot("Time of 3 pours, from 0m01s to 0m20s", [1.408, 3.0, 20.0],
                                               linear: true),
      )
    end

    it "fits the width of the terminal" do
      allow(Tty).to receive(:width).and_return(100)
      expect(histogram).to eq(plot("Mean source build time of 3 formulae, from 1m06s to 1h26m",
                                   [awscli, 5163.1, 66.5], width: 100))
    end

    it "says so instead of plotting fewer than 2 times" do
      outputs = [%w[llvm], %w[llvm llvm], %w[--linear llvm], %w[--builds wget], %w[--poured nope]]
                .to_h { |args| [args, histogram(*args)] }
      expect(outputs).to eq(
        %w[llvm]          => "==> No histogram: 1 formula with a source build time, at least 2 are needed\n",
        %w[llvm llvm]     => "==> No histogram: 1 formula with a source build time, at least 2 are needed\n",
        %w[--linear llvm] => "==> No histogram: 1 formula with a source build time, at least 2 are needed\n",
        %w[--builds wget] => "==> No histogram: 0 source builds, at least 2 are needed\n",
        %w[--poured nope] => "==> No histogram: 0 formulae with a pour time, at least 2 are needed\n",
      )
    end

    it "paints the bars by band with colour, the same plot without the colour codes" do
      ENV["HOMEBREW_COLOR"] = "1"
      output = histogram
      expect([output.scan(/\e\[(\d+)m█/).flatten.uniq, Tty.strip_ansi(output)])
        .to eq([%w[33 31], plot("Mean source build time of 3 formulae, from 1m06s to 1h26m",
                                [awscli, 5163.1, 66.5])])
    end
  end

  describe "help" do
    let(:help) { described_class.parser.generate_help_text(remaining_args: []).gsub(/\s+/, " ") }

    it "gives each subcommand a complete one-line summary" do
      summaries = {
        "stats"     => "Show build time statistics and estimates for formula or every logged formula.",
        "histogram" => "Plot a histogram of the source build times of formula or every logged formula.",
        "note"      => "Append text to the problems recorded for the latest logged build of formula.",
        "restamp"   => "Add the logged build times to the install receipts of installed formulae that lack them.",
      }
      found = summaries.to_h { |subcommand, summary| [subcommand, help[/#{subcommand}: #{Regexp.escape(summary)}/]] }
      expect(found).to eq(summaries.to_h { |subcommand, summary| [subcommand, "#{subcommand}: #{summary}"] })
    end

    it "shows the usual `[subcommand]` usage and the description in `docs/build-times.md`", :aggregate_failures do
      expect(help).to start_with("Usage: brew build-times [subcommand] ")
      expect(help)
        .to include("Show and annotate the log of how long formulae took to build from source or to pour a bottle. " \
                    "brew install-timed, brew upgrade-timed and brew reinstall-timed use it to order the formulae " \
                    "they run.")
    end

    it "lists `stats` first" do
      expect(help.index("stats:")).to be < help.index("note:")
    end
  end

  describe "note" do
    it "appends a problem to the formula's latest build" do
      described_class.new(["note", "wget", "needs --with-x"]).run
      expect(JSON.parse(database.read).dig("packages", "wget", "builds", -1, "problems")).to eq(["needs --with-x"])
    end

    it "matches the name as brew does, ignoring case and tap" do
      %w[LLVM homebrew/core/LLVM].each { |name| described_class.new(["note", name, "from #{name}"]).run }
      expect(JSON.parse(database.read).dig("packages", "llvm", "builds", -1, "problems"))
        .to eq(["from LLVM", "from homebrew/core/LLVM"])
    end

    it "fails for a formula with no builds logged" do
      expect { described_class.new(%w[note nope text]).run }
        .to raise_error(SystemExit).and output(/no builds logged for nope/).to_stderr
    end

    it "does not create a database for a formula with no builds logged" do
      database.delete
      expect { described_class.new(%w[note nope text]).run }
        .to raise_error(SystemExit).and output(/no builds logged/).to_stderr
      expect(database).not_to exist
    end

    it "requires a formula and text" do
      expect { described_class.new(%w[note wget]) }.to raise_error(Homebrew::CLI::NumberOfNamedArgumentsError)
    end
  end

  describe "restamp" do
    let(:receipts) { Pathname(__FILE__).dirname.parent/"fixtures/receipts" }
    let(:llvm) { HOMEBREW_CELLAR/"llvm/23.1.2/INSTALL_RECEIPT.json" }
    # Logged as poured.
    let(:openexr) { HOMEBREW_CELLAR/"openexr/3.5.1/INSTALL_RECEIPT.json" }

    before do
      { llvm => "built.json", openexr => "poured.json" }.each do |receipt, fixture|
        receipt.dirname.mkpath
        FileUtils.cp receipts/fixture, receipt
      end
    end

    it "stamps the build times of every logged formula's installed kegs that have none, naming each keg" do
      expect { described_class.new(%w[restamp]).run }
        .to output("==> Restamped #{llvm.dirname}\n==> Restamped #{openexr.dirname}\n").to_stdout
    end

    it "stamps only the named formulae" do
      described_class.new(%w[restamp openexr]).run
      expect([llvm, openexr].map { |receipt| JSON.parse(receipt.read)["build_times"] })
        .to eq([nil, { "started" => "2026-09-27", "install_seconds" => 3.0 }])
    end

    it "says when there is nothing to restamp" do
      described_class.new(%w[restamp]).run
      expect { described_class.new(%w[restamp]).run }.to output("==> No receipts to restamp\n").to_stdout
    end

    it "stamps even with `HOMEBREW_TIMED_NO_STAMP_RECEIPTS`, as it is asked for explicitly" do
      ENV["HOMEBREW_TIMED_NO_STAMP_RECEIPTS"] = "1"
      described_class.new(%w[restamp llvm]).run
      expect(JSON.parse(llvm.read)).to have_key("build_times")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
