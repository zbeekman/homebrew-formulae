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
require_relative "../cmd/install-timed"
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

    it "doesn't load a Ruby caskfile to reinstall a cask that isn't trusted, with tap trust on, as " \
       "`Timed::Command.installed_cask` follows, keeping the new cask (and its `zap`)" do
      body = brew_source("cask/installer.rb")[/^    def load_installed_caskfile!.*?^    end$/m].to_s
      guard = ["tab = CaskLoader.load_installed_tab(@cask)", "tap = tab.tap", "tap ||= @cask.tap",
               'if installed_caskfile.extname == ".rb" &&', "Homebrew::EnvConfig.require_tap_trust? &&", "tap &&",
               "!Homebrew::Trust.trusted?(:cask, \"\#{tap.name}/\#{@cask.token}\")"]
      lines = body.lines.map(&:strip)
      untrusted = body[/trusted\?.*?^\s+return$/m]
      zap = brew_source("cask/installer.rb")[/^    def zap\n.*?^    end$/m].to_s
      expect([guard.map { |line| lines.index(line) }.then { |at| at.all? && at == at.sort },
              untrusted&.exclude?("@cask ="), zap.include?("@cask.artifacts.grep(Artifact::Zap)")])
        .to eq([true, true, true])
    end

    it "uninstalls instead the artifacts the untrusted cask recorded, replayed as `Timed::Command.recorded_cask` " \
       "replays them" do
      source = brew_source("cask/installer.rb")
      untrusted = source[/^    def load_installed_caskfile!.*?^    end$/m].to_s[/trusted\?.*?^\s+return$/m].to_s
      replay = ["dsl = DSL.new(@cask)",
                "default_uninstall_artifact_keys = DSL::ACTIVATABLE_ARTIFACT_CLASSES.filter_map do |klass|",
                "next if [Artifact::Uninstall, Artifact::Zap].include?(klass)",
                "next if !klass.method_defined?(:uninstall_phase) && !klass.method_defined?(:post_uninstall_phase)",
                "Array(tab.uninstall_artifacts).each do |artifact_entry|",
                "next unless default_uninstall_artifact_keys.include?(dsl_key)",
                "args = Array(raw_args)", "if args.last.is_a?(Hash)", "*args[...-1],",
                "**T.cast(args.last, T::Hash[T.any(Symbol, String), T.anything]).transform_keys(&:to_sym),",
                "dsl.public_send(dsl_key, *args)",
                "@default_uninstall_artifacts ||= dsl.artifacts"]
      expect([replay.map { |line| untrusted.lines.map(&:strip).include?(line) },
              source.match?(/def artifacts\n\s+@default_uninstall_artifacts \|\| @cask\.artifacts\n/)])
        .to eq([replay.map { true }, true])
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

  describe "the casks the wrapped commands act on" do
    it "are, for `brew upgrade`, the outdated ones below `--minimum-version`, but not `installer manual` ones" do
      expected = ["casks = minimum_version_casks(casks, quiet: true)",
                  "return false if minimum_version.present? && casks.empty?", "",
                  "outdated_casks = Cask::Upgrade.outdated_casks(", "casks,", "args:,",
                  "force: args.force?,", "quiet: true,", "greedy: args.greedy?,",
                  "greedy_latest: args.greedy_latest?,", "greedy_auto_updates: args.greedy_auto_updates?,",
                  "summary_pinned: final_upgrade_summary.pinned_casks,", ")", "return true if outdated_casks.empty?",
                  "", "manual_installer_casks = outdated_casks.select do |cask|", "cask.artifacts.any? do |artifact|",
                  "artifact.is_a?(Cask::Artifact::Installer) && artifact.manual_install"]
      expect("cmd/upgrade.rb" => lines_from("cmd/upgrade.rb", expected.fetch(0), expected.length))
        .to eq("cmd/upgrade.rb" => expected)
    end

    it "are, for `brew install`, the new ones and the installed, outdated ones it upgrades" do
      expected = ["installed_casks, new_casks = casks.partition(&:installed?)", "",
                  "fetch_casks = if Homebrew::EnvConfig.no_install_upgrade?", "new_casks", "else",
                  "upgrade_casks = Cask::Upgrade.outdated_casks(casks, args:, force: true, quiet: true)",
                  "new_casks | upgrade_casks", "end",
                  "Install.ask_casks fetch_casks, skip_cask_deps: args.skip_cask_deps? if ask"]
      expect("cmd/install.rb" => lines_from("cmd/install.rb", expected.fetch(0), expected.length))
        .to eq("cmd/install.rb" => expected)
    end

    it "are printed by `Install.print_dry_run_casks`, which `brew install --dry-run` and the cask prompts use, " \
       "and which returns the dependencies to install that make brew ask" do
      ask_casks = brew_source("install.rb")[/^      def ask_casks\(.*?^      end$/m].to_s
      expect([brew_source("cmd/install.rb").include?(
        "Install.print_dry_run_casks(casks, skip_cask_deps: args.skip_cask_deps?, include_installed: false)",
      ), brew_source("cmd/reinstall.rb").include?(
        'Install.ask_casks casks, action: "reinstallation", skip_cask_deps: args.skip_cask_deps? if ask',
      ), ask_casks.include?("dependency_names = print_dry_run_casks("),
              ask_casks.match?(/planned_names:\s+cask_names \+ dependency_names,\n\s+requested_names: cask_names,/)])
        .to eq([true, true, true, true])
    end

    it "are uninstalled, on upgrade, as their installed caskfile defines them, or as rebuilt from it" do
      expect(brew_source("cask/upgrade.rb"))
        .to include("CaskLoader.recover_from_installed_caskfile(installed_caskfile, fallback_cask: c)")
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

  # The lines of brew's `path` from the one that is `first` on, stripped and
  # with runs of spaces squeezed.
  def lines_from(path, first, count)
    lines = brew_source(path).lines.map { |line| line.strip.squeeze(" ") }
    lines.index(first)&.then { |index| lines[index, count] }
  end

  def upgrade_lines(first, count) = lines_from("cmd/upgrade.rb", first, count)

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

  it "prints `Installation times` only if anything was installed, as `brew reinstall` finishes after the " \
     "dependents check, which `Timed::Runner` takes as brew not having stopped early", :aggregate_failures do
    expect { Messages.new.display_install_times }.not_to output.to_stdout
    expect(brew_source("cmd/reinstall.rb")[/rescue BuildError.*Install\.finish_installation\(/m]).to be_present
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

  it "times a formula's install from before it installs its dependencies, each named after the full name of the " \
     "formula it is a dependency of, so `Timed::Runner.parse` takes their times from its time" do
    install = brew_source("formula_installer.rb")[/^  def install\n.*?^  end$/m].to_s
    expect([install.match?(/start_time = Time\.now\n.*install_dependencies\(deps\)\n.*end_time - start_time\)/m),
            install.include?("Homebrew.messages.package_installed(formula.name, end_time - start_time)"),
            brew_source("formula_installer.rb")
              .include?("oh1 \"\#{action} \#{formula.full_name} dependency: \#{Formatter.identifier(dep.name)} \"")])
      .to eq([true, true, true])
  end

  describe "`Dependency.expand`" do
    it "names each dependency it keeps by its formula's full name, and prunes by `action` only without a block" do
      expand = brew_source("dependency.rb")[/^    def expand\(.*?^    end$/m]
      action = brew_source("dependency.rb")[/^    def action\(.*?^    end$/m]
      expect([expand.include?("dep = dep.dup_with_formula_name(dep_formula)"),
              brew_source("dependency.rb").include?("self.class.new(formula.full_name.to_s, tags)"),
              action.include?("Dependable::PRUNE unless T.cast(dependent, Formula).build.with?(dep)")])
        .to eq([true, true, true])
    end
  end

  describe "`brew reinstall`" do
    it "has no `--dry-run`, so `brew reinstall-timed` adds its own and prints brew's plan in-process" do
      options = Timed::Command.builtin("reinstall").parser.processed_options.flat_map { |short, long| [short, long] }
      expect(options & %w[-n --dry-run]).to eq([])
    end

    it "asks by `Install.formulae_ask_prompt_needed?`, through `Install.ask_formulae`, unless `--no-ask`, but " \
       "never when it reinstalls no formula, where `brew reinstall-timed` asks anyway" do
      reinstall = brew_source("cmd/reinstall.rb")
      ask_formulae = brew_source("install.rb")[/^      def ask_formulae\(.*?^      end$/m].to_s
      prompt_check = "return if formulae_installer.empty?\n        " \
                     "return if prompt && !formulae_ask_prompt_needed?(formulae_installer, dependants)"
      expect([reinstall.include?("ask = !args.no_ask?"),
              reinstall.match?(/Install\.ask_formulae\(\n\s+formulae_installers,\n\s+dependants,\n\s+action:\s+
                                "reinstallation",/x),
              ask_formulae.include?(prompt_check), ask_formulae.include?("ask_input(action:) if prompt")])
        .to eq([true, true, true, true])
    end

    it "reinstalls the linked keg, else the one in `opt`, whose receipt `Timed::Receipts.receipt_stat` reads" do
      resolve = brew_source("formulary.rb")[/^  def self\.resolve\(.*?^  end$/m]
      expect([resolve.include?("f = from_rack(rack, spec, alias_path:, force_bottle:, flags:)"),
              brew_source("keg.rb").include?(
                "kegs.find(&:linked?) || kegs.find(&:optlinked?) || kegs.max_by(&:scheme_and_version)",
              ),
              brew_source("formula_installer.rb").include?("keg.optlink(verbose: verbose?, overwrite: overwrite?)")])
        .to eq([true, true, true])
    end

    it "checks the outdated dependents of each named formula, pinned ones it refuses too, even when it reinstalls " \
       "none, and upgrades those not named, as `brew reinstall-timed` does" do
      reinstall = brew_source("cmd/reinstall.rb")
      installers = brew_source("upgrade.rb")[/^      def dependent_formula_installers\(.*?^      end$/m].to_s
      refused = /reinstall_contexts = formulae\.filter_map do \|formula\|\n\s+if formula\.pinned\?/
      expect([reinstall.match?(/unless formulae\.empty\?\n(?:.*\n)*?\s+#{refused}/),
              reinstall.match?(/Upgrade\.dependants\(\n\s+formulae,/),
              reinstall.match?(/Upgrade\.upgrade_dependents\(\n\s+dependants, formulae,/),
              installers.include?("deps.upgradeable.reject { |formula| formula_names.include?(formula.full_name) }")])
        .to eq([true, true, true, true])
    end

    it "stops at a failed build, where `brew install` and `brew upgrade` carry on" do
      reraised = brew_source("cmd/reinstall.rb").match?(/rescue BuildError\n(?:\s*#.*\n)*\s*raise\n/)
      dumped = /rescue BuildError => e\n\s*(?:require .*\n\s*)?(?:Utils::Analytics.*\n\s*)?e\.dump/
      carry_on = %w[install.rb upgrade.rb].to_h { |path| [path, brew_source(path).match?(dumped)] }
      expect([reraised, carry_on]).to eq([true, { "install.rb" => true, "upgrade.rb" => true }])
    end
  end

  describe "`brew install`" do
    let(:install) { brew_source("cmd/install.rb") }

    it "auto-updates first, as `brew upgrade` does, but `brew reinstall` doesn't" do
      commands = brew_source("utils/auto-update.sh")[/^  AUTO_UPDATE_COMMANDS=\(\n(.*?)^  \)$/m, 1].to_s.split
      expect(%w[install upgrade reinstall].to_h { |command| [command, commands.include?(command)] })
        .to eq("install" => true, "upgrade" => true, "reinstall" => false)
    end

    it "installs the taps of the names it is given, then loads every name before it installs anything" do
      expect([install.include?("tap&.ensure_installed!"),
              install.include?("args.named.to_formulae_and_casks(warn: false)")]).to eq([true, true])
    end

    it "asks by `Install.formulae_ask_prompt_needed?`, through `Install.ask_formulae`, unless `--no-ask` or " \
       "`--dry-run`" do
      ask_formulae = brew_source("install.rb")[/^      def ask_formulae\(.*?^      end$/m].to_s
      prompt_check = "return if prompt && !formulae_ask_prompt_needed?(formulae_installer, dependants)"
      expect([install.include?("ask = !args.no_ask? && !args.dry_run?"),
              install.match?(/dependants = Upgrade\.dependants\(\n\s+installed_formulae,\n\s+flags:/),
              install.match?(/Install\.ask_formulae\(\n\s+formulae_installer,\n\s+dependants,\n\s+flags:/),
              ask_formulae.include?('action: "installation")'), ask_formulae.include?(prompt_check)])
        .to eq([true, true, true, true, true])
    end

    it "builds every named formula from source with `--build-from-source`, `--HEAD` or `--build-bottle`" do
      flags = Regexp.escape("if @table[:build_from_source?] || @table[:HEAD?] || @table[:build_bottle?]")
      expect(brew_source("cli/args.rb")).to match(/#{flags}\n\s+named\.to_formulae\.map\(&:full_name\)/)
    end

    it "stops before it installs anything without build tools for a source build, or with `--env`" do
      lines = ["unless DevelopmentTools.installed?", 'build_flags << "--HEAD" if args.HEAD?',
               'build_flags << "--build-bottle" if args.build_bottle?',
               'build_flags << "--build-from-source" if args.build_from_source?',
               "raise BuildFlagsError.new(build_flags, bottled: formulae.all?(&:bottled?)) if build_flags.present?"]
      expect([install.include?('odisabled "`brew install --env`", "`env :std` in specific formula files"'),
              install.match?(/#{lines.map { |line| Regexp.escape(line) }.join("\\s+")}/)]).to eq([true, true])
    end

    it "prints with `--dry-run` what `Install.ask_formulae` prints, which builds no installers of its own" do
      ask_formulae = brew_source("install.rb")[/^      def ask_formulae\(.*?^      end$/m].to_s
      expect([ask_formulae.match?(/^\s+prompt: true,$/),
              ask_formulae.include?("install_formulae(formulae_installer, dry_run: true, " \
                                    "dry_run_action: dry_run_action(action))"),
              ask_formulae.match?(/Upgrade\.upgrade_dependents\(.*?dry_run:\s+true,/m),
              install.match?(/Install\.install_formulae\(\n\s+formulae_installer,\n\s+dry_run: args\.dry_run\?,/),
              install.match?(/dependents\(\n\s+dependants, installed_formulae,\n.*?dry_run:\s+args\.dry_run\?,/m),
              brew_source("install.rb").include?("Migrator.migrate_if_needed(formula, force:, dry_run:)")])
        .to eq([true, true, true, true, true, true])
    end

    it "leaves out a formula it can't install with an error and installs the rest, under `--yes`" do
      select = brew_source("install.rb")[/^      def select_formula_installers\(.*?^      end$/m].to_s
      prelude = brew_source("formula_installer.rb")[/^  def prelude\n.*?^  end$/m].to_s
      rescues = ["rescue CannotInstallFormulaError => e", "ofail e.message", "false", "rescue => e",
                 "ofail \"\#{fi.formula}: \#{e}\"", "false"].map { |line| Regexp.escape(line) }.join("\n\\s+")
      expect([select.match?(/#{rescues}/),
              brew_source("install.rb").include?("[:prelude, :enqueue_fetch].each do |step|"),
              prelude.include?("verify_deps_exist unless ignore_deps?"), prelude.include?("check_install_sanity")])
        .to eq([true, true, true, true])
    end
  end

  describe "`Install.install_formula?`" do
    it "is what `brew install` checks each named formula with, before it installs anything, with these options" do
      select = /installed_formulae = formulae\.select do \|f\|\n\s+Install\.install_formula\?\((.*?)\)\n/m
      call = brew_source("cmd/install.rb")[select, 1]
      options = call.to_s.split(",").map { |option| option.strip.squeeze(" ") }.reject(&:empty?)
      expect(options).to eq(["f", "head: args.HEAD?", "fetch_head: args.fetch_HEAD?",
                             "only_dependencies: args.only_dependencies?", "force: args.force?",
                             "quiet: args.quiet?", "skip_link: args.skip_link?", "overwrite: args.overwrite?"])
    end

    it "installs a missing formula, marks an installed one as installed on request, dropping keys brew doesn't " \
       "know, and stops at a HEAD-only formula without `head`" do
      missing = formula("missing") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/missing-2.0.tgz"
      end
      current = formula("current") do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/current-2.0.tgz"
      end
      keg = HOMEBREW_CELLAR/"current/2.0"
      (keg/"bin").mkpath
      (keg/AbstractTab::FILENAME).write(JSON.generate("installed_on_request" => false, "build_times" => {}))
      [HOMEBREW_PREFIX/"opt", HOMEBREW_LINKED_KEGS].each do |dir|
        dir.mkpath
        FileUtils.ln_s keg, dir/"current"
      end
      head_only = formula("headonly") do
        T.bind(self, T.class_of(Formula))
        head "https://brew.sh/headonly.git"
      end
      stopped = begin
        Homebrew::Install.install_formula?(head_only)
      rescue SystemExit
        :stopped
      end
      expect([Homebrew::Install.install_formula?(missing), Homebrew::Install.install_formula?(current),
              JSON.parse((keg/AbstractTab::FILENAME).read).slice("installed_on_request", "build_times"), stopped])
        .to eq([true, false, { "installed_on_request" => true }, :stopped])
    end
  end

  describe "`FormulaInstaller`'s checks before it installs" do
    # The statements of the method `name` of `formula_installer.rb`, without
    # blank lines and comments.
    def installer_statements(name)
      body = brew_source("formula_installer.rb")[/^  def #{name}(?:\(.*?\))?\n(.*?)^  end$/m, 1].to_s
      body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    end

    it "are, in `prelude_fetch`, the deprecation and forbidden checks, then fetching the bottle manifest, " \
       "then the downloads" do
      expect(installer_statements("prelude_fetch")).to eq([
        "unless @ran_prelude_fetch_metadata", "deprecate_disable_type = DeprecateDisable.type(formula)",
        "if deprecate_disable_type.present?",
        "message = \"\#{formula.full_name} has been \#{DeprecateDisable.message(formula)}\"",
        "case deprecate_disable_type", "when :deprecated", "opoo message", "when :disabled", "if force?",
        "opoo message", "else", "GitHub::Actions.puts_annotation_if_env_set!(:error, message)",
        "raise CannotInstallFormulaError, message", "end", "end", "end",
        "forbidden_tap_check(formula_only: true)", "forbidden_formula_check(formula_only: true)",
        "fetch_bottle_tab(enqueue: true) if pour_bottle?", "fetch_fetch_deps unless ignore_deps?",
        "@ran_prelude_fetch_metadata = true", "end", "return if metadata_only || @ran_prelude_fetch",
        "if pour_bottle?", "@enqueued_bottle_download = enqueue_bottle_download(stage: true)",
        "elsif formula.loaded_from_api?",
        "Homebrew::API::Formula.source_download(formula, download_queue:, enqueue: true)", "end",
        "@ran_prelude_fetch = true"
      ])
    end

    it "are, in `prelude`, reading the bottle manifest, then checking dependencies, licence, tap, formula " \
       "and sanity, then downloading dependencies" do
      expect(installer_statements("prelude")).to eq([
        "prelude_fetch unless @ran_prelude_fetch", "determine_bottle_tab_attributes",
        "verify_deps_exist unless ignore_deps?", "forbidden_license_check", "forbidden_tap_check",
        "forbidden_formula_check", "check_install_sanity",
        "install_fetch_deps if !ignore_deps? && Homebrew::EnvConfig.download_concurrency <= 1",
        "@ran_prelude = true"
      ])
    end

    it "works out the dependencies, in `compute_dependencies`, from the bottle manifest when pouring, then " \
       "the requirements, then `expand_dependencies`, which `install` does again, uncached, before installing" do
      install = installer_statements("install")
      expect([installer_statements("compute_dependencies"), install.include?("unless ignore_deps?"),
              install.include?("deps = compute_dependencies(use_cache: false)"),
              install.include?("install_dependencies(deps)")])
        .to eq([["@compute_dependencies = T.let(nil, T.nilable(T::Array[Dependency])) unless use_cache",
                 "@compute_dependencies ||= begin", "fetch_bottle_tab if pour_bottle?",
                 "check_requirements(expand_requirements)", "expand_dependencies", "end"], true, true, true])
    end

    it "check, before installing any dependency, that each has a bottle, with `--build-bottle` or a pour " \
       "without the developer tools, so `brew install-timed` batches none then" do
      expect(installer_statements("install"))
        .to include("if ((pour_bottle? && !DevelopmentTools.installed?) || build_bottle?) &&",
                    "(unbottled = unbottled_dependencies(deps)).presence")
    end
  end

  describe "`FormulaInstaller#install_dependency`" do
    let(:body) { brew_source("formula_installer.rb")[/^  def install_dependency\(.*?^  end$/m].to_s }

    it "upgrades an outdated dependency, keeping whether it was installed on request, and installs a missing one " \
       "as a dependency, even with `HOMEBREW_NO_INSTALL_UPGRADE`, which only brew's check of the named formulae " \
       "heeds and `brew upgrade` never reads" do
      on_request = "installed_on_request = dep_formula.any_version_installed? && tab.present? && " \
                   "tab.installed_on_request"
      readers = %w[formula_installer.rb install/check.rb upgrade.rb cmd/upgrade.rb].to_h do |path|
        [path, brew_source(path).scan("Homebrew::EnvConfig.no_install_upgrade?").length]
      end
      named_skip = Regexp.new(["if formula.outdated? && !head",
                               "if !Homebrew::EnvConfig.no_install_upgrade? && !formula.pinned?",
                               "puts \"\#{message} but outdated (so it will be upgraded).\""]
                                .map { |line| Regexp.escape(line) }.join('\n\s+'))
      expect([body.include?("upgrading = dep_formula.outdated?"), body.include?(on_request), readers,
              brew_source("install/check.rb").match?(named_skip)])
        .to eq([true, true, { "formula_installer.rb" => 0, "install/check.rb" => 2, "upgrade.rb" => 0,
                              "cmd/upgrade.rb" => 0 }, true])
    end

    it "stops at an outdated dependency installed from another tap, which `brew upgrade` would upgrade from " \
       "that tap, as it resolves a name through the installed keg, so `brew install-timed` leaves those to brew" do
      resolve = brew_source("formulary.rb")[/^  def self\.resolve\(.*?^  end$/m].to_s
      expect([body.include?("dep_formula.tap.to_s != tab_tap.to_s\n      odie"),
              resolve.include?("rack = to_rack(name)") &&
                resolve.include?("f = from_rack(rack, spec, alias_path:, force_bottle:, flags:)"),
              brew_source("cmd/upgrade.rb")
                .include?("args.named.to_formulae_and_casks_and_unavailable(method: :resolve)")])
        .to eq([true, true, true])
    end

    it "is cleaned up by neither `brew install` nor `brew upgrade`, which clean only the formulae they are " \
       "given, unless `HOMEBREW_NO_INSTALL_CLEANUP` is set, as for `brew install-timed`'s dependency batches" do
      cleanup = brew_source("cleanup.rb")
      first_lines = %w[install_cleanup_formulae install_formula_clean! install_clean! periodic_clean!].to_h do |name|
        [name, cleanup[/^    def self\.#{Regexp.escape(name)}[(\n].*?\n\s*(.*?)\n/, 1]]
      end
      expect([brew_source("formula_installer.rb").include?("Cleanup"), first_lines,
              brew_source("upgrade.rb").include?("Cleanup.install_formula_clean!(fi.formula) if upgraded && " \
                                                 "!dry_run && cleanup")])
        .to eq([false, { "install_cleanup_formulae" => "return [] if Homebrew::EnvConfig.no_install_cleanup?",
                         "install_formula_clean!"   => "return if install_cleanup_formulae([formula]).blank?",
                         "install_clean!"           => "return if Homebrew::EnvConfig.no_install_cleanup?",
                         "periodic_clean!"          => "return if Homebrew::EnvConfig.no_install_cleanup?" },
                true])
    end

    it "gives the dependency's installer its receipt's options and the dependency's, and of the command's " \
       "options only these, which `brew install-timed` gives its dependency batches, or with `debug_symbols`, " \
       "batches none" do
      options = [
        "options = Options.new", "options |= tab.used_options if tab.present?",
        "options |= Tab.remap_deprecated_options(dep_formula.deprecated_options, dep.options)",
        "options &= dep_formula.options"
      ]
      call = body[/fi = FormulaInstaller\.new\(\n\s+dep_formula,\n(.*?)\n\s+\)\n/m, 1].to_s
      keywords = call.lines.map { |line| line.strip.delete_suffix(",").squeeze(" ") }
      expect([options.all? { |line| body.include?(line) }, keywords])
        .to eq([true, ["options:", "link_keg: keg_had_linked_keg && keg_was_linked", "installed_on_request:",
                       "force_bottle: false", "include_test_formulae: @include_test_formulae",
                       "build_from_source_formulae: @build_from_source_formulae", "keep_tmp: keep_tmp?",
                       "debug_symbols: debug_symbols?", "force: force?", "debug: debug?", "quiet: quiet?",
                       "verbose: verbose?"]])
    end

    it "carries on, within one call, past a dependency it already tried for another formula, even if that " \
       "failed, so `brew install-timed` and `brew upgrade-timed` never give one call two formulae that need it" do
      source = brew_source("formula_installer.rb")
      expect([source.include?("raise FormulaInstallationAlreadyAttemptedError, formula if " \
                              "self.class.attempted.include?(formula)"),
              source.include?("self.class.attempted << formula"),
              body.include?("raise unless e.is_a? FormulaInstallationAlreadyAttemptedError")])
        .to eq([true, true, true])
    end

    it "can't be given `--debug-symbols` on its own by `brew install`, which needs `--build-from-source` for it" do
      expect { Timed::Command.builtin("install").parser.parse(%w[--debug-symbols foo]) }
        .to raise_error(Homebrew::CLI::OptionConstraintError,
                        /`--debug-symbols` cannot be passed without `--build-from-source`/)
    end
  end

  describe "`brew upgrade`'s installer for a formula" do
    it "keeps whether the keg linked into `opt` was installed on request, and builds a bottle again if it was " \
       "built as one, but takes one without such a keg as installed on request" do
      body = brew_source("upgrade.rb")[/^      def create_formula_installer\(.*?^      end$/m].to_s
      lines = ["keg = if formula.optlinked?", "if keg", "tab = keg.tab",
               "installed_on_request = tab.installed_on_request == true", "build_bottle = tab.built_bottle?",
               "else", "link_keg = nil", "installed_on_request = true"]
      expect(lines.reject { |line| body.include?(line) }).to eq([])
    end
  end

  describe "the order `brew install` works in" do
    let(:install) { brew_source("cmd/install.rb") }

    it "warns about `--ignore-dependencies` as `brew install-timed` does" do
      warning = /if args\.ignore_dependencies\?\n\s+opoo <<~EOS\n(.*?)\n\s+EOS/m
      ours = (Pathname(__FILE__).dirname.parent/"cmd/install-timed.rb").read[warning, 1].to_s.lines.map(&:strip)
      expect(ours).to eq(install[warning, 1].to_s.lines.map(&:strip))
    end

    it "fetches the bottle manifests, runs the preinstall checks and prints and asks about its plan, then " \
       "checks each formula with `prelude` and downloads" do
      steps = ["Install.prelude_fetch_formulae(formulae_installer,", "metadata_only:  ask)",
               "Install.perform_preinstall_checks_once", "Install.check_cc_argv(args.cc)",
               "dependants = Upgrade.dependants(", "Install.ask_formulae(", "Install.enqueue_formulae("]
      expect(steps.map { |step| install.index(step) }.then { |at| at.all? && at == at.sort }).to be(true)
    end

    it "never warns that building from source isn't supported, as it raises first without the developer tools" do
      build_flags = install[/^        build_flags = \[\]\n(.*?)^        end$/m, 1].to_s
      expect([build_flags.lines.first&.strip, build_flags.include?("raise BuildFlagsError"),
              install.include?("if build_flags.present? && !Homebrew::EnvConfig.developer?")])
        .to eq(["unless DevelopmentTools.installed?", true, true])
    end

    # The keywords given to the call that starts with `call` in `source`, up
    # to the end of the line that closes it.
    def keywords(source, call)
      source[/#{Regexp.escape(call)}(.*?)\)\n/m, 1].to_s.scan(/\b(\w+):\s/).flatten
    end

    it "gives its installers, dependents check and plan the options `brew install-timed` gives them" do
      ours = (Pathname(__FILE__).dirname.parent/"cmd/install-timed.rb").read
      options = Timed::Command.installer_options(Homebrew::Cmd::InstallTimed.new(%w[cmake]).args).keys.map(&:to_s)
      calls = ["Install.formula_installers(", "Upgrade.dependants(", "Install.ask_formulae("]
      expanded = ->(call) { keywords(ours, call).reject { |keyword| keyword == "prompt" } + options }
      expect(calls.to_h { |call| [call, keywords(install, call).sort] })
        .to eq(calls.to_h { |call| [call, expanded.call(call).sort] })
    end
  end

  describe "the order `brew upgrade` works in" do
    it "reads its installers' bottle manifests before it prints and asks about their dependencies" do
      installers = brew_source("upgrade.rb")[/^      def formula_installers\(.*?^      end$/m].to_s
      upgrade = brew_source("cmd/upgrade.rb")
      in_order = ->(source, steps) { steps.map { |step| source.index(step) }.then { |at| at.all? && at == at.sort } }
      expect([in_order.call(installers, ["download_queue.fetch(only: Resource::BottleManifest",
                                         "fi.determine_bottle_tab_attributes"]),
              in_order.call(upgrade, ["Upgrade.formula_installers(",
                                      "Install.formulae_ask_prompt_needed?(context.formulae_installer"])])
        .to eq([true, true])
    end
  end

  describe "brew's check for dependents with broken linkage" do
    # `text` with each run of whitespace made one space.
    def squished(text) = text.gsub(/\s+/, " ").strip

    # The method `name` in `source`, without its `sig`.
    def method_source(source, name) = source[/^      def #{name}\(.*?^      end$/m].to_s

    let(:upgrade) { brew_source("upgrade.rb") }

    it "finds them as the private `check_broken_dependents`, which `Timed::Command.broken_dependents` copies",
       :aggregate_failures do
      expect(Homebrew::Upgrade.private_methods).to include(:check_broken_dependents)
      expect(squished(method_source(upgrade, "check_broken_dependents"))).to eq(squished(<<~RUBY))
        def check_broken_dependents(installed_formulae)
          CacheStoreDatabase.use(:linkage) do |db|
            installed_formulae.flat_map(&:runtime_installed_formula_dependents)
                              .uniq
                              .select do |f|
              keg = f.any_installed_keg
              next unless keg
              next unless keg.directory?

              LinkageChecker.new(
                keg,
                cache_db: T.cast(db, CacheStoreDatabase[String, T::Hash[T.any(String, Symbol), T.anything]]),
              ).broken_library_linkage?
            end.compact
          end
        end
      RUBY
    end

    it "orders them as the private `depends_on`, which `Timed::Command` copies", :aggregate_failures do
      ours = (Pathname(__FILE__).dirname.parent/"lib/timed/command.rb").read
      expect(Homebrew::Upgrade.private_methods).to include(:depends_on)
      expect(squished(method_source(upgrade, "depends_on")))
        .to eq(squished(ours[/^    def self.depends_on\(.*?^    end$/m].to_s.sub("def self.", "def ")))
    end

    it "checks those of the non-core formulae it installed after the bottle-filtered dependents, and reinstalls " \
       "them from source, dependencies first, unless outdated or pinned, carrying on past a failed build" do
      dependents = squished(method_source(upgrade, "upgrade_dependents"))
      snippets = [
        "filter_dependent_formula_installers( prefetched_formula_installers.select",
        "installed_non_core_formulae = FormulaInstaller.installed.to_a.reject(&:core_formula?)",
        "broken_dependents = check_broken_dependents(installed_non_core_formulae)",
        "reinstallable_broken_dependents = broken_dependents.reject(&:outdated?) .reject(&:pinned?) " \
        ".sort { |a, b| depends_on(a, b) }",
        "build_from_source_formulae: build_from_source_formulae + [formula.full_name],",
        "Reinstall.reinstall_formula(reinstall_context) rescue FormulaInstallationAlreadyAttemptedError",
        "rescue BuildError => e e.dump(verbose:) puts Homebrew.failed = true rescue => e ofail e end",
      ]
      expect(snippets.reject { |snippet| dependents.include?(snippet) }).to eq([])
    end
  end

  it "reports the support tiers noted in the process as it exits, then forgets them, and `--cc` notes one",
     :aggregate_failures do
    tiers = Homebrew::Diagnostic.support_tiers
    saved = tiers.dup
    tiers.clear
    Homebrew::Install.check_cc_argv("gcc-9")
    noted = tiers.dup
    expect { Homebrew::Diagnostic.report_support_tier }.to output(/This is a Tier 3 configuration/).to_stderr
    expect([brew_source("diagnostic.rb").include?("at_exit { Homebrew::Diagnostic.report_support_tier }"), noted,
            tiers]).to eq([true, [3], []])
  ensure
    tiers&.replace(saved || [])
  end

  it "writes each receipt as a new file, while a failed reinstall renames the old keg back, receipt and all" do
    reinstall = brew_source("reinstall/reinstall.rb")
    receipt = mktmpdir/"INSTALL_RECEIPT.json"
    receipt.write("{}")
    inode = receipt.stat.ino
    receipt.atomic_write("{}")
    expect([brew_source("tab.rb").include?("tfile.atomic_write(to_json)"), receipt.stat.ino == inode,
            reinstall.include?("keg.rename backup_path(keg)"), reinstall.include?("path.rename keg.to_s")])
      .to eq([true, false, true, true])
  end

  it "writes the install time into the receipt of every keg it builds or pours" do
    create = brew_source("tab.rb")[/^  def self\.create\(.*?^  end$/m]
    pour = brew_source("formula_installer.rb")[/^  def pour\n.*?^  end$/m]
    expect([create.include?("time:                     Time.now.to_i,"), pour.include?("tab.time = Time.now.to_i")])
      .to eq([true, true])
  end

  describe "the lines `Timed::Runner.parse` names formulae by" do
    let(:foo) do
      formula("foo", tap: Tap.fetch("user", "tap")) do
        T.bind(self, T.class_of(Formula))
        url "https://brew.sh/foo-1.0.tgz"
      end
    end

    def parsed(lines) = Timed::Runner.parse(lines.map { |line| ["#{line}\n", nil] }).keys

    it "include the heading a tap formula's install starts with" do
      lines = []
      allow(foo).to receive(:ohai) { |title| lines << "==> #{title}" }
      foo.print_tap_action
      expect(parsed(lines)).to eq(%w[foo])
    end

    it "include the bottle a formula pours, which is all an install with no dependencies to install names " \
       "before its summary", :aggregate_failures do
      expect(brew_source("formula_installer.rb")).to include(
        "oh1 \"Installing \#{Formatter.identifier(formula.full_name)} \#{options}\".strip if show_header?",
        "@show_header = true unless deps.empty?",
        "ohai \"Pouring \#{downloadable_object.downloader.basename}\"",
      )
      bottle = Bottle::Filename.new("foo", PkgVersion.parse("1.0_1"), Utils::Bottles.tag, 1)
      expect(parsed(["==> Pouring #{bottle}"])).to eq(%w[foo])
    end

    it "include the log a failed build prints the end of, in a directory named after the formula",
       :aggregate_failures do
      expect(brew_source("formula.rb")).to include(
        "log_filename = format(\"\#{logs}/\#{active_log_prefix}%02<exec_count>d.%<cmd_base>s.log\",",
        "puts \"Last \#{log_lines} lines from \#{log_filename}:\"",
      )
      expect(parsed(["Last 15 lines from #{foo.logs}/01.make.log:", "make: *** Error 1"])).to eq(%w[foo])
    end

    it "name a failed resource download after its formula, and a patch or API source download only by file, " \
       "which `Timed::Runner` relies on to tell a formula brew left out from one it never got to" do
      resource = brew_source("resource.rb")
      expect([resource.include?("owner_name ? \"\#{owner_name}--\#{escaped_name}\" : escaped_name"),
              resource.scan(/def download_queue_type = "([^"]+)"/).flatten,
              brew_source("api/source_download.rb").include?('def download_queue_type = "API Source"'),
              brew_source("downloadable.rb").include?("\"\#{download_queue_type} \#{download_queue_name}\"")])
        .to eq([true, ["Resource", "Formula", "Bottle Manifest", "Patch"], true, true])
    end

    it "include none from dependents brew rebuilds or upgrades after its heading, or a failed post-install" do
      expect([brew_source("upgrade.rb").include?('oh1 "Checking for dependents of upgraded formulae..."'),
              brew_source("upgrade.rb").include?(
                "ohai \"\#{upgrade_verb} \#{Utils.pluralize(\"dependent\", upgradeable.count,",
              ),
              brew_source("formula_installer.rb")
                .include?('opoo "The post-install step did not complete successfully"')])
        .to eq([true, true, true])
    end

    it "include the error ending a verbose build's failure, which prints no log tail", :aggregate_failures do
      expect([brew_source("formula.rb").include?("if !verbose? || verbose_using_dots"),
              brew_source("exceptions.rb").include?(
                "onoe \"\#{formula.full_name} \#{formula.version} did not build\"",
              )]).to eq([true, true])
      expect(parsed(["Error: #{foo.full_name} #{foo.version} did not build"])).to eq(%w[foo])
    end
  end

  describe "`Tty`, which paints `brew build-times stats`, `histogram`, `runs` and `run`" do
    # It can be 0; `histogram` and `run` draw at least 40 columns whatever it is.
    it "gives the width of the terminal, which `histogram` and `run` fit, as a number of columns" do
      expect(Tty.width).to be_a(Integer)
    end

    it "has the colours and reset the table paints with, as escape sequences when colour is on" do
      ENV["HOMEBREW_COLOR"] = "1"
      codes = [:blue, :green, :yellow, :red, :cyan, :magenta, :italic, :bold, :underline].to_h do |colour|
        [colour, "#{Tty.public_send(colour)}x#{Tty.reset}"]
      end
      expect(codes).to eq(blue: "\e[34mx\e[0m", green: "\e[32mx\e[0m", yellow: "\e[33mx\e[0m", red: "\e[31mx\e[0m",
                          cyan: "\e[36mx\e[0m", magenta: "\e[35mx\e[0m", italic: "\e[3mx\e[0m",
                          bold: "\e[1mx\e[0m", underline: "\e[4mx\e[0m")
    end

    it "is in colour with `HOMEBREW_COLOR`, never with `HOMEBREW_NO_COLOR`, and not when not a terminal" do
      colour = lambda do |env|
        ENV.delete("HOMEBREW_COLOR")
        ENV.delete("HOMEBREW_NO_COLOR")
        env.each { |key, value| ENV[key] = value }
        Tty.color?
      end
      expect([colour.call({}), colour.call("HOMEBREW_COLOR" => "1"),
              colour.call("HOMEBREW_COLOR" => "1", "HOMEBREW_NO_COLOR" => "1")]).to eq([false, true, false])
    end

    it "strips the escape sequences it writes" do
      expect(Tty.strip_ansi("\e[31mred\e[0m")).to eq("red")
    end
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
