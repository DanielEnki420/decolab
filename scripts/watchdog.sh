#!/usr/bin/env bash
# watchdog.sh - self-healing watcher, run as root by a systemd timer (90 s
# after boot, then every 10 minutes).
#
#   A. Web interfaces that do not answer get their container restarted once;
#      the result is reported either way.
#   B. Containers stuck in "Created" after a reboot (start-order race) are
#      started.
#   C. Log files that root created in /var/log/decolab are handed back to
#      the Decolab user: logrotate rotates as that user, and a single
#      root-owned file makes it fail for ALL files.
#
# A container the maintenance flag names is never touched: the job that
# stopped it on purpose would find it running in the middle of its work. Only a flag with a live job and a
# fresh time stamp counts; otherwise the watchdog repairs as usual (one
# unnecessary restart is better than a service that stays down for hours).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
state=$DECOLAB_STATE_DIR/watchdog
mkdir -p "$state"

# notify once per topic per 30 minutes
notify_once() {
  local key last=0 now
  key=$state/n_$(printf '%s' "$1" | tr -cd 'A-Za-z0-9')
  now=$(date +%s)
  [ -f "$key" ] && last=$(cat "$key")
  [ $((now - last)) -gt 1800 ] || return 0
  echo "$now" >"$key"
  notify "$1" "$2"
}
alive() {
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' -m 8 "$1" 2>/dev/null)
  case $code in 200 | 301 | 302 | 401 | 403) return 0 ;; *) return 1 ;; esac
}

# C. hand logs back (-type f, chown -h: symbolic links are neither found nor followed)
find "$DECOLAB_LOG_DIR" -maxdepth 1 -type f -name '*.log' ! -user "$DECOLAB_USER" -print \
  -exec chown -h "$DECOLAB_USER:$DECOLAB_USER" {} + 2>/dev/null | while read -r f; do
  log "log file was not owned by $DECOLAB_USER, handed back: $f"
done

maintenance_read
acted=0
ui=$WEB_UI_ADDRESS
checks="pihole|http://$ui:8053/admin/ portainer|http://$ui:9000/ perses|http://127.0.0.1:8800/"
is_yes MODULE_IMMICH && checks="$checks immich_server|http://$ui:2283/api/server/ping"
is_yes MODULE_VAULTWARDEN && checks="$checks vaultwarden|http://127.0.0.1:8500/alive"
# Kuma watches all others and is watched by nobody else: if it stands, every
# alarm stays silent.
is_yes MODULE_UPTIME_KUMA && checks="$checks uptime-kuma|http://$ui:3001/"

for c in $checks; do
  name=${c%%|*} url=${c#*|}
  case $MAINTENANCE_CONTAINERS in *" $name "*)
    # Stay visible: a watcher that silently does nothing cannot be told
    # apart from a broken one.
    log "maintenance: $name is being backed up, no repair"
    continue
    ;;
  esac
  alive "$url" && continue
  acted=1
  log "DOWN: $name ($url), restarting it"
  docker restart "$name" >/dev/null 2>&1
  sleep 8
  if alive "$url"; then
    log "OK: $name answers again"
    notify_once "✅ Watchdog: $name repaired" "$name did not answer and was restarted automatically. It works again."
  else
    log "FAILED: $name still down"
    notify_once "🔴 Watchdog: $name DOWN" "$name does not answer and could NOT be repaired automatically. Please have a look."
  fi
done

# docker start, not "docker compose up": Decolab's stacks need their env
# files, and a created container already has its whole configuration.
docker ps -a --filter status=created --format '{{.Names}}' 2>/dev/null | while read -r name; do
  [ -n "$name" ] || continue
  case $MAINTENANCE_CONTAINERS in *" $name "*) continue ;; esac
  log "CREATED: $name, starting it"
  if docker start "$name" >/dev/null 2>&1; then
    notify_once "🔧 Watchdog: $name started" "Container $name was stuck in 'Created' after a reboot and has been started."
  else
    notify_once "🔴 Watchdog: $name stuck" "Container $name is stuck in 'Created' and does not start."
  fi
done

[ "$acted" = 0 ] && log "all web interfaces answer"
exit 0
