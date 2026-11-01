package olint

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:text/table"

@(private = "file")
ANSI_RESET :: "\x1b[0m"
@(private = "file")
ANSI_BOLD :: "\x1b[1m"
@(private = "file")
ANSI_DIM :: "\x1b[2m"
@(private = "file")
ANSI_RED :: "\x1b[31m"
@(private = "file")
ANSI_GREEN :: "\x1b[32m"
@(private = "file")
ANSI_YELLOW :: "\x1b[33m"
@(private = "file")
ANSI_CYAN :: "\x1b[36m"
@(private = "file")
ANSI_MAGENTA :: "\x1b[35m"

@(private = "file")
_Palette :: struct {
	bold, dim, reset, green, red, yellow, cyan, magenta: string,
}

@(private = "file")
_palette :: proc(color: bool) -> _Palette {
	if !color {
		return {}
	}
	return _Palette {
		bold = ANSI_BOLD,
		dim = ANSI_DIM,
		reset = ANSI_RESET,
		green = ANSI_GREEN,
		red = ANSI_RED,
		yellow = ANSI_YELLOW,
		cyan = ANSI_CYAN,
		magenta = ANSI_MAGENTA,
	}
}

@(private = "file")
_ansi_width_proc :: proc(text: string) -> int {
	if strings.index_byte(text, 0x1b) < 0 {
		return table.unicode_width_proc(text)
	}
	visible := strings.builder_make(context.temp_allocator)
	in_escape := false
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case in_escape:
			in_escape = !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
		case c == 0x1b:
			in_escape = true
		case:
			strings.write_byte(&visible, c)
		}
	}
	return table.unicode_width_proc(strings.to_string(visible))
}

@(private)
_Report_Table :: struct {
	tbl:   table.Table,
	arena: runtime.Arena,
}

@(private)
_report_table_init :: proc(rt: ^_Report_Table) -> ^table.Table {
	rt.arena = runtime.Arena {
		backing_allocator = context.allocator,
	}
	table.init(&rt.tbl, runtime.arena_allocator(&rt.arena), context.allocator)
	return &rt.tbl
}

@(private)
_report_table_destroy :: proc(rt: ^_Report_Table) {
	table.destroy(&rt.tbl)
	runtime.arena_destroy(&rt.arena)
}

@(private)
_set_cell :: proc(
	tbl: ^table.Table,
	row, col: int,
	text: string,
	alignment := table.Cell_Alignment.Left,
) {
	table.set_cell_value_and_alignment(tbl, row, col, text, alignment)
}

@(private = "file")
_write_table_row :: proc(w: io.Writer, tbl: ^table.Table, row: int, sep: string) {
	for col in 0 ..< tbl.nr_cols {
		if col > 0 {
			io.write_string(w, sep)
		}
		if col == tbl.nr_cols - 1 && table.get_cell(tbl, row, col).alignment == .Left {
			io.write_string(w, table.get_cell(tbl, row, col).text)
		} else {
			table.write_table_cell(w, tbl, row, col)
		}
	}
	io.write_byte(w, '\n')
}

@(private = "file")
_table_width :: proc(tbl: ^table.Table, sep_width: int) -> int {
	width := 0
	for col_width in tbl.colw {
		width += col_width
	}
	return width + sep_width * max(tbl.nr_cols - 1, 0)
}

@(private = "file")
_format_loc :: proc(root_path: string, loc: Location) -> string {
	rel := relative_display_path(root_path, loc.file_path, context.temp_allocator)
	if loc.line > 0 && loc.column > 0 {
		return fmt.tprintf("%s:%d:%d", rel, loc.line, loc.column)
	}
	if loc.line > 0 {
		return fmt.tprintf("%s:%d", rel, loc.line)
	}
	return rel
}

/*
Writes the formatted terminal diagnostic report (table of findings, witness call/import chains,
and summary footer) to `w`.
*/
write_terminal_report :: proc(w: io.Writer, r: ^Report, #by_ptr cfg: Config) {
	p := _palette(cfg.color_output)

	deps := ""
	if r.dependencies_count > 0 {
		deps = fmt.tprintf(" + %d imported", r.dependencies_count)
	}
	fmt.wprintf(
		w,
		"\n%solint:%s %s%s (%s/%s, %d package(s)%s, %d file(s), %d proc(s) analyzed in %.2f ms)%s\n",
		p.bold,
		p.reset,
		p.dim,
		r.target_name,
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		r.packages_count,
		deps,
		r.files_count,
		r.procs_count,
		r.elapsed_ms,
		p.reset,
	)

	for pe in r.parse_errors {
		fmt.wprintf(w, " %s✗ parse error:%s %s\n", p.red, p.reset, pe)
	}
	for e in r.io_errors {
		fmt.wprintf(w, " %s✗ %s%s\n", p.red, e, p.reset)
	}

	if len(r.diagnostics) == 0 && len(r.parse_errors) == 0 && len(r.io_errors) == 0 {
		rule := strings.repeat("─", 88, context.temp_allocator)
		fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)
		fmt.wprintf(
			w,
			"%sPASS:%s 0 errors, 0 warnings across %d package(s) (%d procedures verified)\n\n",
			p.green,
			p.reset,
			r.packages_count,
			r.procs_count,
		)
		return
	}

	if len(r.diagnostics) > 0 {
		rt: _Report_Table
		tbl := _report_table_init(&rt)
		defer _report_table_destroy(&rt)

		table.header(tbl, "rule", "severity", "location", "finding")

		for &d in r.diagnostics {
			table.row(tbl)
			row := table.last_row(tbl)

			sev_color := p.cyan
			switch d.severity {
			case .Error:
				sev_color = p.red
			case .Warning:
				sev_color = p.yellow
			case .Info:
				sev_color = p.cyan
			}

			_set_cell(tbl, row, 0, fmt.tprintf("%s%s%s", p.cyan, d.rule_name, p.reset))
			_set_cell(
				tbl,
				row,
				1,
				fmt.tprintf("%s%s%s", sev_color, severity_label(d.severity), p.reset),
			)
			_set_cell(tbl, row, 2, _format_loc(r.root_path, d.location))
			_set_cell(tbl, row, 3, d.message)
		}

		SEP :: " │ "
		table.build(tbl, _ansi_width_proc)
		rule := strings.repeat(
			"─",
			max(_table_width(tbl, len(" | ")), 88),
			context.temp_allocator,
		)

		fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)
		io.write_string(w, p.bold)
		_write_table_row(w, tbl, table.header_row(tbl), SEP)
		io.write_string(w, p.reset)
		fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)

		for &d, idx in r.diagnostics {
			_write_table_row(w, tbl, idx + 1, SEP)
			for step, s_idx in d.chain {
				is_last := s_idx + 1 == len(d.chain)
				branch := is_last ? "╰─►" : "├─►"
				step_loc := _format_loc(r.root_path, step.location)
				fmt.wprintf(
					w,
					"   %s%s%s %s%s%s %s(%s)%s ── %s\n",
					p.dim,
					branch,
					p.reset,
					p.bold,
					step.symbol,
					p.reset,
					p.dim,
					step_loc,
					p.reset,
					step.description,
				)
			}
		}
		fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)
	}

	passed := report_passed(r, cfg)
	if passed {
		fmt.wprintf(
			w,
			"%sPASS:%s %d error(s), %d warning(s) across %d package(s)\n\n",
			p.green,
			p.reset,
			r.error_count,
			r.warning_count,
			r.packages_count,
		)
	} else {
		io_note := ""
		if len(r.io_errors) > 0 {
			io_note = fmt.tprintf(", %d report file error(s)", len(r.io_errors))
		}
		fmt.wprintf(
			w,
			"%sFAIL:%s %d error(s), %d warning(s), %d parse error(s)%s across %d package(s)\n\n",
			p.red,
			p.reset,
			r.error_count,
			r.warning_count,
			len(r.parse_errors),
			io_note,
			r.packages_count,
		)
	}
}

/*
Prints the terminal report to `os.stdout`.
*/
print_terminal_report :: proc(r: ^Report, #by_ptr cfg: Config) {
	write_terminal_report(os.to_stream(os.stdout), r, cfg)
}

/*
Writes the import list and the allocation behavior of every procedure (after propagation) for
`olint graph`. Imported packages from outside the analyzed directory are left out.
*/
write_workspace_graph :: proc(w: io.Writer, ws: ^Workspace, cg: ^Call_Graph, color := true) {
	p := _palette(color)
	pkg_count, proc_count := 0, 0
	for &pkg in ws.packages {
		if !pkg.is_dependency {
			pkg_count += 1
		}
	}
	for &pr in ws.procs {
		if !ws.packages[pr.pkg_id].is_dependency {
			proc_count += 1
		}
	}
	fmt.wprintf(
		w,
		"\n%solint graph:%s %s%s (%d package(s), %d procedure(s))%s\n",
		p.bold,
		p.reset,
		p.dim,
		ws.target_name,
		pkg_count,
		proc_count,
		p.reset,
	)
	rule := strings.repeat("─", 88, context.temp_allocator)
	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)

	procs_by_pkg := make([][dynamic]int, len(ws.packages), context.temp_allocator)
	for &pr in ws.procs {
		append(&procs_by_pkg[pr.pkg_id], pr.id)
	}

	for &pkg in ws.packages {
		if pkg.is_dependency {
			continue
		}
		layer_badge :=
			pkg.annotations.layer != "" ? fmt.tprintf(" [layer:%s]", pkg.annotations.layer) : ""
		fmt.wprintf(
			w,
			"%s%s%s %s(%s)%s%s\n",
			p.cyan,
			pkg.name,
			p.reset,
			p.dim,
			pkg.rel_dir,
			layer_badge,
			p.reset,
		)

		for imp in pkg.imports {
			fmt.wprintf(w, " %s├─ import%s \"%s\"\n", p.dim, p.reset, imp.raw_path)
		}

		pkg_procs := procs_by_pkg[pkg.id][:]
		for pid, idx in pkg_procs {
			pr := &ws.procs[pid]
			taints := cg.summaries[pid].taints
			branch := "╰─" if idx + 1 == len(pkg_procs) else "├─"

			badge := fmt.tprintf("%s[no-alloc]%s", p.green, p.reset)
			switch {
			case .Heap in taints && .Temp in taints:
				badge = fmt.tprintf("%s[heap + temp]%s", p.red, p.reset)
			case .Heap in taints:
				badge = fmt.tprintf("%s[heap]%s", p.red, p.reset)
			case .Temp in taints:
				badge = fmt.tprintf("%s[temp]%s", p.yellow, p.reset)
			case .Param in taints:
				badge = fmt.tprintf("%s[param-alloc]%s", p.magenta, p.reset)
			}

			local_name := pr.full_name[len(pr.pkg_name) + 1:]
			ann_tag := " @zero_alloc" if pr.annotations.zero_alloc else ""
			fmt.wprintf(
				w,
				" %s%s%s %s%s%s%s %s\n",
				p.dim,
				branch,
				p.reset,
				local_name,
				p.cyan,
				ann_tag,
				p.reset,
				badge,
			)
		}
	}
	fmt.wprintf(w, "%s%s%s\n\n", p.dim, rule, p.reset)
}
