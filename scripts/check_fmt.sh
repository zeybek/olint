#!/usr/bin/env bash
# Checks the given .odin files with odinfmt and the repository's odinfmt.json.
# Used by the pre-commit hook in .lefthook.yml. Skips (with a note) when odinfmt isn't
# installed; set ODINFMT to its path if it isn't on PATH. CI checks every file anyway.
set -euo pipefail

ODINFMT="${ODINFMT:-odinfmt}"
if ! command -v "$ODINFMT" >/dev/null 2>&1; then
  echo "odinfmt not found, skipping the format check (see CONTRIBUTING.md)"
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0
for f in "$@"; do
  [ -f "$f" ] || continue
  if ! "$ODINFMT" -config:"$ROOT/odinfmt.json" "$f" | diff -q "$f" - >/dev/null; then
    echo "needs formatting: $f (run: make fmt)"
    status=1
  fi
done
exit $status
