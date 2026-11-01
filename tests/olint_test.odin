package olint_tests

import olint "../olint"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_zero_alloc_transitive_call_chain :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/sim/tick.odin",
			src = `package sim

import "../physics"

// @zero_alloc
step_world :: proc(dt: f32) {
	physics.resolve_contacts(dt)
}

// @zero_alloc
clean_math :: proc(a, b: f32) -> f32 {
	return a * b + 1.0
}
`,
		},
		{
			path = "/virtual/physics/narrow.odin",
			src = `package physics

import "core:fmt"

resolve_contacts :: proc(dt: f32) {
	emit_contact_debug(dt)
}

emit_contact_debug :: proc(dt: f32) {
	msg := fmt.aprintf("dt=%f", dt)
	delete(msg)
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 1)
	testing.expect_value(t, len(rep.diagnostics), 1)
	if len(rep.diagnostics) == 1 {
		d := rep.diagnostics[0]
		testing.expect_value(t, d.rule, olint.Rule_ID.Zero_Alloc)
		testing.expect_value(t, d.symbol, "sim.step_world")
		testing.expect_value(t, len(d.chain), 3)
		if len(d.chain) == 3 {
			testing.expect_value(t, d.chain[0].symbol, "sim.step_world")
			testing.expect_value(t, d.chain[1].symbol, "physics.resolve_contacts")
			testing.expect_value(t, d.chain[2].symbol, "physics.emit_contact_debug")
		}
	}
}

@(test)
test_map_index_assignment_in_zero_alloc :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/cache/cache.odin",
			src = `package cache

import "core:mem"

// @zero_alloc
insert_heap_map :: proc(m: ^map[string]int, k: string, v: int) {
	m[k] = v
}

// @zero_alloc
insert_arena_map :: proc(buf: []byte, k: string, v: int) {
	arena: mem.Arena
	mem.arena_init(&arena, buf)
	arena_alloc := mem.arena_allocator(&arena)
	m := make(map[string]int, 16, arena_alloc)
	m[k] = v
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 1)
	testing.expect_value(t, len(rep.diagnostics), 1)
	if len(rep.diagnostics) == 1 {
		testing.expect_value(t, rep.diagnostics[0].rule, olint.Rule_ID.Zero_Alloc)
		testing.expect_value(t, rep.diagnostics[0].symbol, "cache.insert_heap_map")
	}
}

@(test)
test_allocator_parameter_forwarding :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/pkg/alloc_forward.odin",
			src = `package pkg

import "core:fmt"
import "core:mem"
import "core:strings"

format_temp :: proc(x: int, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%d", x, allocator = allocator)
}

format_heap :: proc(x: int, allocator := context.allocator) -> string {
	return strings.clone("abc", allocator)
}

// @zero_alloc
caller_using_temp_default :: proc(x: int) -> string {
	return format_temp(x)
}

// @zero_alloc
caller_using_custom_arena :: proc(x: int) -> string {
	buf: [256]byte
	arena: mem.Arena
	mem.arena_init(&arena, buf[:])
	arena_alloc := mem.arena_allocator(&arena)
	return format_heap(x, arena_alloc)
}

// @zero_alloc
caller_using_heap_default :: proc(x: int) -> string {
	return format_heap(x)
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 1)
	testing.expect_value(t, len(rep.diagnostics), 1)
	if len(rep.diagnostics) == 1 {
		testing.expect_value(t, rep.diagnostics[0].symbol, "pkg.caller_using_heap_default")
	}
}

@(test)
test_no_temp_and_loop_temp_rules :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/audio/mixer.odin",
			src = `package audio

import "core:fmt"

// @no_temp_alloc
audio_callback :: proc(samples: []f32) {
	_ = fmt.tprintf("len=%d", len(samples))
}

server_loop_bad :: proc(items: []int) {
	running := len(items) > 0
	for running {
		_ = fmt.tprintf("item=%d", items[0])
		running = false
	}
}

server_loop_good :: proc(items: []int) {
	running := len(items) > 0
	for running {
		free_all(context.temp_allocator)
		_ = fmt.tprintf("item=%d", items[0])
		running = false
	}
}

accumulate_temp_slice :: proc(items: []int) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	for x in items {
		append(&out, x * 2)
	}
	return out
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 1)
	testing.expect_value(t, rep.warning_count, 1)
	testing.expect_value(t, len(rep.diagnostics), 2)
	if len(rep.diagnostics) == 2 {
		testing.expect_value(t, rep.diagnostics[0].rule, olint.Rule_ID.No_Temp)
		testing.expect_value(t, rep.diagnostics[0].symbol, "audio.audio_callback")
		testing.expect_value(t, rep.diagnostics[1].rule, olint.Rule_ID.Loop_Temp)
		testing.expect_value(t, rep.diagnostics[1].symbol, "audio.server_loop_bad")
	}
}

@(test)
test_dangling_temp_return_rule :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/uaf/uaf.odin",
			src = `package uaf

import "base:runtime"
import "core:fmt"
import "core:strings"

bad_defer_free :: proc(name: string) -> string {
	defer free_all(context.temp_allocator)
	return fmt.tprintf("hello %s", name)
}

bad_temp_guard_var :: proc(name: string) -> string {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	tmp := strings.clone(name, context.temp_allocator)
	return tmp
}

safe_heap_return :: proc(name: string) -> string {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	_ = fmt.tprintf("scratch %s", name)
	return strings.clone(name, context.allocator)
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 2)
	testing.expect_value(t, len(rep.diagnostics), 2)
	if len(rep.diagnostics) == 2 {
		testing.expect_value(t, rep.diagnostics[0].rule, olint.Rule_ID.Dangling_Temp)
		testing.expect_value(t, rep.diagnostics[0].symbol, "uaf.bad_defer_free")
		testing.expect_value(t, rep.diagnostics[1].rule, olint.Rule_ID.Dangling_Temp)
		testing.expect_value(t, rep.diagnostics[1].symbol, "uaf.bad_temp_guard_var")
	}
}

@(test)
test_discarded_alloc_rule :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/leak/leak.odin",
			src = `package leak

import "core:strings"

leaky :: proc(s: string) {
	strings.clone(s)
	_ = make([]int, 16)
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 2)
	for d in rep.diagnostics {
		testing.expect_value(t, d.rule, olint.Rule_ID.Discarded_Alloc)
	}
}

@(test)
test_layer_boundary_and_import_cycle :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/ui/view.odin",
			src = `// @forbid_import("db")
package ui

import "../state"

render_ui :: proc() {
	state.load_user()
}
`,
		},
		{
			path = "/virtual/state/store.odin",
			src = `package state

import "../db"

load_user :: proc() {
	db.query()
}
`,
		},
		{path = "/virtual/db/db.odin", src = `package db

query :: proc() {}
`},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.error_count, 1)
	if len(rep.diagnostics) == 1 {
		d := rep.diagnostics[0]
		testing.expect_value(t, d.rule, olint.Rule_ID.Layer_Boundary)
		testing.expect_value(t, d.pkg_name, "ui")
		testing.expect_value(t, len(d.chain), 2)
	}
}

@(test)
test_import_cycle_detection :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/alpha/alpha.odin",
			src = `package alpha

import "../beta"

a :: proc() { beta.b() }
`,
		},
		{
			path = "/virtual/beta/beta.odin",
			src = `package beta

import "../alpha"

b :: proc() { alpha.a() }
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect(t, rep.error_count >= 1)
	found_cycle := false
	for d in rep.diagnostics {
		if d.rule == .Import_Cycle {
			found_cycle = true
		}
	}
	testing.expect(t, found_cycle)
}

@(test)
test_large_value_copy_and_selector_range :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/perf/copy.odin",
			src = `package perf

Big_Transform :: struct {
	matrices: [4][16]f32, // 256 bytes
}

Scene :: struct {
	transforms: [dynamic]Big_Transform,
}

// Normal Odin proc: compiler passes >16B immutable parameter by const pointer automatically (no copy!).
takes_immutable_odin :: proc(t: Big_Transform) -> f32 {
	return t.matrices[0][0]
}

// C-ABI proc without #by_ptr: forces a 256-byte stack copy!
takes_c_by_value :: proc "c" (t: Big_Transform) -> f32 {
	return t.matrices[0][0]
}

// Shadow-copying an immutable parameter into a mutable local copies 256 bytes onto the stack!
shadows_param :: proc(t: Big_Transform) -> f32 {
	t := t
	t.matrices[0][0] += 1.0
	return t.matrices[0][0]
}

takes_c_by_ptr :: proc "c" (#by_ptr t: Big_Transform) -> f32 {
	return t.matrices[0][0]
}

iterates_by_value :: proc(items: []Big_Transform) -> f32 {
	sum := f32(0)
	for item in items {
		sum += item.matrices[0][0]
	}
	return sum
}

iterates_selector_by_value :: proc(s: ^Scene) -> f32 {
	sum := f32(0)
	for item in s.transforms {
		sum += item.matrices[0][0]
	}
	return sum
}

iterates_by_ref :: proc(s: ^Scene) -> f32 {
	sum := f32(0)
	for &item in s.transforms {
		sum += item.matrices[0][0]
	}
	return sum
}
`,
		},
	}

	cfg := olint.default_config()
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	rep := olint.analyze_workspace(&ws, cfg)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.warning_count, 4)
	if len(rep.diagnostics) == 4 {
		testing.expect_value(t, rep.diagnostics[0].rule, olint.Rule_ID.Large_Value_Copy)
		testing.expect_value(t, rep.diagnostics[0].symbol, "perf.takes_c_by_value")
		testing.expect_value(t, rep.diagnostics[1].rule, olint.Rule_ID.Large_Value_Copy)
		testing.expect_value(t, rep.diagnostics[1].symbol, "perf.shadows_param")
		testing.expect_value(t, rep.diagnostics[2].rule, olint.Rule_ID.Large_Value_Copy)
		testing.expect_value(t, rep.diagnostics[2].symbol, "perf.iterates_by_value")
		testing.expect_value(t, rep.diagnostics[3].rule, olint.Rule_ID.Large_Value_Copy)
		testing.expect_value(t, rep.diagnostics[3].symbol, "perf.iterates_selector_by_value")
	}
}

@(test)
test_json_md_and_sarif_export :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "olint-export-test-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(tmp)

	src := `package demo

import "core:fmt"

// @zero_alloc
hot_fn :: proc() -> string {
	return fmt.aprintf("alloc")
}
`
	fpath, _ := filepath.join({tmp, "demo.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(fpath, src), nil)

	json_path, _ := filepath.join({tmp, "out.json"}, context.temp_allocator)
	md_path, _ := filepath.join({tmp, "out.md"}, context.temp_allocator)
	sarif_path, _ := filepath.join({tmp, "out.sarif"}, context.temp_allocator)

	cfg := olint.default_config()
	cfg.color_output = false
	cfg.json_export_path = json_path
	cfg.md_export_path = md_path
	cfg.sarif_export_path = sarif_path

	rep, ok := olint.analyze_path(tmp, cfg)
	testing.expect(t, ok)
	defer olint.report_destroy(&rep)

	json_bytes, j_err := os.read_entire_file(json_path, context.temp_allocator)
	testing.expect_value(t, j_err, nil)
	testing.expect(t, strings.contains(string(json_bytes), "\"alloc/zero-alloc\""))

	md_bytes, m_err := os.read_entire_file(md_path, context.temp_allocator)
	testing.expect_value(t, m_err, nil)
	testing.expect(t, strings.contains(string(md_bytes), "`alloc/zero-alloc`"))
	testing.expect(t, strings.contains(string(md_bytes), "**ERROR**"))

	sarif_bytes, s_err := os.read_entire_file(sarif_path, context.temp_allocator)
	testing.expect_value(t, s_err, nil)
	testing.expect(t, strings.contains(string(sarif_bytes), "\"version\": \"2.1.0\""))
	testing.expect(t, strings.contains(string(sarif_bytes), "\"codeFlows\""))
}
