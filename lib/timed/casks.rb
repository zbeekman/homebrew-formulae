# typed: strict
# frozen_string_literal: true

require "find"
require "sorbet-runtime"

module Timed
  # Sorts casks into those to run before the formula batches ("first") and
  # after them ("last"), and says why. Pure Ruby over cask objects: what is on
  # disk and whether sudo can prompt come in through seams; no brew calls.
  module Casks
    # One file as `lstat` sees it (symlinks not followed), except `directory`,
    # which follows symlinks like `Pathname#directory?`.
    class FileEntry < T::Struct
      const :path, Pathname
      const :uid, Integer
      # Readable by the current user.
      const :readable, T::Boolean
      # A directory, or a symlink to one, as `Pathname#directory?` says.
      const :directory, T::Boolean, default: false
    end

    # What the classifier needs to know about the disk: `DiskFacts` reads it;
    # specs pass fakes.
    module Facts
      extend T::Helpers

      interface!

      # The current user's uid.
      sig { abstract.returns(Integer) }
      def uid; end

      # `nil` when nothing (not even a symlink) is at `path`.
      sig { abstract.params(path: Pathname).returns(T.nilable(FileEntry)) }
      def lstat(path); end

      # `path` and everything under it, each by `lstat`; symlinks are not
      # followed. Empty when `path` is missing.
      sig { abstract.params(path: Pathname).returns(T::Array[FileEntry]) }
      def walk(path); end

      # Like `Pathname#writable?`: follows symlinks, false when missing.
      sig { abstract.params(path: Pathname).returns(T::Boolean) }
      def writable?(path); end

      # Like `Pathname#realpath`, `nil` when missing.
      sig { abstract.params(path: Pathname).returns(T.nilable(Pathname)) }
      def realpath(path); end

      # Like `Pathname#readlink`, `nil` when `path` isn't a symlink.
      sig { abstract.params(path: Pathname).returns(T.nilable(Pathname)) }
      def readlink(path); end
    end

    # `Facts` as the disk has them.
    class DiskFacts
      include Facts

      sig { override.returns(Integer) }
      def uid = Process.euid

      # A directory that can't be searched can't be read whole either.
      sig { override.params(path: Pathname).returns(T.nilable(FileEntry)) }
      def lstat(path)
        stat = path.lstat
        FileEntry.new(path:, uid: stat.uid, readable: stat.readable? && (!stat.directory? || stat.executable?),
                      directory: path.directory?)
      rescue SystemCallError
        nil
      end

      sig { override.params(path: Pathname).returns(T::Array[FileEntry]) }
      def walk(path)
        return [] unless lstat(path)

        entries = T.let([], T::Array[FileEntry])
        Find.find(path.to_s) { |file| lstat(Pathname(file))&.then { |entry| entries << entry } }
        entries
      end

      sig { override.params(path: Pathname).returns(T::Boolean) }
      def writable?(path) = path.writable?

      sig { override.params(path: Pathname).returns(T.nilable(Pathname)) }
      def realpath(path)
        path.realpath
      rescue SystemCallError
        nil
      end

      sig { override.params(path: Pathname).returns(T.nilable(Pathname)) }
      def readlink(path)
        path.readlink
      rescue SystemCallError
        nil
      end
    end

    # Whether `/dev/tty` opens, where sudo asks for a password: not without a
    # controlling terminal, e.g. under `launchd` or `cron`.
    sig { returns(T::Boolean) }
    def self.terminal?
      File.open("/dev/tty") { true }
    rescue SystemCallError
      false
    end

    # Why a cask goes last. `kind` is `:dependency` (waits for the run),
    # `:sudo` (may prompt for a password) or `:dialog` (may raise a macOS
    # dialog or permission prompt, but needs no sudo).
    class Reason < T::Struct
      const :kind, Symbol
      const :message, String
    end

    # A cask's place in the run and the reasons for it.
    class Entry < T::Struct
      const :cask, Cask::Cask
      const :reasons, T::Array[Reason], default: []
    end

    # Casks to run before the formula batches, after them, and not at all.
    class Plan < T::Struct
      const :first, T::Array[Entry]
      const :last, T::Array[Entry]
      const :skipped, T::Array[Entry]
    end

    # `in_run` names the formulae in this run and `casks_in_run` its casks, as
    # a formula and a cask may share a name. `installed_for` maps each formula
    # in it that brew installs only as a dependency to the formulae it installs
    # it for. `macos`
    # says whether brew runs `add_altname_metadata`. `tty` says whether
    # `/dev/tty` can be opened, where sudo reads the password.
    #
    # `installed`, `needs` and `missing` are keyed by the cask's full name, as
    # casks from different taps may share a token.
    #
    # `installed` maps a cask to the one loaded from its installed caskfile.
    # On upgrade and reinstall brew runs the `uninstall_phase` of every artifact
    # of that cask, so the uninstall side (`uninstall` directives, uninstall
    # flight blocks and steps, and its bundles and links) applies to it (to the
    # new cask when it is missing), and brew merges its config into the new
    # cask's, as `Cask::Upgrade` does: this assigns `Cask#config` of the new
    # casks.
    #
    # `force` is `install --force`, which brew passes on to the casks; it only
    # matters for `:install` (an upgrade or reinstall always deletes the old
    # bundle).
    #
    # `zap` is `reinstall --zap`, which brew alone honours: it uninstalls the
    # installed cask without a successor and dispatches its `zap` stanza.
    #
    # `needs` maps a cask to the formulae and the casks it needs that are in
    # the run, e.g. through its formulae's dependencies, which brew may install
    # before it, as the run names them (the caller matches them by full name);
    # without an entry, its own `depends_on` counts, matched by name.
    #
    # `missing` maps a cask to those brew's cask installer would install
    # before it as they aren't installed: what their installs need (sudo,
    # a dialog) counts for the cask, naming the dependency.
    #
    # `cask_dependencies` maps a cask to the casks brew may install before it,
    # by full name, and the casks among those that can't be loaded, as named
    # (formulae never count); without an entry, its own `depends_on cask:`, as
    # named. See `skip_dependents`.
    sig {
      params(
        casks:             T::Array[Cask::Cask],
        verb:              Symbol,
        in_run:            T::Array[String],
        facts:             Facts,
        tty:               T.proc.returns(T::Boolean),
        casks_in_run:      T::Array[String],
        macos:             T::Boolean,
        env:               T::Hash[String, String],
        installed:         T::Hash[String, Cask::Cask],
        zap:               T::Boolean,
        force:             T::Boolean,
        needs:             T::Hash[String, [T::Array[String], T::Array[String]]],
        missing:           T::Hash[String, T::Array[Cask::Cask]],
        cask_dependencies: T::Hash[String, [T::Array[String], T::Array[String]]],
        installed_for:     T::Hash[String, T::Array[String]],
      ).returns(Plan)
    }
    def self.plan(casks, verb:, in_run:, facts:, tty:, casks_in_run: [], macos: OS.mac?, env: ENV.to_h,
                  installed: {}, zap: false, force: false, needs: {}, missing: {}, cask_dependencies: {},
                  installed_for: {})
      upgrading = [:upgrade, :reinstall].include?(verb)
      zap &&= verb == :reinstall
      entries = casks.map do |cask|
        old = installed[cask.full_name] if upgrading
        formulae, needed_casks = needs.fetch(cask.full_name) { [cask.depends_on.formula, cask.depends_on.cask] }
        own = depends_on_run(formulae, in_run:, installed_for:) +
              depends_on_run(needed_casks, in_run: casks_in_run, casks: true) +
              reasons(cask, old:, upgrading:, zap:, force:, facts:, macos:)
        # Brew installs a dependency without `force`, as on request.
        dependencies = missing.fetch(cask.full_name, []).flat_map do |dependency|
          reasons(dependency, old: nil, upgrading: false, zap: false, force: false, facts:, macos:).map do |reason|
            Reason.new(kind: reason.kind, message: "dependency `#{dependency.full_name}`: #{reason.message}")
          end
        end
        Entry.new(cask:, reasons: own + dependencies)
      end
      first, last = entries.partition { |entry| entry.reasons.empty? }
      # A cask upgrade that fails partway is rolled back, and the rollback may
      # need sudo too, so without a way to prompt these are skipped, not tried.
      skipped, last = last.partition { |entry| entry.reasons.any? { |reason| reason.kind == :sudo } }
      if skipped.empty? || tty.call || !env["SUDO_ASKPASS"].to_s.empty?
        last = entries - first
        skipped = []
      elsif verb == :install
        skipped, first, last = skip_dependents(skipped, first, last, cask_dependencies:)
      end
      Plan.new(first:, last:, skipped:)
    end

    # Brew's cask installer installs a missing cask dependency before the cask,
    # so a dependent of a skipped cask would run the skipped cask's sudo. Move
    # every such entry to `skipped` too, and those that depend on them in turn.
    # Only on `install`: it installs just the missing dependencies, and a
    # dependency that is in an `upgrade` or `reinstall` run is installed
    # already, so its dependents are left alone there (the caller classifies
    # the install of an installed, outdated cask as `:upgrade`).
    # A dependent is matched by its cask dependencies only (see `plan`'s
    # `cask_dependencies`): by full name, or, for one that can't be loaded, by
    # name alone, which may skip it for another tap's cask of that name, to be
    # safe.
    sig {
      params(skipped: T::Array[Entry], first: T::Array[Entry], last: T::Array[Entry],
             cask_dependencies: T::Hash[String, [T::Array[String], T::Array[String]]])
        .returns([T::Array[Entry], T::Array[Entry], T::Array[Entry]])
    }
    def self.skip_dependents(skipped, first, last, cask_dependencies: {})
      remaining = first + last
      queue = skipped.dup
      while (current = queue.shift)
        dependency = current.cask.full_name
        dependents = remaining.select do |entry|
          resolved, unresolved = cask_dependencies.fetch(entry.cask.full_name) { [[], entry.cask.depends_on.cask] }
          resolved.include?(dependency) ||
            unresolved.any? { |name| Utils.name_from_full_name(name) == current.cask.token }
        end
        remaining -= dependents
        moved = dependents.map do |entry|
          reason = Reason.new(kind: :dependency, message: "depends on `#{dependency}`, which is skipped")
          Entry.new(cask: entry.cask, reasons: entry.reasons + [reason])
        end
        skipped += moved
        queue += moved
      end
      [skipped, first & remaining, last & remaining]
    end

    sig {
      params(
        cask:      Cask::Cask,
        old:       T.nilable(Cask::Cask),
        upgrading: T::Boolean,
        zap:       T::Boolean,
        force:     T::Boolean,
        facts:     Facts,
        macos:     T::Boolean,
      ).returns(T::Array[Reason])
    }
    def self.reasons(cask, old:, upgrading:, zap:, force:, facts:, macos:)
      cask.config = cask.default_config.merge(old.config) if old
      reasons = requires_sudo(cask) + flight_blocks(cask, uninstall: false)
      # Upgrade and reinstall uninstall the old version first.
      if upgrading
        uninstalled = old || cask
        reasons += flight_blocks(uninstalled, uninstall: true) + uninstall_directives(uninstalled, zap:) +
                   uninstall_steps(uninstalled, facts:) + replaced_bundles([cask, old].compact, facts:)
        reasons += unwritable_directories(old, facts:) if old
      elsif force
        # `install --force` overwrites an existing bundle through the same `delete`.
        reasons += replaced_bundles([cask], facts:)
      end
      reasons += unwritable_directories(cask, facts:)
      reasons += altname_metadata(cask, facts:) if macos
      (reasons + install_steps(cask, facts:)).uniq(&:message)
    end

    # Brew's own check, used for `HOMEBREW_NO_SUDO` in `cask/installer.rb`.
    sig { params(cask: Cask::Cask).returns(T::Array[Reason]) }
    def self.requires_sudo(cask)
      cask.artifacts.select(&:requires_sudo?).map do |artifact|
        Reason.new(kind: :sudo, message: "`#{artifact.class.dsl_key}` requires sudo")
      end
    end

    # What a cask `needed` that is in this run (see `plan`): formulae, or,
    # with `casks`, casks, which the reason says.
    sig {
      params(needed: T::Array[String], in_run: T::Array[String], installed_for: T::Hash[String, T::Array[String]],
             casks: T::Boolean).returns(T::Array[Reason])
    }
    def self.depends_on_run(needed, in_run:, installed_for: {}, casks: false)
      names = in_run.map { |name| Utils.name_from_full_name(name) }
      needed.filter_map do |name|
        next unless names.include?(Utils.name_from_full_name(name))

        dependents = installed_for[name]
        where = if dependents
          "this run installs for #{dependents.map { |dependent| "`#{dependent}`" }.join(", ")}"
        else
          "is in this run"
        end
        what = casks ? "the `#{name}` cask" : "`#{name}`"
        Reason.new(kind: :dependency, message: "depends on #{what}, which #{where}")
      end
    end

    # Arbitrary Ruby that may call `system_command ..., sudo: true`, invisible
    # to `requires_sudo?`. Conservative: blocks that don't need sudo go last too.
    # The `uninstall_*` blocks run when a cask is uninstalled, the others when
    # it is installed.
    sig { params(cask: Cask::Cask, uninstall: T::Boolean).returns(T::Array[Reason]) }
    def self.flight_blocks(cask, uninstall:)
      cask.artifacts.grep(Cask::Artifact::AbstractFlightBlock).flat_map do |artifact|
        artifact.directives.keys.select { |key| key.start_with?("uninstall_") == uninstall }.map do |key|
          Reason.new(kind: :sudo, message: "`#{key}` block may call sudo")
        end
      end
    end

    # Run as root, via `sudo`.
    ROOT_UNINSTALL_DIRECTIVES = [:pkgutil, :launchctl, :kext, :delete].freeze
    # Run as root only with `sudo: true`.
    SCRIPT_UNINSTALL_DIRECTIVES = [:script, :early_script].freeze

    # With `reinstall --zap` brew passes no `successor`, so `login_item` runs,
    # and after the `uninstall` stanza it dispatches every directive of the
    # `zap` stanza, unfiltered (`Installer#zap`).
    sig { params(cask: Cask::Cask, zap: T::Boolean).returns(T::Array[Reason]) }
    def self.uninstall_directives(cask, zap:)
      reasons = cask.artifacts.grep(Cask::Artifact::Uninstall).flat_map do |artifact|
        # Brew skips `signal` on upgrade and reinstall unless `on_upgrade` names it.
        raw_on_upgrade = artifact.directives[:on_upgrade]
        on_upgrade = case raw_on_upgrade
        when Symbol then [raw_on_upgrade]
        when Array then raw_on_upgrade.map(&:to_sym)
        else []
        end
        directive_reasons(artifact, "uninstall", signal: on_upgrade.include?(:signal), login_item: zap)
      end
      return reasons unless zap

      reasons + cask.artifacts.grep(Cask::Artifact::Zap).flat_map do |artifact|
        directive_reasons(artifact, "zap", signal: true, login_item: true)
      end
    end

    # `signal` is always present in the directives, empty when unused.
    sig {
      params(artifact: Cask::Artifact::AbstractUninstall, stanza: String, signal: T::Boolean, login_item: T::Boolean)
        .returns(T::Array[Reason])
    }
    def self.directive_reasons(artifact, stanza, signal:, login_item:)
      artifact.directives.compact_blank.filter_map do |directive, value|
        if ROOT_UNINSTALL_DIRECTIVES.include?(directive) ||
           (SCRIPT_UNINSTALL_DIRECTIVES.include?(directive) && value.is_a?(Hash) && value[:sudo] == true)
          Reason.new(kind: :sudo, message: "`#{stanza} #{directive}` runs as root")
        elsif directive == :quit || (directive == :signal && signal) || (directive == :login_item && login_item)
          Reason.new(kind: :dialog, message: "`#{stanza} #{directive}` may raise a dialog")
        end
      end
    end

    # Brew backs an existing bundle up with `cp -pR` (sudo retry when anything
    # is unreadable), deletes it with `gain_permissions_remove` (`sudo chown`
    # for an entry that isn't the user's) and moves the new one in (`sudo cp`
    # when the target isn't writable). Typical trigger: root-owned helpers
    # inside an app that updated itself.
    # A target shared by the old and new cask is walked once.
    sig { params(casks: T::Array[Cask::Cask], facts: Facts).returns(T::Array[Reason]) }
    def self.replaced_bundles(casks, facts:)
      moved = casks.flat_map { |cask| cask.artifacts.grep(Cask::Artifact::Moved) }
      moved.uniq(&:target).filter_map do |artifact|
        target = artifact.target
        next if facts.lstat(target).nil?

        message = if (entry = facts.walk(target).find { |e| e.uid != facts.uid || !e.readable })
          "`#{artifact.class.dsl_key}` target has `#{entry.path}` not owned by or readable by you"
        elsif !facts.writable?(target)
          "`#{artifact.class.dsl_key}` target `#{target}` is not writable"
        end
        Reason.new(kind: :sudo, message:) if message
      end
    end

    # `sudo mkdir`, `sudo ln`, `sudo rm` for the old link, and `sudo cp` for a
    # bundle, when the nearest existing ancestor of the target's directory is
    # not writable.
    sig { params(cask: Cask::Cask, facts: Facts).returns(T::Array[Reason]) }
    def self.unwritable_directories(cask, facts:)
      cask.artifacts.grep(Cask::Artifact::Relocated).filter_map do |artifact|
        directory = artifact.target.dirname
        directory = directory.dirname while facts.lstat(directory).nil? && !directory.root?
        next if facts.writable?(directory)

        Reason.new(kind: :sudo, message: "`#{artifact.class.dsl_key}` needs `#{directory}` writable")
      end
    end

    # `Relocated#add_altname_metadata` runs `chmod u+rw` on a file and its
    # realpath and `xattr -w` on the file, each with `sudo: nil`, when the
    # target's basename differs from the source's. The file is the target of a
    # bundle and the (staged) source of a link.
    sig { params(cask: Cask::Cask, facts: Facts).returns(T::Array[Reason]) }
    def self.altname_metadata(cask, facts:)
      cask.artifacts.grep(Cask::Artifact::Relocated).filter_map do |artifact|
        next if artifact.source.basename.to_s.casecmp?(artifact.target.basename.to_s)

        file = artifact.is_a?(Cask::Artifact::Symlinked) ? artifact.source : artifact.target
        unless [file, facts.realpath(file)].compact.all? { |path| user_can_change?(path, facts:) }
          Reason.new(kind: :sudo, message: "`#{artifact.class.dsl_key}` needs `#{file}` owned by and writable by you")
        end
      end
    end

    sig { params(path: Pathname, facts: Facts).returns(T::Boolean) }
    def self.user_can_change?(path, facts:)
      entry = facts.lstat(path)
      entry.nil? || (entry.uid == facts.uid && facts.writable?(path))
    end

    # `requires_sudo?` passes `include_optional: false`, so brew runs steps
    # with `sudo: :if_needed` with sudo only when the target's parent directory
    # is not writable (`dirname.writable?` is false when it is missing), and
    # `set_ownership` needs the terminal's macOS App Management permission,
    # may raise its prompt and fails without it (`install_steps.rb`).
    #
    # `Uninstall*Steps` have no `install_phase`, so brew's `requires_sudo?` is
    # always false for them, yet they run before an upgrade or reinstall: ask
    # the runner's own predicate there, and skip them on install.
    sig { params(cask: Cask::Cask, facts: Facts).returns(T::Array[Reason]) }
    def self.install_steps(cask, facts:)
      cask.artifacts.grep(Cask::Artifact::AbstractInstallSteps).select { |a| a.respond_to?(:install_phase) }
          .flat_map do |artifact|
        artifact.steps.flat_map { |step| step_reasons(cask, artifact.class.dsl_key, step, facts:) }
      end
    end

    # The cask being uninstalled, which is the installed one on upgrade.
    # `Uninstall*Steps` run all their steps; `preflight_steps` and
    # `postflight_steps` only remove their `symlink … uninstall: true` links
    # (`run_uninstall_step`).
    sig { params(cask: Cask::Cask, facts: Facts).returns(T::Array[Reason]) }
    def self.uninstall_steps(cask, facts:)
      installing, uninstalling = cask.artifacts.grep(Cask::Artifact::AbstractInstallSteps)
                                     .partition { |artifact| artifact.respond_to?(:install_phase) }
      links = installing.flat_map { |artifact| removed_links(cask, artifact.class.dsl_key, artifact.steps, facts:) }
      steps = uninstalling.flat_map do |artifact|
        stanza = artifact.class.dsl_key
        reasons = artifact.steps.flat_map { |step| step_reasons(cask, stanza, step, facts:) }
        if Homebrew::InstallSteps::Runner.new(context: cask).sudo_required?(artifact.steps, include_optional: false)
          reasons << Reason.new(kind: :sudo, message: "`#{stanza}` runs a step as root")
        end
        reasons
      end
      links + steps
    end

    sig {
      params(cask: Cask::Cask, stanza: Symbol, steps: Homebrew::InstallSteps::Steps, facts: Facts)
        .returns(T::Array[Reason])
    }
    def self.removed_links(cask, stanza, steps, facts:)
      steps.select { |step| step["type"] == "symlink" && step["uninstall"] == true }.filter_map do |step|
        sudo = step["sudo"]
        next unless [true, "if_needed"].include?(sudo)

        target = step["target"]
        # A `symlink` step always has a hash target; the guard is for Sorbet.
        path = resolve_path(cask, target) if target.is_a?(Hash)
        source_spec = step["source"]
        source = link_source(cask, source_spec) if source_spec.is_a?(Hash)
        # Brew returns early unless the target is a symlink to the source, and
        # only escalates when its directory isn't writable.
        next if path && source && (facts.readlink(path) != source || facts.writable?(path.dirname))

        Reason.new(kind: :sudo, message: "`#{stanza}` removes its `symlink` on uninstall with sudo")
      end
    end

    sig {
      params(cask: Cask::Cask, stanza: Symbol, step: Homebrew::InstallSteps::Step, facts: Facts)
        .returns(T::Array[Reason])
    }
    def self.step_reasons(cask, stanza, step, facts:)
      if step["type"] == "set_ownership"
        # `chown` runs with `sudo: nil`, which `SystemCommand` retries with sudo.
        [Reason.new(kind: :sudo, message: "`#{stanza}` runs `set_ownership`, which retries `chown` with sudo"),
         Reason.new(kind: :dialog, message: "`#{stanza}` runs `set_ownership`, which needs App Management access")]
      elsif step["sudo"] == "if_needed"
        if_needed_reasons(cask, stanza, step, facts:)
      else
        []
      end
    end

    # Brew runs the step with sudo when the parent directory of its target is
    # not writable. `create_symlink` first runs `mkpath` without sudo, so a
    # missing directory is no reason, and `remove` returns early for a path that
    # isn't there. A path that can't be resolved here counts, to be safe.
    sig {
      params(cask: Cask::Cask, stanza: Symbol, step: Homebrew::InstallSteps::Step, facts: Facts)
        .returns(T::Array[Reason])
    }
    def self.if_needed_reasons(cask, stanza, step, facts:)
      specs = case step["type"]
      when "remove" then [step["paths"]]
      when "symlink" then [step["target"]]
      else []
      end
      specs.flatten.grep(Hash).filter_map do |spec|
        path = resolve_path(cask, spec)
        # With `source_glob`, brew links into a target that is a directory
        # (`target/source.basename`), and so checks that directory. The number
        # of matches is unknown until staging; an existing directory is the case
        # that matters, a missing one is made without sudo.
        into_directory = path && step["type"] == "symlink" && step["source_glob"] == true &&
                         facts.lstat(path)&.directory
        directory = into_directory ? path : path&.dirname
        if path && directory
          # A glob is expanded by brew, so the directory stands in for its matches.
          present = (step["type"] == "remove" && !glob?(path.basename.to_s)) ? path : directory
          next if facts.lstat(present).nil? || facts.writable?(directory)
        end

        Reason.new(kind: :sudo, message: "`#{stanza}` runs `#{step["type"]}` with sudo when " \
                                         "#{directory || "its target"} is not writable")
      end
    end

    # What brew compares `readlink` with: a `relative` source as written,
    # anything else resolved. `nil` when it can't be resolved here.
    sig { params(cask: Cask::Cask, spec: Homebrew::InstallSteps::PathSpec).returns(T.nilable(Pathname)) }
    def self.link_source(cask, spec)
      path = spec.fetch("path")
      return if path.include?("{{")

      (spec["base"] == "relative") ? Pathname(path) : resolve_path(cask, spec)
    end

    sig { params(string: String).returns(T::Boolean) }
    def self.glob?(string) = string.match?(/[?*\[{]/)

    # Templates, globs in the directory, and every base other than the blank
    # and `absolute` ones, `home`, `homebrew_prefix`, `staged_path`,
    # `caskroom_path` and the `Cask::Config` directories (so `relative`,
    # `temp`, `formula_*` and any unknown base) are left unresolved.
    sig { params(cask: Cask::Cask, spec: Homebrew::InstallSteps::PathSpec).returns(T.nilable(Pathname)) }
    def self.resolve_path(cask, spec)
      path = spec.fetch("path")
      return if path.include?("{{") || glob?(File.dirname(path))

      case (base = spec["base"])
      when nil, "", "absolute" then Pathname(path).expand_path
      when "home" then Pathname(Dir.home)/path
      when "homebrew_prefix" then HOMEBREW_PREFIX/path
      when "staged_path" then cask.staged_path/path
      when "caskroom_path" then cask.caskroom_path/path
      else
        option = base.to_s.to_sym
        cask.config.public_send(option)/path if Cask::Config::DEFAULT_DIRS.key?(option)
      end
    end
  end
end
