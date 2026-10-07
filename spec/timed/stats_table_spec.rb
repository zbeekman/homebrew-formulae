# typed: true
# frozen_string_literal: true

# Homebrew's own specs turn this cop off ("RSpec helper methods typecheck better
# as regular methods"); the tap's style config does not inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/stats_table"

RSpec.describe Timed::StatsTable do
  describe ".json_rows" do
    let(:log) do
      Timed::BuildLog.new(
        "schema_version" => Timed::BuildLog::SCHEMA_VERSION,
        "packages"       => {
          "mixed"  => { "builds" => [
            { "build_seconds" => 100.0, "started" => "2026-09-01", "status" => "built", "version" => "1" },
            { "install_seconds" => 4.0, "started" => "2026-09-02T10:00:00-04:00", "status" => "poured",
              "version" => "2" },
            { "started" => "2026-09-03", "status" => "failed", "version" => "3" },
            { "build_seconds" => 300.0, "started" => "2026-09-04", "status" => "built", "version" => "3" },
            { "build_seconds" => 0.0, "install_seconds" => 0.0, "started" => "2026-09-05", "status" => "built",
              "version" => "4" },
          ] },
          "broken" => { "builds" => [{ "started" => "2026-09-06", "status" => "failed", "version" => "1" },
                                     { "started" => "2026-09-07", "version" => "2" }] },
          "empty"  => { "builds" => [] },
        },
      )
    end

    def json_for(*names) = described_class.json_rows(log, names.flat_map { |name| described_class.rows(log, name) })

    it "has an object per row, with the statistics of that kind in seconds" do
      keys = %w[name kind n median mean stdev]
      expect(json_for("mixed").map { |row| row.slice(*keys) }).to eq(
        [{ "name" => "mixed", "kind" => "built", "n" => 2, "median" => 200.0, "mean" => 200.0,
           "stdev" => Timed::BuildLog.summarise([100.0, 300.0])&.stdev },
         { "name" => "mixed", "kind" => "poured", "n" => 1, "median" => 4.0, "mean" => 4.0, "stdev" => 0.0 }],
      )
    end

    it "lists every build of the kind, oldest first, with a failed build in every row" do
      builds = json_for("mixed").to_h { |row| [row["kind"], row["builds"].map { |build| build["version"] }] }
      expect(builds).to eq("built" => %w[1 3 3 4], "poured" => %w[2 3])
    end

    it "gives each build its seconds, its date as logged, its version and its status" do
      expect(json_for("mixed").fetch(0).fetch("builds")).to eq(
        [{ "seconds" => 100.0, "date" => "2026-09-01", "version" => "1", "status" => "built" },
         { "seconds" => nil, "date" => "2026-09-03", "version" => "3", "status" => "failed" },
         { "seconds" => 300.0, "date" => "2026-09-04", "version" => "3", "status" => "built" },
         { "seconds" => nil, "date" => "2026-09-05", "version" => "4", "status" => "built" }],
      )
    end

    it "keeps the date of a build with a time as logged" do
      expect(json_for("mixed").fetch(1).fetch("builds").first)
        .to eq("seconds" => 4.0, "date" => "2026-09-02T10:00:00-04:00", "version" => "2", "status" => "poured")
    end

    it "has a null kind and statistics for a formula with only failed builds" do
      expect(json_for("broken")).to eq(
        [{ "name" => "broken", "kind" => nil, "n" => 0, "median" => nil, "mean" => nil, "stdev" => nil,
           "builds" => [{ "seconds" => nil, "date" => "2026-09-06", "version" => "1", "status" => "failed" }] }],
      )
    end

    it "has no builds and null statistics for an unknown formula" do
      expect(json_for("nope")).to eq(
        [{ "name" => "nope", "kind" => nil, "n" => 0, "median" => nil, "mean" => nil, "stdev" => nil,
           "builds" => [] }],
      )
    end

    it "has the keys in a fixed order" do
      row = json_for("mixed").first
      expect(row.keys).to eq(%w[name kind n median mean stdev builds])
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
