# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require "formula_installer"
require "reinstall"
require "tab"
require_relative "../../lib/timed/receipts"

RSpec.describe Timed::Receipts do
  # Copies of receipts brew wrote: one for a source build, one for a pour.
  let(:fixtures) { Pathname(__FILE__).dirname.parent/"fixtures/receipts" }
  let(:cellar) { mktmpdir/"Cellar" }
  let(:build) do
    { "version" => "0.14.1", "status" => "built", "verb" => "upgrade", "started" => "2026-09-27T20:57:40-04:00",
      "install_seconds" => 39.0, "build_seconds" => 40.0, "wall_seconds" => 41.2, "batch" => "main",
      "log" => "/logs/batch-1.log", "problems" => ["a note"] }
  end
  let(:build_times) do
    { "verb" => "upgrade", "started" => "2026-09-27T20:57:40-04:00", "install_seconds" => 39.0,
      "build_seconds" => 40.0, "wall_seconds" => 41.2 }
  end

  # A keg in `cellar` whose receipt is a copy of `fixture`.
  def receipt(name, version, fixture = "built.json")
    path = cellar/name/version/"INSTALL_RECEIPT.json"
    path.dirname.mkpath
    FileUtils.cp fixtures/fixture, path
    path
  end

  describe ".stamp" do
    it "adds only `build_times`, keeping every other key, in brew's format" do
      stamped = %w[built.json poured.json].to_h do |fixture|
        path = receipt("foo", fixture, fixture)
        described_class.stamp(path, build)
        [fixture, path.read]
      end
      expect(stamped).to eq(%w[built.json poured.json].to_h do |fixture|
        [fixture, JSON.pretty_generate(JSON.parse((fixtures/fixture).read).merge("build_times" => build_times))]
      end)
    end

    it "is tested on receipts in brew's format" do
      formats = %w[built.json poured.json].to_h do |fixture|
        content = (fixtures/fixture).read
        [fixture, JSON.pretty_generate(JSON.parse(content)) == content]
      end
      expect(formats).to eq("built.json" => true, "poured.json" => true)
    end

    it "leaves a receipt brew reads as before" do
      path = receipt("foo", "0.14.1")
      before = Tab.from_file_content(path.read, path).to_json
      described_class.stamp(path, build)
      expect(Tab.from_file_content(path.read, path).to_json).to eq(before)
    end

    it "keeps the receipt's permissions" do
      path = receipt("foo", "0.14.1")
      path.chmod(0640)
      described_class.stamp(path, build)
      expect(path.stat.mode & 0777).to eq(0640)
    end

    it "leaves out durations the build doesn't have" do
      path = receipt("foo", "0.14.1")
      described_class.stamp(path, { "status" => "poured", "install_seconds" => 1.5, "build_seconds" => nil })
      expect(JSON.parse(path.read)["build_times"]).to eq("install_seconds" => 1.5)
    end
  end

  describe ".installed_since?" do
    # The fixtures' install time.
    let(:installed_at) { Time.at(1_790_557_052) }
    let(:foo) do
      formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
      end
    end

    # `foo`'s keg `version`, installed `seconds` after the fixtures' install
    # time, linked into `opt` unless not `opt`.
    def install_foo(seconds, version: "1.0", opt: true)
      keg = HOMEBREW_CELLAR/"foo"/version
      keg.mkpath
      receipt = JSON.parse((fixtures/"built.json").read).merge("time" => installed_at.to_i + seconds)
      receipt["source"]["versions"]["stable"] = "1.0"
      (keg/AbstractTab::FILENAME).write(JSON.pretty_generate(receipt))
      if opt
        (HOMEBREW_PREFIX/"opt").mkpath
        FileUtils.ln_sf keg, HOMEBREW_PREFIX/"opt/foo"
      end
      keg
    end

    it "is whether the receipt of the keg in `opt` says brew installed it at the time given or later" do
      installed = { "later" => 5, "within the same second" => 0, "earlier" => -1, "no receipt" => nil }
      results = installed.to_h do |label, seconds|
        keg = install_foo(seconds || 0)
        (keg/AbstractTab::FILENAME).delete if seconds.nil?
        result = described_class.installed_since?(foo, installed_at + 0.5, before: nil)
        keg.rmtree
        [label, result]
      end
      expect(results).to eq("later" => true, "within the same second" => true, "earlier" => false,
                            "no receipt" => false)
    end

    it "is false for the receipt it had before, even within the same second" do
      install_foo(0)
      before = described_class.receipt_stat(foo)
      expect(described_class.installed_since?(foo, installed_at, before:)).to be(false)
    end

    it "is true for a new receipt written as brew writes one, even with the old one's install time" do
      receipt = install_foo(0)/AbstractTab::FILENAME
      before = described_class.receipt_stat(foo)
      receipt.atomic_write(receipt.read)
      expect(described_class.installed_since?(foo, installed_at, before:)).to be(true)
    end

    it "reads the keg brew reinstalled, not a newer HEAD keg" do
      foo = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
        head "https://brew.sh/foo.git"
      end
      install_foo(-60, version: "HEAD-abc1234", opt: false)
      install_foo(60)
      expect(described_class.installed_since?(foo, installed_at, before: nil)).to be(true)
    end

    it "is false after a failed `brew reinstall`, which puts the old keg back" do
      keg = Keg.new(install_foo(0))
      before = described_class.receipt_stat(foo)
      installer = FormulaInstaller.new(foo)
      allow(installer).to receive(:install) do
        (HOMEBREW_CELLAR/"foo/1.0").mkpath
        raise BuildError.new(foo, "make", [], {})
      end
      context = Homebrew::Reinstall::InstallationContext.new(formula_installer: installer, keg:, formula: foo,
                                                             options: Options.new)
      expect { Homebrew::Reinstall.reinstall_formula(context) }.to raise_error(BuildError)
      expect([(keg/AbstractTab::FILENAME).file?, described_class.installed_since?(foo, installed_at, before:)])
        .to eq([true, false])
    end
  end

  describe ".restamp" do
    let(:pour) { build.merge("status" => "poured", "install_seconds" => 2.0).except("build_seconds") }
    let(:log) do
      Timed::BuildLog.new(
        "schema_version" => 1,
        "packages"       => {
          "foo" => { "builds" => [build.merge("install_seconds" => 10.0), build, pour,
                                  build.merge("version" => "0.14.2", "status" => "failed")] },
          "bar" => { "builds" => [build.merge("version" => "2.0", "status" => "poured")] },
          "baz" => { "builds" => [build.merge("version" => "3.0")] },
        },
      )
    end

    it "stamps installed kegs of logged formulae from the latest successful build of the keg's version" do
      foo = receipt("foo", "0.14.1")
      bar = receipt("bar", "2.0", "poured.json")
      expect(described_class.restamp(log, log.package_names, cellar:)).to eq([bar, foo])
    end

    it "stamps the times of the latest build of the kind the receipt records, source build or pour" do
      stamped = { "built.json" => "0.14.1", "poured.json" => "0.14.1" }.to_h do |fixture, version|
        path = receipt("foo", version, fixture)
        described_class.restamp(log, %w[foo], cellar:)
        times = JSON.parse(path.read)["build_times"]
        path.dirname.rmtree
        [fixture, times]
      end
      expect(stamped).to eq("built.json"  => build_times,
                            "poured.json" => build_times.merge("install_seconds" => 2.0).except("build_seconds"))
    end

    it "leaves alone kegs of other versions, failed builds, kegs without a receipt and formulae not named" do
      kegs = [receipt("foo", "0.14.0"), receipt("foo", "0.14.2"), receipt("bar", "2.0")]
      (cellar/"baz/3.0").mkpath
      expect([described_class.restamp(log, %w[foo baz], cellar:), kegs.map(&:read)])
        .to eq([[], [(fixtures/"built.json").read] * 3])
    end

    it "only touches receipts without build times, so a second run changes nothing" do
      foo = receipt("foo", "0.14.1")
      described_class.restamp(log, %w[foo], cellar:)
      stamped = foo.read
      expect([described_class.restamp(log, %w[foo], cellar:), foo.read]).to eq([[], stamped])
    end

    it "takes full names" do
      foo = receipt("foo", "0.14.1")
      expect(described_class.restamp(log, %w[homebrew/core/foo], cellar:)).to eq([foo])
    end

    it "leaves casks alone" do
      cask = HOMEBREW_PREFIX/"Caskroom/foo/.metadata/INSTALL_RECEIPT.json"
      cask.dirname.mkpath
      FileUtils.cp fixtures/"built.json", cask
      described_class.restamp(log, %w[foo], cellar:)
      expect(cask.read).to eq((fixtures/"built.json").read)
    end

    it "warns about receipts that aren't JSON objects and carries on" do
      broken = [receipt("bar", "2.0"), receipt("baz", "3.0")]
      broken.first.write("{")
      broken.last.write("[]")
      foo = receipt("foo", "0.14.1")
      warnings = broken.map { |path| "Warning: #{path} is not an install receipt; not stamping it.\n" }.join
      expect { expect(described_class.restamp(log, %w[bar baz foo], cellar:)).to eq([foo]) }
        .to output(warnings).to_stderr
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
