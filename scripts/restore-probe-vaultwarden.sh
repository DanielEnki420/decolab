#!/usr/bin/env bash
# restore-probe-vaultwarden.sh [--offsite] - does the backup become a
# working password vault?
#
# Every morning (05:50) from the newest local backup. With --offsite (root,
# Sundays 07:00, see restore-probe-vaultwarden-offsite.sh) from the newest
# restic snapshot: the copy you need when the disk is gone.
#
# Proves: the archive is intact, the database and the key are there, the
# schema is right, and Vaultwarden starts with the copy and reads it.
# Does NOT prove that the vault can be decrypted: that needs the users'
# master passwords, which are nowhere on this system and do not belong here.
#
# Identity, not trust: Vaultwarden shows almost nothing without a login.
# So the COPY gets client_kdf_iter set to a mark (111111), and
# /identity/accounts/prelogin of the probe must answer exactly that value.
# Production answers 600000; a fresh empty database answers the default.
# The probe runs with the admin page off (empty ADMIN_TOKEN) and sign-ups
# off: a daily container with a valid admin token is needless attack surface.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
# shellcheck source=lib/probe.sh
. "$decolab_root/lib/probe.sh"

if ! is_yes MODULE_VAULTWARDEN; then
  log "Vaultwarden is switched off"
  exit 0
fi
mark=111111
monitor=PROBE_VAULTWARDEN
[ "${1:-}" = --offsite ] && monitor=PROBE_VAULTWARDEN_OFFSITE
probe_init vaultwarden "$monitor" "${PROBE_PORT:-8599}"
[ "$PROBE_PORT" != 8500 ] || probe_fail "port 8500 belongs to production"

if [ "${1:-}" = --offsite ]; then
  # The newest snapshot's backup folder, fetched by restic into a private
  # temporary file (removed with the copy).
  [ -n "${RESTIC_REPOSITORY:-}" ] || {
    log "off-site backup is off (RESTIC_REPOSITORY empty)"
    exit 0
  }
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$SECRETS_DIR/restic-password}
  restic=${RESTIC_BIN:-restic}
  snaps=$("$restic" snapshots --tag decolab --latest 1 --json 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || probe_fail "restic snapshots failed (rc=$rc$([ "$rc" -eq 10 ] && echo ': the repository does not exist'))"
  path=$(printf '%s' "$snaps" | python3 -I -c 'import json, re, sys
for p in json.load(sys.stdin)[-1]["paths"]:
    if re.search(r"/20\d\d-\d\d-\d\d_\d\d-\d\d$", p):
        print(p)' 2>/dev/null)
  [ -n "$path" ] || probe_fail "the newest restic snapshot holds no backup folder"
  age=$(backup_age_h "$path")
  [ "${age:-999}" -le 26 ] || probe_fail "the newest off-site backup is ${age} h old"
  probe_tmp
  PROBE_BACKUP=$path PROBE_ARCHIVE=$PROBE_DIR/vaultwarden.tar.gz
  "$restic" dump --tag decolab latest "$path/vaultwarden.tar.gz" >"$PROBE_ARCHIVE" ||
    probe_fail "restic dump of $path/vaultwarden.tar.gz failed"
fi

probe_archive vaultwarden.tar.gz
probe_extract                                                               # 1
d=$PROBE_COPY/vaultwarden
db=$d/db.sqlite3
[ -s "$db" ] || probe_fail "db.sqlite3 is missing or empty"
# Without rsa_key.pem every session and token is invalid after a restore:
# the vault would open, but no device would stay signed in.
[ -s "$d/rsa_key.pem" ] || probe_fail "rsa_key.pem is missing: all sessions would be invalid after a restore"
probe_ok                                                                    # 2

integrity=$(probe_sql "$db" "PRAGMA integrity_check")
[ "$integrity" = ok ] || probe_fail "db.sqlite3 is damaged: ${integrity:-no answer}"
probe_ok                                                                    # 3
columns=$(probe_sql "$db" "SELECT group_concat(name) FROM pragma_table_info('users')")
for c in email client_kdf_iter akey; do
  case ",$columns," in *",$c,"*) ;; *) probe_fail "column $c missing in users (old schema?)" ;; esac
done
probe_ok                                                                    # 4
users=$(probe_sql "$db" "SELECT count(*) FROM users")
[ "${users:-0}" -ge 1 ] || probe_fail "the backup holds no user (Vaultwarden not set up yet?)"
entries=$(probe_sql "$db" "SELECT count(*) FROM ciphers")
probe_count_guard entries "${entries:-0}"
probe_ok                                                                    # 5

email=$(probe_sql "$db" "SELECT email FROM users LIMIT 1")
probe_sql "$db" "UPDATE users SET client_kdf_iter=$mark" >/dev/null || probe_fail "cannot set the mark in the copy"
[ "$(probe_sql "$db" "SELECT count(*) FROM users WHERE client_kdf_iter<>$mark")" = 0 ] ||
  probe_fail "the mark did not take in the copy"
probe_ok                                                                    # 6

probe_image vaultwarden
probe_run ${PROBE_USER:+--user "$PROBE_USER"} --cap-drop ALL --memory 256m \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 -p "127.0.0.1:$PROBE_PORT:80" -v "$d:/data" \
  -e ADMIN_TOKEN= -e SIGNUPS_ALLOWED=false -e "DOMAIN=http://localhost:$PROBE_PORT" "$PROBE_IMAGE"
probe_mounted /data                                                         # 7
# shellcheck disable=SC2329 # called by probe_wait
alive() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$PROBE_PORT/alive")" = 200 ]; }
probe_wait "${PROBE_WAIT_S:-120}" "answer on /alive" alive
probe_ok                                                                    # 8

answer=$(python3 -I -c 'import json, sys; print(json.dumps({"email": sys.argv[1]}))' "$email" | curl -s --fail -m 15 -X POST -H 'Content-Type: application/json' \
  --data-binary @- "http://127.0.0.1:$PROBE_PORT/identity/accounts/prelogin" |
  python3 -I -c 'import json, sys
try:
    print(json.load(sys.stdin).get("kdfIterations", ""))
except ValueError:
    print("")')
[ "$answer" = "$mark" ] ||
  probe_fail "prelogin answers '${answer:-nothing}' instead of the mark $mark: the probe does NOT read the restored copy"
probe_ok                                                                    # 9

# A failed schema migration shows up here, and only here.
bad=$(docker logs "$PROBE_NAME" 2>&1 | grep -ciE '\[error\]|panic|migration.*fail' || true)
[ "${bad:-0}" = 0 ] || probe_fail "$bad error lines in Vaultwarden's start log"
probe_ok                                                                    # 10

probe_pass 10 "${PROBE_BACKUP##*/}: $users users, $entries vault entries"
