<!--
The title becomes the commit message on main, so write it as a Conventional Commit:
fix: ..., feat: ..., perf: ..., docs: ... Put ! after the type (feat!: ...) if the change
breaks existing code or the JSON report layout.
-->

## What and why

<!-- What changed and why. Link the issue if there is one ("Closes #123"). -->

## How it was tested

<!-- The commands you ran, and on which OS and CPU. If the change affects diagnostics or the
report, paste the olint output from before and after. -->

## Checklist

<!-- Tick what you did. Delete the lines that don't apply. -->

- [ ] `make check test smoke` passes
- [ ] `make fmt-check` passes, or I couldn't run odinfmt and CI will check it
- [ ] New behavior has a test in `tests/` or `cmd/olint/main_test.odin`
- [ ] New or changed public declarations have doc comments, and `olint/doc.odin` covers anything users need to know
- [ ] A change to the JSON report layout bumps `JSON_FORMAT_VERSION`
- [ ] A new example package is in `EXAMPLE_PKGS` in the `Makefile`, in the check step of `.github/workflows/ci.yml`, and covered by `scripts/smoke.sh`
