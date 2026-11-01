package olint

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

@(private = "file")
_diagnostic_matches_filter :: proc(#by_ptr d: Diagnostic, filter: string) -> bool {
	if filter == "" {
		return true
	}
	return(
		strings.contains(d.rule_name, filter) ||
		strings.contains(d.pkg_name, filter) ||
		strings.contains(d.symbol, filter) ||
		strings.contains(d.location.file_path, filter) ||
		strings.contains(d.message, filter) \
	)
}

@(private = "file")
_apply_report_filter :: proc(r: ^Report, filter: string) {
	if filter == "" || len(r.diagnostics) == 0 {
		return
	}
	alloc := r.allocator
	write_idx := 0
	r.error_count = 0
	r.warning_count = 0
	r.info_count = 0

	for i in 0 ..< len(r.diagnostics) {
		d := r.diagnostics[i]
		if _diagnostic_matches_filter(d, filter) {
			r.diagnostics[write_idx] = d
			write_idx += 1
			switch d.severity {
			case .Error:
				r.error_count += 1
			case .Warning:
				r.warning_count += 1
			case .Info:
				r.info_count += 1
			}
		} else {
			delete(d.pkg_name, alloc)
			delete(d.symbol, alloc)
			delete(d.location.file_path, alloc)
			delete(d.message, alloc)
			for &step in d.chain {
				delete(step.symbol, alloc)
				delete(step.location.file_path, alloc)
				delete(step.description, alloc)
			}
			delete(d.chain)
		}
	}
	resize(&r.diagnostics, write_idx)
}

/*
Runs all enabled `olint` rules against an already-loaded `Workspace` and `Call_Graph`.
*/
@(require_results)
analyze_workspace_with_graph :: proc(
	ws: ^Workspace,
	cg: ^Call_Graph,
	#by_ptr cfg: Config,
	allocator := context.allocator,
	loc := #caller_location,
) -> Report {
	scratch := runtime.Arena {
		backing_allocator = allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	rep := report_create(ws.target_name, ws.root_path, allocator, loc)
	for &pkg in ws.packages {
		if pkg.is_dependency {
			rep.dependencies_count += 1
		} else {
			rep.packages_count += 1
			rep.files_count += len(pkg.files)
		}
	}
	for &pr in ws.procs {
		if !ws.packages[pr.pkg_id].is_dependency {
			rep.procs_count += 1
		}
	}

	for pe in ws.parse_errors {
		append(&rep.parse_errors, strings.clone(pe, allocator))
	}

	run_alloc_rules(ws, cg, cfg, &rep)
	run_arch_rules(ws, cfg, &rep)
	run_perf_rules(ws, cfg, &rep)
	run_annotation_rules(ws, cfg, &rep)

	_apply_report_filter(&rep, cfg.filter)
	report_sort(&rep)
	return rep
}

/*
Builds the call graph and runs all enabled rules on `ws`.
*/
@(require_results)
analyze_workspace :: proc(
	ws: ^Workspace,
	#by_ptr cfg: Config,
	allocator := context.allocator,
	loc := #caller_location,
) -> Report {
	t0 := time.tick_now()
	cg := callgraph_build(ws, allocator, loc)
	defer callgraph_destroy(&cg)

	rep := analyze_workspace_with_graph(ws, &cg, cfg, allocator, loc)
	rep.elapsed_ms = time.duration_milliseconds(time.tick_since(t0))
	return rep
}

/*
Loads all Odin packages under `target_dir`, builds the call graph, runs all enabled rules, and
writes any configured JSON, Markdown, or SARIF exports.
*/
@(require_results)
analyze_path :: proc(
	target_dir: string,
	#by_ptr cfg := Config{},
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	rep: Report,
	ok: bool,
) {
	t0 := time.tick_now()

	scratch := runtime.Arena {
		backing_allocator = allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	ws, loaded := workspace_load_from_path(target_dir, cfg, allocator, loc)
	if !loaded {
		return {}, false
	}
	defer workspace_destroy(&ws)

	cg := callgraph_build(&ws, allocator, loc)
	defer callgraph_destroy(&cg)

	rep = analyze_workspace_with_graph(&ws, &cg, cfg, allocator, loc)
	rep.elapsed_ms = time.duration_milliseconds(time.tick_since(t0))

	write_report_files(&rep, cfg)
	return rep, true
}

/*
Writes the JSON, Markdown, and SARIF reports configured in `cfg`. A file that can't be written
is recorded in `rep.io_errors`, which makes `report_passed` fail.
*/
write_report_files :: proc(rep: ^Report, #by_ptr cfg: Config) {
	record :: proc(rep: ^Report, kind, path: string, err: Report_Error) {
		if err != nil {
			append(
				&rep.io_errors,
				fmt.aprintf(
					"could not write %s report '%s': %v",
					kind,
					path,
					err,
					allocator = rep.allocator,
				),
			)
		}
	}
	if cfg.json_export_path != "" {
		record(rep, "JSON", cfg.json_export_path, save_json_report(rep, cfg.json_export_path))
	}
	if cfg.md_export_path != "" {
		record(rep, "Markdown", cfg.md_export_path, save_markdown_report(rep, cfg.md_export_path))
	}
	if cfg.sarif_export_path != "" {
		record(rep, "SARIF", cfg.sarif_export_path, save_sarif_report(rep, cfg.sarif_export_path))
	}
}
