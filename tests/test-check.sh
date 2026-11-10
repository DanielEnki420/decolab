#!/usr/bin/env bash
# Contract tests for tools/check.sh: CI is only worth something if it fails.
#
# A copy of the repository (tracked files, one commit) must pass
# "check.sh lint"; then one planted fault at a time must make it fail, named
# in the summary line. Faults are built at run time (tools/guard.sh scans
# this file too).
# Planted faults are literal text: no expansion meant.
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in shellcheck gitleaks git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    t_fail "$tool installed" "tools/check.sh lint needs it"
    t_finish
    exit 1
  fi
done

copy=$t_tmp/copy
mkdir -p "$copy"
# tracked and new (not ignored) files: what the next commit would hold
(cd "$t_root" && git ls-files -z --cached --others --exclude-standard | xargs -0 tar cf - | tar xf - -C "$copy")
g() { git -C "$copy" -c user.name=test -c user.email=test@example.invalid -c core.hooksPath=/dev/null "$@"; }
g init -q && g add -A && g commit -qm "copy"
# ruff and mypy live in the ignored .lint/ (tools/setup-dev.sh), so the copy
# has none and the python-lint step failed on any machine without them on PATH
[ -d "$t_root/.lint" ] && ln -s "$t_root/.lint" "$copy/.lint"
# no private word list: the copy must pass on the generic patterns alone
export DECOLAB_GUARD_WORDS=$t_tmp/no-words

check "a clean copy passes" 0 "all checks passed" -- "$copy/tools/check.sh" lint

# plant NAME FILE CONTENT WANT - add FILE (committed), expect WANT in FAILED:
plant() {
  local name=$1 file=$2 content=$3 want=$4
  mkdir -p "$(dirname "$copy/$file")"
  printf '%s\n' "$content" >"$copy/$file"
  if ! { g add -A && g commit -qm "plant $name"; }; then t_fail "$name: planted" "not committed"; return; fi
  check "$name: check.sh lint fails" 1 "FAILED:" -- "$copy/tools/check.sh" lint
  check "  ... and names $want" 0 "$want" -- sh -c 'printf "%s" "$1" | tail -1' _ "$out"
  g rm -q "$file" && g commit -qm "remove $name"
}

plant "a shell bug" scripts/planted.sh '#!/usr/bin/env bash
echo $undefined_on_purpose $1' shellcheck
plant "a shell bug without .sh" bin/planted '#!/usr/bin/env bash
rm -rf $1/*' shellcheck
plant "grep -q after a pipe" scripts/planted-grep.sh '#!/usr/bin/env bash
set -uo pipefail
ip -o addr show | grep -q inet || exit 1' grep-q
plant "a Python syntax error" lib/planted.py 'def broken(:
    pass' python
ip="192.168"
ip="$ip.31.77"
plant "a private address" docs/planted.md "the box is at $ip" guard-tree
key="ghp_"
key="${key}aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3z5A"
plant "a token" config/planted.conf "GITHUB_TOKEN=$key" gitleaks
# a leak removed again stays in the history: both history checks see it
check "the token in an old commit: still found" 1 "gitleaks" -- "$copy/tools/check.sh" lint
refute "  ... the tree itself is clean again" "guard-tree"

t_finish
