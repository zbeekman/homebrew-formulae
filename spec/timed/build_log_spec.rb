# typed: true
# frozen_string_literal: true

require_relative "../../lib/timed/build_log"

RSpec.describe Timed::BuildLog do
  let(:fixture) { Pathname(__FILE__).dirname.parent/"fixtures/build-log.json" }
  let(:path) { mktmpdir/"config/build-log.json" }
  let(:log) { described_class.load(fixture) }

  describe ".default_path" do
    it "is in the user config home" do
      ENV["HOMEBREW_USER_CONFIG_HOME"] = "/some/where"
      expect(described_class.default_path).to eq(Pathname("/some/where/build-log.json"))
    end
  end

  describe ".load" do
    it "is empty when the file does not exist" do
      expect(described_class.load(path).to_h).to eq("schema_version" => 1, "packages" => {})
    end

    it "reads schema version 1" do
      build_counts = log.package_names.to_h { |name| [name, log.builds(name).length] }
      expect(build_counts).to eq("asciidoc" => 1, "awscli" => 3, "llvm" => 1, "openexr" => 2, "wget" => 2)
    end

    it "rejects a newer schema version" do
      path.dirname.mkpath
      path.write('{"schema_version": 2, "packages": {}}')
      expect { described_class.load(path) }.to raise_error(/schema version 2/)
    end

    it "names the file when it is not valid JSON" do
      path.dirname.mkpath
      path.write('{"schema_version": 1, "packages": {')
      expect { described_class.load(path) }.to raise_error(RuntimeError, /#{Regexp.escape(path.to_s)}.*valid JSON/)
    end

    it "names the file when the top level is not an object" do
      path.dirname.mkpath
      path.write("[]")
      expect { described_class.load(path) }.to raise_error(RuntimeError, /#{Regexp.escape(path.to_s)}.*JSON object/)
    end

    it "names the file when `packages` is missing" do
      path.dirname.mkpath
      path.write('{"schema_version": 1}')
      expect { described_class.load(path) }.to raise_error(RuntimeError, /#{Regexp.escape(path.to_s)}.*`packages`/)
    end

    it "names the file when a value cannot be written back as JSON" do
      path.dirname.mkpath
      calls = [-> { described_class.load(path) }, -> { described_class.update(path) { |_log| nil } }]
      contents = [
        '{"schema_version": 1, "packages": {"x": {"builds": [{"version": 1e400}]}}}',
        '{"schema_version": 1, "packages": {}, "x": 1e400}',
      ]
      messages = contents.to_h do |content|
        path.write(content)
        [content, calls.map do |call|
          call.call
          nil
        rescue RuntimeError => e
          e.message.sub(path.to_s, "<path>")
        end]
      end
      message = "<path> is not a build log: Infinity not allowed in JSON"
      expect(messages).to eq(contents.to_h { |content| [content, [message, message]] })
    end

    it "names the file, package and build for every malformed package or build" do
      not_object = "<path> is not a build log: package `x` must be a JSON object with a `builds` array."
      not_build = "<path> is not a build log: build %d of package `x` must be a JSON object."
      not_number = "<path> is not a build log: `%s` of build 0 of package `x` must be a number of seconds " \
                   "from 0 to 604800."
      cases = {
        '{"x": []}'                                                           => not_object,
        '{"x": {}}'                                                           => not_object,
        '{"x": {"builds": {}}}'                                               => not_object,
        '{"x": {"builds": [null]}}'                                           => format(not_build, 0),
        '{"x": {"builds": [{}, 1]}}'                                          => format(not_build, 1),
        '{"x": {"builds": [{"problems": "old"}]}}'                            =>
          "<path> is not a build log: `problems` of build 0 of package `x` must be an array.",
        '{"x": {"builds": [{"started": null}]}}'                              =>
          "<path> is not a build log: `started` of build 0 of package `x` must be a string.",
        '{"x": {"builds": [{"started": 5}]}}'                                 =>
          "<path> is not a build log: `started` of build 0 of package `x` must be a string.",
        '{"x": {"builds": [{"install_seconds": -1}]}}'                        =>
          format(not_number, "install_seconds"),
        %Q({"x": {"builds": [{"build_seconds": 1#{"0" * 400}}]}})             =>
          format(not_number, "build_seconds"),
        '{"x": {"builds": [{"wall_seconds": 604801}]}}'                       =>
          format(not_number, "wall_seconds"),
        '{"x": {"builds": [{"wall_seconds": 1e200}]}}'                        =>
          format(not_number, "wall_seconds"),
        '{"x": {"builds": [{"install_seconds": true}]}}'                      =>
          format(not_number, "install_seconds"),
        '{"x": {"builds": [{"build_seconds": "1"}]}}'                         =>
          format(not_number, "build_seconds"),
        '{"x": {"builds": [{"wall_seconds": []}]}}'                           =>
          format(not_number, "wall_seconds"),
      }
      messages = cases.keys.to_h do |packages|
        path.dirname.mkpath
        path.write(%Q({"schema_version": 1, "packages": #{packages}}))
        message = begin
          described_class.load(path)
          nil
        rescue RuntimeError => e
          e.message.sub(path.to_s, "<path>")
        end
        [packages, message]
      end
      expect(messages).to eq(cases)
    end

    it "accepts a duration of exactly one week" do
      path.dirname.mkpath
      path.write('{"schema_version": 1, "packages": {"x": {"builds": [{"wall_seconds": 604800}]}}}')
      expect { described_class.load(path) }.not_to raise_error
    end

    it "accepts builds with numeric or missing durations and array problems" do
      path.dirname.mkpath
      path.write('{"schema_version": 1, "packages": {"x": {"builds": [{"install_seconds": 1, "wall_seconds": 2.5, ' \
                 '"build_seconds": null, "problems": [], "started": "2026-09-29"}]}}}')
      expect(described_class.load(path).builds("x").length).to eq(1)
    end

    it "names the file when `packages` is not an object" do
      path.dirname.mkpath
      path.write('{"schema_version": 1, "packages": []}')
      expect { described_class.load(path) }.to raise_error(RuntimeError, /#{Regexp.escape(path.to_s)}.*`packages`/)
    end
  end

  describe ".update" do
    let(:change) { ->(log) { log.record("foo", { "version" => "1" }) } }

    it "refuses to write an invalid record, naming the path, package and build, and leaves the file as it was" do
      path.dirname.mkpath
      old_time = Time.utc(2000, 1, 1)
      original = fixture.read
      cases = {
        "problems"        => [{ "problems" => "bad" }, "`problems` of build 0 of package `foo` must be an array."],
        "install_seconds" => [{ "install_seconds" => "1" },
                              "`install_seconds` of build 0 of package `foo` must be a number of seconds " \
                              "from 0 to 604800."],
        "started"         => [{ "started" => 5 }, "`started` of build 0 of package `foo` must be a string."],
        "Rational"        => [{ "wall_seconds" => Rational(1, 2) },
                              "`wall_seconds` of build 0 of package `foo` must be a number of seconds " \
                              "from 0 to 604800."],
        "nesting"         => [{ "version" => (1..150).reduce([]) { |inner, _| [inner] } },
                              "nesting of 100 is too deep. " \
                              "Did you try to serialize objects with circular references?"],
        "Complex"         => [{ "build_seconds" => Complex(1, 2) },
                              "`build_seconds` of build 0 of package `foo` must be a number of seconds " \
                              "from 0 to 604800."],
        "negative"        => [{ "wall_seconds" => -0.5 },
                              "`wall_seconds` of build 0 of package `foo` must be a number of seconds " \
                              "from 0 to 604800."],
        "NaN"             => [{ "install_seconds" => Float::NAN },
                              "`install_seconds` of build 0 of package `foo` must be a number of seconds " \
                              "from 0 to 604800."],
      }
      outcomes = cases.transform_values do |(entry, _message)|
        FileUtils.cp fixture, path
        path.chmod(0644)
        File.utime(old_time, old_time, path)
        message = begin
          described_class.update(path) { |log| log.record("foo", entry) }
          nil
        rescue RuntimeError => e
          e.message.sub(path.realpath.to_s, "<path>")
        end
        [message, path.read == original, path.stat.mode & 0777, path.mtime]
      end
      expected = cases.transform_values do |(_entry, message)|
        ["<path> is not a build log: #{message}", true, 0644, old_time]
      end
      expect(outcomes).to eq(expected)
    end

    it "names the file when a value that is not a duration cannot be written as JSON" do
      path.dirname.mkpath
      FileUtils.cp fixture, path
      expect { described_class.update(path) { |log| log.record("foo", { "version" => Float::NAN }) } }
        .to raise_error(RuntimeError, /#{Regexp.escape(path.realpath.to_s)} is not a build log: .*NaN/)
    end

    it "leaves a malformed file alone and names it", :aggregate_failures do
      path.dirname.mkpath
      path.write("[]")
      expect { described_class.update(path, &change) }.to raise_error(RuntimeError, /#{Regexp.escape(path.to_s)}/)
      expect(path.read).to eq("[]")
    end

    it "keeps the format of a sorted, two-space-indented file" do
      path.dirname.mkpath
      FileUtils.cp fixture, path
      described_class.update(path, &change)
      expect(fixture.read.lines - path.read.lines).to eq([])
    end

    it "sorts keys at every level" do
      path.dirname.mkpath
      FileUtils.cp fixture, path
      described_class.update(path) { |log| log.record("aaa", { "version" => "1", "status" => "built" }) }
      expected = fixture.read.sub(
        %Q(  "packages": {\n),
        %Q(  "packages": {\n    "aaa": {\n      "builds": [\n        {\n          "status": "built",\n) +
        %Q(          "version": "1"\n        }\n      ]\n    },\n),
      )
      expect(path.read).to eq(expected)
    end

    it "replaces the file rather than rewriting it in place" do
      path.dirname.mkpath
      FileUtils.cp fixture, path
      inode = path.stat.ino
      described_class.update(path, &change)
      expect(path.stat.ino).not_to eq(inode)
    end

    context "when the database is a symlink" do
      let(:target) { mktmpdir/"elsewhere/build-log.json" }

      before do
        target.dirname.mkpath
        FileUtils.cp fixture, target
        path.dirname.mkpath
        path.make_symlink(target)
        described_class.update(path, &change)
      end

      it "updates the target" do
        expect(JSON.parse(target.read).fetch("packages")).to have_key("foo")
      end

      it "keeps the symlink" do
        expect(path).to be_a_symlink
      end
    end

    it "writes nothing when the block changes nothing" do
      path.dirname.mkpath
      path.write('{"schema_version":1,"packages":{}}')
      described_class.update(path) { |_log| nil }
      expect(path.read).to eq('{"schema_version":1,"packages":{}}')
    end

    it "does not create the file when the block changes nothing" do
      described_class.update(path) { |_log| nil }
      expect(path).not_to exist
    end

    it "creates the file with mode 0600" do
      described_class.update(path, &change)
      expect(path.stat.mode & 0777).to eq(0600)
    end

    it "forces mode 0600 on an existing file" do
      path.dirname.mkpath
      FileUtils.cp fixture, path
      path.chmod(0644)
      described_class.update(path, &change)
      expect(path.stat.mode & 0777).to eq(0600)
    end

    it "takes a lock file alongside the database" do
      described_class.update(path, &change)
      expect(Pathname("#{path}.lock")).to exist
    end

    it "holds the lock while the block runs" do
      obtained = []
      described_class.update(path) do |_log|
        File.open("#{path}.lock", File::RDWR) do |file|
          obtained << file.flock(File::LOCK_EX | File::LOCK_NB)
        end
      end
      expect(obtained).to eq([false])
    end

    it "does not write when the block raises" do
      expect { described_class.update(path) { |_log| raise "boom" } }.to raise_error("boom")
      expect(path).not_to exist
    end

    it "returns the block's value" do
      expect(described_class.update(path) { |_log| :result }).to eq(:result)
    end

    it "keeps fields it does not know about" do
      path.dirname.mkpath
      path.write('{"schema_version":1,"extra":{"a":1},"packages":{"x":{"note":"y","builds":[{"z":2}]}}}')
      described_class.update(path, &change)
      expect(JSON.parse(path.read)).to include("extra" => { "a" => 1 })
    end
  end

  describe "#record" do
    let(:entry) do
      { "version" => "1.0", "started" => "2026-09-29", "install_seconds" => 5.0, "build_seconds" => nil,
        "problems" => [], "status" => "built", "verb" => "upgrade", "ignored" => "x" }
    end

    it "appends a build under the short formula name, keeping only known non-empty keys" do
      new_log = described_class.new
      new_log.record("homebrew/core/foo", entry)
      expect(new_log.builds("foo")).to eq(
        [{ "version" => "1.0", "started" => "2026-09-29", "install_seconds" => 5.0,
           "status" => "built", "verb" => "upgrade" }],
      )
    end

    it "appends after existing builds" do
      log.record("wget", entry)
      expect(log.builds("wget").length).to eq(3)
    end
  end

  describe "#add_note" do
    it "appends a problem to the latest build" do
      log.add_note("wget", "broke")
      expect(log.builds("wget").last.fetch("problems")).to eq(["broke"])
    end

    it "leaves earlier builds' problems alone" do
      log.add_note("awscli", "more")
      expect(log.builds("awscli")[1].fetch("problems")).to eq(["note with é"])
    end

    it "appends to existing problems" do
      log.add_note("awscli", "first")
      log.add_note("awscli", "second")
      expect(log.builds("awscli").last.fetch("problems")).to eq(["first", "second"])
    end

    it "accepts a tap-qualified name" do
      log.add_note("homebrew/core/wget", "broke")
      expect(log.builds("wget").last.fetch("problems")).to eq(["broke"])
    end

    it "returns nil for a formula with no builds" do
      expect(log.add_note("nope", "x")).to be_nil
    end
  end

  describe "#durations" do
    it "prefers `install_seconds` and falls back to `build_seconds` when it is zero" do
      expect(log.durations("awscli")).to eq([189.52, 190.868, 205.0])
    end

    it "only counts builds of the requested kind" do
      expect(log.durations("openexr", status: "poured")).to eq([3.0])
    end

    it "skips failed builds and builds without a duration" do
      expect(log.durations("wget")).to eq([20.0])
    end

    it "is empty for an unknown formula" do
      expect(log.durations("nope")).to eq([])
    end
  end

  describe ".summarise" do
    it "is nil without samples" do
      expect(described_class.summarise([])).to be_nil
    end

    it "computes count, median, mean, mode (whole minutes) and sample stdev" do
      summary = described_class.summarise([60.0, 120.0, 130.0])
      expect([summary&.n, summary&.median, summary&.mean&.round(3), summary&.mode, summary&.stdev&.round(3)])
        .to eq([3, 120.0, 103.333, 120, 37.859])
    end

    it "takes the smallest mode and rounds half minutes to even" do
      expect(described_class.summarise([30.0, 90.0])&.mode).to eq(0)
    end

    it "has zero stdev for one sample" do
      expect(described_class.summarise([5.0])&.stdev).to eq(0.0)
    end
  end

  describe ".format_duration" do
    it "shows `?` for nil" do
      expect(described_class.format_duration(nil)).to eq("?")
    end

    it "rounds half seconds to even" do
      expect(described_class.format_duration(90.5)).to eq("1m30s")
    end

    it "formats minutes and seconds" do
      expect(described_class.format_duration(191.6)).to eq("3m12s")
    end

    it "formats hours and minutes" do
      expect(described_class.format_duration(5163.1)).to eq("1h26m")
    end

    it "formats under a minute" do
      expect(described_class.format_duration(0.4)).to eq("0m00s")
    end
  end

  describe "#estimate" do
    it "pours: uses the formula's own mean, without a stdev margin" do
      pours = described_class.new(
        "schema_version" => 1,
        "packages"       => {
          "many"  => { "builds" => [10.0, 11.0, 60.0].map { |s| { "status" => "poured", "install_seconds" => s } } },
          "other" => { "builds" => [1.0, 2.0, 3.0].map { |s| { "status" => "poured", "install_seconds" => s } } },
        },
      )
      expect(pours.estimate("many", pour: true)).to eq(27.0)
    end

    it "pours: falls back to the median of all pour times" do
      expect(log.estimate("nope", pour: true)).to eq(3.0)
    end

    it "pours: falls back to 15 seconds without any pour history" do
      expect(described_class.new.estimate("nope", pour: true)).to eq(15.0)
    end

    it "pours: ignores build history" do
      expect(log.estimate("llvm", pour: true)).to eq(3.0)
    end

    it "builds: is mean + 1.5 * stdev" do
      xs = [189.52, 190.868, 205.0]
      mean = xs.sum / 3
      stdev = Math.sqrt(xs.sum { |x| (x - mean)**2 } / 2)
      expect(log.estimate("awscli", pour: false)).to be_within(1e-9).of(mean + (1.5 * stdev))
    end

    it "builds: with one sample is that sample (no NaN stdev margin)" do
      expect(log.estimate("llvm", pour: false)).to eq(5163.1)
    end

    it "builds: with the median estimator is the median" do
      expect(log.estimate("awscli", pour: false, estimator: :median)).to eq(190.868)
    end

    it "builds: ignores pour history" do
      expect(log.estimate("wget", pour: false)).to be_nil
    end

    it "builds: is nil without history so the caller can apply a guess" do
      expect(log.estimate("nope", pour: false)).to be_nil
    end
  end

  describe "#fallback_estimate" do
    it "is the median of per-package mean build times" do
      xs = log.durations("awscli", status: "built")
      expect(log.fallback_estimate).to eq(xs.sum / xs.length)
    end

    it "is ten minutes without any build history" do
      expect(described_class.new.fallback_estimate).to eq(600.0)
    end
  end
end
