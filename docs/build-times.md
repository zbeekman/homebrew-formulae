# brew build-times

## Usage

`brew build-times` \[`stats`\] \[*`formula`* ...\]

`brew build-times note` *`formula`* *`text`*

`brew build-times restamp` \[*`formula`* ...\]

## Description

Show and annotate the log of how long formulae took to build from source or to
pour a bottle. [`brew upgrade-timed`](upgrade-timed.md) logs each formula it
upgrades there, and uses it to order its batches by measured times instead of
guesses.

The log is `build-log.json` in `$HOMEBREW_USER_CONFIG_HOME` (`~/.homebrew` by
default, `$XDG_CONFIG_HOME/homebrew` when that is set). It is written with mode
`0600`, and only when something changes. Writing also creates the directory
(mode `0700`) if it is missing, and a `build-log.json.lock` file beside the log.

`brew build-times` is a command in this tap. Trust it once with
`brew trust --command zbeekman/tap/build-times`, or trust the whole tap. See
[Tap Trust](https://docs.brew.sh/Tap-Trust).

## Subcommands

### `stats` \[*`formula`* ...\]

The default subcommand. Print a table with a row for each logged formula, or
for each *`formula`* named, then the fallback estimate for formulae with no
history. The columns are:

- `kind`: `built` for source builds or `poured` for pours (`-` if the formula
  has neither), the kind that the row's statistics and estimate are about;
- `n`: the number of timed builds of that kind;
- `median`, `mean`, `mode` and `stdev`: the median, mean, most common whole
  number of minutes and standard deviation of the build times;
- `estimate`: how long the formula's next build is expected to take;
- `last`: the version, status and date of the latest build.

A formula with both source builds and pours gets a row for each. The two kinds
are never mixed: each row's statistics and estimate use only that kind.

The `estimate` of a source build is its mean plus 1.5 standard deviations, and
of a pour its mean. An estimate ending in `?` is a guess, because there is no
usable history of that kind. For source builds, and for formulae with no
successful builds, it is the median of the per-formula mean build times
(10 minutes if there are none). For pours it is the median of every timed pour
(15 seconds if there are none).

### `note` *`formula`* *`text`*

Append *`text`* to the problems recorded for the latest logged build of
*`formula`*. It fails if the formula has no logged builds.

### `restamp` \[*`formula`* ...\]

Add the logged build times to the install receipts of installed formulae that
lack them. Each installed keg of *`formula`*, or of every logged formula, whose
`INSTALL_RECEIPT.json` has no `build_times` key gets one from the latest logged
build of the keg's version of the same kind: a pour for a keg poured from a
bottle, a source build otherwise. Kegs with no such build and
receipts that already have the key are left alone, so it can be run again
safely. It prints each keg it stamps.

The key holds the build's `verb` (when logged), `started`, `install_seconds`,
`build_seconds` and `wall_seconds`. Homebrew ignores it (`brew info` doesn't
show it), and drops it whenever it rewrites a receipt, e.g. when a formula
installed as a dependency is installed on request, with `brew tab` or when a
formula is renamed; this puts it back. Casks are never stamped.

`restamp` is an explicit request, so it stamps receipts even when
`$HOMEBREW_TIMED_NO_STAMP_RECEIPTS` is set; that variable, like
`brew upgrade-timed --no-stamp-receipts`, only stops `brew upgrade-timed` from
stamping the kegs it installs.

## Options

`-d`, `--debug`, `-q`, `--quiet`, `-v`, `--verbose` and `-h`, `--help` are the
usual Homebrew options.
