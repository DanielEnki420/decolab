#!/usr/bin/env bash
# verify-backup.sh - is last night's backup complete and readable?
#
# Runs at 03:30, after backup.sh, and trusts nothing backup.sh said: it reads
# every archive back by itself. Reports to its Uptime Kuma push monitor
# (VERIFY) on success too, so the monitor turns red by itself if this check
# stops running.
#
# Checked in the newest complete backup (BACKUP_DIR/YYYY-MM-DD_HH-MM):
#   - it is at most 26 hours old, and no newer run ended incomplete
#   - every expected archive exists for the modules switched on
#   - every archive can be read and holds its core file: a valid archive
#     without its core file is exactly how the original system kept a
#     worthless Vaultwarden backup for nine days without noticing
#   - the Immich dump has its end mark and the asset table
#   - config.tar.gz holds decolab.conf and EVERY file that is in
#     SECRETS_DIR now
#   - nothing in the backup is readable by other users
# Folders that do not belong in BACKUP_DIR are reported: the original once
# checked a helper folder named "duckdns-..." (it sorted after the dates)
# and reported every file missing while the backup was fine next to it.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init

errors=""
err() {
  errors="$errors- $1
"
}
pattern=$DECOLAB_BACKUP_PATTERN

latest=$(backup_latest)
newest_incomplete=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "$pattern-incomplete" 2>/dev/null | sort | tail -1)
foreign=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 ! -name "$pattern" ! -name "$pattern-incomplete" \
  2>/dev/null | sed 's#.*/##' | sort | tr '\n' ' ')
[ -z "$foreign" ] || err "does not belong in $BACKUP_DIR: $foreign(a .partial-* folder means a backup is still running or was killed)"

# archive_has ARCHIVE PATH... - every PATH is a member of the archive
archive_has() {
  local archive=$1 listing p
  shift
  listing=$(tar -tzf "$archive" 2>/dev/null) || {
    err "UNREADABLE: ${archive##*/}"
    return
  }
  for p in "$@"; do
    case $'\n'$listing$'\n' in
      *$'\n'"$p"$'\n'* | *$'\n'"./$p"$'\n'*) ;;
      *) err "INCOMPLETE: ${archive##*/} has no $p" ;;
    esac
  done
}

if [ -z "$latest" ]; then
  err "no complete backup in $BACKUP_DIR"
else
  name=${latest##*/}
  log "checking $name"
  if [ -n "$newest_incomplete" ] && [ "${newest_incomplete##*/}" \> "$name" ]; then
    err "the newest run ${newest_incomplete##*/} ended with errors (see backup.log)"
  fi
  age_h=$(backup_age_h "$latest")
  [ "$age_h" -le 26 ] || err "the newest complete backup is $age_h hours old"

  expect="pihole portainer config"
  is_yes MODULE_VAULTWARDEN && expect="$expect vaultwarden"
  is_yes MODULE_UPTIME_KUMA && expect="$expect uptime-kuma"
  for a in $expect; do
    f=$latest/$a.tar.gz
    if [ ! -s "$f" ]; then
      err "MISSING: $a.tar.gz"
      continue
    fi
    case $a in
      pihole) archive_has "$f" pihole/gravity.db pihole/pihole.toml ;;
      portainer) archive_has "$f" portainer/portainer.db ;;
      vaultwarden) archive_has "$f" vaultwarden/db.sqlite3 vaultwarden/rsa_key.pem ;;
      uptime-kuma) archive_has "$f" uptime-kuma/kuma.db ;;
      config)
        # shellcheck disable=SC2046 # file names in SECRETS_DIR have no spaces (install.sh)
        archive_has "$f" config/decolab.conf $(find "$SECRETS_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null |
          sed 's#.*/#config/secrets/#' | sort)
        ;;
    esac
  done

  if is_yes MODULE_IMMICH; then
    f=$latest/immich-db.sql.gz
    if [ ! -s "$f" ]; then
      err "MISSING: immich-db.sql.gz"
    elif ! gzip -t "$f" 2>/dev/null; then
      err "DAMAGED: immich-db.sql.gz"
    else
      verdict=$(gzip -dc "$f" | awk '
        /^COPY public\.asset / { asset = 1 }
        /PostgreSQL database dump complete/ { mark = NR }
        END { if (!mark || NR - mark > 10) print "no end mark"; else if (!asset) print "no asset table"; else print "ok" }')
      [ "$verdict" = ok ] || err "INCOMPLETE: immich-db.sql.gz ($verdict)"
    fi
  fi

  open=$(find "$latest" -perm -004 2>/dev/null | head -3 | tr '\n' ' ')
  [ -z "$open" ] || err "readable by every user (the backup holds every secret): $open"
fi

if [ -n "$errors" ]; then
  notify "🚨 Backup check" "$errors"
  kuma_push VERIFY down "$(printf '%s' "$errors" | tr '\n' ' ')"
  log "FAILED: $(printf '%s' "$errors" | tr '\n' ' ')"
  exit 1
fi
summary="$(find "$latest" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') archives complete and readable (${latest##*/}, ${age_h} h old)"
kuma_push VERIFY up "$summary" || exit 1
log "OK: $summary"
