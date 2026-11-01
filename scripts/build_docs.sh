#!/usr/bin/env bash
# Builds the HTML package documentation into build/docs with the generator behind
# pkg.odin-lang.org (https://github.com/odin-lang/pkg.odin-lang.org), which must be on PATH
# as `odin-doc`. The settings are in scripts/odin-doc.json. Used by `make docs` and
# .github/workflows/docs.yml.
set -euo pipefail

cd "$(dirname "$0")/.."
rm -rf build/docs build/olint.odin-doc
mkdir -p build/docs

odin doc olint -all-packages -doc-format -out:build/olint.odin-doc

cd build/docs
odin-doc ../olint.odin-doc ../../scripts/odin-doc.json
rm ../olint.odin-doc
