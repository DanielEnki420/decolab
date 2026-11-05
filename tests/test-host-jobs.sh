#!/usr/bin/env bash
# Contract tests for the host jobs: device-watch.sh, speedtest.sh, and the
# UPS (ups-metrics.sh, ups-event.sh, lib/ups-queue.sh).
# arp-scan, librespeed-cli, upsc and upsmon are fakes in $t_tmp; a failing
# Telegram is played by a missing telegram.env.
# Single quotes around $… are intended: bash -c evaluates them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"
no_tg=/nonexistent/telegram.env

echo "device-watch.sh"
known=$DECOLAB_STATE_DIR/known-devices
net="192.0.2"
# MACs built at run time (tools/guard.sh scans the tests too)
m() { local IFS=:; printf '%s' "$*"; }
mac1=$(m 02 11 22 33 44 01) mac2=$(m a4 11 22 33 44 02) mac3=$(m 5c 11 22 33 44 03)
rnd=$(m 06 aa bb cc dd ee) up=$(m 5C AA BB CC DD 0F) low=$(m 5c aa bb cc dd 0f) other=$(m 5c 00 00 00 00 99)
cat >"$t_tmp/scan" <<EOF
#!/bin/sh
cat "$t_tmp/scan.out"
EOF
chmod +x "$t_tmp/scan"
export DEVICE_SCAN_CMD=$t_tmp/scan
printf '%s\t%s\t%s\n' "$net.1" "$mac2" "Router Maker" "$net.20" "$mac1" "" >"$t_tmp/scan.out"
check "the first run starts learning" 0 "learning: 2 seen, 2 known" -- script device-watch.sh
printf '%s\t%s\t%s\n' "$net.1" "$mac2" "Router Maker" "$net.21" "$mac3" "Phone Maker" >"$t_tmp/scan.out"
check "  during the learning phase new devices are learned silently" 0 "learning: 2 seen, 3 known" -- script device-watch.sh
same "  ... no message" "$(telegrams)" ""
echo 1 >"$known.start"
printf '%s\t%s\t%s\n' "$net.1" "$mac2" "Router Maker" "$net.30" "$rnd" "" "$net.31" "$up" "Laptop Maker" >"$t_tmp/scan.out"
check "after learning: new devices reported" 0 "OK: 3 devices, 2 new" -- script device-watch.sh
check "  ... with address and vendor, a random address marked" 0 "$rnd  unknown vendor (random address" -- telegrams
check "  ... the MAC in lower case" 0 "$low  Laptop Maker" -- telegrams
: >"$FAKE_CURL_LOG"
check "  ... and not again" 0 "0 new" -- script device-watch.sh
same "  ... no message" "$(telegrams)" ""
printf '%s\t%s\t\n' "$net.40" "$other" >"$t_tmp/scan.out"
check "the message fails: exit 1" 1 "the next run reports them again" -- env TELEGRAM_ENV_FILE=$no_tg "$t_root/scripts/device-watch.sh"
check "  ... not remembered, so reported next time" 0 "1 new" -- script device-watch.sh
printf 'garbage\n' >"$t_tmp/scan.out"
check "a scan that finds nothing is an error" 1 "the scan found no device" -- script device-watch.sh

echo "speedtest.sh"
cat >"$t_tmp/librespeed" <<'EOF'
#!/bin/sh
sid=""
while [ $# -gt 0 ]; do [ "$1" = --server ] && sid=$2; shift; done
echo "$sid" >>"$LS_LOG"
case " $LS_BROKEN " in *" $sid "*) echo "connection refused" >&2; exit 1 ;; esac
case " $LS_ZERO " in *" $sid "*) printf '[{"download":0,"upload":0,"ping":5}]'; exit 0 ;; esac
printf '[{"download":912.3,"upload":48.71,"ping":9.04,"jitter":1.2,"server":{"name":"S%s"},"bytes_received":900000000,"bytes_sent":50000000}]' "$sid"
EOF
chmod +x "$t_tmp/librespeed"
export LIBRESPEED_BIN=$t_tmp/librespeed LS_LOG=$t_tmp/ls.log LS_BROKEN="" LS_ZERO=""
prom=$DECOLAB_TEXTFILE_DIR/speedtest.prom
first=$(python3 -I -c 'import json, sys; print(" ".join(str(s["id"]) for s in json.load(open(sys.argv[1]))))' "$t_root/config/speedtest-servers.json")
read -r s1 s2 s3 <<<"$first"
check "a measurement" 0 "OK: cron: down 912.3 up 48.7 Mbit/s, ping 9.0 ms (S$s1, 950 MB)" -- script speedtest.sh
check "  for Prometheus" 0 "decolab_speedtest_download_mbit 912.3" -- cat "$prom"
check "  ... the run is ok" 0 "decolab_speedtest_last_run_ok 1" -- cat "$prom"
check "the first server fails: the next one measures" 0 "(S$s2," -- env LS_BROKEN="$s1" "$t_root/scripts/speedtest.sh"
check "a server reporting 0 Mbit/s is skipped" 0 "(S$s3," -- env LS_BROKEN="$s1" LS_ZERO="$s2" "$t_root/scripts/speedtest.sh"
check "all fail: exit 1 with every reason" 1 "server $s2: exit 1 connection refused" -- env LS_BROKEN="$s1 $s2 $s3" "$t_root/scripts/speedtest.sh"
check "  ... the last good values stay" 0 "decolab_speedtest_download_mbit 912.3" -- cat "$prom"
check "  ... the run is not ok" 0 "decolab_speedtest_last_run_ok 0" -- cat "$prom"
check "  ... the history has the error" 0 '"error": "server' -- cat "$DECOLAB_STATE_DIR/speedtest-history.json"
check "--manual within 10 minutes: no new run" 0 "less than 10 minutes old" -- script speedtest.sh --manual
check "a run already going: nothing to do" 0 "already running" -- bash -c 'exec 3>>"$1/speedtest.lock"; python3 -I -c "import fcntl, os, subprocess, sys
fcntl.flock(3, fcntl.LOCK_EX)
sys.exit(subprocess.run([sys.argv[1]]).returncode)" "$2"' _ "$DECOLAB_RUN_DIR" "$t_root/scripts/speedtest.sh"
sed -i.bak 's/^SPEEDTEST=.*/SPEEDTEST=no/' "$DECOLAB_CONF"
check "SPEEDTEST=no: nothing measured" 0 "speed test is off" -- script speedtest.sh
check "  ... and no stale values left" 0 "" -- test ! -e "$prom"
mv "$DECOLAB_CONF.bak" "$DECOLAB_CONF"
grep -q -- "--concurrent" "$t_root/lib/speedtest.py" && same "8 connections per direction" "$(sed -n 's/^CONCURRENT = //p' "$t_root/lib/speedtest.py")" "8"

echo "ups-metrics.sh / ups-event.sh"
cat >"$t_tmp/upsc" <<'EOF'
#!/bin/sh
[ -z "$UPSC_DOWN" ] || { echo "Error: Data stale"; exit 1; }
printf 'battery.charge: %s\nbattery.charge.low: 20\nbattery.runtime: %s\nbattery.runtime.low: 300\nups.load: 12\noutput.voltage: 230.0\n' \
  "${UPSC_CHARGE:-100}" "${UPSC_RT:-2700}"
[ -n "$UPSC_NOSTATUS" ] || printf 'ups.status: %s\n' "${UPSC_STATUS:-OL}"
EOF
printf '#!/bin/sh\necho "upsmon $*" >>"%s/upsmon.calls"\n' "$t_tmp" >"$t_tmp/upsmon"
chmod +x "$t_tmp/upsc" "$t_tmp/upsmon"
export UPS_UPSC=$t_tmp/upsc UPS_UPSMON=$t_tmp/upsmon UPS_SUDO="" UPS_CONF=$t_tmp/ups.conf UPSC_DOWN="" UPSC_NOSTATUS="" UPS_BOOT=100
: >"$t_tmp/ups.conf"
ev() { "$t_root/scripts/ups-event.sh" "$@" </dev/null; }
ups_prom=$DECOLAB_TEXTFILE_DIR/ups.prom

: >"$FAKE_CURL_LOG"
check "the UPS on mains" 0 "" -- script ups-metrics.sh
check "  for Prometheus" 0 "decolab_ups_on_line 1" -- cat "$ups_prom"
check "  ... the readings" 0 "decolab_ups_runtime_seconds 2700.0" -- cat "$ups_prom"
same "  Kuma up with the state" "$(kuma UPS)" "up OL | battery 100 % | about 45 min"
check "NUT does not answer: Kuma down" 1 "Data stale" -- env UPSC_DOWN=1 "$t_root/scripts/ups-metrics.sh"
same "  ... down" "$(kuma UPS | cut -d' ' -f1)" "down"
check "  ... and no old readings stay (a flat line looks like a full battery)" 0 "" -- bash -c '! grep -q battery_percent "$1" && grep -q "^decolab_ups_reachable 0$" "$1"' _ "$ups_prom"
check "upsc answers without a status (driver lost the UPS): not reachable" 1 "" -- env UPSC_NOSTATUS=1 "$t_root/scripts/ups-metrics.sh"
check "  ... and its numbers are not shown as readings" 0 "" -- bash -c '! grep -q battery_percent "$1" && grep -q "^decolab_ups_reachable 0$" "$1"' _ "$ups_prom"
check "HW_UPS=auto without NUT: nothing at all" 0 "" -- env UPS_CONF=/nonexistent "$t_root/scripts/ups-metrics.sh"

: >"$FAKE_CURL_LOG"
check "power lost: a message" 0 "" -- env UPSC_STATUS=OB UPSC_RT=1500 "$t_root/scripts/ups-event.sh" power-lost
check "  ... with charge and runtime" 0 "Battery: 100 % · runtime: about 25 min" -- telegrams
check "  ... the start is noted" 0 "" -- test -s "$DECOLAB_STATE_DIR/ups-on-battery-since"
echo $(($(date +%s) - 330)) >"$DECOLAB_STATE_DIR/ups-on-battery-since"
check "power back" 0 "" -- ev power-back
check "  ... a message with how long" 0 "On mains again after 6 min" -- telegrams
check "an unknown event is refused" 2 "" -- ev rm-rf
check "  ... and logged" 0 "REFUSED: unknown event 'rm-rf'" -- cat "$DECOLAB_LOG_DIR/ups-event.log"

check "battery-limit on battery: forced shutdown" 0 "" -- env UPSC_STATUS="OB DISCHRG" "$t_root/scripts/ups-event.sh" battery-limit
check "  ... upsmon -c fsd" 0 "upsmon -c fsd" -- cat "$t_tmp/upsmon.calls"
rm -f "$t_tmp/upsmon.calls"
check "battery-limit on mains (a timer left behind): nothing" 0 "" -- env UPSC_STATUS=OL "$t_root/scripts/ups-event.sh" battery-limit
check "  ... no shutdown" 0 "" -- test ! -e "$t_tmp/upsmon.calls"

# The night of a long outage without internet: every message waits.
: >"$FAKE_CURL_LOG"
check "no internet: power lost is queued" 0 "" -- env TELEGRAM_ENV_FILE=$no_tg UPSC_STATUS=OB "$t_root/scripts/ups-event.sh" power-lost
check "  shutting down is queued behind it" 0 "" -- env TELEGRAM_ENV_FILE=$no_tg UPSC_STATUS="OB LB" "$t_root/scripts/ups-event.sh" shutdown
check "  FSD and SHUTDOWN both arrive: only the first reports" 0 "already reported" -- bash -c 'TELEGRAM_ENV_FILE=$2 "$1" shutdown; cat "$3"' _ "$t_root/scripts/ups-event.sh" "$no_tg" "$DECOLAB_LOG_DIR/ups-event.log"
same "  two messages wait" "$(find "$DECOLAB_STATE_DIR/ups-queue" -name '*.msg' | wc -l | tr -d ' ')" "2"
same "  nothing was sent" "$(telegrams)" ""
# The host starts again (boot time after the mark), on mains, internet back.
check "after the restart: the queue goes out, then 'back'" 0 "" -- env UPS_BOOT=$(($(date +%s) + 60)) "$t_root/scripts/ups-metrics.sh"
same "  in order: power cut, shutting down, back" "$(telegrams | grep -E '^(⚡|🔋|✅) ' | sed 's/^[^ ]* [^:]*: //' | tr '\n' '|')" "power cut, running on battery|shutting down (power cut)|back after UPS shutdown|"
check "  late ones say so" 0 "Delivered late, originally" -- telegrams
check "  'back' names the outage" 0 "Power cut from" -- telegrams
check "  the queue is empty, the marks are gone" 0 "" -- bash -c '! ls "$1"/ups-queue/*.msg 2>/dev/null && test ! -e "$1/ups-shut-down" && test ! -e "$1/ups-on-battery-since"' _ "$DECOLAB_STATE_DIR"
: >"$FAKE_CURL_LOG"
check "  ... and 'back' only once" 0 "" -- env UPS_BOOT=$(($(date +%s) + 60)) "$t_root/scripts/ups-metrics.sh"
same "  ... nothing more" "$(telegrams)" ""

: >"$FAKE_CURL_LOG"
check "offline: usb-lost waits" 0 "" -- env TELEGRAM_ENV_FILE=$no_tg "$t_root/scripts/ups-event.sh" usb-lost
check "online again, a new event: the waiting one goes out FIRST" 0 "" -- ev usb-back
same "  ... in order" "$(telegrams | grep -E '^(⚠️|✅) ' | sed 's/^[^ ]* [^:]*: //' | tr '\n' '|')" "UPS not reachable|UPS reachable again|"
: >"$FAKE_CURL_LOG"
date +%s >"$DECOLAB_STATE_DIR/ups-shut-down"
check "a mark from a shutdown that has not happened yet (boot before it): no 'back'" 0 "" -- script ups-metrics.sh
same "  ... nothing" "$(telegrams)" ""
check "  ... the mark stays" 0 "" -- test -e "$DECOLAB_STATE_DIR/ups-shut-down"
check "two runs at once: only one sends 'back'" 0 "" -- env FAKE_FLOCK_BUSY=1 UPS_BOOT=$(($(date +%s) + 60)) "$t_root/scripts/ups-metrics.sh"
same "  ... the busy one does not" "$(telegrams)" ""
rm -f "$DECOLAB_STATE_DIR/ups-shut-down"

check "the queue keeps at most 30" 0 "" -- bash -c 'for i in $(seq 1 35); do TELEGRAM_ENV_FILE=$2 "$1" usb-lost; done' _ "$t_root/scripts/ups-event.sh" "$no_tg"
same "  ... 30" "$(find "$DECOLAB_STATE_DIR/ups-queue" -name '*.msg' | wc -l | tr -d ' ')" "30"

echo "decolab-tailnet-ports"
a="100.64"
export FAKE_TAILSCALE_NETMAP='{"PacketFilter": [
 {"Srcs": ["'$a'.0.5/32"], "Dsts": [{"Net": "*", "Ports": {"First": 443, "Last": 443}}, {"Net": "*", "Ports": {"First": 8000, "Last": 8100}}]},
 {"Srcs": ["'$a'.0.0/24"], "Dsts": [{"Net": "*", "Ports": {"First": 22, "Last": 22}}]},
 {"Srcs": ["'$a'.9.9/32"], "Dsts": [{"Net": "*", "Ports": {"First": 0, "Last": 65535}}]}]}'
check "a device: its rules and those of its network" 0 "22
443
8000-8100" -- "$t_root/bin/decolab-tailnet-ports" "$a.0.5"
refute "  ... not the rule of another device" "0-65535"
check "a device without a rule" 0 "none" -- "$t_root/bin/decolab-tailnet-ports" "$a.1.1"
check "no IP address" 1 "not an IP address" -- "$t_root/bin/decolab-tailnet-ports" "my-phone"

echo "decolab-harden-unit"
mkdir -p "$t_tmp/sbin" "$t_tmp/systemd/demo.service.d"
printf '#!/bin/sh\nexec "$@"\n' >"$t_tmp/sbin/sudo" && chmod +x "$t_tmp/sbin/sudo"
# systemctl: active unless the drop-in contains BREAK; with CRASHLATER the
# restart counter grows with every look (a crash while watching).
export FAKE_SYSTEMCTL='d="'$t_tmp'/systemd/demo.service.d/decolab-hardening.conf"
case $1 in
  is-active) if grep -q BREAK "$d" 2>/dev/null; then echo failed; exit 3; fi; echo active ;;
  show) n=$(cat "'$t_tmp'/restarts" 2>/dev/null || echo 0); echo "$n"
    grep -q CRASHLATER "$d" 2>/dev/null && echo $((n + 1)) >"'$t_tmp'/restarts" ;;
esac; exit 0'
harden() { env PATH="$t_tmp/sbin:$PATH" HARDEN_SYSTEMD_DIR="$t_tmp/systemd" HARDEN_SETTLE_S=0 HARDEN_WATCH_S=0 "$t_root/bin/decolab-harden-unit" "$@"; }
dropin=$t_tmp/systemd/demo.service.d/decolab-hardening.conf
printf '[Service]\nProtectHome=yes\n' >"$dropin"
check "a working drop-in stays" 0 "✓ running and working" -- harden demo true <<<"$(printf '[Service]\nProtectSystem=strict')"
check "  ... installed" 0 "ProtectSystem=strict" -- cat "$dropin"
check "the service stops: taken back, the EARLIER drop-in restored" 1 "earlier drop-in restored" -- harden demo true <<<"BREAK"
check "  ... it is the earlier one" 0 "ProtectSystem=strict" -- cat "$dropin"
check "the service runs but fails its check: taken back" 1 "fails its check" -- harden demo false <<<"[Service]"
check "a delayed crash (a restart while watching): taken back" 1 "restarted in the meantime" -- harden demo true <<<"CRASHLATER"
rm -f "$t_tmp/restarts" "$dropin"
check "no drop-in before: none after a failure" 1 "(no drop-in)" -- harden demo true <<<"BREAK"
check "  ... gone" 0 "" -- test ! -e "$dropin"
check "a bad unit name is refused" 2 "invalid unit name" -- harden 'demo;rm' true <<<"x"
unset FAKE_SYSTEMCTL

t_finish
