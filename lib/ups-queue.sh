# shellcheck shell=bash
# lib/ups-queue.sh - UPS messages with a queue on disk. Sourced by
# scripts/ups-event.sh and scripts/ups-metrics.sh (after lib/common.sh).
#
# Why: in a power cut the internet is often gone too (the modem is not on
# the UPS, or the provider is down), so every message DURING the outage
# would be lost: "power lost", "shutting down", and often "power back",
# because the modem is still booting. What does not go out waits here, on
# disk (it survives the shutdown), and ups-metrics.sh sends it every minute,
# oldest first, with its original time.
#
# Order is a must: while older messages wait, a new one queues up behind
# them, otherwise "power back" would arrive before "power lost".
#
#   ups_send TITLE TEXT    send now or queue: 0 = delivered, 1 = queued
#   ups_flush              send what waits, stop at the first failure:
#                          0 = nothing waits any more

UPS_QUEUE=${UPS_QUEUE:-$DECOLAB_STATE_DIR/ups-queue}
UPS_QUEUE_MAX=30 # a loose USB cable must not pile up messages without end

# ups_time EPOCH FORMAT - GNU date or BSD date
ups_time() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"; }

ups_enqueue() {
  mkdir -p "$UPS_QUEUE" || return 1
  local n old tmp
  n=$(find "$UPS_QUEUE" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  while [ "$n" -ge "$UPS_QUEUE_MAX" ]; do
    old=$(find "$UPS_QUEUE" -maxdepth 1 -name '*.msg' | sort | head -1)
    rm -f "$old"
    n=$((n - 1))
  done
  tmp=$(mktemp "$UPS_QUEUE/.new.XXXXXX") || return 1
  { date +%s; printf '%s\n' "$1"; printf '%s' "$2"; } >"$tmp"
  # Named by nanoseconds: sorts like time, the same length for centuries.
  mv "$tmp" "$UPS_QUEUE/$(python3 -I -c 'import time; print(time.time_ns())').msg"
}

# flock: cron and an event must never send the same message twice.
ups_flush() {
  [ -d "$UPS_QUEUE" ] || return 0
  (
    flock -w 30 8 || exit 1
    for f in $(find "$UPS_QUEUE" -maxdepth 1 -name '*.msg' | sort); do
      t=$(sed -n 1p "$f")
      title=$(sed -n 2p "$f")
      text=$(sed -n '3,$p' "$f")
      case $t in '' | *[!0-9]*) rm -f "$f" && continue ;; esac # broken: away with it
      notify "$title" "$text
⏱ Delivered late, originally $(ups_time "$t" '%d.%m. %H:%M')" || exit 1
      rm -f "$f"
    done
  ) 8>"$UPS_QUEUE/.lock"
}

ups_send() {
  if ups_flush && notify "$1" "$2"; then
    return 0
  fi
  ups_enqueue "$1" "$2"
  return 1
}
