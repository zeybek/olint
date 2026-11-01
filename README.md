# olint

[![CI](https://github.com/zeybek/olint/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/zeybek/olint/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/zeybek/olint?include_prereleases&sort=semver)](https://github.com/zeybek/olint/releases)
[![Docs](https://img.shields.io/badge/docs-API%20reference-blue)](https://zeybek.github.io/olint/olint/)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--10%2B-1e5fa8)](https://odin-lang.org/)
[![Dependencies](https://img.shields.io/badge/dependencies-base%20%2B%20core-brightgreen)](https://github.com/zeybek/olint/tree/main/olint)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](https://github.com/zeybek/olint/blob/main/LICENSE)

Static call-graph allocation, architecture, and data-oriented performance linter for [Odin](https://odin-lang.org/). It parses a project with `core:odin/parser`, builds the call graph and the package import graph, and checks `@zero_alloc` and `@no_temp_alloc` guarantees, `context.temp_allocator` discipline, package layering, and large value copies, without compiling or running the project. It uses only `base:` and `core:` packages.

Companion to [`obench`](https://github.com/zeybek/obench): obench checks `@zero_alloc` at runtime on the inputs a benchmark actually runs, and olint checks the same annotation statically on every call path it can resolve.

Status: before 1.0. The API and the JSON report layout can still change, and the [release notes](https://github.com/zeybek/olint/releases) list every breaking change.

## Guide

The [package documentation](https://zeybek.github.io/olint/olint/) covers the annotations, allocator parameter forwarding, architectural layer rules, running inside `odin test`, report exports, configuration, and known limits. `olint help` lists the CLI options, and `olint rules` lists all built-in rules.

## Getting Started

`olint` needs Odin `dev-2026-10` or newer. CI tests it on Linux (x86 and ARM), macOS (ARM and Intel), and Windows against the latest Odin release and the nightly build.

1. Build the CLI from a clone of this repository (on Windows, use `-out:bin/olint.exe`), or take a prebuilt one from a [release](https://github.com/zeybek/olint/releases):

    ```sh
    odin build cmd/olint -out:bin/olint -o:speed
    ```

2. Run `olint` on any Odin project — no imports or source edits required:

    ```sh
    ./bin/olint path/to/project
    ```

3. Mark hot-path procedures with `// @zero_alloc` (or pass `-e <proc>` on the command line). When a `@zero_alloc` procedure reaches an allocation several calls deep across packages, `olint` prints the shortest call chain from that procedure to the allocating call. `olint examples/game_loop -e step_world_leaky` on an Apple M2:

    ```text
    olint: game_loop (darwin/arm64, 2 package(s), 2 file(s), 6 proc(s) analyzed in 1.99 ms)
    ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    rule             │ severity │ location          │ finding
    ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    alloc/zero-alloc │ ERROR    │ sim/sim.odin:35:1 │ sim.step_world_leaky (@zero_alloc) allocates on context.allocator
       ├─► sim.step_world_leaky (sim/sim.odin:37:2) ── calls physics.solve_contacts_debug
       ├─► physics.solve_contacts_debug (physics/physics.odin:30:10) ── calls physics.format_contact_tag
       ╰─► physics.format_contact_tag (physics/physics.odin:36:9) ── calls fmt.aprintf (heap string formatting [heap: context.allocator])
    ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
    FAIL: 1 error(s), 0 warning(s), 0 parse error(s) across 2 package(s)
    ```

    Allocations follow `context`: if the caller sets `context.allocator = mem.arena_allocator(&arena)` before the call, the callee's `make` goes to the arena and isn't reported.

4. Inspect imports and the allocation behavior of every procedure (after following its calls) with `olint graph`:

    ```text
    olint graph: game_loop (2 package(s), 6 procedure(s))
    ────────────────────────────────────────────────────────────────────────────────────────
    physics (physics) [layer:physics]
     ├─ import "core:fmt"
     ├─ import "core:mem"
     ├─ solve_broadphase [param-alloc]
     ├─ solve_contacts_debug [heap]
     ╰─ format_contact_tag [heap]
    sim (sim) [layer:sim]
     ├─ import "../physics"
     ├─ import "core:mem"
     ├─ integrate_velocities @zero_alloc [no-alloc]
     ├─ step_world_with_arena @zero_alloc [no-alloc]
     ╰─ step_world_leaky [heap]
    ────────────────────────────────────────────────────────────────────────────────────────
    ```

Packages imported from outside the target directory (relative paths, or `--collection name=path` for `name:` imports) are analyzed as dependencies: their allocations show up in call chains, but their own findings aren't reported.

## Built-in Rules

| Rule | Severity | Description |
| :--- | :--- | :--- |
| `alloc/zero-alloc` | `ERROR` | Procedure marked `@zero_alloc` (or passed via `-e`) allocates on `context.allocator`, directly or through calls: `make`/`new`, allocating `core:` procedures, `append` and other container growth, map insertion (`m[k] = v`), map and dynamic-array literals, and allocator parameters left at `context.allocator`. Appending to a fixed-capacity `[dynamic; N]T` doesn't count. |
| `alloc/no-temp` | `ERROR` | Procedure marked `@no_temp_alloc` (or passed via `--no-temp`) allocates on `context.temp_allocator`, directly or through calls. |
| `alloc/loop-temp` | `WARN` | An unbounded loop (`for {}`, `for cond {}`), or any loop of a `@zero_alloc` procedure, makes new temp allocations every iteration without `free_all(context.temp_allocator)` or a temp guard in the loop. Appending to a container made before the loop and branches that end in `return` don't count. |
| `alloc/dangling-temp` | `ERROR` | Procedure frees the temp allocator on exit (`defer free_all(context.temp_allocator)` or `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` at procedure scope) but returns memory allocated on it (use after free). |
| `alloc/discarded` | `ERROR` | Return value of a fresh allocation (`make`, `new`, `strings.clone`, `fmt.aprintf`, `slice.clone`, ...) is ignored or assigned to `_`. |
| `arch/layer-boundary` | `ERROR` | Package imports a forbidden package (`// @forbid_import(...)` or `--forbid-import a->b`), directly or through other packages. |
| `arch/import-cycle` | `ERROR` | Cyclic dependency between packages. The compiler rejects these too; olint shows the whole cycle without compiling. |
| `perf/large-value-copy` | `WARN` | An aggregate of at least `--large-copy-bytes` (default `128` B, sized by Odin's layout rules) is copied: a C-ABI parameter without `#by_ptr`, a parameter copied into a local (`p := p`), or `for v in items` instead of `for &v in items`. Plain Odin parameters are passed by an implicit pointer on 64-bit targets and aren't flagged. |
| `annotation/unknown` | `WARN` | A misspelled annotation (`@zero_aloc`) or an unknown rule name in `@ignore(...)`, which would otherwise turn a check off without a word. |

## Running Inside `odin test` and CI

Copy the `olint` folder into your project (for example as `libs/olint`) and call `olint.expect_clean` inside any `@(test)` procedure:

```odin
package my_tests

import "core:testing"
import olint "../libs/olint"

@(test)
verify_architecture_and_allocations :: proc(t: ^testing.T) {
	cfg := olint.default_config()
	cfg.zero_alloc_procs = {"step_world", "audio_render_callback"}
	cfg.forbid_imports = {
		{from = "physics", to = "sim"},
		{from = "sim",     to = "render"},
	}
	olint.expect_clean(t, "../src", cfg)
}
```

For GitHub Actions Code Scanning and PR summaries, export SARIF 2.1.0 (`codeFlows` included), Markdown, or JSON:

```sh
olint check . --fail-on-warnings --sarif results.sarif --md summary.md --json report.json
```

## License

BSD 3-Clause, see [LICENSE](https://github.com/zeybek/olint/blob/main/LICENSE).
