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
arguments, and the batches with their estimates, followed by the outdated
dependents it upgrades after them (see Running), then asks for confirmation
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
is skipped, as in later batches.

Every call runs without Homebrew's check for outdated dependents
(`$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`), and without any of Homebrew's
hints about environment variables (`$HOMEBREW_NO_ENV_HINTS`), such as how to
turn off the check or cleanup: each call only knows its own formulae, so its
check would pour the bottles of formulae planned for a later call, without
`--build-from-source` and even if given to `--last`, and it would also check
the dependents of the outdated dependencies the batches add, which
`brew upgrade` doesn't. Instead, the command does what that check does, once,
after the last batch:

- It upgrades the outdated dependents that Homebrew's check finds while
  planning, for the formulae `brew upgrade` would upgrade (the named ones, or
  every outdated one) other than those given to `--exclude`, if they are
  neither in the batches nor given to `--exclude`, with
  `brew upgrade --formula --yes --display-times` *`options`* *`formula`* ...
  from the home directory. Its options are those of the given ones that
  `brew upgrade` gives such dependents: `--force-bottle`, `--keep-tmp`,
  `--force`, `--debug`, `--quiet` and `--verbose`. As `brew upgrade` does,
  Homebrew leaves out those whose bottles the installed versions of their
  dependencies already satisfy, saying so: right after confirmation, and again
  once the batches are done, just before the call. A dependent that is up to
  date by then (e.g. upgraded as a dependency in a batch) is left out, and one
  that needs a formula that failed or was skipped is skipped; with none left,
  there is no such call.
- It then checks, as Homebrew does, the installed dependents of the formulae
  the run installed for broken library linkage, each formula loaded from the
  tap its install receipt names: all the dependents of the formulae from other
  taps, as Homebrew checks those, and of the `homebrew/core` ones built from
  source, but of the `homebrew/core` bottles, whose linkage Homebrew takes as
  checked, only the dependents built from source. It does this even if no
  dependent was upgraded, where Homebrew only checks after upgrading some; the
  plan says it will. It reinstalls the broken ones from source, dependencies
  first, as Homebrew does, each with its own
  `brew reinstall --formula --yes --display-times --build-from-source`
  *`options`* *`formula`*, so that, as with Homebrew, a failed build doesn't
  stop the others. The options are those of the given ones that Homebrew gives
  them: `--keep-tmp`, `--debug-symbols`, `--force`, `--debug`, `--quiet` and
  `--verbose`. It never reinstalls a broken dependent that is pinned or
  outdated (as Homebrew doesn't), given to `--exclude`, or that failed or was
  skipped in this run, nor one that needs a formula that failed or was
  skipped, which its reinstall would install as a dependency: it names each
  kind with the command to fix it (`brew upgrade-timed` for an outdated one,
  `brew reinstall --build-from-source` for the others, as below), and, for
  those that need such a formula, what they need, to install first. It names
  any formula it can't load (e.g. one whose name is in several taps), with
  `brew reinstall --build-from-source` and its installed dependents (by the
  tap its install receipt names), where it can find them and reinstall them
  now, and says if the check itself fails. Ctrl-C stops the check, which says
  whose dependents it hadn't checked.

Both calls run without the check too, so neither upgrades or reinstalls
anything else. Whatever they leave undone (failed, or not run because of
Ctrl-C) is named with the command that finishes it; one that needs a formula
the run didn't finish is named apart, with what it needs, and the command to
run once that is installed. Those commands do no more than the calls would
have, as Homebrew's own check in them would upgrade or reinstall dependents
the run left alone. An outdated dependent is finished with
`brew upgrade-timed`, with the run's `--exclude` (less the formulae it names,
which that would leave out) and `--no-stamp-receipts`, so its own check leaves
the excluded formulae alone too. A broken one is reinstalled with
`HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew reinstall --build-from-source`,
as the run's call is, so it upgrades or reinstalls nothing else, which a line
after the commands says. A pinned broken dependent that is outdated is named
with `brew upgrade-timed`, to run once unpinned, as `brew reinstall` would
upgrade it from source. With `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` set by
the user, neither call runs, as Homebrew then does neither, and the batches
run with the user's setting (with Homebrew's warning about it in each).

Homebrew's output and errors are shown as they arrive, in colour if the output
is a terminal (unless `$HOMEBREW_NO_COLOR` is set), and kept without colours in
`$HOMEBREW_LOGS/timed/`*`time`*`-`*`pid`*`-batch`*`N`*`.log`, where *`time`* is
when the run started, e.g. `20260930-143000`, and *`pid`* its process ID, so
runs started in the same second keep their own logs. After each batch, it:

- checks that the new version of each formula is installed; if it isn't, the
  formula failed, and so does the command, as with `brew upgrade`;
- logs each formula Homebrew worked on, including those it upgraded alongside
  the batch (e.g. dependencies), in the log shown by
  [`brew build-times`](build-times.md), with `upgrade`, the batch (`main`,
  `last` for `--last`, or `dependents` for the outdated dependents upgraded
  after the batches) and the batch's log; the dependents with broken linkage
  are logged with `reinstall` and `linkage`. A failed formula is logged with
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
batch, none of which are logged. It then works out, without upgrading or
reinstalling anything, the outdated dependents still to upgrade and the
dependents with broken linkage still to reinstall, and names them with the
command that finishes each; those that need a formula the run didn't finish
are named apart, with what they need. A second Ctrl-C stops that too: it then
says what it didn't work out, with, for the outdated dependents, the command
for those that may be left. The batches that finished are logged. It exits
with status 130, as Homebrew does, even if Homebrew finished the last batch
anyway.

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
- the last, after the batches and the calls that follow them for outdated
  dependents and broken linkage (see [Running](#running)), which may upgrade
  or reinstall what a cask needs, for the rest, so that a password prompt or a
  macOS dialog only waits once the builds are done:
  - casks that need a formula or cask in the run, directly or through the
    dependencies of the formulae and casks they need, which Homebrew may
    install for them. That includes what Homebrew needs to unpack a cask's
    download (e.g. `xz`), which it only knows once it has the download; the
    command, which downloads nothing, goes by the cask's `container type:`,
    else its download if already cached, else the download's extension, as
    Homebrew reads it (e.g. `.tar.xz`, a tarball, needs nothing). What a cask
    needs is matched with the run by full name, after aliases and renames,
    so another tap's formula of the same name doesn't count, except for a
    dependency that can't be loaded, which is matched by name alone; formulae
    are matched only with formulae and casks only with casks. The run
    includes the dependencies Homebrew installs or upgrades in the calls for
    the formulae of the batches; the plan names the formulae each is for;
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
cask call stops the run. Ctrl-C before the batches start, while it downloads
the outdated dependents' bottle manifests to work out the calls after the
batches, stops the run with a warning that the batches didn't run. Whenever
Ctrl-C stops the run there, during the batches or during the calls after them,
the last call doesn't run either: a warning names its casks, with the command
to upgrade them later; a cask that needs an uninstalled formula of the run
(e.g. a new dependency) is named with it and the commands to finish it, as
below.

A cask for the last call that needs, in the same way, a formula of the
batches that failed or was skipped, or a dependency Homebrew would have
installed in that formula's call, or an outdated or broken dependent that the
calls after the batches failed to upgrade or reinstall or skipped, and isn't
installed is not run: Homebrew would install that formula for it, without the
formula options given for it (e.g. pour a bottle of a formula whose source
build failed). Unlike `brew upgrade`, which would, the command leaves it out
with a warning naming it and what it needs, with the `brew upgrade-timed`
command for the formulae that bring that in, to run first, then the command to
upgrade the cask. That command keeps the formula options it was given, and its
`--exclude` and `--no-stamp-receipts`, so it upgrades those formulae as this
run would and doesn't upgrade an excluded outdated dependent; it has no
`--yes`, so it asks as usual, no `--guess`, `--estimator`, `--last` or LLM
options, which only shape the plan, and no `--minimum-version`, whose check the
formulae it names already passed. It names the formulae the run was given
(every outdated one, with no names), not the outdated dependencies the batches
add, as some options (e.g. `--build-from-source`) are only for those given. A
formula upgraded to the new target of the alias it was installed with is named
as it was given, as the command wouldn't upgrade that target by its own name.
If none of those brings it in (e.g. it is needed by a dependency of a formula
given to `--exclude`), the warning gives only the cask's command, for once
that formula is installed. A formula that failed to upgrade is still
installed, so Homebrew leaves it alone and the cask runs.

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
`brew build-times stats`, and one ending in `*` is from `--guess` or an LLM
(`--llm-estimates`). The outdated dependents it upgrades after the batches
follow, under `Then upgrade outdated dependents`, then
`Then check dependents for broken linkage, and reinstall broken ones from source`
(unless `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set). Then come the casks
to upgrade first, and those to upgrade last, each with why.

A new batch starts only:

- before a keg-only formula estimated over 75 seconds that follows formulae
  that are not keg-only (`brew upgrade` upgrades keg-only formulae first),
  shown as `keg-only` *`formula`*;
- before a formula estimated over 75 seconds that needs one estimated over 75
  seconds in the same batch (so a failed dependency never leaves its dependent
  built against the old version), shown as *`formula`* `needs`
  *`dependency`*;
- before the formulae given to `--last` and their dependents, whose batches'
  headings are marked `(--last)`.

## Options

`brew upgrade-timed` takes every `brew upgrade` option, with the same meaning;
see `brew upgrade --help`. It handles `-n`, `--dry-run` and `-y`, `--yes`,
`--no-ask` itself, once for the whole run. It adds:

`--guess`

: Comma-separated `name=duration` estimates for source builds with no history,
  e.g. `llvm=1h30m`: hours, minutes and seconds, as `brew build-times` prints
  them. Each formula can be given once, with a duration over zero. The plan
  marks these estimates with `*`.

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

`--[no-]llm-estimates`

: Ask an LLM for estimates of the source builds with no history, no `--guess`
  and not `--exclude`d, which would otherwise get the fallback, in one request
  within `--llm-timeout`; the plan marks these estimates with `*`. If it fails,
  they keep the fallback, with a warning. It sends the formulae's names,
  versions, descriptions and build dependencies; this computer's CPU and
  architecture, cores and threads (and performance and efficiency cores on
  Apple Silicon), any container CPU limit, model, form (laptop, desktop or
  server), whether it is virtualised, memory and OS; Homebrew's make jobs;
  and what the estimate is for, at temperature 0 for models known to take
  it. Nothing else: no host name, user name, serial number or path. Off by
  default; enabled by default if `$HOMEBREW_TIMED_LLM_ESTIMATES` is set, to
  any value. See [LLM estimates](../README.md#llm-estimates).

`--llm-api-key-file`

: File holding the API key, needed unless `--llm-url` is set. Defaults to
  `$HOMEBREW_TIMED_LLM_API_KEY_FILE`.

`--llm-provider`

: `anthropic` or `openai`. Defaults to `$HOMEBREW_TIMED_LLM_PROVIDER`, else
  `anthropic` for a key starting with `sk-ant-` and `openai` otherwise.

`--llm-url`

: Where to send the request instead of the provider's API, e.g. a server on
  this computer that speaks OpenAI's API. Defaults to `$HOMEBREW_TIMED_LLM_URL`.
  It receives the API key.

`--llm-model`

: The model to ask, needed with `--llm-url`. Defaults to
  `$HOMEBREW_TIMED_LLM_MODEL`, else the provider's small model
  (`claude-haiku-4-5` or `gpt-5-mini`).

`--llm-timeout`

: Seconds to wait for the answer, including one retry on HTTP 429 or 5xx: a
  number over 0 and at most 86400 (a day). Defaults to
  `$HOMEBREW_TIMED_LLM_TIMEOUT`, else 45. A server on this computer may need
  minutes for a long list, and more for its first request, while it loads
  the model.

`--llm-api-key-file`, `--llm-provider`, `--llm-url`, `--llm-model` and
`--llm-timeout` need `--llm-estimates` (or `$HOMEBREW_TIMED_LLM_ESTIMATES`),
and none of the LLM options can be used with `--cask`.
