.PHONY: all build check docs fmt fmt-check hooks lint links test test-lib test-cli test-examples smoke clean

ODIN ?= odin
# odinfmt from DanielGavin/ols (tools/odinfmt); see CONTRIBUTING.md.
ODINFMT ?= odinfmt
SOURCES = olint/*.odin cmd/olint/*.odin tests/*.odin examples/audio_dsp/*.odin examples/game_loop/*/*.odin examples/layered_arch/*/*.odin
# The same checks Odin's own CI applies to core.
FLAGS := -vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do
# Extra flags for test runs; set TEST_FLAGS= to drop the sanitizer where it isn't available.
TEST_FLAGS ?= -sanitize:address -define:ODIN_TEST_FANCY=false
BIN_DIR := bin
OLINT_BIN := $(BIN_DIR)/olint
EXAMPLE_PKGS := audio_dsp game_loop/physics game_loop/sim game_loop/tests layered_arch/domain layered_arch/service

all: check test build smoke

$(OLINT_BIN): cmd/olint/*.odin olint/*.odin
	@mkdir -p $(BIN_DIR)
	$(ODIN) build cmd/olint -out:$(OLINT_BIN) -o:speed $(FLAGS)

build: $(OLINT_BIN)

check:
	$(ODIN) check olint -no-entry-point $(FLAGS)
	$(ODIN) check cmd/olint $(FLAGS)
	$(ODIN) check tests -no-entry-point $(FLAGS)
	@for ex in $(EXAMPLE_PKGS); do \
		echo "$(ODIN) check examples/$$ex -no-entry-point $(FLAGS)"; \
		$(ODIN) check "examples/$$ex" -no-entry-point $(FLAGS) || exit 1; \
	done

# Installs the git hooks from .lefthook.yml (needs lefthook: https://lefthook.dev).
hooks:
	lefthook install

# Workflow files, shell scripts and spelling, with whichever of the tools are installed.
lint:
	@if command -v actionlint >/dev/null; then echo "actionlint"; actionlint; else echo "actionlint not installed, skipped"; fi
	@if command -v shellcheck >/dev/null; then echo "shellcheck"; shellcheck scripts/*.sh; else echo "shellcheck not installed, skipped"; fi
	@if command -v typos >/dev/null; then echo "typos"; typos; else echo "typos not installed, skipped"; fi

# HTML documentation in build/docs (needs odin-doc, see scripts/build_docs.sh).
docs:
	./scripts/build_docs.sh

# Links in the documentation (needs lychee).
links:
	lychee --no-progress --max-concurrency 8 --timeout 20 './*.md' './scripts/odin-doc.json'

fmt:
	@for f in $(SOURCES); do $(ODINFMT) -config:odinfmt.json -w "$$f" || exit 1; done

fmt-check:
	@status=0; for f in $(SOURCES); do \
		$(ODINFMT) -config:odinfmt.json "$$f" | diff -q "$$f" - >/dev/null || { echo "needs formatting: $$f"; status=1; }; \
	done; exit $$status

test: test-lib test-cli test-examples

test-lib:
	$(ODIN) test tests -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(FLAGS) $(TEST_FLAGS)

test-cli:
	$(ODIN) test cmd/olint -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(FLAGS) $(TEST_FLAGS)

test-examples:
	cd examples/game_loop/tests && $(ODIN) test . -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(FLAGS) $(TEST_FLAGS)

smoke: $(OLINT_BIN)
	./scripts/smoke.sh ./$(OLINT_BIN)

clean:
	rm -rf $(BIN_DIR) build .olint_test_*
