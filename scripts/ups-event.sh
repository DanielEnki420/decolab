#!/usr/bin/env bash
# ups-event.sh EVENT - a UPS event becomes a message (HW_UPS).
#
# Chain: upsmon (NOTIFYCMD) -> upssched (timers, config/nut/upssched.conf)
# -> /usr/local/sbin/decolab-ups-event (root-owned, runs as nut) -> via sudo
# as the Decolab user HERE. The detour exists because the bot token is
# readable only by the Decolab user; sudoers allows nut exactly this one
# script as that user, nothing as root.
#
# The event comes from upssched.conf; still only known names are accepted,
# anything else is refused and logged.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
# shellcheck source=lib/ups-queue.sh
. "$decolab_root/lib/ups-queue.sh"

upsc=${UPS_UPSC:-upsc}
ups=${UPS_NAME:-ups@127.0.0.1}
upsmon=${UPS_UPSMON:-/usr/sbin/upsmon}
# Tests set UPS_SUDO="" and a fake upsmon: a test must never shut a host down.
sudo=${UPS_SUDO-sudo -n}
# Start of the outage, so that "power back" can say how long it lasted.
since=$DECOLAB_STATE_DIR/ups-on-battery-since
# On disk, not in /run: it survives the shutdown. ups-metrics.sh reports
# "back" afterwards - upssched's timers die with the host, and upsmon reports
# no ONLINE after the start.
down=$DECOLAB_STATE_DIR/ups-shut-down
elog=$DECOLAB_LOG_DIR/ups-event.log

say() { log "$*" >>"$elog" 2>/dev/null || log "$*"; }
num() { case ${1:-} in '' | *[!0-9]*) return 1 ;; esac; }

# Charge and runtime as the UPS reports them now ("?" if it does not).
raw=$(timeout 10 "$upsc" "$ups" 2>/dev/null)
charge=$(printf '%s\n' "$raw" | sed -n 's/^battery.charge: //p')
charge=${charge:-?}
status=$(printf '%s\n' "$raw" | sed -n 's/^ups.status: //p')
rt=$(printf '%s\n' "$raw" | sed -n 's/^battery.runtime: //p')
rt=${rt%%.*}
if num "$rt"; then rt="about $((rt / 60)) min"; else rt=unknown; fi
host=$(hostname -s 2>/dev/null || echo decolab)

send() {
  say "$1 | $(printf '%s' "$2" | tr '\n' ' ')"
  ups_send "$1" "$2" || say "not delivered (no internet?): waits in $UPS_QUEUE, sent later"
}

case ${1:-} in
  power-lost)
    date +%s >"$since"
    send "⚡ $host: power cut, running on battery" \
      "No power from the socket for 10 seconds. Everything on the UPS keeps running.
Battery: $charge % · runtime: $rt
If the battery runs low, $host shuts down cleanly and starts again by itself when the power is back." ;;
  power-back)
    took=""
    if [ -r "$since" ]; then
      s=$(cat "$since")
      ! num "$s" || took=" after $((($(date +%s) - s + 59) / 60)) min"
      rm -f "$since"
    fi
    send "✅ $host: power is back" "On mains again$took. Battery: $charge %, charging." ;;
  shutdown)
    # FSD and SHUTDOWN usually both arrive: only the first reports.
    a=$(cat "$down" 2>/dev/null)
    if num "$a" && [ $(($(date +%s) - a)) -lt 600 ]; then
      say "shutdown: already reported"
      exit 0
    fi
    date +%s >"$down"
    why="UPS command"
    if [ -r "$since" ]; then
      s=$(cat "$since")
      ! num "$s" || why="power gone for $((($(date +%s) - s) / 60)) min"
    fi
    send "🔋 $host: shutting down (power cut)" \
      "$why · battery: $charge % · runtime: $rt
$host now shuts down cleanly. The UPS then switches off briefly and on again once there is power; $host starts by itself. When it runs again, \"back after UPS shutdown\" follows." ;;
  battery-limit)
    # 30 minutes on battery (upssched.conf). Only if really still on battery:
    # a timer left behind must not switch off a host that is on mains.
    case " $status " in
      *" OB "*)
        say "limit of 30 min on battery reached ($status, battery $charge %): upsmon -c fsd"
        # shellcheck disable=SC2086 # "sudo -n" is two words on purpose
        $sudo "$upsmon" -c fsd || say "upsmon -c fsd FAILED" ;;
      *) say "battery-limit: not on battery ($status): nothing to do" ;;
    esac ;;
  usb-lost)
    send "⚠️ $host: UPS not reachable" \
      "No connection to the UPS (USB) for more than a minute. Check the USB cable between UPS and $host: without it a power cut goes unnoticed and there is no clean shutdown in time." ;;
  usb-back)
    send "✅ $host: UPS reachable again" "The USB connection to the UPS is back. Battery: $charge %." ;;
  replace-battery)
    send "🔋 $host: the UPS asks for a new battery" \
      "Until it is replaced, the runtime in a power cut may not be enough for a clean shutdown." ;;
  *)
    say "REFUSED: unknown event '${1:-}'"
    exit 2 ;;
esac
