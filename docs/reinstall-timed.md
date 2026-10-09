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
prints them before asking, then the order with the estimates, followed by
those outdated dependents it upgrades after the formulae (see Running). It then
asks for confirmation once, under `brew reinstall`'s rules: only if Homebrew
would also install or upgrade dependencies of the formulae, or upgrade outdated
dependents of them, or install dependencies of the casks. Unlike
`brew reinstall`, it also asks when it reinstalls no formula (e.g. every formula
named is pinned) but would upgrade outdated dependents of the named formulae,
which `brew reinstall` then upgrades without asking. Without a terminal it
carries on without asking, as `brew reinstall` does.

Pinned formulae and casks are reported and left out, and unknown names are
reported at the end and make the command fail, all as `brew reinstall` does.
`--interactive` can't be used, as it needs a terminal: use
`brew reinstall --interactive` instead. Casks are reinstalled too, before or
after the formulae: see [Casks](#casks).

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

The call runs without Homebrew's installed-dependents check
(`$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`), and without any of Homebrew's
hints about environment variables (`$HOMEBREW_NO_ENV_HINTS`): that check looks
for dependents with broken linkage only after it has upgraded some outdated
dependents, so a reinstall that changes a keg (e.g. a source build with other
options) could leave a dependent's linkage broken without a word. Instead, the
command does what that check does after the call, as
[`brew install-timed`](install-timed.md#running) does after its batches:

- It upgrades the outdated dependents that Homebrew's check finds for the named
  formulae not given to `--exclude`, including pinned ones, which
  `brew reinstall` refuses to reinstall but checks; so it does this even when
  it reinstalls no formula (e.g. every formula named is pinned) and there is
  no call, as `brew reinstall` does. It leaves out the named formulae, as
  `brew reinstall` does, and those given to `--exclude`. It runs
  `brew upgrade --formula --yes --display-times` *`options`* *`formula`* ...
  with the options `brew reinstall` gives them, as there.
- It then checks the installed dependents of the formulae the run installed for
  broken library linkage, even if no dependent was upgraded, and reinstalls the
  broken ones from source, each with its own
  `brew reinstall --formula --yes --display-times --build-from-source`
  *`options`* *`formula`*, as there.

Both run even when a failed build has stopped `brew reinstall` (see below),
where Homebrew does neither, as the formulae reinstalled before it may have
broken their dependents' linkage; a dependent that needs a formula that failed
or wasn't reinstalled is left alone. Whatever they leave undone or can't do
(e.g. a pinned or outdated broken dependent) is named with the command that
finishes it, as there. With `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` set by
the user, neither runs, as Homebrew then does neither, and the call runs with
the user's setting (with Homebrew's warning about it).

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
- logs each formula Homebrew worked on, including any dependencies it installed
  alongside, in the log shown by [`brew build-times`](build-times.md), with
  `reinstall`, the batch (`main`), the run and the run's log; the outdated
  dependents upgraded after the call are logged with `upgrade` and
  `dependents`, and the dependents with broken linkage with `reinstall` and
  `linkage`. A formula's logged install time leaves out the dependencies
  Homebrew installed for it, which are logged with `dependency_of` (see
  [`brew build-times`](build-times.md));
- adds the times to the install receipt of each keg Homebrew installed, under
  `build_times`, unless `--no-stamp-receipts` is given.

A failed build stops `brew reinstall`, as does an error before it starts on any
formula: the formulae it never started are not reinstalled. They are logged as
`skipped`, listed in a warning, and the command fails. A formula
`brew reinstall` leaves out before it starts on any, because a download
(including a resource or patch) failed or a check before installing it did, is
logged as failed, with two known exceptions: one left out for a failed patch
download is logged as `skipped` when the call also stopped early, and, when
nothing in the call was installed, one left out for a failed check is logged
as `skipped`.

It doesn't run `brew cleanup` itself: `brew reinstall` cleans up the formulae it
reinstalled, and runs Homebrew's periodic cleanup, unless
`$HOMEBREW_NO_INSTALL_CLEANUP` is set.

Ctrl-C stops Homebrew too. The command waits for it to exit, then logs and
stamps the formulae that Homebrew finished (with build and wall times, but no
install time), lists the rest, which are not logged, works out the outdated
dependents and broken ones still to see to, without upgrading or reinstalling
anything, and names them with the commands that finish them, as
[`brew install-timed`](install-timed.md#running) does. It exits with status
130, as Homebrew does, even if Homebrew finished anyway. Ctrl-C while it
downloads the outdated dependents' bottle manifests, before the call, stops the
run with a warning that the batches (here, the call) didn't run. The casks of
the last call then don't run either: a warning names them, with the command to
reinstall them later. One that needs a formula of the run that isn't installed
is named with it, and with the `brew reinstall-timed` command for the named
formulae that bring it in, to run first, as Homebrew would install that formula
for the cask without the options given for it. That command keeps the formula
options it was given, and its `--exclude` and `--no-stamp-receipts`; it has no
`--yes`, so it asks as usual, and no `--guess`, `--estimator` or LLM options,
which only shape the plan.

## Casks

Casks are neither timed nor logged. Before the formulae, it prints the casks
`brew reinstall` would reinstall, with the dependencies it would install for
them, which `brew reinstall` prints only when it asks.

They run in at most two calls of
`brew reinstall --cask --yes` *`options`* *`cask`* ..., split into a first call
before the formulae and a last one after them as for
[`brew upgrade-timed`](upgrade-timed.md#casks), with the cask options it was
given (`--zap` too; `--[no-]binaries` as there). A cask that isn't installed is
installed, as `brew reinstall` does, so it has no old version to uninstall, and
with `--force` an existing app in its way counts, as for
[`brew install-timed`](install-timed.md#casks). With `--zap`, Homebrew
uninstalls the old version without a successor, so its `uninstall login_item`
counts as a dialog, then runs every directive of its `zap` stanza, so those
that run as root or may raise a dialog count, `signal` and `login_item` always.

The uninstall side is read from the cask as installed, as Homebrew loads it
to reinstall it. With tap trust on (the default unless
`$HOMEBREW_NO_REQUIRE_TAP_TRUST` is set), Homebrew doesn't load an installed
Ruby caskfile for a cask that isn't trusted: it uninstalls the artifacts the
cask recorded when it was installed and zaps with the new cask's `zap` stanza
instead, so the uninstall side is read from those, and, to be safe, from the
new cask's `uninstall` stanza too, which Homebrew doesn't run then.

A failed build stops `brew reinstall` before it reinstalls any cask it was
given. The casks of the first call, before the formulae, have been reinstalled
by then; those of the last call, after the formulae, don't run: a warning
names them, with the command to reinstall them later, as after Ctrl-C. After
any other failure Homebrew carries on to the casks, and so does the command,
as it does after a failed post-install step. The last call comes after the
calls for outdated dependents and broken linkage, which it may need. Homebrew
prints the installation times as it finishes, if it installed anything, so then
it didn't stop. Otherwise the command takes brew as stopped when it never
started a formula it was given (more of them than downloads it couldn't tie to
a formula failed), or when the call's last formula printed the end of its build
log, or with `--verbose` its `did not build` error. So when nothing in the call
was installed, a formula brew left out before installing it, for a failed
check, still makes it skip the last casks, with its warning. Without
`--verbose`, a last formula that fails at an `inreplace` or while applying a
patch prints neither, so the last casks still run then. A failed reinstall
puts the old keg back, so a last cask that needs that formula still runs;
only one that needs a formula that isn't installed (e.g. one that wasn't
installed before, or a dependency Homebrew would have installed for it) is left
out, as for [`brew upgrade-timed`](upgrade-timed.md#casks), with the
`brew reinstall-timed` command for the named formulae that bring that in, to
run first.

## Output

A heading gives the number of formulae, in one batch, and the estimated total.
A row per formula, in the order they will be reinstalled, shows `pour` or
`build` and its estimate. An estimate ending in `?` has no history of that kind
of build to go on, as in `brew build-times stats`, and one ending in `*` is
from `--guess` or an LLM (`--llm-estimates`). The outdated dependents it
upgrades after the formulae follow, under `Then upgrade outdated dependents`,
then
`Then check dependents for broken linkage, and reinstall broken ones from source`
(unless `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set). Then come the casks
to reinstall first, and those to reinstall last, each with why.

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
  them. Each formula can be given once, with a duration over zero. The plan
  marks these estimates with `*`.

`--estimator`

: How to estimate a source build from its history: `mean` (the default: the
  mean plus 1.5 standard deviations) or `median`.

`--exclude`

: Comma-separated formulae to leave out of the run. Homebrew may still
  install or upgrade them as dependencies of the others.

`--guess`, `--estimator` and `--exclude` plan formulae only, so they can't be
used with `--cask`, and each name must be a formula.

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
  and what the estimate is for, at temperature 0 and a low effort for the
  models known to take them. Nothing else: no host name, user name, serial
  number or path. Off by default; enabled by default if
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
  `$HOMEBREW_TIMED_LLM_MODEL`, else the provider's default model
  (`claude-sonnet-5-5` or `gpt-5-mini`).

`--llm-timeout`

: Seconds to wait for the answer, including one retry on HTTP 429 or 5xx: a
  number over 0 and at most 86400 (a day). Defaults to
  `$HOMEBREW_TIMED_LLM_TIMEOUT`, else 45. A server on this computer may need
  minutes for a long list, and more for its first request, while it loads
  the model.

`--llm-effort`

: How hard the model works on its answer, e.g. `low` or `high`: lowercase
  letters only, sent as given to any model on any URL, as
  `output_config.effort` in Anthropic's API format and `reasoning_effort` in
  OpenAI's. Defaults to `$HOMEBREW_TIMED_LLM_EFFORT`, else, on the provider's
  API only, `low` for `claude-haiku-5-5`, `claude-sonnet-5-5` and
  `claude-opus-5-5` and `minimal` for `gpt-5-mini`; other models get their
  own default. A model that doesn't take it fails the request with HTTP 400,
  and those formulae keep the fallback.

`--llm-api-key-file`, `--llm-provider`, `--llm-url`, `--llm-model`,
`--llm-timeout` and `--llm-effort` need `--llm-estimates` (or
`$HOMEBREW_TIMED_LLM_ESTIMATES`), and none of the LLM options can be used
with `--cask`.
