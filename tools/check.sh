#!/usr/bin/env bash
# check.sh - every check Decolab's CI runs, the same way on your machine
#
#   tools/check.sh lint     shellcheck, Python syntax, ruff, mypy, guard (tree + history), gitleaks
#   tools/check.sh test     the contract tests (tests/run.sh; needs Docker)
#   tools/check.sh          both
#
# .github/workflows/ci.yml calls exactly these, so "green here" and "green in
# CI" mean the same. One difference stays: CI has no private word list for
# tools/guard.sh (it must never be uploaded), so only your machine checks it.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1
what=${1:-all}
failed=""

step() { printf '\n== %s\n' "$1"; }
fail() { failed="$failed $1"; }

# Shell files: tracked *.sh plus tracked files with a sh/bash shebang.
# (if, not &&: under pipefail a last failed test would fail the whole list)
shell_files() {
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case $f in
      *.template) ;; # placeholders (${...}) first, shell only once rendered
      *.sh) printf '%s\0' "$f" ;;
      *) if head -1 "$f" 2>/dev/null | grep -E '^#!(/usr/bin/env |/bin/)(ba)?sh( |$)' >/dev/null; then printf '%s\0' "$f"; fi ;;
    esac
  done
}
python_files() {
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case $f in
      *.py) printf '%s\0' "$f" ;;
      *) if head -1 "$f" 2>/dev/null | grep -E '^#!.*python' >/dev/null; then printf '%s\0' "$f"; fi ;;
    esac
  done
}

lint() {
  local n
  step "shellcheck"
  n=$(shell_files | tr -cd '\0' | wc -c | tr -d ' ')
  if shell_files | xargs -0 shellcheck -x; then echo "shellcheck: $n files clean"; else fail shellcheck; fi

  # "cmd | grep -q": grep stops at the first match, cmd may still write and
  # die of SIGPIPE, and under pipefail the test fails at random (decolab-
  # firewall, 2026-11-08). Write "grep ... >/dev/null" instead. Tests and
  # plain-sh code (sh -c, no pipefail) are exempt.
  step "no grep -q after a pipe"
  local hits
  hits=$(shell_files | tr '\0' '\n' | grep -v '^tests/' | while IFS= read -r f; do
    grep -nE '\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' "$f" | grep -vE '^[0-9]+:[[:space:]]*#|sh -c ' | sed "s|^|$f:|"
  done)
  if [ -z "$hits" ]; then echo "grep-q: none after a pipe"; else printf '%s\n' "$hits"; fail grep-q; fi

  step "python syntax"
  n=$(python_files | tr -cd '\0' | wc -c | tr -d ' ')
  # compile into a throw-away cache: nothing lands in the checkout
  if python_files | PYTHONPYCACHEPREFIX=$(mktemp -d) xargs -0 python3 -I -m py_compile; then
    echo "python: $n files compile"
  else
    fail python
  fi

  # ruff and mypy come from .lint/ (tools/setup-dev.sh, pinned by checksum in
  # tools/requirements-lint.txt) or, in CI, from the PATH
  step "ruff"
  if [ -x .lint/bin/ruff ]; then PATH="$root/.lint/bin:$PATH"; fi
  if ! command -v ruff >/dev/null 2>&1 || ! command -v mypy >/dev/null 2>&1; then
    echo "ruff or mypy is not installed: run tools/setup-dev.sh" >&2
    fail python-lint
  else
    if python_files | xargs -0 ruff check --no-cache --quiet; then
      echo "ruff: $n files clean"
    else
      fail ruff
    fi
    step "mypy"
    python_files | xargs -0 mypy || fail mypy
  fi

  step "guard (tree)"
  tools/guard.sh --tree || fail guard-tree
  step "guard (history)"
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "guard: the clone is shallow; the history check needs all of it (fetch-depth: 0)" >&2
    fail guard-history
  else
    tools/guard.sh --history || fail guard-history
  fi

  step "gitleaks (history)"
  if command -v gitleaks >/dev/null 2>&1; then
    gitleaks git --redact --no-banner --log-level warn . || fail gitleaks
  else
    echo "gitleaks is not installed" >&2
    fail gitleaks
  fi
}

tests() {
  step "contract tests"
  tests/run.sh || fail tests
}

case $what in
  lint) lint ;;
  test) tests ;;
  all) lint; tests ;;
  *) sed -n '2,6s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac

if [ -n "$failed" ]; then
  printf '\nFAILED:%s\n' "$failed"
  exit 1
fi
printf '\nall checks passed\n'
