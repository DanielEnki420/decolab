#!/usr/bin/env bash
# restore-probe-immich.sh - does the backup become a photo library again?
#
# Immich's backup has two parts that must fit together:
#   1. the database dump (immich-db.sql.gz, from backup.sh): albums, people,
#      dates, and above all which file is which photo
#   2. the original files (upload/, library/, profile/), mirrored to the USB
#      disk by backup-usb.sh and off-site by backup-offsite.sh
# Without the database the files are a heap of UUID names; without the
# files the database is a catalogue without content. Only both together
# are a backup.
#
# Proves: the dump loads into a fresh database of production's image, it is
# complete (as many photos as the dump lists), and a random sample of the
# files it names really lies in the copy of the files: the USB copy if there
# is one (USB_BACKUP_DIR), otherwise the library itself.
# Does NOT prove that every file is undamaged: a sample is checked daily,
# the monthly restic check reads the off-site copy.
#
# The throw-away database has no network, no host port and no bind mount:
# it is asked from inside (docker exec), its data lives in an anonymous
# volume that is removed with the container. It cannot be mistaken for
# production, and production cannot be reached from it.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
# shellcheck source=lib/probe.sh
. "$decolab_root/lib/probe.sh"

if ! is_yes MODULE_IMMICH; then
  log "Immich is switched off"
  exit 0
fi
probe_init immich PROBE_IMMICH -
samples=${PROBE_SAMPLES:-20}
read_secrets "$SECRETS_DIR/immich.env" DB_USERNAME DB_DATABASE_NAME || probe_fail "cannot read immich.env"

probe_archive immich-db.sql.gz
gzip -t "$PROBE_ARCHIVE" 2>/dev/null || probe_fail "immich-db.sql.gz is damaged (gzip)"
probe_ok                                                                    # 1

# The target comes FROM THE DUMP, not from production: otherwise the probe
# would only check that two systems happen to agree.
# (awk reads to the end: "gzip -dc | grep -q" ends in SIGPIPE under pipefail.)
assets=$(gzip -dc "$PROBE_ARCHIVE" | awk '
  /^COPY public\.asset \(/ { inside = 1; next }
  inside && /^\\\.$/ { inside = 0 }
  inside { n++ }
  END { print n + 0 }')
[ "${assets:-0}" -ge 1 ] || probe_fail "the dump holds no photo (Immich not used yet?)"
probe_count_guard assets "$assets"
probe_ok                                                                    # 2

# Production's image and capabilities. No password: no network, and the
# only way in is docker exec.
probe_image immich_postgres
probe_run --cap-drop ALL --cap-add CHOWN --cap-add FOWNER --cap-add SETUID --cap-add SETGID \
  --cap-add DAC_OVERRIDE --memory 1g --shm-size 128m --network none \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e "POSTGRES_USER=$DB_USERNAME" -e "POSTGRES_DB=$DB_DATABASE_NAME" "$PROBE_IMAGE"
# Over TCP, not the socket: during its first start the image runs a
# temporary server on the socket only, then restarts. Loading the dump into
# that one would be cut off by the restart.
# shellcheck disable=SC2329 # called by probe_wait
ready() { docker exec "$PROBE_NAME" pg_isready -q -h 127.0.0.1 -U "$DB_USERNAME" -d "$DB_DATABASE_NAME"; }
probe_wait "${PROBE_WAIT_S:-120}" "accept connections" ready
probe_ok                                                                    # 3

# "already exists": the image creates the extensions itself; the dump does too.
probe_tmp
gzip -dc "$PROBE_ARCHIVE" |
  timeout "${PROBE_RESTORE_S:-1800}" docker exec -i "$PROBE_NAME" psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -q -v ON_ERROR_STOP=0 \
    >"$PROBE_DIR/restore.log" 2>&1
rc=$?
[ "$rc" = 0 ] || probe_fail "loading the dump ended with exit code $rc (124: took longer than ${PROBE_RESTORE_S:-1800} s)"
errors=$(grep -E '^psql:.*ERROR' "$PROBE_DIR/restore.log" | grep -v 'already exists' | head -3)
[ -z "$errors" ] || probe_fail "loading the dump reported errors: $(printf '%s' "$errors" | tr '\n' ' ')"
probe_ok                                                                    # 4

ask() { docker exec "$PROBE_NAME" psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -t -A -c "$1" 2>/dev/null; }
restored=$(ask 'SELECT count(*) FROM asset')
[ "$restored" = "$assets" ] || probe_fail "${restored:-no} photos restored, the dump lists $assets"
probe_ok                                                                    # 5
users=$(ask 'SELECT count(*) FROM "user"')
[ "${users:-0}" -ge 1 ] 2>/dev/null || probe_fail "the restored database has no user"
albums=$(ask 'SELECT count(*) FROM album')
probe_ok                                                                    # 6

# The cross-check: do the files the database names lie in the copy?
# /data in the database is DATA_DIR/immich/library on the host (compose).
# External libraries (paths outside /data) are not part of the backup.
where=library base=$DATA_DIR/immich/library
if [ -n "${USB_BACKUP_DIR:-}" ]; then
  where="USB copy" base=$USB_BACKUP_DIR/immich
  [ -e "$USB_BACKUP_DIR/.decolab-usb-backup" ] || probe_fail "USB_BACKUP_DIR is set, but the USB disk is not mounted (no .decolab-usb-backup)"
fi
[ -d "$base" ] && [ -r "$base" ] || probe_fail "cannot read the $where at $base"
checked=0 missing=0 empty=0 first=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  checked=$((checked + 1))
  f=$base/${p#/data/}
  if [ ! -f "$f" ]; then
    missing=$((missing + 1)) first=${first:-$p}
  elif [ ! -s "$f" ]; then
    empty=$((empty + 1)) first=${first:-$p}
  fi
done < <(ask "SELECT \"originalPath\" FROM asset WHERE \"originalPath\" LIKE '/data/%' ORDER BY random() LIMIT $samples")
[ "$checked" -gt 0 ] || probe_fail "the cross-check did not run: no file paths in the restored database"
[ "$missing" = 0 ] || probe_fail "$missing of $checked sampled photos are missing in the $where (e.g. $first)"
[ "$empty" = 0 ] || probe_fail "$empty of $checked sampled photos are empty in the $where (e.g. $first)"
probe_ok                                                                    # 7

probe_pass 7 "${PROBE_BACKUP##*/}: $restored photos, $users users, ${albums:-0} albums, $checked files found in the $where"
