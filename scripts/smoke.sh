#!/usr/bin/env bash
# End-to-end checks for the olint CLI. Used by `make smoke` and CI.
# Usage: scripts/smoke.sh [path/to/olint]
set -euo pipefail

OLINT="${1:-./bin/olint}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/olint-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
WORK_N="$(native_path "$WORK")"
step() { echo; echo "smoke: $*"; }

snapshot() { find examples -type f | LC_ALL=C sort; }
BEFORE="$(snapshot)"

step "usage errors exit with status 2"
set +e
"$OLINT" --definitely-not-a-flag >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 2 ] || fail "expected exit 2 for an unknown flag, got $code"

step "version and rules subcommands"
"$OLINT" version | grep -q "^olint "
"$OLINT" rules | tee "$WORK/rules.txt" >/dev/null
[ "$(grep -c "alloc/" "$WORK/rules.txt")" -eq 5 ] || fail "expected 5 alloc/* rules"
[ "$(grep -c "arch/" "$WORK/rules.txt")" -eq 2 ] || fail "expected 2 arch/* rules"
[ "$(grep -c "perf/" "$WORK/rules.txt")" -eq 1 ] || fail "expected 1 perf/* rule"
[ "$(grep -c "annotation/" "$WORK/rules.txt")" -eq 1 ] || fail "expected 1 annotation/* rule"

step "an unwritable report path fails the run"
set +e
"$OLINT" check examples --no-color --json "$WORK_N/missing-dir/out.json" >"$WORK/io.txt" 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 when a report file can't be written, got $code"
grep -q "could not write JSON report" "$WORK/io.txt" || fail "missing report write error"

step "clean check across all example packages"
"$OLINT" check examples --fail-on-warnings --no-color \
  --json "$WORK_N/examples.json" \
  --md "$WORK_N/examples.md" \
  --sarif "$WORK_N/examples.sarif"
grep -q '"error_count": 0' "$WORK/examples.json" || fail "expected 0 errors in examples.json"
grep -q '"warning_count": 0' "$WORK/examples.json" || fail "expected 0 warnings in examples.json"
grep -q "PASS:" "$WORK/examples.md" || fail "expected PASS in examples.md"
grep -q '"version": "2.1.0"' "$WORK/examples.sarif" || fail "expected SARIF 2.1.0 output"

step "transitive @zero_alloc violation is caught with full call chain"
set +e
"$OLINT" check examples/game_loop -e step_world_leaky --no-color \
  --json "$WORK_N/leaky.json" \
  --sarif "$WORK_N/leaky.sarif" >"$WORK/leaky.txt" 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for transitive zero_alloc violation, got $code"
grep -q "alloc/zero-alloc" "$WORK/leaky.txt" || fail "missing alloc/zero-alloc in terminal output"
grep -q "physics.solve_contacts_debug" "$WORK/leaky.txt" || fail "missing intermediate hop in witness chain"
grep -q "physics.format_contact_tag" "$WORK/leaky.txt" || fail "missing leaf hop in witness chain"
grep -q '"codeFlows"' "$WORK/leaky.sarif" || fail "missing codeFlows in SARIF output"

step "architectural layer boundary violation is caught via --forbid-import"
set +e
"$OLINT" check examples/layered_arch --forbid-import "service->domain" --no-color >"$WORK/arch.txt" 2>&1
code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for forbidden import, got $code"
grep -q "arch/layer-boundary" "$WORK/arch.txt" || fail "missing arch/layer-boundary in output"

step "olint graph prints package and procedure allocation badges"
"$OLINT" graph examples --no-color | tee "$WORK/graph.txt" >/dev/null
grep -q "\[no-alloc\]" "$WORK/graph.txt" || fail "missing [no-alloc] badge in graph output"
grep -q "\[heap\]" "$WORK/graph.txt" || fail "missing [heap] badge in graph output"

step "self-check on the olint repository passes with --fail-on-warnings"
"$OLINT" check . --fail-on-warnings --no-color

step "nothing was written into the source tree"
AFTER="$(snapshot)"
[ "$BEFORE" = "$AFTER" ] || fail "files under examples/ changed"

echo
echo "smoke: all checks passed"
