# zbeekman/tap

## How do I install these formulae?
`brew install zbeekman/tap/<formula>`

Or `brew tap zbeekman/tap`, trust the formula with
`brew trust --formula zbeekman/tap/<formula>` and then `brew install <formula>`.
See [Tap Trust](https://docs.brew.sh/Tap-Trust).

## Commands
- [`brew build-times`](docs/build-times.md): show and annotate the log of how
  long formulae took to build from source or pour (as a table or, with
  `stats --json`, as JSON), plot a histogram of those times (the table and
  the histogram can be coloured by quartile), list the runs of the `-timed`
  commands and draw a timeline of each, and restore the times in install
  receipts.
- [`brew install-timed`](docs/install-timed.md): install formulae in batches
  ordered by estimated build time, quickest first, and log how long each took;
  casks go before the batches, or after them if they may prompt.
- [`brew reinstall-timed`](docs/reinstall-timed.md): reinstall formulae in one
  call ordered by estimated build time, quickest first, and log how long each
  took; casks go before the formulae, or after them if they may prompt.
- [`brew upgrade-timed`](docs/upgrade-timed.md): upgrade outdated formulae in
  batches ordered by estimated build time, quickest first, and log how long
  each took; casks go before the batches, or after them if they may prompt.

## Timed installs, upgrades and reinstalls
`brew install-timed`, `brew upgrade-timed` and `brew reinstall-timed` are for
formulae built from source. Each takes every option of the command it wraps,
except `--interactive`, which needs a terminal: run the wrapped command with
`--interactive` instead (e.g. `brew install --interactive`). With `--debug`,
Homebrew's interactive debugger is turned off, as its prompt couldn't be
answered. It orders the formulae by estimates from earlier runs, dependencies
first, then quickest first, and runs `brew install` or `brew upgrade` once per
batch (`brew reinstall` once), so quick builds finish early and long ones never
hold them up.

Trust the commands once, or the whole tap with `brew trust zbeekman/tap`:

```sh
brew trust --command zbeekman/tap/build-times
brew trust --command zbeekman/tap/install-timed
brew trust --command zbeekman/tap/reinstall-timed
brew trust --command zbeekman/tap/upgrade-timed
```

Then, for example:

```sh
brew upgrade-timed --dry-run                  # print the plan and estimates
brew upgrade-timed --guess llvm=1h30m --last llvm
brew install-timed --build-from-source <formula>
brew build-times stats                        # the times estimates come from
```

- They ask for confirmation once for the whole run, by the rules of the
  command they wrap; `--yes` skips that, and without a terminal they carry on
  unasked, as Homebrew does, so they can run unattended.
- Each formula's times go in `build-log.json` in `$HOMEBREW_USER_CONFIG_HOME`,
  shown by `brew build-times`, and in its install receipt under
  `build_times`, unless `--no-stamp-receipts` is given or
  `$HOMEBREW_TIMED_NO_STAMP_RECEIPTS` is set. Each batch's output is kept in
  `$HOMEBREW_LOGS/timed/`.
- Casks aren't timed: they go in one call before the batches, and one after
  them for those that may ask for a password, show a dialog or need a formula
  or cask in the run. Without a terminal (`/dev/tty` can't be opened) and with
  `$SUDO_ASKPASS` unset, casks that may need `sudo` are skipped, with a warning
  naming them and the command to run them later.
- Each command's page above says what it runs, including what happens to the
  installed dependents of the formulae it installs, upgrades or reinstalls.

## LLM estimates
A formula built from source with no history in `brew build-times` is estimated
from `--guess`, or else gets the median of the other formulae's mean build
times, marked `?` in the plan. With `--llm-estimates`, the `-timed` commands
ask an LLM for those estimates instead, in one request for the whole run, and
mark them `*` in the plan, as they do `--guess`'s. The plan says so first:
`Asking` *`provider`* *`model`* `for` *`N`* `estimates`, or, with
`--llm-url`, `Asking` *`model`* `at` *`host`*`:`*`port`* `for` *`N`*
`estimates`, naming only the host and port of the URL.

It is off unless you turn it on. Every setting is an option, or a variable
when the option isn't given:

| Option | Variable | Default |
| ------ | -------- | ------- |
| `--[no-]llm-estimates` | `HOMEBREW_TIMED_LLM_ESTIMATES` (set to any value) | off |
| `--llm-api-key-file=`*`path`* | `HOMEBREW_TIMED_LLM_API_KEY_FILE` | none; needed unless `--llm-url` is set |
| `--llm-provider=anthropic`\|`openai` | `HOMEBREW_TIMED_LLM_PROVIDER` | `anthropic` for a key starting with `sk-ant-`, `openai` otherwise |
| `--llm-url=`*`url`* | `HOMEBREW_TIMED_LLM_URL` | the provider's API |
| `--llm-model=`*`name`* | `HOMEBREW_TIMED_LLM_MODEL` | `claude-sonnet-5-5` or `gpt-5-mini`; none, so needed, with `--llm-url` |
| `--llm-timeout=`*`seconds`* | `HOMEBREW_TIMED_LLM_TIMEOUT` | 45 |
| `--llm-effort=`*`level`* | `HOMEBREW_TIMED_LLM_EFFORT` | on the provider's API, `low` for `claude-haiku-5-5`, `claude-sonnet-5-5` and `claude-opus-5-5`, and `minimal` for `gpt-5-mini`; none otherwise |

For example, with the key in a file only you can read:

```sh
chmod 600 ~/.config/anthropic-key
brew upgrade-timed --dry-run --llm-estimates --llm-api-key-file ~/.config/anthropic-key
# or a server on this computer that speaks OpenAI's API, without a key,
# given 10 minutes, as it may be slow:
export HOMEBREW_TIMED_LLM_ESTIMATES=1
brew upgrade-timed --dry-run --llm-url http://127.0.0.1:11434/v1/chat/completions --llm-model qwen2.5:7b \
  --llm-timeout 600
```

- What is sent: for each formula asked about, its name, version, description
  and build dependencies; this computer's hardware and setup, as far as it can
  be read quickly: the CPU's name and architecture, its cores and threads (and
  performance and efficiency cores on Apple Silicon), any container CPU limit,
  the computer's model (e.g. `MacBookPro16,4`) and form (laptop, desktop or
  server), whether it is virtualised, its memory and OS version; how many
  jobs Homebrew runs `make` with; and a sentence saying the estimate is for
  building and installing the formula alone, not downloads or dependencies.
  Nothing else: no host name, user name, serial number or path, and no build
  times, so nothing about what else is installed. Turning it on agrees to
  sending that to the provider.
- Models known to take it are asked at temperature 0, so the same request
  gets the same estimates: `claude-haiku-4-5` on Anthropic's API, and any
  model on an `--llm-url` server other than a hosted one known or expected to
  reject it (OpenAI's `o` series and `gpt-5` and later, Claude 5 and later,
  also behind a prefix such as `openai/` or `us.anthropic.`). Others,
  including both default models and every model on OpenAI's API so far, get
  the provider's default, so the same request can get different estimates;
  `claude-sonnet-5-5` at `low` effort gives much the same each time.
- Models known to take it are asked at a low effort, so they answer sooner
  and think little or not at all: on the provider's API, `low` for
  `claude-haiku-5-5`, `claude-sonnet-5-5` and `claude-opus-5-5`, and
  `minimal` for `gpt-5-mini`. Others, including every model on an `--llm-url`
  server, get their own default. `--llm-effort` is sent as given to any model
  on any URL, as `output_config.effort` in Anthropic's API format and
  `reasoning_effort` in OpenAI's; it must be lowercase letters, but isn't
  checked against the provider's levels, which change. A model that doesn't
  take it, such as `claude-haiku-4-5`, fails the request with HTTP 400, and
  the warning says to check `--llm-effort`. Extended thinking is neither
  asked for nor turned off: the effort decides it.
- Only source builds with no history, no `--guess` and not `--exclude`d are
  asked about, and none means no request. Each answer is kept in
  `build-log.json` under `estimates`, with the model and date, and used again
  for the same version, so a later run or `--dry-run` doesn't ask again; once
  a formula has a source build, that is used instead. `brew build-times stats`
  shows each estimate next to the source build of its version, to judge
  whether the model is good enough.
- It never holds up a run for long: the whole request, including one retry on
  HTTP 429 or 5xx, has `--llm-timeout` seconds, 45 unless set. That suits the
  providers' APIs; a server on this computer, without a fast GPU, may need
  minutes for a long list, and more for its first request, while it loads the
  model. If it fails for any reason (no answer in time, offline, a refused
  key, an unknown model, an effort the model doesn't take, a model that
  refuses or runs out of tokens before it answers, an answer with no valid
  estimate), a warning says why (for an HTTP error, only its status and a
  hint), and those formulae keep the median. Answers are checked: only the
  formulae asked about are used, each between 1 second and 48 hours, and a
  warning names any that an answer leaves out, which keep the median. Settings
  that can't work (no key without `--llm-url`, `--llm-url` without
  `--llm-model`, an `--llm-url` host that isn't a host name or an IPv4 or
  bracketed IPv6 address, an `--llm-url` port outside 1 to 65535, `http://` to
  an address that isn't on this computer or a private network, a key file that
  can't be read, an unknown provider, an `--llm-timeout` that isn't a number of
  seconds over 0 and at most 86400, an `--llm-effort` that isn't lowercase
  letters) stop the command before it does anything.
- The key is read from a file only, never from an option or a variable:
  options show up in `ps`, shell history and debug output, and a variable
  holding it could reach any formula or cask download. The file must hold
  just the key; a warning asks you to `chmod 600` it if other users can read
  it. The key is never shown, logged, written to a file or passed to the
  `brew` calls the commands make, and nothing the server answers is shown
  either.
- `--llm-url` is sent the key, whatever it names. Only give it a server you
  trust with your key. Plain `http://` only goes to this computer or a
  private network address, checked after the host name is looked up;
  anything else needs `https://`. Redirects are never followed.

## Documentation
`brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
