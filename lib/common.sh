# shellcheck shell=bash
# lib/common.sh - shared helpers for Decolab's scripts
#
# Usage at the top of a script:
#   . "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
#   decolab_init              # loads decolab.conf or exits with its errors
#
# Two rules hold for everything in here:
#   - Secrets never appear in a process list or a log. curl gets every URL
#     that contains a token on stdin (-K -), never as an argument: the
#     arguments of running processes are visible to every user (ps).
#   - Failure is loud. A helper that cannot do its job returns non-zero and
#     says why; it never reports success it did not have. A notification
#     path that fails silently would swallow every alarm of the system.
#
# Secret files (SECRETS_DIR/*.env) are read like decolab.conf: as data, line
# by line, only the keys asked for, never sourced.
#
# Paths can be overridden for tests (DECOLAB_CONF, DECOLAB_RUN_DIR,
# DECOLAB_LOG_DIR, DECOLAB_TEXTFILE_DIR, DECOLAB_STATE_DIR, KUMA_ENV_FILE,
# TELEGRAM_ENV_FILE, NTFY_ENV_FILE):
# a test must never reach the real Uptime Kuma or the real phone.
# Compatible with bash 3.2 (macOS) and bash 5 (Debian).

decolab_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/config.sh
. "$decolab_root/lib/config.sh"

DECOLAB_CONF=${DECOLAB_CONF:-$decolab_root/decolab.conf}
DECOLAB_RUN_DIR=${DECOLAB_RUN_DIR:-/run/decolab}
DECOLAB_LOG_DIR=${DECOLAB_LOG_DIR:-/var/log/decolab}
DECOLAB_TEXTFILE_DIR=${DECOLAB_TEXTFILE_DIR:-/var/lib/node_exporter}
# Small state files of the scripts (last counts, last reported situation)
DECOLAB_STATE_DIR=${DECOLAB_STATE_DIR:-/var/lib/decolab}
# How long a maintenance flag may suppress alarms. A job pauses containers
# for a few minutes; much longer would be dangerous, because a
# stopped Pi-hole means no DNS filter in the house.
DECOLAB_MAINTENANCE_MAX_MIN=${DECOLAB_MAINTENANCE_MAX_MIN:-20}

# --- logging -----------------------------------------------------------------

# Cron appends stdout and stderr of each job to /var/log/decolab/<job>.log.
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARNING: $*"; }
die() {
  log "ERROR: $*"
  exit 1
}

# --- configuration -----------------------------------------------------------

decolab_init() {
  decolab_config_load "$DECOLAB_CONF" || die "$DECOLAB_CONF is invalid (bin/decolab-config check)"
}

# _valid_name NAME - only upper-case variable names reach eval below
_valid_name() {
  case $1 in '' | [0-9]* | *[!A-Z0-9_]*) return 1 ;; esac
}

# is_yes SETTING - true if the setting (by name) is "yes"
is_yes() {
  local v
  _valid_name "$1" || return 1
  eval "v=\${$1:-}"
  [ "$v" = yes ]
}

# hw_wanted SETTING DETECT-COMMAND... - HW_* settings: yes = always, no =
# never, auto = if the detection command succeeds
hw_wanted() {
  local setting=$1 v
  shift
  _valid_name "$setting" || return 1
  eval "v=\${$setting:-auto}"
  case $v in
    yes) return 0 ;;
    no) return 1 ;;
    *) "$@" >/dev/null 2>&1 ;;
  esac
}

# --- secrets -----------------------------------------------------------------

# read_secrets FILE KEY... - sets each KEY from FILE (KEY=VALUE lines).
# Fails if the file is missing, readable by others, malformed, or lacks a
# key. Values: letters, digits and . _ / : @ + , - only.
read_secrets() {
  local file=$1 line key value want n=0 found
  shift
  for want in "$@"; do
    _valid_name "$want" || {
      log "ERROR: read_secrets: bad key name '$want'"
      return 1
    }
  done
  [ -r "$file" ] || {
    log "ERROR: secret file $file is missing or not readable"
    return 1
  }
  if [ -n "$(find "$file" -prune -perm -004 2>/dev/null)" ]; then
    log "ERROR: $file is readable by every user; chmod 600 it"
    return 1
  fi
  for want in "$@"; do
    found=0 n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      case $line in '' | '#'*) continue ;; esac
      key=${line%%=*}
      [ "$key" = "$want" ] || continue
      if [ "$found" -eq 1 ]; then
        log "ERROR: $file:$n: $key is set twice"
        return 1
      fi
      value=${line#*=}
      if ! [[ $value =~ ^[A-Za-z0-9._/:@+,-]+$ ]]; then
        log "ERROR: $file:$n: $key has an empty value or characters that are not allowed"
        return 1
      fi
      printf -v "$key" '%s' "$value"
      found=1
    done <"$file"
    [ "$found" -eq 1 ] || {
      log "ERROR: $file has no $want"
      return 1
    }
  done
}

# --- Uptime Kuma -------------------------------------------------------------

# kuma_push MONITOR up|down MESSAGE
#   Pushes to the Uptime Kuma push monitor whose token is KUMA_<MONITOR> in
#   SECRETS_DIR/kuma-push.env (KUMA_BASE is the push URL prefix, for example
#   http://127.0.0.1:3001/api/push). A push monitor is a dead-man's switch:
#   if the pushes stop, it turns red by itself.
kuma_push() {
  local monitor=$1 status=$2 msg=$3 env token answer rc=0
  _valid_name "$monitor" || {
    log "ERROR: kuma_push: bad monitor name '$monitor'"
    return 1
  }
  if ! is_yes MODULE_UPTIME_KUMA; then
    log "Uptime Kuma is off (MODULE_UPTIME_KUMA=no); result $monitor: $status $msg"
    return 0
  fi
  env=${KUMA_ENV_FILE:-${SECRETS_DIR:-/nonexistent}/kuma-push.env}
  read_secrets "$env" KUMA_BASE "KUMA_$monitor" || return 1
  eval "token=\$KUMA_$monitor"
  answer=$(printf 'url = "%s/%s"\n' "$KUMA_BASE" "$token" |
    curl -sS -m 10 -G -K - --data-urlencode "status=$status" --data-urlencode "msg=$msg" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "ERROR: push to Uptime Kuma ($monitor) failed: curl exit $rc"
    return 1
  fi
  case $answer in
    *'"ok":true'*) return 0 ;;
    *)
      log "ERROR: Uptime Kuma refused the push ($monitor): $(printf '%s' "$answer" | head -c 150)"
      return 1
      ;;
  esac
}

# --- notifications -----------------------------------------------------------

# notify TITLE TEXT
#   NOTIFY=telegram: sends through the bot in SECRETS_DIR/telegram.env
#   (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID). Every failure is written to
#   /var/log/decolab/notify-errors.log as well and returns 1; Telegram's
#   answer is checked, because curl is happy with any HTTP reply.
#   NOTIFY=ntfy: publishes to NTFY_URL (https://SERVER/TOPIC) in
#   SECRETS_DIR/ntfy.env, with NTFY_TOKEN as bearer token if set. The topic
#   is a secret on a public server: anyone who knows it can read along.
#   NOTIFY=none: only logs the title.
notify() {
  local title=$1 text=${2:-} env answer rc=0 why=""
  case ${NOTIFY:-none} in
    telegram) ;;
    ntfy)
      _notify_ntfy "$title" "$text" && return 0
      log "ERROR: notification failed ($why): $title"
      printf '%s %s: %s | title: %s\n' "$(date '+%F %T')" "${0##*/}" "$why" "$title" \
        >>"$DECOLAB_LOG_DIR/notify-errors.log" 2>/dev/null
      return 1 ;;
    *)
      log "notification (NOTIFY=${NOTIFY:-none}): $title"
      return 0 ;;
  esac
  env=${TELEGRAM_ENV_FILE:-${SECRETS_DIR:-/nonexistent}/telegram.env}
  if ! read_secrets "$env" TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID; then
    why="cannot read $env"
  else
    answer=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
      curl -sS -m 10 -K - -d "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$title
$text" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      why="curl exit $rc"
    else
      case $answer in
        *'"ok":true'*) return 0 ;;
        *) why="Telegram refused: $(printf '%s' "$answer" | head -c 150)" ;;
      esac
    fi
  fi
  log "ERROR: notification failed ($why): $title"
  printf '%s %s: %s | title: %s\n' "$(date '+%F %T')" "${0##*/}" "$why" "$title" \
    >>"$DECOLAB_LOG_DIR/notify-errors.log" 2>/dev/null
  return 1
}

# _notify_ntfy TITLE TEXT - sets why on failure (notify's local)
#   Everything goes to curl as its config on stdin (-K -): URL, token and
#   body (JSON, so titles may hold any character) never appear in the
#   process list. ntfy answers a published message with "event":"message".
_notify_ntfy() {
  local env answer rc=0 NTFY_URL="" NTFY_TOKEN=""
  env=${NTFY_ENV_FILE:-${SECRETS_DIR:-/nonexistent}/ntfy.env}
  if ! read_secrets "$env" NTFY_URL; then
    why="cannot read $env"
    return 1
  fi
  if grep '^NTFY_TOKEN=' "$env" >/dev/null 2>&1 && ! read_secrets "$env" NTFY_TOKEN; then
    why="cannot read NTFY_TOKEN in $env"
    return 1
  fi
  if ! [[ $NTFY_URL =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._-]+)*/[A-Za-z0-9_-]{1,64}$ ]]; then
    why="NTFY_URL is not like https://ntfy.sh/TOPIC"
    return 1
  fi
  answer=$(N_URL=$NTFY_URL N_TOKEN=$NTFY_TOKEN N_TITLE=$1 N_TEXT=$2 python3 -I -c '
import json, os
url = os.environ["N_URL"]
base, topic = url.rsplit("/", 1)
body = json.dumps({"topic": topic, "title": os.environ["N_TITLE"],
                   "message": os.environ["N_TEXT"] or os.environ["N_TITLE"]})
q = lambda v: json.dumps(v)  # ASCII only: the same escapes as curl'"'"'s config
print("url = " + q(base + "/"))
print("header = " + q("Content-Type: application/json"))
if os.environ["N_TOKEN"]:
    print("header = " + q("Authorization: Bearer " + os.environ["N_TOKEN"]))
print("data-binary = " + q(body))
' | curl -sS -m 10 -K - 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    why="curl exit $rc"
    return 1
  fi
  case $answer in
    *'"event":"message"'*) return 0 ;;
  esac
  why="ntfy refused: $(printf '%s' "$answer" | head -c 150)"
  return 1
}

# --- maintenance flag --------------------------------------------------------
#
# A job that stops containers on purpose (an update) writes a flag naming
# them, so that the watchers do not report what is expected to be down. The
# flag carries the job's PID: if the job dies without its EXIT trap (SIGKILL,
# OOM), the orphaned flag is noticed at once instead of silencing alarms
# until it expires. It lives in /run (tmpfs): a flag that survived a reboot
# could match a PID that has long been reused.

maintenance_flag() { printf '%s/maintenance' "$DECOLAB_RUN_DIR"; }

# maintenance_begin CONTAINER... - announce BEFORE stopping anything
maintenance_begin() {
  local flag
  flag=$(maintenance_flag)
  if { printf 'pid %s\n' "$$" && printf '%s\n' "$@"; } >"$flag.tmp" 2>/dev/null && mv "$flag.tmp" "$flag"; then
    return 0
  fi
  # Without the flag there will be false alarms, never false silence.
  log "ERROR: cannot write the maintenance flag $flag; false alarms are possible"
  return 1
}

maintenance_end() {
  local flag
  flag=$(maintenance_flag)
  rm -f "$flag" "$flag.tmp"
}

# _pid_alive PID - /proc where it exists: kill -0 fails with EPERM for a
# process of another user, which would look like an orphaned flag.
_pid_alive() {
  case $1 in '' | *[!0-9]*) return 1 ;; esac
  if [ -d /proc/self ]; then [ -d "/proc/$1" ]; else kill -0 "$1" 2>/dev/null; fi
}

# maintenance_read - sets
#   MAINTENANCE_CONTAINERS  " a b " if the flag is valid, else empty
#   MAINTENANCE_NAMED       " a b " named by the flag, valid or not
#   MAINTENANCE_PROBLEM     a message if the flag exists but must not be trusted
# Read it as LATE as possible, after collecting what is down: a job and its
# watcher may start in the same second.
# shellcheck disable=SC2034  # results for the caller
maintenance_read() {
  local flag pid age
  flag=$(maintenance_flag)
  MAINTENANCE_CONTAINERS="" MAINTENANCE_NAMED="" MAINTENANCE_PROBLEM=""
  [ -f "$flag" ] || return 0
  pid=$(awk '$1 == "pid" { print $2; exit }' "$flag" 2>/dev/null)
  MAINTENANCE_NAMED=" $(awk '$1 != "pid"' "$flag" 2>/dev/null | tr '\n' ' ')"
  age=$((($(date +%s) - $(date -r "$flag" +%s 2>/dev/null || echo 0)) / 60))
  if [ -z "$pid" ]; then
    MAINTENANCE_PROBLEM="maintenance flag without PID: ignored"
  elif ! _pid_alive "$pid"; then
    MAINTENANCE_PROBLEM="maintenance flag orphaned: process $pid is gone"
  elif [ "$age" -gt "$DECOLAB_MAINTENANCE_MAX_MIN" ]; then
    MAINTENANCE_PROBLEM="maintenance flag is $age min old (allowed: $DECOLAB_MAINTENANCE_MAX_MIN): the job hangs"
  else
    MAINTENANCE_CONTAINERS=$MAINTENANCE_NAMED
  fi
}

# --- Prometheus textfile metrics ---------------------------------------------

# textfile_write NAME - writes stdin to TEXTFILE_DIR/NAME.prom atomically
# (temporary file in the same directory, then rename), so node_exporter
# never reads half a file. The directory is mounted as a whole into
# node_exporter, so the rename is seen (unlike a single-file bind mount).
textfile_write() {
  local target=$DECOLAB_TEXTFILE_DIR/$1.prom
  if cat >"$target.$$" 2>/dev/null && chmod 644 "$target.$$" && mv "$target.$$" "$target"; then
    return 0
  fi
  rm -f "$target.$$"
  log "ERROR: cannot write $target"
  return 1
}

# --- correctness checks ------------------------------------------------------
#
# A check measures the EFFECT (a real login, a validated signature, data that
# is really there), not whether a port answers, and reports to its Uptime
# Kuma push monitor. If the check itself stops running, the monitor turns red
# by itself.
#
#   CHECK_MONITOR=SAMBA        # token: KUMA_SAMBA in kuma-push.env
#   check_fail "reason"        # pushes down, logs, exits 1
#   check_ok "what was seen"   # pushes up, logs, exits 0 (1 if the push failed)

check_fail() {
  kuma_push "${CHECK_MONITOR:?}" down "$1"
  log "FAILED: $1"
  exit 1
}

check_ok() {
  if kuma_push "${CHECK_MONITOR:?}" up "$1"; then
    log "OK: $1"
    exit 0
  fi
  log "OK, but the result did not reach Uptime Kuma: $1"
  exit 1
}

# prom_query PROMQL - prints the first value of an instant query, nothing on
# error or empty result
# (the answer is kept first, then parsed: data, never run)
prom_query() {
  local answer
  answer=$(curl -sS -m 10 -G "${PROM_URL:-http://127.0.0.1:9090}/api/v1/query" --data-urlencode "query=$1" 2>/dev/null) || answer=""
  printf '%s' "$answer" |
    python3 -I -c 'import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(r[0]["value"][1] if r else "")
except Exception:
    print("")' 2>/dev/null
}

# --- one heavy job at a time -------------------------------------------------
#
# job_lock SECONDS - waits up to SECONDS for the shared lock of the heavy
# jobs (backup.sh, backup-usb.sh, backup-offsite.sh, update.sh, the restic
# check), holds it until the script exits (file descriptor 9). Returns 1 if
# it is still taken then. One lock for all of them: an update that restarts
# immich_postgres in the middle of the dump, or restic reading a backup
# folder that is still being written, would both produce a backup that
# looks fine and is not.
#
# The lock file is opened read-only: flock works on any open file, and a
# file created by a root job (0644) stays usable for DECOLAB_USER's jobs.
job_lock() {
  local file=$DECOLAB_RUN_DIR/jobs.lock
  if [ ! -e "$file" ]; then
    (umask 022 && : >>"$file") 2>/dev/null || {
      log "ERROR: cannot create the job lock $file"
      return 1
    }
  fi
  exec 9<"$file" || {
    log "ERROR: cannot open the job lock $file"
    return 1
  }
  flock -w "$1" 9 && return 0
  log "ERROR: another heavy job still holds $file after $1 s"
  return 1
}

# --- backups -----------------------------------------------------------------

# Name of a complete nightly backup in BACKUP_DIR (backup.sh); a run with
# errors is "<name>-incomplete", one in progress ".partial-<name>".
# shellcheck disable=SC2034 # used by the scripts
DECOLAB_BACKUP_PATTERN='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]'

# backup_latest - path of the newest complete backup, empty if there is none
backup_latest() {
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name "$DECOLAB_BACKUP_PATTERN" 2>/dev/null | sort | tail -1
}

# backup_age_h PATH - age of a backup in hours, taken from its NAME: an mtime
# changes when a file is copied in or out
backup_age_h() {
  local then_s
  then_s=$(python3 -I -c 'import datetime, sys
print(int(datetime.datetime.strptime(sys.argv[1][:16], "%Y-%m-%d_%H-%M").timestamp()))' "${1##*/}") || return 1
  echo $((($(date +%s) - then_s) / 3600))
}
