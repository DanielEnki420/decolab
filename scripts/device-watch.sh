#!/usr/bin/env bash
# device-watch.sh - a message when an UNKNOWN device appears in the home
# network. Runs as root (arp-scan needs raw sockets), every 15 minutes.
#
# Pi-hole cannot do this: it runs in a Docker bridge network and does not
# see the LAN's ARP table.
#
# Known devices: $DECOLAB_STATE_DIR/known-devices, one MAC per line. To
# learn anew, delete it and known-devices.start.
#
# Learning phase: a single scan misses sleeping phones (the first run of
# the original system saw 15 devices, a scan ten seconds later 2 "new"
# ones). For DEVICE_LEARN_S (24 h) after the first run, everything found is
# silently learned.
# A new device is remembered only after the message was delivered;
# otherwise the next run reports it again.
# A scan that finds NOTHING is an error (exit 1), never "all quiet".
#
# Phones use a random "private" address per Wi-Fi (second character 2, 6,
# a or e). A visitor's phone is reported: that is intended.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
known=$DECOLAB_STATE_DIR/known-devices
learn_s=${DEVICE_LEARN_S:-86400}

scan() { # lines "<ip><TAB><mac><TAB><vendor>"
  if [ -n "${DEVICE_SCAN_CMD:-}" ]; then "$DEVICE_SCAN_CMD"; return; fi
  command -v arp-scan >/dev/null || die "arp-scan is not installed (install.sh installs it)"
  timeout 60 arp-scan -I "$LAN_INTERFACE" --localnet -q -x -g 2>/dev/null
}

found=$(scan | awk -F'\t' 'tolower($2) ~ /^([0-9a-f][0-9a-f]:)+[0-9a-f][0-9a-f]$/ && length($2) == 17 { print $1 "\t" tolower($2) "\t" $3 }' |
  sort -t "$(printf '\t')" -k2,2 -u)
[ -n "$found" ] || die "the scan found no device on $LAN_INTERFACE (not even the router)"
count=$(printf '%s\n' "$found" | grep -c .)

if [ ! -f "$known" ]; then
  if ! { : >"$known" && date +%s >"$known.start"; }; then die "cannot write $known"; fi
fi
start=$(cat "$known.start" 2>/dev/null)
case $start in '' | *[!0-9]*) start=0 ;; esac
if [ $(($(date +%s) - start)) -lt "$learn_s" ]; then
  learned=$(printf '%s\n' "$found" | cut -f2 | grep -vxF -f "$known")
  [ -z "$learned" ] || printf '%s\n' "$learned" >>"$known"
  log "learning: $count seen, $(grep -c . "$known") known"
  exit 0
fi

new="" remember=""
while IFS="$(printf '\t')" read -r ip mac vendor; do
  grep -qxF "$mac" "$known" && continue
  kind=""
  case ${mac:1:1} in [26ae]) kind=" (random address: usually a phone or tablet)" ;; esac
  new="$new"$'\n'"• $ip  $mac  ${vendor:-unknown vendor}$kind"
  remember="$remember$mac"$'\n'
done <<<"$found"

n_new=$(printf '%s' "$remember" | grep -c . || true)
if [ -n "$new" ]; then
  if notify "🆕 New device in the home network" "Not seen before:$new

Do you know it? Then nothing to do: it will not be reported again."; then
    printf '%s' "$remember" >>"$known"
  else
    die "$count devices, $n_new new, but the message failed: the next run reports them again"
  fi
fi
log "OK: $count devices, $n_new new"
