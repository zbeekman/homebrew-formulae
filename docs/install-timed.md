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
`brew install --dry-run` prints them, and the batches with their estimates,
followed by those outdated dependents the batches don't install (see Running).
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
batch, as with `brew install`. With `--debug`, Homebrew's interactive debugger
is turned off (`$HOMEBREW_DISABLE_DEBREW`), as its prompt couldn't be answered.

Every call runs without Homebrew's check for outdated dependents
(`$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`), and without any of Homebrew's
hints about environment variables (`$HOMEBREW_NO_ENV_HINTS`), such as how to
turn off the check or cleanup: each batch's `brew install` only knows its own
formulae, so its check would pour the bottles of formulae planned for a later
batch, without their options and even if given to `--last`. Instead, the
command does what that check does, once, after the last batch:

- It upgrades the outdated dependents that Homebrew's check finds for the
  formulae in the batches while planning, other than the named formulae and
  those given to `--exclude`, with
  `brew upgrade --formula --yes --display-times` *`options`* *`formula`* ...
  from the home directory. Its options are those of the given ones that
  `brew install` gives such dependents and `brew upgrade` takes:
  `--force-bottle`, `--keep-tmp`, `--force`, `--debug`, `--quiet` and
  `--verbose`. As `brew install` does, Homebrew leaves out those whose bottles
  the installed versions of their dependencies already satisfy, saying so:
  right after confirmation, and again once the batches are done, just before
  the call. A dependent that is up to date by then (e.g. upgraded as a
  dependency in a batch) is left out, and one that needs a formula that failed
  or was skipped is skipped; with none left, there is no such call.
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

- checks that the latest version of each formula is installed, with a new
  install receipt if that version was already installed when planned (e.g.
  `--overwrite` of an unlinked formula, or `--HEAD` with the stable version
  installed), or, with `--only-dependencies`, that each dependency Homebrew was
  to install or upgrade for it (as worked out just before its batch) is; if
  not, the formula failed, and so does the command, as with `brew install`;
- logs each formula Homebrew worked on, including the dependencies it installed
  alongside the batch, in the log shown by [`brew build-times`](build-times.md),
  with `install`, the batch (`main`, or `last` for `--last`) and the batch's
  log; the outdated dependents upgraded after the batches are logged with
  `upgrade` and `dependents`, and the dependents with broken linkage with
  `reinstall` and `linkage`. A failed formula is logged with the version it
  was to install. With `--only-dependencies`, a named formula
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
installs no cask dependency. The last call comes after the calls for outdated
dependents and broken linkage too. A last cask that needs a formula that failed
to install or was skipped, or a dependency Homebrew would have installed for
one, or an outdated or broken dependent that the calls after the batches failed
to upgrade or reinstall or skipped, and isn't installed is left out, with a
warning, as for `brew upgrade-timed`: Homebrew would install that formula for
it, without the options given for it. The warning names what it needs, with
the `brew install-timed` command for the named formulae that bring that in, to
run first, then the command to install the cask. That command keeps the
formula options it was given, and its `--exclude` and `--no-stamp-receipts`,
so it installs those formulae as this run would and doesn't upgrade an
excluded outdated dependent; it has no `--yes`, so it asks as usual, and no
`--guess`, `--estimator`, `--last` or LLM options, which only shape the plan.

Ctrl-C before the batches start, while it downloads the outdated dependents'
bottle manifests to work out the calls after the batches, stops the run with a
warning that the batches didn't run. Whenever Ctrl-C stops the run there,
during the batches or during the calls after them, the last call doesn't run
either: a warning names its casks, with the command to install them later; a
cask that needs an uninstalled formula of the run is named with it and the
commands to finish it, as above.

## Output

A heading gives the number of formulae and batches and the estimated total.
Each batch has a heading with its estimated time and why a new batch starts
there, then a row per formula with `pour` or `build` and its estimate. An
estimate ending in `?` has no history of that kind of build to go on, as in
`brew build-times stats`, and one ending in `*` is from `--guess` or an LLM
(`--llm-estimates`). With `--only-dependencies`, the headings have no
times and each row reads `dependencies of` *`formula`*. The outdated dependents
it upgrades after the batches follow, under `Then upgrade outdated dependents`,
then
`Then check dependents for broken linkage, and reinstall broken ones from source`
(unless `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set). Then come the casks
to install first, and those to install last, each with why.

A new batch starts only:

- before a formula estimated over 75 seconds that needs one estimated over 75
  seconds in the same batch (so a failed dependency never leaves its dependent
  built against the old version), shown as *`formula`* `needs`
  *`dependency`*;
- before the formulae given to `--last` and their dependents, whose batches'
  headings are marked `(--last)`.

Keg-only formulae keep their place: only `brew upgrade` moves them first.

## Options

`brew install-timed` takes every `brew install` option, with the same meaning;
see `brew install --help`. It handles `-n`, `--dry-run` and `-y`, `--yes`,
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
  of at most 45 seconds; the plan marks these estimates with `*`. If it fails,
  they keep the fallback, with a warning. It sends the formulae's names,
  versions, descriptions and build dependencies, and this computer's CPU,
  cores, memory and OS, nothing else. Off by default; enabled by default if
  `$HOMEBREW_TIMED_LLM_ESTIMATES` is set, to any value. See
  [LLM estimates](../README.md#llm-estimates).

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

`--llm-api-key-file`, `--llm-provider`, `--llm-url` and `--llm-model` need
`--llm-estimates` (or `$HOMEBREW_TIMED_LLM_ESTIMATES`), and none of the LLM
options can be used with `--cask`.
