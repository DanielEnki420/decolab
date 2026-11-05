#!/usr/bin/env bash
# check-services.sh - finds systemd services that keep failing: in state
# "failed", or in a restart loop.
#
# A service without a port slips through every HTTP and port check. A unit
# in a restart loop is worse: it even looks "active" now and then, burns CPU
# time and floods the journal, unnoticed for days.
#
# Writes services.prom (rules SystemdUnitFailed, SystemdUnitRestartLoop) and
# notifies only when the situation CHANGES: the same message every 15
# minutes would be noise after a day, and noise gets ignored.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
threshold=${SERVICES_RESTART_THRESHOLD:-10}
state=$DECOLAB_STATE_DIR/services
systemctl=${SYSTEMCTL:-systemctl}

failed=$("$systemctl" list-units --type=service --state=failed --no-legend --plain --no-pager 2>/dev/null |
  awk '{ printf " %s", $1 }')
looping=""
for unit in $("$systemctl" list-units --type=service --no-legend --plain --no-pager 2>/dev/null | awk '{ print $1 }'); do
  n=$("$systemctl" show -p NRestarts --value "$unit" 2>/dev/null)
  [ "${n:-0}" -gt "$threshold" ] 2>/dev/null && looping="$looping $unit($n)"
done
n_failed=$(printf '%s' "$failed" | wc -w | tr -d ' ')
n_looping=$(printf '%s' "$looping" | wc -w | tr -d ' ')

textfile_write services <<METRICS
# HELP decolab_systemd_units_failed systemd services in state failed.
# TYPE decolab_systemd_units_failed gauge
decolab_systemd_units_failed $n_failed
# HELP decolab_systemd_units_restart_loop systemd services with more than $threshold restarts.
# TYPE decolab_systemd_units_restart_loop gauge
decolab_systemd_units_restart_loop $n_looping
METRICS

now="$n_failed|$n_looping|$failed$looping"
before=$(cat "$state" 2>/dev/null || true)
echo "$now" >"$state" || warn "cannot write $state"
if [ "$n_failed" -eq 0 ] && [ "$n_looping" -eq 0 ]; then
  [ -n "$before" ] && [ "$before" != "$now" ] && notify "✅ Services" "All systemd services are fine again."
  log "OK: no failed service, none in a restart loop"
  exit 0
fi
[ "$before" != "$now" ] && notify "🔴 Services" "failed:${failed:- none} · restart loop:${looping:- none}"
log "FAILED: failed=$n_failed ($failed ) restart loop=$n_looping ($looping )"
exit 1
