# typed: true
# frozen_string_literal: true

require_relative "../../cmd/build-times"

RSpec.describe Homebrew::Cmd::BuildTimes do
  let(:fixture) { Pathname(__FILE__).dirname.parent/"fixtures/build-log.json" }
  let(:database) { Pathname(ENV.fetch("HOMEBREW_USER_CONFIG_HOME"))/"build-log.json" }

  before do
    database.dirname.mkpath
    FileUtils.cp fixture, database
  end

  describe "stats" do
    # `openexr` has built and poured builds, which get a row each and are
    # never mixed.
    let(:table) do
      <<~EOS
        formula                      kind     n   median     mean     mode    stdev  estimate  last
        asciidoc                     poured   1    0m01s    0m01s    0m00s    0m00s     0m01s  10.2.1_1 poured 2026-09-24
        awscli                       built    3    3m11s    3m15s    3m00s    0m09s     3m28s  2.37.3 built 2026-09-26
        llvm                         built    1    1h26m    1h26m    1h26m    0m00s     1h26m  23.1.2 built 2026-09-25
        openexr                      built    1    1m06s    1m06s    1m00s    0m00s     1m06s  3.5.1 poured 2026-09-27
        openexr                      poured   1    0m03s    0m03s    0m00s    0m00s     0m03s  3.5.1 poured 2026-09-27
        wget                         poured   1    0m20s    0m20s    0m00s    0m00s     0m20s  1.25.1 failed 2026-09-27
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
        .to output(/^mixed +built .*  3 failed 2026-09-29\nmixed +poured .*  3 failed 2026-09-29\n/).to_stdout
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

    it "handles a missing database" do
      database.delete
      expect { described_class.new(%w[stats]).run }
        .to output("#{table.lines.first}fallback for unknown formulae (median of per-package means): 10m00s\n")
        .to_stdout
    end
  end

  describe "help" do
    let(:help) { described_class.parser.generate_help_text(remaining_args: []).gsub(/\s+/, " ") }

    it "gives each subcommand a complete one-line summary" do
      summaries = {
        "stats" => "Show build time statistics and estimates for formula or every logged formula.",
        "note"  => "Append text to the problems recorded for the latest logged build of formula.",
      }
      found = summaries.to_h { |subcommand, summary| [subcommand, help[/#{subcommand}: #{Regexp.escape(summary)}/]] }
      expect(found).to eq(summaries.to_h { |subcommand, summary| [subcommand, "#{subcommand}: #{summary}"] })
    end

    it "shows the usual `[subcommand]` usage and the description in `docs/build-times.md`", :aggregate_failures do
      expect(help).to start_with("Usage: brew build-times [subcommand] ")
      expect(help)
        .to include("Show and annotate the log of how long formulae took to build from source or to pour a bottle. " \
                    "brew upgrade-timed uses it to order its batches.")
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
end
