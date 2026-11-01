#!/usr/bin/env bash
# Checks that a commit message starts with a Conventional Commits header, which
# release-please needs to version releases. Used by the commit-msg hook in .lefthook.yml.
# Usage: scripts/check_commit_msg.sh <file with the commit message>
set -euo pipefail

header="$(head -n 1 "$1")"
types="feat|fix|perf|refactor|docs|style|test|build|ci|chore|revert"

# Messages git writes itself.
case "$header" in
  "Merge "* | "Revert "* | "fixup! "* | "squash! "* | "amend! "*) exit 0 ;;
esac

if ! printf '%s' "$header" | grep -Eq "^($types)(\([a-z0-9_./-]+\))?!?: [^ ].*"; then
  echo "commit message must start with a Conventional Commits header, for example:" >&2
  echo "  fix: handle selector expressions in perf/large-value-copy" >&2
  echo "  feat(cli)!: require arrow separator in --forbid-import" >&2
  echo "allowed types: ${types//|/, }" >&2
  echo "got: $header" >&2
  exit 1
fi
