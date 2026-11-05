#!/usr/bin/env python3
"""speedtest.py - measure the internet speed with librespeed-cli.

Started by scripts/speedtest.sh (which reads decolab.conf and the SPEEDTEST
switch), never directly. Paths come from the environment:
  DECOLAB_TEXTFILE_DIR  speedtest.prom for Prometheus
  DECOLAB_STATE_DIR     speedtest-history.json, the last 120 runs (~4 weeks)
  DECOLAB_RUN_DIR       speedtest.lock against two runs at once
  SPEEDTEST_SERVERS     the server list (config/speedtest-servers.json)
  LIBRESPEED_BIN        librespeed-cli

Why librespeed-cli: open source, a Debian package, and servers you choose
yourself instead of a commercial test network. The servers are tried in
order; if one fails, the next measures: one broken server on the other end
is no slow line.

Lessons of the original system:
- A slow server looks like a slow line. One server never went past 330
  Mbit/s on a line that does 913 with others, with any number of
  connections. Fast servers first, and 8 parallel connections instead of the
  default 3 (with 3 even a fast server did not get there).
- A "measurement" of 0 Mbit/s is the server's fault, not a result:
  otherwise a broken server raises the slow-line alarm.
- After a failed run the last GOOD values stay (with their timestamp) and
  decolab_speedtest_last_run_ok drops to 0: a gap in the curve would hide
  that the line was fine before.
- One run moves about 1 GB on a fast line: only 10 s per direction, and a
  lock so that cron and a manual run (--manual, at most every 10 min) never
  measure at the same time.
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time

LIBRESPEED = os.environ.get("LIBRESPEED_BIN", "librespeed-cli")
SERVERS = os.environ["SPEEDTEST_SERVERS"]
TEXTFILE = os.path.join(os.environ.get("DECOLAB_TEXTFILE_DIR", "/var/lib/node_exporter"), "speedtest.prom")
HISTORY = os.path.join(os.environ.get("DECOLAB_STATE_DIR", "/var/lib/decolab"), "speedtest-history.json")
LOCK = os.path.join(os.environ.get("DECOLAB_RUN_DIR", "/run/decolab"), "speedtest.lock")
DURATION = os.environ.get("SPEEDTEST_DURATION_S", "10")
TIMEOUT = int(os.environ.get("SPEEDTEST_TIMEOUT_S", "120"))
CONCURRENT = 8
MANUAL_GAP_S = 600
KEEP = 120


def write_atomic(path, text):
    """Neighbour file, then rename: Prometheus never reads half a file."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".speedtest-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_history():
    try:
        with open(HISTORY) as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except (OSError, ValueError):
        return []


def server_ids():
    with open(SERVERS) as f:
        return [int(s["id"]) for s in json.load(f)]


def measure(sid):
    """One run against one server: (result, None) or (None, reason)."""
    try:
        r = subprocess.run(
            [LIBRESPEED, "--local-json", SERVERS, "--server", str(sid), "--json",
             "--duration", str(DURATION), "--no-icmp", "--concurrent", str(CONCURRENT)],
            capture_output=True, text=True, timeout=TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        return None, f"server {sid}: no result within {TIMEOUT} s"
    except OSError as e:
        return None, f"cannot start librespeed-cli: {e}"
    if r.returncode != 0:
        return None, f"server {sid}: exit {r.returncode} {r.stderr.strip()[:120]}"
    try:
        d = json.loads(r.stdout)
        d = d[0] if isinstance(d, list) else d
        res: dict = {
            "down": round(float(d["download"]), 1),
            "up": round(float(d["upload"]), 1),
            "ping": round(float(d["ping"]), 1),
            "jitter": round(float(d.get("jitter") or 0), 1),
            "server": str(d.get("server", {}).get("name", sid))[:80],
            "mb": round((int(d.get("bytes_received") or 0) + int(d.get("bytes_sent") or 0)) / 1e6),
        }
    except (ValueError, KeyError, TypeError, IndexError, AttributeError):
        return None, f"server {sid}: unreadable output"
    if res["down"] <= 0 or res["up"] <= 0:
        return None, f"server {sid}: reported 0 Mbit/s"
    return res, None


def prom_text(last_ok, run_t, run_ok):
    z = []
    if last_ok:
        for name, key, help_ in [
            ("decolab_speedtest_download_mbit", "down", "Download of the last successful measurement (Mbit/s)."),
            ("decolab_speedtest_upload_mbit", "up", "Upload of the last successful measurement (Mbit/s)."),
            ("decolab_speedtest_ping_ms", "ping", "Ping over HTTP (ms)."),
            ("decolab_speedtest_jitter_ms", "jitter", "Variation of the ping (ms)."),
        ]:
            z += [f"# HELP {name} {help_}", f"# TYPE {name} gauge", f"{name} {last_ok[key]}"]
        z += ["# HELP decolab_speedtest_last_success_timestamp_seconds Time of the last successful measurement.",
              "# TYPE decolab_speedtest_last_success_timestamp_seconds gauge",
              f"decolab_speedtest_last_success_timestamp_seconds {last_ok['t']}"]
    z += ["# HELP decolab_speedtest_last_run_timestamp_seconds Time of the last run, successful or not.",
          "# TYPE decolab_speedtest_last_run_timestamp_seconds gauge",
          f"decolab_speedtest_last_run_timestamp_seconds {run_t}",
          "# HELP decolab_speedtest_last_run_ok 1 = the last run measured, 0 = every server failed.",
          "# TYPE decolab_speedtest_last_run_ok gauge",
          f"decolab_speedtest_last_run_ok {1 if run_ok else 0}"]
    return "\n".join(z) + "\n"


def main():
    source = "manual" if "--manual" in sys.argv[1:] else "cron"
    lock = open(LOCK, "a")  # noqa: SIM115 (held, and so locked, until the process ends)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"{time.strftime('%F %T')} a measurement is already running: nothing to do")
        return 0

    history = read_history()
    now = int(time.time())
    if source == "manual" and history and now - int(history[-1].get("t", 0)) < MANUAL_GAP_S:
        print(f"{time.strftime('%F %T')} the last measurement is less than 10 minutes old: no new run")
        return 0

    res, reasons = None, []
    try:
        ids = server_ids()
    except (OSError, ValueError, KeyError, TypeError) as e:
        ids, reasons = [], [f"server list unreadable: {e}"]
    if not ids and not reasons:
        reasons = ["the server list is empty"]
    for sid in ids:
        res, why = measure(sid)
        if res:
            break
        reasons.append(why)

    entry = {"t": now, "ok": bool(res), "source": source}
    if res:
        entry.update(res)
    else:
        entry["error"] = "; ".join(reasons)[:300]
    history = (history + [entry])[-KEEP:]
    last_ok = next((e for e in reversed(history) if e.get("ok")), None)
    write_atomic(HISTORY, json.dumps(history, ensure_ascii=False))
    write_atomic(TEXTFILE, prom_text(last_ok, now, bool(res)))

    if res:
        print(f"{time.strftime('%F %T')} OK: {source}: down {res['down']} up {res['up']} Mbit/s, "
              f"ping {res['ping']} ms ({res['server']}, {res['mb']} MB)")
        return 0
    print(f"{time.strftime('%F %T')} FAILED: {source}: no measurement - {entry['error']}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
