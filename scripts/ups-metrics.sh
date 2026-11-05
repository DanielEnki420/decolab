#!/usr/bin/env bash
# ups-metrics.sh - the UPS (NUT, HW_UPS) for Prometheus, and a sign of life
# for Uptime Kuma (push monitor UPS). Every minute.
#
# Division of work: a power cut, its end and "battery low -> shut down" are
# reported by upsmon itself (upssched.conf -> ups-event.sh), at once and
# also when this job is not running. This script delivers the curves and
# watches the watcher: if NUT stops answering, upsmon would notice no power
# cut at all - then Kuma reports.
#
# Readings are only in the file while upsc answers: a flat line with the
# last value would look like a full battery.
#
# Also sends what lib/ups-queue.sh holds back, and "back after UPS
# shutdown" once the host has started again.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
hw_wanted HW_UPS test -e "${UPS_CONF:-/etc/nut/ups.conf}" || exit 0
# shellcheck source=lib/ups-queue.sh
. "$decolab_root/lib/ups-queue.sh"

upsc=${UPS_UPSC:-upsc}
ups=${UPS_NAME:-ups@127.0.0.1}
since=$DECOLAB_STATE_DIR/ups-on-battery-since
down=$DECOLAB_STATE_DIR/ups-shut-down
boot=${UPS_BOOT:-$(awk '/^btime / { print $2 }' /proc/stat 2>/dev/null)}
num() { case ${1:-} in '' | *[!0-9]*) return 1 ;; esac; }

# Messages left behind: every minute, also while NUT does not answer.
ups_flush || log "queue: the message did not go out yet, next minute again"

rc=0
raw=$(timeout 15 "$upsc" "$ups" 2>&1) || rc=$?

printf '%s' "$raw" | python3 -I -c '
import sys, time
rc = int(sys.argv[1])
w = {}
if rc == 0:
    for line in sys.stdin.read().splitlines():
        k, _, v = line.partition(": ")
        if v:
            w[k.strip()] = v.strip()
status = w.get("ups.status", "").split()
ok = rc == 0 and bool(status)
z = []
def m(name, value, help_):
    z.extend([f"# HELP {name} {help_}", f"# TYPE {name} gauge", f"{name} {value}"])
m("decolab_ups_reachable", int(ok), "1 = NUT (upsc) answered just now.")
if ok:
    for key, name, help_ in [
        ("battery.charge", "decolab_ups_battery_percent", "Battery charge in percent."),
        ("battery.runtime", "decolab_ups_runtime_seconds", "Estimated runtime on battery (the UPS estimate)."),
        ("ups.load", "decolab_ups_load_percent", "Load in percent of the rated power (rough on small UPSes)."),
        ("output.voltage", "decolab_ups_output_volts", "Voltage at the UPS sockets."),
        ("battery.charge.low", "decolab_ups_shutdown_battery_percent", "Below this charge NUT reports battery low: shutdown."),
        ("battery.runtime.low", "decolab_ups_shutdown_runtime_seconds", "Below this runtime as well."),
    ]:
        try:
            m(name, float(w[key]), help_)
        except (KeyError, ValueError):
            pass
    for flag, name, help_ in [
        ("OL", "decolab_ups_on_line", "1 = power from the socket."),
        ("OB", "decolab_ups_on_battery", "1 = power cut, running on battery."),
        ("LB", "decolab_ups_battery_low", "1 = battery low, the host shuts down."),
        ("RB", "decolab_ups_replace_battery", "1 = the UPS asks for a new battery."),
        ("CHRG", "decolab_ups_charging", "1 = the battery is charging."),
    ]:
        m(name, int(flag in status), help_)
print("\n".join(z))
' "$rc" | textfile_write ups || die "cannot write ups.prom"

if [ "$rc" -ne 0 ] || ! grep -q '^decolab_ups_reachable 1$' "$DECOLAB_TEXTFILE_DIR/ups.prom"; then
  kuma_push UPS down "NUT does not answer: $(printf '%s' "$raw" | head -c 120)"
  die "upsc $ups: $(printf '%s' "$raw" | head -c 200)"
fi
status=$(printf '%s\n' "$raw" | sed -n 's/^ups.status: //p')
charge=$(printf '%s\n' "$raw" | sed -n 's/^battery.charge: //p')
rt=$(printf '%s\n' "$raw" | sed -n 's/^battery.runtime: //p')
rt=${rt%%.*}
num "$rt" || rt=0
kuma_push UPS up "$status | battery ${charge:-?} % | about $((rt / 60)) min" || warn "the result did not reach Uptime Kuma"

# After a UPS shutdown: "back". Only once the system started AFTER the
# mark (else it would fire in the middle of a shutdown during a test on
# mains) and the UPS is on mains. The mark is removed only after the message
# was delivered; otherwise next minute again (DNS and internet may still be
# missing right after the start).
# The original system sent this message TWICE: a Pi has no clock battery and
# starts with an old time; when NTP corrects it, cron runs a missed minute at
# once, and two runs saw the mark. So only ONE run may do this (flock -n),
# and it checks the mark again under the lock.
if [ -r "$down" ] && exec 7>"$down.lock" && flock -n 7 && [ -r "$down" ]; then
  a=$(cat "$down" 2>/dev/null)
  if num "$a" && num "$boot" && [ "$boot" -gt "$a" ] && [[ " $status " == *" OL "* ]]; then
    host=$(hostname -s 2>/dev/null || echo decolab)
    text="Shut down at $(ups_time "$a" %H:%M), started again at $(ups_time "$boot" %H:%M) ($(((boot - a + 59) / 60)) min off)."
    s=$(cat "$since" 2>/dev/null)
    ! num "$s" || text="Power cut from $(ups_time "$s" %H:%M). $text"
    # Only after every older message (power cut, shutting down) went out.
    if ups_flush && notify "✅ $host: back after UPS shutdown" "$text
Power: on mains · battery ${charge:-?} %, charging."; then
      rm -f "$down" "$since"
    else
      log "message \"back\" not delivered yet: next minute again"
    fi
  fi
fi
