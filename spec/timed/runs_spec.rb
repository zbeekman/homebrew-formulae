# typed: true
# frozen_string_literal: true

# Homebrew's own specs turn this cop off ("RSpec helper methods typecheck better
# as regular methods"); the tap's style config does not inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/runs"
require_relative "../../lib/timed/stats_table"

RSpec.describe Timed::Runs do
  # Two runs: an `upgrade` of `fmt`, then an `upgrade` with every kind of
  # batch and a `reinstall` of a broken dependent. The rest is logged before
  # the runner, or without a log.
  let(:log) { Timed::BuildLog.load(Pathname(__FILE__).dirname.parent/"fixtures/runs-build-log.json") }
  let(:runs) { described_class.all(log) }
  let(:latest) { runs.fetch(0) }
  let(:plain) { ->(text, _style) { text } }
  let(:paint) { ->(text, style) { "<#{style}:#{text}>" } }

  # A log with a formula `f<n>` for each of `builds`.
  def log_of(*builds)
    packages = builds.each_with_index.to_h { |build, index| ["f#{index}", { "builds" => [build] }] }
    Timed::BuildLog.new("schema_version" => 1, "packages" => packages)
  end

  def names(runs) = runs.map { |run| [run.id, run.builds.map(&:name)] }

  def run_of(*builds) = Timed::Runs::Run.new(id: "20261001-100000-1", builds:)

  def build(name: "a", status: "built", label: "main", batch: 1, started: 0.0, seconds: 10.0, ended: nil)
    Timed::Runs::Build.new(name:, status:, verb: "install", label:, batch:, started: Time.at(started).utc, seconds:,
                           batch_ended: (Time.at(ended).utc if ended))
  end

  describe ".all" do
    it "groups the builds by run, newest first, in batch order, a call's skipped formulae after its builds, then " \
       "the other skipped formulae" do
      grouped = runs.map { |run| [run.id, run.builds.map { |build| [build.name, build.status, build.batch] }] }
      expect(grouped).to eq(
        [["20261001-100000-222", [["ninja", "poured", 1], ["fmt", "built", 1], ["llvm", "built", 2],
                                  ["qux", "failed", 3], ["quux", "skipped", nil], ["libpng", "built", 4],
                                  ["zlib", "skipped", nil]]],
         ["20260930-090000-111", [["fmt", "built", 1], ["cmake", "skipped", nil]]]],
      )
    end

    it "groups by the run logged with a build, ahead of its log's name, so a run that only skipped is a run" do
      ran = { "status" => "built", "started" => "2026-10-01T10:00:00Z", "run" => "20261001-100000-1",
              "log"    => "/logs/20261001-100000-1-batch1.log" }
      renamed = ran.merge("log" => "/logs/20261001-095959-9-batch2.log", "started" => "2026-10-01T10:00:01Z")
      skipped = { "status" => "skipped", "started" => "2026-10-01T11:00:00Z", "run" => "20261001-110000-2" }
      unmarked = skipped.merge("started" => "2026-10-01T11:30:00Z").except("run")
      expect(names(described_class.all(log_of(ran, renamed, skipped, unmarked))))
        .to eq([["20261001-110000-2", %w[f2 f3]], ["20261001-100000-1", %w[f0 f1]]])
    end

    it "numbers runs that started at the same time by their ids, the later id first" do
      builds = %w[2 1].map do |pid|
        { "status" => "built", "started" => "2026-10-01T10:00:00Z",
          "log"    => "/logs/20261001-100000-#{pid}-batch1.log" }
      end
      expect(described_class.all(log_of(*builds)).map(&:id)).to eq(%w[20261001-100000-2 20261001-100000-1])
    end

    it "puts a skipped formula logged with no run in the latest run that started at or before it, as logged" do
      skipped = { "status" => "skipped", "started" => "2026-10-01T10:00:00+05:00" }
      ran = { "status" => "built", "started" => "2026-10-01T10:00:00+05:00",
              "log"    => "/logs/20261001-100000-1-batch1.log" }
      later = ran.merge("log" => "/logs/20261001-100001-2-batch1.log", "started" => "2026-10-01T10:00:01+05:00")
      expect(names(described_class.all(log_of(skipped, ran, later))))
        .to eq([["20261001-100001-2", ["f2"]], ["20261001-100000-1", %w[f1 f0]]])
    end

    it "leaves out builds with no log of a run, or with a date alone, and skipped ones before every run" do
      grouped = runs.flat_map { |run| run.builds.map { |build| [build.name, build.started.iso8601] } }
      logged = log.package_names.flat_map { |name| log.builds(name).map { |build| [name, build["started"]] } }
      expect(logged - grouped).to eq([%w[asciidoc 2026-09-24], %w[cmake 2026-10-01], %w[llvm 2026-09-25],
                                      %w[wget 2026-09-01T08:00:00-04:00], %w[wget 2026-09-30T09:30:00-04:00]])
    end

    it "puts a build logged with a log of a run but no start, as a failure brew never named once was, at the " \
       "first start in its log, and leaves it out if its log has none" do
      ran = { "status" => "built", "started" => "2026-10-01T10:00:05Z", "wall_seconds" => 10.0,
              "log"    => "/logs/20261001-100000-1-batch1.log" }
      unnamed = { "status" => "failed", "log" => "/logs/20261001-100000-1-batch1.log" }
      alone = unnamed.merge("log" => "/logs/20261001-100000-1-batch2.log")
      placed = described_class.all(log_of(ran, unnamed, alone)).map do |run|
        run.builds.map { |build| [build.name, build.status, build.batch, build.started.iso8601, build.seconds] }
      end
      expect(placed).to eq([[["f0", "built", 1, "2026-10-01T10:00:05Z", 10.0],
                             ["f1", "failed", 1, "2026-10-01T10:00:05Z", nil]]])
    end

    it "orders runs by when they started, not by their logs' names" do
      builds = [["10:00:00", "20261001-235959-1"], ["11:00:00", "20261001-000000-2"]].map do |time, run|
        { "status" => "built", "started" => "2026-10-01T#{time}Z", "log" => "/logs/#{run}-batch1.log" }
      end
      expect(names(described_class.all(log_of(*builds))))
        .to eq([["20261001-000000-2", ["f1"]], ["20261001-235959-1", ["f0"]]])
    end

    it "reads a status, verb or batch label that isn't a string, as nothing checks them, as text" do
      build = { "status" => nil, "verb" => 1, "batch" => 2, "started" => "2026-10-01T10:00:00Z",
                "log"    => "/logs/20261001-100000-1-batch1.log" }
      read = described_class.all(log_of(build)).fetch(0).builds.fetch(0)
      expect([read.status, read.verb, read.label]).to eq(["", "1", "2"])
    end

    it "takes a wall time of 0 with a longer install time as unknown, as logged when brew's dependency heading " \
       "went unread" do
      builds = [[0.0, 92.3], [0.0, nil], [0.0, 0.0], [5.0, 92.3]].map do |wall, install|
        { "status" => "built", "started" => "2026-10-01T10:00:00Z", "wall_seconds" => wall,
          "install_seconds" => install, "log" => "/logs/20261001-100000-1-batch1.log" }.compact
      end
      expect(described_class.all(log_of(*builds)).fetch(0).builds.map(&:seconds)).to eq([nil, 0.0, 0.0, 5.0])
    end

    it "is empty with no runs logged" do
      expect(described_class.all(Timed::BuildLog.new)).to eq([])
    end
  end

  describe "a run" do
    it "runs from the first start to the last finish, skipped formulae aside, the bars covering some of it" do
      expect([latest.started.iso8601, latest.finished.iso8601, latest.length, latest.between])
        .to eq(["2026-10-01T10:00:05-04:00", "2026-10-01T11:04:00-04:00", 3835.0, 80.0])
    end

    it "has the verbs of its calls and the number of builds with each status" do
      counts = %w[built poured failed skipped].to_h { |status| [status, latest.count(status)] }
      expect([latest.verbs, counts])
        .to eq([%w[upgrade reinstall], { "built" => 3, "poured" => 1, "failed" => 1, "skipped" => 2 }])
    end

    it "counts overlapping bars once in the time they cover" do
      builds = [["10:00:00", 60.0], ["10:00:30", 60.0], ["10:00:40", 10.0], ["10:02:00", 30.0]].map do |time, wall|
        { "status" => "built", "started" => "2026-10-01T#{time}Z", "wall_seconds" => wall,
          "log"    => "/logs/20261001-100000-1-batch1.log" }
      end
      run = described_class.all(log_of(*builds)).fetch(0)
      expect([run.length, run.between]).to eq([150.0, 30.0])
    end
  end

  describe ".lines" do
    it "has a header and a line for each run, numbered from the latest" do
      expect(described_class.lines(runs, paint: plain)).to eq(
        ["run  started           verbs              built  poured  failed  skipped   length",
         "  1  2026-10-01 10:00  upgrade,reinstall      3       1       1        2    1h03m",
         "  2  2026-09-30 09:00  upgrade                1       0       0        1    1m00s"],
      )
    end

    it "makes the column names bold and underlined, and paints a number of failed builds other than 0 red" do
      lines = described_class.lines(runs, paint:)
      ends = lines.drop(1).map { |line| line[/ +\S+ +\S+ +\S+\z/] }
      expect([lines.fetch(0)[/\A.*?started>> */], *ends])
        .to eq(["<underline:<bold:run>>  <underline:<bold:started>>           ", "       <red:1>        2    1h03m",
                "       0        1    1m00s"])
    end

    it "marks the length of a run whose end isn't logged, after its last build with no time, as a lower bound, " \
       "but not that of a run that only skipped formulae" do
      single = run_of(build(status: "failed", seconds: nil))
      after = run_of(build, build(name: "b", status: "failed", started: 15.0, seconds: nil))
      skipped = run_of(build(status: "skipped", batch: nil, seconds: nil))
      expect(described_class.lines([after, single, skipped], paint: plain).drop(1).map { |line| line[/ +\S+\z/] })
        .to eq(["   0m15s+", "   0m00s+", "    0m00s"])
    end

    it "marks the length of a run as a lower bound when a build with no time is in the batch of the last finish, " \
       "even if named before it, as when brew names a formula before its dependencies and then it fails" do
      parent = run_of(build(status: "failed", seconds: nil), build(name: "dep", started: 2.0))
      expect(described_class.lines([parent], paint: plain).fetch(1)[/ +\S+\z/]).to eq("   0m12s+")
    end

    it "ends a run when the brew calls of its batches ended, if logged, so a build with no time in them leaves " \
       "its length exact, but not one logged without that" do
      runs = {
        "named before its dependency" => run_of(build(status: "failed", seconds: nil, ended: 30.0),
                                                build(name: "dep", started: 2.0, ended: 30.0)),
        "after the last finish"       => run_of(build(ended: 12.0),
                                                build(name: "b", status: "failed", batch: 2, started: 15.0,
                                                      seconds: nil, ended: 40.0)),
        "only one with no time"       => run_of(build(status: "failed", seconds: nil, ended: 5.0)),
        "logged without it"           => run_of(build(ended: 12.0),
                                                build(name: "b", status: "failed", batch: 2, started: 15.0,
                                                      seconds: nil)),
      }
      expect(runs.transform_values { |run| described_class.lines([run], paint: plain).fetch(1)[/\S+\z/] })
        .to eq("named before its dependency" => "0m30s", "after the last finish" => "0m40s",
               "only one with no time" => "0m05s", "logged without it" => "0m15s+")
    end
  end

  describe ".timeline" do
    # 80 columns: the name, status and time take 27, so the bars have 53.
    it "has a heading for the run and its header, then one for each batch, with a bar for each formula" do
      expect(described_class.timeline(latest, 1, width: 80, paint: plain)).to eq(
        [["Run 1, started 2026-10-01 10:00: upgrade, reinstall", ["formula  status      time  0#{" " * 47}1h03m"]],
         ["Batch 1", ["ninja    poured     0m05s  █", "fmt      built      1m30s  ██"]],
         ["Batch 2 (--last)", ["llvm     built      1h00m   #{"█" * 51}"]],
         ["Then upgrade outdated dependents",
          ["qux      failed         -  #{" " * 51}×", "quux     skipped        -"]],
         ["Then check dependents for broken linkage, and reinstall broken ones from source",
          ["libpng   built      1m00s  #{" " * 52}█"]],
         ["Skipped", ["zlib     skipped        -"]]],
      )
    end

    it "paints the header bold and underlined, and each status and bar in its colour" do
      sections = described_class.timeline(latest, 1, width: 80, paint:)
      expect(sections.values_at(0, 1, 3, 5).map { |_, lines| lines.fetch(0) }).to eq(
        ["<underline:<bold:formula>>  <underline:<bold:status>>      <underline:<bold:time>>  0#{" " * 47}1h03m",
         "ninja    <magenta:poured>     0m05s  <magenta:█>",
         "qux      <red:failed>         -  #{" " * 51}<red:×>",
         "zlib     skipped        -"],
      )
    end

    it "labels the axis of a run whose end isn't logged with its length as a lower bound" do
      run = run_of(build, build(name: "b", status: "failed", started: 15.0, seconds: nil))
      expect(described_class.timeline(run, 1, width: 57, paint: plain).fetch(0))
        .to eq(["Run 1, started 1970-01-01 00:00: install", ["formula  status      time  0#{"0m15s+".rjust(29)}"]])
    end

    it "keeps the bars at least 10 columns wide, however narrow the terminal or long the names" do
      lines = described_class.timeline(run_of(build(name: "a" * 40)), 1, width: 0, paint: plain).flat_map(&:last)
      expect(lines).to eq(["formula#{" " * 35}status      time  0    0m10s",
                           "#{"a" * 40}  built      0m10s  #{"█" * 10}"])
    end

    it "draws a failed build with a time as a bar of ×, and labels a batch of no known kind by its number" do
      run = run_of(build, build(name: "b", status: "failed", label: "other", batch: 2, started: 10.0),
                   build(name: "c", label: nil, batch: 3, started: 20.0))
      sections = described_class.timeline(run, 1, width: 57, paint: plain).drop(1)
      expect(sections).to eq([["Batch 1", ["a        built      0m10s  #{"█" * 10}"]],
                              ["Batch 2 (other)", ["b        failed     0m10s  #{" " * 10}#{"×" * 10}"]],
                              ["Batch 3", ["c        built      0m10s  #{" " * 20}#{"█" * 10}"]]])
    end

    it "draws a build with no time as a single column where it started" do
      run = run_of(build, build(name: "b", started: 15.0, seconds: nil))
      expect(described_class.timeline(run, 1, width: 57, paint: plain).fetch(1))
        .to eq(["Batch 1", ["a        built      0m10s  #{"█" * 20}", "b        built          -  #{" " * 29}█"]])
    end

    it "has no time axis for a run that only skipped formulae, as nothing ran" do
      run = run_of(build(status: "skipped", batch: nil, seconds: nil))
      expect(described_class.timeline(run, 1, width: 80, paint: plain))
        .to eq([["Run 1, started 1970-01-01 00:00: install", ["formula  status      time"]],
                ["Skipped", ["a        skipped        -"]]])
    end

    it "heads a call after the batches that only skipped formulae as that call" do
      run = run_of(build, build(name: "b", status: "skipped", label: "linkage", batch: nil, seconds: nil))
      expect(described_class.timeline(run, 1, width: 57, paint: plain).drop(1))
        .to eq([["Batch 1", ["a        built      0m10s  #{"█" * 30}"]],
                ["Then check dependents for broken linkage, and reinstall broken ones from source",
                 ["b        skipped        -"]]])
    end
  end

  it "keeps the column helpers it shares with `Timed::StatsTable` private" do
    helpers = [:heading, :pad]
    public_helpers = [described_class, Timed::StatsTable].to_h do |table|
      [table, helpers.select { |helper| table.respond_to?(helper) }]
    end
    expect(public_helpers).to eq(described_class => [], Timed::StatsTable => [])
  end

  describe ".total" do
    it "gives the run's length and how much of it is between the bars, which, with a failed build with no " \
       "time, includes that build" do
      expect(described_class.total(latest))
        .to eq(["Total 1h03m, 1m20s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks.",
                "The gaps also include builds with no logged end, such as failed builds."])
    end

    it "says that nothing ran, rather than give a length and gaps, for a run that only skipped formulae" do
      run = Timed::Runs::Run.new(id: "20261001-100000-1", builds: [
        Timed::Runs::Build.new(name: "a", status: "skipped", verb: "install", label: "main", batch: nil,
                               started: Time.at(0).utc, seconds: nil),
      ])
      expect(described_class.total(run)).to eq(["Nothing ran: every formula was skipped."])
    end

    # A run of a build for each `[status, seconds, started, batch]`, started
    # at 0 in batch 1 by default.
    def run_from(*builds)
      run_of(*builds.map do |status, seconds, started, batch|
        build(status:, seconds:, started: started || 0.0, batch: batch || 1)
      end)
    end

    def total_of(*builds) = described_class.total(run_from(*builds))

    it "gives a single failed build's run as at least its length, and says the run's end isn't logged" do
      expect(total_of(["failed", nil]))
        .to eq(["Total at least 0m00s, 0m00s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks.",
                "The run's end isn't logged: a build with no time, such as a failed one,",
                "may have run past the last bar."])
    end

    it "gives a run with a failed build in a batch before the last finish its length, the failure in the gaps" do
      run = run_from(["built", 10.0], ["failed", nil, 12.0], ["built", 10.0, 20.0, 2])
      expect([described_class.lines([run], paint: plain).fetch(1)[/\S+\z/], *described_class.total(run)])
        .to eq(["0m30s", "Total 0m30s, 0m10s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks.",
                "The gaps also include builds with no logged end, such as failed builds."])
    end

    it "gives a run that ends with a failed build after others as at least its length, the failure not in the gaps" do
      expect(total_of(["built", 10.0], ["failed", nil, 15.0]))
        .to eq(["Total at least 0m15s, 0m05s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks.",
                "The run's end isn't logged: a build with no time, such as a failed one,",
                "may have run past the last bar."])
    end

    it "gives a run with a failed build named before the last finish in its batch as at least its length, the " \
       "failure in the gaps and maybe after them" do
      expect(total_of(["failed", nil], ["built", 10.0, 2.0]))
        .to eq(["Total at least 0m12s, 0m02s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks.",
                "The gaps also include builds with no logged end, such as failed builds.",
                "The run's end isn't logged: a build with no time, such as a failed one,",
                "may have run past the last bar."])
    end

    it "gives a run with a failed build named before its dependency, in a batch whose end is logged, its exact " \
       "length, the failure in the gaps" do
      batch = { "log" => "/logs/20261001-100000-1-batch1.log", "batch_ended" => "2026-10-01T10:00:30Z" }
      parent = batch.merge("status" => "failed", "started" => "2026-10-01T10:00:00Z")
      dependency = batch.merge("status" => "built", "started" => "2026-10-01T10:00:02Z", "wall_seconds" => 10.0)
      expect(described_class.total(described_class.all(log_of(parent, dependency)).fetch(0)))
        .to eq(["Total 0m30s, 0m20s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks.",
                "The gaps also include builds with no logged end, such as failed builds."])
    end

    it "gives a run whose last batch made a brew call for each formula its exact length when the batch's end is " \
       "logged, a failure in an earlier call in the gaps, and at least that length when it isn't" do
      totals = [120.0, nil].to_h do |ended|
        run = run_of(build(seconds: 50.0, ended: (50.0 if ended)),
                     build(name: "a", status: "failed", label: "linkage", batch: 2, started: 60.0, seconds: nil,
                           ended:),
                     build(name: "c", label: "linkage", batch: 2, started: 110.0, ended:))
        [ended, described_class.total(run)]
      end
      gaps = ["The gaps between the bars are brew's own work, such as downloads and checks.",
              "The gaps also include builds with no logged end, such as failed builds."]
      expect(totals).to eq(120.0 => ["Total 2m00s, 1m00s of it between the bars.", *gaps],
                           nil   => ["Total at least 2m00s, 1m00s of it between the bars.", *gaps,
                                     *Timed::Runs::OPEN_END])
    end

    it "puts a build with no time before the run's end in the gaps, even after the last known finish, or " \
       "with none known" do
      totals = [[["built", 10.0], ["failed", nil, 15.0], ["failed", nil, 100.0]],
                [["failed", nil], ["failed", nil, 10.0]]].map { |builds| total_of(*builds) }
      footer = ["The gaps between the bars are brew's own work, such as downloads and checks.",
                "The gaps also include builds with no logged end, such as failed builds.",
                "The run's end isn't logged: a build with no time, such as a failed one,",
                "may have run past the last bar."]
      expect(totals).to eq([["Total at least 1m40s, 1m30s of it between the bars.", *footer],
                            ["Total at least 0m10s, 0m10s of it between the bars.", *footer]])
    end

    it "says nothing of builds with no logged end when every build has a time" do
      expect(total_of(["failed", 10.0]))
        .to eq(["Total 0m10s, 0m00s of it between the bars.",
                "The gaps between the bars are brew's own work, such as downloads and checks."])
    end

    it "says that the gaps include a build that didn't fail but has no time" do
      expect(total_of(["built", 10.0], ["built", nil]).fetch(2))
        .to eq("The gaps also include builds with no logged end, such as failed builds.")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
