#!/usr/bin/env bash
# monitor.sh - are the essential containers running, is there disk space and
# memory left, and (HARDENING=yes) is the Docker firewall in place?
#
# Notifies when the list of problems changes, and reminds every two hours
# while it stays. The maintenance flag is read as LATE as possible: this
# check and a job that stops containers may start in the same second, and a
# flag read in the first milliseconds would not exist yet while the
# container is already stopped a second later.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
state=$DECOLAB_STATE_DIR/monitor
remind_s=${MONITOR_REMIND_S:-7200}

critical="pihole unbound prometheus perses portainer samba"
is_yes MODULE_IMMICH && critical="$critical immich_server immich_postgres"
is_yes MODULE_VAULTWARDEN && critical="$critical vaultwarden"
is_yes MODULE_UPTIME_KUMA && critical="$critical uptime-kuma"

issues=""
add() { issues="$issues$1
"; }
down=""
for c in $critical; do
  status=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null) || status=missing
  [ "$status" = running ] || down="$down $c:$status"
done

maintenance_read
[ -z "$MAINTENANCE_PROBLEM" ] || add "$MAINTENANCE_PROBLEM"
paused=""
for e in $down; do
  c=${e%%:*} status=${e#*:}
  # Only "exited" is excused: docker stop never leaves a container "missing".
  if [ "$status" = exited ] && case $MAINTENANCE_CONTAINERS in *" $c "*) true ;; *) false ;; esac; then
    paused="$paused $c"
  else
    add "$c: $status"
  fi
done

for mount in / "$DATA_DIR"; do
  pct=$(df -P "$mount" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }')
  [ "${pct:-0}" -le 90 ] || add "disk $mount: $pct % full"
done
mem_pct=$(awk '/^MemTotal/ { t = $2 } /^MemAvailable/ { a = $2 } END { if (t) print int(100 - a * 100 / t) }' /proc/meminfo 2>/dev/null)
[ "${mem_pct:-0}" -le 95 ] || add "memory: $mem_pct % used"

# Firewall (bin/decolab-firewall): one nftables table. Without it every
# published container port is open to every network the host is in, IPv6
# included, and nothing else would notice. A trial that was never confirmed
# switches itself off after 5 minutes; still pending after 10 means the way
# back did not run.
if is_yes HARDENING; then
  fw_state=${MONITOR_FW_STATE:-/var/lib/decolab}
  if [ -f "$fw_state/firewall-pending" ]; then
    since=$(cat "$fw_state/firewall-pending" 2>/dev/null)
    case $since in '' | *[!0-9]*) since=0 ;; esac
    [ $(($(date +%s) - since)) -lt 600 ] ||
      add "firewall: a trial (decolab-firewall apply) is pending for more than 10 minutes: its way back did not run"
  elif [ ! -f "$fw_state/firewall-confirmed" ]; then
    add "firewall: HARDENING=yes, but no firewall is confirmed: sudo bin/decolab-firewall apply, then confirm"
  else
    active=$(systemctl is-active decolab-firewall.service 2>/dev/null)
    [ "$active" = active ] || add "firewall: decolab-firewall.service is '${active:-unknown}': container ports may be open"
    table=$(sudo -n nft list table inet decolab 2>/dev/null)
    if [ -z "$table" ]; then
      add "firewall: table inet decolab missing or unreadable: container ports may be open"
    elif ! printf '%s\n' "$table" | grep -qE 'hook input priority .*policy drop' ||
      ! printf '%s\n' "$table" | awk '/chain forward/ { f = 1 } f && /^[[:space:]]*}/ { exit } f { last = $0 } END { exit last !~ /^[[:space:]]*drop$/ }'; then
      add "firewall: table inet decolab is incomplete (input policy or final drop missing)"
    fi
  fi
fi

# A suppression nobody sees is a blind spot: it is in every log line.
note=""
[ -z "$paused" ] || note=" [maintenance:$paused paused, alarm suppressed]"
now=$(date +%s)
if [ -z "$issues" ]; then
  [ -s "$state" ] && notify "✅ Decolab" "All problems are solved."
  : >"$state"
  log "OK: $(echo "$critical" | wc -w | tr -d ' ') containers running$note"
  exit 0
fi
# $(...) drops trailing newlines on both sides, so they compare equal.
before=$(sed 1d "$state" 2>/dev/null) last=$(head -1 "$state" 2>/dev/null) current=$(printf '%s' "$issues")
if [ "$before" != "$current" ] || [ $((now - ${last:-0})) -ge "$remind_s" ]; then
  notify "⚠️ Decolab" "$current" && { echo "$now"; printf '%s\n' "$current"; } >"$state"
fi
log "ALERT: $(printf '%s' "$issues" | tr '\n' ';')$note"
exit 1
