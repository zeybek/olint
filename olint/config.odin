package olint

import "core:os"
import "core:strconv"
import "core:strings"

/*
Built-in static analysis rule identifiers.
*/
Rule_ID :: enum {
	// `@zero_alloc` procedure allocates on the heap directly or transitively.
	Zero_Alloc,
	// `@no_temp_alloc` procedure allocates on `context.temp_allocator` directly or transitively.
	No_Temp,
	// A loop body allocates fresh memory on `context.temp_allocator` without freeing it inside the loop.
	Loop_Temp,
	// Procedure frees/guards `context.temp_allocator` on exit (`defer free_all` or `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`) but returns a value allocated on `context.temp_allocator`.
	Dangling_Temp,
	// Return value of a fresh allocation (`make`, `new`, `strings.clone`, `fmt.aprintf`, etc.) is discarded.
	Discarded_Alloc,
	// A package imports a forbidden target package directly or transitively.
	Layer_Boundary,
	// Cyclic import dependency between workspace packages.
	Import_Cycle,
	// Large aggregate copied by value: C-ABI parameters, local copies of parameters, and `for v in` loops.
	Large_Value_Copy,
	// Misspelled annotation (`// @zero_aloc`) or unknown rule name in `@ignore(...)`.
	Unknown_Annotation,
}

/*
Bit set of active `Rule_ID` values.
*/
Rule_Set :: distinct bit_set[Rule_ID]

/*
All built-in rules enabled by default.
*/
ALL_RULES :: Rule_Set {
	.Zero_Alloc,
	.No_Temp,
	.Loop_Temp,
	.Dangling_Temp,
	.Discarded_Alloc,
	.Layer_Boundary,
	.Import_Cycle,
	.Large_Value_Copy,
	.Unknown_Annotation,
}

/*
Diagnostic severity level.
*/
Severity :: enum {
	Info,
	Warning,
	Error,
}

/*
Architectural layer boundary constraint forbidding `from` from importing `to` (directly or
transitively). Both `from` and `to` match package names, relative directory suffixes, or
collection prefixes with `*` (such as `"vendor:*"`).
*/
Import_Rule :: struct {
	from: string,
	to:   string,
}

/*
Import collection, as passed to the compiler with `-collection:name=path`. Imports such as
`"libs:text"` resolve to `path/text`.
*/
Collection :: struct {
	name: string,
	path: string,
}

/*
Configuration for a static analysis run.
*/
Config :: struct {
	enabled_rules:           Rule_Set,
	filter:                  string,
	fail_on_warnings:        bool,
	include_tests:           bool,
	treat_all_as_zero_alloc: bool,
	large_copy_bytes:        int,
	zero_alloc_procs:        []string,
	no_temp_procs:           []string,
	forbid_imports:          []Import_Rule,
	collections:             []Collection,
	color_output:            bool,
	json_export_path:        string,
	md_export_path:          string,
	sarif_export_path:       string,
}

/*
Returns the default configuration, honoring `NO_COLOR`, `OLINT_NO_COLOR`, `OLINT_FILTER`,
`OLINT_ZERO_ALLOC`, `OLINT_FAIL_ON_WARNINGS`, `OLINT_LARGE_COPY_BYTES`, `OLINT_JSON`,
`OLINT_MD`, and `OLINT_SARIF`.
*/
@(require_results)
default_config :: proc() -> Config {
	cfg := Config {
		enabled_rules           = ALL_RULES,
		treat_all_as_zero_alloc = DEFAULT_ZERO_ALLOC,
		fail_on_warnings        = DEFAULT_FAIL_ON_WARNINGS,
		large_copy_bytes        = DEFAULT_LARGE_COPY_BYTES,
		color_output            = DEFAULT_COLOR,
	}

	if val := os.get_env("OLINT_FILTER", context.temp_allocator); len(val) > 0 {
		cfg.filter = val
	}
	if val := os.get_env("NO_COLOR", context.temp_allocator); len(val) > 0 {
		cfg.color_output = false
	}
	if val := os.get_env("OLINT_NO_COLOR", context.temp_allocator); val == "1" || val == "true" {
		cfg.color_output = false
	}
	if val := os.get_env("OLINT_ZERO_ALLOC", context.temp_allocator); val == "1" || val == "true" {
		cfg.treat_all_as_zero_alloc = true
	}
	if val := os.get_env("OLINT_FAIL_ON_WARNINGS", context.temp_allocator);
	   val == "1" || val == "true" {
		cfg.fail_on_warnings = true
	}
	if val := os.get_env("OLINT_LARGE_COPY_BYTES", context.temp_allocator); len(val) > 0 {
		if n, ok := strconv.parse_int(val); ok && n > 0 {
			cfg.large_copy_bytes = n
		}
	}
	if val := os.get_env("OLINT_JSON", context.temp_allocator); len(val) > 0 {
		cfg.json_export_path = val
	}
	if val := os.get_env("OLINT_MD", context.temp_allocator); len(val) > 0 {
		cfg.md_export_path = val
	}
	if val := os.get_env("OLINT_SARIF", context.temp_allocator); len(val) > 0 {
		cfg.sarif_export_path = val
	}
	return cfg
}

/*
Returns the canonical string identifier for a `Rule_ID` (for example `"alloc/zero-alloc"`).
*/
@(require_results)
rule_id_string :: proc "contextless" (rule: Rule_ID) -> string {
	switch rule {
	case .Zero_Alloc:
		return "alloc/zero-alloc"
	case .No_Temp:
		return "alloc/no-temp"
	case .Loop_Temp:
		return "alloc/loop-temp"
	case .Dangling_Temp:
		return "alloc/dangling-temp"
	case .Discarded_Alloc:
		return "alloc/discarded"
	case .Layer_Boundary:
		return "arch/layer-boundary"
	case .Import_Cycle:
		return "arch/import-cycle"
	case .Large_Value_Copy:
		return "perf/large-value-copy"
	case .Unknown_Annotation:
		return "annotation/unknown"
	}
	return "unknown"
}

/*
Returns a short one-line description of a `Rule_ID`.
*/
@(require_results)
rule_description :: proc "contextless" (rule: Rule_ID) -> string {
	switch rule {
	case .Zero_Alloc:
		return(
			"Procedure marked @zero_alloc allocates on context.allocator directly or transitively" \
		)
	case .No_Temp:
		return(
			"Procedure marked @no_temp_alloc uses context.temp_allocator directly or transitively" \
		)
	case .Loop_Temp:
		return "Loop body allocates on context.temp_allocator without freeing it inside the loop"
	case .Dangling_Temp:
		return "Procedure frees context.temp_allocator on exit but returns a temp-allocated value"
	case .Discarded_Alloc:
		return "Return value of a heap/temp allocation procedure is discarded without being stored"
	case .Layer_Boundary:
		return "Package imports a forbidden package directly or transitively"
	case .Import_Cycle:
		return "Cyclic dependency between packages (also rejected by the compiler)"
	case .Large_Value_Copy:
		return(
			"Large aggregate copied by value: C-ABI parameter, local copy of a parameter, or `for v in` loop" \
		)
	case .Unknown_Annotation:
		return "Misspelled annotation or unknown rule name in @ignore(...)"
	}
	return ""
}

/*
Default severity of a `Rule_ID`.
*/
@(require_results)
rule_default_severity :: proc "contextless" (rule: Rule_ID) -> Severity {
	switch rule {
	case .Zero_Alloc, .No_Temp, .Dangling_Temp, .Discarded_Alloc, .Layer_Boundary, .Import_Cycle:
		return .Error
	case .Loop_Temp, .Large_Value_Copy, .Unknown_Annotation:
		return .Warning
	}
	return .Warning
}

/*
Parses a rule identifier string (such as `"alloc/zero-alloc"` or `"zero-alloc"` or `"zero_alloc"`).
*/
@(require_results)
parse_rule_id :: proc(text: string) -> (rule: Rule_ID, ok: bool) {
	s := strings.trim_space(text)
	switch s {
	case "alloc/zero-alloc", "zero-alloc", "zero_alloc":
		return .Zero_Alloc, true
	case "alloc/no-temp", "no-temp", "no_temp", "no-temp-alloc", "no_temp_alloc":
		return .No_Temp, true
	case "alloc/loop-temp", "loop-temp", "loop_temp":
		return .Loop_Temp, true
	case "alloc/dangling-temp", "dangling-temp", "dangling_temp", "temp-return", "temp_return":
		return .Dangling_Temp, true
	case "alloc/discarded", "discarded", "discarded-alloc", "discarded_alloc":
		return .Discarded_Alloc, true
	case "arch/layer-boundary", "layer-boundary", "layer_boundary", "forbid-import":
		return .Layer_Boundary, true
	case "arch/import-cycle", "import-cycle", "import_cycle":
		return .Import_Cycle, true
	case "perf/large-value-copy", "large-value-copy", "large_value_copy", "large-copy":
		return .Large_Value_Copy, true
	case "annotation/unknown", "unknown-annotation", "unknown_annotation":
		return .Unknown_Annotation, true
	}
	return .Zero_Alloc, false
}

/*
Formats a `Severity` as an uppercase label (`"ERROR"`, `"WARN"`, `"INFO"`).
*/
@(require_results)
severity_label :: proc "contextless" (sev: Severity) -> string {
	switch sev {
	case .Error:
		return "ERROR"
	case .Warning:
		return "WARN"
	case .Info:
		return "INFO"
	}
	return "INFO"
}

/*
Formats a `Severity` as a lowercase string (`"error"`, `"warning"`, `"info"`).
*/
@(require_results)
severity_string :: proc "contextless" (sev: Severity) -> string {
	switch sev {
	case .Error:
		return "error"
	case .Warning:
		return "warning"
	case .Info:
		return "info"
	}
	return "info"
}
