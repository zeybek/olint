package olint

import "base:runtime"
import "core:encoding/json"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"

/*
Source code location for a diagnostic or a step in a call/import chain.
*/
Location :: struct {
	file_path: string `json:"file_path"`,
	line:      int `json:"line"`,
	column:    int `json:"column"`,
}

/*
One hop in a witness chain (for example a call chain `step_world -> resolve_contacts -> fmt.aprintf`
or an import chain `ui -> state -> db`).
*/
Chain_Step :: struct {
	symbol:      string `json:"symbol"`,
	location:    Location `json:"location"`,
	description: string `json:"description"`,
}

/*
Single static analysis finding produced by `olint`.
*/
Diagnostic :: struct {
	rule:      Rule_ID `json:"-"`,
	rule_name: string `json:"rule"`,
	severity:  Severity `json:"-"`,
	level:     string `json:"severity"`,
	pkg_name:  string `json:"package"`,
	symbol:    string `json:"symbol,omitempty"`,
	location:  Location `json:"location"`,
	message:   string `json:"message"`,
	chain:     [dynamic]Chain_Step `json:"chain,omitempty"`,
}

/*
Complete report for a workspace analysis run.
*/
Report :: struct {
	allocator:          runtime.Allocator,
	root_path:          string,
	target_name:        string,
	packages_count:     int, // Packages under the analyzed directory
	dependencies_count: int, // Imported packages from outside it, analyzed but not reported on
	files_count:        int,
	procs_count:        int,
	elapsed_ms:         f64,
	error_count:        int,
	warning_count:      int,
	info_count:         int,
	parse_errors:       [dynamic]string,
	io_errors:          [dynamic]string, // Report files that could not be written
	diagnostics:        [dynamic]Diagnostic,
}

/*
Error returned by procedures that read or write report files.
*/
Report_Error :: union #shared_nil {
	os.Error,
	io.Error,
	json.Marshal_Error,
}

/*
Initializes an empty `Report` backed by `allocator`.
*/
@(require_results)
report_create :: proc(
	target_name: string,
	root_path := "",
	allocator := context.allocator,
	loc := #caller_location,
) -> Report {
	return Report {
		allocator = allocator,
		root_path = strings.clone(root_path, allocator, loc),
		target_name = strings.clone(target_name, allocator, loc),
		parse_errors = make([dynamic]string, allocator, loc),
		io_errors = make([dynamic]string, allocator, loc),
		diagnostics = make([dynamic]Diagnostic, allocator, loc),
	}
}

/*
Frees all memory owned by `r`.
*/
report_destroy :: proc(r: ^Report) {
	alloc := r.allocator
	delete(r.root_path, alloc)
	delete(r.target_name, alloc)
	for msg in r.parse_errors {
		delete(msg, alloc)
	}
	delete(r.parse_errors)
	for msg in r.io_errors {
		delete(msg, alloc)
	}
	delete(r.io_errors)
	for &d in r.diagnostics {
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
	delete(r.diagnostics)
	r^ = {}
}

/*
Appends a diagnostic finding to `r` and updates the severity counters. Strings are cloned into
the report's allocator.
*/
report_add_diagnostic :: proc(
	r: ^Report,
	rule: Rule_ID,
	severity: Severity,
	pkg_name: string,
	symbol: string,
	loc: Location,
	message: string,
	chain: []Chain_Step = nil,
) {
	alloc := r.allocator
	steps := make([dynamic]Chain_Step, 0, len(chain), alloc)
	for s in chain {
		append(
			&steps,
			Chain_Step {
				symbol = strings.clone(s.symbol, alloc),
				location = Location {
					file_path = strings.clone(s.location.file_path, alloc),
					line = s.location.line,
					column = s.location.column,
				},
				description = strings.clone(s.description, alloc),
			},
		)
	}

	d := Diagnostic {
		rule = rule,
		rule_name = rule_id_string(rule),
		severity = severity,
		level = severity_string(severity),
		pkg_name = strings.clone(pkg_name, alloc),
		symbol = strings.clone(symbol, alloc),
		location = Location {
			file_path = strings.clone(loc.file_path, alloc),
			line = loc.line,
			column = loc.column,
		},
		message = strings.clone(message, alloc),
		chain = steps,
	}
	append(&r.diagnostics, d)

	switch severity {
	case .Error:
		r.error_count += 1
	case .Warning:
		r.warning_count += 1
	case .Info:
		r.info_count += 1
	}
}

/*
Sorts diagnostics deterministically by file path, line, column, rule, and message.
*/
report_sort :: proc(r: ^Report) {
	slice.sort_by(r.diagnostics[:], proc(a, b: Diagnostic) -> bool {
		if a.location.file_path != b.location.file_path {
			return a.location.file_path < b.location.file_path
		}
		if a.location.line != b.location.line {
			return a.location.line < b.location.line
		}
		if a.location.column != b.location.column {
			return a.location.column < b.location.column
		}
		if a.rule_name != b.rule_name {
			return a.rule_name < b.rule_name
		}
		return a.message < b.message
	})
}

/*
Reports whether `r` passed according to `cfg`: no parse errors, no report files that failed to
write, no error diagnostics, and no warnings when `cfg.fail_on_warnings` is set.
*/
@(require_results)
report_passed :: proc "contextless" (r: ^Report, #by_ptr cfg: Config) -> bool {
	if len(r.parse_errors) > 0 || len(r.io_errors) > 0 || r.error_count > 0 {
		return false
	}
	if cfg.fail_on_warnings && r.warning_count > 0 {
		return false
	}
	return true
}

/*
Converts `abs_path` into a slash-normalized path relative to `root_path` when `abs_path` lies
under `root_path`.
*/
@(require_results)
relative_display_path :: proc(
	root_path: string,
	abs_path: string,
	allocator := context.temp_allocator,
) -> string {
	norm_abs, _ := strings.replace_all(abs_path, "\\", "/", context.temp_allocator)
	if root_path == "" {
		return strings.clone(norm_abs, allocator)
	}
	norm_root, _ := strings.replace_all(root_path, "\\", "/", context.temp_allocator)
	norm_root = strings.trim_right(norm_root, "/")
	if norm_abs == norm_root {
		return strings.clone(".", allocator)
	}
	prefix := strings.concatenate({norm_root, "/"}, context.temp_allocator)
	if strings.has_prefix(norm_abs, prefix) {
		return strings.clone(norm_abs[len(prefix):], allocator)
	}
	return strings.clone(norm_abs, allocator)
}
