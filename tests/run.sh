#!/usr/bin/env bash
# run.sh - run all Decolab tests:  tests/run.sh [NAME-FILTER]
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
filter=${1:-}
failed=0 files=0

for t in "$here"/test-*.sh; do
  case $(basename "$t") in *"$filter"*) ;; *) continue ;; esac
  files=$((files + 1))
  printf '\n%s\n' "$(basename "$t")"
  bash "$t" || failed=$((failed + 1))
done

[ "$files" -gt 0 ] || { echo "no test file matches '$filter'" >&2; exit 2; }
if [ "$failed" -gt 0 ]; then
  printf '\n%d of %d test files FAILED\n' "$failed" "$files"
  exit 1
fi
printf '\nall %d test files passed\n' "$files"
