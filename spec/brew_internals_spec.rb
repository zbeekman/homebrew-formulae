# typed: true
# frozen_string_literal: true

# Homebrew's own specs turn this cop off in `Library/Homebrew/test/.rubocop.yml`
# ("RSpec helper methods typecheck better as regular methods"); the tap's style
# config does not inherit that override.
# rubocop:disable Sorbet/BlockMethodDefinition

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
  def brew_source(path) = (HOMEBREW_LIBRARY_PATH/path).read

  # `[command, sudo]` for each `run`/`run!` call with a `sudo:` argument.
  def sudo_calls(path)
    brew_source(path)
      .scan(/\.run!?[\s(]+"([^"]+)"(?:(?!\.run!?[\s(]).)*?sudo:\s*(nil|true)/m)
  end

  # The value of every `sudo:` keyword in the file, whatever the call looks
  # like; shorthand `sudo:` gives `""`.
  def sudo_values(path) = brew_source(path).scan(/\bsudo:[ \t]*([^,)\s]*)/).flatten

  describe "the `cmd_args` block of the wrapped commands" do
    it "is kept in `@parser_block`" do
      commands = [Homebrew::Cmd::UpgradeCmd, Homebrew::Cmd::InstallCmd, Homebrew::Cmd::Reinstall]
      block_classes = commands.to_h { |command| [command.name, command.instance_variable_get(:@parser_block).class] }
      expect(block_classes).to eq(commands.to_h { |command| [command.name, Proc] })
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
    # `stanza` is Cask DSL source: Sorbet cannot see the DSL's generated methods.
    def artifacts(stanza)
      Cask::Cask.new("timed-canary") do
        version "1.0"
        sha256 :no_check
        url "file:///dev/null"
        instance_eval(stanza, __FILE__, __LINE__)
      end.artifacts
    end

    it "is true for the stanzas that need root" do
      stanzas = {
        "pkg"                  => 'pkg "Foo.pkg"',
        "keyboard_layout"      => 'keyboard_layout "Foo.bundle"',
        "installer with sudo"  => 'installer script: { executable: "install.sh", sudo: true }',
        "install step as root" => 'postflight_steps steps: [{ type: "run", executable: "/usr/bin/true", sudo: true }]',
      }
      requires_sudo = stanzas.transform_values { |stanza| artifacts(stanza).any?(&:requires_sudo?) }
      expect(requires_sudo).to eq(stanzas.transform_values { true })
    end

    it "is false for app" do
      expect(artifacts('app "Foo.app"').any?(&:requires_sudo?)).to be(false)
    end
  end

  it "covers every flight block stanza with Cask::Artifact::AbstractFlightBlock" do
    keys = Cask::DSL::ARTIFACT_BLOCK_CLASSES.flat_map do |klass|
      (klass < Cask::Artifact::AbstractFlightBlock) ? [klass.dsl_key, klass.uninstall_dsl_key] : [klass]
    end
    expect(keys).to contain_exactly(:preflight, :postflight, :uninstall_preflight, :uninstall_postflight)
  end

  describe "cask file-permission sudo fallbacks" do
    let(:expected_sudo_calls) do
      {
        "cask/artifact/moved.rb"                   => [["/bin/cp", "nil"], ["/bin/cp", "nil"], ["/bin/cp", "nil"]],
        "cask/artifact/symlinked.rb"               => [["/bin/ln", "nil"]],
        "extend/os/mac/cask/artifact/symlinked.rb" => [["/bin/ln", "nil"]],
        "cask/utils.rb"                            => [["mkdir", "nil"], ["rmdir", "nil"], ["/bin/rm", "nil"],
                                                       ["chown", "true"]],
      }
    end

    it "runs the same commands with `sudo:` in each file" do
      expect(expected_sudo_calls.to_h { |path, _calls| [path, sudo_calls(path)] }).to eq(expected_sudo_calls)
    end

    it "has no other `sudo:` arguments in each file" do
      expect(expected_sudo_calls.to_h { |path, _calls| [path, sudo_values(path)] })
        .to eq(expected_sudo_calls.transform_values { |calls| calls.map(&:last) })
    end

    it "still goes through Cask::Utils.gain_permissions_* in `moved.rb` and `symlinked.rb`" do
      helpers = %w[cask/artifact/moved.rb cask/artifact/symlinked.rb extend/os/mac/cask/artifact/symlinked.rb]
                .flat_map { |path| brew_source(path).scan(/Utils\.(gain_permissions_\w+)/).flatten }
      expect(helpers.uniq).to contain_exactly("gain_permissions_mkpath", "gain_permissions_remove")
    end
  end

  it "rolls back a failed cask upgrade" do
    revert_lines = brew_source("cask/upgrade.rb").lines.grep(/revert_upgrade/).map(&:strip)
    expect("cask/upgrade.rb" => revert_lines)
      .to eq("cask/upgrade.rb" => ["old_cask_installer.revert_upgrade(predecessor: new_cask) if started_upgrade"])
  end

  describe "Homebrew::Ask.confirm?" do
    def confirmed_on_tty?(key)
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
    def update_if_needed(env)
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
    partition_lines = brew_source("upgrade.rb").lines.grep(/partition\(&:keg_only\?\)/).map(&:strip)
    expect("upgrade.rb" => partition_lines)
      .to eq("upgrade.rb" => ["formulae_to_install.replace(formulae_to_install.partition(&:keg_only?).flatten(1))"])
  end

  it "prints `Installation times` in a fixed format" do
    messages = Messages.new
    messages.package_installed("llvm", 2811.4)
    expect { messages.display_install_times }
      .to output("==> Installation times\nllvm                   2811.400 s\n").to_stdout
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
