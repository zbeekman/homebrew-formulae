# brew upgrade-timed

## Usage

`brew upgrade-timed` \[*`options`*\] \[*`installed_formula`*\|*`installed_cask`* ...\]

## Description

Upgrade outdated, unpinned formulae like `brew upgrade`, in timed batches:
dependencies first, then the quickest, so quick upgrades finish early and slow
builds never hold them up. With no *`installed_formula`* named, that is every
outdated formula; with some named, it is those. A formula installed through an
alias whose target has changed is upgraded to the new target, unless that is
already installed and up to date, as `brew upgrade` does. Either way it
includes the outdated dependencies Homebrew would upgrade first, found as
Homebrew finds them: build dependencies only count for formulae built from
source that are not current, and a formula that pours a bottle leaves alone any
dependency installed at least at the version its bottle was built with (when
the bottle's manifest can be downloaded).

The estimates come from the log shown by
[`brew build-times`](build-times.md). A formula that will pour a bottle is
estimated from its earlier pours only, and one that will build from source from
its earlier source builds only, as `brew build-times stats` shows them.

It first auto-updates as `brew upgrade` does, unless `$HOMEBREW_NO_AUTO_UPDATE`
is set, and runs again from the start if that fetched anything. Then it prints
the plan from `brew upgrade --dry-run`, with the same options and named
arguments, and the batches with their estimates, then asks for confirmation
once for the whole run under `brew upgrade`'s rules: with named arguments, only
if the batches or the casks it would upgrade include any other than the names
as given (so a new alias target, an alias or a name not given exactly as the
formula's or cask's full name, e.g. a core formula with its tap or another
tap's formula without it, counts as another), or Homebrew would install
dependencies or upgrade outdated dependents of the named formulae; otherwise,
if there is anything to upgrade. Without a terminal it carries on without
asking, as `brew upgrade` does.

Formulae it won't upgrade (up to date, not installed, pinned, unknown or
needing a newer version of a pinned dependency) are reported by
`brew upgrade --dry-run`'s plan, and the command fails if that does. Relative
paths to formula or cask files are passed on as absolute paths, as Homebrew
runs from the home directory. With no *`installed_formula`* named, it warns
about any formula that `brew upgrade --dry-run` lists but the batches leave
out, or the other way round (formulae given to `--exclude` count as planned,
and a name that is also an installed cask's token is taken for the cask).
`--interactive` can't be used, as it needs a terminal: use
`brew upgrade --interactive` instead.

Outdated casks are upgraded too, as `brew upgrade` does, before or after the
batches: see [Casks](#casks).

`brew upgrade-timed` is a command in this tap. Trust it once with
`brew trust --command zbeekman/tap/upgrade-timed`, or trust the whole tap. See
[Tap Trust](https://docs.brew.sh/Tap-Trust).

## Running

Once confirmed, it runs
`brew upgrade --formula --yes --display-times` *`options`* *`formula`* ...
once per batch, from the home directory, with the formula options it was
given other than `--minimum-version` (which the plan has already applied).
With `--debug`, Homebrew's interactive debugger is turned off
(`$HOMEBREW_DISABLE_DEBREW`), as its prompt couldn't be answered.

`--build-from-source` only builds the named formulae from source, as with
`brew upgrade`, but `--debug-symbols` would apply to every source build in a
call. So when it is given, each batch is split, in its order (dependencies
first), into runs of formulae the plan shows as a `pour` and runs of the named
formulae and the others built from source. Each run is one call: a run of
pours without either option, the rest with them. A batch without pours stays
one call. A formula that needs one that failed in an earlier call of the batch
is skipped, as in later batches. Calls for pours skip Homebrew's check for
outdated dependents (`$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`), which would
pour a named formula before its own call builds it;
`brew upgrade --build-from-source` doesn't run that check for them either.

Homebrew's output and errors are shown as they arrive, in colour if the output
is a terminal (unless `$HOMEBREW_NO_COLOR` is set), and kept without colours in
`$HOMEBREW_LOGS/timed/`*`time`*`-`*`pid`*`-batch`*`N`*`.log`, where *`time`* is
when the run started, e.g. `20260930-143000`, and *`pid`* its process ID, so
runs started in the same second keep their own logs. After each batch, it:

- checks that the new version of each formula is installed; if it isn't, the
  formula failed, and so does the command, as with `brew upgrade`;
- logs each formula Homebrew worked on, including those it upgraded alongside
  the batch (e.g. outdated dependents), in the log shown by
  [`brew build-times`](build-times.md), with `upgrade`, the batch (`main`, or
  `last` for `--last`) and the batch's log. A failed formula is logged with
  the version it was to be upgraded to;
- adds the times to the install receipt (`INSTALL_RECEIPT.json`) of each keg
  Homebrew installed, under `build_times`, unless `--no-stamp-receipts` is
  given;
- skips the formulae in later batches that need one that failed or was
  skipped, and logs them as `skipped`. The other formulae still run.

It doesn't run `brew cleanup` itself: each `brew upgrade` cleans up the
formulae it upgraded, and runs Homebrew's periodic cleanup, unless
`$HOMEBREW_NO_INSTALL_CLEANUP` is set.

Ctrl-C stops Homebrew too. The command waits for it to exit, then logs and
stamps the formulae of the stopped batch that Homebrew finished (with build and
wall times, but no install time), lists the rest of that batch and every later
batch, none of which are logged, and exits with status 130, as Homebrew does.
The batches that finished are logged. It exits with status 130 even if
Homebrew finished the last batch anyway.

## Casks

Casks are neither timed nor logged. With no *`installed_cask`* named, the
outdated casks are upgraded as `brew upgrade` picks them, unless `--formula` is
given; with some named, those; with only formulae named, none. Pinned casks,
casks not below `--minimum-version` and `installer manual` casks are left out,
for `brew upgrade --dry-run`'s plan to report.

They are upgraded in at most two calls of
`brew upgrade --cask --yes` *`options`* *`cask`* ... from the home directory
with Homebrew's output straight to the terminal, each given the cask options
it was given other than `--minimum-version`, with `--binaries` or
`--no-binaries` where that differs from `$HOMEBREW_CASK_OPTS`. The calls are:

- the first, before the batches, for the casks that need nothing in the run
  and shouldn't prompt;
- the last, after the batches, for the rest, so that a password prompt or a
  macOS dialog only waits once the builds are done:
  - casks that need a formula or cask in the run, directly or through the
    dependencies of the formulae and casks they need, which Homebrew may
    install for them;
  - casks with a cask dependency that isn't installed, which Homebrew would
    install first, whose install may need sudo or raise a dialog by the rules
    below (each reason names the dependency). With `--skip-cask-deps`,
    Homebrew installs no cask dependency, so neither these nor a cask
    dependency in the run count, but it still installs the formulae those
    need, which do;
  - casks that may need sudo: those Homebrew itself says need it (e.g. `pkg`,
    `installer script:` with `sudo: true`), any `preflight` or `postflight`
    block and the install steps or file permissions that make Homebrew fall
    back to sudo (`sudo: :if_needed` steps whose directory you can't write,
    `set_ownership` steps, bundles with files not owned by or readable by you,
    targets in directories you can't write, renamed targets you don't own);
  - casks whose old version may need sudo or raise a dialog as it is
    uninstalled: `uninstall` directives that run as root (`pkgutil`,
    `launchctl`, `kext`, `delete`, `script` with `sudo: true`) or may raise a
    dialog (`quit` and `signal` when `on_upgrade` names it), its
    `uninstall_preflight` and `uninstall_postflight` blocks and its uninstall
    steps. As Homebrew uninstalls the version installed, these are read from
    the cask as installed.

The plan lists the casks of each call, with why each goes last. A failed cask
call is reported and fails the command; the batches still run. Ctrl-C during a
cask call stops the run.

A cask for the last call that needs, in the same way, a formula of the
batches that failed or was skipped and isn't installed is not run: Homebrew
would install that formula for it, without the formula options given for it
(e.g. pour a bottle of a formula whose source build failed). Unlike
`brew upgrade`, which would, the command leaves it out with a warning naming
it, what it needs and the command to run it later. A formula that failed to
upgrade is still installed, so Homebrew leaves it alone and the cask runs.

Without a terminal (`/dev/tty` can't be opened, e.g. under `launchd` or
`cron`) and with `$SUDO_ASKPASS` unset, sudo can't ask for a password, so the
casks that may need sudo are skipped, with a warning naming them and the
command to upgrade them later. A cask upgrade that fails partway is rolled
back, but the rollback may need sudo too and then fails, leaving the cask
half-upgraded; `brew upgrade` would try them anyway.

Each command it suggests to run casks later has the cask options the call
would have been given, and names a cask given as a file by that file, with
every argument escaped for the shell.

## Output

A heading gives the number of formulae and batches and the estimated total.
Each batch has a heading with its estimated time and why a new batch starts
there, then a row per formula with `pour` or `build` and its estimate. An
estimate ending in `?` has no history of that kind of build to go on, as in
`brew build-times stats`. Then come the casks to upgrade first, and those to
upgrade last, each with why.

A new batch starts:

- before a keg-only formula estimated over 75 seconds that follows formulae
  that are not keg-only (`brew upgrade` upgrades keg-only formulae first);
- before a formula estimated over 75 seconds that needs one estimated over 75
  seconds in the same batch (so a failed dependency never leaves its dependent
  built against the old version);
- before the formulae given to `--last` and their dependents.

## Options

`brew upgrade-timed` takes every `brew upgrade` option, with the same meaning;
see `brew upgrade --help`. It handles `-n`, `--dry-run` and `-y`, `--yes`,
`--no-ask` itself, once for the whole run. It adds:

`--guess`

: Comma-separated `name=duration` estimates for source builds with no history,
  e.g. `llvm=1h30m`: hours, minutes and seconds, as `brew build-times` prints
  them. Each formula can be given once, with a duration over zero.

`--estimator`

: How to estimate a source build from its history: `mean` (the default: the
  mean plus 1.5 standard deviations) or `median`.

`--last`

: Comma-separated formulae to run in a final batch, with their dependents.

`--exclude`

: Comma-separated formulae to leave out of the run. Homebrew may still
  install or upgrade them as dependencies of the others.

`--guess`, `--estimator`, `--last` and `--exclude` plan formulae only, so they
can't be used with `--cask`, and each name must be a formula.

`--no-stamp-receipts`

: Don't add the build times to the install receipts of the formulae it
  installs; they are still logged. Enabled by default if
  `$HOMEBREW_TIMED_NO_STAMP_RECEIPTS` is set, to any value. Receipts are then
  left exactly as Homebrew wrote them.
