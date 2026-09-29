# typed: true
# frozen_string_literal: true

require "ask"
require "caveats"
require "cask/cask"
require "cmd/install"
require "cmd/reinstall"
require "cmd/upgrade"
require "messages"
require "open3"
require "tab"

# Canaries: each pins a brew internal the `-timed` commands rely on, so a brew
# change fails here instead of during a real upgrade. When one fails, re-check
# the plan's rule that depends on it before updating the expectation.
RSpec.describe "brew internals", type: :system do
  define_method(:brew_source) { |path| (HOMEBREW_LIBRARY_PATH/path).read }

  # `[command, sudo]` for each `run`/`run!` call with a `sudo:` argument.
  define_method(:sudo_calls) do |path|
    brew_source(path)
      .scan(/\.run!?[\s(]+"([^"]+)"(?:(?!\.run!?[\s(]).)*?sudo:\s*(nil|true)/m)
  end

  # The value of every `sudo:` keyword in the file, whatever the call looks
  # like; shorthand `sudo:` gives `""`.
  define_method(:sudo_values) { |path| brew_source(path).scan(/\bsudo:[ \t]*([^,)\s]*)/).flatten }

  describe "the `cmd_args` block of the wrapped commands" do
    [Homebrew::Cmd::UpgradeCmd, Homebrew::Cmd::InstallCmd, Homebrew::Cmd::Reinstall].each do |command|
      it "is kept by #{command.name} in `@parser_block`" do
        expect(command.instance_variable_get(:@parser_block)).to be_a(Proc)
      end
    end
  end

  describe "Tab" do
    let(:receipt) { mktmpdir/"foo/1.0/INSTALL_RECEIPT.json" }
    let(:content) do
      JSON.pretty_generate("homebrew_version" => "5.0.0", "build_times" => { "wall_seconds" => 1.0 })
    end

    before { receipt.dirname.mkpath }

    it "ignores unknown keys when reading a receipt" do
      expect(Tab.from_file_content(content, receipt).homebrew_version).to eq("5.0.0")
    end

    it "drops unknown keys when writing a receipt" do
      Tab.from_file_content(content, receipt).write
      expect(JSON.parse(receipt.read)).not_to have_key("build_times")
    end

    it "writes receipts with `JSON.pretty_generate`" do
      Tab.from_file_content(content, receipt).write
      expect(receipt.read).to eq(JSON.pretty_generate(JSON.parse(receipt.read)))
    end
  end

  describe "Cask::Artifact::AbstractArtifact#requires_sudo?" do
    define_method(:artifacts) do |&stanza|
      Cask::Cask.new("timed-canary") do
        version "1.0"
        sha256 :no_check
        url "file:///dev/null"
        instance_exec(&stanza)
      end.artifacts
    end

    {
      "pkg"                  => -> { pkg "Foo.pkg" },
      "keyboard_layout"      => -> { keyboard_layout "Foo.bundle" },
      "installer with sudo"  => -> { installer script: { executable: "install.sh", sudo: true } },
      "install step as root" => lambda {
        postflight_steps steps: [{ type: "run", executable: "/usr/bin/true", sudo: true }]
      },
    }.each do |name, stanza|
      it "is true for #{name}" do
        expect(artifacts(&stanza).any?(&:requires_sudo?)).to be(true)
      end
    end

    it "is false for app" do
      expect(artifacts { app "Foo.app" }.any?(&:requires_sudo?)).to be(false)
    end
  end

  it "covers every flight block stanza with Cask::Artifact::AbstractFlightBlock" do
    keys = Cask::DSL::ARTIFACT_BLOCK_CLASSES.flat_map do |klass|
      (klass < Cask::Artifact::AbstractFlightBlock) ? [klass.dsl_key, klass.uninstall_dsl_key] : [klass]
    end
    expect(keys).to contain_exactly(:preflight, :postflight, :uninstall_preflight, :uninstall_postflight)
  end

  describe "cask file-permission sudo fallbacks" do
    {
      "cask/artifact/moved.rb"                   => [["/bin/cp", "nil"], ["/bin/cp", "nil"], ["/bin/cp", "nil"]],
      "cask/artifact/symlinked.rb"               => [["/bin/ln", "nil"]],
      "extend/os/mac/cask/artifact/symlinked.rb" => [["/bin/ln", "nil"]],
      "cask/utils.rb"                            => [["mkdir", "nil"], ["rmdir", "nil"], ["/bin/rm", "nil"],
                                                     ["chown", "true"]],
    }.each do |path, calls|
      it "runs the same commands with `sudo:` in `#{path}`" do
        expect(sudo_calls(path)).to eq(calls)
      end

      it "has no other `sudo:` arguments in `#{path}`" do
        expect(sudo_values(path)).to eq(calls.map(&:last))
      end
    end

    it "still goes through Cask::Utils.gain_permissions_* in `moved.rb` and `symlinked.rb`" do
      helpers = %w[cask/artifact/moved.rb cask/artifact/symlinked.rb extend/os/mac/cask/artifact/symlinked.rb]
                .flat_map { |path| brew_source(path).scan(/Utils\.(gain_permissions_\w+)/).flatten }
      expect(helpers.uniq).to contain_exactly("gain_permissions_mkpath", "gain_permissions_remove")
    end
  end

  it "rolls back a failed cask upgrade" do
    expect(brew_source("cask/upgrade.rb")
      .match?(/^\s*old_cask_installer\.revert_upgrade\(predecessor: new_cask\) if started_upgrade$/))
      .to be(true), "`cask/upgrade.rb` no longer always reverts a started upgrade that failed"
  end

  describe "Homebrew::Ask.confirm?" do
    define_method(:confirmed_on_tty?) do |key|
      allow($stdin).to receive_messages(tty?: true, getch: key)
      allow($stdout).to receive(:tty?).and_return(true)
      Homebrew::Ask.confirm?(action: "upgrade")
    end

    it "returns false without a TTY" do
      allow($stdin).to receive(:tty?).and_return(false)
      expect(Homebrew::Ask.confirm?(action: "upgrade")).to be(false)
    end

    it "returns true on y" do
      expect(confirmed_on_tty?("y")).to be(true)
    end

    it "exits 1 on n" do
      expect { confirmed_on_tty?("n") }.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe "`brew update-if-needed`" do
    define_method(:update_if_needed) do |env|
      script = <<~SH
        brew() { echo "brew $*"; }
        source "#{HOMEBREW_LIBRARY_PATH}/utils/auto-update.sh"
        source "#{HOMEBREW_LIBRARY_PATH}/cmd/update-if-needed.sh"
        homebrew-update-if-needed
        echo "not exec'd"
      SH
      env = { "PATH" => ENV.fetch("PATH"), "HOMEBREW_REPOSITORY" => mktmpdir.to_s, **env }
      Open3.capture2(env, "/bin/bash", "-c", script, unsetenv_others: true).first
    end

    it "updates without `HOMEBREW_AUTO_UPDATE_CHECKED`, and doesn't exec" do
      expect(update_if_needed({})).to eq("brew update --auto-update\nnot exec'd\n")
    end

    it "is a no-op with `HOMEBREW_AUTO_UPDATE_CHECKED` set" do
      expect(update_if_needed("HOMEBREW_AUTO_UPDATE_CHECKED" => "1")).to eq("not exec'd\n")
    end
  end

  it "upgrades keg-only formulae first" do
    expect(brew_source("upgrade.rb")
      .match?(/^\s*formulae_to_install\.replace\(formulae_to_install\.partition\(&:keg_only\?\)\.flatten\(1\)\)$/))
      .to be(true), "`upgrade.rb` no longer moves keg-only formulae to the front"
  end

  it "prints `Installation times` in a fixed format" do
    messages = Messages.new
    messages.package_installed("llvm", 2811.4)
    expect { messages.display_install_times }
      .to output("==> Installation times\nllvm                   2811.400 s\n").to_stdout
  end
end
