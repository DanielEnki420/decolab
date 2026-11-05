#!/usr/bin/env bash
# Contract tests for the fan control service (services/fan_control.py).
# The hardware is files in $t_tmp: temperatures in millidegrees, the PWM the
# service writes, the RPM it reads. The service runs with a short interval
# for a moment, then gets SIGTERM, as from systemctl stop.
# Single quotes around $… are intended: bash -c evaluates them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

h=$t_tmp/hw
mkdir -p "$h"
cat >"$t_tmp/notify" <<EOF
#!/bin/sh
printf '%s | %s\n' "\$1" "\$2" >>"$t_tmp/alarms"
EOF
printf '#!/bin/sh\nprintf "VDD_CORE_A current(7)=1.50000000A\\nVDD_CORE_V volt(7)=0.80000000V\\n3V3_SYS_A current(0)=0.10000000A\\n3V3_SYS_V volt(0)=3.30000000V\\n"\n' >"$t_tmp/vcgencmd"
chmod +x "$t_tmp/notify" "$t_tmp/vcgencmd"
export FAN_CPU_PATH=$h/cpu FAN_NVME_PATH=$h/nvme FAN_PWM_PATH=$h/pwm FAN_RPM_PATH=$h/rpm \
  FAN_METRICS=$t_tmp/fan.prom FAN_ENERGY=$t_tmp/energy FAN_NOTIFY=$t_tmp/notify FAN_VCGENCMD=$t_tmp/vcgencmd \
  FAN_OVERRIDE=$t_tmp/override.json FAN_INTERVAL=0.05 FAN_NIGHT=0 FAN_SENSORS="cpu nvme"

# hw CPU NVME [RPM] - temperatures in °C ("-" = sensor file missing)
hw() {
  rm -f "$h/cpu" "$h/nvme"
  [ "$1" = - ] || echo "$(($1 * 1000))" >"$h/cpu"
  [ "$2" = - ] || echo "$(($2 * 1000))" >"$h/nvme"
  echo "${3:-1500}" >"$h/rpm"
}
# run SECONDS [ARGS] - the service for a while, then SIGTERM; the PWM it
# had set just before is in $pwm_before_stop
run() {
  : >"$t_tmp/pwm-seen"
  rm -f "$t_tmp/alarms"
  python3 -I "$t_root/services/fan_control.py" "${@:2}" >"$t_tmp/fan.log" 2>&1 &
  local pid=$!
  sleep "$1"
  pwm_before_stop=$(cat "$h/pwm" 2>/dev/null)
  kill -TERM "$pid"
  wait "$pid"
  rc=$?
}

echo "fan_control.py"
hw 45 40
run 1
same "45 °C: the curve's value" "$pwm_before_stop" "64"
same "  stops cleanly on SIGTERM" "$rc" "0"
same "  ... and leaves the fan at the safe value" "$(cat "$h/pwm")" "150"
check "  metrics: PWM and both sensors" 0 'decolab_fan_sensor_ok{sensor="nvme"} 1' -- cat "$t_tmp/fan.prom"
check "  ... the SoC power from the PMIC" 0 "decolab_soc_power_watts 1.53" -- cat "$t_tmp/fan.prom"
check "  ... no failsafe" 0 "decolab_fan_failsafe_active 0" -- cat "$t_tmp/fan.prom"
check "  ... readable for node_exporter" 0 "" -- test "$(find "$t_tmp/fan.prom" -perm -004 | wc -l)" -eq 1
same "  no alarm" "$(cat "$t_tmp/alarms" 2>/dev/null)" ""

hw 45 40
echo 3000 >"$h/cpu" # 3 °C: implausible, the old bug read failures as 0 °C
run 1
check "an implausible value counts as a failed sensor: failsafe floor" 0 "" -- test "$pwm_before_stop" -ge 180
check "  ... alarm names the sensor" 0 "Temperature sensor cpu failed" -- cat "$t_tmp/alarms"
check "  ... metrics say so" 0 'decolab_fan_sensor_ok{sensor="cpu"} 0' -- cat "$t_tmp/fan.prom"

hw - 84
run 1
same "one sensor dead, the other hot: the curve above the floor" "$pwm_before_stop" "250"
hw - -
run 1
same "both sensors dead: full speed" "$pwm_before_stop" "255"
check "  ... alarm" 0 "No temperature sensor readable" -- cat "$t_tmp/alarms"
check "  ... the metric omits nothing it has: failsafe 1" 0 "decolab_fan_failsafe_active 1" -- cat "$t_tmp/fan.prom"

hw 75 40
FAN_NIGHT=1 run 1
same "night: capped" "$pwm_before_stop" "70"
check "  ... metric" 0 "decolab_fan_night_mode_active 1" -- cat "$t_tmp/fan.prom"
hw 85 40
FAN_NIGHT=1 run 1
same "night at 85 °C: the escape lifts the cap" "$pwm_before_stop" "255"

hw 85 40
echo '{"mode": "fixed", "pwm": 0}' >"$t_tmp/override.json"
run 1
same "an override 'fan off' at 85 °C: the escape wins" "$pwm_before_stop" "255"
hw 45 40
run 1
same "  ... at 45 °C the override holds" "$pwm_before_stop" "0"
echo "{\"mode\": \"max\", \"until\": $(($(date +%s) - 10))}" >"$t_tmp/override.json"
run 1
same "an expired override: automatic, and it is deleted" "$pwm_before_stop $(test -e "$t_tmp/override.json" && echo kept)" "64 "

hw 70 40 0
run 1
check "hot and the fan does not turn: fan failure alarm" 0 "Fan failure" -- cat "$t_tmp/alarms"

hw 45 40
mv "$h/pwm" "$h/pwm.file" 2>/dev/null
mkdir "$h/pwm" # writing fails
run 1
same "the PWM cannot be written: no crash, it keeps running" "$rc" "0"
check "  ... alarm" 0 "cannot set the speed" -- cat "$t_tmp/alarms"
check "  ... the error counter" 0 "" -- bash -c 'grep -qE "^decolab_fan_pwm_write_errors_total [1-9]" "$1"' _ "$t_tmp/fan.prom"
rmdir "$h/pwm"

hw 45 40
printf '[[50, 100], [40, 60]]' >"$t_tmp/curve.json"
FAN_CURVE=$t_tmp/curve.json run 1
same "a broken curve file: the default curve" "$pwm_before_stop" "64"
check "  ... loudly" 0 "Fan curve" -- cat "$t_tmp/alarms"
printf '[[30, 100], [60, 200]]' >"$t_tmp/curve.json"
FAN_CURVE=$t_tmp/curve.json run 1
same "a valid curve file is used" "$pwm_before_stop" "150"

hw 45 -
FAN_SENSORS="" run 1
same "auto sensors with an NVMe path set: both expected (dead NVMe = failsafe)" "$(test "$pwm_before_stop" -ge 180 && echo yes)" "yes"
if ! grep -qx nvme /sys/class/hwmon/hwmon*/name 2>/dev/null; then
  hw 45 -
  FAN_SENSORS="" FAN_NVME_PATH="" run 1
  same "no NVMe in this machine: only the CPU, no failsafe" "$pwm_before_stop" "64"
fi

hw 45 40
run 1 --dry-run
same "--dry-run writes no PWM" "$(cat "$h/pwm")" "150" # still the value of the last run

t_finish
