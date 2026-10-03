# zbeekman/tap

## How do I install these formulae?
`brew install zbeekman/tap/<formula>`

Or `brew tap zbeekman/tap`, trust the formula with
`brew trust --formula zbeekman/tap/<formula>` and then `brew install <formula>`.
See [Tap Trust](https://docs.brew.sh/Tap-Trust).

## Commands
- [`brew build-times`](docs/build-times.md): show and annotate the log of how
  long formulae took to build from source or pour, and restore those times in
  install receipts.
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
formulae built from source. Each takes every option of the command it wraps.
It orders the formulae by estimates from earlier runs, dependencies first, then
quickest first, and runs `brew install` or `brew upgrade` once per batch
(`brew reinstall` once), so quick builds finish early and long ones never hold
them up.

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

## Documentation
`brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
