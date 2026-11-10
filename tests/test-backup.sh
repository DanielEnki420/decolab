#!/usr/bin/env bash
# Contract tests for the backup chain: backup.sh, verify-backup.sh,
# backup-usb.sh, backup-offsite.sh, check-restic-integrity.sh. The services'
# data are small real directories with real SQLite databases; docker, restic
# and curl are fakes (tests/script-env.sh).
# Single quotes around $… are intended: the fakes evaluate them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

data=$t_tmp/data backups=$t_tmp/data/backups
export BACKUP_LOCK_WAIT_S=1

sql() { python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit(); c.close()' "$@"; }

make_data() {
  rm -rf "$data/pihole" "$data/vaultwarden" "$data/uptime-kuma" "$data/portainer"
  mkdir -p "$data/pihole/listsCache" "$data/pihole/gravity_backups" "$data/vaultwarden/attachments" \
    "$data/vaultwarden/icon_cache" "$data/uptime-kuma/upload" "$data/portainer"
  sql "$data/pihole/gravity.db" "CREATE TABLE adlist(address TEXT); INSERT INTO adlist VALUES('https://lists.example/hosts');"
  sql "$data/pihole/pihole-FTL.db" "CREATE TABLE queries(domain TEXT); INSERT INTO queries VALUES('private.example');"
  echo '[dns]' >"$data/pihole/pihole.toml"
  echo cache >"$data/pihole/listsCache/list.1"
  echo old >"$data/pihole/gravity_old.db"
  sql "$data/vaultwarden/db.sqlite3" "PRAGMA journal_mode=WAL; CREATE TABLE users(email TEXT); INSERT INTO users VALUES('a@example.org');"
  echo key >"$data/vaultwarden/rsa_key.pem"
  echo file >"$data/vaultwarden/attachments/1"
  echo icon >"$data/vaultwarden/icon_cache/x.png"
  sql "$data/uptime-kuma/kuma.db" "PRAGMA journal_mode=WAL; CREATE TABLE monitor(name TEXT); INSERT INTO monitor VALUES('BACKUP');"
  echo bolt >"$data/portainer/portainer.db"
}
make_data
printf 'DB_USERNAME=postgres\nDB_DATABASE_NAME=immich\nDB_PASSWORD=x\n' >"$t_tmp/secrets/immich.env"
chmod 600 "$t_tmp/secrets/immich.env"
dump='-- PostgreSQL database dump
COPY public.asset (id) FROM stdin;
1
\.
--
-- PostgreSQL database dump complete
--
'
export DUMP=$dump FAKE_DOCKER='case "$*" in *pg_dump*) printf "%s" "$DUMP" ;; esac'

latest() { find "$backups" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1; }
members() { tar -tzf "$(latest)/$1"; }

echo "sqlite snapshot"
snapshot() { python3 -I "$t_root/lib/sqlite_snapshot.py" "$@"; }
hold() { # DB SECONDS - another process keeps a write lock
  python3 -I -c 'import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("BEGIN EXCLUSIVE")
open(sys.argv[1] + ".held", "w").close()
time.sleep(float(sys.argv[2]))
c.execute("COMMIT")' "$1" "$2" &
  while [ ! -e "$1.held" ]; do sleep 0.05; done
}
# WAL databases (Vaultwarden, Kuma) never block a reader; gravity.db uses a
# rollback journal, and Pi-hole's weekly list update locks it.
g=$data/pihole/gravity.db
hold "$data/uptime-kuma/kuma.db" 2
check "a WAL database is copied while it is written" 0 "" -- snapshot "$data/uptime-kuma/kuma.db" "$t_tmp/snap0.db"
wait
hold "$g" 1
check "waits for a short write lock" 0 "" -- snapshot "$g" "$t_tmp/snap1.db"
wait
rm -f "$g.held"
hold "$g" 4
check "gives up on a lock that stays, loudly" 1 "still locked after 1 s" -- env SQLITE_SNAPSHOT_TIMEOUT_S=1 SQLITE_SNAPSHOT_PAUSE_S=0.1 python3 -I "$t_root/lib/sqlite_snapshot.py" "$g" "$t_tmp/snap2.db"
check "  ... and leaves no half copy" 1 "" -- test -e "$t_tmp/snap2.db"
wait
rm -f "$g.held" "$data/uptime-kuma/kuma.db.held"
python3 -I - "$t_tmp/bad.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE t(a TEXT)")
c.execute("CREATE INDEX i ON t(a)")
c.executemany("INSERT INTO t VALUES(?)", [("row%05d" % i,) for i in range(3000)])
c.commit()
c.close()
f = open(sys.argv[1], "r+b")
pages = f.seek(0, 2) // 4096
f.seek(4096 * (pages - 2) + 200)
f.write(b"\xff" * 300)  # garbage in a real page: the copy is faithful, and damaged
f.close()
PY
check "a damaged database fails, with a short reason" 1 "integrity_check of the copy" -- snapshot "$t_tmp/bad.db" "$t_tmp/snap4.db"
same "  ... the reason fits a message" "$(snapshot "$t_tmp/bad.db" "$t_tmp/snap4.db" 2>&1 | wc -l | tr -d ' ')" "1"
check "  ... and no copy is left" 1 "" -- test -e "$t_tmp/snap4.db"
check "never creates a missing database" 1 "does not exist" -- snapshot "$t_tmp/none.db" "$t_tmp/snap3.db"
check "  ... at the source either" 1 "" -- test -e "$t_tmp/none.db"

echo "backup.sh"
export BACKUP_STAMP=2026-11-01_03-00
check "a healthy system: up" 0 "OK: 6 archives" -- script backup.sh
same "  Kuma got up" "$(kuma BACKUP | cut -d' ' -f1)" "up"
b=$(latest)
case ${b##*/} in *-incomplete | .partial*) t_fail "  folder is complete" "${b##*/}" ;; *) t_ok "  folder is complete" ;; esac
check "  pihole: gravity.db is in" 0 "pihole/gravity.db" -- members pihole.tar.gz
check "  pihole: no query history, no caches" 1 "" -- bash -c 'tar -tzf "$1" | grep -E "pihole-FTL|listsCache|gravity_old|gravity_backups"' _ "$b/pihole.tar.gz"
check "  vaultwarden: database, key, attachments" 0 "vaultwarden/attachments/1" -- members vaultwarden.tar.gz
check "  vaultwarden: no icon cache, no -wal" 1 "" -- bash -c 'tar -tzf "$1" | grep -E "icon_cache|db.sqlite3-"' _ "$b/vaultwarden.tar.gz"
check "  kuma database" 0 "uptime-kuma/kuma.db" -- members uptime-kuma.tar.gz
check "  config holds decolab.conf and the secrets" 0 "config/secrets/kuma-push.env" -- members config.tar.gz
mkdir -p "$t_tmp/out" && tar -xzf "$b/vaultwarden.tar.gz" -C "$t_tmp/out"
check "  the copied database has the data" 0 "a@example.org" -- python3 -I -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("select email from users").fetchone()[0])' "$t_tmp/out/vaultwarden/db.sqlite3"
same "  everything private to the user" "$(find "$backups" -perm -004 | wc -l | tr -d ' ')" "0"
check "  immich dump" 0 "" -- test -s "$b/immich-db.sql.gz"
same "  no partial folder left" "$(find "$backups" -name '.partial*' | wc -l | tr -d ' ')" "0"

export BACKUP_STAMP=2026-11-02_03-00
export DUMP='-- PostgreSQL database dump
COPY public.asset (id) FROM stdin;
1
'
check "a cut-off dump: down, folder incomplete" 1 "immich: the dump has no end mark" -- script backup.sh
same "  Kuma got down" "$(kuma BACKUP | cut -d' ' -f1)" "down"
check "  ... and a message" 0 "dump has no end mark" -- telegrams
check "  the folder is marked incomplete" 0 "" -- bash -c 'ls -d "$1"/*-incomplete' _ "$backups"
export DUMP=$dump

export BACKUP_STAMP=2026-11-03_03-00
mv "$data/vaultwarden" "$data/vaultwarden.away"
check "a missing source is an error, not a smaller backup" 1 "vaultwarden: $data/vaultwarden is missing" -- script backup.sh
mv "$data/vaultwarden.away" "$data/vaultwarden"

export BACKUP_STAMP=2026-11-03_03-01
printf 'not a database' >"$data/uptime-kuma/kuma.db"
check "a broken database is an error" 1 "uptime-kuma: consistent copy of kuma.db failed" -- script backup.sh
make_data

export BACKUP_STAMP=2026-11-03_03-02
rm "$data/portainer/portainer.db"
check "an archive without its core file is an error" 1 "portainer: archive is readable but has no portainer/portainer.db" -- script backup.sh
make_data

echo "  locking and rotation"
export FAKE_FLOCK_BUSY=1
check "another heavy job holds the lock: down, no folder" 1 "held the lock for too long" -- script backup.sh
unset FAKE_FLOCK_BUSY
mkdir -p "$backups/.partial-2026-01-01_03-00"
for d in 2026-01-0{1,2,3,4,5,6,7,8,9}_03-00; do mkdir -p "$backups/$d"; done
export BACKUP_STAMP=2026-11-04_03-00
sed 's/^BACKUP_KEEP_DAYS=.*/BACKUP_KEEP_DAYS=3/' "$DECOLAB_CONF" >"$t_tmp/keep3.conf"
check "rotation keeps the newest by count" 0 "OK:" -- env DECOLAB_CONF="$t_tmp/keep3.conf" "$t_root/scripts/backup.sh"
same "  three complete backups left" "$(find "$backups" -mindepth 1 -maxdepth 1 -type d -name '20*_[0-9][0-9]-[0-9][0-9]' | wc -l | tr -d ' ')" "3"
check "  the new one is among them" 0 "" -- test -d "$(latest)"
same "  the killed run was removed" "$(find "$backups" -name '.partial*' | wc -l | tr -d ' ')" "0"
check "  incomplete ones stay for inspection" 0 "" -- bash -c 'ls -d "$1"/*-incomplete' _ "$backups"
check "as root it refuses" 1 "not as root" -- env FAKE_ID_U=0 bash -c 'id() { [ "$1" = -u ] && echo "$FAKE_ID_U" || command id "$@"; }; export -f id; "$1"' _ "$t_root/scripts/backup.sh"

echo "verify-backup.sh"
rm -rf "$backups"
now_stamp=$(date +%Y-%m-%d_%H-%M)
BACKUP_STAMP=$now_stamp script backup.sh >/dev/null
check "a fresh complete backup: up" 0 "OK: 6 archives complete and readable" -- script verify-backup.sh
same "  Kuma got up" "$(kuma VERIFY | cut -d' ' -f1)" "up"
b=$backups/$now_stamp
cp "$b/vaultwarden.tar.gz" "$t_tmp/vw.keep"
mkdir -p "$t_tmp/vwx/vaultwarden" && echo x >"$t_tmp/vwx/vaultwarden/rsa_key.pem"
tar -C "$t_tmp/vwx" -czf "$b/vaultwarden.tar.gz" vaultwarden && chmod 600 "$b/vaultwarden.tar.gz"
check "a valid archive without its database: down" 1 "vaultwarden.tar.gz has no vaultwarden/db.sqlite3" -- script verify-backup.sh
same "  Kuma got down" "$(kuma VERIFY | cut -d' ' -f1)" "down"
check "  ... and a message" 0 "has no vaultwarden/db.sqlite3" -- telegrams
printf 'garbage' >"$b/vaultwarden.tar.gz"
check "a damaged archive: down" 1 "UNREADABLE: vaultwarden.tar.gz" -- script verify-backup.sh
cp "$t_tmp/vw.keep" "$b/vaultwarden.tar.gz"
rm "$b/uptime-kuma.tar.gz"
check "a missing archive: down" 1 "MISSING: uptime-kuma.tar.gz" -- script verify-backup.sh
sed 's/^MODULE_UPTIME_KUMA=.*/MODULE_UPTIME_KUMA=no/' "$DECOLAB_CONF" >"$t_tmp/nokuma.conf"
check "  ... not expected when the module is off" 0 "OK:" -- env DECOLAB_CONF="$t_tmp/nokuma.conf" "$t_root/scripts/verify-backup.sh"
check "a second run in the same minute refuses" 1 "exists" -- env BACKUP_STAMP="$now_stamp" "$t_root/scripts/backup.sh"
rm -rf "$b" && BACKUP_STAMP=$now_stamp script backup.sh >/dev/null
printf 'NEW=1\n' >"$t_tmp/secrets/new.env" && chmod 600 "$t_tmp/secrets/new.env"
check "a secret that is not in the backup: down" 1 "config.tar.gz has no config/secrets/new.env" -- script verify-backup.sh
rm "$t_tmp/secrets/new.env"
chmod 644 "$b/config.tar.gz"
check "readable by everyone: down" 1 "readable by every user" -- script verify-backup.sh
chmod 600 "$b/config.tar.gz"
mkdir "$backups/duckdns-cleanup"
check "a foreign folder is reported" 1 "does not belong in $backups: duckdns-cleanup" -- script verify-backup.sh
rmdir "$backups/duckdns-cleanup"
mkdir "$backups/2099-01-01_03-00-incomplete"
check "a newer incomplete run: down" 1 "2099-01-01_03-00-incomplete ended with errors" -- script verify-backup.sh
rmdir "$backups/2099-01-01_03-00-incomplete"
old=$(python3 -I -c 'import datetime; print((datetime.datetime.now() - datetime.timedelta(hours=27)).strftime("%Y-%m-%d_%H-%M"))')
mv "$b" "$backups/$old"
check "older than 26 hours: down" 1 "is 27 hours old" -- script verify-backup.sh
rm -rf "$backups"
check "no backup at all: down" 1 "no complete backup" -- script verify-backup.sh

echo "backup-usb.sh"
usb=$t_tmp/usb
sed "s#^USB_BACKUP_DIR=.*#USB_BACKUP_DIR=$usb#" "$DECOLAB_CONF" >"$t_tmp/usb.conf"
usb_run() { env DECOLAB_CONF="$t_tmp/usb.conf" DECOLAB_TEST_SAME_DEVICE=1 "$@" "$t_root/scripts/backup-usb.sh" </dev/null; } # [VAR=value...]
: >"$FAKE_CURL_LOG"
check "switched off: quiet" 0 "USB copy is off" -- script backup-usb.sh
same "  ... no push" "$(kuma USB)" ""
mkdir -p "$usb"
check "no marker (disk not mounted): down, nothing written" 1 "disk not plugged in or not mounted" -- usb_run
check "  ... nothing written" 1 "" -- test -e "$usb/daily"
touch "$usb/.decolab-usb-backup"
check "same file system as the backup: down" 1 "same file system" -- usb_run DECOLAB_TEST_SAME_DEVICE=0
BACKUP_STAMP=$now_stamp script backup.sh >/dev/null
mkdir -p "$data/nas" "$data/immich/library/upload/u1" "$data/immich/library/profile" "$data/immich/library/thumbs"
echo photo >"$data/immich/library/upload/u1/a.jpg"
echo doc >"$data/nas/doc.txt"
echo thumb >"$data/immich/library/thumbs/t.webp"
if rsync --version 2>/dev/null | grep -q 'version 3'; then
  check "a real copy: up" 0 "OK: copy up to date" -- usb_run
  same "  Kuma got up" "$(kuma USB | cut -d' ' -f1)" "up"
  check "  the nightly backup is there" 0 "" -- test -s "$usb/daily/$now_stamp/config.tar.gz"
  check "  photos and the share are there" 0 "" -- test -s "$usb/immich/upload/u1/a.jpg" -a -s "$usb/nas/doc.txt"
  check "  no thumbnails" 1 "" -- test -e "$usb/immich/thumbs"
  rm "$data/nas/doc.txt"
  echo doc2 >"$data/nas/other.txt"
  check "a deleted file is mirrored" 0 "OK:" -- usb_run
  check "  ... gone from the mirror" 1 "" -- test -e "$usb/nas/doc.txt"
  check "  ... but kept in deleted/" 0 "doc" -- bash -c 'cat "$1"/deleted/*/nas/doc.txt' _ "$usb"
else
  echo "  note: no rsync 3 here (macOS has openrsync), real copies are tested on Linux"
  rs=$t_tmp/rsync-fake
  mkdir -p "$rs" && printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/rsync.log"\n' "$t_tmp" >"$rs/rsync" && chmod +x "$rs/rsync"
  check "copies (arguments only): up" 0 "OK: copy up to date" -- usb_run PATH="$rs:$PATH"
  check "  nightly backups without --delete, without killed runs" 0 "" -- grep -x -- "-a --exclude=.partial-\* $backups/ $usb/daily/" "$t_tmp/rsync.log"
  check "  the share with --delete and a backup dir" 0 "" -- grep -E -- "^-a --delete --backup --backup-dir=$usb/deleted/[0-9_-]+/nas $data/nas/ $usb/nas/$" "$t_tmp/rsync.log"
  check "  photos, not thumbnails" 1 "" -- grep -E "thumbs|encoded-video" "$t_tmp/rsync.log"
fi
mkdir -p "$usb/nas" && echo keep >"$usb/nas/keep.txt"
rm -rf "$data/nas" && mkdir -p "$data/nas"
check "an empty source never empties the mirror" 1 "nas: $data/nas is EMPTY but the copy is not" -- usb_run PATH="${rs:-/nonexistent}:$PATH"
check "  ... the copy is still there" 0 "keep" -- cat "$usb/nas/keep.txt"
mkdir -p "$t_tmp/hostdir" && echo x >"$t_tmp/hostdir/file"
rm -rf "$data/nas" && ln -s "$t_tmp/hostdir" "$data/nas"
: >"$t_tmp/rsync.log"
check "a source swapped for a link is not followed" 1 "nas: $data/nas is a link, not a folder: not copied" -- usb_run PATH="${rs:-/nonexistent}:$PATH"
check "  ... rsync never got it" 1 "" -- grep -qF -- " $data/nas/ " "$t_tmp/rsync.log"
rm -f "$data/nas" && mkdir -p "$data/nas"

echo "backup-offsite.sh"
sed 's#^RESTIC_REPOSITORY=.*#RESTIC_REPOSITORY=sftp:backup@storage.example.com:/decolab#' "$DECOLAB_CONF" >"$t_tmp/restic.conf"
export FAKE_RESTIC_LOG=$t_tmp/restic.log OFFSITE_PAUSE_S=0
off_run() { env DECOLAB_CONF="$t_tmp/restic.conf" "$@" "$t_root/scripts/backup-offsite.sh" </dev/null; } # [VAR=value...]
# restic: backup fails BACKUP_FAILS times, the rest as told
restic_says() {
  export FAKE_RESTIC='case $1 in
    backup) [ -z "${BACKUP_RC:-}" ] || exit "$BACKUP_RC"
      n=$(grep -c "^backup" "$FAKE_RESTIC_LOG"); [ "$n" -gt "${BACKUP_FAILS:-0}" ] || exit 1 ;;
    forget) exit "${FORGET_RC:-0}" ;;
    snapshots) one="[{\"time\":\"2026-11-04T04:10:00Z\"}]"; printf "%s" "${SNAPSHOTS-$one}" ;;
    dump) if [ -n "${DUMP_WRONG:-}" ]; then echo other; else cat "$5"; fi ;;
    check) printf "%s\n" "${CHECK_OUT-no errors were found}"; exit "${CHECK_RC:-0}" ;;
  esac'
}
restic_says
: >"$FAKE_CURL_LOG"
check "switched off: quiet" 0 "off-site backup is off" -- script backup-offsite.sh
same "  ... no push" "$(kuma OFFSITE)" ""
check "no restic password: down" 1 "restic password" -- off_run
printf 'pw\n' >"$t_tmp/secrets/restic-password" && chmod 600 "$t_tmp/secrets/restic-password"
rm -rf "$data/nas" && mkdir -p "$data/nas" && echo doc >"$data/nas/doc.txt"
: >"$FAKE_RESTIC_LOG"
check "a good run: up" 0 "OK: snapshot of $now_stamp" -- off_run
same "  Kuma got up" "$(kuma OFFSITE | cut -d' ' -f1)" "up"
check "  the consistent local backup, photos and share" 0 "" -- grep -x -- "backup --tag decolab --exclude-caches $backups/$now_stamp $data/immich/library/upload $data/immich/library/profile $data/nas" "$FAKE_RESTIC_LOG"
check "  never a live database directory" 1 "" -- grep -E "^backup .*($data/pihole|$data/vaultwarden|$data/uptime-kuma|immich/postgres|thumbs)" "$FAKE_RESTIC_LOG"
# --group-by host,tags: restic groups by host,paths by default, so a changed
# folder list starts a new group and the old one never expires
check "  retention, grouped by host and tag (not by folder list)" 0 "" -- grep -x -- "forget --tag decolab --group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune" "$FAKE_RESTIC_LOG"
: >"$FAKE_RESTIC_LOG"
check "two failed attempts, the third works: up" 0 "attempt 3 of 3" -- off_run BACKUP_FAILS=2
: >"$FAKE_RESTIC_LOG"
check "three failed attempts: down" 1 "restic backup failed 3 times" -- off_run BACKUP_FAILS=3
check "  ... and a message" 0 "failed 3 times" -- telegrams
: >"$FAKE_RESTIC_LOG"
check "no repository (restic rc 10): down, says restic init" 1 "create it once with restic init" -- off_run BACKUP_RC=10
same "  ... at once, without more attempts" "$(grep -c "^backup" "$FAKE_RESTIC_LOG")" 1
check "forget/prune fails: down" 1 "forget/prune failed" -- off_run FORGET_RC=1
check "no snapshot afterwards: down" 1 "no snapshot can be found" -- off_run SNAPSHOTS='[]'
check "read-back differs: down" 1 "read-back failed" -- off_run DUMP_WRONG=1
mv "$backups" "$backups.away"
check "no complete local backup: down" 1 "no complete local backup" -- off_run
mv "$backups.away" "$backups"

echo "check-restic-integrity.sh"
chk_run() { env DECOLAB_CONF="$t_tmp/restic.conf" "$@" "$t_root/scripts/check-restic-integrity.sh" </dev/null; } # [VAR=value...]
check "switched off: quiet" 0 "off-site backup is off" -- script check-restic-integrity.sh
check "repository without errors: up" 0 "repository without errors: 1 snapshots, 5% of the data read back" -- chk_run
same "  Kuma got up" "$(kuma RESTIC | cut -d' ' -f1)" "up"
check "  reads data back, not only the structure" 0 "" -- grep -x -- "check --read-data-subset=5%" "$FAKE_RESTIC_LOG"
check "an empty repository is no success" 1 "NO snapshot tagged decolab" -- chk_run SNAPSHOTS='[]'
check "check fails: down" 1 "restic check rc=1" -- chk_run CHECK_RC=1 CHECK_OUT="pack 1a2b: not referenced"
check "rc 0 without the all-clear: down" 1 "without 'no errors were found'" -- chk_run CHECK_OUT="warning: something"
check "  ... and a message" 0 "without 'no errors were found'" -- telegrams

t_finish
