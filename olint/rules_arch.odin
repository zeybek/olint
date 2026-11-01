package olint

import "core:fmt"
import "core:strings"

@(private = "file")
_pattern_matches_pkg :: proc(pattern: string, #by_ptr pkg: Package_Info) -> bool {
	if pattern == "*" {
		return true
	}
	if strings.has_suffix(pattern, "*") {
		prefix := pattern[:len(pattern) - 1]
		return strings.has_prefix(pkg.name, prefix) || strings.has_prefix(pkg.rel_dir, prefix)
	}
	return(
		pkg.name == pattern ||
		pkg.rel_dir == pattern ||
		pkg.annotations.layer == pattern ||
		strings.has_suffix(pkg.rel_dir, fmt.tprintf("/%s", pattern)) \
	)
}

@(private = "file")
_pattern_matches_raw_import :: proc(
	pattern: string,
	raw_path: string,
	resolved_pkg: ^Package_Info,
) -> bool {
	if resolved_pkg != nil && _pattern_matches_pkg(pattern, resolved_pkg^) {
		return true
	}
	if pattern == "*" {
		return true
	}
	if strings.has_suffix(pattern, "*") {
		prefix := pattern[:len(pattern) - 1]
		return strings.has_prefix(raw_path, prefix)
	}
	if raw_path == pattern {
		return true
	}
	// Match last path segment of `core:net` or `../db`.
	base := raw_path
	if colon := strings.last_index_byte(base, ':'); colon >= 0 {
		base = base[colon + 1:]
	}
	base = strings.trim_right(base, "/")
	if slash := strings.last_index_byte(base, '/'); slash >= 0 {
		base = base[slash + 1:]
	}
	return base == pattern
}

/*
Runs the architectural rules (`arch/layer-boundary` and `arch/import-cycle`) across `ws`,
appending findings to `report`.
*/
run_arch_rules :: proc(ws: ^Workspace, #by_ptr cfg: Config, report: ^Report) {
	if .Layer_Boundary in cfg.enabled_rules {
		_check_layer_boundaries(ws, cfg, report)
	}
	if .Import_Cycle in cfg.enabled_rules {
		_check_import_cycles(ws, report)
	}
}

@(private = "file")
_check_layer_boundaries :: proc(ws: ^Workspace, #by_ptr cfg: Config, report: ^Report) {
	for i in 0 ..< len(ws.packages) {
		pkg := &ws.packages[i]
		if pkg.is_dependency || is_rule_ignored(pkg.annotations, .Layer_Boundary) {
			continue
		}

		// Collect all forbidden targets that apply to `pkg`.
		forbidden := make([dynamic]string, context.temp_allocator)
		for f in pkg.annotations.forbid_imports {
			append(&forbidden, f)
		}
		for rule in cfg.forbid_imports {
			if _pattern_matches_pkg(rule.from, pkg^) {
				append(&forbidden, rule.to)
			}
		}

		for target_pat in forbidden {
			if chain, imp_loc, found := _find_import_violation_chain(
				ws,
				i,
				target_pat,
				context.temp_allocator,
			); found {
				msg := fmt.tprintf(
					"package '%s' is forbidden from importing '%s'",
					pkg.name,
					target_pat,
				)
				report_add_diagnostic(
					report,
					.Layer_Boundary,
					.Error,
					pkg.name,
					pkg.name,
					imp_loc,
					msg,
					chain[:],
				)
			}
		}
	}
}

@(private = "file")
_find_import_violation_chain :: proc(
	ws: ^Workspace,
	start_pkg_id: int,
	target_pat: string,
	allocator := context.temp_allocator,
) -> (
	chain: [dynamic]Chain_Step,
	root_loc: Location,
	found: bool,
) {
	chain = make([dynamic]Chain_Step, allocator)

	// Each node remembers the import that reached it; descriptions are only formatted for the
	// chain that gets reported.
	Queue_Node :: struct {
		pkg_id:     int,
		parent:     int,
		via_pkg:    int, // Package whose import reached this node
		via_import: int, // Index into that package's imports
	}

	queue := make([dynamic]Queue_Node, 0, len(ws.packages), context.temp_allocator)
	visited := make([]bool, len(ws.packages), context.temp_allocator)
	append(&queue, Queue_Node{pkg_id = start_pkg_id, parent = -1, via_pkg = -1, via_import = -1})
	visited[start_pkg_id] = true

	for head := 0; head < len(queue); head += 1 {
		pkg := &ws.packages[queue[head].pkg_id]
		for &imp, imp_idx in pkg.imports {
			resolved: ^Package_Info = nil
			if imp.resolved_id >= 0 && imp.resolved_id < len(ws.packages) {
				resolved = &ws.packages[imp.resolved_id]
			}

			if _pattern_matches_raw_import(target_pat, imp.raw_path, resolved) {
				path := make([dynamic]int, context.temp_allocator)
				for idx := head; idx >= 0 && queue[idx].parent >= 0; idx = queue[idx].parent {
					append(&path, idx)
				}
				for k := len(path) - 1; k >= 0; k -= 1 {
					node := queue[path[k]]
					via := &ws.packages[node.via_pkg]
					step_imp := &via.imports[node.via_import]
					append(
						&chain,
						Chain_Step {
							symbol = via.name,
							location = step_imp.location,
							description = fmt.tprintf(
								"imports \"%s\" (package %s)",
								step_imp.raw_path,
								ws.packages[node.pkg_id].name,
							),
						},
					)
				}
				target_label := resolved.name if resolved != nil else imp.raw_path
				append(
					&chain,
					Chain_Step {
						symbol = pkg.name,
						location = imp.location,
						description = fmt.tprintf(
							"imports \"%s\" (%s)",
							imp.raw_path,
							target_label,
						),
					},
				)
				return chain, chain[0].location, true
			}

			if imp.resolved_id >= 0 && !visited[imp.resolved_id] {
				visited[imp.resolved_id] = true
				append(
					&queue,
					Queue_Node {
						pkg_id = imp.resolved_id,
						parent = head,
						via_pkg = queue[head].pkg_id,
						via_import = imp_idx,
					},
				)
			}
		}
	}

	return chain, {}, false
}

@(private = "file")
_check_import_cycles :: proc(ws: ^Workspace, report: ^Report) {
	n := len(ws.packages)
	if n <= 1 {
		return
	}

	// 0 = unvisited, 1 = visiting (on stack), 2 = done
	state := make([]u8, n, context.temp_allocator)
	parent_pkg := make([]int, n, context.temp_allocator)
	parent_imp := make([]Import_Entry, n, context.temp_allocator)

	for start in 0 ..< n {
		if state[start] != 0 {
			continue
		}
		_dfs_cycle(ws, start, state, parent_pkg, parent_imp, report)
	}
}

@(private = "file")
_dfs_cycle :: proc(
	ws: ^Workspace,
	u: int,
	state: []u8,
	parent_pkg: []int,
	parent_imp: []Import_Entry,
	report: ^Report,
) {
	state[u] = 1
	pkg := &ws.packages[u]

	for imp in pkg.imports {
		v := imp.resolved_id
		if v < 0 || v >= len(ws.packages) {
			continue
		}
		if state[v] == 0 {
			parent_pkg[v] = u
			parent_imp[v] = imp
			_dfs_cycle(ws, v, state, parent_pkg, parent_imp, report)
		} else if state[v] == 1 {
			// Cycle found from `v` -> ... -> `u` -> `v`.
			v_pkg := &ws.packages[v]
			if v_pkg.is_dependency || is_rule_ignored(v_pkg.annotations, .Import_Cycle) {
				continue
			}
			steps := make([dynamic]Chain_Step, context.temp_allocator)
			rev_nodes := make([dynamic]int, context.temp_allocator)
			for curr := u; curr != v && curr >= 0; curr = parent_pkg[curr] {
				append(&rev_nodes, curr)
			}
			for k := len(rev_nodes) - 1; k >= 0; k -= 1 {
				node_id := rev_nodes[k]
				p_id := parent_pkg[node_id]
				p_imp := parent_imp[node_id]
				append(
					&steps,
					Chain_Step {
						symbol = ws.packages[p_id].name,
						location = p_imp.location,
						description = fmt.tprintf(
							"imports \"%s\" (package %s)",
							p_imp.raw_path,
							ws.packages[node_id].name,
						),
					},
				)
			}
			append(
				&steps,
				Chain_Step {
					symbol = pkg.name,
					location = imp.location,
					description = fmt.tprintf(
						"imports \"%s\" (back to package %s)",
						imp.raw_path,
						v_pkg.name,
					),
				},
			)
			root_loc := len(steps) > 0 ? steps[0].location : imp.location
			msg := fmt.tprintf("cyclic package import involving '%s'", v_pkg.name)
			report_add_diagnostic(
				report,
				.Import_Cycle,
				.Error,
				v_pkg.name,
				v_pkg.name,
				root_loc,
				msg,
				steps[:],
			)
		}
	}

	state[u] = 2
}
