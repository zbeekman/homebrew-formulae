# zbeekman/tap

## How do I install these formulae?
`brew install zbeekman/tap/<formula>`

Or `brew tap zbeekman/tap`, trust the formula with
`brew trust --formula zbeekman/tap/<formula>` and then `brew install <formula>`.
See [Tap Trust](https://docs.brew.sh/Tap-Trust).

## What is `brew build-times`?
A log of how long formulae took to build from source or pour, kept so later
commands can use measured times instead of guesses. Trust the command once with
`brew trust --command zbeekman/tap/build-times`, or trust the whole tap.

`brew build-times [stats] [<formula> ...]` prints, for each logged formula (or
the ones named), the number of builds, median, mean, mode and standard
deviation of the build times, an `estimate` and the latest build, then the
fallback estimate for formulae with no history. A formula with both source
builds and pours gets a row for each; the two are never mixed. The `estimate`
of a source build is its mean plus 1.5 standard deviations, and of a pour its
mean. An estimate ending in `?` is a guess, as there is no usable history of
that kind: the median of the per-formula mean build times (10 minutes if there
are none) for source builds and for formulae with no successful builds, or the
median of every timed pour (15 seconds if there are none) for pours.

`brew build-times note <formula> <text>` records a problem against the
formula's latest logged build.

The log is `build-log.json` in `$HOMEBREW_USER_CONFIG_HOME` (`~/.homebrew` by
default, `$XDG_CONFIG_HOME/homebrew` when that is set), written with mode
`0600`. A `build-log.json` written by `brewup.py` can be copied there as it is.

## Documentation
`brew help`, `man brew` or check [Homebrew's documentation](https://docs.brew.sh).
