# Contributing to olint

Bug reports, fixes, and new examples are welcome. For anything larger than a fix, open an issue first so we can agree on the shape before you write the code.

## Setup

You need Odin `dev-2026-10` or newer, `make`, and `bash`. The repository is laid out like this:

| Path | What it is |
| :--- | :--- |
| `olint/` | The library package, the only folder users copy into their projects |
| `cmd/olint/` | The CLI, with its tests in `main_test.odin` |
| `tests/` | Library tests (`olint_test.odin`, precision cases in `precision_test.odin`, type sizes in `layout_test.odin`) using in-memory `Virtual_File` workspaces and temporary directories |
| `examples/` | Example packages (`audio_dsp`, `game_loop`, `layered_arch`) checked by `olint` and `odin test` |
| `scripts/` | End-to-end checks of the CLI (`smoke.sh`), the checks the git hooks run, and the documentation build (`build_docs.sh` with `odin-doc.json`) |

`olint/` is one Odin package with a file per topic. `config.odin`, `annotations.odin`, `workspace.odin`, `callgraph.odin`, and `analyzer.odin` hold the workspace loader and call-graph engine; `rules_alloc.odin`, `rules_arch.odin`, and `rules_perf.odin` implement the static analysis rules; each report format has its own `report_*.odin`, and `testing.odin` integrates with `odin test`. Subfolders would be separate packages in Odin, which is why there are none.

The user documentation lives in two places: the README, and the package documentation in `olint/doc.odin`, which `make docs` renders into `build/docs` with the generator behind pkg.odin-lang.org.

Optional tools the repository is set up for:

| Tool | What it does here |
| :--- | :--- |
| [lefthook](https://lefthook.dev) | `make hooks` installs a commit-msg hook that checks the Conventional Commits header and a pre-commit hook that runs odinfmt, `make check`, shellcheck, and typos on what you commit. Hooks for tools you don't have are skipped. |
| [actionlint](https://github.com/rhysd/actionlint), [shellcheck](https://www.shellcheck.net), [typos](https://github.com/crate-ci/typos) | `make lint` runs whichever is installed. CI runs all three. |
| [lychee](https://lychee.cli.rs) | `make links` checks the links in the documentation. CI runs it weekly. |

## Before you open a pull request

```sh
make check            # odin check on every package, with the flags Odin's own CI uses for core
make test             # library, CLI, and example tests (leak checks + AddressSanitizer)
make smoke            # builds bin/olint and runs scripts/smoke.sh
make fmt-check ODINFMT=path/to/odinfmt
```

If AddressSanitizer isn't available on your platform, run `make test TEST_FLAGS=`.

`odinfmt` comes from [DanielGavin/ols](https://github.com/DanielGavin/ols). Build it with `odin build tools/odinfmt/main.odin -file -collection:src=src -out:odinfmt -o:speed` in a clone of that repository. CI pins the commit it uses in `.github/workflows/ci.yml`, and `make fmt` formats everything with the repository's `odinfmt.json`.

## Code style

Follow the [Odin naming and style convention](https://github.com/odin-lang/examples/wiki/Naming-and-style-convention): `Ada_Case` types and enum values, `snake_case` procedures and variables, `SCREAMING_SNAKE_CASE` constants, and tabs for indentation. On top of that:

- Prefer `core:` packages over hand-written helpers. The reports use `core:text/table` and `core:encoding/json`, and the CLI uses `core:flags`.
- Procedures that allocate take `allocator` and `loc := #caller_location` parameters. Procedures that return a value people shouldn't ignore get `@(require_results)`.
- Pass structs larger than 128 bytes by pointer (`^T`) or `#by_ptr` so `olint` passes its own `perf/large-value-copy` check with `--fail-on-warnings`.
- File operations return `Report_Error` rather than `bool`.
- Every public declaration needs a doc comment that `odin doc` can render.

## Changes users will see

Don't edit `CHANGELOG.md` or the `VERSION` constant by hand. [release-please](https://github.com/googleapis/release-please) writes both from the commit messages on `main` (see below). What you control is the pull request title, which becomes the commit message: a `feat:` or `fix:` shows up in the release notes, and a `!` after the type (`feat!: ...`) marks a breaking change. A change to the JSON report layout is breaking and also needs `JSON_FORMAT_VERSION` bumped.

## Commit messages and pull requests

Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `style:`, `test:`, `build:`, `ci:`, `chore:` or `revert:`, an optional scope (`fix(cli): ...`), and `!` for breaking changes. The commit-msg hook checks this locally.

Every change to `main` goes through a pull request, the maintainer's own included. Pull requests are squash-merged, so the PR title becomes the commit on `main` and the description stays on the pull request. A workflow checks that the title follows the same format. The pull request template asks for what changed, why, and how you tested it.

## Releases

After CI passes on a push to `main`, release-please opens or updates a release PR. If CI fails, or `main` has moved on to a newer push, the release PR stays as it was until a later push passes. It picks the next version from the commits since the last release (before 1.0, a breaking change bumps the minor version) and writes the changelog entry. The PR updates `CHANGELOG.md` and `VERSION` in `olint/doc.odin`. Merging it tags the release and creates the GitHub release, with an archive of the `olint` folder and CLI archives for five platforms attached, each with its SHA-256 sum.

The release PR is opened with the default `GITHUB_TOKEN`, and GitHub holds the CI runs on it until a maintainer approves them on the pull request (they show as "action required"). To have CI start on release PRs without that step, add a personal access token as a repository secret and pass it to the action as `token`.
