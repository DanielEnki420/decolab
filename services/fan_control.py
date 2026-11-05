#!/usr/bin/env python3
"""fan_control.py - temperature curve for the Raspberry Pi 5 fan (HW_FAN).

Runs as the systemd service decolab-fan. Reads the CPU and (if there is
one) the NVMe temperature, sets the PWM of the hwmon device "pwmfan" (the
Pi 5 fan header: Active Cooler or a case fan on it), and writes fan.prom.

Every rule below is a way the original system once ended up with "no
cooling, no message":
 1. A read error returned 0.0 °C, which the curve turned into its MINIMUM,
    and the alarm needed 60 °C: a dead sensor meant minimal cooling in
    silence. Now a failed or implausible reading is None, never a number.
    One sensor dead: at least FAILSAFE_FLOOR; both dead: full speed.
 2. An override could switch the fan off, and the fan-failure alarm needed
    PWM > 60. Now every cap (override, night) is lifted from ESCAPE_TEMP on.
 3. The night mode capped BEFORE the emergency rule: 85 °C at 3 a.m. stayed
    at night speed. Now the escape comes last.
 4. No SIGTERM handler: "systemctl stop" froze the fan at its last value
    (maybe the minimum). Now stopping leaves it at STOP_PWM.
 5. A PermissionError on writing crashed the service; Restart=always made
    that a restart loop every 5 s that systemd never reports as failed.
    Now writing never raises; it alarms and keeps regulating.
 6. A fixed hwmon number (hwmon2) pointed to another device after a kernel
    update. Now devices are found by NAME, again after every read error.
 7. A single read per cycle made the fan hunt: the CPU sensor steps by about
    0.55 °C, and in the flat part of the curve that changed the PWM in two
    of three cycles (10,924 changes a day). The curve gets the mean of the
    last 30 s and goes down only when it is 1 °C cooler (509 changes a day,
    rather cooler on average). Escape, alarms and failsafe see the RAW value:
    real heat does not wait 30 s.
 8. A metrics file that could not be written left the old one in place:
    Prometheus read it as a flat, believable line for two weeks. Every
    failure is logged once (and its recovery), and TextfileMetricStale
    catches a writer that stopped.

Sensors: the CPU always; the NVMe only if hwmon "nvme" exists at start (a
Pi without NVMe must not run in failsafe for ever). FAN_SENSORS="cpu nvme"
forces both.

Override (FAN_OVERRIDE, default /run/decolab/fan-override.json, tmpfs: it
does not survive a reboot):
  {"mode": "auto"} | {"mode": "quiet"} (max 60) | {"mode": "max"} |
  {"mode": "fixed", "pwm": 100}; optional "until": <unix time>.
  Without "until" it expires after 6 hours: a forgotten override must not
  disable the regulation for ever.
Curve (FAN_CURVE, optional JSON [[temp, pwm], ...], ascending): checked
when it changes; a broken file falls back to the default curve, loudly.

Paths can be set in the environment for tests: FAN_CPU_PATH, FAN_NVME_PATH,
FAN_PWM_PATH, FAN_RPM_PATH (then ONLY that path is used: a fallback to the
real sensor once made every failure test worthless), FAN_METRICS,
FAN_ENERGY, FAN_NOTIFY, FAN_INTERVAL, FAN_NIGHT (0/1), FAN_VCGENCMD.
"""

import collections
import datetime
import glob
import itertools
import json
import logging
import os
import signal
import subprocess
import sys
import time

logging.basicConfig(level=logging.INFO, format="%(asctime)s [fan] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
log = logging.getLogger("fan")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CURVE_FILE = os.environ.get("FAN_CURVE", "")
OVERRIDE_FILE = os.environ.get("FAN_OVERRIDE", "/run/decolab/fan-override.json")
METRICS_FILE = os.environ.get("FAN_METRICS", "/var/lib/node_exporter/fan.prom")
ENERGY_STATE = os.environ.get("FAN_ENERGY", "/var/lib/decolab/soc-energy.state")
NOTIFY = os.environ.get("FAN_NOTIFY", os.path.join(ROOT, "bin", "decolab-notify"))
VCGENCMD = os.environ.get("FAN_VCGENCMD", "vcgencmd")
PATH_ENV = {k: os.environ.get(f"FAN_{k.upper()}_PATH") for k in ("cpu", "nvme", "pwm", "rpm")}

INTERVAL = float(os.environ.get("FAN_INTERVAL", "5"))
PWM_DEADBAND = 2
SMOOTH_S = 30
TEMP_HYST = 1.0
RAMP_UP = 255           # up at once: hardly audible; up-and-down pumping is
RAMP_DOWN = 8           # (from 40 to 255 took over a minute with 15 both ways)
NIGHT_START, NIGHT_END, NIGHT_PWM_MAX = 23, 7, 70
ESCAPE_TEMP = 78.0      # from here every cap is lifted: night and override
HOT_TEMP, HOT_CYCLES = 80.0, 6   # reported even while the fan turns, after 30 s
ALERT_RPM_MIN, ALERT_TEMP = 100, 60.0
ALERT_COOLDOWN = 900
TEMP_MIN_PLAUS, TEMP_MAX_PLAUS = 5.0, 125.0
FAILSAFE_FLOOR = 180    # a FLOOR, not a fixed value: 82 °C must still get 240
FAILSAFE_BOTH = 255
FAIL_DEBOUNCE = 3       # 3 bad readings in, 3 good ones out: no howl per glitch
STOP_PWM = 150
OVERRIDE_MAX_AGE = 6 * 3600
DEFAULT_CURVE = [(40, 40), (50, 88), (61, 130), (70, 190), (85, 255)]

_alert_at: dict[str, float] = {}  # cooldown PER alarm: one global cooldown let new
_curve = list(DEFAULT_CURVE)  # alarms silence each other for 15 minutes
_curve_mtime = 0.0
_hwmon: dict[tuple[str, str], str] = {}
_pwm_write_errors = 0
_troubles: dict[str, bool] = {}
_stop = False


def alarm(key, title, text):
    """The cooldown starts only after a DELIVERED message: a failed send must
    not cost 15 minutes of silence."""
    now = time.time()
    if now - _alert_at.get(key, 0) < ALERT_COOLDOWN:
        return
    try:
        r = subprocess.run([NOTIFY, title, text], timeout=30, check=False, capture_output=True)
        if r.returncode == 0:
            _alert_at[key] = now
            log.warning("alarm sent: %s", title)
        else:
            log.error("alarm NOT delivered (exit %s), no cooldown: %s", r.returncode, title)
    except Exception as e:  # noqa: BLE001 - any failure: log, keep regulating
        log.error("alarm NOT delivered (%s), no cooldown: %s", e, title)


def once(what, error):
    """A trouble logged once, its recovery once: not every 5 s, not never."""
    if error is not None:
        if what not in _troubles:
            log.warning("%s failing: %s (reported once until it recovers)", what, error)
        _troubles[what] = True
    elif _troubles.pop(what, None):
        log.info("%s works again", what)


def load_curve():
    global _curve, _curve_mtime
    if not CURVE_FILE:
        return _curve
    try:
        m = os.path.getmtime(CURVE_FILE)
        if m == _curve_mtime:
            return _curve
        with open(CURVE_FILE) as f:
            points = [(int(t), int(p)) for t, p in json.load(f)]
        if not points or sorted(points) != points:
            raise ValueError("empty or not ascending")
        if any(not (0 <= t <= 100 and 0 <= p <= 255) for t, p in points):
            raise ValueError("value out of range")
        _curve, _curve_mtime = points, m
        log.info("curve loaded from %s: %s", CURVE_FILE, points)
    except Exception as e:  # noqa: BLE001
        if _curve_mtime != -1:
            log.error("curve not loadable (%s): default curve %s", e, DEFAULT_CURVE)
            alarm("curve", "⚠️ Fan curve", f"{CURVE_FILE} is not usable: {e}\nUsing the default curve.")
            _curve, _curve_mtime = list(DEFAULT_CURVE), -1
    return _curve


def hwmon_path(name, file, fresh=False):
    """/sys/class/hwmon/hwmonN/FILE of the device NAME, or None. Never a
    silent fallback to hwmon0 (that once delivered the CPU temperature as
    the NVMe value). Numbers follow probe order and can change at runtime."""
    key = (name, file)
    if fresh:
        _hwmon.pop(key, None)
    if key in _hwmon:
        return _hwmon[key]
    hits = []
    for nm in glob.glob("/sys/class/hwmon/hwmon*/name"):
        try:
            with open(nm) as f:
                if f.read().strip() == name:
                    p = os.path.join(os.path.dirname(nm), file)
                    if os.path.exists(p):
                        hits.append(p)
        except OSError:
            continue
    if not hits:
        return None
    _hwmon[key] = min(hits)
    return _hwmon[key]


HWMON = {"cpu": ("cpu_thermal", "temp1_input"), "nvme": ("nvme", "temp1_input"),
         "pwm": ("pwmfan", "pwm1"), "rpm": ("pwmfan", "fan1_input")}


def path(kind, fresh=False):
    return PATH_ENV[kind] or hwmon_path(*HWMON[kind], fresh=fresh)


def read_temp(kind):
    """None on failure, never 0.0. An explicit path is used ALONE."""
    candidates = [PATH_ENV[kind]] if PATH_ENV[kind] else [p for p in (path(kind), path(kind, fresh=True)) if p]
    for p in dict.fromkeys(c for c in candidates if c):
        try:
            with open(p) as f:
                value = int(f.read().strip()) / 1000
        except (OSError, ValueError):
            continue
        if TEMP_MIN_PLAUS <= value <= TEMP_MAX_PLAUS:
            return value
        log.warning("sensor %s reads an implausible %.1f °C: counted as failed", kind, value)
    return None


def read_rpm():
    p = path("rpm")
    try:
        with open(p) as f:
            return int(f.read().strip())
    except (OSError, ValueError, TypeError):
        return 0


def set_pwm(value):
    """The written value, or None. Never raises (see rule 5)."""
    global _pwm_write_errors
    value = max(0, min(255, int(value)))
    p = path("pwm")
    if not p:
        _pwm_write_errors += 1
        alarm("pwm-path", "🚨 Fan not controllable",
              "No hwmon device 'pwmfan': the PWM cannot be set. The kernel's thermal governor is the only protection now.")
        return None
    try:
        with open(p, "w") as f:
            f.write(str(value))
        return value
    except OSError as e:
        _pwm_write_errors += 1
        alarm("pwm-write", "🚨 Fan: cannot set the speed",
              f"Writing the PWM failed ({e}). Regulation goes on but has no effect. Errors so far: {_pwm_write_errors}")
        return None


def temp_to_pwm(temp, curve):
    if temp <= curve[0][0]:
        return curve[0][1]
    for (t0, p0), (t1, p1) in itertools.pairwise(curve):
        if t0 <= temp <= t1:
            return int(p0 + (temp - t0) / (t1 - t0) * (p1 - p0)) if t1 != t0 else p1
    return curve[-1][1]


def curve_target(temp, curve, current):
    """Up at once, down only TEMP_HYST cooler."""
    target = temp_to_pwm(temp, curve)
    if current >= 0 and target < current:
        target = min(current, temp_to_pwm(temp + TEMP_HYST, curve))
    return target


def is_night():
    forced = os.environ.get("FAN_NIGHT")
    if forced in ("0", "1"):
        return forced == "1"
    h = datetime.datetime.now().hour
    return h >= NIGHT_START or h < NIGHT_END


def read_override():
    try:
        with open(OVERRIDE_FILE) as f:
            d = json.load(f)
        until = d.get("until")
        expired = (time.time() > float(until)) if until is not None else \
            (time.time() - os.path.getmtime(OVERRIDE_FILE) > OVERRIDE_MAX_AGE)
        if expired:
            log.info("override expired: back to automatic")
            os.remove(OVERRIDE_FILE)
            return None
        return d
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def ramp(current, target):
    return min(target, current + RAMP_UP) if target > current else max(target, current - RAMP_DOWN)


def read_watts():
    """Sum of the rails the PMIC measures: SoC and RAM, WITHOUT NVMe, fan,
    USB and power supply losses (the PMIC measures no input current). About
    2 W where the socket sees 4-7 W: hence the name soc_power, not power."""
    try:
        out = subprocess.run([VCGENCMD, "pmic_read_adc"], capture_output=True, text=True, timeout=3, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    amps, volts = {}, {}
    for line in out.splitlines():
        p = line.split()
        if len(p) < 2 or "=" not in p[-1]:
            continue
        try:
            val = float(p[-1].split("=", 1)[1].rstrip("AV"))
        except ValueError:
            continue
        if p[0].endswith("_A"):
            amps[p[0][:-2]] = val
        elif p[0].endswith("_V"):
            volts[p[0][:-2]] = val
    if not amps:
        return None  # it ran but measured nothing: no value, not 0
    return round(sum(a * volts.get(r, 0) for r, a in amps.items()), 2)


def update_energy(watts):
    try:
        now, total, last = time.time(), 0.0, time.time()
        if os.path.exists(ENERGY_STATE):
            with open(ENERGY_STATE) as f:
                parts = f.read().split()
            if len(parts) >= 2:
                total, last = float(parts[0]), float(parts[1])
        dt_h = (now - last) / 3600.0
        if 0 < dt_h < 0.1:  # a gap (service stopped) adds nothing invented
            total += watts * dt_h / 1000.0
        with open(ENERGY_STATE + ".tmp", "w") as f:
            f.write("%f %f" % (total, now))
        os.replace(ENERGY_STATE + ".tmp", ENERGY_STATE)
        once("energy counter", None)
        return round(total, 6)
    except (OSError, ValueError) as e:
        once("energy counter", e)
        return None


def write_metrics(temps, pwm, rpm, mode, failsafe):
    """Atomic. A missing reading is a MISSING line: a 0 looks like a valid
    value in a dashboard, and like a reset in a counter."""
    try:
        watts = read_watts()
        once("power reading (vcgencmd)", None if watts is not None else "no value")
        energy = update_energy(watts) if watts is not None else None
        z = ["# HELP decolab_fan_pwm PWM the fan control set (0-255), -1 = none set yet.",
             "# TYPE decolab_fan_pwm gauge", "decolab_fan_pwm %d" % (pwm if pwm is not None else -1),
             "# HELP decolab_fan_rpm Fan speed.", "# TYPE decolab_fan_rpm gauge", "decolab_fan_rpm %d" % rpm,
             "# HELP decolab_fan_sensor_ok 1 = the temperature sensor reads plausible values.",
             "# TYPE decolab_fan_sensor_ok gauge"]
        z += ['decolab_fan_sensor_ok{sensor="%s"} %d' % (s, 0 if t is None else 1) for s, t in temps.items()]
        z += ["# HELP decolab_fan_failsafe_active 1 = a sensor failed, the fan runs at least at the failsafe floor.",
              "# TYPE decolab_fan_failsafe_active gauge", "decolab_fan_failsafe_active %d" % (1 if failsafe else 0),
              "# HELP decolab_fan_night_mode_active 1 = the night cap limits the fan.",
              "# TYPE decolab_fan_night_mode_active gauge", "decolab_fan_night_mode_active %d" % (1 if mode == "night" else 0),
              "# HELP decolab_fan_pwm_write_errors_total Failed PWM writes since the start.",
              "# TYPE decolab_fan_pwm_write_errors_total counter", "decolab_fan_pwm_write_errors_total %d" % _pwm_write_errors]
        if watts is not None:
            z += ["# HELP decolab_soc_power_watts Sum of the PMIC rails (SoC and RAM), without NVMe, fan, USB and supply losses.",
                  "# TYPE decolab_soc_power_watts gauge", "decolab_soc_power_watts %s" % watts]
        if energy is not None:
            z += ["# HELP decolab_soc_energy_kwh_total Energy of the PMIC rails, same limits as decolab_soc_power_watts.",
                  "# TYPE decolab_soc_energy_kwh_total counter", "decolab_soc_energy_kwh_total %s" % energy]
        tmp = METRICS_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(z) + "\n")
        os.chmod(tmp, 0o644)  # UMask=0077 of the hardening: node_exporter could not read it
        os.replace(tmp, METRICS_FILE)
        once("metrics", None)
    except OSError as e:
        once("metrics", e)


def _on_signal(signum, frame):
    global _stop
    _stop = True


def expected_sensors():
    forced = os.environ.get("FAN_SENSORS")
    if forced:
        return [s for s in forced.split() if s in ("cpu", "nvme")] or ["cpu"]
    return ["cpu"] + (["nvme"] if path("nvme") else [])


def main():
    dry = "--dry-run" in sys.argv
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    sensors = expected_sensors()
    log.info("fan control started%s, sensors: %s", " (dry run)" if dry else "", " ".join(sensors))

    current, bad_run, good_run, failsafe, hot_run, fan_reported = -1, 0, 0, False, 0, False
    last_logged = None
    window: collections.deque[float] = collections.deque(maxlen=max(1, round(SMOOTH_S / INTERVAL)))
    while not _stop:
        curve = load_curve()
        temps = {s: read_temp(s) for s in sensors}
        healthy = [t for t in temps.values() if t is not None]
        if len(healthy) < len(sensors):
            bad_run, good_run = bad_run + 1, 0
        else:
            bad_run, good_run = 0, good_run + 1
        if bad_run >= FAIL_DEBOUNCE:
            failsafe = True
        if failsafe and good_run >= FAIL_DEBOUNCE:
            failsafe = False
            log.info("sensors healthy again: failsafe left")
        temp = max(healthy) if healthy else None
        if temp is not None:
            window.append(temp)
        smooth = sum(window) / len(window) if window else None
        mode = "auto"

        # No reading at all, debounce not through yet: HOLD the PWM. (A first
        # draft computed temp_to_pwm(None) here, crashed, and Restart=always
        # made that the restart loop of rule 5.)
        if temp is None and not failsafe:
            log.warning("no sensor value (cycle %d/%d): holding the PWM", bad_run, FAIL_DEBOUNCE)
            if current < 0:
                current = FAILSAFE_FLOOR if dry else (set_pwm(FAILSAFE_FLOOR) or -1)
            write_metrics(temps, current, read_rpm(), "no-reading", failsafe)
            time.sleep(INTERVAL)
            continue

        if failsafe and not healthy:
            target, mode = FAILSAFE_BOTH, "failsafe-all"
            alarm("sensor", "🚨 No temperature sensor readable",
                  f"Neither {' nor '.join(sensors)} can be read. Fan at {FAILSAFE_BOTH} (full speed).")
        elif failsafe:
            target, mode = max(temp_to_pwm(temp, curve), FAILSAFE_FLOOR), "failsafe-one"
            dead = ", ".join(s for s, t in temps.items() if t is None)
            alarm("sensor", f"⚠️ Temperature sensor {dead} failed",
                  f"{dead} cannot be read. Fan at least {FAILSAFE_FLOOR}, now {target}. Remaining sensor: {temp:.1f} °C")
        else:
            assert temp is not None  # noqa: S101 (for mypy: the no-reading case continued above)
            ov = read_override() or {}
            om = ov.get("mode", "auto")
            if om == "quiet":
                target, mode = 60, "quiet"
            elif om == "max":
                target, mode = 255, "max"
            elif om == "fixed":
                try:
                    target = max(0, min(255, int(ov.get("pwm", 100))))
                except (TypeError, ValueError):
                    target = 100
                mode = "fixed"
            else:
                target = curve_target(smooth, curve, current)
            if mode == "auto" and is_night() and target > NIGHT_PWM_MAX:
                target, mode = NIGHT_PWM_MAX, "night"
            # The escape comes LAST: it lifts night and override (rule 3).
            if temp >= ESCAPE_TEMP and temp_to_pwm(temp, curve) > target:
                target, mode = temp_to_pwm(temp, curve), mode + "+escape"

        new = target if current < 0 else ramp(current, target)
        if abs(new - current) >= PWM_DEADBAND or current < 0:
            if dry:
                log.info("[dry run] would set PWM %d", new)
                current = new
            else:
                written = set_pwm(new)
                if written is not None:  # only what the hardware really got
                    current = written
        rpm = read_rpm()

        if temp is not None and temp >= ALERT_TEMP and current > 60 and rpm < ALERT_RPM_MIN:
            if not fan_reported:
                log.error("FAN FAILURE: %.1f °C, PWM %d, %d RPM", temp, current, rpm)
                alarm("fan", "🚨 Fan failure", f"The fan does not turn.\n{temp:.1f} °C | PWM {current} | {rpm} RPM")
                fan_reported = True
        else:
            fan_reported = False
        if temp is not None and temp >= HOT_TEMP:
            hot_run += 1
            if hot_run == HOT_CYCLES:
                alarm("hot", "🔥 Too hot",
                      f"{temp:.1f} °C for {HOT_CYCLES * INTERVAL:.0f} s | PWM {current} | {rpm} RPM\nThe fan turns, but it is not enough.")
        else:
            hot_run = 0

        write_metrics(temps, current, rpm, mode, failsafe)
        # Logged when something changes, not every 5 s (17,280 lines a day).
        if (current, mode) != last_logged:
            last_logged = (current, mode)
            log.info("%s | mean %s -> target %d | PWM %d, %d RPM [%s]",
                     " | ".join(f"{s} {t:.1f}°C" if t is not None else f"{s} DEAD" for s, t in temps.items()),
                     f"{smooth:.1f}°C" if smooth is not None else "-", target, current, rpm, mode)
        time.sleep(INTERVAL)

    log.info("stopped (signal): fan to the safe value %d", STOP_PWM)
    if not dry:
        set_pwm(STOP_PWM)


if __name__ == "__main__":
    main()
