/*
Static call-graph allocation, architecture, and data-oriented performance linter for Odin.

`olint` parses an Odin project with `core:odin/parser`, builds the call graph and the package
import graph, and checks `@zero_alloc` and `@no_temp_alloc` guarantees, `context.temp_allocator`
discipline, package layering, and large value copies, without compiling or running the
project. It depends on `base:` and `core:` only.

Odin's `-vet` flags look at one procedure or file at a time. When a procedure marked
`// @zero_alloc` calls a helper that, four calls further down and in another package, calls
`fmt.aprintf`, appends to a dynamic array, or inserts into a map, `olint` reports the shortest
call chain from the marked procedure to that statement.

Features:

- Call-graph checks for `@zero_alloc` and `@no_temp_alloc` (`alloc/zero-alloc`, `alloc/no-temp`)
- Allocations follow `context`: a callee's `make` goes wherever the caller's `context.allocator`
  points at the call (`context.allocator = mem.arena_allocator(&a)` removes it,
  `context.allocator = context.temp_allocator` turns it into a temp allocation), and allocator
  parameters (`allocator := context.allocator`) are followed through every call
- Temp allocations that pile up in loops (`alloc/loop-temp`) and temp memory returned from a
  procedure that frees the temp allocator on exit (`alloc/dangling-temp`)
- Discarded results of allocating calls (`alloc/discarded`)
- Package layering and import cycles (`arch/layer-boundary`, `arch/import-cycle`)
- Large value copies (`perf/large-value-copy`), with sizes computed by Odin's layout rules
- Misspelled annotations (`annotation/unknown`), so a typo such as `@zero_aloc` doesn't
  silently turn a check off
- Terminal, Markdown (`--md`), JSON (`--json`), and SARIF 2.1.0 (`--sarif`, with `codeFlows`)
  reports, and `odin test` integration (`expect_clean`)

Install

This folder is the library. Copy it into your project, for example as `libs/olint`, and
import it with `import olint "libs/olint"`. Each release on
https://github.com/zeybek/olint/releases has it as `olint-<tag>-library.tar.gz` and
`.zip`, together with the license.

To keep the whole repository in your history and update it later, add it with git subtree
and import the folder inside it, `libs/olint/olint`. The CLI skips a copy like this when it
scans a project, unless the project imports it.

	git subtree add --prefix=libs/olint https://github.com/zeybek/olint main --squash

What gets analyzed

Every package under the target directory is analyzed and reported on, except directories
named `bin`, `build`, `dist`, `node_modules`, `target`, or `vendor`, hidden directories, and
`*_test.odin` files (pass `--include-tests` for those). Packages that these import from
outside the directory, through relative paths or through `--collection name=path`, are
loaded as dependencies: their allocations count in call chains, but their own findings are
not reported. Calls into `base:`, `core:`, and `vendor:` packages use a built-in table of the
procedures that allocate (`fmt.aprintf`, `strings.clone`, `slice.clone`, `os.read_entire_file`,
...); calls to other procedures in those packages count as not allocating.

Files are filtered by their `#+build` tags for the platform `olint` runs on, the same way the
compiler would filter them.

Annotations

Put annotations in doc comments (`// @...`) above procedures, or above `package`:

	// @zero_alloc                  Fails if the procedure allocates on context.allocator,
	                                directly or through the procedures it calls.
	// @no_temp_alloc               Fails if the procedure allocates on context.temp_allocator,
	                                directly or through the procedures it calls.
	// @alloc_safe                  The procedure encapsulates its allocations (for example, a
	                                private scratch arena it destroys), so callers aren't tainted.
	// @forbid_import("a", "b:*")   Above `package`: forbids importing matching packages,
	                                directly or indirectly. Matches package names, directory
	                                paths, `@layer` names, and prefixes ending in `*`.
	// @layer(sim)                  Above `package`: names the package's layer.
	// @ignore(alloc/zero-alloc)    Suppresses the listed rules (all rules without arguments)
	                                for a procedure, or above `package` for that file.

Annotations sit on comment lines of their own, and one line may hold several, as in
`// @zero_alloc @no_temp_alloc`. Lines that don't start with `@` are prose, so a sentence
that mentions `@zero_alloc` changes nothing. obench's `@group`, `@params`, and `@threads` are
accepted. `@(zero_alloc)`, `@(no_temp_alloc)`, and `@(alloc_safe)` work as attributes too,
when the project is compiled with `-custom-attribute:zero_alloc,no_temp_alloc,alloc_safe`.

Procedures declared inside another procedure are checked like any other, under names such as
`pkg.outer.inner`. A procedure literal passed as an argument (a comparator, an iterator
callback) counts as running inside the caller.

Running Inside `odin test`

`expect_clean` runs `olint` from a `@(test)` procedure, logs the terminal report on failure,
and fails the test when any error (or warning when `fail_on_warnings` is set) is found. The
path is relative to the directory `odin test` runs in:

	package my_tests

	import "core:testing"
	import olint "../libs/olint"

	@(test)
	architecture_and_allocations :: proc(t: ^testing.T) {
		cfg := olint.default_config()
		cfg.zero_alloc_procs = {"step_world", "audio_callback"}
		cfg.forbid_imports = {
			{from = "sim",     to = "render"},
			{from = "physics", to = "sim"},
		}
		olint.expect_clean(t, "../src", cfg)
	}

Configuration

Programs that call `default_config` pick up these environment variables. Command-line flags
override them:

	OLINT_FILTER             Same as --filter
	OLINT_ZERO_ALLOC         1 or true to treat every procedure as @zero_alloc
	OLINT_FAIL_ON_WARNINGS   1 or true to fail on warnings as well as errors
	OLINT_LARGE_COPY_BYTES   Byte threshold for perf/large-value-copy (default: 128)
	OLINT_JSON, OLINT_MD     Report output paths
	OLINT_SARIF              SARIF 2.1.0 output path
	OLINT_NO_COLOR, NO_COLOR Disable ANSI colors

A report file that can't be written fails the run, so a wrong path in CI doesn't pass
silently.

Compile-time defaults can be changed with `-define`:

	// Enforce zero heap allocations globally across all procedures.
	DEFAULT_ZERO_ALLOC       : bool : #config(OLINT_ZERO_ALLOC,       false)
	// Treat warnings as errors in exit status and expect_clean.
	DEFAULT_FAIL_ON_WARNINGS : bool : #config(OLINT_FAIL_ON_WARNINGS, false)
	// Byte threshold for perf/large-value-copy.
	DEFAULT_LARGE_COPY_BYTES : int  : #config(OLINT_LARGE_COPY_BYTES, 128)
	// Enable ANSI color output in terminal reports.
	DEFAULT_COLOR            : bool : #config(OLINT_COLOR,            true)

Large value copies

With Odin's default `"odin"` and `"contextless"` conventions a procedure can't modify its
parameters, and the compiler passes a large struct or array by an implicit pointer, so a
by-value parameter costs nothing and `perf/large-value-copy` doesn't flag it. It flags the
places where a copy does happen: a C-ABI procedure (`"c"`, `"system"`, `"stdcall"`, ...) that
takes an aggregate by value without `#by_ptr`, a large parameter copied into a local
(`p := p`), and `for v in items` over large elements. Unoptimized builds copy every element of
such a loop; optimized builds drop the copy unless the loop variable escapes (its address is
taken, it is passed to a call, or it is assigned to), which the message says.

This describes 64-bit targets (amd64, arm64). On i386, Odin's own conventions copy large
aggregate parameters as well, and `olint` doesn't report those copies.

Limits

- `core:odin/parser` builds a syntax tree, not a type-checked program. `olint` resolves calls by
  name through import aliases, nested procedures, and procedure groups (all members of a
  group count), and doesn't evaluate overloads by argument type.
- Calls through procedure values (`cb()`, `vtable.update()`, `x->method()`) have no single
  known target and are not followed.
- A local variable holding an allocator is recognized from its initializer
  (`a := mem.arena_allocator(&arena)` is an arena, `a := runtime.heap_allocator()` the heap).
  Other allocator values passed through variables count as custom allocators.
- In procedures that measure something with obench (`for obench.step(b)`,
  `obench.iter_batched`, `obench.iter_with_large_drop`, `obench.run_parallel`), only the
  measured code counts for `@zero_alloc`, as in obench itself. Code between `obench.pause`
  and `obench.resume`, or after `obench.scoped_pause` until the end of its block, isn't
  measured. obench calls are recognized through an import of obench.
- Odin's compiler rejects import cycles itself; `arch/import-cycle` reports the full cycle
  without compiling.
- Sizes of types from `core:` and `vendor:` packages are known for a few common ones
  (`runtime.Allocator`, `runtime.Source_Code_Location`, `time.Duration`, ...). Others count
  as 8 bytes, so the size of a struct that embeds one by value can be off.
*/
package olint

// Version of the olint library and CLI.
VERSION :: "0.1.0" // x-release-please-version

// Enforce zero heap allocations globally across all procedures.
DEFAULT_ZERO_ALLOC: bool : #config(OLINT_ZERO_ALLOC, false)
// Treat warnings as errors in exit status and `expect_clean`.
DEFAULT_FAIL_ON_WARNINGS: bool : #config(OLINT_FAIL_ON_WARNINGS, false)
// Byte threshold for `perf/large-value-copy`.
DEFAULT_LARGE_COPY_BYTES: int : #config(OLINT_LARGE_COPY_BYTES, 128)
// Enable ANSI color output in terminal reports.
DEFAULT_COLOR: bool : #config(OLINT_COLOR, true)
