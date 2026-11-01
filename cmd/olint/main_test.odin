package main

import olint "../../olint"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_parse_cli_args_defaults :: proc(t: ^testing.T) {
	opts, err := parse_cli_args(nil)
	defer destroy_cli_options(&opts)

	testing.expect_value(t, err, "")
	testing.expect_value(t, opts.subcommand, Subcommand.Check)
	testing.expect_value(t, opts.target_path, ".")
	testing.expect_value(t, opts.enabled_rules, olint.ALL_RULES)
	testing.expect_value(t, opts.large_copy_bytes, 128)
}

@(test)
test_parse_cli_args_flags_and_rules :: proc(t: ^testing.T) {
	args := []string {
		"check",
		"examples/game_loop",
		"-f",
		"sim",
		"-e",
		"step_world",
		"--no-temp",
		"audio_mix",
		"--forbid-import",
		"sim->render",
		"--disable",
		"perf/large-value-copy",
		"--large-copy-bytes",
		"256",
		"--md",
		"report.md",
		"--fail-on-warnings",
		"--no-color",
	}
	opts, err := parse_cli_args(args)
	defer destroy_cli_options(&opts)

	testing.expect_value(t, err, "")
	testing.expect_value(t, opts.subcommand, Subcommand.Check)
	testing.expect_value(t, opts.target_path, "examples/game_loop")
	testing.expect_value(t, opts.filter, "sim")
	testing.expect_value(t, len(opts.entries), 1)
	testing.expect_value(t, opts.entries[0], "step_world")
	testing.expect_value(t, len(opts.no_temp_entries), 1)
	testing.expect_value(t, opts.no_temp_entries[0], "audio_mix")
	testing.expect_value(t, len(opts.forbid_imports), 1)
	testing.expect_value(t, opts.forbid_imports[0].from, "sim")
	testing.expect_value(t, opts.forbid_imports[0].to, "render")
	testing.expect(t, .Large_Value_Copy not_in opts.enabled_rules)
	testing.expect(t, .Zero_Alloc in opts.enabled_rules)
	testing.expect_value(t, opts.large_copy_bytes, 256)
	testing.expect_value(t, opts.md_path, "report.md")
	testing.expect_value(t, opts.fail_on_warnings, true)
	testing.expect_value(t, opts.no_color, true)
}

@(test)
test_parse_cli_args_invalid :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args([]string{"--forbid-import", "invalid_arrow"})
		defer destroy_cli_options(&opts)
		testing.expect(t, err != "")
	}
	{
		opts, err := parse_cli_args([]string{"--rule", "nonexistent_rule"})
		defer destroy_cli_options(&opts)
		testing.expect(t, err != "")
	}
	{
		opts, err := parse_cli_args([]string{"--large-copy-bytes", "0"})
		defer destroy_cli_options(&opts)
		testing.expect(t, err != "")
	}
}

@(test)
test_cli_skips_vendored_olint_checkout :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "olint-vendor-test-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(root)

	// User package is clean.
	user_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(user_dir), nil)
	user_file, _ := filepath.join({user_dir, "app.odin"}, context.temp_allocator)
	testing.expect_value(
		t,
		os.write_entire_file(
			user_file,
			`package app
// @zero_alloc
add :: proc(a, b: int) -> int { return a + b }
`,
		),
		nil,
	)

	// Vendored `libs/olint` contains marker files (`doc.odin` + `callgraph.odin`) and a broken example.
	vendor_lib, _ := filepath.join({root, "libs", "olint"}, context.temp_allocator)
	vendor_ex, _ := filepath.join({vendor_lib, "examples"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory_all(vendor_ex), nil)
	doc_f, _ := filepath.join({vendor_lib, "doc.odin"}, context.temp_allocator)
	cg_f, _ := filepath.join({vendor_lib, "callgraph.odin"}, context.temp_allocator)
	ex_f, _ := filepath.join({vendor_ex, "bad.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(doc_f, "package olint\n"), nil)
	testing.expect_value(t, os.write_entire_file(cg_f, "package olint\n"), nil)
	testing.expect_value(
		t,
		os.write_entire_file(
			ex_f,
			`package bad
// @zero_alloc
leaky :: proc() -> []int { return make([]int, 8) }
`,
		),
		nil,
	)

	cfg := olint.default_config()
	cfg.color_output = false
	rep, ok := olint.analyze_path(root, cfg)
	testing.expect(t, ok)
	defer olint.report_destroy(&rep)

	testing.expect_value(t, rep.packages_count, 1)
	testing.expect_value(t, rep.error_count, 0)
}
