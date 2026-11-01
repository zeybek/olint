package olint_tests

import olint "../olint"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Loads `vfiles`, runs every rule, and returns the report. The caller destroys it.
@(private = "file")
_analyze :: proc(vfiles: []olint.Virtual_File, cfg := olint.Config{}) -> olint.Report {
	run_cfg := cfg
	if run_cfg.enabled_rules == {} {
		run_cfg.enabled_rules = olint.ALL_RULES
	}
	if run_cfg.large_copy_bytes == 0 {
		run_cfg.large_copy_bytes = olint.DEFAULT_LARGE_COPY_BYTES
	}
	ws := olint.workspace_load_virtual(vfiles, run_cfg)
	defer olint.workspace_destroy(&ws)
	return olint.analyze_workspace(&ws, run_cfg)
}

@(private = "file")
_symbols_for :: proc(rep: ^olint.Report, rule: olint.Rule_ID) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for &d in rep.diagnostics {
		if d.rule == rule {
			append(&out, d.symbol)
		}
	}
	return out[:]
}

@(private = "file")
_has :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}

// A user procedure named like an obench harness call (`step`) must still be analyzed when the
// package doesn't import obench.
@(test)
test_user_proc_named_step_is_not_treated_as_obench :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/game/game.odin",
				src = `package game

import "core:fmt"

step :: proc(dt: f32) -> string {
	return fmt.aprintf("%f", dt)
}

// @zero_alloc
frame :: proc(dt: f32) {
	s := step(dt)
	delete(s)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "game.frame"))
}

// Procedures declared inside another procedure are part of the call graph.
@(test)
test_nested_procedure_calls_are_followed :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/nest/nest.odin",
				src = `package nest

import "core:strings"

// @zero_alloc
outer :: proc(s: string) {
	helper :: proc(s: string) -> string {
		return strings.clone(s)
	}
	c := helper(s)
	delete(c)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	zero := _symbols_for(&rep, .Zero_Alloc)
	testing.expect(t, _has(zero, "nest.outer"))
}

// `context.allocator = context.temp_allocator` redirects later allocations to the temp
// allocator: that is a temp allocation, not a heap one.
@(test)
test_context_allocator_redirected_to_temp :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/ctx/ctx.odin",
				src = `package ctx

// @zero_alloc
// @no_temp_alloc
redirected :: proc(n: int) {
	context.allocator = context.temp_allocator
	buf := make([]u8, n)
	_ = buf
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, !_has(_symbols_for(&rep, .Zero_Alloc), "ctx.redirected"))
	testing.expect(t, _has(_symbols_for(&rep, .No_Temp), "ctx.redirected"))
}

// Callees inherit the caller's `context`, so a callee's `make` goes to an arena the caller set.
@(test)
test_callee_inherits_context_arena :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/arena/arena.odin",
				src = `package arena

import "core:mem"

build :: proc(n: int) -> []int {
	return make([]int, n)
}

// @zero_alloc
with_arena :: proc(backing: []byte, n: int) {
	a: mem.Arena
	mem.arena_init(&a, backing)
	context.allocator = mem.arena_allocator(&a)
	xs := build(n)
	_ = xs
}

// @zero_alloc
without_arena :: proc(n: int) {
	xs := build(n)
	delete(xs)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	zero := _symbols_for(&rep, .Zero_Alloc)
	testing.expect(t, !_has(zero, "arena.with_arena"))
	testing.expect(t, _has(zero, "arena.without_arena"))
}

// A file-level `@ignore` covers that file only, not every procedure of the package.
@(test)
test_file_ignore_does_not_leak_into_other_files :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/pkg/a.odin",
				src = `// @ignore
package pkg

import "core:fmt"

// @zero_alloc
quiet :: proc() -> string {
	return fmt.aprintf("x")
}
`,
			},
			{
				path = "/virtual/pkg/b.odin",
				src = `package pkg

import "core:fmt"

// @zero_alloc
loud :: proc() -> string {
	return fmt.aprintf("y")
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	zero := _symbols_for(&rep, .Zero_Alloc)
	testing.expect(t, !_has(zero, "pkg.quiet"))
	testing.expect(t, _has(zero, "pkg.loud"))
}

// A procedure literal passed as an argument runs on behalf of the caller (sort comparators,
// iterators), so its allocations count.
@(test)
test_inline_callback_allocations_count :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/cb/cb.odin",
				src = `package cb

import "core:fmt"
import "core:slice"

// @zero_alloc
sort_names :: proc(xs: []int) {
	slice.sort_by(xs, proc(a, b: int) -> bool {
		s := fmt.aprintf("%d", a)
		defer delete(s)
		return a < b
	})
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "cb.sort_names"))
}

// Procedure group members may live in another package.
@(test)
test_cross_package_proc_group_members :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/lib/lib.odin",
				src = `package lib

import "core:strings"

dup_string :: proc(s: string) -> string {
	return strings.clone(s)
}
`,
			},
			{
				path = "/virtual/app/app.odin",
				src = `package app

import "../lib"

dup :: proc{lib.dup_string}

// @zero_alloc
use_group :: proc(s: string) {
	c := dup(s)
	delete(c)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "app.use_group"))
}

// `iter_batched` with named arguments: only `routine` is measured.
@(test)
test_iter_batched_named_arguments :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/bench/bench.odin",
				src = `package bench

import "core:fmt"
import obench "../obench"

// @zero_alloc
bench_named :: proc(b: ^obench.Bencher) {
	obench.iter_batched(
		b,
		setup = proc(b: ^obench.Bencher) -> []int { return make([]int, 8) },
		routine = proc(data: ^[]int) { s := fmt.aprintf("%d", len(data^)); delete(s) },
		teardown = proc(data: ^[]int) { delete(data^) },
	)
}
`,
			},
			{
				path = "/virtual/obench/obench.odin",
				src = `package obench

Bencher :: struct { n: int }

iter_batched :: proc(b: ^Bencher, setup: rawptr = nil, routine: rawptr = nil, teardown: rawptr = nil) {}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	chain_has_aprintf := false
	for &d in rep.diagnostics {
		if d.rule == .Zero_Alloc && d.symbol == "bench.bench_named" {
			for step in d.chain {
				if strings.contains(step.description, "fmt.aprintf") {
					chain_has_aprintf = true
				}
			}
		}
	}
	testing.expect(t, chain_has_aprintf)
}

// Virtual package directories are compared in the cleaned form imports resolve to (on Windows
// that form uses `\`, so `/virtual/lib` never matched).
@(test)
test_virtual_imports_resolve_to_cleaned_directories :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/app/app.odin",
				src = `package app

import "../lib"

// @zero_alloc
run :: proc() -> int {
	return lib.grow()
}
`,
			},
			{
				path = "/virtual/x/../lib/lib.odin",
				src = `package lib

grow :: proc() -> int {
	xs := make([]int, 4)
	defer delete(xs)
	return len(xs)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "app.run"))
}

// `iter_with_large_drop` measures `routine` only; `drop` runs outside the measurement.
@(test)
test_iter_with_large_drop_measures_only_the_routine :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/drop/drop.odin",
				src = `package drop

import "core:fmt"
import obench "../obench"

// @zero_alloc
bench_drop_frees :: proc(b: ^obench.Bencher) {
	obench.iter_with_large_drop(
		b,
		proc() -> int { return 1 },
		proc(v: ^int) { s := fmt.aprintf("%d", v^); delete(s) },
	)
}

// @zero_alloc
bench_routine_allocates :: proc(b: ^obench.Bencher) {
	obench.iter_with_large_drop(
		b,
		routine = proc() -> []int { return make([]int, 8) },
		drop = proc(v: ^[]int) { delete(v^) },
	)
}
`,
			},
			{
				path = "/virtual/obench/obench.odin",
				src = `package obench

Bencher :: struct { n: int }

iter_with_large_drop :: proc(b: ^Bencher, routine: rawptr = nil, drop: rawptr = nil) {}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	zero := _symbols_for(&rep, .Zero_Alloc)
	testing.expect(t, !_has(zero, "drop.bench_drop_frees"))
	testing.expect(t, _has(zero, "drop.bench_routine_allocates"))
}

// Code between `obench.pause` and `obench.resume`, or after `obench.scoped_pause` until the
// end of its block, isn't measured.
@(test)
test_paused_code_is_not_measured :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/pz/pz.odin",
				src = `package pz

import obench "../obench"

// @zero_alloc
bench_scoped :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		{
			obench.scoped_pause(b)
			buf := make([]u8, 128)
			delete(buf)
		}
	}
}

// @zero_alloc
bench_pause_resume :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		obench.pause(b)
		buf := make([]u8, 128)
		delete(buf)
		obench.resume(b)
	}
}

// @zero_alloc
bench_after_scope :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		{
			obench.scoped_pause(b)
		}
		buf := make([]u8, 64)
		delete(buf)
	}
}

// @zero_alloc
bench_after_resume :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		obench.pause(b)
		obench.resume(b)
		buf := make([]u8, 64)
		delete(buf)
	}
}
`,
			},
			{
				path = "/virtual/obench/obench.odin",
				src = `package obench

Bencher :: struct { n: int }

step :: proc(b: ^Bencher) -> bool { return false }
pause :: proc(b: ^Bencher) {}
resume :: proc(b: ^Bencher) {}
scoped_pause :: proc(b: ^Bencher) {}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	zero := _symbols_for(&rep, .Zero_Alloc)
	testing.expect(t, !_has(zero, "pz.bench_scoped"))
	testing.expect(t, !_has(zero, "pz.bench_pause_resume"))
	testing.expect(t, _has(zero, "pz.bench_after_scope"))
	testing.expect(t, _has(zero, "pz.bench_after_resume"))
}

// `@no_temp_alloc` holds even when the loop frees the temp allocator each iteration.
@(test)
test_no_temp_sees_allocations_in_self_freeing_loops :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/nt/nt.odin",
				src = `package nt

import "core:fmt"

// @no_temp_alloc
render :: proc(items: []int) {
	for x in items {
		free_all(context.temp_allocator)
		_ = fmt.tprintf("%d", x)
	}
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .No_Temp), "nt.render"))
}

// `[dynamic; N]T` has a fixed capacity and never allocates.
@(test)
test_fixed_capacity_dynamic_array_append_is_not_an_allocation :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/fc/fc.odin",
				src = `package fc

// @zero_alloc
collect :: proc(xs: []int) -> int {
	buf: [dynamic; 16]int
	for x in xs {
		append(&buf, x)
	}
	return len(buf)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect_value(t, len(_symbols_for(&rep, .Zero_Alloc)), 0)
}

// Map and dynamic-array literals (behind `#+feature dynamic-literals`) allocate on
// `context.allocator`.
@(test)
test_dynamic_literals_allocate :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/lit/lit.odin",
				src = `#+feature dynamic-literals
package lit

// @zero_alloc
table :: proc() -> int {
	m := map[string]int{"a" = 1}
	defer delete(m)
	return len(m)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "lit.table"))
}

// A temp guard inside a nested block ends with that block, not at the procedure exit.
@(test)
test_dangling_temp_only_for_procedure_scope_guards :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/dg/dg.odin",
				src = `package dg

import "base:runtime"
import "core:fmt"

label :: proc(name: string, verbose: bool) -> string {
	if verbose {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		_ = fmt.tprintf("scratch")
	}
	return fmt.tprintf("hello %s", name)
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect_value(t, len(_symbols_for(&rep, .Dangling_Temp)), 0)
}

// An allocation in a branch that returns runs once per call, not once per iteration.
@(test)
test_loop_temp_ignores_allocations_followed_by_return :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/lt/lt.odin",
				src = `package lt

import "core:fmt"

find :: proc(queue: []int, target: int) -> string {
	head := 0
	for head < len(queue) {
		if queue[head] == target {
			msg := fmt.tprintf("found %d", target)
			return msg
		}
		head += 1
	}
	return ""
}

churn :: proc(queue: []int) {
	head := 0
	for head < len(queue) {
		_ = fmt.tprintf("visit %d", queue[head])
		head += 1
	}
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	loop := _symbols_for(&rep, .Loop_Temp)
	testing.expect(t, !_has(loop, "lt.find"))
	testing.expect(t, _has(loop, "lt.churn"))
}

// `@(zero_alloc)` attributes (with `-custom-attribute:zero_alloc`) work like the comment form.
@(test)
test_attribute_annotations :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/attr/attr.odin",
				src = `package attr

import "core:fmt"

@(zero_alloc)
tagged :: proc() -> string {
	return fmt.aprintf("x")
}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "attr.tagged"))
}

// A misspelled annotation must not silently disable a check.
@(test)
test_misspelled_annotation_is_reported :: proc(t: ^testing.T) {
	rep := _analyze(
		{
			{
				path = "/virtual/typo/typo.odin",
				src = `package typo

// @zero_aloc
fast :: proc() {}

// @ignore(alloc/zero-aloc)
also_fast :: proc() {}

// @group(sorting) @params(8, 64)
bench_like :: proc() {}

// @note not an annotation olint knows, and not close to one
documented :: proc() {}
`,
			},
		},
	)
	defer olint.report_destroy(&rep)
	unknown := _symbols_for(&rep, .Unknown_Annotation)
	testing.expect_value(t, len(unknown), 2)
	testing.expect(t, _has(unknown, "typo.fast"))
	testing.expect(t, _has(unknown, "typo.also_fast"))
}

// Imports of packages outside the analyzed directory are followed as dependencies: their
// allocations count, but their own findings are not reported.
@(test)
test_dependencies_outside_root_are_followed :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "olint-deps-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)

	app_dir, _ := filepath.join({root, "app"}, context.temp_allocator)
	lib_dir, _ := filepath.join({root, "lib"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(app_dir), nil)
	testing.expect_value(t, os.make_directory_all(lib_dir), nil)
	app_file, _ := filepath.join({app_dir, "app.odin"}, context.temp_allocator)
	lib_file, _ := filepath.join({lib_dir, "lib.odin"}, context.temp_allocator)
	testing.expect_value(
		t,
		os.write_entire_file(
			app_file,
			`package app

import "../lib"

// @zero_alloc
tick :: proc() {
	lib.log_frame()
}
`,
		),
		nil,
	)
	testing.expect_value(
		t,
		os.write_entire_file(
			lib_file,
			`package lib

import "core:fmt"

log_frame :: proc() {
	s := fmt.aprintf("frame")
	delete(s)
}

// @zero_alloc
own_problem :: proc() -> string {
	return fmt.aprintf("not reported: lib is a dependency here")
}
`,
		),
		nil,
	)

	cfg := olint.default_config()
	cfg.color_output = false
	rep, ok := olint.analyze_path(app_dir, cfg)
	testing.expect(t, ok)
	defer olint.report_destroy(&rep)

	zero := _symbols_for(&rep, .Zero_Alloc)
	testing.expect(t, _has(zero, "app.tick"))
	testing.expect(t, !_has(zero, "lib.own_problem"))
	testing.expect_value(t, rep.packages_count, 1)
	testing.expect_value(t, rep.dependencies_count, 1)
}

// `name:sub` imports resolve through `Config.collections`.
@(test)
test_collection_imports_resolve :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "olint-coll-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)

	app_dir, _ := filepath.join({root, "app"}, context.temp_allocator)
	shared_dir, _ := filepath.join({root, "shared", "text"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(app_dir), nil)
	testing.expect_value(t, os.make_directory_all(shared_dir), nil)
	app_file, _ := filepath.join({app_dir, "app.odin"}, context.temp_allocator)
	text_file, _ := filepath.join({shared_dir, "text.odin"}, context.temp_allocator)
	testing.expect_value(
		t,
		os.write_entire_file(
			app_file,
			`package app

import "libs:text"

// @zero_alloc
tick :: proc(s: string) {
	c := text.copy_of(s)
	delete(c)
}
`,
		),
		nil,
	)
	testing.expect_value(
		t,
		os.write_entire_file(
			text_file,
			`package text

import "core:strings"

copy_of :: proc(s: string) -> string {
	return strings.clone(s)
}
`,
		),
		nil,
	)

	shared_root, _ := filepath.join({root, "shared"}, context.temp_allocator)
	cfg := olint.default_config()
	cfg.color_output = false
	cfg.collections = {{name = "libs", path = shared_root}}
	rep, ok := olint.analyze_path(app_dir, cfg)
	testing.expect(t, ok)
	defer olint.report_destroy(&rep)
	testing.expect(t, _has(_symbols_for(&rep, .Zero_Alloc), "app.tick"))
}

// An export path that can't be written fails the run instead of passing silently.
@(test)
test_unwritable_export_fails_the_run :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "olint-io-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)
	src_file, _ := filepath.join({root, "ok.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(src_file, "package ok\n\nf :: proc() {}\n"), nil)

	bad_path, _ := filepath.join({root, "missing-dir", "out.json"}, context.temp_allocator)
	cfg := olint.default_config()
	cfg.color_output = false
	cfg.json_export_path = bad_path
	rep, ok := olint.analyze_path(root, cfg)
	testing.expect(t, ok)
	defer olint.report_destroy(&rep)
	testing.expect_value(t, len(rep.io_errors), 1)
	testing.expect(t, !olint.report_passed(&rep, cfg))
}
