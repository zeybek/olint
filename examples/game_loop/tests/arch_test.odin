package game_loop_tests

import olint "../../../olint"
import "core:testing"

@(test)
verify_game_loop_architecture :: proc(t: ^testing.T) {
	cfg := olint.default_config()
	cfg.forbid_imports = {{from = "physics", to = "sim"}, {from = "sim", to = "render"}}
	olint.expect_clean(t, "..", cfg)
}
