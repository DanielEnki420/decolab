#!/usr/bin/env bash
# Contract tests for the OLED display (services/oled_display.py --print):
# what the pages show, from a fake /proc and fake hwmon devices. No
# display, no PIL needed.
# Single quotes around $… are intended: bash -c evaluates them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

p=$t_tmp/proc hw=$t_tmp/hwmon tf=$t_tmp/textfile st=$t_tmp/state bk=$t_tmp/backups
mkdir -p "$p" "$tf" "$st" "$bk"
echo "cpu  100 0 100 600 200 0 0 0 0 0" >"$p/stat"
printf 'MemTotal:       8000000 kB\nMemFree:         100000 kB\nMemAvailable:    6000000 kB\n' >"$p/meminfo"
echo "93784.12 300000.00" >"$p/uptime"
# hwmon numbers on purpose NOT in the order the original assumed
dev() { mkdir -p "$hw/hwmon$1" && echo "$2" >"$hw/hwmon$1/name" && echo "$3" >"$hw/hwmon$1/$4"; }
dev 0 nvme 41850 temp1_input
dev 1 rp1_adc 1 in1_input
dev 2 cpu_thermal 52300 temp1_input
dev 3 pwmfan 2100 fan1_input
echo "0|0|" >"$st/services"
printf 'decolab_ups_on_battery 0\ndecolab_ups_battery_percent 100\n' >"$tf/ups.prom"
mkdir "$bk/$(date -v-3H +%Y-%m-%d_%H-%M 2>/dev/null || date -d '3 hours ago' +%Y-%m-%d_%H-%M)"
export OLED_PROC=$p OLED_HWMON=$hw DECOLAB_TEXTFILE_DIR=$tf DECOLAB_STATE_DIR=$st BACKUP_DIR=$bk \
  OLED_MESSAGE=$t_tmp/msg.json LAN_INTERFACE=""
show() { python3 -I "$t_root/services/oled_display.py" --print; }

echo "oled_display.py"
check "CPU load from /proc/stat (iowait counts as idle)" 0 "CPU 20.0% [##        ]" -- show
check "RAM from MemAvailable" 0 "RAM 25.0%" -- show
check "the fan by name, not by number" 0 "Fan: 2100 RPM" -- show
check "CPU temperature by name" 0 "CPU  52.3C" -- show
check "NVMe temperature by name (hwmon0, not hwmon1)" 0 "NVMe 41.9C" -- show
check "uptime" 0 "Up: 1d 2h" -- show
check "the Decolab page: power, backup, services" 0 "Power: mains
Backup: 3 h
Services: ok" -- show

rm "$hw/hwmon0/temp1_input"
echo 0 >"$hw/hwmon2/temp1_input"
check "a failed sensor shows -- (never 0.0)" 0 "NVMe   --C" -- show
check "  ... an implausible 0 as well" 0 "CPU    --C" -- show
refute "  ... no 0.0 anywhere" " 0.0C"
rm -rf "$hw/hwmon3"
check "no fan: --" 0 "Fan: --" -- show

printf 'decolab_ups_on_battery 1\ndecolab_ups_battery_percent 64\n' >"$tf/ups.prom"
echo "2|1| a b c" >"$st/services"
rm -rf "${bk:?}"/*
mkdir "$bk/2020-01-01_03-00"
check "on battery, an old backup, failed services: said plainly" 0 "BATTERY 64%" -- show
check "  ... the backup is OLD" 0 "OLD" -- show
check "  ... services" 0 "FAILED: 3" -- show

echo '{"text": "Back at 6", "expires": 0}' >"$t_tmp/msg.json"
check "a message" 0 "MESSAGE: Back at 6" -- show
echo "{\"text\": \"old\", \"expires\": $(($(date +%s) - 5))}" >"$t_tmp/msg.json"
check "an expired message is gone" 0 "" -- bash -c '! "$@" | grep -q MESSAGE' _ python3 -I "$t_root/services/oled_display.py" --print
check "  ... and deleted" 0 "" -- test ! -e "$t_tmp/msg.json"
check "the unit must not hide /proc/stat (ProcSubset=pid)" 0 "" -- bash -c '! grep -q "^ProcSubset=pid" "$1"' _ "$t_root/config/systemd/decolab-oled.service.template"

t_finish
