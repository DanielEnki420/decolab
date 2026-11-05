#!/usr/bin/env bash
# check-tailscale-keys.sh - warns BEFORE a Tailscale device key expires.
#
# An expired key looks like a total outage from that device. The dangerous
# case is the host's own key: with it goes the way to repair anything from
# afar. A freshly set up host gets an expiring key at its first
# "tailscale up" again, so this checks ALL devices, not just the ones you
# happen to think of.
#
# Writes tailscale.prom (rule TailscaleKeyExpiring); notifies only when the
# situation changes.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
is_yes TAILSCALE || exit 0
threshold=${TAILSCALE_KEY_DAYS:-14}
state=$DECOLAB_STATE_DIR/tailscale-keys
raw=$("${TAILSCALE_BIN:-tailscale}" status --json 2>/dev/null)

# Whoever cannot check has a problem, not a reason to stay quiet.
if ! printf '%s' "$raw" | python3 -I -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null; then
  notify "🔴 Tailscale" "Keys cannot be checked: 'tailscale status --json' returns nothing usable."
  die "tailscale status --json is empty or broken"
fi

# One line per device: NAME DAYS (-1 = key expiry disabled)
devices=$(printf '%s' "$raw" | python3 -I -c '
import datetime, json, re, sys
d = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
for p in [d["Self"]] + list((d.get("Peer") or {}).values()):
    name = re.sub(r"[^A-Za-z0-9._-]", "_", p.get("HostName") or "?")
    e = p.get("KeyExpiry")
    days = -1 if not e else (datetime.datetime.fromisoformat(e.replace("Z", "+00:00")) - now).days
    print(name, days)')

expiring="" count=0 next=-1
while read -r name days; do
  [ -n "$name" ] && [ "$days" != -1 ] || continue
  { [ "$next" = -1 ] || [ "$days" -lt "$next" ]; } && next=$days
  if [ "$days" -le "$threshold" ]; then
    expiring="$expiring $name(${days}d)"
    count=$((count + 1))
  fi
done <<<"$devices"

{
  echo "# HELP decolab_tailscale_key_days_left Days until the device key expires (-1 = expiry disabled)."
  echo "# TYPE decolab_tailscale_key_days_left gauge"
  while read -r name days; do
    [ -n "$name" ] && echo "decolab_tailscale_key_days_left{device=\"$name\"} $days"
  done <<<"$devices"
  echo "# HELP decolab_tailscale_keys_expiring Devices whose key expires within $threshold days."
  echo "# TYPE decolab_tailscale_keys_expiring gauge"
  echo "decolab_tailscale_keys_expiring $count"
} | textfile_write tailscale

now="$count|$expiring"
before=$(cat "$state" 2>/dev/null || true)
echo "$now" >"$state" || warn "cannot write $state"
if [ "$count" -eq 0 ]; then
  [ -n "$before" ] && [ "$before" != "$now" ] && notify "✅ Tailscale" "All device keys have time again (next expiry in $next days)."
  log "OK: next key expiry in $next days (-1 = all disabled)"
  exit 0
fi
[ "$before" != "$now" ] && notify "🔑 Tailscale key expires" "Affected:$expiring
Log in again with 'tailscale up' on the device, or disable key expiry in the admin console. If the host's own key expires, remote access is gone too: then only SSH from the home network (port $SSH_PORT) helps."
log "WARNING: $count key(s) expire within $threshold days:$expiring"
exit 1
