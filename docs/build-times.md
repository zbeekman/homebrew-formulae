# brew build-times

## Usage

`brew build-times` \[`stats`\] \[`--sort=`*`key`*\] \[`--reverse`\] \[`--json`\[=*`version`*\]\] \[*`formula`* ...\]

`brew build-times histogram` \[`--poured`\] \[`--builds`\] \[`--smooth`\] \[`--linear`\] \[*`formula`* ...\]

`brew build-times runs`

`brew build-times run` \[*`number`*\]

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

### `stats` \[`--sort=`*`key`*\] \[`--reverse`\] \[`--json`\[=*`version`*\]\] \[*`formula`* ...\]

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
table below gets the same colours for `estimate` and `actual`. The header row
of both tables has each column name in bold and underlined, the underline
stopping at the name so the columns stand apart.

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
- `--json`\[=*`version`*\]: print the build history as JSON instead of the
  tables, as `brew tap-info --json` does. `v1` is the default and the only
  accepted *`version`*; any other is a usage error. See [JSON](#json).

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

#### JSON

`--json` prints a JSON array to standard output, never coloured, with an object
for each row of the table, in the same order (the named formulae, `--sort` and
`--reverse` apply). The `built` and `poured` rows of a formula are separate, as
in the table. The objects have these keys, in this order:

- `name`: the formula's short name;
- `kind`: `built` or `poured`, or `null` for a formula with no successful
  build;
- `n`: the number of builds of that kind that have a time;
- `median`, `mean` and `stdev`: the median, mean and standard deviation of
  those times, in seconds, as numbers, or `null` without any;
- `builds`: every logged build of that kind, oldest first, each an object with
  `seconds` (its time in seconds, as the statistics use it, or `null` if none
  was logged), `date` (when it started, as logged: a date alone in older
  entries, else a timestamp), `version` and `status` (`built`, `poured` or
  `failed`). A failed build is of neither kind, so it is listed in every row of
  its formula, as in the trend.

Left out: the `last` column (the last entry of `builds`), the estimate and
whether it is a guess, the fallback estimate for unknown formulae and the LLM
estimates. A formula named but not logged has a row with a `null` kind and no
builds.

```sh
brew build-times stats --json llvm
```

```json
[
  {
    "name": "llvm",
    "kind": "built",
    "n": 1,
    "median": 5163.1,
    "mean": 5163.1,
    "stdev": 0.0,
    "builds": [
      {
        "seconds": 5163.1,
        "date": "2026-09-25",
        "version": "23.1.2",
        "status": "built"
      }
    ]
  }
]
```

### `histogram` \[`--poured`\] \[`--builds`\] \[`--smooth`\] \[`--linear`\] \[*`formula`* ...\]

Plot a histogram of the source build times of every logged formula, or of
each *`formula`* named: a heading naming what is counted and the shortest and
longest time, then bars of how many took how long, with the count on the y axis
and the time on the x axis. Each formula counts once, with the mean of its
times, so a formula built many times does not outweigh the others.

- The x axis is on a log scale, as build times run from seconds to hours, from
  the shortest time to the longest (see `--linear` for a linear one). It has
  ticks at `1s`, `10s`, `1m`, `10m`, `1h` and `10h` where they are in that
  range, edges included, so a narrow range may have none. A label that would
  touch the one before it is left out.
- 75 seconds, where the `-timed` commands start to split batches, is marked
  in the x axis only, with `┴`, or `┼` where a tick is there too. A row under
  the tick labels names it: `└ 75s batch split` from the mark to the right, or
  `75s batch split ┘` ending at the mark if that does not fit in the width.
  With 75 seconds outside the range, there is no mark and no row for it.
- The plot is as wide as the terminal (at least 40 columns) and 10 rows high.
  The bins are of equal width on the log scale: at least 2 per cube root of the
  number of times (5 for 10 formulae, 10 for 100), sometimes a few more so the
  bins fill the width evenly, so a bar is one or more columns wide. The y axis
  is labelled with the highest count. The top of a bar is drawn in eighths of a
  row (`▁▂▃▄▅▆▇█`), and a bin with any time in it is at least `▁` high.
- With colour, each bar is green up to 75 seconds, yellow up to 10 minutes and
  red above, by the median of the times in it, as `estimate` is in `stats`.
  Colour follows the same rules as in `stats`; without it the plot is plain
  text.
- With fewer than 2 times to plot, it says so (`No histogram:` and what it
  found) instead of plotting.

There is no `--json`; `stats --json` gives every time plotted.

- `--poured`: plot the times of pours instead of source builds. The two are
  never mixed.
- `--builds`: count every build, not one mean for each formula.
- `--smooth`: draw a smoothed curve instead of the bars, in braille, on the
  same axes: a Gaussian kernel density estimate of the log times, with
  Silverman's rule-of-thumb bandwidth (0.9 times the smaller of the standard
  deviation and the interquartile range divided by 1.34, or the one that is
  not zero, times the number of times to the power -1/5; one bin's width if
  the times are all equal). It is just the line, with no bars or fill under
  it, and it is never coloured. At each point it shows how many times the
  estimate puts within one bin's width centred there, so the y axis counts
  what it does for the bars: a lone time is never higher than 1, and a
  cluster of times narrower than the plot can show is still drawn. The y axis
  goes up to the curve's peak, rounded up, which can be higher than the
  highest bar, as when a cluster straddles the edge of two bins, or lower.
- `--linear`: put time on a linear scale instead, from 0 to the end of the bin
  of the longest time. The bins are of equal width, a round time, so their
  edges fall on whole minutes and hours and on the ticks: the
  Freedman–Diaconis width (twice the interquartile range times the number of
  times to the power -1/3), rounded to the nearest of 1, 2, 5, 10 or 20
  seconds or minutes or 1, 2 or 5 times a power of ten of hours; made
  narrower if that gives fewer bins than the log scale has at least (2 per
  cube root of the number of times), and wider if the bins would not each get
  a column. With no interquartile range, as when more than half the times are
  equal, it is the widest that gives that many bins. A bin is never narrower
  than 1 second, so very short times, such as pours, can get fewer bins than
  that. Each bin is the same whole number of columns wide, so the plot can be
  narrower than the terminal. The ticks are at the multiples of the first step
  of 1, 2, 5, 10, 15, 20 or 30 seconds or minutes or 1, 2, 3, 5, 6, 10, 12, 20,
  50 or more hours that is a multiple of the bin width and puts them at least
  an eighth of the axis apart, with room for their labels: the time as in
  `stats` without the parts that are 0 (`0`, `30s`, `1m15s`, `10m`, `1h`,
  `1h30m`). 75 seconds is still marked, as `┼` on the `0` tick when it is in
  the first column, and each bar is coloured by the median of its times, so a
  first bin of quick builds is green even when it runs past 75 seconds. With
  `--smooth`, the estimate is still of the log times, so none
  of it is below 0 seconds, and at each point the curve shows how many times it
  puts in one bin's width centred there, so where it crosses the middle of a
  bin it is the bin's expected count. Equal times are smoothed over about one
  bin's width at them.

```console
$ brew build-times histogram
==> Mean source build time of 91 formulae, from 0m05s to 3h08m
20 ┤                        ████████
   │                        ████████
   │                        ████████████████
   │                ████████████████████████
   │                ████████████████████████▄▄▄▄▄▄▄▄
   │        ████████████████████████████████████████
   │▄▄▄▄▄▄▄▄████████████████████████████████████████████████
   │████████████████████████████████████████████████████████
   │████████████████████████████████████████████████████████        ▄▄▄▄▄▄▄▄
   │████████████████████████████████████████████████████████████████████████
 0 └──────┬────────────────┬─┴──────────────────┬────────────────┬──────────
          10s              1m                   10m              1h
                             └ 75s batch split
```

```console
$ brew build-times histogram --smooth
==> Mean source build time of 91 formulae, from 0m05s to 3h08m
18 ┤                         ⣀⣀⠤⠤⠤⠤⣀⣀
   │                    ⢀⡠⠔⠒⠉        ⠉⠑⠢⠤⣀
   │                 ⣀⠔⠊⠁                 ⠉⠒⠤⡀
   │             ⣀⠤⠒⠉                        ⠈⠑⠢⢄⡀
   │         ⢀⡠⠔⠊                                ⠈⠑⠢⣀
   │      ⢀⡠⠒⠁                                       ⠉⠢⢄⡀
   │   ⢀⠤⠒⠁                                             ⠈⠒⠤⣀
   │⢀⠤⠊⠁                                                    ⠑⠢⢄⣀
   │⠁                                                           ⠉⠒⠢⠤⢄⣀⣀
   │                                                                   ⠉⠉⠉⠒⠒
 0 └──────┬────────────────┬─┴──────────────────┬────────────────┬──────────
          10s              1m                   10m              1h
                             └ 75s batch split
```

```console
$ brew build-times histogram --linear
==> Mean source build time of 91 formulae, from 0m05s to 3h08m
64 ┤██
   │██
   │██
   │██
   │██
   │██
   │██
   │██
   │██▃▃
   │████▆▆▅▅▁▁▄▄    ▁▁▁▁              ▁▁          ▁▁                          ▁▁
 0 └┼───────────┬───────────┬───────────┬───────────┬───────────┬───────────┬───
    0           30m         1h          1h30m       2h          2h30m       3h
    └ 75s batch split
```

### `runs`

List the runs of [`brew install-timed`](install-timed.md),
[`brew upgrade-timed`](upgrade-timed.md) and
[`brew reinstall-timed`](reinstall-timed.md) in the log, newest first, one
line each, under a header:

- `run`: the run's number, 1 for the latest, as `run` takes it;
- `started`: when its first formula started, as logged (in the local time of
  the run);
- `verbs`: the verbs of its calls, in order, e.g. `upgrade,reinstall` for an
  upgrade that reinstalled dependents with broken linkage;
- `built`, `poured`, `failed` and `skipped`: how many builds it logged as
  built from source, poured, failed and skipped; these count builds, not
  formulae, so a formula built in a batch and reinstalled after the batches
  counts twice;
- `length`: from when its first formula started to when its last one
  finished.

With colour, the column names are bold and underlined, as in `stats`, and a
number of failed builds other than 0 is red. With no runs in the log, it
says so instead.

### `run` \[*`number`*\]

Draw a timeline of run *`number`*, as `runs` numbers them, or of the latest
run: a heading naming the run, when it started and its verbs, with a header
whose time axis goes from 0 to the run's length; then a heading for each batch
(`Batch` and its number, with `(--last)` for the batch of `--last` formulae)
and for each call after the batches, headed as the plan of
[`brew upgrade-timed --dry-run`](upgrade-timed.md) heads it (`Then upgrade
outdated dependents`, `Then check dependents for broken linkage, and reinstall
broken ones from source`), each with a row for each formula: its name, its
status (`built`, `poured`, `failed` or `skipped`), its time and a bar on the
time axis, from when brew first named the formula to when it finished. The
axis is shared by the whole run and is linear, so the bars show when each
formula ran and how long it took next to the others; there is no 75 second
mark, as the axis is the run's clock, not a build's length.

- A bar is at least one column wide, so a quick pour still shows. A failed
  formula's bar is drawn with `×`; brew's output for a failed formula has no
  end, so with no time it is a single `×` where it started. Any other
  formula with no time is a single column where it started, with `-` as its
  time; that includes a dependency logged with a time of 0 but a longer
  install time, as older versions of these commands logged dependencies when
  brew named them with their version.
- The skipped formulae of a call after the batches follow its bars, with no
  bar. Those of the batches follow under `Skipped`, as the log doesn't say
  which batch skipped them.
- The gaps between the bars are brew's own work, such as downloads and
  checks. The last lines give the run's length and how much of it is between
  the bars, and, if the run has a formula with no time, such as a failed one,
  say that the gaps include it. A run that only skipped formulae has no time
  axis, and its last line says that nothing ran.
- The bars are as wide as the terminal allows (it is taken to be at least 40
  columns) after the name, status and time, and never narrower than 10
  columns.
- With colour, each status and its bar are painted: `built` cyan, `poured`
  magenta and `failed` red, as in `stats`.

A *`number`* that isn't a whole number from 1 is a usage error, and one past
the oldest run is an error naming how many runs there are. With no runs in the
log, it says so instead.

```console
$ brew build-times run
==> Run 1, started 2026-10-01 10:00: upgrade, reinstall
formula  status      time  0                                               1h03m
==> Batch 1
ninja    poured     0m05s  █
fmt      built      1m30s  ██
==> Batch 2 (--last)
llvm     built      1h00m   ███████████████████████████████████████████████████
==> Then upgrade outdated dependents
qux      failed         -                                                     ×
quux     skipped        -
==> Then check dependents for broken linkage, and reinstall broken ones from source
libpng   built      1m00s                                                      █
==> Skipped
zlib     skipped        -
Total 1h03m, 1m20s of it between the bars.
The gaps between the bars are brew's own work, such as downloads and checks.
The gaps also include builds with no logged end, such as failed builds.
```

#### How builds are grouped into runs

Each logged build has `started` (when brew first named the formula),
`wall_seconds` (from then until brew's summary line for it), `batch` (the
label of its batch: `main`, `last`, `dependents` or `linkage`), `verb`,
`log`, the output of its batch, kept in `$HOMEBREW_LOGS/timed/` and named
`<YYYYmmdd-HHMMSS>-<pid>-batch<n>.log` after when its run started (in local
time), the run's process and the batch's number, and `run`, that name up to
`-batch`, the same for every build of the run, skipped formulae too. Builds
with the same `run` are of the same run, each in the batch its log names.

- Builds logged before `run` was added have none, so a build with a log is of
  the run its log's name gives. A skipped formula has no log, so one with no
  `run` is put in the latest run that started at or before the time it was
  logged, by the local time of both. That can put it in the wrong run when
  runs overlap, and can't make a run of a run that only skipped formulae;
  builds logged with `run` have neither problem.
- Builds other than skipped formulae with no such log, and those whose
  `started` is only a date (logged before the runs were kept), belong to no
  run and are left out.
- Casks aren't in the build log, so the cask calls of a run don't appear.
- There is no `--json`; the build log itself is JSON.

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
