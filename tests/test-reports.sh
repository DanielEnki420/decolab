#!/usr/bin/env bash
# Contract tests for the reports: morning-report.sh, ...
# The night is written as log files with today's date; Uptime Kuma's
# database is a small SQLite file with the tables the report reads.
# Single quotes around $… are intended: the fakes evaluate them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

echo "morning-report.sh"
L=$DECOLAB_LOG_DIR
day=2030-05-17
now_utc="2030-05-17 04:15:00"
kdb=$t_tmp/kuma.db
export MORNING_DATE=$day MORNING_NOW_UTC=$now_utc MORNING_KUMA_DB=$kdb MORNING_APT_LIST=$t_tmp/apt.txt

# kuma_db "NAME STATUS MINUTES-AGO" ... - one active monitor per argument
kuma_db() {
  rm -f "$kdb"
  python3 -I - "$kdb" "$now_utc" "$@" <<'PY'
import datetime, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE monitor (id INTEGER PRIMARY KEY, name TEXT, active INTEGER)")
c.execute("CREATE TABLE heartbeat (id INTEGER PRIMARY KEY, monitor_id INTEGER, status INTEGER, time TEXT)")
now = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%d %H:%M:%S")
c.execute("INSERT INTO monitor (name, active) VALUES ('paused', 0)")
c.execute("INSERT INTO heartbeat (monitor_id, status, time) VALUES (1, 0, ?)", (str(now),))
for spec in sys.argv[3:]:
    name, status, ago = spec.split()
    mid = c.execute("INSERT INTO monitor (name, active) VALUES (?, 1)", (name,)).lastrowid
    old = now - datetime.timedelta(minutes=int(ago) + 60)
    c.execute("INSERT INTO heartbeat (monitor_id, status, time) VALUES (?, 0, ?)", (mid, str(old)))
    t = now - datetime.timedelta(minutes=int(ago))
    c.execute("INSERT INTO heartbeat (monitor_id, status, time) VALUES (?, ?, ?)", (mid, int(status), str(t)))
c.commit()
PY
}
good_night() {
  rm -f "$L"/*.log
  local j
  for j in backup verify-backup image-digests; do
    printf '%s 03:10:00 OK: fine\n' "$day" >"$L/$j.log"
  done
  for j in pihole vaultwarden immich kuma; do
    printf '%s 06:01:00 PASSED: fine\n' "$day" >"$L/restore-probe-$j.log"
  done
  # the Prometheus check ran a minute ago (local time)
  printf '%s OK: 12 targets up, 15 rules loaded, no alert\n' "$(date '+%F %T')" >"$L/check-prometheus-alerts.log"
  echo "0|0|" >"$DECOLAB_STATE_DIR/services"
  kuma_db "dns 1 1" "backup 1 2" "maint 3 1"
  : >"$t_tmp/apt.txt"
}
report() { MORNING_SHOW_ONLY=1 "$t_root/scripts/morning-report.sh" </dev/null; }

good_night
check "a good night: OK" 0 "night OK" -- report
check "  names what worked" 0 "backup · verified · digests" -- report
check "  and the state now" 0 "probes 4/4 · services ok · no alert · Kuma 3/3 green" -- report
refute "  a paused monitor does not count" "4/4 green"
refute "  no USB or off-site line while they are off" "USB"

: >"$FAKE_CURL_LOG"
check "it is SENT every morning, also when all is well" 0 "" -- script morning-report.sh
check "  ... as a message" 0 "night OK" -- telegrams

printf '%s 03:10:00 OK: fine\n' 2030-05-16 >"$L/backup.log"
check "yesterday's OK does not count" 0 "Backup: no result of today (backup.log)" -- report
check "  ... the title counts what is open" 0 "night - 1 open" -- report

good_night
printf '%s 06:02:00 FAILED: 3 of 20 sampled photos are missing\n' "$day" >"$L/restore-probe-immich.log"
check "a failed probe: its reason" 0 "Probe immich: 3 of 20 sampled photos are missing" -- report
check "  ... and the count" 0 "probes 3/4" -- report

good_night
rm "$L/restore-probe-kuma.log"
check "a probe that did not run" 0 "Probe kuma: no result of today" -- report

good_night
sed -i.bak 's/^USB_BACKUP_DIR=.*/USB_BACKUP_DIR=\/mnt\/usb/; s/^RESTIC_REPOSITORY=.*/RESTIC_REPOSITORY=\/srv\/restic/' "$DECOLAB_CONF"
check "USB and off-site switched on: they are expected" 0 "USB copy: no result of today" -- report
check "  ... both" 0 "Off-site backup: no result of today" -- report
printf '%s 03:55:00 OK: fine\n' "$day" >"$L/backup-usb.log"
printf '%s 04:20:00 OK: fine\n' "$day" >"$L/backup-offsite.log"
check "  ... and named when they ran" 0 "USB · off-site" -- report
mv "$DECOLAB_CONF.bak" "$DECOLAB_CONF"

good_night
sed -i.bak 's/^MODULE_IMMICH=.*/MODULE_IMMICH=no/' "$DECOLAB_CONF"
rm "$L/restore-probe-immich.log"
check "a module switched off: its probe is not expected" 0 "night OK" -- report
check "  ... and not counted" 0 "probes 3/3" -- report
mv "$DECOLAB_CONF.bak" "$DECOLAB_CONF"

good_night
echo "1|0| decolab-fan.service" >"$DECOLAB_STATE_DIR/services"
check "a failed service" 0 "Services: decolab-fan.service" -- report
rm "$DECOLAB_STATE_DIR/services"
check "no services state at all" 0 "Services: state unknown" -- report

good_night
printf '2030-05-17 05:00:00 FAILED: 1 alert firing: DiskAlmostFull\n' >"$L/check-prometheus-alerts.log"
check "a Prometheus check that is old: it stopped" 0 "Prometheus check: last run 2030-05-17 05:00" -- report
printf '%s FAILED: 1 alert firing: DiskAlmostFull\n' "$(date '+%F %T')" >"$L/check-prometheus-alerts.log"
check "a firing alert" 0 "Prometheus: 1 alert firing: DiskAlmostFull" -- report

good_night
kuma_db "dns 1 1" "backup 0 2" "samba 2 1"
check "Kuma: monitors not green, by name" 0 "Uptime Kuma: 2 not green: backup, samba" -- report
kuma_db "dns 1 90" "backup 1 95"
check "Kuma standing still is no green" 0 "Uptime Kuma stands still: last heartbeat 90 min ago" -- report
refute "  ... not reported as green" "green"
rm -f "$kdb"
check "Kuma's database unreadable" 0 "Uptime Kuma: database not readable" -- report

good_night
echo "docker-ce/stable 5:29.0.1-1 arm64 [upgradable from: 5:29.0.0-1]" >"$t_tmp/apt.txt"
check "a waiting Docker update is named, not counted as open" 0 "Docker update waiting" -- report
refute "  ... still OK" "open"

good_night
printf '%s 23:10:00 backup.sh: curl exit 6 | title: x\n' 2030-05-16 >"$L/notify-errors.log"
check "failed sends since yesterday" 0 "Notifications: 1 failed since yesterday" -- report
printf '%s 23:10:00 backup.sh: curl exit 6 | title: x\n' 2030-05-15 >"$L/notify-errors.log"
check "  ... older ones do not count" 0 "night OK" -- report

good_night
: >"$FAKE_CURL_LOG"
check "sending fails: exit 1" 1 "sending failed" -- env TELEGRAM_ENV_FILE=/nonexistent "$t_root/scripts/morning-report.sh"

echo "update-report.sh"
unset MORNING_DATE MORNING_NOW_UTC MORNING_KUMA_DB MORNING_APT_LIST
# A copy of the tree as release v1.0.0, cloned from an "origin" that has
# v1.0.0 and, later, v1.9.0 and v1.10.0 (as text, 1.9 would sort last).
origin=$t_tmp/origin tree=$t_tmp/tree
mkdir -p "$origin"
cp -R "$t_root/lib" "$t_root/scripts" "$t_root/config" "$t_root/bin" "$origin/"
g() { git -C "$1" -c user.name=t -c user.email=t@example.org "${@:2}"; }
g "$origin" init -q && g "$origin" add -A && g "$origin" commit -qm r && g "$origin" tag v1.0.0
git clone -q "$origin" "$tree" 2>/dev/null
export UPDATE_APT_LIST=$t_tmp/apt.txt UPDATE_REBOOT_FILE=$t_tmp/reboot-required UPDATE_TODAY=2030-05-20
ur() { "$tree/scripts/update-report.sh" "$@" </dev/null; }
export FAKE_DOCKER='case $1 in inspect) exit 1 ;; esac' # no Watchtower
apt_line() { printf '%s/%s 1.2-3 arm64 [upgradable from: 1.2-2]\n' "$1" "$2"; }

printf 'Listing... Done\n' >"$t_tmp/apt.txt"
: >"$FAKE_CURL_LOG"
check "nothing to do: green" 0 "green" -- ur
check "  one line" 0 "2030-05-20: everything is current" -- telegrams
same "  Kuma up" "$(kuma UPDATES | cut -d' ' -f1-2)" "up green:"

: >"$FAKE_CURL_LOG"
check "--quiet: no message" 0 "green" -- ur --quiet
same "  ... none" "$(telegrams)" ""
same "  ... but Kuma hears it" "$(kuma UPDATES | cut -d' ' -f1)" "up"

{ apt_line openssl stable-security; apt_line vim stable; } >"$t_tmp/apt.txt"
check "updates open: yellow, security named" 0 "apt: 2 open (1 security, open for 0 days)" -- ur
check "  ... the package" 0 "  openssl" -- ur
check "  still open 8 days later: red" 0 "red" -- env UPDATE_TODAY=2030-05-28 "$tree/scripts/update-report.sh"
check "  ... says it does not install by itself" 0 "check unattended-upgrades" -- telegrams
same "  ... Kuma down: an alarm" "$(kuma UPDATES | cut -d' ' -f1)" "down"
check "  ... the first day is kept" 0 "openssl 2030-05-20" -- cat "$DECOLAB_STATE_DIR/security-updates-since"
apt_line vim stable >"$t_tmp/apt.txt"
check "installed: the day is forgotten" 0 "yellow" -- env UPDATE_TODAY=2030-05-29 "$tree/scripts/update-report.sh"
same "  ... state empty" "$(cat "$DECOLAB_STATE_DIR/security-updates-since")" ""

{ apt_line docker-ce stable; apt_line containerd.io stable; } >"$t_tmp/apt.txt"
check "the Docker engine waits: named with what to do" 0 "Docker engine: docker-ce containerd.io waiting" -- ur
check "  ... by hand" 0 "sudo apt upgrade (restarts every container)" -- telegrams

printf 'Listing... Done\n' >"$t_tmp/apt.txt"
: >"$t_tmp/reboot-required"
check "a reboot waiting: yellow" 0 "reboot needed: yes" -- ur
rm "$t_tmp/reboot-required"

check "the running release is named" 0 "green" -- ur
g "$origin" commit -q --allow-empty -m r2 && g "$origin" tag v1.9.0 && g "$origin" tag v1.10.0
: >"$FAKE_CURL_LOG"
check "a newer release at origin: named" 0 "Decolab: v1.10.0 available (running v1.0.0)" -- ur
check "  ... with the way to it" 0 "bin/decolab-checkout v1.10.0 && ./install.sh && scripts/update.sh --dry-run" -- telegrams
g "$tree" fetch -q --tags && g "$tree" checkout -q v1.10.0
check "  ... current again after the checkout" 0 "green" -- ur
g "$tree" remote remove origin
check "no origin: no release check, no error" 0 "green" -- ur

export FAKE_DOCKER='case $1 in
  inspect) [ "$2" = watchtower ] ;;
  logs) printf "%s\n" "level=info msg=\"Session done\" Failed=0 Scanned=3 Updated=1 notify=no" "time=x msg=\"Update session completed\" updated=2 failed=1" ;;
esac'
check "Watchtower installed: its week" 0 "Watchtower this week: 2 updated, 1 failed" -- ur
check "  ... a failure is yellow" 0 "yellow" -- ur

t_finish
