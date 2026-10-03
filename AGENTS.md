# Agent Instructions for zbeekman/tap

Keep the diff as small, DRY and YAGNI as possible.
Re-read relevant files after each prompt and preserve user edits and comments.
Before finishing, check your work and point out anything the user may not have considered.
Update `README.md` and `docs/` when the behaviour they describe changes.
Give each command a line under `## Commands` in `README.md` and a page at `docs/<command>.md`, using the markup of Homebrew's `docs/Manpage.md` (placeholders as *`text`*, brackets escaped as `\[...\]`, so they are not read as HTML).
Do not reference tools or files outside this repository, other than Homebrew and its documentation, in code, specs or docs; describe the behaviour instead.
In the commands (`cmd/`, `lib/`), in this order: never leave the user's system broken (e.g. dependents with broken linkage, or a formula poured, built or upgraded against what was asked), even where matching Homebrew would; say clearly whenever behaviour differs from what the user asked for or would expect, naming what was and wasn't done and the command to finish it; then follow Homebrew's native behaviour and conventions (paths, flags, output, idioms) wherever possible, and when unsure, copy what the nearest built-in command does.
Write Ruby code (`cmd/`, `lib/`) test-first, red-green-refactor: write a failing spec and see it fail, write the least code to pass it, then refactor with the suite green; only push green commits.
Run the specs with `brew ruby -- spec/run.rb [<rspec options>] [<spec files>]` from the root of any checkout (the tapped copy or a worktree); it prints a coverage summary and writes `coverage/index.html`.
Typecheck `cmd/`, `lib/` and `spec/` with `script/typecheck` (any checkout; it checks a copy of those directories, so `.claude/` and `.tmp/` are skipped; it takes no arguments, as `--fix` and `--lsp` would act on that copy); CI runs `brew typecheck zbeekman/tap` over the same directories. Use `typed: strict` with Sorbet sigs in `cmd/` and `lib/`.
In specs, write RSpec helpers as plain `def` methods, not `define_method` (Sorbet cannot follow those; disable `Sorbet/BlockMethodDefinition` at the top of the file with the reason), and, rather than generating examples with `.each`, make one `it` that loops and names the item on failure: either one `expect` over a hash keyed by the item (`expect(actual_by_item).to eq(expected_by_item)`), or `aggregate_failures` with a custom failure message naming the item (`aggregate_failures` alone drops its label when only one expectation fails).
Target 95% line coverage of `cmd/` and `lib/` and strive for it, but prioritise tests that catch bugs and exercise edge cases over tests written to raise the number; coverage is reported, not gated.

## Formula Changes

Best way to learn is by example. Check and use existing formulae in homebrew-core as reference of how to do specific things. See the resources at the end for links to documentation.

### New Formulae

- Follow the [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook) and use existing formulae as examples
- Create by running `brew create --tap zbeekman/tap <url>` and then edit the generated formula

### Dependencies

- Add new dependencies only when actually required for build or runtime; prefer the use of formulae as dependencies rather than using resources and try to avoid downloads inside install block.
- Avoid externally downloaded binaries, instead use `depends_on "formula"`, or resource blocks if you require external resource

### Test block

- Test MUST verify actual functionality:
  - execute the installed binary or library
  - include at least one assertion beyond `--version` or `--help` or similar
  - validate the build produced a working result,
  - For libraries: compile and link sample code
- `testpath` returns the working directory for tests in test block
- Test should not cover every possible edge case nor be so minimal that it doesn't actually verify the software.

### When to Add a Revision

Run `brew bump-revision [--write-only] zbeekman/tap/<formula>` when:

- Dependencies changed in a way that affects the built package
- The installed binary/library behavior changes

Do NOT add revision for cosmetic changes (comments, style, livecheck fixes).

## Required Validation

All checks MUST pass locally before opening a PR (add `--debug` and/or `--verbose` to command if more output is needed):

```sh
brew install --build-from-source zbeekman/tap/<formula>
brew test zbeekman/tap/<formula>
brew audit --strict [--new] zbeekman/tap/<formula>
brew style zbeekman/tap
```

## CI Failures

- Fetch complete build log in "Checks" (via gh cli)
- Reproduce failures locally
- Code patches added for fixing/patching source must be submitted as PR or opened as an issue upstream if not already done, and linked in the PR description and as a comment in the formula if applicable. So first try without patching.

## Git

- Inspect `git diff` and keep it focused.
- Never commit to `main`. Branch from `origin/HEAD` with a relevant name without category prefixes such as `fix/` or `chore/`, replacing any autogenerated branch name before its first commit.
- One commit per changed formula.
- Amend the existing commit for related fixes and update its message rather than adding a follow-up commit, until the branch is pushed; after that, fix in a new commit and never rewrite pushed commits.
- Pass multiline messages through `git commit -F` rather than literal `\n`.
- Open pull requests but never merge them; the user reviews and merges.

## Commit Message Format

- Version update: `foo 1.2.3`
- New formula: `foo 1.2.3 (new formula)`
- Fix/change: `foo: fix <description>` or `foo: <description>`
- Use a commit subject under 51 characters without Conventional Commit prefixes such as `feat:`, `fix:` or `chore:`; the Commit Style workflow rejects them.
- When a body is useful, use a dash list with lines under 73 characters focused on why and wrap filenames, code and identifiers in backticks.
- Reference issues with `Closes #12345` in commit body if applicable

## AI Attribution

- Never add `Co-Authored-By` or other AI attribution trailers to commits or pull requests and never GPG-sign agent commits.
- Do not identify an AI tool as an author, co-author, committer or signatory of a commit, including through an `Assisted-by`, `Co-developed-by` or similar commit trailer.

## Shell

- Use `&>/dev/null` instead of `>/dev/null 2>&1`.
- Put a comment immediately above each `shellcheck disable` explaining why it is needed.

## References

- [Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Rubydoc #Formula](https://docs.brew.sh/rubydoc/Formula.html)
- [Commands](https://docs.brew.sh/Manpage) or `man brew`
