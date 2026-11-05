# shellcheck shell=bash
# tests/fakes/panel-host.sh - a made-up host for the panel
#
#   panel_host DIR PORT   build it below DIR (the panel listens on PORT)
#
# Writes DIR/decolab.conf (a "foreign" installation: no Immich, no fan, no
# NVMe sensor), DIR/secrets/panel-token, a fake /proc and /sys, a backup
# directory and a Prometheus answer for prometheus-stub.py in DIR/prom.
# Addresses are documentation ranges, built from halves (tools/guard.sh).
panel_host() {
  local d=$1 port=$2 lan="192.0" doc
  lan="$lan.2.40"
  mkdir -p "$d/secrets" "$d/proc/net" "$d/proc/device-tree" "$d/sys/class/hwmon/hwmon3" \
    "$d/backups" "$d/state" "$d/prom" "$d/data"
  cat >"$d/decolab.conf" <<CONF
DECOLAB_USER=someone
DECOLAB_DIR=$d/repo
DATA_DIR=$d/data
SECRETS_DIR=$d/secrets
TZ=UTC
LAN_INTERFACE=end0
LAN_SUBNET=192.0.2.0/24
HOST_LAN_IP=$lan
SSH_PORT=22
DOCKER_ADDRESS_POOL=10.210.0.0/16
WEB_UI_ADDRESS=127.0.0.1
PANEL_PORT=$port
TAILSCALE=yes
TAILNET_NAME=tailtest
MODULE_IMMICH=no
MODULE_VAULTWARDEN=yes
MODULE_UPTIME_KUMA=yes
HW_FAN=no
HW_OLED=no
HW_NVME=no
HW_UPS=no
SPEEDTEST=yes
HARDENING=no
BACKUP_DIR=$d/backups
BACKUP_KEEP_DAYS=7
NOTIFY=none
CONF
  printf '%s\n' "testtoken-0123456789abcdefghijklmnopqrstuvwxyz" >"$d/secrets/panel-token"
  chmod 600 "$d/secrets/panel-token"
  cat >"$d/proc/stat" <<STAT
cpu  1000 0 500 8000 100 0 0 0 0 0
cpu0 250 0 125 2000 25 0 0 0 0 0
cpu1 250 0 125 2000 25 0 0 0 0 0
cpu2 250 0 125 2000 25 0 0 0 0 0
cpu3 250 0 125 2000 25 0 0 0 0 0
STAT
  cat >"$d/proc/meminfo" <<MEM
MemTotal:        8000000 kB
MemFree:         1000000 kB
MemAvailable:    6000000 kB
SwapTotal:       2000000 kB
SwapFree:        1500000 kB
MEM
  echo "93784.12 300000.00" >"$d/proc/uptime"
  echo "0.42 0.37 0.30 1/400 1234" >"$d/proc/loadavg"
  printf 'Some Board Rev 1.0\0' >"$d/proc/device-tree/model"
  cat >"$d/proc/net/dev" <<NET
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0
  end0: 5000000000 100 0 0 0 0 0 0 700000000 50 0 0 0 0 0 0
NET
  echo cpu_thermal >"$d/sys/class/hwmon/hwmon3/name"
  echo 51234 >"$d/sys/class/hwmon/hwmon3/temp1_input"
  mkdir -p "$d/backups/2026-01-02_03-00" "$d/backups/2026-01-01_03-00" "$d/backups/2025-12-31_03-00-incomplete"
  doc='[{"t": 1767225600, "ok": true, "source": "cron", "down": 250.4, "up": 40.1, "ping": 12.3, "jitter": 1.2, "server": "Example", "secret": "x"},'
  doc="$doc"'{"t": 1767247200, "ok": false, "source": "cron", "error": "no server"}]'
  printf '%s\n' "$doc" >"$d/state/speedtest-history.json"
  cat >"$d/prom/query.json" <<'Q'
{"status":"success","data":{"resultType":"vector","result":[
 {"metric":{"name":"pihole","image":"pihole/pihole:2026.10.1"},"value":[1767300000,"1767200000"]},
 {"metric":{"name":"unbound","image":"madnuttah/unbound:1.26.2-0"},"value":[1767300000,"1767200000"]},
 {"metric":{"name":"prometheus","image":"prom/prometheus"},"value":[1767300000,"1767200000"]},
 {"metric":{"name":"vaultwarden","image":"vaultwarden/server"},"value":[1767300000,"1767200000"]},
 {"metric":{"name":"<img src=x onerror=alert(1)>","image":"evil"},"value":[1767300000,"1767200000"]},
 {"metric":{"name":"my-own-thing","image":"example/thing"},"value":[1767300000,"1767200000"]}
]}}
Q
  cat >"$d/prom/alerts.json" <<'A'
{"status":"success","data":{"alerts":[
 {"labels":{"alertname":"DiskAlmostFull","severity":"warning"},"annotations":{"summary":"<b>disk</b> 91 %"},"state":"firing","activeAt":"2026-01-02T03:04:05Z"},
 {"labels":{"alertname":"Flapping"},"annotations":{},"state":"pending","activeAt":"2026-01-02T03:04:05Z"}
]}}
A
}
