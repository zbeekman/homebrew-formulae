# typed: true
# frozen_string_literal: true

require "cask/cask"
require_relative "../../lib/timed/casks"

# A world of files: `entries` maps a path to `[uid, readable]`. Only entries
# (and the root) exist to be written; `unwritable` paths are read-only, and
# `links` maps a symlink's path to what it points to.
class FakeCaskFacts
  include Timed::Casks::Facts

  def initialize(entries: {}, unwritable: [], realpaths: {}, links: {})
    @entries = entries
    @links = links
    @unwritable = unwritable
    @realpaths = realpaths
  end

  def uid = 501

  def lstat(path)
    uid, readable = @entries[path.to_s]
    Timed::Casks::FileEntry.new(path:, uid:, readable:) if uid
  end

  def walk(path)
    @entries.keys.select { |key| key == path.to_s || key.start_with?("#{path}/") }.filter_map do |key|
      lstat(Pathname(key))
    end
  end

  # Like `Pathname#writable?`: false for anything that isn't there.
  def writable?(path) = (path.root? || !lstat(path).nil?) && @unwritable.exclude?(path.to_s)
  def realpath(path) = @realpaths[path.to_s]

  def readlink(path)
    target = @links[path.to_s]
    Pathname(target) if target
  end
end

RSpec.describe Timed::Casks do
  # Plain `def` helpers, unlike `define_method`, are visible to `brew typecheck`.
  # rubocop:disable Sorbet/BlockMethodDefinition
  sig {
    params(token: String, config: T.nilable(Cask::Config), stanza: T.nilable(T.proc.bind(Cask::DSL).void))
      .returns(Cask::Cask)
  }
  def cask(token = "foo", config: nil, &stanza)
    Cask::Cask.new(token, config:) do
      version "1.0"
      sha256 :no_check
      url "file:///dev/null"
      instance_exec(&stanza) if stanza
    end
  end

  def facts(**world) = FakeCaskFacts.new(**world)

  sig {
    params(
      casks:     Cask::Cask,
      in_run:    T::Array[String],
      verb:      Symbol,
      world:     T.nilable(Timed::Casks::Facts),
      macos:     T::Boolean,
      tty:       T.proc.returns(T::Boolean),
      env:       T::Hash[String, String],
      installed: T::Hash[String, Cask::Cask],
    ).returns(Timed::Casks::Plan)
  }
  def plan(*casks, in_run: [], verb: :upgrade, world: nil, macos: true, tty: -> { true }, env: {}, installed: {})
    described_class.plan(casks, verb:, in_run:, facts: world || facts, macos:, tty:, env:, installed:)
  end

  sig { params(entries: T::Array[Timed::Casks::Entry]).returns(T::Array[String]) }
  def tokens(entries) = entries.map { |entry| entry.cask.token }

  sig { params(entries: T::Array[Timed::Casks::Entry]).returns(T::Array[Symbol]) }
  def kinds(entries) = entries.flat_map { |entry| entry.reasons.map(&:kind) }

  sig { params(entries: T::Array[Timed::Casks::Entry]).returns(T::Array[String]) }
  def messages(entries) = entries.flat_map { |entry| entry.reasons.map(&:message) }

  # The stanzas are deprecated, so the DSL refuses them; casks still in the
  # wild carry the artifacts.
  sig { params(klass: T.class_of(Cask::Artifact::AbstractFlightBlock), key: Symbol).returns(Cask::Cask) }
  def cask_with_block(klass, key)
    cask { artifacts.add(klass.new(cask, key => proc {})) }
  end

  # `directory` and a file in it, the directory read-only.
  sig { params(directory: T.any(String, Pathname)).returns(Timed::Casks::Facts) }
  def readonly_world(directory)
    facts(entries: { directory.to_s => [0, true], "#{directory}/f" => [0, true] }, unwritable: [directory.to_s])
  end

  describe "dependencies in this run" do
    it "puts a cask with no dependencies first" do
      expect(tokens(plan(cask).first)).to eq(["foo"])
    end

    it "puts a cask depending on a formula in the run last" do
      result = plan(cask { depends_on formula: "llvm" }, in_run: ["llvm"])
      expect(kinds(result.last)).to eq([:dependency])
    end

    it "puts a cask depending on a cask in the run last, whatever the tap prefix" do
      result = plan(cask { depends_on cask: "other" }, in_run: ["homebrew/cask/other"])
      expect(kinds(result.last)).to eq([:dependency])
    end

    it "leaves a cask depending on something not in the run first" do
      expect(tokens(plan(cask { depends_on formula: "llvm" }, in_run: ["gcc"]).first)).to eq(["foo"])
    end
  end

  describe "`requires_sudo?` artifacts" do
    it "puts a `pkg` cask last, for sudo" do
      expect(kinds(plan(cask { pkg "Foo.pkg" }).last)).to eq([:sudo])
    end

    it "puts a plain `app` cask first" do
      expect(tokens(plan(cask { app "Foo.app" }).first)).to eq(["foo"])
    end
  end

  describe "flight blocks" do
    it "puts a cask with any flight block last, for sudo" do
      {
        Cask::Artifact::PreflightBlock  => [:preflight, :uninstall_preflight],
        Cask::Artifact::PostflightBlock => [:postflight, :uninstall_postflight],
      }.each do |klass, keys|
        keys.each { |key| expect(kinds(plan(cask_with_block(klass, key)).last)).to eq([:sudo]), key.to_s }
      end
    end
  end

  describe "flight blocks by phase" do
    it "leaves a cask with only an uninstall block first on install" do
      expect(tokens(plan(cask_with_block(Cask::Artifact::PostflightBlock, :uninstall_postflight),
                         verb: :install).first)).to eq(["foo"])
    end

    it "puts a cask with an install block last on install" do
      expect(kinds(plan(cask_with_block(Cask::Artifact::PostflightBlock, :postflight), verb: :install).last))
        .to eq([:sudo])
    end
  end

  describe "`uninstall` directives, run before an upgrade or reinstall" do
    let(:upgrading) { [:upgrade, :reinstall] }

    let(:sudo_directives) do
      {
        "pkgutil"                => { pkgutil: "com.foo" },
        "launchctl"              => { launchctl: "com.foo" },
        "kext"                   => { kext: "com.foo" },
        "delete"                 => { delete: "/Library/Foo" },
        "script with sudo"       => { script: { executable: "x.sh", sudo: true } },
        "early_script with sudo" => { early_script: { executable: "x.sh", sudo: true } },
      }
    end

    let(:dialog_directives) { { "quit" => { quit: "com.foo" } } }

    it "puts a cask with a root directive last on upgrade and reinstall, for sudo" do
      sudo_directives.each do |name, directives|
        upgrading.each do |verb|
          expect(kinds(plan(cask { uninstall(**directives) }, verb:).last)).to eq([:sudo]), "#{name} on #{verb}"
        end
      end
    end

    it "puts a cask with a dialog directive last on upgrade and reinstall, for a dialog" do
      dialog_directives.each do |name, directives|
        upgrading.each do |verb|
          expect(kinds(plan(cask { uninstall(**directives) }, verb:).last)).to eq([:dialog]), "#{name} on #{verb}"
        end
      end
    end

    it "leaves a cask with `signal` first on upgrade and reinstall, as brew skips it" do
      upgrading.each do |verb|
        cask = cask { uninstall signal: ["TERM", "com.foo"] }
        expect(tokens(plan(cask, verb:).first)).to eq(["foo"]), verb.to_s
      end
    end

    it "puts a cask with `signal` last when `on_upgrade` includes it, for a dialog" do
      symbol = cask { uninstall signal: ["TERM", "com.foo"], on_upgrade: :signal }
      directives = { signal: ["TERM", "com.foo"], on_upgrade: [:signal] }
      expect([kinds(plan(symbol).last), kinds(plan(cask { uninstall(**directives) }).last)])
        .to eq([[:dialog], [:dialog]])
    end

    it "ignores a bare string `on_upgrade`, which brew doesn't honour" do
      directives = { signal: ["TERM", "com.foo"], on_upgrade: "signal" }
      expect(tokens(plan(cask { uninstall(**directives) }).first)).to eq(["foo"])
    end

    it "leaves a cask with `login_item` first on upgrade and reinstall, as brew returns early" do
      upgrading.each do |verb|
        expect(tokens(plan(cask { uninstall login_item: "Foo" }, verb:).first)).to eq(["foo"]), verb.to_s
      end
    end

    it "leaves a cask with any directive first on install" do
      extra = { "signal"     => { signal: ["TERM", "com.foo"], on_upgrade: :signal },
                "login_item" => { login_item: "Foo" } }
      sudo_directives.merge(dialog_directives, extra).each do |name, directives|
        expect(tokens(plan(cask { uninstall(**directives) }, verb: :install).first)).to eq(["foo"]), name
      end
    end

    it "leaves a cask with `script` without sudo first" do
      expect(tokens(plan(cask { uninstall script: { executable: "x.sh" } }).first)).to eq(["foo"])
    end

    it "leaves a cask with `trash` first" do
      expect(tokens(plan(cask { uninstall trash: "~/Foo" }).first)).to eq(["foo"])
    end

    it "ignores `zap`" do
      expect(tokens(plan(cask { zap pkgutil: "com.foo" }).first)).to eq(["foo"])
    end
  end

  describe "an existing bundle being replaced" do
    let(:app) { cask { app "Foo.app", target: "/Applications/Foo.app" } }
    let(:mine) { [501, true] }

    it "goes first when everything in it is the user's and readable" do
      world = facts(entries: { "/Applications/Foo.app" => mine, "/Applications/Foo.app/Contents/x" => mine })
      expect(tokens(plan(app, world:).first)).to eq(["foo"])
    end

    it "goes last for sudo when an entry inside is owned by another user" do
      world = facts(entries: { "/Applications/Foo.app" => mine, "/Applications/Foo.app/Contents/x" => [0, true] })
      expect(kinds(plan(app, world:).last)).to eq([:sudo])
    end

    it "goes last for sudo when an entry inside is unreadable" do
      world = facts(entries: { "/Applications/Foo.app" => mine, "/Applications/Foo.app/x" => [501, false] })
      expect(kinds(plan(app, world:).last)).to eq([:sudo])
    end

    it "goes last for sudo when the bundle is not writable" do
      world = facts(entries: { "/Applications/Foo.app" => mine }, unwritable: ["/Applications/Foo.app"])
      expect(kinds(plan(app, world:).last)).to eq([:sudo])
    end

    it "goes last on reinstall too" do
      world = facts(entries: { "/Applications/Foo.app" => [0, true] })
      expect(kinds(plan(app, verb: :reinstall, world:).last)).to eq([:sudo])
    end

    it "is not walked on install" do
      world = facts(entries: { "/Applications/Foo.app" => [0, true] })
      expect(tokens(plan(app, verb: :install, world:).first)).to eq(["foo"])
    end

    it "goes first when the target is missing" do
      expect(tokens(plan(app).first)).to eq(["foo"])
    end
  end

  describe "the directory a bundle or link goes into" do
    let(:app) { cask { app "Foo.app", target: "/Applications/Foo.app" } }
    let(:binary) { cask { binary "foo", target: "/opt/bin/foo" } }

    it "puts an `app` last on every verb when its directory is not writable" do
      world = facts(entries: { "/Applications" => [0, true] }, unwritable: ["/Applications"])
      [:install, :upgrade, :reinstall].each do |verb|
        expect(kinds(plan(app, verb:, world:).last)).to eq([:sudo]), verb.to_s
      end
    end

    it "puts a `binary` last on every verb when its directory is not writable" do
      world = facts(entries: { "/opt/bin" => [0, true] }, unwritable: ["/opt/bin"])
      [:install, :upgrade, :reinstall].each do |verb|
        expect(kinds(plan(binary, verb:, world:).last)).to eq([:sudo]), verb.to_s
      end
    end

    it "checks the nearest existing ancestor when the directory is missing" do
      world = facts(entries: { "/opt" => [0, true] }, unwritable: ["/opt"])
      expect(messages(plan(binary, world:).last)).to eq(["`binary` needs `/opt` writable"])
    end

    it "goes first when the nearest existing ancestor is writable, whatever is above it" do
      world = facts(entries: { "/opt" => [501, true] }, unwritable: ["/"])
      expect(tokens(plan(binary, world:).first)).to eq(["foo"])
    end

    it "goes first when the directory is writable" do
      world = facts(entries: { "/Applications" => [501, true] })
      expect(tokens(plan(app, world:).first)).to eq(["foo"])
    end
  end

  describe "`add_altname_metadata` on a renamed bundle or link" do
    let(:app) { cask { app "Foo.app", target: "/Applications/Bar.app" } }
    let(:binary) { cask { binary "foo", target: "/opt/bin/bar" } }
    let(:theirs) { [0, true] }

    it "puts a bundle last when its target is owned by another user" do
      world = facts(entries: { "/Applications/Bar.app" => theirs })
      expect(kinds(plan(app, verb: :install, world:).last)).to eq([:sudo])
    end

    it "puts a bundle last when the target's realpath is owned by another user" do
      world = facts(
        entries:   { "/Applications/Bar.app" => [501, true], "/real/Bar.app" => theirs },
        realpaths: { "/Applications/Bar.app" => Pathname("/real/Bar.app") },
      )
      expect(kinds(plan(app, verb: :install, world:).last)).to eq([:sudo])
    end

    it "puts a bundle last when the target is not writable" do
      world = facts(entries: { "/Applications/Bar.app" => [501, true] }, unwritable: ["/Applications/Bar.app"])
      expect(kinds(plan(app, verb: :install, world:).last)).to eq([:sudo])
    end

    it "puts a bundle last when the target's realpath is not writable" do
      world = facts(
        entries:    { "/Applications/Bar.app" => [501, true], "/real/Bar.app" => [501, true] },
        realpaths:  { "/Applications/Bar.app" => Pathname("/real/Bar.app") },
        unwritable: ["/real/Bar.app"],
      )
      expect(kinds(plan(app, verb: :install, world:).last)).to eq([:sudo])
    end

    it "goes first when the target is the user's and writable" do
      world = facts(entries: { "/Applications/Bar.app" => [501, true] })
      expect(tokens(plan(app, verb: :install, world:).first)).to eq(["foo"])
    end

    it "goes first when the target does not exist yet" do
      expect(tokens(plan(app, verb: :install).first)).to eq(["foo"])
    end

    it "ignores a rename that only changes case" do
      cask = cask { app "Foo.app", target: "/Applications/foo.app" }
      world = facts(entries: { "/Applications/foo.app" => theirs })
      expect(tokens(plan(cask, verb: :install, world:).first)).to eq(["foo"])
    end

    it "does nothing off macOS, where brew makes it a no-op" do
      world = facts(entries: { "/Applications/Bar.app" => theirs })
      expect(tokens(plan(app, verb: :install, world:, macos: false).first)).to eq(["foo"])
    end

    it "checks the staged source of a renamed link, not its target" do
      world = facts(entries: { (binary.staged_path/"foo").to_s => theirs })
      expect(kinds(plan(binary, verb: :install, world:).last)).to eq([:sudo])
    end

    it "leaves a renamed link first when only its target is owned by another user" do
      world = facts(entries: { "/opt/bin/bar" => theirs })
      expect(tokens(plan(binary, verb: :install, world:).first)).to eq(["foo"])
    end
  end

  describe "install steps with `sudo: :if_needed`" do
    sig { params(directory: T.any(String, Pathname)).returns(String) }
    def unwritable_message(directory)
      "`postflight_steps` runs `remove` with sudo when #{directory} is not writable"
    end

    sig { params(path: String, base: T.nilable(String)).returns(Cask::Cask) }
    def remove_cask(path, base: nil)
      steps = [{ type: "remove", paths: [{ path:, base: }.compact], sudo: "if_needed" }]
      cask { postflight_steps steps: }
    end

    it "puts a `remove` step last on every verb when its directory is not writable" do
      [:install, :upgrade, :reinstall].each do |verb|
        expect(kinds(plan(remove_cask("/opt/x/f"), verb:, world: readonly_world("/opt/x")).last))
          .to eq([:sudo]), verb.to_s
      end
    end

    it "leaves a `remove` step first when its path is missing, as brew has nothing to remove" do
      world = facts(entries: { "/opt/x" => [0, true] }, unwritable: ["/opt/x"])
      expect(tokens(plan(remove_cask("/opt/x/f"), world:).first)).to eq(["foo"])
    end

    it "leaves a `remove` step first when its directory is missing" do
      expect(tokens(plan(remove_cask("/opt/x/f"), world: facts).first)).to eq(["foo"])
    end

    it "checks the directory of a globbed `remove` path" do
      world = facts(entries: { "/opt/x" => [0, true] }, unwritable: ["/opt/x"])
      expect([kinds(plan(remove_cask("/opt/x/*.plist"), world:).last),
              tokens(plan(remove_cask("/opt/y/*.plist"), world:).first)]).to eq([[:sudo], ["foo"]])
    end

    it "leaves a `remove` step first when its directory is writable" do
      world = facts(entries: { "/opt/x" => [501, true] })
      expect(tokens(plan(remove_cask("/opt/x/f"), world:).first)).to eq(["foo"])
    end

    it "puts a `symlink` step last when its target's directory is not writable" do
      cask = cask { postflight_steps { symlink "src", "/opt/bin/foo", sudo: :if_needed } }
      world = facts(entries: { "/opt/bin" => [0, true] }, unwritable: ["/opt/bin"])
      expect(kinds(plan(cask, world:).last)).to eq([:sudo])
    end

    it "leaves a `symlink` step first when its target's directory is missing, as brew makes it" do
      cask = cask { postflight_steps { symlink "src", "/opt/bin/foo", sudo: :if_needed } }
      expect(tokens(plan(cask, world: facts).first)).to eq(["foo"])
    end

    it "ignores `sudo: :if_needed` on step types brew doesn't check" do
      steps = [{ type: "run", executable: "/usr/bin/true", sudo: "if_needed" }]
      expect(tokens(plan(cask { postflight_steps steps: }, world: readonly_world("/usr/bin")).first)).to eq(["foo"])
    end

    it "leaves a `remove` step without `sudo` first" do
      cask = cask { postflight_steps { remove "/opt/x/f" } }
      expect(tokens(plan(cask, world: facts(unwritable: ["/opt/x"])).first)).to eq(["foo"])
    end

    it "puts a step whose path can't be resolved last" do
      expect(kinds(plan(remove_cask("{{version}}/f")).last)).to eq([:sudo])
    end

    it "resolves a step path against the cask's `appdir`" do
      cask = remove_cask("Foo/f", base: "appdir")
      world = readonly_world("#{cask.config.appdir}/Foo")
      expect(messages(plan(cask, world:).last)).to eq([unwritable_message("#{cask.config.appdir}/Foo")])
    end

    it "resolves a step path against the home directory" do
      result = plan(remove_cask("x/f", base: "home"), world: readonly_world("#{Dir.home}/x"))
      expect(messages(result.last)).to eq([unwritable_message("#{Dir.home}/x")])
    end

    it "puts a step whose directory is a glob last, as unresolved" do
      expect(messages(plan(remove_cask("/opt/*/f")).last))
        .to eq(["`postflight_steps` runs `remove` with sudo when its target is not writable"])
    end

    it "resolves a step path against the Homebrew prefix" do
      result = plan(remove_cask("x/f", base: "homebrew_prefix"), world: readonly_world("#{HOMEBREW_PREFIX}/x"))
      expect(messages(result.last)).to eq([unwritable_message("#{HOMEBREW_PREFIX}/x")])
    end

    it "resolves a step path against the cask's Caskroom path" do
      cask = remove_cask("x/f", base: "caskroom_path")
      result = plan(cask, world: readonly_world("#{cask.caskroom_path}/x"))
      expect(messages(result.last)).to eq([unwritable_message("#{cask.caskroom_path}/x")])
    end

    it "treats a base it can't resolve as unresolved, not as writable" do
      %w[temp relative search_path formula_opt_prefix formula_pkgetc bogus].each do |base|
        expect(messages(plan(remove_cask("x/f", base:)).last))
          .to eq(["`postflight_steps` runs `remove` with sudo when its target is not writable"]), base
      end
    end

    it "resolves a step path relative to the staged path" do
      cask = remove_cask("x/f", base: "staged_path")
      result = plan(cask, world: readonly_world("#{cask.staged_path}/x"))
      expect(messages(result.last)).to eq([unwritable_message("#{cask.staged_path}/x")])
    end
  end

  describe "`uninstall_*_steps`, run before an upgrade or reinstall" do
    sig { params(stanza: Symbol, steps: T::Array[T::Hash[Symbol, T.anything]]).returns(Cask::Cask) }
    def cask_with_steps(stanza, steps)
      cask { public_send(stanza, steps:) }
    end

    let(:upgrading) { [:upgrade, :reinstall] }
    let(:root_run) { [{ type: "run", executable: "/usr/bin/true", sudo: true }] }
    let(:keychain) { [{ type: "delete_keychain_certificate", name: "Foo CA" }] }
    let(:if_needed) { [{ type: "remove", paths: [{ path: "/opt/x/f" }], sudo: "if_needed" }] }
    let(:ownership) { [{ type: "set_ownership", paths: [{ path: "/Applications/Foo.app" }] }] }

    it "puts a cask last, for sudo, when a step runs as root" do
      [:uninstall_preflight_steps, :uninstall_postflight_steps].each do |stanza|
        upgrading.each do |verb|
          expect(kinds(plan(cask_with_steps(stanza, root_run), verb:).last)).to eq([:sudo]), "#{stanza} on #{verb}"
        end
      end
    end

    it "puts a cask last, for sudo, when a step deletes a keychain certificate" do
      upgrading.each do |verb|
        cask = cask_with_steps(:uninstall_postflight_steps, keychain)
        expect(kinds(plan(cask, verb:).last)).to eq([:sudo]), verb.to_s
      end
    end

    it "leaves a cask with root steps first on install" do
      cask = cask_with_steps(:uninstall_postflight_steps, root_run + keychain + ownership)
      expect(tokens(plan(cask, verb: :install).first))
        .to eq(["foo"])
    end

    it "checks `sudo: :if_needed` and `set_ownership` only on upgrade and reinstall" do
      steps = if_needed + ownership
      cask = cask_with_steps(:uninstall_preflight_steps, steps)
      world = readonly_world("/opt/x")
      expect([plan(cask, verb: :install, world:).first.size, kinds(plan(cask, verb: :upgrade, world:).last)])
        .to eq([1, [:sudo, :sudo, :dialog]])
    end

    it "counts an install-phase root step once" do
      expect(kinds(plan(cask_with_steps(:postflight_steps, root_run)).last)).to eq([:sudo])
    end

    it "leaves a cask with steps that need no sudo first" do
      steps = [{ type: "run", executable: "/usr/bin/true" }]
      expect(tokens(plan(cask_with_steps(:uninstall_postflight_steps, steps)).first)).to eq(["foo"])
    end
  end

  describe "the installed (old) cask" do
    let(:root_step) { [{ type: "run", executable: "/usr/bin/true", sudo: true }] }
    let(:plain_step) { [{ type: "run", executable: "/usr/bin/true" }] }

    sig { params(steps: T::Array[T::Hash[Symbol, T.anything]]).returns(Cask::Cask) }
    def with_uninstall_steps(steps) = cask { uninstall_postflight_steps steps: }

    it "takes `uninstall` directives from the installed cask, not the new one" do
      result = plan(cask, installed: { "foo" => cask { uninstall pkgutil: "com.foo" } })
      expect(kinds(result.last)).to eq([:sudo])
    end

    it "ignores `uninstall` directives the new cask added" do
      result = plan(cask { uninstall pkgutil: "com.foo" }, installed: { "foo" => cask })
      expect(tokens(result.first)).to eq(["foo"])
    end

    it "takes `Uninstall*Steps` from the installed cask, not the new one" do
      result = plan(with_uninstall_steps(plain_step), installed: { "foo" => with_uninstall_steps(root_step) })
      expect(kinds(result.last)).to eq([:sudo])
    end

    it "ignores `Uninstall*Steps` the new cask added" do
      result = plan(with_uninstall_steps(root_step), installed: { "foo" => with_uninstall_steps(plain_step) })
      expect(tokens(result.first)).to eq(["foo"])
    end

    it "keeps install-side rules on the new cask" do
      result = plan(cask { pkg "Foo.pkg" }, installed: { "foo" => cask })
      expect(kinds(result.last)).to eq([:sudo])
    end

    it "uses the installed cask's config for the new cask's targets, as `brew upgrade` merges it" do
      old = cask(config: Cask::Config.new(explicit: { appdir: "/Custom" })) { app "Foo.app" }
      world = facts(entries: { "/Custom" => [0, true] }, unwritable: ["/Custom"])
      expect(messages(plan(cask { app "Foo.app" }, installed: { "foo" => old }, world:).last))
        .to eq(["`app` needs `/Custom` writable"])
    end

    it "ignores the installed cask on install, config included" do
      old = cask(config: Cask::Config.new(explicit: { appdir: "/Custom" })) { app "Foo.app" }
      world = facts(entries: { "/Custom" => [0, true] }, unwritable: ["/Custom"])
      result = plan(cask { app "Foo.app" }, verb: :install, installed: { "foo" => old }, world:)
      expect(tokens(result.first)).to eq(["foo"])
    end

    it "takes the uninstall blocks of the installed cask" do
      old = cask_with_block(Cask::Artifact::PostflightBlock, :uninstall_postflight)
      expect(kinds(plan(cask, installed: { "foo" => old }).last)).to eq([:sudo])
    end

    it "ignores uninstall blocks the new cask added" do
      new = cask_with_block(Cask::Artifact::PostflightBlock, :uninstall_postflight)
      expect(tokens(plan(new, installed: { "foo" => cask }).first)).to eq(["foo"])
    end

    it "takes the uninstall phase of the installed cask's `symlink … uninstall: true` steps" do
      step = { type: "symlink", source: { path: "/opt/src" }, target: { path: "/opt/bin/foo" }, uninstall: true }
      entries = { "/opt/bin" => [0, true], "/opt/bin/foo" => [501, true] }
      links = { "/opt/bin/foo" => "/opt/src" }
      unwritable = facts(entries:, unwritable: ["/opt/bin"], links:)
      [true, "if_needed"].each do |sudo|
        old = cask { postflight_steps steps: [step.merge(sudo:)] }
        expect([kinds(plan(cask, installed: { "foo" => old }, world: unwritable).last),
                tokens(plan(cask, installed: { "foo" => old }, world: facts(entries:, links:)).first),
                tokens(plan(cask, installed: { "foo" => old }, world: facts).first)])
          .to eq([[:sudo], ["foo"], ["foo"]]), sudo.inspect
      end
    end

    it "leaves an installed link removal first when the target isn't a link to the source, as brew leaves it" do
      step = { type: "symlink", source: { path: "/opt/src" }, target: { path: "/opt/bin/foo" }, uninstall: true,
               sudo: true }
      old = cask { postflight_steps steps: [step] }
      entries = { "/opt/bin" => [0, true], "/opt/bin/foo" => [501, true] }
      worlds = {
        "regular file"     => facts(entries:, unwritable: ["/opt/bin"]),
        "unrelated link"   => facts(entries:, unwritable: ["/opt/bin"], links: { "/opt/bin/foo" => "/elsewhere" }),
        "link to the file" => facts(entries:, unwritable: ["/opt/bin"], links: { "/opt/bin/foo" => "/opt/src" }),
      }
      firsts = worlds.transform_values { |world| tokens(plan(cask, installed: { "foo" => old }, world:).first) }
      expect(firsts).to eq({ "regular file" => ["foo"], "unrelated link" => ["foo"], "link to the file" => [] })
    end

    it "compares a `relative` source with the link as written, and counts a source it can't resolve" do
      step = { type: "symlink", target: { path: "/opt/bin/foo" }, uninstall: true, sudo: true }
      entries = { "/opt/bin" => [0, true], "/opt/bin/foo" => [501, true] }
      relative = cask { postflight_steps steps: [step.merge(source: { path: "../src", base: "relative" })] }
      templated = cask { postflight_steps steps: [step.merge(source: { path: "{{version}}/src" })] }
      templated_relative = cask do
        postflight_steps steps: [step.merge(source: { path: "{{version}}/src", base: "relative" })]
      end
      world = ->(link) { facts(entries:, unwritable: ["/opt/bin"], links: { "/opt/bin/foo" => link }) }
      results = {
        "matching relative"  => plan(cask, installed: { "foo" => relative }, world: world.call("../src")),
        "different relative" => plan(cask, installed: { "foo" => relative }, world: world.call("/opt/src")),
        "unresolved source"  => plan(cask, installed: { "foo" => templated }, world: world.call("/opt/src")),
        "templated relative" => plan(cask, installed: { "foo" => templated_relative }, world: world.call("/opt/src")),
      }
      expect(results.transform_values { |result| kinds(result.last) })
        .to eq({ "matching relative" => [:sudo], "different relative" => [], "unresolved source" => [:sudo],
                 "templated relative" => [:sudo] })
    end

    it "treats an installed link removal it can't resolve, or that needs no sudo, accordingly" do
      step = { type: "symlink", source: { path: "src" }, uninstall: true }
      unresolved = cask do
        postflight_steps steps: [step.merge(target: { path: "{{version}}/foo" }, sudo: "if_needed")]
      end
      no_sudo = cask { postflight_steps steps: [step.merge(target: { path: "/opt/bin/foo" })] }
      expect([kinds(plan(cask, installed: { "foo" => unresolved }).last),
              tokens(plan(cask, installed: { "foo" => no_sudo }).first)]).to eq([[:sudo], ["foo"]])
    end

    it "puts a cask last when an installed link removal with `sudo: true` has an unresolved target" do
      step = { type: "symlink", source: { path: "src" }, target: { path: "{{version}}/foo" }, uninstall: true }
      old = cask { postflight_steps steps: [step.merge(sudo: true)] }
      expect(kinds(plan(cask, installed: { "foo" => old }, world: facts).last)).to eq([:sudo])
    end

    it "ignores installed `symlink` steps that aren't removed on uninstall" do
      step = { type: "symlink", source: { path: "src" }, target: { path: "/opt/bin/foo" }, sudo: "if_needed" }
      old = cask { postflight_steps steps: [step] }
      world = facts(entries: { "/opt/bin" => [0, true], "/opt/bin/foo" => [501, true] }, unwritable: ["/opt/bin"])
      expect(tokens(plan(cask, installed: { "foo" => old }, world:).first)).to eq(["foo"])
    end

    it "checks the installed cask's bundle, which brew backs up and deletes" do
      old = cask { app "Old.app", target: "/Applications/Old.app" }
      world = facts(entries: { "/Applications" => [501, true], "/Applications/Old.app" => [0, true] })
      expect(kinds(plan(cask { app "Foo.app", target: "/Applications/Foo.app" },
                        installed: { "foo" => old }, world:).last)).to eq([:sudo])
    end

    it "checks the directory of the installed cask's link, which brew unlinks" do
      old = cask { binary "old", target: "/opt/bin/old" }
      world = facts(entries: { "/opt/bin" => [0, true] }, unwritable: ["/opt/bin"])
      expect(kinds(plan(cask { app "Foo.app" }, installed: { "foo" => old }, world:).last)).to eq([:sudo])
    end

    it "lists a target both casks share once" do
      old = cask { app "Foo.app", target: "/Applications/Foo.app" }
      world = facts(entries: { "/Applications/Foo.app" => [0, true] })
      result = plan(cask { app "Foo.app", target: "/Applications/Foo.app" }, installed: { "foo" => old }, world:)
      expect(kinds(result.last)).to eq([:sudo])
    end
  end

  describe "`set_ownership` install steps" do
    it "puts a cask last on every verb, for sudo (`chown` retries with it) and a dialog" do
      cask = cask { postflight_steps { set_ownership "/Applications/Foo.app" } }
      [:install, :upgrade, :reinstall].each do |verb|
        expect(kinds(plan(cask, verb:).last)).to eq([:sudo, :dialog]), verb.to_s
      end
    end
  end

  describe "without a terminal" do
    let(:sudo_cask) { cask("sudo-cask") { pkg "Foo.pkg" } }
    let(:dialog_cask) { cask("dialog-cask") { uninstall quit: "com.foo" } }
    let(:dependent_cask) { cask("dependent-cask") { depends_on formula: "llvm" } }
    let(:first_cask) { cask("first-cask") }

    sig { params(env: T::Hash[String, String]).returns(Timed::Casks::Plan) }
    def no_terminal_plan(env = {})
      plan(sudo_cask, dialog_cask, dependent_cask, first_cask, in_run: ["llvm"], tty: -> { false }, env:)
    end

    it "skips only the casks that need sudo" do
      expect(tokens(no_terminal_plan.skipped)).to eq(["sudo-cask"])
    end

    it "keeps the dialog and dependent casks last" do
      expect(tokens(no_terminal_plan.last)).to eq(["dialog-cask", "dependent-cask"])
    end

    it "keeps the first casks first" do
      expect(tokens(no_terminal_plan.first)).to eq(["first-cask"])
    end

    it "keeps the reasons of a skipped cask" do
      expect(kinds(no_terminal_plan.skipped)).to eq([:sudo])
    end

    it "skips nothing with a terminal or with `SUDO_ASKPASS` set" do
      expect([plan(sudo_cask, tty: -> { true }).skipped,
              no_terminal_plan("SUDO_ASKPASS" => "/usr/bin/askpass").skipped]).to eq([[], []])
    end

    it "treats an empty `SUDO_ASKPASS` as unset" do
      expect(tokens(no_terminal_plan("SUDO_ASKPASS" => "").skipped)).to eq(["sudo-cask"])
    end

    it "doesn't check the terminal when no cask needs sudo" do
      expect { plan(first_cask, dialog_cask, tty: -> { raise "checked" }) }.not_to raise_error
    end
  end

  # rubocop:enable Sorbet/BlockMethodDefinition
end
