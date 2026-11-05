# shellcheck shell=bash
# shellcheck disable=SC2154 # decolab_root, BACKUP_DIR, ...: lib/common.sh
# lib/probe.sh - shared parts of the restore probes (scripts/restore-probe-*.sh)
#
# A restore probe restores the newest backup into a throw-away container
# and proves through the APPLICATION that the data is there: a mark set in
# the copy, or a value taken from the copy, must come back through the
# service. "The archive can be unpacked" proves little; the original system
# once kept valid, empty Vaultwarden backups for nine days.
#
# Four borders to production, each checked at run time, not trusted:
#   name     the container is decolab-probe-<service>; it may never be one
#            of the container names in the compose files
#   port     a loopback port nobody listens on (or no network at all)
#   files    only a fresh mktemp directory; the cleanup removes nothing
#            that does not match that pattern
#   removal  only the container this run started, and only while it
#            carries the label decolab.probe
#
# Usage, after lib/common.sh and decolab_init:
#   . "$decolab_root/lib/probe.sh"
#   probe_init vaultwarden PROBE_VAULTWARDEN 8599   # service, Kuma monitor, port ("-": none)
#   probe_archive vaultwarden.tar.gz                # -> PROBE_BACKUP, PROBE_ARCHIVE
#   probe_extract                                   # -> PROBE_COPY (in PROBE_DIR)
#   probe_image vaultwarden                         # -> PROBE_IMAGE, PROBE_USER of production
#   probe_run ARGS...                               # docker run -d with the borders
#   probe_ok                                        # count a passed check
#   probe_fail "reason"                             # down + message, cleanup, exit 1
#   probe_pass N "summary"                          # all N checks ran? up
#   probe_count_guard KEY COUNT                     # fail if COUNT < half of the last run

probe_init() { # SERVICE MONITOR PORT
  PROBE_SERVICE=$1 PROBE_MONITOR=$2 PROBE_PORT=$3
  PROBE_NAME=decolab-probe-$1
  PROBE_DIR="" PROBE_COPY="" PROBE_BACKUP="" PROBE_STARTED=0 PROBE_CHECKS=0 PROBE_START=$(date +%s)
  PROBE_TMP_PATTERN="${TMPDIR:-/tmp}"
  PROBE_TMP_PATTERN=${PROBE_TMP_PATTERN%/}/decolab-probe-$1.
  trap probe_cleanup EXIT
  trap 'exit 1' INT TERM HUP
  local n
  for n in $(probe_protected); do
    [ "$PROBE_NAME" != "$n" ] || probe_fail "probe name $PROBE_NAME is a production container"
  done
  if [ "$PROBE_PORT" != - ] && ! python3 -I -c 'import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)' "$PROBE_PORT"; then
    probe_fail "port $PROBE_PORT is taken: stopping instead of colliding"
  fi
  # One heavy job at a time, and never two probes on the same port.
  job_lock "${PROBE_LOCK_WAIT_S:-900}" || probe_fail "another heavy job held the lock for too long"
}

# probe_protected - every container name of Decolab's compose files
probe_protected() {
  cat "$decolab_root"/compose/*.yml "$decolab_root"/stacks/*/compose.yml 2>/dev/null |
    sed -n 's/^[[:space:]]*container_name:[[:space:]]*\([A-Za-z0-9_.-]*\).*/\1/p'
}

probe_cleanup() {
  local rc=$?
  if [ "$PROBE_STARTED" = 1 ]; then
    if [ "$(docker inspect -f '{{index .Config.Labels "decolab.probe"}}' "$PROBE_NAME" 2>/dev/null)" = "$PROBE_SERVICE" ]; then
      timeout 60 docker rm -f -v "$PROBE_NAME" >/dev/null 2>&1
    else
      log "WARNING: $PROBE_NAME has no decolab.probe label: NOT removed"
    fi
  fi
  # The copy holds secrets: deleting it is a duty, not cosmetics.
  if [ -n "$PROBE_DIR" ]; then
    case $PROBE_DIR in
      "$PROBE_TMP_PATTERN"??????*) rm -rf "$PROBE_DIR" ;;
      *) log "WARNING: $PROBE_DIR does not match the mktemp pattern: NOT deleted" ;;
    esac
  fi
  return "$rc"
}

probe_ok() { PROBE_CHECKS=$((PROBE_CHECKS + 1)); }

probe_fail() {
  local msg="$1 (after $(($(date +%s) - PROBE_START)) s)"
  log "FAILED: $msg"
  notify "🔴 Restore probe $PROBE_SERVICE" "$msg"
  kuma_push "$PROBE_MONITOR" down "$msg"
  exit 1
}

probe_pass() { # EXPECTED SUMMARY
  [ "$PROBE_CHECKS" = "$1" ] || probe_fail "only $PROBE_CHECKS of $1 checks ran"
  local msg="$2, $PROBE_CHECKS checks, $(($(date +%s) - PROBE_START)) s"
  kuma_push "$PROBE_MONITOR" up "$msg" || exit 1
  log "PASSED: $msg"
  exit 0
}

# probe_archive FILE - FILE of the newest complete backup, at most 26 h old.
# PROBE_ARCHIVE may be set beforehand (the off-site probe brings its own).
probe_archive() {
  if [ -z "${PROBE_ARCHIVE:-}" ]; then
    PROBE_BACKUP=$(backup_latest)
    [ -n "$PROBE_BACKUP" ] || probe_fail "no complete backup in $BACKUP_DIR"
    local age
    age=$(backup_age_h "$PROBE_BACKUP")
    [ "${age:-999}" -le 26 ] || probe_fail "the newest backup is ${age} h old: the nightly backup is not running"
    PROBE_ARCHIVE=$PROBE_BACKUP/$1
  fi
  [ -s "$PROBE_ARCHIVE" ] || probe_fail "$PROBE_ARCHIVE is missing or empty"
  log "probe of $PROBE_ARCHIVE"
}

# probe_tmp - the run's private directory PROBE_DIR (created once)
probe_tmp() {
  [ -z "$PROBE_DIR" ] || return 0
  PROBE_DIR=$(mktemp -d "${PROBE_TMP_PATTERN}XXXXXXXX") || probe_fail "mktemp failed"
  chmod 700 "$PROBE_DIR"
}

# probe_extract - unpacks PROBE_ARCHIVE into PROBE_COPY=PROBE_DIR/copy.
# Refuses archives with links, devices, absolute paths or "..": unpacking
# them could write outside the directory.
probe_extract() {
  python3 -I - "$PROBE_ARCHIVE" <<'PY' || probe_fail "the archive cannot be read or holds links or paths outside itself"
import sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as t:
    for m in t:
        if not (m.isfile() or m.isdir()) or m.name.startswith("/") or ".." in m.name.split("/"):
            print("not allowed in a backup: " + m.name, file=sys.stderr)
            sys.exit(1)
PY
  probe_tmp
  PROBE_COPY=$PROBE_DIR/copy
  mkdir "$PROBE_COPY" || probe_fail "cannot create $PROBE_COPY"
  tar -xzf "$PROBE_ARCHIVE" -C "$PROBE_COPY" --no-same-owner || probe_fail "unpacking failed"
  probe_ok
}

# probe_image CONTAINER - image and user of the PRODUCTION container: the
# probe tests what runs, not whatever "latest" is today.
probe_image() {
  PROBE_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null)
  [ -n "$PROBE_IMAGE" ] || probe_fail "image of $1 unknown (is the container there?)"
  docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 ||
    probe_fail "image $PROBE_IMAGE is missing: the backup could NOT be restored right now"
  PROBE_USER=$(docker inspect -f '{{.Config.User}}' "$1" 2>/dev/null)
  # A probe run by root (the off-site probe) hands the copy to that user.
  if [ "$(id -u)" = 0 ] && [ -n "$PROBE_DIR" ] && [ -n "$PROBE_USER" ]; then
    chown -R "$PROBE_USER" "$PROBE_DIR" || probe_fail "cannot hand the copy to $PROBE_USER"
  fi
}

# probe_run ARGS... - starts the probe container (detached, never pulled,
# labelled, no new privileges); ARGS are further docker run arguments.
probe_run() {
  probe_remove_stale
  timeout 120 docker run -d --name "$PROBE_NAME" --pull=never --label "decolab.probe=$PROBE_SERVICE" \
    --security-opt no-new-privileges:true "$@" >/dev/null ||
    probe_fail "the probe container did not start"
  PROBE_STARTED=1
}

# A container left by a killed run blocks the name; remove it only if it is
# a probe container.
probe_remove_stale() {
  local label
  label=$(docker inspect -f '{{index .Config.Labels "decolab.probe"}}' "$PROBE_NAME" 2>/dev/null) || return 0
  [ "$label" = "$PROBE_SERVICE" ] || probe_fail "$PROBE_NAME exists and is no probe container: not touched"
  timeout 60 docker rm -f -v "$PROBE_NAME" >/dev/null 2>&1
}

# probe_mounted DEST - the container really mounts the copy at DEST
probe_mounted() {
  local src
  src=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$1\"}}{{.Source}}{{end}}{{end}}" "$PROBE_NAME" 2>/dev/null)
  case $src in
    "$PROBE_COPY"/*) probe_ok ;;
    *) probe_fail "the probe mounts '${src:-nothing}' at $1 instead of the restored copy" ;;
  esac
}

# probe_count_guard KEY COUNT - silent data loss: a vault that drops from
# 205 to 3 entries is formally valid. Fails below half of the last run.
probe_count_guard() {
  local state=$DECOLAB_STATE_DIR/probe-$PROBE_SERVICE-$1 before
  before=$(cat "$state" 2>/dev/null)
  case $before in '' | *[!0-9]*) before=0 ;; esac
  [ "$2" -ge $((before / 2)) ] || probe_fail "$1 dropped from $before to $2: possible data loss"
  echo "$2" >"$state" || warn "cannot write $state"
}

# probe_sql DB SQL - one value from a SQLite database (host Python: the
# images do not all have sqlite3)
probe_sql() {
  python3 -I -c 'import sqlite3, sys
import urllib.parse
c = sqlite3.connect("file:" + urllib.parse.quote(sys.argv[1]) + "?mode=rw", uri=True)
# the file comes from a container and root may open it: its own views and
# triggers get no functions with side effects
c.execute("PRAGMA trusted_schema=OFF")
r = c.execute(sys.argv[2]).fetchone()
c.commit()
print("" if r is None else r[0])' "$1" "$2"
}

# probe_wait SECONDS WHAT CMD... - until CMD succeeds; fails with the
# container log and "after SECONDS s the probe still does not WHAT". CMD may
# set PROBE_LAST (its last answer) for that message.
probe_wait() {
  local max=$1 what=$2 i=0
  shift 2
  PROBE_LAST=""
  while [ "$i" -lt "$max" ]; do
    "$@" >/dev/null 2>&1 && return 0
    if [ "$(docker inspect -f '{{.State.Status}}' "$PROBE_NAME" 2>/dev/null)" = exited ]; then
      log "container log: $(docker logs --tail 8 "$PROBE_NAME" 2>&1 | tr '\n' ' ')"
      probe_fail "the probe container stopped: the backup cannot be loaded"
    fi
    sleep "${PROBE_STEP_S:-1}"
    i=$((i + ${PROBE_STEP_S:-1}))
  done
  log "container log: $(docker logs --tail 8 "$PROBE_NAME" 2>&1 | tr '\n' ' ')"
  local last=""
  [ -z "$PROBE_LAST" ] || last=" (last answer: '$PROBE_LAST')"
  probe_fail "after $max s the probe still does not $what$last"
}
