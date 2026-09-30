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
if the batches include formulae other than the names as given (so a new alias
target, an alias or a name not given exactly as the formula's full name, e.g.
a core formula with its tap or another tap's formula without it, counts as
another), or Homebrew would install dependencies or upgrade outdated
dependents of the named formulae; otherwise, if there is anything to upgrade.
Without a terminal it carries on without asking, as `brew upgrade` does.

Formulae it won't upgrade (up to date, not installed, pinned, unknown or
needing a newer version of a pinned dependency) are reported by
`brew upgrade --dry-run`'s plan, and the command fails if that does. Relative
paths to formula or cask files are passed on as absolute paths, as Homebrew
runs from the home directory.

Running the batches is not implemented yet: without `--dry-run`, it stops
after the confirmation. Casks are listed in `brew upgrade --dry-run`'s plan,
but not in the batches.

`brew upgrade-timed` is a command in this tap. Trust it once with
`brew trust --command zbeekman/tap/upgrade-timed`, or trust the whole tap. See
[Tap Trust](https://docs.brew.sh/Tap-Trust).

## Output

A heading gives the number of formulae and batches and the estimated total.
Each batch has a heading with its estimated time and why a new batch starts
there, then a row per formula with `pour` or `build` and its estimate. An
estimate ending in `?` has no history of that kind of build to go on, as in
`brew build-times stats`.

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

: Comma-separated formulae to leave out of the batches. Homebrew may still
  upgrade them as dependencies of the others.

These plan formulae only, so they can't be used with `--cask`, and each name
must be a formula.
