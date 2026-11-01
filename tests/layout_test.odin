package olint_tests

import olint "../olint"
import "core:odin/ast"
import "core:testing"

// Expected sizes are `size_of` results from the Odin compiler (dev-2026-10, 64-bit target).
@(test)
test_type_layout_matches_compiler :: proc(t: ^testing.T) {
	vfiles := []olint.Virtual_File {
		{
			path = "/virtual/layout/layout.odin",
			src = `package layout

import "base:runtime"

N :: 4
A :: struct { a: u8, b: u64, c: u16 }
B :: struct #packed { a: u8, b: u64 }
C :: struct { m: [N]A, s: string, flag: bool }
D :: struct #raw_union { x: u64, y: [3]u32 }
E :: enum u16 { X, Y }
F :: struct { e: E, d: D, arr: [dynamic]int, m: map[int]int }
G :: struct { c: complex64, q: quaternion128 }
H :: struct { loc: runtime.Source_Code_Location, alloc: runtime.Allocator, fixed: [dynamic; 3]u32 }
`,
		},
	}
	cfg := olint.Config {
		enabled_rules = olint.ALL_RULES,
	}
	ws := olint.workspace_load_virtual(vfiles, cfg)
	defer olint.workspace_destroy(&ws)

	expected := [?]struct {
		name: string,
		size: int,
	}{{"A", 24}, {"B", 9}, {"C", 120}, {"D", 16}, {"E", 2}, {"F", 96}, {"G", 24}, {"H", 80}}

	for e in expected {
		tid := olint.lookup_type(&ws, 0, "", e.name)
		if !testing.expectf(t, tid >= 0, "type %s not found", e.name) {
			continue
		}
		ident := ast.Ident {
			name = e.name,
		}
		ident.derived = &ident
		ident.derived_expr = &ident
		got := olint.estimate_type_size(&ws, 0, &ident)
		testing.expectf(t, got == e.size, "size_of(%s): expected %d, got %d", e.name, e.size, got)
	}
}
