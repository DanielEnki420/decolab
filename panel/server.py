#!/usr/bin/env python3
"""Decolab panel: a read-only dashboard for this host.

    python3 -I panel/server.py DECOLAB_CONF

The panel shows, it does not act: every API route is a GET, nothing restarts,
reboots, updates or writes. Actions would need an authentication design made
for them first.

Only the Python standard library: install.sh installs no packages.

Security model
  - Listens on WEB_UI_ADDRESS:PANEL_PORT only (127.0.0.1 by default: reached
    through tailscale serve or an SSH tunnel).
  - Every API route except /api/v1/health needs the token in
    SECRETS_DIR/panel-token: as "Authorization: Bearer TOKEN", or as the
    cookie that POST /login sets. Even read-only data (container names,
    versions, addresses) helps an attacker in the LAN.
  - The Host header must be one of this host's names (DNS rebinding: a page on
    a foreign site cannot make the browser talk to the panel under its own
    name). POST /login also checks Origin.
  - Static files come from a fixed list, never from a path in the request.
  - Strict Content-Security-Policy; the page builds every value with
    textContent (container and alert names are data from outside).
  - Docker is never asked directly: container state comes from Prometheus
    (cAdvisor), so this process needs no Docker access at all. The systemd
    unit forbids UNIX sockets, which also keeps it away from docker.sock.

The JSON shapes are the contract for the tests (tests/test-panel.sh) and for
the dashboard. Convention: what this host does not have is reported as
{"available": false} (or null for a single value), never as an error.

Hooks for the tests (all optional):
  PANEL_PROC        instead of /proc
  PANEL_SYS         instead of /sys
  PANEL_PROMETHEUS  instead of http://127.0.0.1:9090
  PANEL_HOSTNAME    instead of the real host name
  PANEL_SAMPLE_S    sampling interval in seconds (default 5)
  DECOLAB_STATE_DIR instead of /var/lib/decolab
"""

import hmac
import http.server
import json
import os
import re
import socket
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "0.1.0"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
STATIC = os.path.join(HERE, "static")

PROC = os.environ.get("PANEL_PROC", "/proc")
SYS = os.environ.get("PANEL_SYS", "/sys")
PROMETHEUS = os.environ.get("PANEL_PROMETHEUS", "http://127.0.0.1:9090").rstrip("/")
STATE_DIR = os.environ.get("DECOLAB_STATE_DIR", "/var/lib/decolab")
SAMPLE_S = float(os.environ.get("PANEL_SAMPLE_S", "5"))
HISTORY_LEN = 60
COOKIE = "decolab_panel"
MAX_BODY = 512

# The web interfaces the panel links to. "reach": web_ui = published on
# WEB_UI_ADDRESS (plain HTTP on that address), tailscale = published on
# 127.0.0.1 only, reachable as HTTPS through tailscale serve.
# tests/test-panel.sh checks every entry against the compose files.
SERVICES = [
    # id, title, module, stack, port, path, icon, reach
    ("pihole", "Pi-hole", None, "core", 8053, "/admin/", "shield", "web_ui"),
    ("portainer", "Portainer", None, "core", 9000, "/", "box", "web_ui"),
    ("perses", "Perses", None, "core", 8800, "/", "chart", "tailscale"),
    ("immich", "Immich", "MODULE_IMMICH", "immich", 2283, "/", "image", "web_ui"),
    ("vaultwarden", "Vaultwarden", "MODULE_VAULTWARDEN", "vaultwarden", 8500, "/", "lock", "tailscale"),
    ("uptime-kuma", "Uptime Kuma", "MODULE_UPTIME_KUMA", "uptime-kuma", 3001, "/", "pulse", "web_ui"),
]

# Fixed list of static files: URL path -> (file below panel/static, type).
STATIC_FILES = {
    "/static/panel.css": ("panel.css", "text/css; charset=utf-8"),
    "/static/panel.js": ("panel.js", "text/javascript; charset=utf-8"),
    "/static/login.js": ("login.js", "text/javascript; charset=utf-8"),
    "/static/fonts/cinzel-600.woff2": ("fonts/cinzel-600.woff2", "font/woff2"),
    "/static/icons/ui.svg": ("icons/ui.svg", "image/svg+xml"),
    "/static/icons/eqv-logo.webp": ("icons/eqv-logo.webp", "image/webp"),
    "/static/icons/eqv-ring.svg": ("icons/eqv-ring.svg", "image/svg+xml"),
    "/static/favicon-32.png": ("favicon-32.png", "image/png"),
    "/static/favicon-64.png": ("favicon-64.png", "image/png"),
    "/static/icon-180.png": ("icon-180.png", "image/png"),
    "/static/icon-192.png": ("icon-192.png", "image/png"),
    "/static/icon-512.png": ("icon-512.png", "image/png"),
    "/static/manifest.json": ("manifest.json", "application/manifest+json"),
}

CSP_PAGE = ("default-src 'none'; script-src 'self'; style-src 'self'; "
            "style-src-attr 'unsafe-inline'; img-src 'self'; font-src 'self'; "
            "connect-src 'self'; manifest-src 'self'; form-action 'self'; "
            "base-uri 'none'; frame-ancestors 'none'")
# SVG files are documents of their own; the sprite has one <style> element.
CSP_SVG = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'"


# --- configuration ------------------------------------------------------------

def load_conf(path):
    """KEY=VALUE lines; install.sh has validated the file (decolab-config)."""
    conf = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            conf[k.strip()] = v.strip()
    return conf


def yes(conf, key):
    return conf.get(key, "no") == "yes"


def read_token(conf):
    path = os.path.join(conf.get("SECRETS_DIR", "/nonexistent"), "panel-token")
    with open(path, encoding="utf-8") as f:
        token = f.read().strip()
    if len(token) < 32:
        raise ValueError(f"{path}: token shorter than 32 characters")
    return token


def allowed_hosts(conf):
    name = os.environ.get("PANEL_HOSTNAME") or socket.gethostname()
    short = name.split(".")[0]
    hosts = {"localhost", "127.0.0.1", "[::1]", short, name, f"{short}.local"}
    for key in ("WEB_UI_ADDRESS", "HOST_LAN_IP"):
        if conf.get(key):
            hosts.add(conf[key])
    if yes(conf, "TAILSCALE") and conf.get("TAILNET_NAME"):
        hosts.add(f"{short}.{conf['TAILNET_NAME']}.ts.net")
    return {h.lower() for h in hosts}


def host_only(value):
    """Host header or Origin netloc without the port; '' if malformed."""
    value = (value or "").strip().lower()
    if value.startswith("["):
        end = value.find("]")
        return value[:end + 1] if end > 0 else ""
    return value.split(":", 1)[0]


# --- readers for /proc and /sys -----------------------------------------------

def read(path, default=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default


def cpu_times():
    """[(busy, total)] for all CPUs, then one per core."""
    out = []
    for line in (read(os.path.join(PROC, "stat"), "") or "").splitlines():
        if not line.startswith("cpu"):
            continue
        parts = line.split()
        try:
            vals = [int(x) for x in parts[1:9]]
        except ValueError:
            continue
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
        out.append((sum(vals) - idle, sum(vals)))
    return out


def meminfo():
    info = {}
    for line in (read(os.path.join(PROC, "meminfo"), "") or "").splitlines():
        m = re.match(r"(\w+):\s+(\d+)", line)
        if m:
            info[m.group(1)] = int(m.group(2)) * 1024
    return info


def hwmon(name, *files):
    """Values of FILES of the hwmon device called NAME, None if it is absent.
    By name, never by number: the numbers change between boots."""
    base = os.path.join(SYS, "class", "hwmon")
    try:
        entries = sorted(os.listdir(base))
    except OSError:
        return None
    for entry in entries:
        d = os.path.join(base, entry)
        if (read(os.path.join(d, "name"), "") or "").strip() != name:
            continue
        vals = []
        for f in files:
            raw = (read(os.path.join(d, f), "") or "").strip()
            try:
                vals.append(int(raw))
            except ValueError:
                vals.append(None)
        return vals
    return None


def net_bytes(iface):
    for line in (read(os.path.join(PROC, "net", "dev"), "") or "").splitlines():
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        if name.strip() == iface:
            f = rest.split()
            try:
                return int(f[0]), int(f[8])
            except (IndexError, ValueError):
                return None
    return None


def disk(path):
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    used = total - st.f_bfree * st.f_frsize
    return {"path": path, "total": total, "used": used, "free": free,
            "pct": round(used / total * 100, 1) if total else 0.0}


# --- sampler: the live values and the short history ---------------------------

class Sampler:
    def __init__(self, conf):
        self.conf = conf
        self.lock = threading.Lock()
        self.prev_cpu = cpu_times()
        self.prev_net = None
        self.prev_t = time.monotonic()
        self.cpu = None
        self.cores = []
        self.net_rate = None
        self.history = {k: [] for k in ("t", "cpu", "ram", "cpu_temp", "nvme_temp", "rx", "tx")}

    def temps(self):
        cpu = hwmon("cpu_thermal", "temp1_input")
        nvme = hwmon("nvme", "temp1_input")
        def c(v):
            return round(v[0] / 1000, 1) if v and v[0] is not None else None
        return c(cpu), c(nvme)

    def sample(self):
        now = time.monotonic()
        cur = cpu_times()
        pct = []
        for (b0, t0), (b1, t1) in zip(self.prev_cpu, cur):
            dt = t1 - t0
            pct.append(round((b1 - b0) / dt * 100, 1) if dt > 0 else 0.0)
        net = net_bytes(self.conf.get("LAN_INTERFACE", "eth0"))
        rate = None
        if net and self.prev_net and now > self.prev_t:
            span = now - self.prev_t
            rate = {"rx": max(0, int((net[0] - self.prev_net[0]) / span)),
                    "tx": max(0, int((net[1] - self.prev_net[1]) / span))}
        mem = meminfo()
        ram = None
        if mem.get("MemTotal"):
            ram = round((mem["MemTotal"] - mem.get("MemAvailable", 0)) / mem["MemTotal"] * 100, 1)
        ctemp, ntemp = self.temps()
        with self.lock:
            self.prev_cpu, self.prev_net, self.prev_t = cur, net, now
            if pct:
                self.cpu, self.cores = pct[0], pct[1:]
            self.net_rate = rate
            point = {"t": int(time.time()), "cpu": self.cpu, "ram": ram,
                     "cpu_temp": ctemp, "nvme_temp": ntemp,
                     "rx": rate["rx"] if rate else None, "tx": rate["tx"] if rate else None}
            for k, v in point.items():
                self.history[k].append(v)
                del self.history[k][:-HISTORY_LEN]

    def run(self):
        while True:
            time.sleep(SAMPLE_S)
            try:
                self.sample()
            except Exception as e:  # a bad read must not stop the history
                print(f"sampler: {e}", file=sys.stderr, flush=True)

    def snapshot(self):
        with self.lock:
            return (self.cpu, list(self.cores), self.net_rate,
                    {k: list(v) for k, v in self.history.items()})


# --- API ----------------------------------------------------------------------

def api_system(conf, sampler):
    cpu, cores, rate, _ = sampler.snapshot()
    mem = meminfo()
    total = mem.get("MemTotal")
    used = total - mem.get("MemAvailable", 0) if total else None
    swap_total = mem.get("SwapTotal")
    up = (read(os.path.join(PROC, "uptime"), "") or "").split()
    load = (read(os.path.join(PROC, "loadavg"), "") or "").split()
    model = (read(os.path.join(PROC, "device-tree", "model"), "") or "").strip("\x00\n ")
    ctemp, ntemp = sampler.temps()
    fan = hwmon("pwmfan", "fan1_input", "pwm1")
    net = net_bytes(conf.get("LAN_INTERFACE", "eth0"))
    disks = [d for d in (disk("/"), disk(conf.get("DATA_DIR", "/nonexistent"))) if d]
    if len(disks) == 2 and disks[0]["total"] == disks[1]["total"] and disks[0]["used"] == disks[1]["used"]:
        disks = disks[:1]  # the data directory is on the system disk
    return {
        "hostname": os.environ.get("PANEL_HOSTNAME") or socket.gethostname(),
        "model": model or None,
        "kernel": os.uname().release,
        "uptime_s": int(float(up[0])) if up else None,
        "load": [float(x) for x in load[:3]] if len(load) >= 3 else None,
        "cpu": {"pct": cpu, "cores": cores, "count": len(cores) or None},
        "memory": {"total": total, "used": used,
                   "pct": round(used / total * 100, 1) if total else None},
        "swap": {"total": swap_total, "used": swap_total - mem.get("SwapFree", 0)}
                if swap_total else {"available": False},
        "disks": disks,
        "temps": {"cpu": ctemp, "nvme": ntemp},
        "fan": {"available": True, "rpm": fan[0], "pwm": fan[1]} if fan else {"available": False},
        "network": {"interface": conf.get("LAN_INTERFACE", "eth0"),
                    "address": conf.get("HOST_LAN_IP") or None,
                    "rx_total": net[0] if net else None, "tx_total": net[1] if net else None,
                    "rx_rate": rate["rx"] if rate else None, "tx_rate": rate["tx"] if rate else None},
    }


def stacks(conf):
    out = ["core"]
    for module, stack in (("MODULE_IMMICH", "immich"), ("MODULE_VAULTWARDEN", "vaultwarden"),
                          ("MODULE_UPTIME_KUMA", "uptime-kuma")):
        if yes(conf, module):
            out.append(stack)
    return out


def expected_containers(conf):
    """container_name entries of the compose files of this installation."""
    names = []
    for stack in stacks(conf):
        f = os.path.join(REPO, "compose", "core.yml") if stack == "core" else \
            os.path.join(REPO, "stacks", stack, "compose.yml")
        for m in re.finditer(r"^\s+container_name:\s*([A-Za-z0-9_.-]+)\s*$", read(f, "") or "", re.M):
            names.append(m.group(1))
    return names


def prometheus(path, params):
    url = f"{PROMETHEUS}{path}?{urllib.parse.urlencode(params)}" if params else PROMETHEUS + path
    with urllib.request.urlopen(url, timeout=3) as r:  # noqa: S310 (fixed local URL)
        body = json.loads(r.read(1_000_000))
    if body.get("status") != "success":
        raise ValueError("prometheus answered " + str(body.get("status")))
    return body["data"]


def api_containers(conf):
    expected = expected_containers(conf)
    try:
        data = prometheus("/api/v1/query", {"query": 'container_start_time_seconds{name!=""}'})
    except (OSError, ValueError, KeyError, urllib.error.URLError) as e:
        return {"available": False, "reason": f"Prometheus not reachable ({type(e).__name__})",
                "containers": [{"name": n, "image": None, "running": None, "since": None,
                                "expected": True} for n in expected]}
    seen = {}
    for s in data.get("result", []):
        m = s.get("metric", {})
        name = m.get("name")
        if not name or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", name):
            continue
        try:
            since = int(float(s["value"][1]))
        except (KeyError, IndexError, ValueError, TypeError):
            since = None
        seen[name] = {"image": str(m.get("image", ""))[:200] or None, "since": since}
    out = []
    for name in expected:
        s = seen.get(name)
        out.append({"name": name, "image": s["image"] if s else None, "running": bool(s),
                    "since": s["since"] if s else None, "expected": True})
    for name in sorted(set(seen) - set(expected)):
        out.append({"name": name, "image": seen[name]["image"], "running": True,
                    "since": seen[name]["since"], "expected": False})
    return {"available": True, "containers": out}


def api_alerts():
    try:
        data = prometheus("/api/v1/alerts", None)
    except (OSError, ValueError, KeyError, urllib.error.URLError) as e:
        return {"available": False, "reason": f"Prometheus not reachable ({type(e).__name__})"}
    firing, pending = [], 0
    for a in data.get("alerts", []):
        if a.get("state") == "pending":
            pending += 1
            continue
        if a.get("state") != "firing":
            continue
        labels, notes = a.get("labels", {}), a.get("annotations", {})
        firing.append({"name": str(labels.get("alertname", "?"))[:120],
                       "severity": str(labels.get("severity", ""))[:40] or None,
                       "summary": str(notes.get("summary", ""))[:300] or None,
                       "since": str(a.get("activeAt", ""))[:40] or None})
    return {"available": True, "firing": firing, "pending": pending}


def api_services(conf):
    out = []
    for sid, title, module, _stack, port, path, icon, reach in SERVICES:
        if module and not yes(conf, module):
            continue
        out.append({"id": sid, "title": title, "port": port, "path": path, "icon": icon,
                    "reach": reach,
                    "available": reach != "tailscale" or yes(conf, "TAILSCALE")})
    return {"services": out}


def api_backup(conf):
    d = conf.get("BACKUP_DIR")
    try:
        names = os.listdir(d) if d else None
    except OSError:
        names = None
    if names is None:
        return {"available": False}
    pat = re.compile(r"(20\d\d-\d\d-\d\d_\d\d-\d\d)(-incomplete)?")
    done, incomplete, running = [], [], False
    for n in names:
        if n.startswith(".partial-"):
            running = True
            continue
        m = pat.fullmatch(n)
        if m:
            (incomplete if m.group(2) else done).append(m.group(1))
    latest = max(done) if done else None
    age_h = None
    if latest:
        age_h = int((time.time() - time.mktime(time.strptime(latest, "%Y-%m-%d_%H-%M"))) // 3600)
    newest_bad = max(incomplete) if incomplete else None
    return {"available": True, "latest": latest, "age_h": age_h, "running": running,
            "count": len(done),
            "last_incomplete": newest_bad if newest_bad and (not latest or newest_bad > latest) else None}


def api_speedtest(conf):
    if not yes(conf, "SPEEDTEST"):
        return {"available": False}
    raw = read(os.path.join(STATE_DIR, "speedtest-history.json"))
    try:
        hist = json.loads(raw) if raw else []
    except ValueError:
        hist = []
    keep = ("t", "ok", "source", "down", "up", "ping", "jitter", "server")
    runs = [{k: e[k] for k in keep if k in e} for e in hist if isinstance(e, dict)][-60:]
    return {"available": True, "runs": runs}


# --- HTTP ---------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "decolab-panel"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 15

    def log_request(self, code="-", size="-"):  # path without the query string
        # escaped: a client's ESC or newline must not reach the journal raw
        path = self.path.split('?')[0].encode("unicode_escape", "backslashreplace").decode("ascii")
        print(f"{self.address_string()} {self.command} {path} {code}",
              file=sys.stderr, flush=True)

    def log_message(self, fmt, *args):
        # Only the format, never the arguments: for a malformed request they
        # hold the raw request line, which can be a login form with the token.
        print(f"{self.address_string()} {fmt.split('%')[0].strip() or 'error'}", file=sys.stderr, flush=True)

    def send(self, code, body, ctype="application/json; charset=utf-8", csp=CSP_PAGE, extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", csp)
        self.send_header("X-Content-Type-Options", "nosniff")
        # same-origin, not no-referrer: with no-referrer the browser sends
        # "Origin: null" on the login form, and the Origin check refuses it.
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store" if not ctype.startswith(("image/", "font/")) else "max-age=3600")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def host_ok(self):
        return host_only(self.headers.get("Host")) in self.server.hosts

    def authed(self):
        token = self.server.token.encode()
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer ") and hmac.compare_digest(auth[7:].strip().encode(), token):
            return True
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE and hmac.compare_digest(v.encode(), token):
                return True
        return False

    def static(self, name, ctype):
        try:
            with open(os.path.join(STATIC, name), "rb") as f:
                body = f.read()
        except OSError:
            return self.send(404, {"error": "not found"})
        self.send(200, body, ctype, CSP_SVG if ctype.startswith("image/svg") else CSP_PAGE)

    def do_GET(self):
        if not self.host_ok():
            return self.send(421, {"error": "unknown host name"})
        path = urllib.parse.urlsplit(self.path).path
        if path in STATIC_FILES:
            return self.static(*STATIC_FILES[path])
        if path == "/api/v1/health":
            return self.send(200, {"ok": True, "version": VERSION})
        if path in ("/", "/index.html"):
            return self.static("index.html" if self.authed() else "login.html", "text/html; charset=utf-8")
        if not path.startswith("/api/"):
            return self.send(404, {"error": "not found"})
        if not self.authed():
            return self.send(401, {"error": "token required"}, extra={"WWW-Authenticate": "Bearer"})
        conf, sampler = self.server.conf, self.server.sampler
        routes = {
            "/api/v1/system": lambda: api_system(conf, sampler),
            "/api/v1/history": lambda: sampler.snapshot()[3],
            "/api/v1/containers": lambda: api_containers(conf),
            "/api/v1/alerts": api_alerts,
            "/api/v1/services": lambda: api_services(conf),
            "/api/v1/backup": lambda: api_backup(conf),
            "/api/v1/speedtest": lambda: api_speedtest(conf),
        }
        if path not in routes:
            return self.send(404, {"error": "not found"})
        try:
            return self.send(200, routes[path]())
        except Exception as e:  # report, never leak a trace to the page
            print(f"{path}: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            return self.send(500, {"error": "internal error"})

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        # A refused POST leaves its body unread; on a kept-alive connection it
        # would be parsed as the next request. So every POST ends the connection.
        self.close_connection = True
        if not self.host_ok():
            return self.send(421, {"error": "unknown host name"})
        if urllib.parse.urlsplit(self.path).path != "/login":
            return self.send(405, {"error": "read-only"}, extra={"Allow": "GET, HEAD"})
        origin = self.headers.get("Origin")
        if origin and host_only(urllib.parse.urlsplit(origin).netloc) not in self.server.hosts:
            return self.send(403, {"error": "foreign origin"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            return self.send(413, {"error": "too large"})
        form = urllib.parse.parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        given = (form.get("token") or [""])[0].strip()
        if not hmac.compare_digest(given.encode(), self.server.token.encode()):
            time.sleep(1)  # slows guessing; the token has 48 random characters anyway
            return self.send(303, b"", "text/plain", extra={"Location": "/?wrong=1"})
        cookie = f"{COOKIE}={self.server.token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000"
        return self.send(303, b"", "text/plain", extra={"Location": "/", "Set-Cookie": cookie})

    def refuse(self):
        self.send(405, {"error": "read-only"}, extra={"Allow": "GET, HEAD"})

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS = refuse


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, addr, conf, token, sampler):
        if ":" in addr[0]:
            self.address_family = socket.AF_INET6
        super().__init__(addr, Handler)
        self.conf, self.token, self.sampler = conf, token, sampler
        self.hosts = allowed_hosts(conf)

    def server_bind(self):
        # HTTPServer.server_bind asks DNS for the fully qualified name
        # (socket.getfqdn): 20 s at start without a resolver. Not needed.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def main(argv):
    if len(argv) != 2:
        print("usage: server.py DECOLAB_CONF", file=sys.stderr)
        return 2
    try:
        conf = load_conf(argv[1])
        token = read_token(conf)
    except (OSError, ValueError) as e:
        print(f"decolab-panel: {e}", file=sys.stderr)
        return 1
    address = conf.get("WEB_UI_ADDRESS", "127.0.0.1")
    try:
        port = int(conf.get("PANEL_PORT", "8090"))
    except ValueError:
        print("decolab-panel: PANEL_PORT is not a number", file=sys.stderr)
        return 1
    sampler = Sampler(conf)
    sampler.sample()
    threading.Thread(target=sampler.run, daemon=True).start()
    try:
        srv = Server((address, port), conf, token, sampler)
    except OSError as e:
        print(f"decolab-panel: cannot listen on {address}:{port}: {e}", file=sys.stderr)
        return 1
    print(f"decolab-panel {VERSION} on http://{address}:{port}/ (read-only)", file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
