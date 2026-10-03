# brew install-timed

## Usage

`brew install-timed` \[*`options`*\] *`formula`* \[...\]

## Description

Install formulae like `brew install`, in timed batches: dependencies first,
then the quickest, so quick installs finish early and slow builds never hold
them up. The batches hold the named formulae that `brew install` would install
or upgrade, as Homebrew's own check decides, with its messages about the
others: those not installed; those installed, linked and outdated, which it
upgrades unless they are pinned or `$HOMEBREW_NO_INSTALL_UPGRADE` is set
(keg-only ones too); and, with `--only-dependencies`, `--overwrite` or
`--skip-link`, the installed ones it would act on with those options. Homebrew
installs their dependencies within each batch, as `brew install` does;
dependencies are not batched themselves.

The estimates come from the log shown by
[`brew build-times`](build-times.md). A formula that will pour a bottle is
estimated from its earlier pours only, and one that will build from source from
its earlier source builds only, as `brew build-times stats` shows them.
`--build-from-source`, `--HEAD`, `--build-bottle` and `--cc` make every named
formula a source build, as in `brew install`. With `--only-dependencies`, each
row is the dependencies of a named formula, which have no estimates yet: they
are ordered dependencies first, then by name, and are never split into batches
by speed, only by `--last`.

It first auto-updates as `brew install` does, unless `$HOMEBREW_NO_AUTO_UPDATE`
is set, and runs again from the start if that fetched anything. As
`brew install` does, it then taps the tap of each name given with one, e.g.
`user/repo/formula`. Then it does what `brew install` does before printing its
plan, once for the whole run and mostly in the same order: it warns about
`--ignore-dependencies`, has Homebrew check each named formula (with its
messages about those it won't install), checks those it will (deprecated,
disabled, `$HOMEBREW_FORBIDDEN_*`), runs Homebrew's preinstall checks, which
can stop it, warns about `--cc` and fetches the bottle manifests of the
formulae that will pour (but no bottles). Homebrew's search for outdated
dependents, with its warning when `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is
set, comes after the bottle manifests here, as planning needs to know which
formulae will pour, where `brew install` runs it before them.

It then prints what `brew install` would install, with the dependencies it
would install or upgrade and the outdated dependents it would upgrade, as
`brew install --dry-run` prints them, and the batches with their estimates.
It then asks for confirmation once for the whole run, under `brew install`'s
rules: only if Homebrew would also install or upgrade dependencies of the
formulae in the batches, or upgrade outdated dependents of them, or install
dependencies of the casks. Like
`brew install`, it works out those dependencies before reading the bottle
manifests, so it can list and ask about an outdated dependency that a bottle
would accept and Homebrew then leaves alone. Without a terminal it carries on
without asking, as `brew install` does.

Where `brew install` stops before installing anything, so does the command,
with Homebrew's error: an unknown name, a HEAD-only formula without `--HEAD`,
`--HEAD` for a formula without one, a formula installed from another tap, a
source build without the developer tools or `--env`. Homebrew's checks of each
formula (deprecated or disabled, `$HOMEBREW_FORBIDDEN_*`, no bottle available,
`--force-bottle` without a bottle, dependencies built for another
architecture, outdated pinned dependencies, dependencies that can't be loaded
or aren't supported on this computer) run while planning, so a formula that
fails one is reported first, with Homebrew's error, and left out of the plan,
and the others still run, as with `brew install --yes`. This happens with
`--dry-run` too, which then fails. `brew install --dry-run` also fails on
dependencies that can't be loaded or aren't supported, but skips the other
checks (deprecated or disabled, `$HOMEBREW_FORBIDDEN_*`, no bottle, another
architecture, pinned dependencies), so it lists such a formula with the others
and succeeds.

Homebrew notes the support tier of what it does (e.g. Tier 3 with `--cc`) and
says so as it exits: each batch's `brew install` does, so the command doesn't
say it again; with `--dry-run`, or with nothing to run, it does.

Like `brew install`, even with `--dry-run`, Homebrew's check marks a named
formula that is already installed as installed on request, which rewrites its
install receipt without the build times; the command then writes them back as
they were, unless `--no-stamp-receipts` is given. Relative paths to formula
files are passed on as absolute paths, as Homebrew runs from the home
directory. `--interactive` can't be used, as it needs a terminal: use
`brew install --interactive` instead. Casks are installed too, before or after
the batches: see [Casks](#casks).

`brew install-timed` is a command in this tap. Trust it once with
`brew trust --command zbeekman/tap/install-timed`, or trust the whole tap. See
[Tap Trust](https://docs.brew.sh/Tap-Trust).

## Running

Once confirmed, it runs
`brew install --formula --yes --display-times` *`options`* *`formula`* ...
once per batch, from the home directory, with the formula options it was given.
Every formula in a batch is named, so options for the named formulae, such as
`--build-from-source` and `--debug-symbols`, apply to each formula of the
batch, as with `brew install`. A formula of a later batch may have been
upgraded before its batch runs, though: Homebrew's check for outdated
dependents of what an earlier batch installed pours the bottles of those it
finds, named formulae too, without those options and even if given to
`--last`, and the later batch then finds the formula up to date. With
`--debug`, Homebrew's interactive debugger is turned off
(`$HOMEBREW_DISABLE_DEBREW`), as its prompt couldn't be answered.

Homebrew's output and errors are shown as they arrive, in colour if the output
is a terminal (unless `$HOMEBREW_NO_COLOR` is set), and kept without colours in
`$HOMEBREW_LOGS/timed/`*`time`*`-`*`pid`*`-batch`*`N`*`.log`, where *`time`* is
when the run started, e.g. `20260930-143000`, and *`pid`* its process ID, so
runs started in the same second keep their own logs. After each batch, it:

- checks that the latest version of each formula is installed, with a new
  install receipt if that version was already installed when planned (e.g.
  `--overwrite` of an unlinked formula, or `--HEAD` with the stable version
  installed), or, with `--only-dependencies`, that each dependency Homebrew was
  to install or upgrade for it (as worked out just before its batch) is; if
  not, the formula failed, and so does the command, as with `brew install`;
- logs each formula Homebrew worked on, including the dependencies it installed
  and the outdated dependents it upgraded alongside the batch, in the log shown
  by [`brew build-times`](build-times.md), with `install`, the batch (`main`,
  or `last` for `--last`) and the batch's log. A failed formula is logged with
  the version it was to install. With `--only-dependencies`, a named formula
  is never logged for itself, failed or skipped, only what Homebrew installed
  for it; it is logged, and stamped, when Homebrew installs it as another
  named formula's dependency;
- adds the times to the install receipt (`INSTALL_RECEIPT.json`) of each keg
  Homebrew installed, under `build_times`, unless `--no-stamp-receipts` is
  given;
- skips the formulae in later batches that need one that failed or was
  skipped, and logs them as `skipped` (except with `--only-dependencies`). The
  other formulae still run.

A failed build doesn't stop `brew install`: the other formulae of its batch
still install.

It doesn't run `brew cleanup` itself: each `brew install` cleans up the
formulae it installed, and runs Homebrew's periodic cleanup, unless
`$HOMEBREW_NO_INSTALL_CLEANUP` is set.

Ctrl-C stops Homebrew too. The command waits for it to exit, then logs and
stamps the formulae of the stopped batch that Homebrew finished (with build and
wall times, but no install time), lists the rest of that batch and every later
batch, none of which are logged, and exits with status 130, as Homebrew does.
The batches that finished are logged. It exits with status 130 even if
Homebrew finished the last batch anyway.

## Casks

Casks are neither timed nor logged. As `brew install` does, it installs the
named casks that aren't installed and upgrades the installed, outdated ones,
unless they are pinned or `$HOMEBREW_NO_INSTALL_UPGRADE` is set. Before the
formulae, it prints what `brew install` prints about the casks: with
`--dry-run`, those not installed; otherwise those it would install or upgrade;
each time with the dependencies it would install for them.

They run in at most two calls of
`brew install --cask --yes` *`options`* *`cask`* ..., split into a first call
before the batches and a last one after them as for
[`brew upgrade-timed`](upgrade-timed.md#casks), with the cask options it was
given (`--[no-]binaries` as there). Only the casks it upgrades have an old
version to uninstall. With `--force`, Homebrew deletes an existing app in the
way of a cask it installs, so that counts as a file it may need sudo for. The
installed casks Homebrew won't upgrade go in the first call, for Homebrew to
say why. Without a terminal, a cask that depends on a skipped one, following
its dependencies through other casks, is skipped too, as Homebrew would install
the skipped one first, except with `--skip-cask-deps`, with which Homebrew
installs no cask dependency. A last cask that needs a formula that failed to
install or was skipped, or a dependency Homebrew would have installed for one,
and isn't installed is left out, with a warning, as for `brew upgrade-timed`:
Homebrew would install that formula for it, without the options given for it.

## Output

A heading gives the number of formulae and batches and the estimated total.
Each batch has a heading with its estimated time and why a new batch starts
there, then a row per formula with `pour` or `build` and its estimate. An
estimate ending in `?` has no history of that kind of build to go on, as in
`brew build-times stats`. With `--only-dependencies`, the headings have no
times and each row reads `dependencies of` *`formula`*. Then come the casks
to install first, and those to install last, each with why.

A new batch starts:

- before a formula estimated over 75 seconds that needs one estimated over 75
  seconds in the same batch (so a failed dependency never leaves its dependent
  built against the old version);
- before the formulae given to `--last` and their dependents.

Keg-only formulae keep their place: only `brew upgrade` moves them first.

## Options

`brew install-timed` takes every `brew install` option, with the same meaning;
see `brew install --help`. It handles `-n`, `--dry-run` and `-y`, `--yes`,
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
