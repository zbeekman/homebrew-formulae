# typed: true
# frozen_string_literal: true

# Homebrew's own specs allow this (`Library/Homebrew/test/.rubocop.yml`: RSpec
# helper methods typecheck better as regular methods); tap style doesn't
# inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

require_relative "../../lib/timed/runner"

RSpec.describe Timed::Runner do
  # A batch's output as the runner reads it: each line with when it arrived,
  # unknown for a saved log.
  def fixture_lines(name)
    (Pathname(__FILE__).dirname.parent/"fixtures/batch-logs/#{name}").readlines.map { |line| [line, nil] }
  end

  def built(version, install_seconds, build_seconds)
    { "version" => version, "status" => "built", "install_seconds" => install_seconds,
      "build_seconds" => build_seconds }
  end

  def poured(version, install_seconds)
    { "version" => version, "status" => "poured", "install_seconds" => install_seconds }
  end

  describe ".parse" do
    it "reads a source build's install time, `built in` time and version" do
      expect(described_class.parse(fixture_lines("upgrade-llvm.log"))).to eq(
        "llvm" => { "version" => "23.1.2", "status" => "built", "install_seconds" => 5169.797,
                    "build_seconds" => 5160.0 },
      )
    end

    it "reads every formula of a batch, including those brew installed alongside, from real logs" do
      expected = {
        "upgrade-pour-and-builds.log" => {
          "python-markdown" => poured("3.11", 1.549),
          "virtualenv"      => built("21.12.1", 97.091, 97.0),
          "openexr"         => built("3.5.1", 69.609, 71.0),
        },
        "upgrade-dependencies.log"    => {
          "gumbo-parser" => built("0.14.1", 39.0, 40.0),
          "virtualenv"   => built("21.13.0", 87.201, 88.0),
          "glances"      => built("4.5.7", 212.655, 214.0),
          "asciidoctor"  => poured("2.0.26", 1.411),
          "cpp-httplib"  => poured("0.58.0", 1.091),
          "doctest"      => poured("2.5.3", 1.233),
          "span-lite"    => poured("0.11.0", 1.046),
          "tl-expected"  => poured("1.3.1", 1.08),
          "ccache"       => built("4.14.1", 96.435, 89.0),
          "hunspell"     => built("1.7.4", 67.421, 68.0),
          "liquid-dsp"   => built("1.8.3", 37.721, 38.0),
          "qpdf"         => built("12.4.2", 106.434, 108.0),
          "tcl-tk"       => built("9.0.4_1", 355.928, 360.0),
          "imagemagick"  => built("7.1.2-32", 164.016, 166.0),
        },
        "upgrade-versioned.log"       => {
          "openssl@3" => built("3.6.4_1", 229.274, 237.0),
          "openssl@4" => built("4.0.2_1", 232.797, 242.0),
        },
      }
      expect(expected.to_h { |name, _| [name, described_class.parse(fixture_lines(name))] }).to eq(expected)
    end

    # The failure logs are made up in the format of brew's output, as no real
    # log has a failure.
    it "marks formulae that never finished as failed, with the errors printed while they were running" do
      curl = "`/usr/bin/curl --location https://example.com/tool-2.0.tar.gz`"
      fetch_error = <<~EOS.chomp
        Error: curl: (22) The requested URL returned error: 404
        Failure while executing; #{curl} exited with 22. Here's the output:
        curl: (22) The requested URL returned error: 404
      EOS
      checksum_error = <<~EOS.chomp
        Error: Bottle reports different checksum:   #{"a" * 64}
               SHA-256 checksum of downloaded file: #{"b" * 64}
      EOS
      # The end of the failed build's log, as the start of brew's 15 lines is
      # rarely the error.
      build_error = <<~EOS.chomp
        Last 15 lines from /Users/user/Library/Logs/Homebrew/lib/02.make:
        lib.c:1:10: fatal error: 'missing.h' file not found
            1 | #include <missing.h>
              |          ^~~~~~~~~~~
        1 error generated.
        make: *** [lib.o] Error 1
      EOS
      # A log shorter than brew's 15 lines is printed whole, from its header,
      # and followed by brew's own text, which isn't kept.
      short_build_error = <<~EOS.chomp
        Last 15 lines from /Users/user/Library/Logs/Homebrew/short/01.make:

        make
        install

        make: *** No rule to make target `install`.  Stop.
      EOS
      expect(described_class.parse(fixture_lines("upgrade-failures.log"))).to eq(
        "tool"  => { "status" => "failed", "problems" => [fetch_error] },
        "other" => { "version" => "3.0_1", "status" => "failed", "problems" => [checksum_error] },
        "lib"   => { "status" => "failed", "problems" => [build_error] },
        "short" => { "status" => "failed", "problems" => [short_build_error] },
        "app"   => built("2.0", 125.25, 125.0),
      )
    end

    it "ends a whole short log where brew's own text starts, whatever the tier" do
      log = ["Last 15 lines from /logs/foo/01.make:", "2026-09-30 10:00:00 +0000", "", "make", "",
             "make: *** No rule to make target `install`.  Stop."]
      after = {
        "official tap" => ["", "READ THIS: https://docs.brew.sh/Troubleshooting", "",
                           "These open issues may also help:"],
        "other tap"    => ["", "If reporting this issue please do so to (not Homebrew/* repositories):", "  a/tap"],
        "open issues"  => ["", "", "These open issues may also help:", "foo fails https://github.com/a/tap/issues/1"],
        # Tier 2 or 3 with `HOMEBREW_DEVELOPER`, where the tier notice is left out.
        "no notice"    => ["", "", "Warning: Your Xcode (26.3) is outdated.",
                           "Please update to Xcode 26.6 (or delete it).", "Xcode can be updated from the App Store."],
      }
      problems = after.transform_values do |lines|
        described_class.parse(["==> Upgrading foo", *log, *lines].map { |line| ["#{line}\n", nil] })
                       .dig("foo", "problems")
      end
      expect(problems).to eq(after.transform_values { [[log.fetch(0), *log.last(5)].join("\n")] })
    end

    it "doesn't take other programs' `fatal:` lines for brew's errors" do
      lines = [
        "==> Upgrading app",
        "fatal: not a git repository (or any of the parent directories): .git",
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB, built in 5 seconds",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq("app" => { "version" => "2.0", "status" => "built",
                                                             "build_seconds" => 5.0 })
    end

    it "keeps the error of a failed verbose build, which names its logs" do
      logs = %w[00.options.out 01.configure 01.configure.cc 02.make].map do |log|
        "     /Users/user/Library/Logs/Homebrew/lib/#{log}"
      end
      problem = ["Error: lib 2.0 did not build", "Logs:", *logs].join("\n")
      expect(described_class.parse(fixture_lines("upgrade-verbose-failure.log")))
        .to eq("lib" => { "status" => "failed", "problems" => [problem] })
    end

    it "doesn't blame a formula for errors after its summary line" do
      lines = [
        "==> Upgrading app",
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB, built in 5 seconds",
        "==> Checking for dependents of upgraded formulae...",
        "Error: Not reinstalling 1 broken and outdated, but pinned dependent:",
        "pinned 1.0",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq("app" => { "version" => "2.0", "status" => "built",
                                                             "build_seconds" => 5.0 })
    end

    it "takes a formula's status and build time from its last summary line in the batch" do
      lines = [
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB, built in 5 seconds",
        "🍺  /prefix/Cellar/app/2.0: 12 files, 1.1MB",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq("app" => { "version" => "2.0", "status" => "poured" })
    end

    it "times each formula from when brew first names it to its summary line, from the batch's start" do
      lines = [
        ["==> Upgrading lib\n", 0.5],
        ["  1.0 -> 2.0\n", 0.6],
        ["==> Installing lib dependency: dep\n", 2.0],
        ["🍺  /prefix/Cellar/dep/1.0: 4KB\n", 5.5],
        ["🍺  /prefix/Cellar/lib/2.0: 12 files, 1.1MB, built in 1 minute 1 second\n", 62.25],
        ["==> Installation times\n", 62.5],
        ["dep                       3.200 s\n", 62.5],
        ["lib                      58.100 s\n", 62.5],
      ]
      expect(described_class.parse(lines, started: Time.new(2026, 9, 25, 11, 23, 0, "-04:00"))).to eq(
        "lib" => { "version" => "2.0", "status" => "built", "install_seconds" => 58.1, "build_seconds" => 61.0,
                   "started" => "2026-09-25T11:23:00-04:00", "wall_seconds" => 61.8 },
        "dep" => { "version" => "1.0", "status" => "poured", "install_seconds" => 3.2,
                   "started" => "2026-09-25T11:23:02-04:00", "wall_seconds" => 3.5 },
      )
    end

    it "reads coloured output, tap formulae, options and summaries without the install badge" do
      lines = [
        "==> Upgrading zbeekman/tap/cgns@3.4",
        "/prefix/Cellar/cgns@3.4/3.4.1: 3 files, 12KB, built in 5 seconds",
        "\e[32m==>\e[0m \e[1mReinstalling \e[32mfoo\e[39m \e[0m",
        "==> Installing bar --HEAD",
        "Error: bar: something went wrong",
        "Error: bar: something went wrong",
        "\e[32m==>\e[0m \e[1mInstallation times\e[0m",
        "baz                       1.500 s",
      ].map { |line| ["#{line}\n", nil] }
      expect(described_class.parse(lines)).to eq(
        "cgns@3.4" => { "version" => "3.4.1", "status" => "built", "build_seconds" => 5.0 },
        "foo"      => { "status" => "failed" },
        "bar"      => { "status" => "failed", "problems" => ["Error: bar: something went wrong"] },
        "baz"      => { "status" => "failed", "install_seconds" => 1.5 },
      )
    end

    it "starts a formula it has no time for at the batch's start, and has no wall time for it" do
      lines = fixture_lines("upgrade-llvm.log")
      build = described_class.parse(lines, started: Time.new(2026, 9, 25, 11, 23, 0, "-04:00")).fetch("llvm")
      expect(build.slice("started", "wall_seconds")).to eq("started" => "2026-09-25T11:23:00-04:00")
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
