#!/usr/bin/env python3
"""sqlite_snapshot.py SRC DST - consistent copy of a live SQLite database.

Uses SQLite's online backup API while the service keeps running (Pi-hole,
Vaultwarden, Uptime Kuma). A file copy (cp, tar) of a live database can
read the database file and its -wal at different moments; the backup API
copies one consistent state.

Rules (each one is a way this goes wrong otherwise):
- SRC is opened normally, read-write, never with immutable=1 or nolock:
  WAL locking needs the -shm file. mode=rw also refuses to CREATE a missing
  database (a plain connect() would back up a new empty file).
- The copy is made in ONE step (pages=-1, the default). A step-by-step copy
  restarts after every write of another process and may never finish on a
  database that is written all the time (Uptime Kuma).
- Python's backup() waits for a locked database by itself, without end.
  A deadline (SQLITE_SNAPSHOT_TIMEOUT_S, default 300) ends the wait: a
  database that stays locked fails the backup loudly instead of hanging it.
- The copy must pass PRAGMA integrity_check, or it is deleted.

Run by the user who owns the database: the -wal/-shm files SQLite may
create must not end up owned by someone else (the service would be locked
out). Exit 0 on success; otherwise the reason on stderr and exit 1.
"""
import os
import sqlite3
import sys
import time
import urllib.parse

PAUSE_S = float(os.environ.get("SQLITE_SNAPSHOT_PAUSE_S", "0.25"))
TIMEOUT_S = float(os.environ.get("SQLITE_SNAPSHOT_TIMEOUT_S", "300"))


class StillLocked(Exception):
    pass


def fail(message):
    print("sqlite_snapshot: " + message, file=sys.stderr)
    sys.exit(1)


def snapshot(src, dst):
    deadline = time.monotonic() + TIMEOUT_S

    def progress(status, remaining, total):
        # Called after every step, also after each wait for a lock.
        if time.monotonic() > deadline:
            raise StillLocked()

    uri = "file:" + urllib.parse.quote(os.path.abspath(src)) + "?mode=rw"
    source = sqlite3.connect(uri, uri=True, timeout=min(TIMEOUT_S, 30))
    try:
        target = sqlite3.connect(dst)
        try:
            source.backup(target, progress=progress, sleep=PAUSE_S)
        finally:
            target.close()
    finally:
        source.close()


def remove_copy(dst):
    for leftover in (dst, dst + "-wal", dst + "-shm", dst + "-journal"):
        if os.path.exists(leftover):
            os.remove(leftover)


def main():
    if len(sys.argv) != 3:
        fail("usage: sqlite_snapshot.py SRC DST")
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isfile(src):
        fail("%s does not exist" % src)
    if os.path.exists(dst):
        fail("%s exists already" % dst)
    try:
        snapshot(src, dst)
    except StillLocked:
        remove_copy(dst)
        fail("%s: still locked after %g s" % (src, TIMEOUT_S))
    except sqlite3.Error as error:
        remove_copy(dst)
        fail("%s: %s" % (src, error))
    check = sqlite3.connect(dst)
    try:
        result = check.execute("PRAGMA integrity_check").fetchall()
    finally:
        check.close()
    if result != [("ok",)]:
        remove_copy(dst)
        found = " ".join(" ".join(r[0] for r in result[:5]).split())
        fail("%s: integrity_check of the copy: %s" % (src, found[:240]))


if __name__ == "__main__":
    main()
