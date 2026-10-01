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
require_relative "../lib/timed/command"
require_relative "../lib/timed/runner"

# Canaries: each pins a brew internal the `-timed` commands rely on, so a brew
# change fails here instead of during a real upgrade. When one fails, re-check
# the `-timed` behaviour that depends on it before updating the expectation.
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

  describe "tap commands" do
    it "are only found when executable" do
      dir = mktmpdir
      %w[plain runnable].each { |name| FileUtils.touch dir/"#{name}.rb" }
      (dir/"runnable.rb").chmod(0755)
      lookup = %w[plain runnable].to_h { |name| [name, which("#{name}.rb", [dir])] }
      source = brew_source("commands.rb")
      uses = ["which(\"\#{cmd}.rb\", tap_cmd_directories)", "select(&:executable?)"].map do |code|
        source.include?(code)
      end
      expect([lookup, uses]).to eq([{ "plain" => nil, "runnable" => dir/"runnable.rb" }, [true, true]])
    end

    it "in this tap are all executable" do
      expect((Pathname(__FILE__).dirname.parent/"cmd").children.reject(&:executable?)).to eq([])
    end
  end

  describe "the `cmd_args` block of the wrapped commands" do
    it "is kept in `@parser_block`" do
      commands = %w[upgrade install reinstall].map { |name| Timed::Command.builtin(name) }
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

    it "is false for an install step with `sudo: :if_needed`" do
      steps = [{ type: "remove", paths: [{ path: "/opt/x/f" }], sudo: "if_needed" }]
      expect(artifacts("postflight_steps steps: #{steps.inspect}").any?(&:requires_sudo?)).to be(false)
    end

    it "is false for a `set_ownership` install step" do
      steps = [{ type: "set_ownership", paths: [{ path: "/Applications/Foo.app" }] }]
      expect(artifacts("postflight_steps steps: #{steps.inspect}").any?(&:requires_sudo?)).to be(false)
    end
  end

  it "covers every flight block stanza with Cask::Artifact::AbstractFlightBlock" do
    keys = Cask::DSL::ARTIFACT_BLOCK_CLASSES.flat_map do |klass|
      (klass < Cask::Artifact::AbstractFlightBlock) ? [klass.dsl_key, klass.uninstall_dsl_key] : [klass]
    end
    expect(keys).to contain_exactly(:preflight, :postflight, :uninstall_preflight, :uninstall_postflight)
  end

  it "prefixes the uninstall flight block keys with `uninstall_`, and no other" do
    prefixed = Cask::DSL::ARTIFACT_BLOCK_CLASSES.to_h do |klass|
      [klass.name, [klass.dsl_key, klass.uninstall_dsl_key].map { |key| key.start_with?("uninstall_") }]
    end
    expect(prefixed).to eq(Cask::DSL::ARTIFACT_BLOCK_CLASSES.to_h { |klass| [klass.name, [false, true]] })
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

  describe "`Relocated#add_altname_metadata`" do
    it "runs `chmod` and `xattr -w` with `sudo: nil`" do
      expect(sudo_calls("cask/artifact/relocated.rb")).to eq([["chmod", "nil"], ["/usr/bin/xattr", "nil"]])
    end

    it "has no other `sudo:` arguments" do
      expect(sudo_values("cask/artifact/relocated.rb")).to eq(["nil", "nil"])
    end

    it "changes the target of a bundle" do
      expect(brew_source("cask/artifact/moved.rb")).to include("add_altname_metadata(target, source.basename")
    end

    it "changes the source of a link on macOS" do
      expect(brew_source("extend/os/mac/cask/artifact/symlinked.rb"))
        .to include("add_altname_metadata(source, target.basename")
    end

    it "does nothing when the names match, ignoring case" do
      expect(brew_source("cask/artifact/relocated.rb"))
        .to include("return if altname.to_s.casecmp(file.basename.to_s)&.zero?")
    end

    it "is a no-op on Linux" do
      expect(brew_source("extend/os/linux/cask/artifact/relocated.rb")).not_to match(/command\.run|\bsuper\b/)
    end
  end

  describe "`sudo: :if_needed` install steps" do
    it "checks `dirname.writable?` of a removed path and of a symlink's target" do
      checked = brew_source("install_steps.rb").scan(/step\["sudo"\] == "if_needed" && !(\w+)\.dirname\.writable\?/)
      expect(checked.flatten).to eq(["path", "target", "target"])
    end
  end

  describe "optional install steps" do
    it "counts for sudo only when `include_optional` is set, which `requires_sudo?` leaves out" do
      expect(brew_source("install_steps.rb")).to include(
        '(include_optional && (step["sudo"] == "if_needed" || step["type"] == "set_ownership"))',
      )
      expect(brew_source("cask/artifact/install_steps.rb"))
        .to include("sudo_required?(steps, include_optional: false)")
    end
  end

  describe "`requires_sudo?` of install steps" do
    it "is false unless the artifact has an `install_phase`, so `Uninstall*Steps` never count" do
      expect(brew_source("cask/artifact/install_steps.rb")).to include("respond_to?(:install_phase) &&")
    end

    it "is not defined on `Uninstall*Steps`" do
      steps = [Cask::Artifact::UninstallPreflightSteps, Cask::Artifact::UninstallPostflightSteps]
      expect(steps.map { |klass| klass.method_defined?(:install_phase) }).to eq([false, false])
    end
  end

  describe "`uninstall signal` on upgrade and reinstall" do
    it "is skipped unless `on_upgrade` names it" do
      expect(Cask::Artifact::Uninstall::UPGRADE_REINSTALL_SKIP_DIRECTIVES).to eq([:signal])
      expect(brew_source("cask/artifact/uninstall.rb")).to include(
        "(upgrade || reinstall) &&",
        "UPGRADE_REINSTALL_SKIP_DIRECTIVES.include?(directive_sym) &&",
        "on_upgrade_set.exclude?(directive_sym)",
      )
    end

    it "reads `on_upgrade` from a Symbol or an Array only" do
      body = brew_source("cask/artifact/uninstall.rb")[/^        on_upgrade_syms =\n.*?^          end$/m]
      expect(body.gsub(/\s+/, " ").strip).to eq(
        "on_upgrade_syms = case raw_on_upgrade when Symbol [raw_on_upgrade] when Array " \
        "raw_on_upgrade.map(&:to_sym) else [] end",
      )
    end
  end

  describe "`uninstall login_item` on upgrade and reinstall" do
    it "returns early because brew passes a `successor`" do
      body = brew_source("cask/artifact/abstract_uninstall.rb")[/^      def uninstall_login_item\(.*?^      end$/m]
      expect(body).to match(/\A[^\n]*\n\s+return if successor\n/)
      expect(brew_source("cask/upgrade.rb")).to include("old_cask_installer.start_upgrade(successor: new_cask")
      expect(brew_source("cask/installer.rb")).to include("cask_installer.uninstall(successor: @cask)")
    end
  end

  describe "`Cask::Utils` around missing paths" do
    it "makes a symlink's directory without sudo, and has nothing to remove for a missing path" do
      expect(brew_source("install_steps.rb"))
        .to match(/def create_symlink\(source, target, step\)\n\s+target\.dirname\.mkpath\n\s+if step\["sudo"\]/)
      remove_body = brew_source("cask/utils.rb")[/^    def self\.gain_permissions_remove\(.*?^    end$/m]
      expect(remove_body).to match(/# Nothing to remove\.\n\s+return\n\s+end\n/)
      expect(brew_source("cask/utils.rb")).to include("dir = path.ascend.find(&:directory?)")
    end
  end

  describe "removing an install-step link on uninstall" do
    it "removes a link to the source, absolute or `relative`, and leaves any other link" do
      dir = mktmpdir
      (dir/"bin").mkpath
      (dir/"bin/mine").make_symlink(dir/"src")
      (dir/"bin/other").make_symlink("/elsewhere")
      (dir/"bin/rel").make_symlink("../src")
      steps = [
        ["mine", { "path" => (dir/"src").to_s }],
        ["other", { "path" => (dir/"src").to_s }],
        ["rel", { "path" => "../src", "base" => "relative" }],
      ].map do |name, source|
        { "type" => "symlink", "source" => source, "target" => { "path" => (dir/"bin"/name).to_s },
          "uninstall" => true }
      end
      Homebrew::InstallSteps::Runner.new(context: Object.new).run(steps, phase: :uninstall)
      expect(%w[mine other rel].to_h { |name| [name, (dir/"bin"/name).symlink?] })
        .to eq({ "mine" => false, "other" => true, "rel" => false })
    end
  end

  describe "`reinstall --zap`" do
    it "is offered by `reinstall`, not `upgrade`" do
      zap_options = %w[reinstall upgrade].to_h do |name|
        options = Timed::Command.builtin(name).parser.processed_options
        [name, options.any? { |_short, long, _desc, _hidden| long == "--zap" }]
      end
      expect(zap_options).to eq({ "reinstall" => true, "upgrade" => false })
    end

    it "is passed on only by `reinstall`, which calls `Installer#zap` only from `uninstall_existing_cask`" do
      passed_on = %w[cmd/install.rb cmd/upgrade.rb cmd/reinstall.rb].to_h do |path|
        [path, brew_source(path).scan(/zap:\s*args\.zap\?/).length]
      end
      zap_calls = %w[cask/installer.rb cask/upgrade.rb cask/reinstall.rb].flat_map do |path|
        brew_source(path).scan(/\.zap\b/).map { |call| [path, call] }
      end
      expect([passed_on, zap_calls.map(&:first)])
        .to eq([{ "cmd/install.rb" => 0, "cmd/upgrade.rb" => 0, "cmd/reinstall.rb" => 2 }, ["cask/installer.rb"]])
    end

    it "replaces `uninstall(successor:)` with `Installer#zap` for a reinstall of the installed cask" do
      body = brew_source("cask/installer.rb")[/^    def uninstall_existing_cask\n.*?^    end$/m]
      expect(body).to include("zap? ? cask_installer.zap : cask_installer.uninstall(successor: @cask)")
      expect(body).to match(/Installer\.new\(@cask, .*reinstall: true\)/)
    end

    it "uninstalls the installed cask without a successor, then dispatches its `zap` stanzas" do
      body = brew_source("cask/installer.rb")[/^    def zap\n.*?^    end$/m]
      expect(body.lines.map(&:strip).grep(/uninstall_artifacts|zap_phase|load_installed_caskfile/))
        .to eq(["load_installed_caskfile!", "uninstall_artifacts",
                "stanza.zap_phase(command: @command, verbose: verbose?, force: force?)"])
    end

    it "dispatches every directive of a `zap` stanza, with no `successor` or `upgrade`" do
      body = brew_source("cask/artifact/zap.rb")[/^      def zap_phase\(.*?^      end$/m]
      expect(body.lines.map(&:strip).drop(1)).to eq(["dispatch_uninstall_directives(command:, force:)", "end"])
    end

    it "dispatches every ordered directive in `dispatch_uninstall_directives`" do
      source = brew_source("cask/artifact/abstract_uninstall.rb")
      body = source[/^      def dispatch_uninstall_directives\(.*?^      end$/m]
      expect(body.lines.map(&:strip).drop(1))
        .to eq(["ORDERED_DIRECTIVES.each do |directive_sym|",
                "dispatch_uninstall_directive(directive_sym, command:, force:, successor:, upgrade:)", "end", "end"])
    end

    it "runs `uninstall_login_item` unless brew passes a `successor`" do
      body = brew_source("cask/artifact/abstract_uninstall.rb")[/^      def uninstall_login_item\(.*?^      end$/m]
      expect(body.scan(/\breturn\b.*/)).to eq(["return if successor"])
    end
  end

  describe "`install --force` over an existing bundle" do
    it "fails without `force` and otherwise deletes the target, with permission recovery" do
      body = brew_source("cask/artifact/moved.rb")[/^      def move\(.*?^      end$/m]
      lines = body.lines.map(&:strip)
      message = "raise CaskError, \"\#{message}.\""
      kept = ["target.parent.writable?", message, "delete(target", "gain_permissions_remove"]
      expected = [
        "if target.parent.writable? && !force",
        "Utils.gain_permissions_remove(target, command:)",
        "#{message} if !force && !adopt",
        "delete(target, force:, successor:, command:)",
      ]
      expect(lines.select { |line| kept.any? { |part| line.include?(part) } }).to eq(expected)
    end

    it "is reached through the `force` that `brew install` passes to the cask installer" do
      block = brew_source("cmd/install.rb")[/Cask::Installer\.new\(.*?^                \)/m]
      installer = brew_source("cask/installer.rb")
      expect([block.match?(/^\s+force:\s+args\.force\?,$/), installer.include?("force: force?, predecessor:"),
              brew_source("cask/artifact/moved.rb").include?("move(adopt:, auto_updates:, force:,")])
        .to eq([true, true, true])
    end
  end

  describe "`symlink` install step with `source_glob`" do
    it "links into a target directory, so `if_needed` checks that directory" do
      body = brew_source("install_steps.rb")[/^        when "symlink"\n.*?^        when "write"/m]
      expect(body.lines.map(&:strip).grep(/sources\.length|mkpath|create_symlink/))
        .to eq(["if sources.length > 1 || target.directory?", "target.mkpath",
                "sources.each { |source| create_symlink(source, target/source.basename, step) }",
                "create_symlink(source, target, step) if source",
                "create_symlink(link_source(step_path(step, \"source\")), target, step)"])
    end
  end

  describe "`SystemCommand.run` with `sudo: nil`" do
    it "retries with sudo when the command fails, which `set_ownership`'s `chown` relies on" do
      retry_block = brew_source("system_command.rb")[/^    if sudo\.nil\?\n.*?^    end$/m]
      expect(retry_block).to match(/return result\n\s+end\n\s+sudo = true\n/)
    end
  end

  describe "uninstalling a cask" do
    it "runs the `uninstall_phase` of every artifact that has one, on upgrade and on reinstall" do
      body = brew_source("cask/installer.rb")[/^    def uninstall_artifacts\(.*?^    end$/m]
      expect(body).to include("artifacts.each do |artifact|", "if artifact.respond_to?(:uninstall_phase)",
                              "artifact.uninstall_phase(")
      expect(body).not_to include("select", "grep", "reject")
      expect(body.scan(/\bnext\b.*/)).to eq(["next unless artifact.respond_to?(:post_uninstall_phase)"])
    end

    it "does so from `uninstall` (reinstall) and `start_upgrade`" do
      source = brew_source("cask/installer.rb")
      expect([source[/^    def uninstall\(.*?^    end$/m], source[/^    def start_upgrade\(.*?^    end$/m]])
        .to match([/uninstall_artifacts\(clear: true, successor:\)/, /uninstall_artifacts\(successor:, quit:\)/])
    end

    it "runs a flight block's `dsl_key` on install and its `uninstall_dsl_key` on uninstall" do
      source = brew_source("cask/artifact/abstract_flight_block.rb")
      expect([source[/^      def install_phase\(.*?^      end$/m][/abstract_phase\(.*\)/],
              source[/^      def uninstall_phase\(.*?^      end$/m][/abstract_phase\(.*\)/]])
        .to eq(["abstract_phase(self.class.dsl_key)", "abstract_phase(self.class.uninstall_dsl_key)"])
    end

    it "removes only `symlink` steps with `uninstall: true` from `preflight_steps` and `postflight_steps`" do
      body = brew_source("install_steps.rb")[/^      def run_uninstall_step\(step\)\n.*?^      end$/m]
      expect(body).to match(
        /\A[^\n]*\n\s+return if step\.fetch\("type"\) != "symlink"\n\s+return if step\["uninstall"\] != true\n/,
      )
      expect(body).to include("return unless target.symlink?",
                              'step["sudo"] == true || (step["sudo"] == "if_needed" && !target.dirname.writable?)')
    end

    it "loads the installed caskfile to reinstall it" do
      body = brew_source("cask/installer.rb")[/^    def load_installed_caskfile!.*?^    end$/m]
      expect(body).to include("CaskLoader.load_from_installed_caskfile(installed_caskfile)")
    end
  end

  describe "`brew upgrade` of a cask" do
    it "uninstalls the installed caskfile's cask and merges its config into the new cask's" do
      expect(brew_source("cask/upgrade.rb")).to include(
        "CaskLoader.load_from_installed_caskfile(installed_caskfile)",
        "Installer.new(old_cask, **old_options)",
        "new_cask.config = new_cask.default_config.merge(old_config)",
      )
    end
  end

  describe "the cask installer's dependencies" do
    it "installs a missing cask dependency before the cask, unless `--skip-cask-deps` is set" do
      source = brew_source("cask/installer.rb")
      def_lines = ->(name) { source[/^    def #{name}\b.*?^    end$/m].to_s.lines.map(&:strip) }
      install_missing = "cask_installers.reject { |installer| installer.cask.installed? }.each(&:install)"
      wanted = {
        "fetch"                                 => "satisfy_cask_and_formula_dependencies",
        "satisfy_cask_and_formula_dependencies" => install_missing,
        "missing_cask_and_formula_dependencies" => "cask_or_formula.installed?",
        "dependency_installers"                 => "next if skip_cask_deps?",
      }
      expect(wanted.to_h { |name, line| [name, def_lines.call(name).include?(line)] })
        .to eq(wanted.transform_values { true })
    end
  end

  describe "`set_ownership` install steps" do
    it "fails without App Management permission, and runs `chown` with `sudo: nil`" do
      body = brew_source("install_steps.rb")[/^      def run_set_ownership\(step\)\n.*?^      end$/m]
      expect(body).to match(/app_management_permissions_granted\?.*raise ::Cask::CaskError/m)
      expect(body).to match(/@command\.run!\("chown".*?sudo: nil\)/m)
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

  # The lines of brew's `cmd/upgrade.rb` from the one that is `first` on,
  # stripped and with runs of spaces squeezed.
  def upgrade_lines(first, count)
    lines = brew_source("cmd/upgrade.rb").lines.map { |line| line.strip.squeeze(" ") }
    lines.index(first)&.then { |index| lines[index, count] }
  end

  it "drops pinned formulae, then upgrades each to its alias's new target unless that is up to date" do
    expected = ["pinned = outdated.select(&:pinned?)", "outdated -= pinned",
                "formulae_to_install = outdated.map do |f|", "f_latest = f.latest_formula",
                "if f_latest.latest_version_installed?", "f", "else", "f_latest", "end", "end"]
    expect("cmd/upgrade.rb" => upgrade_lines(expected.fetch(0), expected.length))
      .to eq("cmd/upgrade.rb" => expected)
  end

  it "asks by the named arguments as given, and planned names made full names only for named formulae" do
    expected = ["planned_names: planned_fetch_names.map do |planned_name|",
                "formulae.find { |formula| formula.full_specified_name == planned_name }&.full_name || planned_name",
                "end,", "requested_names: args.named,"]
    expect("cmd/upgrade.rb" => upgrade_lines(expected.fetch(0), expected.length))
      .to eq("cmd/upgrade.rb" => expected)
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

  it "prints `Installation times` as `Timed::Runner.parse` reads them, even with one space between the columns" do
    messages = Messages.new
    messages.package_installed("llvm", 2811.4)
    messages.package_installed("a-formula-with-a-long-name", 123456.789)
    lines = []
    allow(messages).to receive(:puts) { |line| lines << [line, nil] }
    messages.display_install_times
    expect(Timed::Runner.parse(lines).transform_values { |build| build["install_seconds"] })
      .to eq("llvm" => 2811.4, "a-formula-with-a-long-name" => 123456.789)
  end

  describe "the summary `FormulaInstaller` prints for each formula it installs" do
    let(:installer) do
      formula = formula("foo") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
      end
      (formula.prefix/"bin").mkpath
      FileUtils.touch [formula.prefix/"bin/foo", formula.prefix/"README"]
      FormulaInstaller.new(formula)
    end

    def parsed_summary(build_time)
      allow(installer).to receive(:build_time).and_return(build_time)
      Timed::Runner.parse([[installer.summary, nil]]).fetch("foo").slice("version", "status", "build_seconds")
    end

    it "ends in `built in` and the build time as `pretty_duration` prints it, which `Timed::Runner.parse` reads" do
      expect(parsed_summary(5190.0)).to eq("version" => "1.0", "status" => "built", "build_seconds" => 5160.0)
    end

    it "has no build time for a pour" do
      expect(parsed_summary(nil)).to eq("version" => "1.0", "status" => "poured")
    end

    it "can be read without the install badge" do
      ENV["HOMEBREW_NO_EMOJI"] = "1"
      expect(parsed_summary(61.0)).to eq("version" => "1.0", "status" => "built", "build_seconds" => 61.0)
    end
  end
end

# rubocop:enable Sorbet/BlockMethodDefinition
