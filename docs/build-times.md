# brew build-times

## Usage

`brew build-times` \[`stats`\] \[`--sort=`*`key`*\] \[`--reverse`\] \[*`formula`* ...\]

`brew build-times note` *`formula`* *`text`*

`brew build-times restamp` \[*`formula`* ...\]

## Description

Show and annotate the log of how long formulae took to build from source or to
pour a bottle. [`brew install-timed`](install-timed.md),
[`brew upgrade-timed`](upgrade-timed.md) and
[`brew reinstall-timed`](reinstall-timed.md) log each formula they install,
upgrade or reinstall there, and use it to order the formulae they run by
measured times instead of guesses.

The log is `build-log.json` in `$HOMEBREW_USER_CONFIG_HOME` (`~/.homebrew` by
default, `$XDG_CONFIG_HOME/homebrew` when that is set). It is written with mode
`0600`, and only when something changes. Writing also creates the directory
(mode `0700`) if it is missing, and a `build-log.json.lock` file beside the log.

`brew build-times` is a command in this tap. Trust it once with
`brew trust --command zbeekman/tap/build-times`, or trust the whole tap. See
[Tap Trust](https://docs.brew.sh/Tap-Trust).

## Subcommands

### `stats` \[`--sort=`*`key`*\] \[`--reverse`\] \[*`formula`* ...\]

The default subcommand. Print a table with a row for each logged formula, or
for each *`formula`* named, then the fallback estimate for formulae with no
history. The columns are:

- `kind`: `built` for source builds or `poured` for pours (`-` if the formula
  has neither), the kind that the row's statistics and estimate are about;
- `n`: the number of timed builds of that kind;
- `median`, `mean`, `mode` and `stdev`: the median, mean, most common whole
  number of minutes and standard deviation of the build times;
- `estimate`: how long the formula's next build is expected to take;
- `last`: the version, status and date of the latest build;
- `trend`: one block character (`▁▂▃▄▅▆▇█`) for each of the latest 8 builds of
  that kind, oldest first. Each row is scaled to its own range, on a log scale
  (build times run from seconds to hours), so a row only shows how that
  formula's times moved, not how long they are. Builds whose times differ by
  under 10 % are drawn flat (`▄`), so noise does not look like a trend. `-`
  means no builds with a time.

A formula with both source builds and pours gets a row for each. The two kinds
are never mixed: each row's statistics, estimate and trend use only that kind.

A failed build has no time and is of neither kind, so, as `last` shows the
latest build of the formula whatever its kind, a failed build is drawn as `×`
in the trend of every row of the formula, at its place among the builds. A
formula with only failed builds has a single row (kind `-`) with only `×`.
The latest 8 count the failed builds too.

With colour, `estimate` and the blocks of the trend are green up to 75 seconds
(where the planner starts splitting batches), yellow up to 10 minutes and red
above; `×` and the `last` of a failed build are red; an estimate that is a
guess (ending in `?`) is also in italics; and `built` and `poured` are cyan
and magenta. Colour follows Homebrew's own rules: it is off unless the output
is a terminal or `$HOMEBREW_COLOR` is set, and always off with
`$HOMEBREW_NO_COLOR`. Without it the table is plain text. The LLM estimates
table below gets the same colours for `estimate` and `actual`.

The rows are in the order of the log (by formula name), or of the formulae
named, unless `--sort` is given. A formula's `built` and `poured` rows always
stay together, ordered by its first row.

- `--sort=`*`key`*: order the rows by *`key`*, one of `name`, `estimate`,
  `median`, `mean`, `n` or `last` (when the latest build started, by the
  instant, so a UTC offset is accounted for; a date alone counts as midnight
  UTC). Numbers go largest first and `last` newest first; ties are ordered by
  name, and a row with no history counts as zero. Any other key is a usage
  error naming these.
- `--reverse`: reverse the order of the rows, whether sorted or not.

The `estimate` of a source build is its mean plus 1.5 standard deviations, and
of a pour its mean. An estimate ending in `?` is a guess, because there is no
usable history of that kind. For source builds, and for formulae with no
successful builds, it is the median of the per-formula mean build times
(10 minutes if there are none). For pours it is the median of every timed pour
(15 seconds if there are none).

Then, if the log keeps any LLM estimates (see `--llm-estimates` in
[`brew upgrade-timed`](upgrade-timed.md#options)) for the formulae shown, a
second table lists each with its `version`, the `estimate`, the `actual` time
of the latest source build of that version (`-` if there is none yet), and the
model and date of the estimate, to judge whether the model is good enough.
The log keeps one estimate per formula, under `estimates`; a formula's own
source builds always take its place once there are any.

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
`--no-stamp-receipts`, only stops `brew install-timed`, `brew upgrade-timed`
and `brew reinstall-timed` from stamping the kegs they install.

## Options

`-d`, `--debug`, `-q`, `--quiet`, `-v`, `--verbose` and `-h`, `--help` are the
usual Homebrew options.
