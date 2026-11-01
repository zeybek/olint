package olint

import "core:fmt"
import "core:odin/ast"

@(private = "file")
_matches_proc_target :: proc(#by_ptr pr: Proc_Info, targets: []string) -> bool {
	for t in targets {
		if t == pr.name || t == pr.full_name {
			return true
		}
	}
	return false
}

@(private = "file")
_rule_active :: proc(#by_ptr cfg: Config, pr: ^Proc_Info, rule: Rule_ID) -> bool {
	return(
		rule in cfg.enabled_rules &&
		!is_rule_ignored(pr.annotations, rule) &&
		!is_rule_ignored(pr.file_annotations, rule) \
	)
}

/*
Runs the allocation rules (`alloc/zero-alloc`, `alloc/no-temp`, `alloc/loop-temp`,
`alloc/dangling-temp`, `alloc/discarded`) across `ws` and `cg`, appending findings to `report`.
Procedures of dependency packages are not reported.
*/
run_alloc_rules :: proc(ws: ^Workspace, cg: ^Call_Graph, #by_ptr cfg: Config, report: ^Report) {
	for i in 0 ..< len(ws.procs) {
		pr := &ws.procs[i]
		if ws.packages[pr.pkg_id].is_dependency {
			continue
		}
		sum := &cg.summaries[i]
		is_zero_alloc :=
			pr.annotations.zero_alloc ||
			cfg.treat_all_as_zero_alloc ||
			_matches_proc_target(pr^, cfg.zero_alloc_procs)

		if is_zero_alloc && _rule_active(cfg, pr, .Zero_Alloc) {
			if chain, found := find_shortest_alloc_chain(ws, cg, i, .Heap); found {
				report_add_diagnostic(
					report,
					.Zero_Alloc,
					.Error,
					pr.pkg_name,
					pr.full_name,
					pr.location,
					fmt.tprintf("%s (@zero_alloc) allocates on context.allocator", pr.full_name),
					chain[:],
				)
			}
		}

		is_no_temp := pr.annotations.no_temp_alloc || _matches_proc_target(pr^, cfg.no_temp_procs)
		if is_no_temp && _rule_active(cfg, pr, .No_Temp) {
			if chain, found := find_shortest_alloc_chain(ws, cg, i, .Temp); found {
				report_add_diagnostic(
					report,
					.No_Temp,
					.Error,
					pr.pkg_name,
					pr.full_name,
					pr.location,
					fmt.tprintf(
						"%s (@no_temp_alloc) allocates on context.temp_allocator",
						pr.full_name,
					),
					chain[:],
				)
			}
		}

		if _rule_active(cfg, pr, .Loop_Temp) {
			_check_proc_loop_temp(ws, cg, pr, sum, is_zero_alloc, report)
		}

		if sum.frees_temp_on_exit && _rule_active(cfg, pr, .Dangling_Temp) {
			_check_dangling_temp_stmt(ws, cg, i, pr, pr.lit.body, report)
		}

		if _rule_active(cfg, pr, .Discarded_Alloc) && pr.lit != nil {
			_check_discarded_alloc_stmt(pr, pr.lit.body, report)
		}
	}
}

/*
Reports misspelled annotations and unknown rule names in `@ignore(...)` on procedures and on the
comment above `package`.
*/
run_annotation_rules :: proc(ws: ^Workspace, #by_ptr cfg: Config, report: ^Report) {
	if .Unknown_Annotation not_in cfg.enabled_rules {
		return
	}
	for &pkg in ws.packages {
		if pkg.is_dependency {
			continue
		}
		for &sf in pkg.files {
			if sf.ast_file == nil || is_rule_ignored(sf.annotations, .Unknown_Annotation) {
				continue
			}
			for p in find_annotation_problems(sf.ast_file.docs) {
				loc := Location{sf.fullpath, p.pos.line, p.pos.column}
				report_add_diagnostic(
					report,
					.Unknown_Annotation,
					.Warning,
					pkg.name,
					pkg.name,
					loc,
					p.message,
				)
			}
		}
	}
	for i in 0 ..< len(ws.procs) {
		pr := &ws.procs[i]
		if ws.packages[pr.pkg_id].is_dependency || !_rule_active(cfg, pr, .Unknown_Annotation) {
			continue
		}
		for p in find_annotation_problems(pr.docs) {
			loc := Location{pr.file_path, p.pos.line, p.pos.column}
			report_add_diagnostic(
				report,
				.Unknown_Annotation,
				.Warning,
				pr.pkg_name,
				pr.full_name,
				loc,
				p.message,
			)
		}
	}
}

// Reports loops that keep allocating on `context.temp_allocator` without freeing it. Only
// unbounded loops (`for { }`, `for cond { }`) are checked, and every loop of a `@zero_alloc`
// procedure. A loop counts an allocation in a nested loop unless a loop in between frees the
// temp allocator each iteration.
@(private = "file")
_check_proc_loop_temp :: proc(
	ws: ^Workspace,
	cg: ^Call_Graph,
	pr: ^Proc_Info,
	sum: ^Proc_Summary,
	is_strict: bool,
	report: ^Report,
) {
	for &lp in sum.loops {
		if lp.frees_temp || (!lp.is_unbounded && !is_strict) {
			continue
		}

		reported := false
		for &site in sum.direct_sites {
			if site.mode != .Temp ||
			   !site.fresh ||
			   !site.in_loop ||
			   !loop_reaches(sum, site.loop_id, lp.id) {
				continue
			}
			steps := [1]Chain_Step {
				{
					symbol = pr.full_name,
					location = site.location,
					description = fmt.tprintf(
						"loop body calls %s (%s [temp: context.temp_allocator])",
						site.callee_name,
						site.reason,
					),
				},
			}
			report_add_diagnostic(
				report,
				.Loop_Temp,
				.Warning,
				pr.pkg_name,
				pr.full_name,
				lp.location,
				fmt.tprintf(
					"loop in %s allocates on context.temp_allocator without free_all(context.temp_allocator)",
					pr.full_name,
				),
				steps[:],
			)
			reported = true
			break
		}
		if reported {
			continue
		}

		for &edge in sum.callees {
			if !edge.in_loop || !loop_reaches(sum, edge.loop_id, lp.id) {
				continue
			}
			callee_mode := edge_brings_fresh_temp(ws, cg, edge)
			if callee_mode == .None {
				continue
			}
			chain := make([dynamic]Chain_Step, context.temp_allocator)
			append(
				&chain,
				Chain_Step {
					symbol = pr.full_name,
					location = edge.location,
					description = fmt.tprintf(
						"loop body calls %s",
						ws.procs[edge.callee_id].full_name,
					),
				},
			)
			if sub, ok := find_shortest_alloc_chain(
				ws,
				cg,
				edge.callee_id,
				callee_mode,
				fresh_only = true,
			); ok {
				append(&chain, ..sub[:])
			}
			report_add_diagnostic(
				report,
				.Loop_Temp,
				.Warning,
				pr.pkg_name,
				pr.full_name,
				lp.location,
				fmt.tprintf(
					"loop in %s transitively allocates on context.temp_allocator without free_all(context.temp_allocator)",
					pr.full_name,
				),
				chain[:],
			)
			break
		}
	}
}

@(private = "file")
_check_dangling_temp_stmt :: proc(
	ws: ^Workspace,
	cg: ^Call_Graph,
	proc_id: int,
	pr: ^Proc_Info,
	stmt: ^ast.Stmt,
	report: ^Report,
) {
	if stmt == nil {
		return
	}
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		for child in s.stmts {
			_check_dangling_temp_stmt(ws, cg, proc_id, pr, child, report)
		}
	case ^ast.Return_Stmt:
		for res_expr in s.results {
			if expr_allocates_on_temp(ws, cg, proc_id, res_expr) {
				report_add_diagnostic(
					report,
					.Dangling_Temp,
					.Error,
					pr.pkg_name,
					pr.full_name,
					Location{pr.file_path, res_expr.pos.line, res_expr.pos.column},
					fmt.tprintf(
						"%s frees context.temp_allocator on exit but returns memory allocated on it (use after free)",
						pr.full_name,
					),
				)
			}
		}
	case ^ast.If_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.else_stmt, report)
	case ^ast.When_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.else_stmt, report)
	case ^ast.For_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
	case ^ast.Range_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
	case ^ast.Inline_Range_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
	case ^ast.Switch_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
	case ^ast.Type_Switch_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.body, report)
	case ^ast.Case_Clause:
		for child in s.body {
			_check_dangling_temp_stmt(ws, cg, proc_id, pr, child, report)
		}
	case ^ast.Tag_Stmt:
		_check_dangling_temp_stmt(ws, cg, proc_id, pr, s.stmt, report)
	}
}

@(private = "file")
_check_discarded_call :: proc(pr: ^Proc_Info, expr: ^ast.Expr, report: ^Report) {
	if expr == nil {
		return
	}
	call, is_call := ast.strip_or_return_expr(expr).derived.(^ast.Call_Expr)
	if !is_call || call.expr == nil {
		return
	}
	qual, name := call_target(call.expr)
	if _, must_use, _ := classify_known_callee(qual, name); must_use {
		full_callee := name if qual == "" else fmt.tprintf("%s.%s", qual, name)
		report_add_diagnostic(
			report,
			.Discarded_Alloc,
			.Error,
			pr.pkg_name,
			pr.full_name,
			Location{pr.file_path, call.pos.line, call.pos.column},
			fmt.tprintf(
				"return value of allocating call '%s' is discarded in %s (memory leak)",
				full_callee,
				pr.full_name,
			),
		)
	}
}

@(private = "file")
_all_lhs_blank :: proc(lhs: []^ast.Expr) -> bool {
	if len(lhs) == 0 {
		return false
	}
	for expr in lhs {
		if expr == nil {
			return false
		}
		id, is_id := expr.derived.(^ast.Ident)
		if !is_id || id.name != "_" {
			return false
		}
	}
	return true
}

@(private = "file")
_check_discarded_alloc_stmt :: proc(pr: ^Proc_Info, stmt: ^ast.Stmt, report: ^Report) {
	if stmt == nil {
		return
	}
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		for child in s.stmts {
			_check_discarded_alloc_stmt(pr, child, report)
		}
	case ^ast.Expr_Stmt:
		_check_discarded_call(pr, s.expr, report)
	case ^ast.Assign_Stmt:
		if _all_lhs_blank(s.lhs) && len(s.rhs) == 1 {
			_check_discarded_call(pr, s.rhs[0], report)
		}
	case ^ast.Value_Decl:
		if len(s.values) > 0 {
			if _, is_proc := s.values[0].derived.(^ast.Proc_Lit); is_proc {
				return
			}
		}
		if _all_lhs_blank(s.names) && len(s.values) == 1 {
			_check_discarded_call(pr, s.values[0], report)
		}
	case ^ast.If_Stmt:
		_check_discarded_alloc_stmt(pr, s.init, report)
		_check_discarded_alloc_stmt(pr, s.body, report)
		_check_discarded_alloc_stmt(pr, s.else_stmt, report)
	case ^ast.When_Stmt:
		_check_discarded_alloc_stmt(pr, s.body, report)
		_check_discarded_alloc_stmt(pr, s.else_stmt, report)
	case ^ast.For_Stmt:
		_check_discarded_alloc_stmt(pr, s.init, report)
		_check_discarded_alloc_stmt(pr, s.body, report)
		_check_discarded_alloc_stmt(pr, s.post, report)
	case ^ast.Range_Stmt:
		_check_discarded_alloc_stmt(pr, s.init, report)
		_check_discarded_alloc_stmt(pr, s.body, report)
	case ^ast.Inline_Range_Stmt:
		_check_discarded_alloc_stmt(pr, s.body, report)
	case ^ast.Switch_Stmt:
		_check_discarded_alloc_stmt(pr, s.init, report)
		_check_discarded_alloc_stmt(pr, s.body, report)
	case ^ast.Type_Switch_Stmt:
		_check_discarded_alloc_stmt(pr, s.tag, report)
		_check_discarded_alloc_stmt(pr, s.body, report)
	case ^ast.Case_Clause:
		for child in s.body {
			_check_discarded_alloc_stmt(pr, child, report)
		}
	case ^ast.Defer_Stmt:
		_check_discarded_alloc_stmt(pr, s.stmt, report)
	case ^ast.Tag_Stmt:
		_check_discarded_alloc_stmt(pr, s.stmt, report)
	}
}
