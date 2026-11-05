#!/usr/bin/env bash
# backup.sh - nightly local backup into BACKUP_DIR/<YYYY-MM-DD_HH-MM>
#
# Runs at 03:00 as DECOLAB_USER, without root: every service keeps its data
# as this user (Pi-hole through PIHOLE_UID, the others through "user:").
# No container is stopped. SQLite databases are copied with SQLite's online
# backup (lib/sqlite_snapshot.py), Immich's Postgres with pg_dump; the rest
# of each directory is copied as it is.
#
#   pihole.tar.gz       DATA_DIR/pihole with a consistent gravity.db (block
#                       lists, allow and deny lists, groups, clients). NOT the
#                       query history pihole-FTL.db: large, the browsing of
#                       the whole household, and not needed for a working
#                       Pi-hole. A restore starts with an empty history.
#   vaultwarden.tar.gz  DATA_DIR/vaultwarden with a consistent db.sqlite3,
#                       rsa_key*, attachments, sends, config.json
#   uptime-kuma.tar.gz  DATA_DIR/uptime-kuma with a consistent kuma.db
#   portainer.tar.gz    DATA_DIR/portainer (BoltDB, copied live: settings
#                       only, low value)
#   immich-db.sql.gz    pg_dump of Immich's database. The photos are files:
#                       backup-usb.sh and backup-offsite.sh copy them.
#   config.tar.gz       decolab.conf and SECRETS_DIR
#
# The backup holds every secret: it is private to DECOLAB_USER (umask 077,
# BACKUP_DIR 0700).
#
# A run writes into .partial-<date> and renames it only at the end, so a run
# that was killed never looks like a backup. A run with errors becomes
# <date>-incomplete and is reported. Rotation keeps the newest
# BACKUP_KEEP_DAYS complete backups by COUNT, not by age: if backups stop
# working, nothing is deleted.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
umask 077

# Root would leave root-owned -wal/-shm files next to the live databases,
# and the services (running as DECOLAB_USER) could no longer open them.
[ "$(id -u)" != 0 ] || die "run backup.sh as $DECOLAB_USER, not as root"

errors=""
err() {
  errors="$errors- $1
"
  log "ERROR: $1"
}
finish() { # report and exit
  if [ -z "$errors" ]; then
    kuma_push BACKUP up "$1" || exit 1
    log "OK: $1"
    exit 0
  fi
  notify "🔴 Backup" "The backup had errors:
$errors"
  kuma_push BACKUP down "$(printf '%s' "$errors" | tr '\n' ' ')"
  log "FAILED: $(printf '%s' "$errors" | tr '\n' ' ')"
  exit 1
}

job_lock "${BACKUP_LOCK_WAIT_S:-1800}" || {
  err "another heavy job held the lock for too long: no backup tonight"
  finish ""
}
if ! mkdir -p "$BACKUP_DIR" || ! chmod 700 "$BACKUP_DIR"; then
  err "cannot create $BACKUP_DIR"
  finish ""
fi

# GNU tar ends with 1 when a file changed while it was read (live data):
# a warning. 2 is fatal. Other tars (macOS, tests) have only 1 for errors.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then gnu_tar=1; else gnu_tar=0; fi
tar_ok() { [ "$1" -eq 0 ] || { [ "$gnu_tar" = 1 ] && [ "$1" -eq 1 ]; }; }

for old in "$BACKUP_DIR"/.partial-*; do
  [ -d "$old" ] || continue
  warn "an earlier run was killed before it finished, removing ${old##*/}"
  rm -rf "$old"
done
# BACKUP_STAMP: tests only (several runs within one minute)
stamp=${BACKUP_STAMP:-$(date +%Y-%m-%d_%H-%M)}
work=$BACKUP_DIR/.partial-$stamp
if [ -e "$BACKUP_DIR/$stamp" ] || ! mkdir "$work"; then
  err "cannot start: $BACKUP_DIR/$stamp exists or $work cannot be created"
  finish ""
fi
log "backup started: $work"

# archive NAME SRC DB CORE [EXCLUDE...]
#   SRC      directory to back up; the archive holds it as NAME-of-SRC/...
#   DB       SQLite database inside SRC, copied consistently ("-": none)
#   CORE     path in the archive without which it is worthless
#   EXCLUDE  tar patterns left out (the live database is always left out)
archive() {
  local name=$1 src=$2 db=$3 core=$4
  shift 4
  local base parent tarfile snap rc listing
  if [ ! -d "$src" ]; then
    # A missing source must be an error: a renamed or unmounted directory
    # would otherwise silently drop out of every backup.
    err "$name: $src is missing, NOT backed up"
    return
  fi
  base=${src##*/} parent=${src%/*}
  tarfile=$work/$name.tar
  local excludes=() p
  for p in "$@"; do excludes+=("--exclude=$p"); done
  if [ "$db" != - ]; then
    excludes+=("--exclude=$base/$db" "--exclude=$base/$db-*")
  fi
  # ${a[@]+...}: bash 3.2 treats an empty array as unset under set -u
  tar -C "$parent" -cf "$tarfile" ${excludes[@]+"${excludes[@]}"} "$base"
  rc=$?
  tar_ok "$rc" || {
    err "$name: tar ended with $rc"
    return
  }
  if [ "$db" != - ]; then
    snap=$work/.snap-$name
    mkdir -p "$snap/$base/$(dirname "$db")"
    if ! python3 -I "$decolab_root/lib/sqlite_snapshot.py" "$src/$db" "$snap/$base/$db"; then
      err "$name: consistent copy of $db failed"
      return
    fi
    tar -C "$snap" -rf "$tarfile" "$base/$db" || {
      err "$name: adding $db to the archive failed"
      return
    }
    rm -rf "$snap"
  fi
  gzip "$tarfile" || {
    err "$name: gzip failed"
    return
  }
  # Read the archive back: a valid archive without its core file is the
  # failure that hid for nine days on the original system (an empty
  # Vaultwarden backup).
  listing=$(tar -tzf "$tarfile.gz" 2>&1) || {
    err "$name: archive cannot be read back"
    return
  }
  case $'\n'$listing$'\n' in
    *$'\n'"$core"$'\n'* | *$'\n'"./$core"$'\n'*) log "  ok $name ($(du -h "$tarfile.gz" | cut -f1))" ;;
    *) err "$name: archive is readable but has no $core" ;;
  esac
}

archive pihole "$DATA_DIR/pihole" gravity.db pihole/gravity.db \
  'pihole-FTL.db*' gravity_old.db 'gravity.db_temp*' gravity_backups listsCache
is_yes MODULE_VAULTWARDEN && archive vaultwarden "$DATA_DIR/vaultwarden" db.sqlite3 \
  vaultwarden/db.sqlite3 icon_cache tmp vaultwarden.log 'db_*.sqlite3'
is_yes MODULE_UPTIME_KUMA && archive uptime-kuma "$DATA_DIR/uptime-kuma" kuma.db \
  uptime-kuma/kuma.db 'kuma.db.bak*'
archive portainer "$DATA_DIR/portainer" - portainer/portainer.db

# Immich: no -t on docker exec (a terminal turns line ends into CRLF and
# breaks the dump). pipefail makes a failed pg_dump fail the pipeline; the
# end mark proves the dump was not cut off; the asset table proves it is
# not just an empty schema.
dump_immich() {
  local out=$work/immich-db.sql.gz verdict
  read_secrets "$SECRETS_DIR/immich.env" DB_USERNAME DB_DATABASE_NAME || {
    err "immich: cannot read immich.env"
    return
  }
  if ! timeout 3600 docker exec immich_postgres pg_dump --username="$DB_USERNAME" \
    --dbname="$DB_DATABASE_NAME" | gzip >"$out"; then
    rm -f "$out"
    err "immich: pg_dump failed"
    return
  fi
  verdict=$(gzip -dc "$out" | awk '
    /^COPY public\.asset / { asset = 1 }
    /PostgreSQL database dump complete/ { mark = NR }
    END {
      if (!mark || NR - mark > 10) print "the dump has no end mark (cut off?)"
      else if (!asset) print "the dump has no asset table (valid, but worthless)"
      else print "ok"
    }')
  if [ "$verdict" = ok ]; then
    log "  ok immich-db ($(du -h "$out" | cut -f1))"
  else
    err "immich: ${verdict:-the dump cannot be read}"
  fi
}
is_yes MODULE_IMMICH && dump_immich

# decolab.conf and the secrets: without them a restore starts from zero.
cfg=$work/.stage-config/config
if mkdir -p "$cfg" && cp -p "$DECOLAB_CONF" "$cfg/decolab.conf" && cp -Rp "$SECRETS_DIR" "$cfg/secrets" &&
  tar -C "$work/.stage-config" -czf "$work/config.tar.gz" config; then
  rm -rf "$work/.stage-config"
  log "  ok config"
else
  err "config: decolab.conf or $SECRETS_DIR could not be copied"
fi

final=$BACKUP_DIR/$stamp
[ -z "$errors" ] || final=$final-incomplete
if ! mv "$work" "$final"; then
  err "cannot rename $work to $final"
  finish ""
fi
size=$(du -sh "$final" | cut -f1)
log "backup written: $final ($size)"

# Rotation by count (names sort by date). A failed rm is reported: until
# 18.9.2026 the original reported "cleaned up" while rm failed on every file.
keep=${BACKUP_KEEP_DAYS:-7}
pattern=$DECOLAB_BACKUP_PATTERN
complete=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "$pattern" | sort)
n=$(printf '%s' "$complete" | grep -c . || true)
left=""
if [ "${n:-0}" -gt "$keep" ]; then
  left=$(printf '%s\n' "$complete" | head -n $((n - keep)) | while IFS= read -r d; do
    rm -rf "$d" 2>/dev/null
    [ ! -e "$d" ] || printf '%s ' "${d##*/}"
  done)
fi
# Incomplete runs are kept for inspection, then removed by age.
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "$pattern-incomplete" -mtime +"$keep" \
  -exec rm -rf {} + 2>/dev/null
[ -z "$left" ] || err "rotation: could not delete ${left}(permissions?)"

finish "$(find "$final" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') archives, $size, ${final##*/}"
