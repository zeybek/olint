package main

import olint "../../olint"
import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:text/table"

EXIT_FAILURE :: 1
EXIT_USAGE :: 2

Subcommand :: enum {
	Check,
	Graph,
	Rules,
	Version,
	Help,
}

CLI_Options :: struct {
	subcommand:              Subcommand,
	target_path:             string,
	filter:                  string,
	entries:                 [dynamic]string,
	no_temp_entries:         [dynamic]string,
	forbid_imports:          [dynamic]olint.Import_Rule,
	collections:             [dynamic]olint.Collection,
	enabled_rules:           olint.Rule_Set,
	fail_on_warnings:        bool,
	include_tests:           bool,
	treat_all_as_zero_alloc: bool,
	large_copy_bytes:        int,
	json_path:               string,
	md_path:                 string,
	sarif_path:              string,
	no_color:                bool,
}

print_usage :: proc() {
	fmt.printf(
		`olint %s
Static call-graph allocation & architecture linter for Odin.

USAGE:
  olint [check] [dir] [options]       Analyze Odin packages under dir (default: .)
  olint graph [dir]                   Print package import graph and procedure allocation badges
  olint rules                         List all built-in static analysis rules
  olint version | help

ANNOTATIONS (in doc comments above procedures, or above 'package' for a whole file/package):
  // @zero_alloc                      Fail if the procedure allocates on context.allocator, directly or through calls
  // @no_temp_alloc                   Fail if the procedure uses context.temp_allocator, directly or through calls
  // @alloc_safe                      Treat internal allocations as encapsulated (callers are not tainted)
  // @forbid_import("net", "vendor:*") Above 'package': forbid importing matching packages, even indirectly
  // @layer(core)                     Above 'package': name the package's layer for --forbid-import
  // @ignore(alloc/zero-alloc)        Suppress rules (all rules without arguments) on a procedure or file

Imports outside dir (relative paths and --collection paths) are analyzed as dependencies:
their allocations count, but their own findings are not reported.

OPTIONS:
  -f, --filter <substring>            Keep only findings matching substring (rule, package, symbol, path)
  -e, --entry <proc>                  Treat <proc> (name or pkg.proc) as @zero_alloc (repeatable)
      --no-temp <proc>                Treat <proc> as @no_temp_alloc (repeatable)
      --zero-alloc                    Treat every procedure in workspace as @zero_alloc
      --forbid-import <from->to>      Forbid package/layer <from> from importing <to> (repeatable)
      --collection <name=path>        Resolve "name:sub" imports like -collection:name=path (repeatable)
  -r, --rule <id>                     Enable only selected rule(s) (repeatable)
      --disable <id>                  Disable specific rule(s) (repeatable)
      --large-copy-bytes <bytes>      Byte threshold for perf/large-value-copy (default: 128)
      --include-tests                 Include *_test.odin files in analysis
  -W, --fail-on-warnings              Exit with status 1 on warnings as well as errors
      --json <file>                   Write a JSON report to <file>
      --md <file>                     Write a GitHub-flavored Markdown report to <file>
      --sarif <file>                  Write a SARIF 2.1.0 report for GitHub Code Scanning
      --no-color                      Disable ANSI colors (NO_COLOR is honored too)

Exit status: 0 clean, 1 findings or parse errors, 2 usage error.
`,
		olint.VERSION,
	)
}

@(private = "file")
_Cli_Flags :: struct {
	overflow:         [dynamic]string,
	filter:           string,
	entry:            [dynamic]string,
	no_temp:          [dynamic]string,
	forbid_import:    [dynamic]string,
	collection:       [dynamic]string,
	rule:             [dynamic]string,
	disable:          [dynamic]string,
	large_copy_bytes: int,
	include_tests:    bool,
	fail_on_warnings: bool,
	zero_alloc:       bool,
	json:             string,
	md:               string,
	sarif:            string,
	no_color:         bool,
	version:          bool,
	f:                string `args:"hidden"`,
	e:                [dynamic]string `args:"hidden"`,
	r:                [dynamic]string `args:"hidden"`,
	W:                bool `args:"hidden"`,
	v:                bool `args:"hidden"`,
}

/*
Parses command-line arguments (without `os.args[0]`). On failure `err` is non-empty.
*/
parse_cli_args :: proc(
	args: []string,
	allocator := context.allocator,
) -> (
	opts: CLI_Options,
	err: string,
) {
	base_cfg := olint.default_config()
	opts = CLI_Options {
		subcommand              = .Check,
		target_path             = ".",
		filter                  = base_cfg.filter,
		entries                 = make([dynamic]string, allocator),
		no_temp_entries         = make([dynamic]string, allocator),
		forbid_imports          = make([dynamic]olint.Import_Rule, allocator),
		collections             = make([dynamic]olint.Collection, allocator),
		enabled_rules           = olint.ALL_RULES,
		large_copy_bytes        = base_cfg.large_copy_bytes,
		fail_on_warnings        = base_cfg.fail_on_warnings,
		treat_all_as_zero_alloc = base_cfg.treat_all_as_zero_alloc,
		no_color                = !base_cfg.color_output,
		json_path               = base_cfg.json_export_path,
		md_path                 = base_cfg.md_export_path,
		sarif_path              = base_cfg.sarif_export_path,
	}

	rest := args
	if len(args) > 0 {
		switch args[0] {
		case "check", "lint", "run":
			opts.subcommand = .Check
			rest = args[1:]
		case "graph", "tree":
			opts.subcommand = .Graph
			rest = args[1:]
		case "rules", "list-rules":
			opts.subcommand = .Rules
			rest = args[1:]
		case "version":
			opts.subcommand = .Version
			rest = args[1:]
		case "help":
			opts.subcommand = .Help
			rest = args[1:]
		}
	}

	UNSET :: min(int)
	fl := _Cli_Flags {
		large_copy_bytes = UNSET,
	}
	parse_err := flags.parse(&fl, rest, .Unix, allocator = context.temp_allocator)
	switch pe in parse_err {
	case nil:
	case flags.Help_Request:
		opts.subcommand = .Help
		return opts, ""
	case flags.Parse_Error:
		return opts, pe.message
	case flags.Validation_Error:
		return opts, pe.message
	case flags.Open_File_Error:
		return opts, fmt.tprintf("could not open '%s'", pe.filename)
	}

	if fl.f != "" {
		fl.filter = fl.f
	}
	if fl.filter != "" {
		opts.filter = fl.filter
	}
	if fl.v || fl.version {
		opts.subcommand = .Version
	}
	if fl.W || fl.fail_on_warnings {
		opts.fail_on_warnings = true
	}
	if fl.include_tests {
		opts.include_tests = true
	}
	if fl.zero_alloc {
		opts.treat_all_as_zero_alloc = true
	}
	if fl.no_color {
		opts.no_color = true
	}
	if fl.json != "" {
		opts.json_path = fl.json
	}
	if fl.md != "" {
		opts.md_path = fl.md
	}
	if fl.sarif != "" {
		opts.sarif_path = fl.sarif
	}

	if fl.large_copy_bytes != UNSET {
		if fl.large_copy_bytes <= 0 {
			return opts, "--large-copy-bytes expects a positive integer"
		}
		opts.large_copy_bytes = fl.large_copy_bytes
	}

	for item in fl.entry {
		append(&opts.entries, strings.clone(item, allocator))
	}
	for item in fl.e {
		append(&opts.entries, strings.clone(item, allocator))
	}
	for item in fl.no_temp {
		append(&opts.no_temp_entries, strings.clone(item, allocator))
	}

	for spec in fl.forbid_import {
		arrow := strings.index(spec, "->")
		if arrow <= 0 || arrow + 2 >= len(spec) {
			return opts, fmt.tprintf("--forbid-import expects 'from->to', got '%s'", spec)
		}
		from_part := strings.trim_space(spec[:arrow])
		to_part := strings.trim_space(spec[arrow + 2:])
		if from_part == "" || to_part == "" {
			return opts, fmt.tprintf("--forbid-import expects 'from->to', got '%s'", spec)
		}
		append(
			&opts.forbid_imports,
			olint.Import_Rule {
				from = strings.clone(from_part, allocator),
				to = strings.clone(to_part, allocator),
			},
		)
	}

	for spec in fl.collection {
		eq := strings.index_byte(spec, '=')
		if eq <= 0 || eq + 1 >= len(spec) {
			return opts, fmt.tprintf("--collection expects 'name=path', got '%s'", spec)
		}
		append(
			&opts.collections,
			olint.Collection {
				name = strings.clone(spec[:eq], allocator),
				path = strings.clone(spec[eq + 1:], allocator),
			},
		)
	}

	if len(fl.rule) > 0 || len(fl.r) > 0 {
		opts.enabled_rules = {}
		for r_str in fl.rule {
			rid, ok := olint.parse_rule_id(r_str)
			if !ok {
				return opts, fmt.tprintf("unknown rule '%s' (see 'olint rules')", r_str)
			}
			opts.enabled_rules += {rid}
		}
		for r_str in fl.r {
			rid, ok := olint.parse_rule_id(r_str)
			if !ok {
				return opts, fmt.tprintf("unknown rule '%s' (see 'olint rules')", r_str)
			}
			opts.enabled_rules += {rid}
		}
	}

	for d_str in fl.disable {
		rid, ok := olint.parse_rule_id(d_str)
		if !ok {
			return opts, fmt.tprintf("unknown rule '%s' (see 'olint rules')", d_str)
		}
		opts.enabled_rules -= {rid}
	}

	positionals := fl.overflow[:]
	switch opts.subcommand {
	case .Check, .Graph:
		if len(positionals) > 1 {
			return opts, fmt.tprintf(
				"expected at most one target directory, got %d",
				len(positionals),
			)
		}
		if len(positionals) == 1 {
			opts.target_path = positionals[0]
		}
	case .Rules, .Version, .Help:
	}

	return opts, ""
}

destroy_cli_options :: proc(opts: ^CLI_Options, allocator := context.allocator) {
	for s in opts.entries {
		delete(s, allocator)
	}
	delete(opts.entries)
	for s in opts.no_temp_entries {
		delete(s, allocator)
	}
	delete(opts.no_temp_entries)
	for r in opts.forbid_imports {
		delete(r.from, allocator)
		delete(r.to, allocator)
	}
	delete(opts.forbid_imports)
	for c in opts.collections {
		delete(c.name, allocator)
		delete(c.path, allocator)
	}
	delete(opts.collections)
}

@(private = "file")
_print_rules_table :: proc() {
	arena := runtime.Arena {
		backing_allocator = context.allocator,
	}
	defer runtime.arena_destroy(&arena)

	tbl: table.Table
	table.init(&tbl, runtime.arena_allocator(&arena), context.allocator)
	defer table.destroy(&tbl)

	table.header(&tbl, "rule", "default", "description")
	for rule in olint.Rule_ID {
		table.row_of_values(
			&tbl,
			olint.rule_id_string(rule),
			olint.severity_label(olint.rule_default_severity(rule)),
			olint.rule_description(rule),
		)
	}
	table.build(&tbl, table.unicode_width_proc)
	table.write_plain_table(os.to_stream(os.stdout), &tbl)
}

@(private = "file")
_options_to_config :: proc(#by_ptr opts: CLI_Options) -> olint.Config {
	return olint.Config {
		enabled_rules = opts.enabled_rules,
		filter = opts.filter,
		fail_on_warnings = opts.fail_on_warnings,
		include_tests = opts.include_tests,
		treat_all_as_zero_alloc = opts.treat_all_as_zero_alloc,
		large_copy_bytes = opts.large_copy_bytes,
		zero_alloc_procs = opts.entries[:],
		no_temp_procs = opts.no_temp_entries[:],
		forbid_imports = opts.forbid_imports[:],
		collections = opts.collections[:],
		color_output = !opts.no_color,
		json_export_path = opts.json_path,
		md_export_path = opts.md_path,
		sarif_export_path = opts.sarif_path,
	}
}

main :: proc() {
	scratch := runtime.Arena {
		backing_allocator = context.allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	opts, parse_err := parse_cli_args(os.args[1:] if len(os.args) > 1 else nil)
	defer destroy_cli_options(&opts)

	if parse_err != "" {
		fmt.eprintf("olint: %s\nRun 'olint --help' for usage.\n", parse_err)
		os.exit(EXIT_USAGE)
	}

	switch opts.subcommand {
	case .Help:
		print_usage()
		return
	case .Version:
		fmt.printf("olint %s\n", olint.VERSION)
		return
	case .Rules:
		_print_rules_table()
		return
	case .Graph:
		if !os.is_directory(opts.target_path) {
			fmt.eprintf("olint: '%s' is not a directory\n", opts.target_path)
			os.exit(EXIT_USAGE)
		}
		cfg := _options_to_config(opts)
		ws, ok := olint.workspace_load_from_path(opts.target_path, cfg)
		if !ok {
			fmt.eprintf("olint: could not load workspace '%s'\n", opts.target_path)
			os.exit(EXIT_FAILURE)
		}
		defer olint.workspace_destroy(&ws)

		cg := olint.callgraph_build(&ws)
		defer olint.callgraph_destroy(&cg)

		olint.write_workspace_graph(os.to_stream(os.stdout), &ws, &cg, !opts.no_color)
		return
	case .Check:
		if !os.is_directory(opts.target_path) {
			fmt.eprintf("olint: '%s' is not a directory\n", opts.target_path)
			os.exit(EXIT_USAGE)
		}
		cfg := _options_to_config(opts)
		rep, ok := olint.analyze_path(opts.target_path, cfg)
		if !ok {
			fmt.eprintf("olint: could not analyze '%s'\n", opts.target_path)
			os.exit(EXIT_FAILURE)
		}
		defer olint.report_destroy(&rep)

		olint.print_terminal_report(&rep, cfg)
		if !olint.report_passed(&rep, cfg) {
			os.exit(EXIT_FAILURE)
		}
	}
}
