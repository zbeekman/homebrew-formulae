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

  describe "help" do
    let(:help) { described_class.parser.generate_help_text(remaining_args: []).gsub(/\s+/, " ") }

    it "gives each subcommand a complete one-line summary" do
      summaries = {
        "stats"   => "Show build time statistics and estimates for formula or every logged formula.",
        "note"    => "Append text to the problems recorded for the latest logged build of formula.",
        "restamp" => "Add the logged build times to the install receipts of installed formulae that lack them.",
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
