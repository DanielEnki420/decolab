#!/usr/bin/env bash
# morning-report.sh - every morning one message: did the night work?
#
# Every nightly job reports only its failures. That is on purpose, but then
# silence means two things: "all good" or "the way to your phone is broken".
# A failed send only lands in notify-errors.log, and nobody reads that. This
# message comes EVERY morning, also when all went well. If it does not
# arrive, something is wrong.
#
# Reads only logs, state files and a COPY of Uptime Kuma's database; changes
# nothing. Runs at 06:15, after the last restore probe (06:05). The Sunday
# jobs from 06:30 (restic check, off-site probe) report failures themselves.
#
# By hand, without sending:  MORNING_SHOW_ONLY=1 scripts/morning-report.sh
# Overridable for tests: MORNING_DATE (YYYY-MM-DD), MORNING_NOW_UTC
# ("YYYY-MM-DD HH:MM:SS"), MORNING_KUMA_DB, MORNING_APT_LIST.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init

logs=$DECOLAB_LOG_DIR
today=${MORNING_DATE:-$(date +%F)}
yesterday=$(python3 -I -c 'import datetime, sys
print(datetime.date.fromisoformat(sys.argv[1]) - datetime.timedelta(days=1))' "$today") ||
  die "MORNING_DATE is no date: $today"
now_utc=${MORNING_NOW_UTC:-$(date -u '+%F %T')}

open=()  # what is missing or failed, one line each
night=() # what worked in the night
state=() # how things look now

# of_today FILE PATTERN - the last line of TODAY matching PATTERN. An OK of
# yesterday does not count: that would be exactly the silent failure.
of_today() { grep -E "^${today} " "$1" 2>/dev/null | grep -E "$2" | tail -1; }

# night_job SHORT NAME LOG - the job's last line of today must be "OK:"
night_job() {
  local z
  z=$(of_today "$logs/$3" ' (OK|FAILED): ')
  case $z in
    *" OK: "*) night+=("$1") ;;
    *" FAILED: "*) open+=("$2: $(printf '%s' "${z#* FAILED: }" | cut -c1-90)") ;;
    *) open+=("$2: no result of today ($3)") ;;
  esac
}

# --- the night ---------------------------------------------------------------
night_job backup "Backup" backup.log
night_job verified "Backup check" verify-backup.log
[ -z "${USB_BACKUP_DIR:-}" ] || night_job USB "USB copy" backup-usb.log
[ -z "${RESTIC_REPOSITORY:-}" ] || night_job off-site "Off-site backup" backup-offsite.log
night_job digests "Image list" image-digests.log

probes="pihole"
is_yes MODULE_VAULTWARDEN && probes="$probes vaultwarden"
is_yes MODULE_IMMICH && probes="$probes immich"
is_yes MODULE_UPTIME_KUMA && probes="$probes kuma"
passed=0 total=0
for p in $probes; do
  total=$((total + 1))
  z=$(of_today "$logs/restore-probe-$p.log" ' (PASSED|FAILED): ')
  case $z in
    *" PASSED: "*) passed=$((passed + 1)) ;;
    *" FAILED: "*) open+=("Probe $p: $(printf '%s' "${z#* FAILED: }" | cut -c1-90)") ;;
    *) open+=("Probe $p: no result of today") ;;
  esac
done
state+=("probes $passed/$total")

# --- the state now -----------------------------------------------------------
s=$(cat "$DECOLAB_STATE_DIR/services" 2>/dev/null)
case $s in
  "0|0|"*) state+=("services ok") ;;
  "") open+=("Services: state unknown (check-services.sh has not run)") ;;
  *) open+=("Services: $(printf '%s' "$s" | cut -d'|' -f3- | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-90)") ;;
esac

# Prometheus: the check runs every 15 minutes; older than 40 min = it stopped.
z=$(tail -1 "$logs/check-prometheus-alerts.log" 2>/dev/null)
age=$(python3 -I -c 'import datetime, sys
try:
    t = datetime.datetime.strptime(sys.argv[1][:19], "%Y-%m-%d %H:%M:%S")
    print(int((datetime.datetime.now() - t).total_seconds() // 60))
except ValueError:
    print(-1)' "$z")
if [ -z "$z" ] || [ "$age" -lt 0 ] || [ "$age" -gt 40 ]; then
  open+=("Prometheus check: last run ${z:0:16}")
elif [[ $z == *" OK: "* ]]; then
  state+=("no alert")
else
  open+=("Prometheus: $(printf '%s' "${z:20}" | sed 's/^FAILED: //' | cut -c1-90)")
fi

# Uptime Kuma: the last heartbeat of every active monitor (3 = maintenance
# counts as green). And the newest heartbeat must be fresh: a copy of the
# database of a Kuma that stopped hours ago is all green, a frozen world.
if is_yes MODULE_UPTIME_KUMA; then
  db=${MORNING_KUMA_DB:-}
  if [ -z "$db" ]; then
    tmp=$(mktemp -d) && trap 'rm -rf "$tmp"' EXIT
    db=$tmp/kuma.db
    python3 -I "$decolab_root/lib/sqlite_snapshot.py" "$DATA_DIR/uptime-kuma/kuma.db" "$db" >/dev/null 2>&1 || db=""
  fi
  kuma=$(python3 -I -c 'import sqlite3, sys
try:
    c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
    rows = c.execute("""SELECT m.name, h.status FROM monitor m
        JOIN heartbeat h ON h.id = (SELECT id FROM heartbeat WHERE monitor_id = m.id
                                    ORDER BY time DESC LIMIT 1)
        WHERE m.active = 1""").fetchall()
    age = c.execute("""SELECT CAST((julianday(?) - julianday(MAX(h.time))) * 1440 AS INTEGER)
        FROM heartbeat h JOIN monitor m ON m.id = h.monitor_id WHERE m.active = 1""",
                    (sys.argv[2],)).fetchone()[0]
except Exception:
    sys.exit(1)
red = [n for n, s in rows if s not in (1, 3)]
print(len(rows), -1 if age is None else age, len(red), ", ".join(red[:3]))' "${db:-/nonexistent}" "$now_utc" 2>/dev/null)
  read -r k_all k_age k_red k_names <<<"$kuma"
  if [ -z "$kuma" ] || [ "${k_all:-0}" -eq 0 ]; then
    open+=("Uptime Kuma: database not readable")
  elif [ "$k_age" -lt 0 ] || [ "$k_age" -gt 15 ]; then
    open+=("Uptime Kuma stands still: last heartbeat ${k_age} min ago - monitoring is not current")
  elif [ "$k_red" = 0 ]; then
    state+=("Kuma $k_all/$k_all green")
  else
    open+=("Uptime Kuma: $k_red not green: $k_names")
  fi
fi

# The Docker engine is never updated automatically (config/host/
# apt-origins.conf: an update restarts every container). So that it is not
# forgotten, it is named here until it is installed.
if [ -n "${MORNING_APT_LIST:-}" ]; then
  dk=$(grep -cE '^(docker-ce|docker-ce-cli|containerd\.io)/' "$MORNING_APT_LIST" 2>/dev/null)
else
  dk=$(apt list --upgradable 2>/dev/null | grep -cE '^(docker-ce|docker-ce-cli|containerd\.io)/')
fi
[ "${dk:-0}" -eq 0 ] || state+=("Docker update waiting (apt upgrade by hand)")

# Failed sends since yesterday: did alarms perhaps never arrive?
tg=$(grep -cE "^(${yesterday}|${today}) " "$logs/notify-errors.log" 2>/dev/null)
[ "${tg:-0}" -eq 0 ] || open+=("Notifications: $tg failed since yesterday (notify-errors.log)")

# --- report ------------------------------------------------------------------
join() { local IFS='|'; printf '%s' "$*" | sed 's/|/ · /g'; }
host=$(hostname -s 2>/dev/null || echo decolab)
if [ ${#open[@]} -eq 0 ]; then
  title="✅ $host: night OK" text=""
else
  title="⚠️ $host: night - ${#open[@]} open"
  text=$(printf '❌ %s\n' "${open[@]}")$'\n'
fi
[ ${#night[@]} -eq 0 ] || text+="$(join "${night[@]}")"$'\n'
text+="$(join "${state[@]}")"

log "$title | $(printf '%s' "$text" | tr '\n' ' ')"
if [ -n "${MORNING_SHOW_ONLY:-}" ]; then
  printf '%s\n%s\n' "$title" "$text"
  exit 0
fi
notify "$title" "$text" || die "sending failed"
