#!/usr/bin/env bash
# tools/demo-panel.sh - the panel on a made-up host, for screenshots
#
#   tools/demo-panel.sh [PORT]     (default 8099), stop with Ctrl-C
#
# Runs panel/server.py against an invented Raspberry Pi 5: every module on,
# fan and NVMe sensor present, all containers running, nightly backups and a
# speedtest history. Nothing is read from this machine. CPU, network and
# temperatures move a little, so the charts fill within a minute.
# Open http://127.0.0.1:PORT/ and log in with the token it prints.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
port=${1:-8099}
prom=$((port + 1))
token=decolab-demo-token-0000000000000000
d=$(mktemp -d "${TMPDIR:-/tmp}/decolab-demo.XXXXXX")
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$d"; }
trap cleanup EXIT INT TERM

mkdir -p "$d/secrets" "$d/proc/net" "$d/proc/device-tree" "$d/state" "$d/prom" "$d/backups" \
  "$d/sys/class/hwmon/hwmon0" "$d/sys/class/hwmon/hwmon1" "$d/sys/class/hwmon/hwmon2"
lan="192.0"
lan="$lan.2.10" # documentation range (RFC 5737), built from halves for tools/guard.sh
cat >"$d/decolab.conf" <<CONF
DECOLAB_USER=pi
DECOLAB_DIR=$root
DATA_DIR=/mnt/data
SECRETS_DIR=$d/secrets
TZ=UTC
LAN_INTERFACE=end0
LAN_SUBNET=192.0.2.0/24
HOST_LAN_IP=$lan
SSH_PORT=22
SSH_PASSWORDS=no
DOCKER_ADDRESS_POOL=10.210.0.0/16
WEB_UI_ADDRESS=127.0.0.1
PANEL_PORT=$port
TAILSCALE=yes
TAILNET_NAME=example
MODULE_IMMICH=yes
MODULE_VAULTWARDEN=yes
MODULE_UPTIME_KUMA=yes
HW_FAN=yes
HW_OLED=no
HW_NVME=yes
HW_UPS=no
SPEEDTEST=yes
HARDENING=yes
BACKUP_DIR=$d/backups
BACKUP_KEEP_DAYS=7
NOTIFY=none
CONF
printf '%s\n' "$token" >"$d/secrets/panel-token"
chmod 600 "$d/secrets/panel-token"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$d/proc/device-tree/model"
echo cpu_thermal >"$d/sys/class/hwmon/hwmon0/name"
echo nvme >"$d/sys/class/hwmon/hwmon1/name"
echo pwmfan >"$d/sys/class/hwmon/hwmon2/name"
cat >"$d/proc/meminfo" <<MEM
MemTotal:        8245000 kB
MemFree:         1210000 kB
MemAvailable:    4930000 kB
SwapTotal:       2097148 kB
SwapFree:        2010000 kB
MEM
echo "0.62 0.48 0.41 2/612 4242" >"$d/proc/loadavg"

# Containers: every container_name of the compose files, running for 3 days.
python3 -I - "$root" "$d/prom" <<'PY'
import json, os, re, sys, time
root, out = sys.argv[1], sys.argv[2]
files = [os.path.join(root, "compose", "core.yml")] + [
    os.path.join(root, "stacks", s, "compose.yml") for s in ("immich", "vaultwarden", "uptime-kuma")]
since, result = int(time.time()) - 3 * 86400 - 4 * 3600, []
for f in files:
    text = open(f, encoding="utf-8").read()
    for block in re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", text):
        name = re.search(r"^\s+container_name:\s*([A-Za-z0-9_.-]+)\s*$", block, re.M)
        image = re.search(r"^\s+image:\s*(\S+)", block, re.M)
        if name:
            result.append({"metric": {"name": name.group(1), "image": image.group(1) if image else ""},
                           "value": [since, str(since)]})
with open(os.path.join(out, "query.json"), "w") as f:
    json.dump({"status": "success", "data": {"resultType": "vector", "result": result}}, f)
with open(os.path.join(out, "alerts.json"), "w") as f:
    json.dump({"status": "success", "data": {"alerts": []}}, f)

# Speedtest every 6 hours for 15 days.
now, hist = int(time.time()), []
for i in range(60, 0, -1):
    k = (i * 37) % 11
    hist.append({"t": now - i * 21600, "ok": True, "source": "cron", "down": round(238 + k * 2.7, 1),
                 "up": round(38 + k * 0.4, 1), "ping": round(11 + (k % 4) * 0.8, 1),
                 "jitter": round(0.8 + (k % 3) * 0.3, 1), "server": "Example ISP"})
with open(os.path.join(os.path.dirname(out), "state", "speedtest-history.json"), "w") as f:
    json.dump(hist, f)
PY

# Nightly backups at 03:00 for the last 7 days.
for i in 0 1 2 3 4 5 6; do
  day=$(python3 -I -c 'import sys,time; print(time.strftime("%Y-%m-%d", time.localtime(time.time() - 3*3600 - int(sys.argv[1])*86400)))' "$i")
  mkdir -p "$d/backups/${day}_03-00"
done

# A small "kernel": CPU, network, temperatures and the fan move a little.
python3 -I - "$d" <<'PY' &
import math, os, random, sys, time
d, t0 = sys.argv[1], time.time()
cpu, rx, tx, n = [0] * 4, 8_400_000_000, 1_150_000_000, 0
def put(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)
while True:
    n += 1
    load = 0.12 + 0.08 * math.sin(n / 9) + random.random() * 0.06
    busy, idle = int(100 * load), int(100 * (1 - load))
    cpu = [cpu[0] + busy, cpu[1] + busy // 3, cpu[2] + idle, cpu[3] + 1]
    line = "cpu  %d 0 %d %d %d 0 0 0 0 0\n" % (cpu[0], cpu[1], cpu[2], cpu[3])
    put(os.path.join(d, "proc", "stat"), line + "".join(
        "cpu%d %d 0 %d %d %d 0 0 0 0 0\n" % (i, cpu[0] // 4, cpu[1] // 4, cpu[2] // 4, cpu[3] // 4) for i in range(4)))
    rx += int(900_000 + 600_000 * random.random())
    tx += int(150_000 + 120_000 * random.random())
    put(os.path.join(d, "proc", "net", "dev"),
        "Inter-|   Receive                                                |  Transmit\n"
        " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
        "    lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0\n"
        "  end0: %d 100 0 0 0 0 0 0 %d 50 0 0 0 0 0 0\n" % (rx, tx))
    put(os.path.join(d, "proc", "uptime"), "%.2f 0.00\n" % (3 * 86400 + 4 * 3600 + time.time() - t0))
    ctemp = 47.5 + 3 * math.sin(n / 11) + random.random()
    put(os.path.join(d, "sys", "class", "hwmon", "hwmon0", "temp1_input"), "%d\n" % (ctemp * 1000))
    put(os.path.join(d, "sys", "class", "hwmon", "hwmon1", "temp1_input"), "%d\n" % ((ctemp - 9) * 1000))
    put(os.path.join(d, "sys", "class", "hwmon", "hwmon2", "fan1_input"), "%d\n" % (2350 + 40 * math.sin(n / 11)))
    put(os.path.join(d, "sys", "class", "hwmon", "hwmon2", "pwm1"), "96\n")
    time.sleep(1)
PY
pids+=($!)
sleep 1.5

python3 -I "$root/tests/fakes/prometheus-stub.py" "$prom" "$d/prom" &
pids+=($!)
PANEL_PROC=$d/proc PANEL_SYS=$d/sys PANEL_PROMETHEUS=http://127.0.0.1:$prom \
  DECOLAB_STATE_DIR=$d/state PANEL_HOSTNAME=decolab PANEL_SAMPLE_S=1 \
  python3 -I - "$root/panel/server.py" "$d/decolab.conf" <<'PY' &
# Kernel and disks would come from this machine: replace them with a Pi's.
import os, runpy, sys
real_uname, real_statvfs = os.uname, os.statvfs
class Uname:
    sysname, nodename, release, version, machine = "Linux", "decolab", "6.12.47+rpt-rpi-2712", "#1 SMP", "aarch64"
class Vfs:
    def __init__(self, total_gb, used_gb):
        self.f_frsize = self.f_bsize = 4096
        self.f_blocks = int(total_gb * 2**30 / 4096)
        self.f_bfree = self.f_bavail = self.f_blocks - int(used_gb * 2**30 / 4096)
os.uname = lambda: Uname
os.statvfs = lambda path: Vfs(64, 21) if path == "/" else Vfs(1863, 742)
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PY
pids+=($!)
echo "demo panel: http://127.0.0.1:$port/  (token: $token, Ctrl-C stops it)"
wait
