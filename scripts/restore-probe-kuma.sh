#!/usr/bin/env bash
# restore-probe-kuma.sh - is the watcher itself restorable?
#
# Uptime Kuma is the most expensive rebuild of the system: not because of
# its size, but because of the push tokens. A token cannot be restored, only
# made anew, and then every script that uses it needs the new one. If Kuma
# is down, everything else is blind.
#
# Checks in the newest backup, before anything starts:
#   - kuma.db is intact and has monitors (no drop to less than half)
#   - EVERY token in SECRETS_DIR/kuma-push.env is a push monitor in it
#   - with NOTIFY set (not none): there is a notification, and no active monitor
#     is without one (a monitor that turns red and reaches nobody)
#
# The danger of starting it: a second Kuma would at once poll every monitor
# and send alerts. So every monitor AND every notification is switched off
# in the COPY first, and checked to be off, before the container starts;
# and the container gets no network at all (it is asked from inside, with
# docker exec): even a monitor that slipped through could reach nobody.
#
# Identity, not trust: the copy gets a random entry page set (setting
# "entryPage"); /api/entry-page of the probe must answer exactly that.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
# shellcheck source=lib/probe.sh
. "$decolab_root/lib/probe.sh"

if ! is_yes MODULE_UPTIME_KUMA; then
  log "Uptime Kuma is switched off"
  exit 0
fi
probe_init uptime-kuma PROBE_KUMA -
mark=decolab-probe-$(python3 -I -c 'import secrets; print(secrets.token_hex(4))')

probe_archive uptime-kuma.tar.gz
probe_extract                                                               # 1
d=$PROBE_COPY/uptime-kuma
db=$d/kuma.db
[ -s "$db" ] || probe_fail "kuma.db is missing or empty"
integrity=$(probe_sql "$db" "PRAGMA integrity_check")
[ "$integrity" = ok ] || probe_fail "kuma.db is damaged: ${integrity:-no answer}"
probe_ok                                                                    # 2

monitors=$(probe_sql "$db" "SELECT count(*) FROM monitor")
[ "${monitors:-0}" -ge 1 ] || probe_fail "the backup holds no monitor"
probe_count_guard monitors "$monitors"
probe_ok                                                                    # 3

# The tokens the scripts use, from kuma-push.env, go to Python on stdin:
# never as arguments (visible to every user).
env_file=${KUMA_ENV_FILE:-$SECRETS_DIR/kuma-push.env}
keys=$(sed -n 's/^\(KUMA_[A-Z0-9_]*\)=.*/\1/p' "$env_file" 2>/dev/null | grep -vx KUMA_BASE)
[ -n "$keys" ] || probe_fail "no push token in $env_file"
# shellcheck disable=SC2086 # key names: [A-Z0-9_] only
read_secrets "$env_file" $keys || probe_fail "cannot read $env_file"
missing=$(for k in $keys; do printf '%s %s\n' "$k" "${!k}"; done | python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
have = {r[0] for r in c.execute("SELECT push_token FROM monitor WHERE type = \"push\" AND push_token IS NOT NULL")}
print(" ".join(k for k, t in (l.split() for l in sys.stdin) if t not in have))' "$db") ||
  probe_fail "cannot compare the push tokens"
[ -z "$missing" ] || probe_fail "push tokens of $missing are NOT in the backup: these checks could not report after a restore"
tokens=$(printf '%s\n' "$keys" | wc -l | tr -d ' ')
probe_ok                                                                    # 4

if [ "$NOTIFY" != none ]; then
  n=$(probe_sql "$db" "SELECT count(*) FROM notification")
  [ "${n:-0}" -ge 1 ] || probe_fail "the backup holds no notification: Kuma could alert nobody"
  silent=$(probe_sql "$db" "SELECT count(*) FROM monitor m WHERE m.active = 1 AND NOT EXISTS
    (SELECT 1 FROM monitor_notification mn WHERE mn.monitor_id = m.id)")
  [ "${silent:-1}" = 0 ] || probe_fail "$silent active monitors without a notification in the backup"
fi
probe_ok                                                                    # 5

# The value as Kuma stores it: JSON (Settings.get parses it).
if ! { probe_sql "$db" "UPDATE monitor SET active = 0" >/dev/null &&
  probe_sql "$db" "UPDATE notification SET active = 0" >/dev/null &&
  probe_sql "$db" "DELETE FROM setting WHERE key = 'entryPage'" >/dev/null &&
  probe_sql "$db" "INSERT INTO setting (key, value, type) VALUES ('entryPage', '\"$mark\"', 'general')" >/dev/null; }; then
  probe_fail "cannot prepare the copy"
fi
on=$(probe_sql "$db" "SELECT (SELECT count(*) FROM monitor WHERE active = 1) + (SELECT count(*) FROM notification WHERE active = 1)")
[ "$on" = 0 ] || probe_fail "$on monitors or notifications still active in the copy: not started"
probe_ok                                                                    # 6

probe_image uptime-kuma
probe_run ${PROBE_USER:+--user "$PROBE_USER"} --cap-drop ALL --memory 512m --network none \
  -v "$d:/app/data" -e UPTIME_KUMA_DB_TYPE=sqlite "$PROBE_IMAGE"
probe_mounted /app/data                                                     # 7
# entry - "ok VALUE" when Kuma answers with its entry page, else nothing
entry() {
  docker exec "$PROBE_NAME" curl -s -m 5 http://127.0.0.1:3001/api/entry-page 2>/dev/null | python3 -I -c 'import json, sys
try:
    r = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if isinstance(r, dict) and r.get("type") == "entryPage":
    print("ok", r.get("entryPage") or "")'
}
# shellcheck disable=SC2329 # called by probe_wait
answers() { [ -n "$(entry)" ]; }
probe_wait "${PROBE_WAIT_S:-180}" "answer /api/entry-page" answers
probe_ok                                                                    # 8
got=$(entry)
got=${got#ok}
got=${got# }
[ "$got" = "$mark" ] || probe_fail "Kuma answers '${got:-nothing}' instead of the mark: the probe does NOT read the restored copy"
probe_ok                                                                    # 9

probe_pass 9 "${PROBE_BACKUP##*/}: $monitors monitors, all $tokens push tokens of the scripts"
