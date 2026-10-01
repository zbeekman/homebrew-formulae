# brew reinstall-timed

## Usage

`brew reinstall-timed` \[*`options`*\] *`formula`* \[...\]

## Description

Reinstall formulae like `brew reinstall`, in one call ordered by their
estimates: dependencies first, then the quickest, so quick reinstalls finish
early and slow builds never hold them up. As with `brew reinstall`, each
*`formula`* is reinstalled with the options it was installed with, a formula
that isn't installed is installed, and a formula installed through an alias
whose target has changed is reinstalled as the new target. Its dependencies are
not reinstalled.

The estimates come from the log shown by
[`brew build-times`](build-times.md). A formula that will pour a bottle is
estimated from its earlier pours only, and one that will build from source from
its earlier source builds only, as `brew build-times stats` shows them.

Unlike `brew install` and `brew upgrade`, `brew reinstall` doesn't auto-update
first, and neither does `brew reinstall-timed`. It prints what
`brew reinstall` would reinstall, with the dependencies it would install or
upgrade and the outdated dependents it would upgrade, as `brew reinstall`
prints them before asking, then the order with the estimates. It then asks for
confirmation once, under `brew reinstall`'s rule: only if Homebrew would also
install or upgrade dependencies of the formulae, or upgrade outdated dependents
of them. Without a terminal it carries on without asking, as `brew reinstall`
does.

Pinned formulae are reported and left out, and unknown names are reported at the
end and make the command fail, both as `brew reinstall` does.
`--interactive` can't be used, as it needs a terminal: use
`brew reinstall --interactive` instead. Casks can't be reinstalled yet: use
`brew reinstall --cask` for those.

`brew reinstall-timed` is a command in this tap. Trust it once with
`brew trust --command zbeekman/tap/reinstall-timed`, or trust the whole tap.
See [Tap Trust](https://docs.brew.sh/Tap-Trust).

## Running

Once confirmed, it runs
`brew reinstall --formula --yes --display-times` *`options`* *`formula`* ...
once, from the home directory, with the formula options it was given and the
formulae in its order, which `brew reinstall` keeps. A formula given as a file
is passed on as that file, made absolute, so Homebrew loads it from there and
not by its name. With `--debug`, Homebrew's
interactive debugger is turned off (`$HOMEBREW_DISABLE_DEBREW`), as its prompt
couldn't be answered.

Homebrew's output and errors are shown as they arrive, in colour if the output
is a terminal (unless `$HOMEBREW_NO_COLOR` is set), and kept without colours in
`$HOMEBREW_LOGS/timed/`*`time`*`-`*`pid`*`-batch1.log`, where *`time`* is when
the run started, e.g. `20260930-143000`, and *`pid`* its process ID, so runs
started in the same second keep their own logs. Then it:

- checks that Homebrew reinstalled each formula: a failed reinstall puts the
  old keg back, at the same version, with its install receipt
  (`INSTALL_RECEIPT.json`) unchanged, so a formula counts as reinstalled only if
  the receipt of its keg in `opt` is a new file, not the one it had before, and
  records an install time no earlier than the second `brew reinstall` started.
  If it doesn't, the formula failed, and so does the command, as with
  `brew reinstall`;
- logs each formula Homebrew worked on, including the outdated dependents it
  upgraded alongside, in the log shown by [`brew build-times`](build-times.md),
  with `reinstall` and the log of the run;
- adds the times to the install receipt of each keg Homebrew installed, under
  `build_times`, unless `--no-stamp-receipts` is given.

A failed build stops `brew reinstall`, as does an error before it starts on any
formula: the formulae it never started are not reinstalled. They are logged as
`skipped`, listed in a warning, and the command fails.

It doesn't run `brew cleanup` itself: `brew reinstall` cleans up the formulae it
reinstalled, and runs Homebrew's periodic cleanup, unless
`$HOMEBREW_NO_INSTALL_CLEANUP` is set.

Ctrl-C stops Homebrew too. The command waits for it to exit, then logs and
stamps the formulae that Homebrew finished (with build and wall times, but no
install time), lists the rest, which are not logged, and exits with status 130,
as Homebrew does, even if Homebrew finished anyway.

## Output

A heading gives the number of formulae, in one batch, and the estimated total.
A row per formula, in the order they will be reinstalled, shows `pour` or
`build` and its estimate. An estimate ending in `?` has no history of that kind
of build to go on, as in `brew build-times stats`.

## Options

`brew reinstall-timed` takes every `brew reinstall` option, with the same
meaning; see `brew reinstall --help`. It handles `-y`, `--yes`, `--no-ask`
itself, once for the whole run. It adds:

`-n`, `--dry-run`

: Show what would be reinstalled, but do not actually reinstall anything.
  `brew reinstall` has no such option.

`--guess`

: Comma-separated `name=duration` estimates for source builds with no history,
  e.g. `llvm=1h30m`: hours, minutes and seconds, as `brew build-times` prints
  them. Each formula can be given once, with a duration over zero.

`--estimator`

: How to estimate a source build from its history: `mean` (the default: the
  mean plus 1.5 standard deviations) or `median`.

`--exclude`

: Comma-separated formulae to leave out of the run. Homebrew may still
  upgrade them as dependencies of the others.

`--guess`, `--estimator` and `--exclude` plan formulae only, so they can't be
used with `--cask`, and each name must be a formula.

`--no-stamp-receipts`

: Don't add the build times to the install receipts of the formulae it
  installs; they are still logged. Enabled by default if
  `$HOMEBREW_TIMED_NO_STAMP_RECEIPTS` is set, to any value. Receipts are then
  left exactly as Homebrew wrote them.
