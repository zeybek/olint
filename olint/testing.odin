package olint

import "base:runtime"
import "core:log"
import "core:strings"
import "core:testing"

/*
Runs `olint` static analysis on `target_dir` inside an `odin test` procedure and fails the test
if any error (or warning when `cfg.fail_on_warnings` is set) is found.

Example:
	package my_tests

	import "core:testing"
	import olint "../libs/olint"

	@(test)
	architecture_and_zero_alloc :: proc(t: ^testing.T) {
		cfg := olint.default_config()
		cfg.zero_alloc_procs = {"step_world"}
		cfg.forbid_imports = {{from = "sim", to = "render"}}
		olint.expect_clean(t, "../src", cfg)
	}
*/
expect_clean :: proc(
	t: ^testing.T,
	target_dir: string,
	#by_ptr cfg := Config{enabled_rules = ALL_RULES, large_copy_bytes = DEFAULT_LARGE_COPY_BYTES},
	loc := #caller_location,
) -> bool {
	scratch := runtime.Arena {
		backing_allocator = context.allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	run_cfg := cfg
	if run_cfg.enabled_rules == {} {
		run_cfg.enabled_rules = ALL_RULES
	}
	if run_cfg.large_copy_bytes <= 0 {
		run_cfg.large_copy_bytes = 128
	}
	run_cfg.color_output = false

	rep, ok := analyze_path(target_dir, run_cfg, context.allocator)
	if !ok {
		testing.expectf(
			t,
			false,
			"olint could not load target directory %q",
			target_dir,
			loc = loc,
		)
		return false
	}
	defer report_destroy(&rep)

	passed := report_passed(&rep, run_cfg)
	if !passed {
		sb := strings.builder_make(context.temp_allocator)
		write_terminal_report(strings.to_writer(&sb), &rep, run_cfg)
		log.info(strings.to_string(sb), location = loc)
	}

	return testing.expectf(
		t,
		passed,
		"olint check failed on %q: %d error(s), %d warning(s), %d parse error(s)",
		target_dir,
		rep.error_count,
		rep.warning_count,
		len(rep.parse_errors),
		loc = loc,
	)
}
