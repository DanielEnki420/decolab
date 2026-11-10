#!/usr/bin/env bash
# backup-offsite.sh - encrypted copy in another place (restic)
#
# Runs as root at 04:10 (cron.d-decolab-root), after the local backup and the USB
# copy, under the same job lock. Backs up:
#   - the newest complete local backup (BACKUP_DIR/<date>): consistent
#     copies of every database. restic never reads a live database: a
#     live SQLite file and its -wal are read at different moments, and a
#     live Postgres directory is no backup at all.
#   - Immich's originals (upload/, library/, profile/)
#   - the Samba share DATA_DIR/nas
# Keeps 7 daily, 4 weekly, 6 monthly snapshots (tag "decolab").
#
# Proven, not assumed, after every run:
#   - restic ended with 0, else up to 3 attempts (not when the repository
#     does not exist: that needs restic init, once): on the original system a
#     DNS answer that failed for a few seconds once cost a whole day of
#     off-site protection, because the next run was 24 hours later
#   - forget/prune worked (or the repository fills up)
#   - a fresh snapshot exists
#   - config.tar.gz comes back from the new snapshot bit for bit: the folder
#     is really in it and can be read
#
# The repository is RESTIC_REPOSITORY (decolab.conf), its password
# SECRETS_DIR/restic-password. Keep that password somewhere else as well:
# without it the copy cannot be read, and the local copy of the password is
# lost together with the disk.
#
# Off (exits quietly) while RESTIC_REPOSITORY is empty.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  log "off-site backup is off (RESTIC_REPOSITORY empty)"
  exit 0
fi
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$SECRETS_DIR/restic-password}
restic=${RESTIC_BIN:-restic}
tag=${RESTIC_TAG:-decolab}
attempts=${OFFSITE_ATTEMPTS:-3}
pause=${OFFSITE_PAUSE_S:-120}

fail() {
  notify "🔴 Off-site copy" "$1"
  kuma_push OFFSITE down "$1"
  log "FAILED: $1"
  exit 1
}

[ -r "$RESTIC_PASSWORD_FILE" ] || fail "the restic password $RESTIC_PASSWORD_FILE is missing"
job_lock "${BACKUP_LOCK_WAIT_S:-1800}" || fail "another heavy job held the lock for too long"

latest=$(backup_latest)
[ -n "$latest" ] || fail "no complete local backup in $BACKUP_DIR: nothing consistent to copy"
paths=("$latest")
if is_yes MODULE_IMMICH; then
  for part in upload library profile; do
    [ -d "$DATA_DIR/immich/library/$part" ] && paths+=("$DATA_DIR/immich/library/$part")
  done
fi
[ -d "$DATA_DIR/nas" ] && paths+=("$DATA_DIR/nas")
log "off-site backup of ${paths[*]}"

rc=1 try=1
while [ "$try" -le "$attempts" ]; do
  if [ "$try" -gt 1 ]; then
    log "attempt $try of $attempts after $pause s"
    sleep "$pause"
  fi
  "$restic" backup --tag "$tag" --exclude-caches "${paths[@]}"
  rc=$?
  [ "$rc" -eq 0 ] && break
  # 10: the repository does not exist. Waiting will not create it.
  [ "$rc" -eq 10 ] && fail "the repository $RESTIC_REPOSITORY does not exist: create it once with restic init (INSTALL.md, step 6)"
  log "attempt $try failed (restic rc=$rc)"
  try=$((try + 1))
done
[ "$rc" -eq 0 ] || fail "restic backup failed $attempts times (rc=$rc)"

# --group-by host,tags: without it restic groups by host,paths. Adding a folder
# to the backup then starts a new group, and the old group never expires (a real
# repository held 65 snapshots instead of 14, the oldest five months old).
"$restic" forget --tag "$tag" --group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune ||
  fail "the backup ran, but forget/prune failed (rc=$?): the repository will fill up"

snap=$("$restic" snapshots --tag "$tag" --latest 1 --json 2>/dev/null)
case $snap in
  *'"time"'*) ;;
  *) fail "restic reported success, but no snapshot can be found" ;;
esac

probe=$latest/config.tar.gz
if ! "$restic" dump --tag "$tag" latest "$probe" | cmp -s - "$probe"; then
  fail "read-back failed: $probe did not come back from the new snapshot as it is"
fi

msg="snapshot of ${latest##*/} and ${#paths[@]} folders, forget/prune ok, config.tar.gz read back"
kuma_push OFFSITE up "$msg" || exit 1
log "OK: $msg"
