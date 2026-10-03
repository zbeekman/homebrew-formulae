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

## Documentation
`brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
