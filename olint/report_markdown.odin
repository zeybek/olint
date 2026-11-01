package olint

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:text/table"

@(private = "file")
_md_cell :: proc(text: string) -> string {
	if !strings.contains_any(text, "|`") {
		return text
	}
	out, _ := strings.replace_all(text, "|", "\\|", context.temp_allocator)
	out, _ = strings.replace_all(out, "`", "'", context.temp_allocator)
	return out
}

@(private = "file")
_md_loc :: proc(root_path: string, loc: Location) -> string {
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
Writes `r` as a GitHub-flavored Markdown report (table of findings and witness chains) to `w`.
*/
@(require_results)
write_markdown_report :: proc(w: io.Writer, r: ^Report) -> io.Error {
	fmt.wprintf(w, "## `olint` report: %s\n\n", _md_cell(r.target_name))
	fmt.wprintf(
		w,
		"- Platform: `%s/%s`\n- Odin: `%s`\n- Analyzed: `%d` package(s), `%d` file(s), `%d` procedure(s) in `%.2f ms`\n\n",
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		ODIN_VERSION,
		r.packages_count,
		r.files_count,
		r.procs_count,
		r.elapsed_ms,
	)

	if len(r.parse_errors) > 0 {
		io.write_string(w, "### Parse Errors\n\n") or_return
		for pe in r.parse_errors {
			fmt.wprintf(w, "- `%s`\n", _md_cell(pe))
		}
		io.write_byte(w, '\n') or_return
	}

	if len(r.diagnostics) == 0 && len(r.parse_errors) == 0 {
		fmt.wprintf(
			w,
			"**PASS:** 0 errors, 0 warnings across %d package(s) (%d procedures verified).\n",
			r.packages_count,
			r.procs_count,
		)
		return .None
	}

	if len(r.diagnostics) > 0 {
		rt: _Report_Table
		tbl := _report_table_init(&rt)
		defer _report_table_destroy(&rt)

		table.header(tbl, "Rule", "Severity", "Location", "Finding & Witness Chain")

		for &d in r.diagnostics {
			table.row(tbl)
			row := table.last_row(tbl)
			loc_str := _md_loc(r.root_path, d.location)

			chain_sb := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&chain_sb, "%s", _md_cell(d.message))
			for step in d.chain {
				s_loc := _md_loc(r.root_path, step.location)
				fmt.sbprintf(
					&chain_sb,
					"<br>↳ `%s` (`%s`) — %s",
					_md_cell(step.symbol),
					_md_cell(s_loc),
					_md_cell(step.description),
				)
			}

			_set_cell(tbl, row, 0, fmt.tprintf("`%s`", d.rule_name), .Left)
			_set_cell(tbl, row, 1, fmt.tprintf("**%s**", severity_label(d.severity)), .Left)
			_set_cell(tbl, row, 2, fmt.tprintf("`%s`", _md_cell(loc_str)), .Left)
			_set_cell(tbl, row, 3, strings.to_string(chain_sb), .Left)
		}
		table.write_markdown_table(w, tbl)
		io.write_byte(w, '\n') or_return
	}

	fmt.wprintf(
		w,
		"**Summary:** %d error(s), %d warning(s), %d parse error(s) across %d package(s).\n",
		r.error_count,
		r.warning_count,
		len(r.parse_errors),
		r.packages_count,
	)
	return .None
}

/*
Saves `r` as a GitHub-flavored Markdown report to `path`.
*/
@(require_results)
save_markdown_report :: proc(r: ^Report, path: string) -> Report_Error {
	sb := strings.builder_make(context.temp_allocator)
	write_markdown_report(strings.to_writer(&sb), r) or_return
	return os.write_entire_file(path, strings.to_string(sb))
}
