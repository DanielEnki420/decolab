# shellcheck shell=bash
# tests/lib.sh - minimal helpers for Decolab's contract tests
#
# A test file sources this, calls `check` for each case and ends with
# `t_finish`. Tests run the real tools as a user would and look only at exit
# codes and output, so they stay valid when a tool is rewritten.
#
# Never write a real-looking address or name literally into a test file:
# tools/guard.sh scans the tests too. Build such values at run time from two
# halves, e.g. ip="192.168"; ip="$ip.31.7".

# shellcheck disable=SC2034  # used by the test files
t_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# pwd -P: macOS hands out TMPDIR with a trailing slash; "//" is no valid path.
t_tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/decolab-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$t_tmp"' EXIT
t_pass=0 t_nfail=0
out="" rc=0

# check NAME EXPECTED_RC EXPECTED_TEXT -- COMMAND [ARGS...]
#   Runs COMMAND, passes if the exit code matches and the combined output
#   contains EXPECTED_TEXT (empty text = no output check).
check() {
  local name=$1 want_rc=$2 want_text=$3
  shift 3
  [ "${1:-}" = -- ] && shift
  rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    t_fail "$name" "exit code $rc, expected $want_rc; output: $(printf '%s' "$out" | head -5)"
  elif [ -n "$want_text" ] && [[ $out != *"$want_text"* ]]; then
    t_fail "$name" "output lacks '$want_text'; output: $(printf '%s' "$out" | head -5)"
  else
    t_ok "$name"
  fi
}

# same NAME ACTUAL EXPECTED - plain comparison
same() {
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1" "got '$2', expected '$3'"; fi
}

# refute NAME TEXT - the output of the last check must NOT contain TEXT
refute() {
  if [[ $out == *"$2"* ]]; then t_fail "$1" "output contains '$2'"; else t_ok "$1"; fi
}

t_ok() { t_pass=$((t_pass + 1)); printf '  ok    %s\n' "$1"; }
t_fail() {
  t_nfail=$((t_nfail + 1))
  printf '  FAIL  %s\n' "$1"
  [ -z "${2:-}" ] || printf '        %s\n' "$2"
}

t_finish() {
  printf '  %d passed, %d failed\n' "$t_pass" "$t_nfail"
  [ "$t_nfail" -eq 0 ]
}
