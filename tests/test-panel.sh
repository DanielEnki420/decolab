#!/usr/bin/env bash
# Contract tests for the panel's HTTP API (panel/server.py).
#
# Everything goes through HTTP, as a browser would see it: status codes, headers, JSON shapes. The host is made up
# (tests/fakes/panel-host.sh), Prometheus is a stub.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fakes/panel-host.sh
. "$t_root/tests/fakes/panel-host.sh"

free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
# jget FILE EXPR - evaluate EXPR on the JSON in FILE (as "d"), print the result
jget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

host=$t_tmp/host
port=$(free_port) prom=$(free_port)
panel_host "$host" "$port"
token=$(cat "$host/secrets/panel-token")
base=http://127.0.0.1:$port

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null && wait "$p" 2>/dev/null; done; rm -rf "$t_tmp"; }
trap cleanup EXIT

python3 -I "$t_root/tests/fakes/prometheus-stub.py" "$prom" "$host/prom" &
pids+=($!)
# start_panel CONF LOG - start a panel in the background, wait for /health
start_panel() {
  PANEL_PROC=$host/proc PANEL_SYS=$host/sys PANEL_PROMETHEUS=http://127.0.0.1:$prom \
    DECOLAB_STATE_DIR=$host/state PANEL_HOSTNAME=probe PANEL_SAMPLE_S=0.2 \
    python3 -I "$t_root/panel/server.py" "$1" >"$2" 2>&1 &
  pids+=($!)
  local p
  p=$(sed -n 's/^PANEL_PORT=//p' "$1")
  for _ in $(seq 1 50); do
    curl -fsS -m 1 "http://127.0.0.1:$p/api/v1/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "panel on $p did not start: $(cat "$2")" >&2
  return 1
}
start_panel "$host/decolab.conf" "$t_tmp/panel.log" || exit 1

# req NAME [CURL ARGS...] - body to $t_tmp/NAME.json, headers to NAME.h; prints the status
req() {
  local name=$1
  shift
  curl -sS -m 5 -o "$t_tmp/$name.json" -D "$t_tmp/$name.h" -w '%{http_code}' "$@"
}
auth=(-H "Authorization: Bearer $token")

echo "access"
same "  health needs no token" "$(req health "$base/api/v1/health")" 200
check "  ... and says only that it is up" 0 '{"ok": true, "version":' -- cat "$t_tmp/health.json"
same "  API without a token: 401" "$(req a1 "$base/api/v1/system")" 401
same "  API with a wrong token: 401" "$(req a2 -H "Authorization: Bearer ${token}x" "$base/api/v1/system")" 401
same "  API with a token of the right length but wrong: 401" "$(req a3 -H "Authorization: Bearer x${token:1}" "$base/api/v1/system")" 401
same "  API with the token: 200" "$(req a4 "${auth[@]}" "$base/api/v1/system")" 200
same "  unknown host name: 421 (DNS rebinding)" "$(req a5 "${auth[@]}" -H "Host: evil.example" "$base/api/v1/system")" 421
same "  ... also for the page" "$(req a6 -H "Host: evil.example:$port" "$base/")" 421
same "  tailnet name of this host: allowed" "$(req a7 "${auth[@]}" -H "Host: probe.tailtest.ts.net:$port" "$base/api/v1/system")" 200
lan_ip=$(sed -n "s/^HOST_LAN_IP=//p" "$host/decolab.conf")
same "  LAN address from the config: allowed" "$(req a8 "${auth[@]}" -H "Host: $lan_ip:$port" "$base/api/v1/system")" 200
same "  page without login: 200" "$(req p1 "$base/")" 200
check "  ... is the login page" 0 "Panel token" -- cat "$t_tmp/p1.json"
refute "  ... not the dashboard" "panel.js"
same "  unknown API route: 404" "$(req a9 "${auth[@]}" "$base/api/v1/nothing")" 404

echo "read-only"
for m in POST PUT DELETE PATCH; do
  same "  $m on the API: 405" "$(req m "${auth[@]}" -X "$m" "$base/api/v1/system")" 405
done
check "  405 names the allowed methods" 0 "Allow: GET, HEAD" -- cat "$t_tmp/m.h"

echo "login"
same "  wrong token: redirect back" "$(req l1 --data-urlencode "token=nope" "$base/login")" 303
check "  ... to the hint" 0 "Location: /?wrong=1" -- cat "$t_tmp/l1.h"
refute "  ... and no cookie" "Set-Cookie"
same "  right token: redirect" "$(req l2 --data-urlencode "token=$token" "$base/login")" 303
check "  ... sets an HttpOnly, SameSite=Strict cookie" 0 "HttpOnly; SameSite=Strict" -- cat "$t_tmp/l2.h"
cookie=$(sed -n 's/^Set-Cookie: \([^;]*\);.*/\1/p' "$t_tmp/l2.h" | tr -d '\r')
same "  the cookie opens the API" "$(req l3 -H "Cookie: $cookie" "$base/api/v1/system")" 200
same "  ... and the dashboard" "$(req l4 -H "Cookie: $cookie" "$base/")" 200
check "  ... which loads panel.js" 0 'src="/static/panel.js"' -- cat "$t_tmp/l4.json"
same "  login from a foreign origin: 403" "$(req l5 -H "Origin: https://evil.example" --data-urlencode "token=$token" "$base/login")" 403
refute "  ... without a cookie" "Set-Cookie"
same "  login with Origin null: 403" "$(req l6 -H "Origin: null" --data-urlencode "token=$token" "$base/login")" 403
same "  login from this host's origin: accepted" "$(req l7 -H "Origin: $base" --data-urlencode "token=$token" "$base/login")" 303
same "  oversized login body: 413" "$(req l8 --data-urlencode "token=$(printf 'x%.0s' $(seq 1 600))" "$base/login")" 413

echo "headers and static files"
req h1 "$base/" >/dev/null
check "  CSP: scripts only from the panel" 0 "script-src 'self';" -- cat "$t_tmp/h1.h"
check "  CSP: no framing" 0 "frame-ancestors 'none'" -- cat "$t_tmp/h1.h"
check "  nosniff" 0 "X-Content-Type-Options: nosniff" -- cat "$t_tmp/h1.h"
check "  referrer only to the same origin" 0 "Referrer-Policy: same-origin" -- cat "$t_tmp/h1.h"
check "  no unsafe-inline for scripts" 1 "" -- grep -qE "script-src[^;]*unsafe" "$t_tmp/h1.h"
same "  stylesheet" "$(req s1 "$base/static/panel.css")" 200
same "  font" "$(req s2 "$base/static/fonts/cinzel-600.woff2")" 200
same "  path traversal: 404" "$(req s3 --path-as-is "$base/static/../server.py")" 404
same "  the server's own source: 404" "$(req s4 "$base/panel/server.py")" 404
same "  a file not on the list: 404" "$(req s5 "$base/static/fonts/OFL.txt")" 404
same "  static files need no token (login page)" "$(req s6 "$base/static/icons/eqv-logo.webp")" 200

echo "system"
req sys "${auth[@]}" "$base/api/v1/system" >/dev/null
same "  host name" "$(jget "$t_tmp/sys.json" 'd["hostname"]')" probe
same "  model from the device tree, without the NUL" "$(jget "$t_tmp/sys.json" 'd["model"]')" "Some Board Rev 1.0"
same "  four cores" "$(jget "$t_tmp/sys.json" 'd["cpu"]["count"]')" 4
same "  memory in bytes, used = total - available" "$(jget "$t_tmp/sys.json" '(d["memory"]["total"], d["memory"]["used"], d["memory"]["pct"])')" "(8192000000, 2048000000, 25.0)"
same "  swap" "$(jget "$t_tmp/sys.json" 'd["swap"]')" "{'total': 2048000000, 'used': 512000000}"
same "  CPU temperature by hwmon name" "$(jget "$t_tmp/sys.json" 'd["temps"]["cpu"]')" 51.2
same "  no NVMe sensor: null" "$(jget "$t_tmp/sys.json" 'd["temps"]["nvme"]')" None
same "  no fan: available false" "$(jget "$t_tmp/sys.json" 'd["fan"]')" "{'available': False}"
same "  network of LAN_INTERFACE" "$(jget "$t_tmp/sys.json" '(d["network"]["interface"], d["network"]["rx_total"], d["network"]["tx_total"])')" "('end0', 5000000000, 700000000)"
same "  uptime in seconds" "$(jget "$t_tmp/sys.json" 'd["uptime_s"]')" 93784
same "  at least the root disk" "$(jget "$t_tmp/sys.json" 'd["disks"][0]["path"]')" /

echo "history"
sleep 0.6
req hist "${auth[@]}" "$base/api/v1/history" >/dev/null
same "  the same keys as the contract" "$(jget "$t_tmp/hist.json" 'sorted(d)')" "['cpu', 'cpu_temp', 'nvme_temp', 'ram', 'rx', 't', 'tx']"
same "  all series equally long, more than one point" "$(jget "$t_tmp/hist.json" 'len({len(v) for v in d.values()}) == 1 and len(d["t"]) > 1')" True
cp "$host/proc/net/dev" "$t_tmp/dev"
sed -i.bak 's/5000000000/5000100000/' "$host/proc/net/dev"
sleep 0.5
req hist2 "${auth[@]}" "$base/api/v1/history" >/dev/null
same "  a counter that grew shows as a rate" "$(jget "$t_tmp/hist2.json" 'any((v or 0) > 0 for v in d["rx"])')" True

echo "containers"
req c "${auth[@]}" "$base/api/v1/containers" >/dev/null
same "  Prometheus answers: available" "$(jget "$t_tmp/c.json" 'd["available"]')" True
same "  a reported container runs" "$(jget "$t_tmp/c.json" '[c["running"] for c in d["containers"] if c["name"] == "pihole"]')" "[True]"
same "  an expected container that is not reported is stopped" "$(jget "$t_tmp/c.json" '[(c["running"], c["expected"]) for c in d["containers"] if c["name"] == "socket-proxy"]')" "[(False, True)]"
same "  modules that are off are not expected (MODULE_IMMICH=no)" "$(jget "$t_tmp/c.json" 'any(c["name"].startswith("immich") for c in d["containers"])')" False
same "  a container from elsewhere is listed as extra" "$(jget "$t_tmp/c.json" '[c["expected"] for c in d["containers"] if c["name"] == "my-own-thing"]')" "[False]"
same "  a name with markup is dropped" "$(jget "$t_tmp/c.json" 'any("<" in c["name"] for c in d["containers"])')" False
same "  every container of the enabled stacks is listed" "$(jget "$t_tmp/c.json" 'sorted(c["name"] for c in d["containers"] if c["expected"])' | tr -d "[]',")" \
  "$(cd "$t_root" && awk '$1 == "container_name:" { print $2 }' compose/core.yml stacks/vaultwarden/compose.yml stacks/uptime-kuma/compose.yml | sort | tr '\n' ' ' | sed 's/ $//')"
mv "$host/prom/query.json" "$host/prom/query.off"
req c2 "${auth[@]}" "$base/api/v1/containers" >/dev/null
same "  Prometheus down: available false" "$(jget "$t_tmp/c2.json" 'd["available"]')" False
same "  ... the expected containers are still listed, state unknown" "$(jget "$t_tmp/c2.json" '{c["running"] for c in d["containers"]}')" "{None}"
mv "$host/prom/query.off" "$host/prom/query.json"

echo "alerts"
req al "${auth[@]}" "$base/api/v1/alerts" >/dev/null
same "  firing alerts with name and summary" "$(jget "$t_tmp/al.json" '[(a["name"], a["summary"]) for a in d["firing"]]')" "[('DiskAlmostFull', '<b>disk</b> 91 %')]"
same "  pending ones only counted" "$(jget "$t_tmp/al.json" 'd["pending"]')" 1
mv "$host/prom/alerts.json" "$host/prom/alerts.off"
req al2 "${auth[@]}" "$base/api/v1/alerts" >/dev/null
same "  Prometheus down: available false" "$(jget "$t_tmp/al2.json" 'd["available"]')" False
mv "$host/prom/alerts.off" "$host/prom/alerts.json"
check "  the panel asks Prometheus nothing but these two" 1 "" -- grep -vE '^/api/v1/(query\?query=container_start_time_seconds|alerts$)' "$host/prom/requests.log"

echo "services"
req sv "${auth[@]}" "$base/api/v1/services" >/dev/null
same "  the enabled web interfaces, in order" "$(jget "$t_tmp/sv.json" '[s["id"] for s in d["services"]]')" "['pihole', 'portainer', 'perses', 'vaultwarden', 'uptime-kuma']"
same "  loopback-only services are reached through tailscale serve" "$(jget "$t_tmp/sv.json" '[s["id"] for s in d["services"] if s["reach"] == "tailscale"]')" "['perses', 'vaultwarden']"
echo "backup"
req b "${auth[@]}" "$base/api/v1/backup" >/dev/null
same "  newest complete backup by name" "$(jget "$t_tmp/b.json" '(d["latest"], d["count"], d["running"], d["last_incomplete"])')" "('2026-01-02_03-00', 2, False, None)"
mkdir "$host/backups/.partial-2026-01-03_03-00" "$host/backups/2026-01-03_03-00-incomplete"
req b2 "${auth[@]}" "$base/api/v1/backup" >/dev/null
same "  a run in progress and a newer incomplete one" "$(jget "$t_tmp/b2.json" '(d["running"], d["last_incomplete"])')" "(True, '2026-01-03_03-00')"

echo "speed test"
req st "${auth[@]}" "$base/api/v1/speedtest" >/dev/null
same "  the runs" "$(jget "$t_tmp/st.json" 'len(d["runs"])')" 2
same "  only the contract's fields" "$(jget "$t_tmp/st.json" 'any("secret" in r or "error" in r for r in d["runs"])')" False

echo "a second host: fan, NVMe, no speed test"
mkdir -p "$host/sys/class/hwmon/hwmon1" "$host/sys/class/hwmon/hwmon7"
echo pwmfan >"$host/sys/class/hwmon/hwmon1/name"
echo 3150 >"$host/sys/class/hwmon/hwmon1/fan1_input"
echo 102 >"$host/sys/class/hwmon/hwmon1/pwm1"
echo nvme >"$host/sys/class/hwmon/hwmon7/name"
echo 41800 >"$host/sys/class/hwmon/hwmon7/temp1_input"
port2=$(free_port)
sed "s/^PANEL_PORT=.*/PANEL_PORT=$port2/; s/^SPEEDTEST=.*/SPEEDTEST=no/; s/^MODULE_IMMICH=.*/MODULE_IMMICH=yes/" "$host/decolab.conf" >"$t_tmp/second.conf"
start_panel "$t_tmp/second.conf" "$t_tmp/panel2.log" || exit 1
base2=http://127.0.0.1:$port2
req f "${auth[@]}" "$base2/api/v1/system" >/dev/null
same "  fan by hwmon name" "$(jget "$t_tmp/f.json" 'd["fan"]')" "{'available': True, 'rpm': 3150, 'pwm': 102}"
same "  NVMe temperature" "$(jget "$t_tmp/f.json" 'd["temps"]["nvme"]')" 41.8
req f2 "${auth[@]}" "$base2/api/v1/speedtest" >/dev/null
same "  SPEEDTEST=no: available false" "$(jget "$t_tmp/f2.json" 'd')" "{'available': False}"
req f3 "${auth[@]}" "$base2/api/v1/services" >/dev/null
same "  MODULE_IMMICH=yes: Immich is linked" "$(jget "$t_tmp/f3.json" '"immich" in [s["id"] for s in d["services"]]')" True
# With every module on: each link must match how a compose file publishes
# its port - on WEB_UI_ADDRESS for web_ui, on loopback for tailscale.
links=0
while IFS='|' read -r sid sport reach; do
  links=$((links + 1))
  if [ "$reach" = web_ui ]; then pat="\"\${WEB_UI_ADDRESS}:$sport:"; else pat="\"127.0.0.1:$sport:"; fi
  check "  $sid: port $sport is published for $reach" 0 "" -- grep -qF "$pat" "$t_root/compose/core.yml" "$t_root"/stacks/*/compose.yml
done < <(jget "$t_tmp/f3.json" '"\n".join(s["id"] + "|" + str(s["port"]) + "|" + s["reach"] for s in d["services"])')
same "  ... all six links checked" "$links" 6
same "  six web interfaces with every module on" "$(jget "$t_tmp/f3.json" 'len(d["services"])')" 6

echo "start-up"
run_panel() { PANEL_PROC=$host/proc PANEL_SYS=$host/sys PANEL_HOSTNAME=probe python3 -I "$t_root/panel/server.py" "$@"; }
sed "s|^SECRETS_DIR=.*|SECRETS_DIR=$t_tmp/none|" "$host/decolab.conf" >"$t_tmp/notoken.conf"
check "  no token file: refuses to start" 1 "panel-token" -- run_panel "$t_tmp/notoken.conf"
mkdir -p "$t_tmp/short"
echo tooshort >"$t_tmp/short/panel-token"
sed "s|^SECRETS_DIR=.*|SECRETS_DIR=$t_tmp/short|" "$host/decolab.conf" >"$t_tmp/short.conf"
check "  a short token: refuses to start" 1 "shorter than 32" -- run_panel "$t_tmp/short.conf"
check "  port taken: says so" 1 "cannot listen" -- run_panel "$host/decolab.conf"
check "  no argument: usage" 2 "usage" -- run_panel
check "  the token never reaches the journal" 1 "" -- grep -F "$token" "$t_tmp/panel.log"
# The two guards behind that, each on its own:
# raw PORT DATA - send DATA on one connection, print everything that comes back
raw() { python3 -I -c 'import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.sendall(sys.argv[2].encode())
out = b""
try:
    while True:
        b = s.recv(4096)
        if not b: break
        out += b
except socket.timeout:
    out += b"<still open>"
print(out.decode("latin-1"))' "$@"; }
body="token=leftover-1234"
answer=$(raw "$port" "POST /login HTTP/1.1"$'\r\n'"Host: 127.0.0.1"$'\r\n'"Origin: https://evil.example"$'\r\n'"Content-Length: ${#body}"$'\r\n\r\n'"$body")
same "  a refused POST closes the connection (its body is never read as a request)" \
  "$(printf '%s' "$answer" | grep -c '^HTTP/1.1')|$(printf '%s' "$answer" | grep -c 'still open')" "1|0"
raw "$port" "marker-in-a-broken-request-5678"$'\r\n\r\n' >/dev/null
sleep 0.2
check "  a broken request is not copied into the journal" 1 "" -- grep -F "marker-in-a-broken-request-5678" "$t_tmp/panel.log"
raw "$port" "GET /x"$'\x1b'"[31mred-9876 HTTP/1.1"$'\r\n'"Host: 127.0.0.1"$'\r\n\r\n' >/dev/null
sleep 0.2
check "  a control character in the path is logged escaped" 0 "" -- grep -F '/x\x1b[31mred-9876' "$t_tmp/panel.log"
check "  ... never raw" 1 "" -- grep -q "$(printf '\033')" "$t_tmp/panel.log"

echo "the page and the unit"
check "  no innerHTML in the page script" 1 "" -- grep -n "\.innerHTML" "$t_root/panel/static/panel.js"
check "  no inline event handlers in the pages" 1 "" -- grep -nE '<[^>]+ on[a-z]+=' "$t_root/panel/static/index.html" "$t_root/panel/static/login.html"
check "  no inline scripts" 1 "" -- grep -nE '<script>|<script [^s]' "$t_root/panel/static/index.html" "$t_root/panel/static/login.html"
check "  nothing loaded from elsewhere" 1 "" -- grep -nE '(src|href)="(https?:)?//' "$t_root/panel/static/index.html" "$t_root/panel/static/login.html"
unit=$t_root/config/systemd/decolab-panel.service.template
check "  unit: no UNIX sockets (no way to docker.sock)" 0 "" -- grep -qx "RestrictAddressFamilies=AF_INET AF_INET6" "$unit"
check "  unit: read-only, no writable paths" 1 "" -- grep -q "ReadWritePaths" "$unit"
# shellcheck disable=SC2016 # the template's own placeholder
check "  unit: traffic only to localhost and the LAN" 0 "" -- grep -qx 'IPAddressAllow=localhost ${LAN_SUBNET}' "$unit"
# Every file the pages ask for is served (the panel has a fixed list).
for f in "$t_root"/panel/static/index.html "$t_root"/panel/static/login.html "$t_root"/panel/static/panel.css "$t_root"/panel/static/manifest.json; do
  while read -r ref; do
    same "  $(basename "$f") -> $ref" "$(req ref "$base$ref")" 200
  done < <(grep -oE '/static/[A-Za-z0-9_./-]+' "$f" | sort -u)
done

t_finish
