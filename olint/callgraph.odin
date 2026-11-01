package olint

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:strings"

/*
Where an allocation goes, as seen from inside one procedure.

`.Heap` is the `context.allocator` the procedure was called with and `.Temp` its
`context.temp_allocator`. A call edge remaps a callee's modes through the caller's context at
the call site, so a callee's `.Heap` allocation becomes the caller's `.Temp` allocation after
`context.allocator = context.temp_allocator`, and disappears after
`context.allocator = mem.arena_allocator(&arena)`.
*/
Call_Alloc_Mode :: enum {
	None,
	Heap, // `context.allocator`
	Temp, // `context.temp_allocator`
	Caller_Param, // The procedure's own allocator parameter
	Custom, // An arena or other explicit allocator
}

/*
Allocation facts of a procedure after propagation through the call graph. The `_Fresh`
variants exclude growth of an existing container (`append`, `m[k] = v`) and temp allocations
in loops that free the temp allocator every iteration; `alloc/loop-temp` only follows those.
*/
Taint :: enum {
	Heap,
	Heap_Fresh,
	Temp,
	Temp_Fresh,
	Param,
	Param_Fresh,
}

/*
Set of `Taint` values.
*/
Taints :: bit_set[Taint]

/*
Direct allocation site inside a procedure body.
*/
Direct_Alloc_Site :: struct {
	mode:        Call_Alloc_Mode,
	fresh:       bool, // False for growth of an existing container
	in_loop:     bool,
	loop_id:     int,
	callee_name: string,
	reason:      string,
	location:    Location,
}

/*
Call edge from `caller_id` to `callee_id` (both indices into `Workspace.procs`).
*/
Call_Edge :: struct {
	caller_id: int,
	callee_id: int,
	arg_mode:  Call_Alloc_Mode, // What the callee's allocator parameter receives
	ctx_heap:  Call_Alloc_Mode, // The caller's `context.allocator` at the call
	ctx_temp:  Call_Alloc_Mode, // The caller's `context.temp_allocator` at the call
	in_loop:   bool,
	loop_id:   int,
	location:  Location,
}

/*
Summary of a `for` or range loop inside a procedure.
*/
Loop_Summary :: struct {
	id:           int,
	parent_id:    int, // Enclosing loop, or -1
	proc_id:      int,
	is_unbounded: bool, // `for { ... }` or `for cond { ... }` without init/post
	frees_temp:   bool, // Calls `free_all(context.temp_allocator)` or uses a temp guard
	location:     Location,
}

/*
Per-procedure static call and allocation summary.
*/
Proc_Summary :: struct {
	proc_id:            int,
	direct_sites:       [dynamic]Direct_Alloc_Site,
	callees:            [dynamic]Call_Edge,
	loops:              [dynamic]Loop_Summary,
	frees_temp_on_exit: bool, // Procedure-scope `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD` or `defer free_all(context.temp_allocator)`
	temp_vars:          [dynamic]string, // Locals assigned memory from `context.temp_allocator`
	taints:             Taints, // Result of propagation
}

/*
Whole-workspace call graph and allocation summaries.
*/
Call_Graph :: struct {
	allocator: runtime.Allocator,
	summaries: [dynamic]Proc_Summary,
}

@(private = "file")
_taint_of :: proc "contextless" (mode: Call_Alloc_Mode, fresh: bool) -> (t: Taints) {
	switch mode {
	case .Heap:
		t = {.Heap, .Heap_Fresh} if fresh else {.Heap}
	case .Temp:
		t = {.Temp, .Temp_Fresh} if fresh else {.Temp}
	case .Caller_Param:
		t = {.Param, .Param_Fresh} if fresh else {.Param}
	case .None, .Custom:
	}
	return
}

/*
Reports whether `taints` include an allocation in `mode` (only fresh ones when `fresh_only`).
*/
@(require_results)
has_taint :: proc "contextless" (
	taints: Taints,
	mode: Call_Alloc_Mode,
	fresh_only := false,
) -> bool {
	switch mode {
	case .Heap:
		return (.Heap_Fresh if fresh_only else .Heap) in taints
	case .Temp:
		return (.Temp_Fresh if fresh_only else .Temp) in taints
	case .Caller_Param:
		return (.Param_Fresh if fresh_only else .Param) in taints
	case .None, .Custom:
	}
	return false
}

/*
Maps an allocation mode of the callee of `edge` to the caller's mode at the call site.
*/
@(require_results)
map_through_edge :: proc "contextless" (
	#by_ptr edge: Call_Edge,
	callee_mode: Call_Alloc_Mode,
) -> Call_Alloc_Mode {
	switch callee_mode {
	case .Heap:
		return edge.ctx_heap
	case .Temp:
		return edge.ctx_temp
	case .Caller_Param:
		return edge.arg_mode
	case .None, .Custom:
	}
	return .None
}

// Reports whether loop `loop_id` or a loop around it frees the temp allocator each iteration.
@(private = "file")
_loop_chain_frees_temp :: proc(sum: ^Proc_Summary, loop_id: int) -> bool {
	for l := loop_id; l >= 0 && l < len(sum.loops); l = sum.loops[l].parent_id {
		if sum.loops[l].frees_temp {
			return true
		}
	}
	return false
}

/*
Reports whether `site` is a fresh allocation for `alloc/loop-temp` purposes.
*/
@(require_results)
site_is_fresh :: proc(sum: ^Proc_Summary, #by_ptr site: Direct_Alloc_Site) -> bool {
	if !site.fresh {
		return false
	}
	if site.mode == .Temp && site.in_loop && _loop_chain_frees_temp(sum, site.loop_id) {
		return false
	}
	return true
}

/*
Reports whether code in loop `inner` (or outside any loop when `inner` is -1) runs on every
iteration of loop `outer` without a loop in between that frees the temp allocator.
*/
@(require_results)
loop_reaches :: proc(sum: ^Proc_Summary, inner: int, outer: int) -> bool {
	for l := inner; l >= 0 && l < len(sum.loops); l = sum.loops[l].parent_id {
		if sum.loops[l].frees_temp {
			return false
		}
		if l == outer {
			return true
		}
	}
	return false
}

/*
Builds the call graph and propagates allocation taints for `ws`.
*/
@(require_results)
callgraph_build :: proc(
	ws: ^Workspace,
	allocator := context.allocator,
	loc := #caller_location,
) -> Call_Graph {
	cg := Call_Graph {
		allocator = allocator,
		summaries = make([dynamic]Proc_Summary, len(ws.procs), allocator, loc),
	}
	for i in 0 ..< len(ws.procs) {
		cg.summaries[i] = Proc_Summary {
			proc_id      = i,
			direct_sites = make([dynamic]Direct_Alloc_Site, allocator, loc),
			callees      = make([dynamic]Call_Edge, allocator, loc),
			loops        = make([dynamic]Loop_Summary, allocator, loc),
			temp_vars    = make([dynamic]string, allocator, loc),
		}
	}
	for i in 0 ..< len(ws.procs) {
		_analyze_proc_body(ws, &cg, i)
	}
	_propagate(ws, &cg)
	return cg
}

/*
Frees all memory owned by `cg`.
*/
callgraph_destroy :: proc(cg: ^Call_Graph) {
	alloc := cg.allocator
	for &s in cg.summaries {
		for &site in s.direct_sites {
			delete(site.callee_name, alloc)
			delete(site.reason, alloc)
			delete(site.location.file_path, alloc)
		}
		delete(s.direct_sites)
		for &edge in s.callees {
			delete(edge.location.file_path, alloc)
		}
		delete(s.callees)
		for &lp in s.loops {
			delete(lp.location.file_path, alloc)
		}
		delete(s.loops)
		for tv in s.temp_vars {
			delete(tv, alloc)
		}
		delete(s.temp_vars)
	}
	delete(cg.summaries)
	cg^ = {}
}

@(private = "file")
_Scan :: struct {
	ws:               ^Workspace,
	cg:               ^Call_Graph,
	proc_id:          int,
	current_loop_id:  int, // -1 when outside any loop
	block_depth:      int, // 1 in the procedure's own body block
	in_defer:         bool,
	has_bench_region: bool, // The procedure measures something with obench
	in_bench_region:  bool, // Inside the measured region of a benchmark
	region_at_pause:  bool, // `in_bench_region` before the last `obench.pause`
	obench_qual:      string, // Import alias of obench in this file, or ""
	in_obench_pkg:    bool,
	ctx_heap:         Call_Alloc_Mode, // What `context.allocator` currently refers to
	ctx_temp:         Call_Alloc_Mode, // What `context.temp_allocator` currently refers to
	alloc_vars:       map[string]Call_Alloc_Mode, // Locals holding an allocator
	container_modes:  map[string]Call_Alloc_Mode, // Containers whose allocator is known
	map_vars:         map[string]bool,
}

/*
Splits a call target into its package qualifier (or `""`) and name, without allocating.
*/
@(require_results)
call_target :: proc(expr: ^ast.Expr) -> (qual: string, name: string) {
	if expr == nil {
		return
	}
	#partial switch e in ast.unparen_expr(expr).derived {
	case ^ast.Ident:
		return "", e.name
	case ^ast.Selector_Expr:
		if id, ok := e.expr.derived.(^ast.Ident); ok && e.field != nil {
			return id.name, e.field.name
		}
	}
	return
}

@(private = "file")
_last_path_segment :: proc(raw: string) -> string {
	s := raw
	if colon := strings.last_index_byte(s, ':'); colon >= 0 {
		s = s[colon + 1:]
	}
	s = strings.trim_right(s, "/")
	if slash := strings.last_index_byte(s, '/'); slash >= 0 {
		s = s[slash + 1:]
	}
	return s
}

// Import alias of obench in `file_path`, or "".
@(private = "file")
_obench_alias :: proc(ws: ^Workspace, pkg_id: int, file_path: string) -> string {
	if flist, found := ws.packages[pkg_id].file_imports[file_path]; found {
		for &imp in flist {
			if _last_path_segment(imp.raw_path) == "obench" {
				return imp.alias
			}
		}
	}
	return ""
}

@(private = "file")
_Bench_Names :: struct {
	qual:   string,
	in_pkg: bool,
	found:  bool,
}

@(private = "file")
_is_obench_ref :: proc(qual: string, obench_qual: string, in_obench_pkg: bool) -> bool {
	return (qual != "" && qual == obench_qual) || (qual == "" && in_obench_pkg)
}

@(private = "file")
_is_step_cond :: proc(cond: ^ast.Expr, obench_qual: string, in_obench_pkg: bool) -> bool {
	if cond == nil {
		return false
	}
	call, is_call := ast.unparen_expr(cond).derived.(^ast.Call_Expr)
	if !is_call {
		return false
	}
	qual, name := call_target(call.expr)
	return(
		(name == "step" || name == "parallel_next") &&
		_is_obench_ref(qual, obench_qual, in_obench_pkg) \
	)
}

// Reports whether `body` measures something with obench (`for obench.step(b)`,
// `obench.iter_batched`, or `obench.run_parallel`).
@(private = "file")
_contains_bench_region :: proc(body: ^ast.Stmt, obench_qual: string, in_obench_pkg: bool) -> bool {
	if body == nil || (obench_qual == "" && !in_obench_pkg) {
		return false
	}
	state := _Bench_Names {
		qual   = obench_qual,
		in_pkg = in_obench_pkg,
	}
	v := ast.Visitor {
		data = &state,
		visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			st := (^_Bench_Names)(v.data)
			if node == nil || st.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.For_Stmt:
				if _is_step_cond(n.cond, st.qual, st.in_pkg) {
					st.found = true
					return nil
				}
			case ^ast.Call_Expr:
				qual, name := call_target(n.expr)
				switch name {
				case "iter_batched", "iter_with_large_drop", "run_parallel":
					if _is_obench_ref(qual, st.qual, st.in_pkg) {
						st.found = true
						return nil
					}
				}
			}
			return v
		},
	}
	ast.walk(&v, body)
	return state.found
}

// Mode of an allocator returned by a call such as `mem.arena_allocator(&a)`.
@(private = "file")
_allocator_ctor_mode :: proc(name: string) -> (mode: Call_Alloc_Mode, ok: bool) {
	if !strings.contains(name, "allocator") {
		return .None, false
	}
	switch {
	case strings.contains(name, "heap_allocator"),
	     strings.contains(name, "default_allocator"),
	     strings.contains(name, "tracking_allocator"),
	     strings.contains(name, "counting_allocator"),
	     strings.contains(name, "mutex_allocator"):
		// The heap, or a wrapper that forwards to its backing allocator.
		return .Heap, true
	}
	return .Custom, true
}

@(private = "file")
_expr_to_alloc_mode :: proc(s: ^_Scan, expr: ^ast.Expr) -> (mode: Call_Alloc_Mode, ok: bool) {
	if expr == nil {
		return .None, false
	}
	pr := &s.ws.procs[s.proc_id]
	#partial switch e in ast.unparen_expr(expr).derived {
	case ^ast.Ident:
		if pr.alloc_param_name != "" && e.name == pr.alloc_param_name {
			return .Caller_Param, true
		}
		if m, found := s.alloc_vars[e.name]; found {
			return m, true
		}
		if strings.has_suffix(e.name, "allocator") || strings.has_suffix(e.name, "alloc") {
			return .Custom, true
		}
	case ^ast.Selector_Expr:
		if is_context_expr(e.expr) && e.field != nil {
			switch e.field.name {
			case "allocator":
				return s.ctx_heap, true
			case "temp_allocator":
				return s.ctx_temp, true
			}
		}
		if e.field != nil &&
		   (e.field.name == "allocator" || strings.has_suffix(e.field.name, "_allocator")) {
			return .Custom, true
		}
	case ^ast.Call_Expr:
		_, name := call_target(e.expr)
		return _allocator_ctor_mode(name)
	}
	return .None, false
}

// Allocator a call passes: an `allocator =` argument, the argument at `alloc_param_idx`, or
// (for known `core:` procedures, `alloc_param_idx < 0`) a trailing argument that is clearly an
// allocator. Falls back to `default_mode` resolved through the current context.
@(private = "file")
_call_alloc_arg :: proc(
	s: ^_Scan,
	call: ^ast.Call_Expr,
	default_mode: Call_Alloc_Mode,
	alloc_param_idx := -1,
) -> Call_Alloc_Mode {
	for arg in call.args {
		if fv, is_fv := arg.derived.(^ast.Field_Value); is_fv {
			if id, is_id := fv.field.derived.(^ast.Ident); is_id {
				if id.name == "allocator" || id.name == "alloc" {
					if m, ok := _expr_to_alloc_mode(s, fv.value); ok {
						return m
					}
					return .Custom
				}
			}
		}
	}
	if alloc_param_idx >= 0 {
		if alloc_param_idx < len(call.args) {
			arg := call.args[alloc_param_idx]
			if _, is_fv := arg.derived.(^ast.Field_Value); !is_fv {
				if m, ok := _expr_to_alloc_mode(s, arg); ok {
					return m
				}
				return .Custom
			}
		}
	} else {
		for i := len(call.args) - 1; i >= 0; i -= 1 {
			arg := call.args[i]
			if _, is_fv := arg.derived.(^ast.Field_Value); is_fv {
				continue
			}
			if m, ok := _expr_to_alloc_mode(s, arg); ok {
				return m
			}
		}
	}
	switch default_mode {
	case .Heap:
		return s.ctx_heap
	case .Temp:
		return s.ctx_temp
	case .None, .Caller_Param, .Custom:
	}
	return default_mode
}

/*
Classifies whether a built-in or `core:` procedure allocates by default, and whether ignoring
its result leaks memory. `pkg_part` is the import alias, which matches the package name for
the usual `import "core:fmt"` style imports.
*/
@(require_results)
classify_known_callee :: proc(
	pkg_part: string,
	proc_name: string,
) -> (
	default_mode: Call_Alloc_Mode,
	must_use_result: bool,
	reason: string,
) {
	if pkg_part == "" {
		switch proc_name {
		case "make",
		     "make_slice",
		     "make_dynamic_array",
		     "make_dynamic_array_len",
		     "make_dynamic_array_len_cap",
		     "make_map",
		     "make_map_cap",
		     "make_multi_pointer",
		     "make_soa",
		     "make_soa_slice",
		     "make_soa_dynamic_array":
			return .Heap, true, "heap allocation via make"
		case "new", "new_clone":
			return .Heap, true, "heap allocation via new"
		case "append",
		     "append_elem",
		     "append_elems",
		     "append_string",
		     "append_nothing",
		     "append_soa",
		     "reserve",
		     "resize",
		     "inject_at",
		     "assign_at",
		     "non_zero_append",
		     "non_zero_resize",
		     "non_zero_reserve",
		     "map_insert",
		     "map_upsert",
		     "map_entry":
			return .Heap, false, "dynamic container growth"
		}
		return .None, false, ""
	}

	switch pkg_part {
	case "fmt":
		switch proc_name {
		case "aprint",
		     "aprintln",
		     "aprintf",
		     "aprintfln",
		     "caprint",
		     "caprintln",
		     "caprintf",
		     "caprintfln":
			return .Heap, true, "heap string formatting"
		case "tprint",
		     "tprintln",
		     "tprintf",
		     "tprintfln",
		     "ctprint",
		     "ctprintln",
		     "ctprintf",
		     "ctprintfln":
			return .Temp, false, "temp_allocator string formatting"
		}
	case "strings":
		switch proc_name {
		case "clone",
		     "clone_from",
		     "clone_from_bytes",
		     "clone_from_cstring",
		     "clone_from_ptr",
		     "clone_to_cstring",
		     "clone_safe",
		     "concatenate",
		     "join",
		     "split",
		     "split_n",
		     "split_after",
		     "split_after_n",
		     "split_lines",
		     "split_lines_n",
		     "split_lines_after",
		     "split_multi",
		     "fields",
		     "fields_proc",
		     "replace",
		     "replace_all",
		     "remove",
		     "remove_all",
		     "repeat",
		     "to_lower",
		     "to_upper",
		     "to_camel_case",
		     "to_pascal_case",
		     "to_snake_case",
		     "to_kebab_case",
		     "to_upper_snake_case",
		     "to_ada_case",
		     "expand_tabs",
		     "centre_justify",
		     "left_justify",
		     "right_justify",
		     "builder_make",
		     "builder_make_none",
		     "builder_make_len",
		     "builder_make_len_cap",
		     "intern_get":
			return .Heap, true, "strings allocation"
		}
	case "bytes":
		switch proc_name {
		case "clone",
		     "concatenate",
		     "join",
		     "split",
		     "split_n",
		     "split_after",
		     "fields",
		     "replace",
		     "replace_all",
		     "remove",
		     "remove_all",
		     "repeat",
		     "to_lower",
		     "to_upper":
			return .Heap, true, "bytes allocation"
		}
	case "slice":
		switch proc_name {
		case "clone",
		     "clone_to_dynamic",
		     "to_dynamic",
		     "concatenate",
		     "mapper",
		     "filter",
		     "map_keys",
		     "map_values",
		     "map_entries",
		     "map_entry_infos",
		     "unique_proc",
		     "reduce_reverse":
			return .Heap, true, "slice allocation"
		}
	case "mem":
		switch proc_name {
		case "alloc",
		     "alloc_bytes",
		     "alloc_bytes_non_zeroed",
		     "new",
		     "new_aligned",
		     "new_clone",
		     "make",
		     "make_slice",
		     "make_dynamic_array",
		     "make_dynamic_array_len",
		     "make_dynamic_array_len_cap",
		     "make_map",
		     "make_multi_pointer",
		     "make_aligned":
			return .Heap, true, "mem allocation"
		case "resize", "resize_bytes", "default_resize_align", "default_resize_bytes_align":
			return .Heap, false, "mem resize"
		}
	case "runtime":
		switch proc_name {
		case "mem_alloc", "mem_alloc_bytes", "mem_alloc_non_zeroed", "new_aligned", "make_aligned":
			return .Heap, true, "runtime allocation"
		case "mem_resize":
			return .Heap, false, "runtime resize"
		}
	case "os":
		switch proc_name {
		case "read_entire_file",
		     "read_entire_file_from_path",
		     "read_entire_file_from_file",
		     "get_env",
		     "get_absolute_path",
		     "read_all_directory_by_path",
		     "read_directory_by_path",
		     "make_directory_temp",
		     "get_working_directory",
		     "get_executable_path",
		     "get_executable_directory",
		     "environ",
		     "process_exec":
			return .Heap, false, "os allocation"
		}
	case "filepath", "slashpath", "path":
		switch proc_name {
		case "join", "clean", "glob", "rel", "abs", "split_list", "from_slash", "to_slash":
			return .Heap, false, "path allocation"
		}
	case "json", "cbor", "xml", "csv", "ini", "hxa":
		switch proc_name {
		case "marshal",
		     "unmarshal",
		     "unmarshal_string",
		     "parse",
		     "parse_string",
		     "encode",
		     "decode",
		     "decode_from_string",
		     "load_from_file",
		     "load_from_bytes",
		     "read_all",
		     "clone_value":
			return .Heap, false, "encoding allocation"
		}
	case "image", "png", "jpeg", "qoi", "bmp", "tga", "netpbm":
		switch proc_name {
		case "load_from_bytes", "load_from_file", "save_to_buffer":
			return .Heap, false, "image allocation"
		}
	case "gzip", "zlib":
		switch proc_name {
		case "load_from_bytes", "load_from_file", "inflate", "inflate_from_byte_array":
			return .Heap, false, "compression allocation"
		}
	case "queue", "priority_queue":
		switch proc_name {
		case "init", "push", "push_back", "push_front", "push_back_elems", "reserve", "resize":
			return .Heap, false, "container allocation"
		}
	case "thread":
		switch proc_name {
		case "create",
		     "create_and_start",
		     "create_and_start_with_data",
		     "create_and_start_with_poly_data",
		     "create_and_start_with_poly_data2",
		     "create_and_start_with_poly_data3",
		     "create_and_start_with_poly_data4":
			return .Heap, false, "thread allocation"
		}
	case "parser":
		switch proc_name {
		case "parse_package_from_path", "collect_package", "parse_file", "parse_file_tags":
			return .Heap, false, "parser AST allocation"
		}
	}
	return .None, false, ""
}

@(private = "file")
_container_root_ident :: proc(expr: ^ast.Expr) -> string {
	curr := ast.unparen_expr(expr)
	for curr != nil {
		#partial switch e in curr.derived {
		case ^ast.Unary_Expr:
			curr = ast.unparen_expr(e.expr)
		case ^ast.Deref_Expr:
			curr = ast.unparen_expr(e.expr)
		case ^ast.Ident:
			return e.name
		case ^ast.Selector_Expr:
			if e.field != nil {
				return e.field.name
			}
			return ""
		case:
			return ""
		}
	}
	return ""
}

@(private = "file")
_is_temp_allocator_arg :: proc(call: ^ast.Call_Expr) -> bool {
	if len(call.args) == 0 {
		return false
	}
	sel, ok := ast.unparen_expr(call.args[0]).derived.(^ast.Selector_Expr)
	return(
		ok &&
		is_context_expr(sel.expr) &&
		sel.field != nil &&
		sel.field.name == "temp_allocator" \
	)
}

@(private = "file")
_site :: proc(
	s: ^_Scan,
	mode: Call_Alloc_Mode,
	fresh: bool,
	callee_name: string,
	reason: string,
	pos: ast.Node,
) {
	if mode == .None || mode == .Custom {
		return
	}
	if s.has_bench_region && !s.in_bench_region {
		return
	}
	alloc := s.cg.allocator
	pr := &s.ws.procs[s.proc_id]
	append(
		&s.cg.summaries[s.proc_id].direct_sites,
		Direct_Alloc_Site {
			mode = mode,
			fresh = fresh,
			in_loop = s.current_loop_id >= 0,
			loop_id = s.current_loop_id,
			callee_name = strings.clone(callee_name, alloc),
			reason = strings.clone(reason, alloc),
			location = Location {
				file_path = strings.clone(pr.file_path, alloc),
				line = pos.pos.line,
				column = pos.pos.column,
			},
		},
	)
}

@(private = "file")
_edge :: proc(s: ^_Scan, callee_id: int, arg_mode: Call_Alloc_Mode, pos: ast.Node) {
	if s.has_bench_region && !s.in_bench_region {
		return
	}
	alloc := s.cg.allocator
	pr := &s.ws.procs[s.proc_id]
	append(
		&s.cg.summaries[s.proc_id].callees,
		Call_Edge {
			caller_id = s.proc_id,
			callee_id = callee_id,
			arg_mode = arg_mode,
			ctx_heap = s.ctx_heap,
			ctx_temp = s.ctx_temp,
			in_loop = s.current_loop_id >= 0,
			loop_id = s.current_loop_id,
			location = Location {
				file_path = strings.clone(pr.file_path, alloc),
				line = pos.pos.line,
				column = pos.pos.column,
			},
		},
	)
}

@(private = "file")
_alloc_default_to_mode :: proc "contextless" (d: Alloc_Param_Default) -> Call_Alloc_Mode {
	switch d {
	case .Heap:
		return .Heap
	case .Temp:
		return .Temp
	case .Custom:
		return .Custom
	case .None:
	}
	return .None
}

@(private = "file")
_edge_to_proc :: proc(s: ^_Scan, callee_id: int, call: ^ast.Call_Expr) {
	callee := &s.ws.procs[callee_id]
	// `max(int)` when the callee has no allocator parameter: never guess from trailing arguments.
	arg_mode := _call_alloc_arg(
		s,
		call,
		_alloc_default_to_mode(callee.alloc_param_default),
		callee.alloc_param_index if callee.alloc_param_index >= 0 else max(int),
	)
	_edge(s, callee_id, arg_mode, call.node)
}

// Runs a procedure literal's body as part of the current procedure: comparators, iterators and
// other callbacks run on behalf of the caller, with the caller's context.
@(private = "file")
_scan_inline_lit :: proc(s: ^_Scan, lit: ^ast.Proc_Lit) {
	if lit == nil || lit.body == nil {
		return
	}
	saved_heap, saved_temp, saved_defer := s.ctx_heap, s.ctx_temp, s.in_defer
	s.in_defer = false
	s.block_depth += 1 // Guards inside the literal end with the literal
	_scan_stmt(s, lit.body)
	s.block_depth -= 1
	s.ctx_heap, s.ctx_temp, s.in_defer = saved_heap, saved_temp, saved_defer
}

// Argument `name` (or positional argument `index`) of `call`.
@(private = "file")
_call_arg :: proc(call: ^ast.Call_Expr, name: string, index: int) -> ^ast.Expr {
	for arg in call.args {
		if fv, is_fv := arg.derived.(^ast.Field_Value); is_fv {
			if id, ok := fv.field.derived.(^ast.Ident); ok && id.name == name {
				return fv.value
			}
		}
	}
	if index < len(call.args) {
		if _, is_fv := call.args[index].derived.(^ast.Field_Value); !is_fv {
			return call.args[index]
		}
	}
	return nil
}

// Scans the routine an obench call measures (the `routine` of `iter_batched` or
// `iter_with_large_drop`, or `run_parallel`'s worker) as part of the benchmark.
@(private = "file")
_scan_measured_callback :: proc(s: ^_Scan, call: ^ast.Call_Expr, cb: ^ast.Expr, in_region: bool) {
	if cb == nil {
		return
	}
	prev := s.in_bench_region
	s.in_bench_region = in_region
	defer s.in_bench_region = prev
	pr := &s.ws.procs[s.proc_id]
	#partial switch c in ast.unparen_expr(cb).derived {
	case ^ast.Proc_Lit:
		_scan_inline_lit(s, c)
	case ^ast.Ident, ^ast.Selector_Expr:
		qual, name := call_target(cb)
		callee_id, _ := resolve_proc_ref(s.ws, pr.pkg_id, pr.file_path, qual, name, s.proc_id)
		if callee_id >= 0 {
			_edge(s, callee_id, .None, call.node)
		}
	}
}

@(private = "file")
_scan_call :: proc(s: ^_Scan, call: ^ast.Call_Expr) {
	if call == nil || call.expr == nil {
		return
	}
	sum := &s.cg.summaries[s.proc_id]
	qual, name := call_target(call.expr)

	// Temp allocator guards and frees.
	is_guard := name == "DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD"
	is_free :=
		(name == "free_all" && _is_temp_allocator_arg(call)) ||
		name == "default_temp_allocator_temp_end"
	if is_guard || is_free {
		if s.current_loop_id >= 0 {
			sum.loops[s.current_loop_id].frees_temp = true
		} else if s.block_depth == 1 && (is_guard || s.in_defer) {
			sum.frees_temp_on_exit = true
		}
		return
	}

	if name == "" {
		if lit, is_lit := ast.unparen_expr(call.expr).derived.(^ast.Proc_Lit); is_lit {
			_scan_inline_lit(s, lit) // `proc() { ... }()`
		}
		for arg in call.args {
			_scan_expr(s, arg)
		}
		return
	}

	if _is_obench_ref(qual, s.obench_qual, s.in_obench_pkg) {
		switch name {
		case "iter_batched":
			// `setup` and `teardown` run outside the measurement.
			_scan_measured_callback(s, call, _call_arg(call, "routine", 2), true)
			return
		case "iter_with_large_drop":
			// `drop` runs outside the measurement.
			_scan_measured_callback(s, call, _call_arg(call, "routine", 1), true)
			return
		case "run_parallel":
			// Code in the worker before `for parallel_next(pb)` is per-thread setup.
			_scan_measured_callback(s, call, _call_arg(call, "body", 1), s.in_bench_region)
			return
		case "pause", "scoped_pause":
			// `scoped_pause` lasts until the end of its block, where `_scan_stmt` restores
			// the region.
			s.region_at_pause = s.in_bench_region
			s.in_bench_region = false
			return
		case "resume":
			s.in_bench_region = s.region_at_pause
			return
		case "step",
		     "parallel_next",
		     "param",
		     "threads",
		     "set_bytes",
		     "set_items",
		     "keep_alive",
		     "black_box",
		     "clobber_memory",
		     "report_metric",
		     "expect_zero_allocs":
			return
		}
	}

	for arg in call.args {
		value := arg
		if fv, is_fv := arg.derived.(^ast.Field_Value); is_fv {
			value = fv.value
		}
		if lit, is_lit := ast.unparen_expr(value).derived.(^ast.Proc_Lit); is_lit {
			_scan_inline_lit(s, lit)
		} else {
			_scan_expr(s, value)
		}
	}

	if qual == "" {
		switch name {
		case "append",
		     "append_elem",
		     "append_elems",
		     "append_string",
		     "append_soa",
		     "reserve",
		     "resize",
		     "inject_at",
		     "assign_at",
		     "non_zero_append",
		     "non_zero_resize",
		     "non_zero_reserve",
		     "map_insert",
		     "map_upsert",
		     "map_entry":
			mode := s.ctx_heap
			if len(call.args) > 0 {
				if cm, found := s.container_modes[_container_root_ident(call.args[0])]; found {
					mode = cm
				}
			}
			_site(s, mode, false, name, "dynamic container growth", call.node)
			return
		}
	}

	if def_mode, _, reason := classify_known_callee(qual, name); def_mode != .None {
		target := name
		if qual != "" {
			target = fmt.tprintf("%s.%s", qual, name)
		}
		_site(s, _call_alloc_arg(s, call, def_mode), true, target, reason, call.node)
		return
	}

	pr := &s.ws.procs[s.proc_id]
	callee_id, group_ids := resolve_proc_ref(s.ws, pr.pkg_id, pr.file_path, qual, name, s.proc_id)
	if callee_id >= 0 {
		_edge_to_proc(s, callee_id, call)
		return
	}
	for gid in group_ids {
		_edge_to_proc(s, gid, call)
	}
}

@(private = "file")
_scan_expr :: proc(s: ^_Scan, expr: ^ast.Expr) {
	if expr == nil {
		return
	}
	#partial switch e in expr.derived {
	case ^ast.Call_Expr:
		_scan_call(s, e)
	case ^ast.Selector_Call_Expr:
		_scan_expr(s, e.expr)
		_scan_call(s, e.call)
	case ^ast.Comp_Lit:
		if e.type != nil {
			#partial switch _ in e.type.derived {
			case ^ast.Map_Type:
				_site(s, s.ctx_heap, true, "map literal", "dynamic literal", e.node)
			case ^ast.Dynamic_Array_Type:
				_site(s, s.ctx_heap, true, "dynamic array literal", "dynamic literal", e.node)
			}
		}
		for el in e.elems {
			_scan_expr(s, el)
		}
	case ^ast.Unary_Expr:
		_scan_expr(s, e.expr)
	case ^ast.Binary_Expr:
		_scan_expr(s, e.left)
		_scan_expr(s, e.right)
	case ^ast.Paren_Expr:
		_scan_expr(s, e.expr)
	case ^ast.Deref_Expr:
		_scan_expr(s, e.expr)
	case ^ast.Index_Expr:
		_scan_expr(s, e.expr)
		_scan_expr(s, e.index)
	case ^ast.Slice_Expr:
		_scan_expr(s, e.expr)
		_scan_expr(s, e.low)
		_scan_expr(s, e.high)
	case ^ast.Ternary_If_Expr:
		_scan_expr(s, e.x)
		_scan_expr(s, e.cond)
		_scan_expr(s, e.y)
	case ^ast.Ternary_When_Expr:
		_scan_expr(s, e.x)
		_scan_expr(s, e.cond)
		_scan_expr(s, e.y)
	case ^ast.Or_Else_Expr:
		_scan_expr(s, e.x)
		_scan_expr(s, e.y)
	case ^ast.Or_Return_Expr:
		_scan_expr(s, e.expr)
	case ^ast.Or_Branch_Expr:
		_scan_expr(s, e.expr)
	case ^ast.Field_Value:
		_scan_expr(s, e.value)
	case ^ast.Type_Cast:
		_scan_expr(s, e.expr)
	case ^ast.Auto_Cast:
		_scan_expr(s, e.expr)
	case ^ast.Type_Assertion:
		_scan_expr(s, e.expr)
	}
}

/*
Reports whether `expr` evaluates to memory from `context.temp_allocator`: a local assigned
such memory, a known `core:` procedure called with the temp allocator, or a workspace procedure
whose allocator parameter receives the temp allocator.
*/
@(require_results)
expr_allocates_on_temp :: proc(
	ws: ^Workspace,
	cg: ^Call_Graph,
	proc_id: int,
	expr: ^ast.Expr,
) -> bool {
	if expr == nil {
		return false
	}
	sum := &cg.summaries[proc_id]
	#partial switch e in ast.strip_or_return_expr(expr).derived {
	case ^ast.Ident:
		for tv in sum.temp_vars {
			if tv == e.name {
				return true
			}
		}
	case ^ast.Call_Expr:
		s := _Scan {
			ws       = ws,
			cg       = cg,
			proc_id  = proc_id,
			ctx_heap = .Heap,
			ctx_temp = .Temp,
		}
		qual, name := call_target(e.expr)
		if def_mode, _, _ := classify_known_callee(qual, name); def_mode != .None {
			return _call_alloc_arg(&s, e, def_mode) == .Temp
		}
		pr := &ws.procs[proc_id]
		callee_id, _ := resolve_proc_ref(ws, pr.pkg_id, pr.file_path, qual, name, proc_id)
		if callee_id >= 0 && has_taint(cg.summaries[callee_id].taints, .Caller_Param) {
			callee := &ws.procs[callee_id]
			arg := _call_alloc_arg(
				&s,
				e,
				_alloc_default_to_mode(callee.alloc_param_default),
				callee.alloc_param_index if callee.alloc_param_index >= 0 else max(int),
			)
			return arg == .Temp
		}
	}
	return false
}

@(private = "file")
_is_map_type_expr :: proc(ws: ^Workspace, pkg_id: int, type_expr: ^ast.Expr, depth := 0) -> bool {
	if type_expr == nil || depth > 6 {
		return false
	}
	#partial switch t in type_expr.derived {
	case ^ast.Map_Type:
		return true
	case ^ast.Pointer_Type:
		return _is_map_type_expr(ws, pkg_id, t.elem, depth + 1)
	case ^ast.Distinct_Type:
		return _is_map_type_expr(ws, pkg_id, t.type, depth + 1)
	case ^ast.Ident, ^ast.Selector_Expr:
		qual, name := call_target(type_expr)
		if tid := lookup_type(ws, pkg_id, qual, name); tid >= 0 {
			info := &ws.types[tid]
			return _is_map_type_expr(ws, info.pkg_id, info.type_expr, depth + 1)
		}
	}
	return false
}

@(private = "file")
_is_fixed_capacity_type :: proc(ws: ^Workspace, pkg_id: int, type_expr: ^ast.Expr) -> bool {
	if type_expr == nil {
		return false
	}
	#partial switch t in type_expr.derived {
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		return true
	case ^ast.Ident, ^ast.Selector_Expr:
		qual, name := call_target(type_expr)
		if tid := lookup_type(ws, pkg_id, qual, name); tid >= 0 {
			_, is_fixed := ws.types[tid].type_expr.derived.(^ast.Fixed_Capacity_Dynamic_Array_Type)
			return is_fixed
		}
	}
	return false
}

@(private = "file")
_track_assignment :: proc(s: ^_Scan, lhs: []^ast.Expr, rhs: []^ast.Expr) {
	if len(lhs) == 0 || len(rhs) == 0 {
		return
	}
	pkg_id := s.ws.procs[s.proc_id].pkg_id

	// `m[key] = value` on a map inserts and may grow it.
	for l in lhs {
		if l == nil {
			continue
		}
		if idx, is_idx := ast.unparen_expr(l).derived.(^ast.Index_Expr); is_idx {
			m_name := _container_root_ident(idx.expr)
			if m_name != "" && s.map_vars[m_name] {
				mode := s.ctx_heap
				if cm, found := s.container_modes[m_name]; found {
					mode = cm
				}
				_site(s, mode, false, "map[key] = value", "map insertion", idx.node)
			}
		}
	}

	if len(lhs) != 1 || len(rhs) != 1 || lhs[0] == nil || rhs[0] == nil {
		return
	}

	// `context.allocator = X`, `context.temp_allocator = X`, `arr.allocator = X`.
	if sel, is_sel := lhs[0].derived.(^ast.Selector_Expr); is_sel && sel.field != nil {
		m, ok := _expr_to_alloc_mode(s, rhs[0])
		if !ok {
			m = .Custom
		}
		if is_context_expr(sel.expr) {
			switch sel.field.name {
			case "allocator":
				s.ctx_heap = m
			case "temp_allocator":
				s.ctx_temp = m
			}
			return
		}
		if id, is_id := sel.expr.derived.(^ast.Ident); is_id && sel.field.name == "allocator" {
			s.container_modes[id.name] = m
		}
		return
	}

	id, is_id := lhs[0].derived.(^ast.Ident)
	if !is_id || id.name == "_" {
		return
	}
	rhs0 := ast.strip_or_return_expr(rhs[0])

	// Locals holding an allocator: `a := mem.arena_allocator(&arena)`, `a := context.allocator`.
	#partial switch r in rhs0.derived {
	case ^ast.Selector_Expr, ^ast.Ident:
		if m, ok := _expr_to_alloc_mode(s, rhs0); ok {
			s.alloc_vars[id.name] = m
		}
		return
	case ^ast.Call_Expr:
		_, name := call_target(r.expr)
		if m, ok := _allocator_ctor_mode(name); ok {
			s.alloc_vars[id.name] = m
			return
		}
		if name == "make" || strings.has_prefix(name, "make_") {
			mode := _call_alloc_arg(s, r, .Heap)
			s.container_modes[id.name] = mode
			if name == "make_map" ||
			   name == "make_map_cap" ||
			   (len(r.args) > 0 && _is_map_type_expr(s.ws, pkg_id, r.args[0])) {
				s.map_vars[id.name] = true
			}
			if mode == .Temp {
				append(
					&s.cg.summaries[s.proc_id].temp_vars,
					strings.clone(id.name, s.cg.allocator),
				)
			}
			return
		}
		if expr_allocates_on_temp(s.ws, s.cg, s.proc_id, rhs0) {
			append(&s.cg.summaries[s.proc_id].temp_vars, strings.clone(id.name, s.cg.allocator))
		}
	case ^ast.Comp_Lit:
		if r.type != nil && _is_map_type_expr(s.ws, pkg_id, r.type) {
			s.map_vars[id.name] = true
		}
	}
}

@(private = "file")
_scan_stmt :: proc(s: ^_Scan, stmt: ^ast.Stmt) {
	if stmt == nil {
		return
	}
	#partial switch st in stmt.derived {
	case ^ast.Block_Stmt:
		saved_heap, saved_temp, saved_loop := s.ctx_heap, s.ctx_temp, s.current_loop_id
		saved_region := s.in_bench_region
		defer s.in_bench_region = saved_region
		// A block that ends in `return` runs at most once per call, even inside a loop.
		if len(st.stmts) > 0 {
			if _, returns := st.stmts[len(st.stmts) - 1].derived.(^ast.Return_Stmt); returns {
				s.current_loop_id = -1
			}
		}
		s.block_depth += 1
		for child in st.stmts {
			_scan_stmt(s, child)
		}
		s.block_depth -= 1
		s.ctx_heap, s.ctx_temp, s.current_loop_id = saved_heap, saved_temp, saved_loop

	case ^ast.Expr_Stmt:
		_scan_expr(s, st.expr)

	case ^ast.Assign_Stmt:
		for r in st.rhs {
			_scan_expr(s, r)
		}
		for l in st.lhs {
			_scan_expr(s, l)
		}
		_track_assignment(s, st.lhs, st.rhs)

	case ^ast.Value_Decl:
		if len(st.values) > 0 {
			if _, is_proc := st.values[0].derived.(^ast.Proc_Lit); is_proc {
				return // Constant procedures are call-graph nodes of their own
			}
		}
		pkg_id := s.ws.procs[s.proc_id].pkg_id
		if st.type != nil {
			for n in st.names {
				id, ok := n.derived.(^ast.Ident)
				if !ok || id.name == "_" {
					continue
				}
				if _is_map_type_expr(s.ws, pkg_id, st.type) {
					s.map_vars[id.name] = true
				}
				if _is_fixed_capacity_type(s.ws, pkg_id, st.type) {
					s.container_modes[id.name] = .None
				}
			}
		}
		for v in st.values {
			_scan_expr(s, v)
		}
		_track_assignment(s, st.names, st.values)

	case ^ast.Return_Stmt:
		for r in st.results {
			_scan_expr(s, r)
		}

	case ^ast.Defer_Stmt:
		prev := s.in_defer
		s.in_defer = true
		if blk, is_blk := st.stmt.derived.(^ast.Block_Stmt); is_blk {
			for child in blk.stmts {
				_scan_stmt(s, child) // A deferred block runs at the enclosing scope's exit
			}
		} else {
			_scan_stmt(s, st.stmt)
		}
		s.in_defer = prev

	case ^ast.If_Stmt:
		_scan_stmt(s, st.init)
		_scan_expr(s, st.cond)
		_scan_stmt(s, st.body)
		_scan_stmt(s, st.else_stmt)

	case ^ast.When_Stmt:
		_scan_expr(s, st.cond)
		_scan_stmt(s, st.body)
		_scan_stmt(s, st.else_stmt)

	case ^ast.Switch_Stmt:
		_scan_stmt(s, st.init)
		_scan_expr(s, st.cond)
		_scan_stmt(s, st.body)

	case ^ast.Type_Switch_Stmt:
		_scan_stmt(s, st.tag)
		_scan_expr(s, st.expr)
		_scan_stmt(s, st.body)

	case ^ast.Case_Clause:
		for e in st.list {
			_scan_expr(s, e)
		}
		for child in st.body {
			_scan_stmt(s, child)
		}

	case ^ast.Tag_Stmt:
		_scan_stmt(s, st.stmt)

	case ^ast.For_Stmt:
		is_step := _is_step_cond(st.cond, s.obench_qual, s.in_obench_pkg)
		prev_bench := s.in_bench_region
		if is_step {
			s.in_bench_region = true
		}
		_scan_loop(
			s,
			st.init,
			st.cond,
			st.post,
			st.body,
			st.node,
			st.init == nil && st.post == nil && !is_step,
		)
		s.in_bench_region = prev_bench

	case ^ast.Range_Stmt:
		_scan_stmt(s, st.init)
		_scan_expr(s, st.expr)
		_scan_loop(s, nil, nil, nil, st.body, st.node, false)

	case ^ast.Inline_Range_Stmt:
		_scan_expr(s, st.expr)
		_scan_loop(s, nil, nil, nil, st.body, st.node, false)
	}
}

@(private = "file")
_scan_loop :: proc(
	s: ^_Scan,
	init: ^ast.Stmt,
	cond: ^ast.Expr,
	post: ^ast.Stmt,
	body: ^ast.Stmt,
	loop_node: ast.Node,
	is_unbounded: bool,
) {
	_scan_stmt(s, init)

	sum := &s.cg.summaries[s.proc_id]
	pr := &s.ws.procs[s.proc_id]
	loop_id := len(sum.loops)
	append(
		&sum.loops,
		Loop_Summary {
			id = loop_id,
			parent_id = s.current_loop_id,
			proc_id = s.proc_id,
			is_unbounded = is_unbounded,
			location = Location {
				file_path = strings.clone(pr.file_path, s.cg.allocator),
				line = loop_node.pos.line,
				column = loop_node.pos.column,
			},
		},
	)

	prev_loop := s.current_loop_id
	s.current_loop_id = loop_id
	_scan_expr(s, cond) // The condition runs on every iteration
	_scan_stmt(s, body)
	_scan_stmt(s, post)
	s.current_loop_id = prev_loop
}

@(private = "file")
_analyze_proc_body :: proc(ws: ^Workspace, cg: ^Call_Graph, proc_id: int) {
	pr := &ws.procs[proc_id]
	if pr.lit == nil || pr.lit.body == nil || pr.annotations.alloc_safe {
		return
	}

	obench_qual := _obench_alias(ws, pr.pkg_id, pr.file_path)
	in_obench_pkg := ws.packages[pr.pkg_id].name == "obench"
	has_bench := _contains_bench_region(pr.lit.body, obench_qual, in_obench_pkg)

	s := _Scan {
		ws               = ws,
		cg               = cg,
		proc_id          = proc_id,
		current_loop_id  = -1,
		has_bench_region = has_bench,
		in_bench_region  = !has_bench,
		obench_qual      = obench_qual,
		in_obench_pkg    = in_obench_pkg,
		ctx_heap         = .Heap,
		ctx_temp         = .Temp,
		alloc_vars       = make(map[string]Call_Alloc_Mode, context.temp_allocator),
		container_modes  = make(map[string]Call_Alloc_Mode, context.temp_allocator),
		map_vars         = make(map[string]bool, context.temp_allocator),
	}
	for &pm in pr.params {
		if pm.name != "" && _is_map_type_expr(ws, pr.pkg_id, pm.type_expr) {
			s.map_vars[pm.name] = true
		}
	}
	_scan_stmt(&s, pr.lit.body)
}

// Taints a procedure has from its own body and annotations.
@(private = "file")
_own_taints :: proc(ws: ^Workspace, cg: ^Call_Graph, proc_id: int) -> (t: Taints) {
	pr := &ws.procs[proc_id]
	if pr.annotations.alloc_safe {
		return {}
	}
	if pr.annotations.allocates_heap {
		t += {.Heap, .Heap_Fresh}
	}
	if pr.annotations.allocates_temp {
		t += {.Temp, .Temp_Fresh}
	}
	sum := &cg.summaries[proc_id]
	for &site in sum.direct_sites {
		t += _taint_of(site.mode, site_is_fresh(sum, site))
	}
	return
}

// Taints that flow to the caller of `edge` from a callee with `callee_taints`.
@(private = "file")
_taints_through_edge :: proc(
	sum: ^Proc_Summary,
	#by_ptr edge: Call_Edge,
	callee_taints: Taints,
) -> (
	t: Taints,
) {
	in_freeing_loop := edge.in_loop && _loop_chain_frees_temp(sum, edge.loop_id)
	for mode in ([3]Call_Alloc_Mode{.Heap, .Temp, .Caller_Param}) {
		if !has_taint(callee_taints, mode) {
			continue
		}
		mapped := map_through_edge(edge, mode)
		fresh := has_taint(callee_taints, mode, true)
		if mapped == .Temp && in_freeing_loop {
			fresh = false
		}
		t += _taint_of(mapped, fresh)
	}
	return
}

// Propagates taints from callees to callers until nothing changes, visiting only callers of
// procedures whose taints changed.
@(private = "file")
_propagate :: proc(ws: ^Workspace, cg: ^Call_Graph) {
	n := len(ws.procs)
	Ref :: struct {
		caller:   int,
		edge_idx: int,
	}
	callers := make([][dynamic]Ref, n, context.temp_allocator)
	for i in 0 ..< n {
		callers[i] = make([dynamic]Ref, context.temp_allocator)
	}
	for i in 0 ..< n {
		for &e, idx in cg.summaries[i].callees {
			append(&callers[e.callee_id], Ref{i, idx})
		}
	}

	queue := make([dynamic]int, 0, n, context.temp_allocator)
	queued := make([]bool, n, context.temp_allocator)
	for i in 0 ..< n {
		cg.summaries[i].taints = _own_taints(ws, cg, i)
		if cg.summaries[i].taints != {} {
			append(&queue, i)
			queued[i] = true
		}
	}

	for head := 0; head < len(queue); head += 1 {
		callee := queue[head]
		queued[callee] = false
		callee_taints := cg.summaries[callee].taints
		for ref in callers[callee] {
			if ws.procs[ref.caller].annotations.alloc_safe {
				continue
			}
			caller_sum := &cg.summaries[ref.caller]
			added := _taints_through_edge(
				caller_sum,
				caller_sum.callees[ref.edge_idx],
				callee_taints,
			)
			if added - caller_sum.taints != {} {
				caller_sum.taints += added
				if !queued[ref.caller] {
					append(&queue, ref.caller)
					queued[ref.caller] = true
				}
			}
		}
	}
}

/*
Returns the callee mode through which `edge` brings a fresh temp allocation into the caller,
or `.None`.
*/
@(require_results)
edge_brings_fresh_temp :: proc(
	ws: ^Workspace,
	cg: ^Call_Graph,
	#by_ptr edge: Call_Edge,
) -> Call_Alloc_Mode {
	if ws.procs[edge.callee_id].annotations.alloc_safe {
		return .None
	}
	callee_taints := cg.summaries[edge.callee_id].taints
	for mode in ([3]Call_Alloc_Mode{.Heap, .Temp, .Caller_Param}) {
		if map_through_edge(edge, mode) == .Temp && has_taint(callee_taints, mode, true) {
			return mode
		}
	}
	return .None
}

/*
Finds the shortest witness chain from `start_proc_id` to a direct allocation in `initial_mode`
(`.Heap` or `.Temp`, as seen by `start_proc_id`), using breadth-first search over
(procedure, mode) states. With `fresh_only`, container growth and temp allocations in
self-freeing loops don't count.
*/
@(require_results)
find_shortest_alloc_chain :: proc(
	ws: ^Workspace,
	cg: ^Call_Graph,
	start_proc_id: int,
	initial_mode: Call_Alloc_Mode,
	allocator := context.temp_allocator,
	fresh_only := false,
) -> (
	chain: [dynamic]Chain_Step,
	found: bool,
) {
	chain = make([dynamic]Chain_Step, allocator)

	State :: struct {
		proc_id: int,
		mode:    Call_Alloc_Mode,
	}
	Queue_Item :: struct {
		state:  State,
		parent: int,
		edge:   ^Call_Edge,
	}

	queue := make([dynamic]Queue_Item, context.temp_allocator)
	visited := make(map[State]bool, context.temp_allocator)

	push :: proc(queue: ^[dynamic]Queue_Item, visited: ^map[State]bool, item: Queue_Item) {
		if !visited[item.state] {
			visited[item.state] = true
			append(queue, item)
		}
	}

	start := &ws.procs[start_proc_id]
	push(&queue, &visited, Queue_Item{state = {start_proc_id, initial_mode}, parent = -1})
	if _alloc_default_to_mode(start.alloc_param_default) == initial_mode {
		push(&queue, &visited, Queue_Item{state = {start_proc_id, .Caller_Param}, parent = -1})
	}

	for head := 0; head < len(queue); head += 1 {
		curr := queue[head]
		sum := &cg.summaries[curr.state.proc_id]
		pr := &ws.procs[curr.state.proc_id]

		for &site in sum.direct_sites {
			if site.mode != curr.state.mode || (fresh_only && !site_is_fresh(sum, site)) {
				continue
			}
			path := make([dynamic]int, context.temp_allocator)
			for idx := head; idx >= 0 && queue[idx].parent >= 0; idx = queue[idx].parent {
				append(&path, idx)
			}
			for i := len(path) - 1; i >= 0; i -= 1 {
				item := queue[path[i]]
				caller := &ws.procs[queue[item.parent].state.proc_id]
				append(
					&chain,
					Chain_Step {
						symbol = strings.clone(caller.full_name, allocator),
						location = Location {
							file_path = strings.clone(item.edge.location.file_path, allocator),
							line = item.edge.location.line,
							column = item.edge.location.column,
						},
						description = fmt.aprintf(
							"calls %s",
							ws.procs[item.state.proc_id].full_name,
							allocator = allocator,
						),
					},
				)
			}
			mode_label :=
				"heap: context.allocator" if initial_mode == .Heap else "temp: context.temp_allocator"
			append(
				&chain,
				Chain_Step {
					symbol = strings.clone(pr.full_name, allocator),
					location = Location {
						file_path = strings.clone(site.location.file_path, allocator),
						line = site.location.line,
						column = site.location.column,
					},
					description = fmt.aprintf(
						"calls %s (%s [%s])",
						site.callee_name,
						site.reason,
						mode_label,
						allocator = allocator,
					),
				},
			)
			return chain, true
		}

		for &edge in sum.callees {
			if ws.procs[edge.callee_id].annotations.alloc_safe {
				continue
			}
			if fresh_only &&
			   curr.state.mode == .Temp &&
			   edge.in_loop &&
			   _loop_chain_frees_temp(sum, edge.loop_id) {
				continue
			}
			callee_taints := cg.summaries[edge.callee_id].taints
			for mode in ([3]Call_Alloc_Mode{.Heap, .Temp, .Caller_Param}) {
				if map_through_edge(edge, mode) == curr.state.mode &&
				   has_taint(callee_taints, mode, fresh_only) {
					push(
						&queue,
						&visited,
						Queue_Item{state = {edge.callee_id, mode}, parent = head, edge = &edge},
					)
				}
			}
		}
	}
	return chain, false
}
