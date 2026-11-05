#!/usr/bin/env bash
# check-restic-integrity.sh - can the off-site copy really be read back?
#
# Runs as root on Sundays (cron.d-decolab-root: the restic password is root's).
# backup-offsite.sh only proves that a fresh snapshot was WRITTEN. An aborted
# upload, a bit flip at the provider or a half-written pack would show up
# only on the day the copy is needed. --read-data-subset reads part of the
# data back and compares the checksums; without it restic checks only the
# structure (index, trees) and misses silent corruption. 5 % a week reads
# the whole repository back in about five months.
#
# Off (exits quietly) while RESTIC_REPOSITORY is empty.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=RESTIC

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  log "off-site backup is off (RESTIC_REPOSITORY empty)"
  exit 0
fi
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$SECRETS_DIR/restic-password}
restic=${RESTIC_BIN:-restic}
subset=${RESTIC_CHECK_SUBSET:-5%}
tag=${RESTIC_TAG:-decolab}
start=$(date +%s)

fail() {
  notify "🔴 Off-site copy" "$1"
  check_fail "$1"
}

# An empty repository passes "check" without complaint: the worst kind of
# green, formally correct and a lost backup. Count first.
snaps=$("$restic" snapshots --tag "$tag" --json 2>&1) || fail "restic snapshots failed: $(printf '%s' "$snaps" | tr '\n' ' ' | head -c 300)"
n=$(printf '%s' "$snaps" | python3 -I -c 'import json, sys
try:
    print(len(json.load(sys.stdin)))
except ValueError:
    print("bad")')
case $n in
  bad) fail "restic snapshots gave no JSON: $(printf '%s' "$snaps" | tr '\n' ' ' | head -c 300)" ;;
  0) fail "the repository has NO snapshot tagged $tag: backup lost or wrong repository" ;;
esac

out=$("$restic" check --read-data-subset="$subset" 2>&1)
rc=$?
printf '%s\n' "$out"
min=$((($(date +%s) - start) / 60))
short=$(printf '%s' "$out" | tr '\n' ' ' | head -c 300)
[ "$rc" -eq 0 ] || fail "restic check rc=$rc after $min min: $short"
# restic also prints warnings with rc 0. Only this line gives the all-clear.
# (No "printf | grep -q": under pipefail an early grep exit is SIGPIPE, 141.)
case $out in
  *"no errors were found"*) ;;
  *) fail "restic check ended without 'no errors were found': $short" ;;
esac
check_ok "repository without errors: $n snapshots, $subset of the data read back, $min min"
