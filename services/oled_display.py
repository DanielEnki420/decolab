#!/usr/bin/env python3
"""oled_display.py - status pages on a 128x64 SSD1306 OLED over I2C (HW_OLED).

Runs as the systemd service decolab-oled. Pages, each OLED_PAGE_S (10) s:
  1. host name and LAN address, CPU and RAM load, fan speed
  2. disk use, CPU and NVMe temperature, uptime
  3. Decolab: power (UPS), age of the newest backup, failed services
A message (OLED_MESSAGE, default /run/decolab/oled-message.json:
{"text": "...", "expires": <unix time, 0 = never>}) replaces the pages
while it is valid.

Lessons of the original display:
- Sensors were read from FIXED hwmon numbers (hwmon0, hwmon1, hwmon3): after
  a kernel update the "NVMe" line showed another device. Here: by NAME.
- A failed reading showed 0.0 °C, which looks like a value. Here: "--".
- The panel rewrote this file's source (a regex on PAGE_SECS) to change a
  setting; a crash in between left half a Python file. Settings come from
  the environment, never from editing code.
- ProcSubset=pid in the unit's hardening hides /proc/stat: the service
  passed its first check and crashed in the first CPU reading. The unit must
  not set it (config/systemd/decolab-oled.service.template).
- No psutil: /proc and os.statvfs are enough, one dependency less.

Without hardware: --print renders every page as text to stdout once (tests,
and a look at what the display would show). OLED_PROC (default /proc) and
OLED_HWMON (default /sys/class/hwmon) can point to fakes.
"""

import glob
import json
import os
import signal
import socket
import sys
import textwrap
import time

WIDTH, HEIGHT = 128, 64
I2C_PORT = int(os.environ.get("OLED_I2C_PORT", "1"))
I2C_ADDRESS = int(os.environ.get("OLED_I2C_ADDRESS", "0x3C"), 16)
PAGE_S = max(1, min(60, int(os.environ.get("OLED_PAGE_S", "10"))))
MESSAGE = os.environ.get("OLED_MESSAGE", "/run/decolab/oled-message.json")
PROC = os.environ.get("OLED_PROC", "/proc")
HWMON = os.environ.get("OLED_HWMON", "/sys/class/hwmon")
IFACE = os.environ.get("LAN_INTERFACE", "")
TEXTFILE = os.environ.get("DECOLAB_TEXTFILE_DIR", "/var/lib/node_exporter")
STATE = os.environ.get("DECOLAB_STATE_DIR", "/var/lib/decolab")
BACKUP_DIR = os.environ.get("BACKUP_DIR", "")
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
_stop = False


# --- readings (None = not readable, shown as "--") ---------------------------

def hwmon_read(name, file):
    for nm in sorted(glob.glob(os.path.join(HWMON, "hwmon*", "name"))):
        try:
            with open(nm) as f:
                if f.read().strip() != name:
                    continue
            with open(os.path.join(os.path.dirname(nm), file)) as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            continue
    return None


def temp(name):
    v = hwmon_read(name, "temp1_input")
    return v / 1000 if v is not None and 5000 <= v <= 125000 else None


def fan_rpm():
    return hwmon_read("pwmfan", "fan1_input")


_cpu_last = None


def cpu_percent():
    """Busy share since the last call (the first call: since boot)."""
    global _cpu_last
    try:
        with open(os.path.join(PROC, "stat")) as f:
            v = [int(x) for x in f.readline().split()[1:]]
    except (OSError, ValueError):
        return None
    idle, total = v[3] + (v[4] if len(v) > 4 else 0), sum(v)
    last, _cpu_last = _cpu_last, (idle, total)
    if last is None:
        return 100.0 * (1 - idle / total) if total else None
    d_total = total - last[1]
    return 100.0 * (1 - (idle - last[0]) / d_total) if d_total > 0 else None


def ram_percent():
    try:
        m = {}
        with open(os.path.join(PROC, "meminfo")) as f:
            for line in f:
                k, _, rest = line.partition(":")
                m[k] = int(rest.split()[0])
        return 100.0 * (1 - m["MemAvailable"] / m["MemTotal"])
    except (OSError, ValueError, KeyError, ZeroDivisionError, IndexError):
        return None


def disk_percent(path="/"):
    try:
        s = os.statvfs(path)
        return 100.0 * (1 - s.f_bavail / s.f_blocks) if s.f_blocks else None
    except OSError:
        return None


def uptime():
    try:
        with open(os.path.join(PROC, "uptime")) as f:
            sec = int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return "--"
    d, r = divmod(sec, 86400)
    return f"{d}d {r // 3600}h" if d else f"{r // 3600}h {r % 3600 // 60:02d}m"


def lan_address():
    """The address of LAN_INTERFACE; without it, the one the default route
    would use (a UDP connect sends no packet)."""
    if IFACE:
        try:
            import fcntl
            import struct
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            raw = fcntl.ioctl(s.fileno(), 0x8915, struct.pack("256s", IFACE[:15].encode()))  # SIOCGIFADDR
            return socket.inet_ntoa(raw[20:24])
        except OSError:
            return "--"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))  # TEST-NET: never contacted
        return s.getsockname()[0]
    except OSError:
        return "--"


def prom_value(file, metric):
    try:
        with open(os.path.join(TEXTFILE, file)) as f:
            for line in f:
                if line.startswith(metric + " "):
                    return float(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def backup_age_h():
    if not BACKUP_DIR:
        return None
    names = sorted(n for n in (os.listdir(BACKUP_DIR) if os.path.isdir(BACKUP_DIR) else [])
                   if len(n) == 16 and n[4] == "-" and n[10] == "_")
    if not names:
        return None
    try:
        t = time.mktime(time.strptime(names[-1], "%Y-%m-%d_%H-%M"))
    except ValueError:
        return None
    return int((time.time() - t) // 3600)


def failed_services():
    try:
        with open(os.path.join(STATE, "services")) as f:
            n = f.read().split("|")
        return int(n[0]) + int(n[1])
    except (OSError, ValueError, IndexError):
        return None


# --- pages: lists of (kind, text, percent) -----------------------------------

def fmt(v, unit, width=4):
    return f"{v:{width}.1f}{unit}" if v is not None else "  --" + unit


def page_system():
    cpu, ram, rpm = cpu_percent(), ram_percent(), fan_rpm()
    return [("title", socket.gethostname().split(".")[0][:18], None), ("text", lan_address(), None),
            ("bar", "CPU " + fmt(cpu, "%"), cpu), ("bar", "RAM " + fmt(ram, "%"), ram),
            ("small", f"Fan: {rpm} RPM" if rpm is not None else "Fan: --", None)]


def page_temperatures():
    disk, c, n = disk_percent(), temp("cpu_thermal"), temp("nvme")
    return [("title", "TEMPERATURES", None), ("bar", "Disk " + fmt(disk, "%"), disk),
            ("bar", "CPU  " + fmt(c, "C"), None if c is None else min(c, 85) / 85 * 100),
            ("bar", "NVMe " + fmt(n, "C"), None if n is None else min(n, 70) / 70 * 100),
            ("small", "Up: " + uptime(), None)]


def page_decolab():
    on_batt, charge = prom_value("ups.prom", "decolab_ups_on_battery"), prom_value("ups.prom", "decolab_ups_battery_percent")
    power = "Power: --" if on_batt is None else (f"BATTERY {charge:.0f}%" if charge is not None else "BATTERY") if on_batt else "Power: mains"
    age, failed = backup_age_h(), failed_services()
    backup = "Backup: --" if age is None else (f"Backup: {age} h" + (" OLD" if age > 26 else ""))
    svc = "Services: --" if failed is None else ("Services: ok" if failed == 0 else f"FAILED: {failed}")
    return [("title", "DECOLAB", None), ("text", power, None), ("text", backup, None), ("text", svc, None)]


PAGES = [page_system, page_temperatures, page_decolab]


def read_message():
    try:
        with open(MESSAGE) as f:
            d = json.load(f)
        exp = float(d.get("expires", 0))
        if exp and time.time() > exp:
            os.remove(MESSAGE)
            return None
        text = str(d.get("text", "")).strip()
        return text or None
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def as_text(lines):
    out = []
    for kind, text, pct in lines:
        out.append(text + (f" [{'#' * int(round(pct) / 10):<10}]" if kind == "bar" and pct is not None else ""))
    return "\n".join(out)


# --- drawing -----------------------------------------------------------------

def draw_page(draw, fonts, lines):
    big, small = fonts
    y = 0
    for kind, text, pct in lines:
        if kind == "title":
            draw.text((0, y), text, font=big, fill=255)
            draw.line([(0, 13), (127, 13)], fill=255)
            y = 16
            continue
        draw.text((0, y), text, font=small if kind == "small" else big, fill=255)
        if kind == "bar":
            draw.rectangle([82, y + 2, 127, y + 10], outline=255, fill=0)
            if pct is not None:
                inner = max(0, min(43, int(43 * pct / 100)))
                if inner:
                    draw.rectangle([83, y + 3, 83 + inner, y + 9], fill=255)
        y += 10 if kind == "small" else 13


def draw_message(draw, fonts, text):
    big, _ = fonts
    draw.rectangle([0, 0, WIDTH - 1, HEIGHT - 1], outline=255)
    lines = textwrap.wrap(text, width=18)[:4]
    y0 = (HEIGHT - len(lines) * 14) // 2
    for i, line in enumerate(lines):
        w = draw.textlength(line, font=big)
        draw.text((max(0, (WIDTH - w) // 2), y0 + i * 14), line, font=big, fill=255)


def _on_signal(signum, frame):
    global _stop
    _stop = True


def main():
    if "--print" in sys.argv:
        msg = read_message()
        if msg:
            print("MESSAGE: " + msg)
        for p in PAGES:
            print(as_text(p()))
            print("-" * 20)
        return 0
    from luma.core.interface.serial import i2c
    from luma.oled.device import ssd1306
    from PIL import Image, ImageDraw, ImageFont

    signal.signal(signal.SIGTERM, _on_signal)
    fonts = (ImageFont.truetype(FONT_BOLD, 11), ImageFont.truetype(FONT, 9))
    device = ssd1306(i2c(port=I2C_PORT, address=I2C_ADDRESS), width=WIDTH, height=HEIGHT)
    page = 0
    try:
        while not _stop:
            img = Image.new("1", (WIDTH, HEIGHT), 0)
            draw = ImageDraw.Draw(img)
            msg = read_message()
            if msg:
                draw_message(draw, fonts, msg)
            else:
                draw_page(draw, fonts, PAGES[page]())
                page = (page + 1) % len(PAGES)
            device.display(img)
            for _ in range(1 if msg else PAGE_S):
                if _stop:
                    break
                time.sleep(1)
    finally:
        device.hide()  # a stopped service leaves no frozen picture
        device.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
