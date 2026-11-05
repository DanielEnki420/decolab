#!/usr/bin/env bash
# Contract tests for the restore probes (scripts/restore-probe-*.sh) and
# lib/probe.sh. The backup is made by the real backup.sh from small real
# data; docker and curl are fakes. The fake services answer from the copy
# the probe mounted, as the real ones would: a probe that mounted the wrong
# directory gets the wrong answer.
# Single quotes around $… are intended: the fakes evaluate them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

data=$t_tmp/data
export PROBE_STEP_S=1 PROBE_WAIT_S=3 RUN_ARGS=$t_tmp/run.args TMPDIR=$t_tmp/tmp
mkdir -p "$TMPDIR"
sql() { python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit(); c.close()' "$@"; }

make_data() {
  rm -rf "$data"
  mkdir -p "$data/pihole" "$data/vaultwarden" "$data/uptime-kuma" "$data/portainer" "$data/immich/library/upload/u1"
  # 1200 ad domains and one that is also on the allowlist (sorts first).
  python3 -I - "$data/pihole/gravity.db" <<'PYDATA'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("CREATE TABLE gravity(domain TEXT, adlist_id INT); CREATE TABLE domainlist(type INT, domain TEXT);"
                "INSERT INTO gravity VALUES ('aaa.allowed-tracker.example', 1); INSERT INTO domainlist VALUES (0, 'aaa.allowed-tracker.example');")
c.executemany("INSERT INTO gravity VALUES (?, 1)", [("ads%04d.tracker.example" % i,) for i in range(1200)])
c.commit()
PYDATA
  echo '[dns]' >"$data/pihole/pihole.toml"
  sql "$data/vaultwarden/db.sqlite3" "PRAGMA journal_mode=WAL;
    CREATE TABLE users(uuid TEXT, email TEXT, akey TEXT, client_kdf_iter INT);
    INSERT INTO users VALUES('u1', 'owner@example.org', 'key', 600000);
    CREATE TABLE ciphers(uuid TEXT);
    INSERT INTO ciphers VALUES('c1'), ('c2'), ('c3'), ('c4');"
  echo key >"$data/vaultwarden/rsa_key.pem"
  # A push monitor for every token of the scripts, one HTTP monitor, all
  # with the one notification.
  python3 -I - "$data/uptime-kuma/kuma.db" "$t_tmp/secrets/kuma-push.env" <<'PYDATA'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""CREATE TABLE monitor(id INTEGER PRIMARY KEY, name TEXT, type TEXT, push_token TEXT, active INT);
  CREATE TABLE notification(id INTEGER PRIMARY KEY, active INT); CREATE TABLE monitor_notification(monitor_id INT, notification_id INT);
  CREATE TABLE setting(id INTEGER PRIMARY KEY, key TEXT UNIQUE, value TEXT, type TEXT);
  INSERT INTO notification VALUES (1, 1); INSERT INTO monitor (name, type, active) VALUES ('Website', 'http', 1);""")
for line in open(sys.argv[2]):
    k, _, v = line.strip().partition("=")
    if k != "KUMA_BASE":
        c.execute("INSERT INTO monitor (name, type, push_token, active) VALUES (?, 'push', ?, 1)", (k, v))
c.execute("INSERT INTO monitor_notification SELECT id, 1 FROM monitor")
c.commit()
PYDATA
  echo bolt >"$data/portainer/portainer.db"
  echo jpeg-a >"$data/immich/library/upload/u1/a.jpg"
  echo jpeg-b >"$data/immich/library/upload/u1/b.jpg"
}
printf 'DB_USERNAME=postgres\nDB_DATABASE_NAME=immich\nDB_PASSWORD=x\n' >"$t_tmp/secrets/immich.env"
chmod 600 "$t_tmp/secrets/immich.env"
export DUMP='-- PostgreSQL database dump
COPY public.asset (id, "originalPath") FROM stdin;
a1	/data/upload/u1/a.jpg
a2	/data/upload/u1/b.jpg
a3	/mnt/external/c.jpg
\.
COPY public."user" (id) FROM stdin;
u1
\.
--
-- PostgreSQL database dump complete
--
'
backup_now() { BACKUP_STAMP=$(date +%Y-%m-%d_%H-%M) "$t_root/scripts/backup.sh" >/dev/null 2>&1 </dev/null || echo "backup failed" >&2; }
fresh_backup() { rm -rf "$data/backups"; backup_now; }

# Fake docker: remembers the last "run", knows the probe label only while
# that container exists, reports the mount source from the run's -v, and
# answers docker exec like the real services, from the mounted copy.
export RESTORED=$t_tmp/restored.sql DIG_COUNT=$t_tmp/dig.count
cat >"$t_tmp/fake-docker.sh" <<'FAKE'
# shellcheck shell=bash
src() { [ -s "$RUN_ARGS" ] && awk -v d="$1" 'p { n = split($0, a, ":"); if (a[2] == d) { print a[1]; exit } } { p = ($0 == "-v") }' "$RUN_ARGS"; }
q() { python3 -I -c 'import sqlite3, sys; r = sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone(); print("" if r is None else r[0])' "$@"; }
section() { awk -v t="COPY public.$1 (" 'index($0, t) == 1 { on = 1; next } on && $0 == "\\." { on = 0 } on' "$RESTORED"; }
case $1 in
  run)
    printf '%s\n' "$@" | tee "$RUN_ARGS.keep" >"$RUN_ARGS"
    # What was switched on in Kuma's copy at the moment it started?
    d=$(src /app/data)
    [ -z "$d" ] || q "$d/kuma.db" "SELECT (SELECT count(*) FROM monitor WHERE active = 1) + (SELECT count(*) FROM notification WHERE active = 1)" >"$RUN_ARGS.active"
    : >"$DIG_COUNT"
    echo cid ;;
  rm) : >"$RUN_ARGS" ;;
  image) exit 0 ;;
  logs) printf '%s\n' "${LOGS:-[INFO] Rocket has launched}" ;;
  inspect)
    case "$*" in
      *Config.Image*) echo "image-of-$4" ;;
      *Config.User*) echo "1000:1000" ;;
      *decolab.probe*) [ -s "$RUN_ARGS" ] || exit 1; sed -n 's/^decolab.probe=//p' "$RUN_ARGS" ;;
      *Mounts*) dest=$(printf '%s' "$*" | sed -n 's/.*Destination "\([^"]*\)".*/\1/p'); src "${MOUNT_DEST:-$dest}" ;;
      *State.Status*) echo "${STATE:-running}" ;;
    esac ;;
  exec)
    case "$*" in
      *pg_dump*) printf '%s' "$DUMP" ;;
      *api/entry-page*)
        v=${ANSWER-$(q "$(src /app/data)/kuma.db" "SELECT value FROM setting WHERE key = 'entryPage'")}
        printf '{"type":"entryPage","entryPage":%s}' "${v:-null}" ;;
      *" dig "*)
        # Like real dig: blank lines between the sections.
        dom=${*: -2:1} n=$(($(wc -l <"$DIG_COUNT") + 1))
        echo >>"$DIG_COUNT"
        if [ -n "${DIG:-}" ]; then
          st=${DIG%% *} a=${DIG#* }
        elif [ "$n" -gt "${DIG_LATE:-0}" ] && [ -n "$(q "$(src /etc/pihole)/gravity.db" "SELECT 1 FROM gravity WHERE domain = '$dom'")" ]; then
          if [ "${BLOCK_MODE:-null}" = nxdomain ]; then st=NXDOMAIN a=""; else st=NOERROR a=0.0.0.0; fi
        else
          st=REFUSED a=""
        fi
        printf '\n; <<>> DiG 9.20 <<>> @127.0.0.1 %s A\n;; global options: +cmd\n;; Got answer:\n;; ->>HEADER<<- opcode: QUERY, status: %s, id: 4711\n;; flags: qr rd ra; QUERY: 1\n\n;; QUESTION SECTION:\n;%s.\t\t\tIN\tA\n\n' "$dom" "$st" "$dom"
        [ -z "$a" ] || printf ';; ANSWER SECTION:\n%s.\t2\tIN\tA\t%s\n\n' "$dom" "$a"
        printf ';; Query time: 1 msec\n;; SERVER: 127.0.0.1#53(127.0.0.1) (UDP)\n\n' ;;
      # PG_INIT: the image's first start. A temporary server answers on the
      # socket at once; the real one (TCP) only from the third question on,
      # and whatever was loaded before is cut off by the restart.
      *pg_isready*)
        case "$*" in *"-h 127.0.0.1"*) echo >>"$DIG_COUNT"; [ -z "${PG_INIT:-}" ] || [ "$(wc -l <"$DIG_COUNT")" -ge 3 ] || exit 2 ;; esac
        exit "${PG_READY:-0}" ;;
      *ON_ERROR_STOP*)
        if [ -n "${PG_INIT:-}" ] && [ "$(wc -l <"$DIG_COUNT")" -lt 3 ]; then cat >/dev/null; echo "psql: error: server closed the connection unexpectedly"; exit 2; fi
        cat >"$RESTORED"; [ -z "${PSQL_ERRORS:-}" ] || printf '%s\n' "$PSQL_ERRORS"; exit "${PSQL_RC:-0}" ;;
      *psql*)
        sql=${*: -1}
        case $sql in
          *"count(*) FROM asset"*) echo "${RESTORED_ASSETS:-$(section asset | wc -l | tr -d ' ')}" ;;
          *'count(*) FROM "user"'*) section '"user"' | wc -l | tr -d ' ' ;;
          *"count(*) FROM album"*) section album | wc -l | tr -d ' ' ;;
          *originalPath*) section asset | cut -f2 | { case $sql in *"LIKE '/data/%'"*) grep '^/data/' ;; *) cat ;; esac; } | head -n "${sql##* }" ;;
        esac ;;
    esac ;;
esac
FAKE
export FAKE_DOCKER='. "$(dirname "$RUN_ARGS")/fake-docker.sh"'

echo "probe_sql"
python3 -I -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).execute("create table t(x)")' "$t_tmp/trust.db"
same "a database from a container gets no trusted schema" \
  "$(bash -c '. "$1/lib/common.sh"; . "$1/lib/probe.sh"; probe_sql "$2" "PRAGMA trusted_schema"' _ "$t_root" "$t_tmp/trust.db")" "0"

echo "restore-probe-vaultwarden.sh"
make_data
fresh_backup
# Fake Vaultwarden: /alive answers, prelogin returns client_kdf_iter from
# the database the probe mounted (or ANSWER, to play the wrong database).
export FAKE_CURL_MORE='case "$*" in
  *8599/alive*) echo 200 ;;
  *prelogin*) d=$(awk "p { split(\$0, a, \":\"); print a[1]; exit } { p = (\$0 == \"-v\") }" "$RUN_ARGS")
    k=${ANSWER:-$(python3 -I -c "import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute(\"select client_kdf_iter from users\").fetchone()[0])" "$d/db.sqlite3")}
    printf "{\"kdf\":0,\"kdfIterations\":%s}" "$k" ;;
  *) exit 7 ;;
esac'
check "a good backup becomes a vault: up" 0 "PASSED: " -- script restore-probe-vaultwarden.sh
same "  Kuma got up" "$(kuma PROBE_VAULTWARDEN | cut -d' ' -f1)" "up"
check "  ... 10 checks, the counts" 0 "1 users, 4 vault entries, 10 checks" -- kuma PROBE_VAULTWARDEN
check "  the container got the production image and user" 0 "" -- grep -x "image-of-vaultwarden" "$RUN_ARGS.keep"
check "  admin page off, sign-ups off, loopback port" 0 "" -- bash -c 'grep -x "ADMIN_TOKEN=" "$1" && grep -x "SIGNUPS_ALLOWED=false" "$1" && grep -x "127.0.0.1:8599:80" "$1"' _ "$RUN_ARGS.keep"
check "  the container was removed" 0 "" -- test ! -s "$RUN_ARGS"
same "  the copy was deleted" "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "  production data untouched (no mark)" 0 "600000" -- python3 -I -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("select client_kdf_iter from users").fetchone()[0])' "$data/vaultwarden/db.sqlite3"

check "the service answers with another database: down" 1 "does NOT read the restored copy" -- env ANSWER=600000 "$t_root/scripts/restore-probe-vaultwarden.sh"
same "  Kuma got down" "$(kuma PROBE_VAULTWARDEN | cut -d' ' -f1)" "down"
check "  ... and a message" 0 "does NOT read the restored copy" -- telegrams
check "errors in the start log: down" 1 "error lines" -- env LOGS="[ERROR] migration failed" "$t_root/scripts/restore-probe-vaultwarden.sh"
check "the container stops: down" 1 "the probe container stopped" -- env STATE=exited FAKE_CURL_MORE='exit 7' "$t_root/scripts/restore-probe-vaultwarden.sh"

sql "$data/vaultwarden/db.sqlite3" "DELETE FROM ciphers WHERE uuid <> 'c1';"
fresh_backup
check "entries drop from 4 to 1: down" 1 "entries dropped from 4 to 1" -- script restore-probe-vaultwarden.sh
make_data
rm "$data/vaultwarden/rsa_key.pem" && fresh_backup
check "a backup without the key: down" 1 "rsa_key.pem is missing" -- script restore-probe-vaultwarden.sh
make_data && fresh_backup
# "belongs to production" where 8500 is free; on a host where Vaultwarden
# runs, the general check ("port 8500 is taken") refuses it first.
check "a production port is refused" 1 "port 8500 " -- env PROBE_PORT=8500 "$t_root/scripts/restore-probe-vaultwarden.sh"
python3 -I -c 'import socket, time; s = socket.socket(); s.bind(("127.0.0.1", 8599)); s.listen(); time.sleep(4)' &
sleep 1
check "a taken port is refused" 1 "port 8599 is taken" -- script restore-probe-vaultwarden.sh
wait
mv "$data/backups" "$data/backups.away" && mkdir -p "$data/backups/2020-01-01_03-00"
check "an old backup is refused" 1 "h old" -- script restore-probe-vaultwarden.sh
rm -rf "$data/backups" && mv "$data/backups.away" "$data/backups"

echo "restore-probe-vaultwarden-offsite.sh"
make_data && fresh_backup
latest_dir=$(find "$data/backups" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)
sed 's#^RESTIC_REPOSITORY=.*#RESTIC_REPOSITORY=sftp:backup@storage.example.com:/decolab#' "$DECOLAB_CONF" >"$t_tmp/restic.conf"
printf 'pw\n' >"$t_tmp/secrets/restic-password" && chmod 600 "$t_tmp/secrets/restic-password"
export FAKE_RESTIC_LOG=$t_tmp/restic.log SNAP_DIR=$latest_dir
export FAKE_RESTIC='case $1 in
  snapshots) printf "[{\"time\":\"x\",\"paths\":[\"%s\",\"/mnt/data/nas\"]}]" "$SNAP_DIR" ;;
  dump) cat "$5" ;;
esac'
check "switched off: quiet" 0 "off-site backup is off" -- script restore-probe-vaultwarden-offsite.sh
check "the off-site copy becomes a vault: up" 0 "PASSED: ${latest_dir##*/}: 1 users" -- env DECOLAB_CONF="$t_tmp/restic.conf" "$t_root/scripts/restore-probe-vaultwarden-offsite.sh"
same "  its own Kuma monitor" "$(kuma PROBE_VAULTWARDEN_OFFSITE | cut -d' ' -f1)" "up"
check "  the archive came from restic" 0 "" -- grep -x "dump --tag decolab latest $latest_dir/vaultwarden.tar.gz" "$FAKE_RESTIC_LOG"
same "  nothing left behind" "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "restic gives a broken archive: down" 1 "cannot be read" -- env DECOLAB_CONF="$t_tmp/restic.conf" FAKE_RESTIC='case $1 in snapshots) printf "[{\"paths\":[\"%s\"]}]" "$SNAP_DIR" ;; dump) echo garbage ;; esac' "$t_root/scripts/restore-probe-vaultwarden-offsite.sh"
check "no repository (restic rc 10): down, says so" 1 "the repository does not exist" -- env DECOLAB_CONF="$t_tmp/restic.conf" FAKE_RESTIC='exit 10' "$t_root/scripts/restore-probe-vaultwarden-offsite.sh"
check "no snapshot at all: down" 1 "holds no backup folder" -- env DECOLAB_CONF="$t_tmp/restic.conf" FAKE_RESTIC='echo "[]"' "$t_root/scripts/restore-probe-vaultwarden-offsite.sh"
refute "  ... without a Python traceback" "Traceback"
check "a snapshot without a backup folder: down" 1 "holds no backup folder" -- env DECOLAB_CONF="$t_tmp/restic.conf" FAKE_RESTIC='echo "[{\"paths\":[\"/mnt/data/nas\"]}]"' "$t_root/scripts/restore-probe-vaultwarden-offsite.sh"

echo "restore-probe-kuma.sh"
make_data && fresh_backup
tokens=$(($(grep -c '^KUMA_' "$t_tmp/secrets/kuma-push.env") - 1))
monitors=$((tokens + 1))
# active monitors, active notifications, entry-page marks
kuma_state() { python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); print(*[c.execute(q).fetchone()[0] for q in ("select count(*) from monitor where active = 1", "select count(*) from notification where active = 1", "select count(*) from setting where key = \"entryPage\"")])' "$1"; }
check "a good backup becomes a watcher: up" 0 "PASSED: " -- script restore-probe-kuma.sh
check "  ... 9 checks, every token of the scripts" 0 "$monitors monitors, all $tokens push tokens of the scripts, 9 checks" -- kuma PROBE_KUMA
same "  every monitor and notification was off when it started" "$(cat "$RUN_ARGS.active")" "0"
check "  no network, no port, production image and user, SQLite" 0 "" -- bash -c 'grep -x -- --network "$1" && grep -x none "$1" && grep -x image-of-uptime-kuma "$1" && grep -x 1000:1000 "$1" && grep -x UPTIME_KUMA_DB_TYPE=sqlite "$1" && ! grep -x -- -p "$1"' _ "$RUN_ARGS.keep"
check "  the container was removed" 0 "" -- test ! -s "$RUN_ARGS"
same "  the copy was deleted" "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "0"
same "  production untouched (all on, no mark)" "$(kuma_state "$data/uptime-kuma/kuma.db")" "$monitors 1 0"
check "the service answers from another database: down" 1 "does NOT read the restored copy" -- env ANSWER='"decolab-probe-00000000"' "$t_root/scripts/restore-probe-kuma.sh"
same "  Kuma got down" "$(kuma PROBE_KUMA | cut -d' ' -f1)" "down"
check "a fresh database (no entry page): down" 1 "Kuma answers 'nothing' instead of the mark" -- env ANSWER=null "$t_root/scripts/restore-probe-kuma.sh"
check "Kuma never answers: down" 1 "still does not answer /api/entry-page" -- env ANSWER='<html>' "$t_root/scripts/restore-probe-kuma.sh"
cp -p "$t_tmp/secrets/kuma-push.env" "$t_tmp/kuma-push.env.good"
echo "KUMA_NEW_CHECK=tok_new" >>"$t_tmp/secrets/kuma-push.env"
check "a token of the scripts is not in the backup: down" 1 "push tokens of KUMA_NEW_CHECK are NOT in the backup" -- script restore-probe-kuma.sh
check "  ... and the token never reached Python's arguments" 0 "" -- bash -c '! grep -q tok_new "$1"' _ "$FAKE_DOCKER_LOG"
cp -p "$t_tmp/kuma-push.env.good" "$t_tmp/secrets/kuma-push.env"
sql "$data/uptime-kuma/kuma.db" "DELETE FROM monitor_notification WHERE monitor_id = 1;"
fresh_backup
check "an active monitor without a notification: down" 1 "1 active monitors without a notification" -- script restore-probe-kuma.sh
sed 's/^NOTIFY=.*/NOTIFY=none/' "$DECOLAB_CONF" >"$t_tmp/quiet.conf"
check "  ... does not matter without Telegram" 0 "PASSED" -- env DECOLAB_CONF="$t_tmp/quiet.conf" "$t_root/scripts/restore-probe-kuma.sh"
sql "$data/uptime-kuma/kuma.db" "DELETE FROM monitor WHERE type = 'push';"
fresh_backup
check "monitors drop to less than half: down" 1 "monitors dropped from $monitors to 1" -- script restore-probe-kuma.sh
sql "$data/uptime-kuma/kuma.db" "DELETE FROM monitor;"
fresh_backup
check "a backup without monitors: down" 1 "holds no monitor" -- script restore-probe-kuma.sh
sed 's/^MODULE_UPTIME_KUMA=.*/MODULE_UPTIME_KUMA=no/' "$DECOLAB_CONF" >"$t_tmp/nokuma.conf"
check "switched off: quiet" 0 "Uptime Kuma is switched off" -- env DECOLAB_CONF="$t_tmp/nokuma.conf" "$t_root/scripts/restore-probe-kuma.sh"

echo "restore-probe-pihole.sh"
make_data && fresh_backup
check "a good backup becomes a blocking DNS server: up" 0 "PASSED: " -- script restore-probe-pihole.sh
check "  ... the test domain from the backup, not from the allowlist" 0 "1201 domains, ads0000.tracker.example blocked, 7 checks" -- kuma PROBE_PIHOLE
check "  no network, no port, production image and capabilities" 0 "" -- bash -c 'grep -x none "$1" && grep -x image-of-pihole "$1" && grep -x SETFCAP "$1" && grep -x "PIHOLE_UID=$2" "$1" && ! grep -x -- -p "$1"' _ "$RUN_ARGS.keep" "$(id -u)"
check "  the container was removed" 0 "" -- test ! -s "$RUN_ARGS"
same "  the copy was deleted" "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "Pi-hole blocks only after it has read gravity: waits, up" 0 "PASSED" -- env DIG_LATE=2 "$t_root/scripts/restore-probe-pihole.sh"
check "NXDOMAIN blocking mode: up" 0 "PASSED" -- env BLOCK_MODE=nxdomain "$t_root/scripts/restore-probe-pihole.sh"
check "every name gets 0.0.0.0: down" 1 "the probe blocks everything" -- env DIG="NOERROR 0.0.0.0" "$t_root/scripts/restore-probe-pihole.sh"
check "nothing is blocked: down" 1 "still does not block ads0000.tracker.example from the backup (last answer: 'SERVFAIL ')" -- env DIG="SERVFAIL " "$t_root/scripts/restore-probe-pihole.sh"
same "  Kuma got down" "$(kuma PROBE_PIHOLE | cut -d' ' -f1)" "down"
check "the probe mounts something else: down" 1 "mounts 'nothing' at /etc/pihole" -- env MOUNT_DEST=/elsewhere "$t_root/scripts/restore-probe-pihole.sh"
sql "$data/pihole/gravity.db" "DELETE FROM gravity WHERE rowid > 599;"
fresh_backup
check "a blocklist of 599 domains: down" 1 "only 599 domains in the blocklist (at least 1000)" -- script restore-probe-pihole.sh
check "  ... below half of the last run, even with a low floor: down" 1 "domains dropped from 1201 to 599" -- env PROBE_MIN_DOMAINS=100 "$t_root/scripts/restore-probe-pihole.sh"
make_data
sql "$data/pihole/gravity.db" "INSERT INTO domainlist SELECT 0, domain FROM gravity;"
fresh_backup
check "every domain on the allowlist: down" 1 "no usable test domain" -- script restore-probe-pihole.sh
make_data
rm "$data/pihole/pihole.toml" && fresh_backup
check "a backup without pihole.toml: down" 1 "pihole.toml is missing" -- script restore-probe-pihole.sh

echo "restore-probe-immich.sh"
make_data && fresh_backup
check "a good dump becomes a photo library: up" 0 "PASSED: " -- script restore-probe-immich.sh
check "  ... the counts, and the files found in the library" 0 "3 photos, 1 users, 0 albums, 2 files found in the library, 7 checks" -- kuma PROBE_IMMICH
check "  no network, no bind mount, no port, production image, no password" 0 "" -- bash -c 'grep -x none "$1" && grep -x image-of-immich_postgres "$1" && grep -x POSTGRES_HOST_AUTH_METHOD=trust "$1" && grep -x POSTGRES_USER=postgres "$1" && ! grep -x -- -v "$1" && ! grep -x -- -p "$1"' _ "$RUN_ARGS.keep"
check "  the dump went into the probe database" 0 "" -- grep -x "a3	/mnt/external/c.jpg" "$RESTORED"
check "  the container was removed" 0 "" -- test ! -s "$RUN_ARGS"
same "  nothing left behind" "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "'already exists' while loading is fine" 0 "PASSED" -- env PSQL_ERRORS='psql:<stdin>:12: ERROR:  extension "vchord" already exists' "$t_root/scripts/restore-probe-immich.sh"
check "other errors while loading: down" 1 'reported errors: psql:<stdin>:40: ERROR:  relation "asset" does not exist' -- env PSQL_ERRORS='psql:<stdin>:40: ERROR:  relation "asset" does not exist' "$t_root/scripts/restore-probe-immich.sh"
check "loading is cut off: down" 1 "exit code 124" -- env PSQL_RC=124 "$t_root/scripts/restore-probe-immich.sh"
check "fewer photos restored than the dump lists: down" 1 "1 photos restored, the dump lists 3" -- env RESTORED_ASSETS=1 "$t_root/scripts/restore-probe-immich.sh"
check "the first start of the image (temporary server): waits for the real one, up" 0 "PASSED" -- env PG_INIT=1 "$t_root/scripts/restore-probe-immich.sh"
check "the database never accepts connections: down" 1 "still does not accept connections" -- env PG_READY=2 "$t_root/scripts/restore-probe-immich.sh"
same "  Kuma got down" "$(kuma PROBE_IMMICH | cut -d' ' -f1)" "down"
rm "$data/immich/library/upload/u1/b.jpg"
check "a photo missing in the library: down" 1 "1 of 2 sampled photos are missing in the library (e.g. /data/upload/u1/b.jpg)" -- script restore-probe-immich.sh
: >"$data/immich/library/upload/u1/b.jpg"
check "an empty photo: down" 1 "1 of 2 sampled photos are empty in the library" -- script restore-probe-immich.sh
sed "s#^USB_BACKUP_DIR=.*#USB_BACKUP_DIR=$t_tmp/usb#" "$DECOLAB_CONF" >"$t_tmp/usb.conf"
mkdir -p "$t_tmp/usb/immich/upload/u1" && echo a >"$t_tmp/usb/immich/upload/u1/a.jpg" && echo b >"$t_tmp/usb/immich/upload/u1/b.jpg"
check "with a USB disk configured but not mounted: down" 1 "the USB disk is not mounted" -- env DECOLAB_CONF="$t_tmp/usb.conf" "$t_root/scripts/restore-probe-immich.sh"
touch "$t_tmp/usb/.decolab-usb-backup"
check "  ... mounted: the files are looked for on it, up" 0 "2 files found in the USB copy" -- env DECOLAB_CONF="$t_tmp/usb.conf" "$t_root/scripts/restore-probe-immich.sh"
rm "$t_tmp/usb/immich/upload/u1/a.jpg"
check "  ... a photo missing on the USB disk: down" 1 "1 of 2 sampled photos are missing in the USB copy" -- env DECOLAB_CONF="$t_tmp/usb.conf" "$t_root/scripts/restore-probe-immich.sh"
make_data && fresh_backup
echo 10 >"$DECOLAB_STATE_DIR/probe-immich-assets"
check "photos drop to less than half: down" 1 "assets dropped from 10 to 3" -- script restore-probe-immich.sh
DUMP=$(printf '%s' "$DUMP" | grep -v '^a[0-9]	') fresh_backup
check "a dump without photos: down" 1 "the dump holds no photo" -- script restore-probe-immich.sh
make_data && fresh_backup
latest_dir=$(find "$data/backups" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)
echo garbage >"$latest_dir/immich-db.sql.gz"
check "a damaged dump: down" 1 "immich-db.sql.gz is damaged" -- script restore-probe-immich.sh
sed 's/^MODULE_IMMICH=.*/MODULE_IMMICH=no/' "$DECOLAB_CONF" >"$t_tmp/noimmich.conf"
check "switched off: quiet" 0 "Immich is switched off" -- env DECOLAB_CONF="$t_tmp/noimmich.conf" "$t_root/scripts/restore-probe-immich.sh"

t_finish
