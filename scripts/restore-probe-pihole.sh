#!/usr/bin/env bash
# restore-probe-pihole.sh - does the backup become a DNS server that blocks?
#
# Pi-hole is the service everything depends on: without it, nobody in the
# house resolves a name. So the probe proves blocking, not just "it starts".
#
# Checks in the newest backup, before anything starts:
#   - gravity.db is intact, pihole.toml is there
#   - the blocklist is not empty: at least PROBE_MIN_DOMAINS (1000) domains,
#     and no drop to less than half of the last run. A valid, empty
#     blocklist is the expensive failure: Pi-hole runs and blocks nothing.
#
# Identity, not trust: the test domain is taken at run time FROM THE
# RESTORED gravity.db (an enabled list of the default group, not on an
# allowlist). If the probe blocks it, the answer can only come from this
# backup. A random name that is in no list must NOT get the same answer:
# otherwise the probe would block everything and prove nothing.
#
# The container has no network at all and is asked from inside (docker
# exec dig), never on port 53, where production listens. Without network
# there is no upstream: an unblocked name gets SERVFAIL or no answer, which
# is exactly what tells it apart from a blocked one.
# Does NOT prove the upstream chain (Unbound): check-unbound-dnssec.sh does.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
# shellcheck source=lib/probe.sh
. "$decolab_root/lib/probe.sh"

probe_init pihole PROBE_PIHOLE -
min=${PROBE_MIN_DOMAINS:-1000}

probe_archive pihole.tar.gz
probe_extract                                                               # 1
d=$PROBE_COPY/pihole
db=$d/gravity.db
[ -s "$db" ] || probe_fail "gravity.db is missing or empty"
[ -s "$d/pihole.toml" ] || probe_fail "pihole.toml is missing: the settings would be lost"
integrity=$(probe_sql "$db" "PRAGMA integrity_check")
[ "$integrity" = ok ] || probe_fail "gravity.db is damaged: ${integrity:-no answer}"
probe_ok                                                                    # 2

domains=$(probe_sql "$db" "SELECT count(*) FROM gravity")
case $domains in '' | *[!0-9]*) probe_fail "cannot count the blocklist in gravity.db" ;; esac
[ "$domains" -ge "$min" ] || probe_fail "only $domains domains in the blocklist (at least $min): the backup is valid but practically empty"
probe_count_guard domains "$domains"
probe_ok                                                                    # 3

# A real ad domain: with a dot, no placeholder, no localhost; from an
# enabled list of the default group (vw_gravity, where Pi-hole has it), and
# on no allowlist.
test_domain=$(python3 -I - "$db" <<'PY'
import sqlite3, sys, urllib.parse
c = sqlite3.connect("file:" + urllib.parse.quote(sys.argv[1]) + "?mode=ro", uri=True)
have = {r[0] for r in c.execute("SELECT name FROM sqlite_master")}
where = ["domain LIKE '%_._%'", "domain NOT LIKE '%localhost%'", "domain NOT LIKE '%localdomain%'",
         "domain NOT GLOB '*[*]*'", "length(domain) BETWEEN 8 AND 60"]
source = "gravity"
if "vw_gravity" in have:
    source = "vw_gravity"
    where.append("(group_id = 0 OR group_id IS NULL)")
if "antigravity" in have:
    where.append("domain NOT IN (SELECT domain FROM antigravity)")
if "domainlist" in have:
    where.append("domain NOT IN (SELECT domain FROM domainlist WHERE type = 0)")
r = c.execute("SELECT domain FROM " + source + " WHERE " + " AND ".join(where) + " ORDER BY domain LIMIT 1").fetchone()
print(r[0] if r else "")
PY
)
[ -n "$test_domain" ] || probe_fail "no usable test domain in gravity.db"
log "test domain from the backup: $test_domain"
probe_ok                                                                    # 4

# Production's image and capabilities; the files of the copy belong to the
# user running this probe, so Pi-hole runs as that user.
probe_image pihole
probe_run --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE \
  --cap-add FOWNER --cap-add KILL --cap-add SETFCAP --memory 512m --network none \
  -e "PIHOLE_UID=$(id -u)" -e "PIHOLE_GID=$(id -g)" -e "TZ=${TZ:-UTC}" -v "$d:/etc/pihole" "$PROBE_IMAGE"
probe_mounted /etc/pihole                                                   # 5

# ask NAME - "STATUS ANSWER" of an A query inside the probe container
ask() {
  docker exec "$PROBE_NAME" dig +time=2 +tries=1 @127.0.0.1 "$1" A 2>/dev/null | awk '
    /status:/ { s = $6; sub(/,$/, "", s) }
    NF > 1 && !/^;/ && $(NF - 1) == "A" { a = $NF }
    END { print s " " a }'
}
# Blocked: 0.0.0.0 (the default) or NXDOMAIN (the other blocking mode).
blocked() { case $1 in "NOERROR 0.0.0.0" | NXDOMAIN*) return 0 ;; esac; return 1; }
# Pi-hole answers queries BEFORE it has read gravity.db (measured on the
# original system): so this waits for the blocked state, within a limit.
# shellcheck disable=SC2329 # called by probe_wait
blocks() {
  answer=$(ask "$test_domain") PROBE_LAST=$answer
  blocked "$answer"
}
answer=""
probe_wait "${PROBE_WAIT_S:-120}" "block $test_domain from the backup" blocks
probe_ok                                                                    # 6

control=decolab-probe-$(python3 -I -c 'import secrets; print(secrets.token_hex(4))').example.org
other=$(ask "$control")
if [ "$other" = "$answer" ] || blocked "$other"; then
  probe_fail "a name in no list gets the same answer ('$other'): the probe blocks everything and proves nothing"
fi
probe_ok                                                                    # 7

probe_pass 7 "${PROBE_BACKUP##*/}: $domains domains, $test_domain blocked"
