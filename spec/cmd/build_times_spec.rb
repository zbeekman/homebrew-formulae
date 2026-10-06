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
        .to output("#{table.lines.first}fallback for unknown formulae (median of per-package means): 10m00s\n")
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
