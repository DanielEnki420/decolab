#!/usr/bin/env bash
# Contract tests for lib/common.sh: secrets, Uptime Kuma pushes,
# notifications, the maintenance flag and textfile metrics. curl is replaced
# by tests/fakes/curl: nothing leaves the machine.
# Single quotes around $… are intended: the code runs in a child shell.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export PATH="$t_root/tests/fakes:$PATH"
export FAKE_CURL_LOG=$t_tmp/curl.log
export DECOLAB_RUN_DIR=$t_tmp/run DECOLAB_LOG_DIR=$t_tmp/log DECOLAB_TEXTFILE_DIR=$t_tmp/textfile
mkdir -p "$DECOLAB_RUN_DIR" "$DECOLAB_LOG_DIR" "$DECOLAB_TEXTFILE_DIR" "$t_tmp/secrets"

# Configuration: the example, with notifications and Kuma switched on.
sed -e 's/^NOTIFY=.*/NOTIFY=telegram/' -e "s#^SECRETS_DIR=.*#SECRETS_DIR=$t_tmp/secrets#" \
  "$t_root/decolab.conf.example" >"$t_tmp/decolab.conf"
export DECOLAB_CONF=$t_tmp/decolab.conf

token="kumatoken"; token="${token}0042"
bot="12345:bottoken"; bot="${bot}XYZ"
printf 'KUMA_BASE=http://127.0.0.1:3001/api/push\nKUMA_BACKUP=%s\n' "$token" >"$t_tmp/secrets/kuma-push.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=-100777\n' "$bot" >"$t_tmp/secrets/telegram.env"
chmod 600 "$t_tmp/secrets/"*.env

# run CODE - runs CODE in a fresh bash with lib/common.sh loaded
run() { bash -c '. "$1/lib/common.sh"; decolab_init; eval "$2"' _ "$t_root" "$1"; }

echo "secrets"
check "reads the keys asked for" 0 "-100777" -- run 'read_secrets "$SECRETS_DIR/telegram.env" TELEGRAM_CHAT_ID && echo "$TELEGRAM_CHAT_ID"'
check "missing file fails" 1 "missing or not readable" -- run 'read_secrets "$SECRETS_DIR/none.env" X'
check "missing key fails" 1 "has no KUMA_OTHER" -- run 'read_secrets "$SECRETS_DIR/kuma-push.env" KUMA_OTHER'
cp "$t_tmp/secrets/telegram.env" "$t_tmp/secrets/open.env" && chmod 644 "$t_tmp/secrets/open.env"
check "file readable by others fails" 1 "readable by every user" -- run 'read_secrets "$SECRETS_DIR/open.env" TELEGRAM_CHAT_ID'
printf 'X=$(touch %s/executed)\n' "$t_tmp" >"$t_tmp/secrets/evil.env" && chmod 600 "$t_tmp/secrets/evil.env"
check "command substitution is rejected" 1 "not allowed" -- run 'read_secrets "$SECRETS_DIR/evil.env" X'
if [ -e "$t_tmp/executed" ]; then t_fail "  ... and not executed" "marker file exists"; else t_ok "  ... and not executed"; fi
printf 'X=a\nX=b\n' >"$t_tmp/secrets/dup.env" && chmod 600 "$t_tmp/secrets/dup.env"
check "key set twice fails" 1 "set twice" -- run 'read_secrets "$SECRETS_DIR/dup.env" X'
check "bad key name fails" 1 "bad key name" -- run 'read_secrets "$SECRETS_DIR/dup.env" "X;id"'

echo "uptime kuma"
: >"$FAKE_CURL_LOG"
check "push succeeds on ok:true" 0 "" -- env FAKE_CURL_REPLY='{"ok":true}' bash -c '. "$1/lib/common.sh"; decolab_init; kuma_push BACKUP up "all good"' _ "$t_root"
check "  the token is not an argument" 1 "" -- grep "^ARGS:.*$token" "$FAKE_CURL_LOG"
check "  the token reaches curl on stdin" 0 "" -- grep "STDIN:url = \"http://127.0.0.1:3001/api/push/$token\"" "$FAKE_CURL_LOG"
check "  status and message are sent" 0 "" -- grep -e '--data-urlencode status=up --data-urlencode msg=all good' "$FAKE_CURL_LOG"
check "refused push fails loudly" 1 "refused the push" -- env FAKE_CURL_REPLY='{"ok":false,"msg":"Monitor not found"}' bash -c '. "$1/lib/common.sh"; decolab_init; kuma_push BACKUP up x' _ "$t_root"
check "curl failure fails loudly" 1 "curl exit 7" -- env FAKE_CURL_RC=7 bash -c '. "$1/lib/common.sh"; decolab_init; kuma_push BACKUP up x' _ "$t_root"
check "unknown monitor fails" 1 "has no KUMA_NOPE" -- run 'kuma_push NOPE up x'
: >"$FAKE_CURL_LOG"
check "Kuma switched off: no push, says so" 0 "Uptime Kuma is off" -- run 'MODULE_UPTIME_KUMA=no; kuma_push BACKUP down broken'
same "  ... and curl was not called" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "notifications"
: >"$FAKE_CURL_LOG"
check "telegram succeeds on ok:true" 0 "" -- env FAKE_CURL_REPLY='{"ok":true,"result":{}}' bash -c '. "$1/lib/common.sh"; decolab_init; notify "Backup" "done"' _ "$t_root"
check "  the bot token is not an argument" 1 "" -- grep "^ARGS:.*$bot" "$FAKE_CURL_LOG"
check "  chat id and text are sent" 0 "" -- grep -e '-d chat_id=-100777 --data-urlencode text=Backup' "$FAKE_CURL_LOG"
check "refused message fails loudly" 1 "Telegram refused" -- env FAKE_CURL_REPLY='{"ok":false,"description":"Unauthorized"}' bash -c '. "$1/lib/common.sh"; decolab_init; notify "Alarm" "x"' _ "$t_root"
check "  ... and is written to notify-errors.log" 0 "title: Alarm" -- cat "$DECOLAB_LOG_DIR/notify-errors.log"
check "missing bot config fails loudly" 1 "cannot read" -- env TELEGRAM_ENV_FILE="$t_tmp/none.env" bash -c '. "$1/lib/common.sh"; decolab_init; notify "Alarm" "x"' _ "$t_root"
: >"$FAKE_CURL_LOG"
check "NOTIFY=none only logs" 0 "notification (NOTIFY=none): Hello" -- run 'NOTIFY=none; notify Hello world'
same "  ... and curl was not called" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"
check "decolab-notify sends" 0 "" -- env FAKE_CURL_REPLY='{"ok":true}' "$t_root/bin/decolab-notify" "From Python" "text"
check "decolab-notify reports failure" 1 "notification failed" -- env FAKE_CURL_REPLY='nope' "$t_root/bin/decolab-notify" "From Python"

echo "notifications: ntfy"
topic="decolabtopic"; topic="${topic}7Q"
ntok="tk_ntfytoken"; ntok="${ntok}99"
printf 'NTFY_URL=https://ntfy.example/%s\n' "$topic" >"$t_tmp/secrets/ntfy.env"
printf 'NTFY_URL=https://ntfy.example/%s\nNTFY_TOKEN=%s\n' "$topic" "$ntok" >"$t_tmp/secrets/ntfy-tok.env"
printf 'NTFY_URL=https://ntfy.example/a b\n' >"$t_tmp/secrets/ntfy-bad.env"
chmod 600 "$t_tmp/secrets/"ntfy*.env
ntfy_ok='{"id":"x1","time":1,"event":"message","topic":"t"}'
: >"$FAKE_CURL_LOG"
check "ntfy succeeds on event:message" 0 "" -- env FAKE_CURL_REPLY="$ntfy_ok" bash -c 'NOTIFY_FILE=$2 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify "Backup ✅" "done \"quoted\" \\ back"'"'"' _ "$1"' _ "$t_root" "$t_tmp/secrets/ntfy.env"
check "  nothing secret is an argument (topic, token)" 1 "" -- grep -e "^ARGS:.*$topic" "$FAKE_CURL_LOG"
check "  curl reads its config from stdin only" 0 "" -- grep -x "ARGS: -sS -m 10 -K -" "$FAKE_CURL_LOG"
check "  posts to the server, not to the topic URL" 0 "" -- grep -x 'STDIN:url = "https://ntfy.example/"' "$FAKE_CURL_LOG"
check "  the body names the topic, title and text as JSON" 0 "" -- python3 -I -c '
import json, re, sys
log = open(sys.argv[1], encoding="utf-8").read()
line = [l for l in log.splitlines() if l.startswith("data-binary = ")][0]
body = json.loads(json.loads(line[len("data-binary = "):]))
assert body == {"topic": sys.argv[2], "title": "Backup \u2705", "message": "done \"quoted\" \\ back"}, body
' "$FAKE_CURL_LOG" "$topic"
check "  no token header without a token" 1 "" -- grep "Authorization" "$FAKE_CURL_LOG"
: >"$FAKE_CURL_LOG"
check "ntfy with a token" 0 "" -- env FAKE_CURL_REPLY="$ntfy_ok" bash -c 'NOTIFY_FILE=$2 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify Hi'"'"' _ "$1"' _ "$t_root" "$t_tmp/secrets/ntfy-tok.env"
check "  sends it as a bearer header, in the config" 0 "" -- grep -x "header = \"Authorization: Bearer $ntok\"" "$FAKE_CURL_LOG"
check "  ... never as an argument" 1 "" -- grep -e "^ARGS:.*$ntok" "$FAKE_CURL_LOG"
check "ntfy refusing fails loudly" 1 "ntfy refused" -- env FAKE_CURL_REPLY='{"code":40301,"error":"forbidden"}' bash -c 'NOTIFY_FILE=$2 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify Alarm2'"'"' _ "$1"' _ "$t_root" "$t_tmp/secrets/ntfy.env"
check "  ... and is written to notify-errors.log" 0 "title: Alarm2" -- cat "$DECOLAB_LOG_DIR/notify-errors.log"
check "ntfy: curl failure fails loudly" 1 "curl exit 6" -- env FAKE_CURL_RC=6 bash -c 'NOTIFY_FILE=$2 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify X'"'"' _ "$1"' _ "$t_root" "$t_tmp/secrets/ntfy.env"
check "ntfy: missing file fails loudly" 1 "cannot read" -- env bash -c 'NOTIFY_FILE=$2 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify X'"'"' _ "$1"' _ "$t_root" "$t_tmp/none.env"
: >"$FAKE_CURL_LOG"
check "ntfy: a malformed URL is refused before curl" 1 "" -- env bash -c 'NOTIFY_FILE=$2 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify X'"'"' _ "$1"' _ "$t_root" "$t_tmp/secrets/ntfy-bad.env"
same "  ... and curl was not called" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"
check "ntfy: an URL without a topic is refused" 1 "not like https://ntfy.sh/TOPIC" -- env bash -c 'printf "NTFY_URL=https://ntfy.example\n" >"$3"; chmod 600 "$3"; NOTIFY_FILE=$3 bash -c '"'"'. "$1/lib/common.sh"; decolab_init; NOTIFY=ntfy; NTFY_ENV_FILE=$NOTIFY_FILE; notify X'"'"' _ "$1"' _ "$t_root" x "$t_tmp/secrets/ntfy-host.env"

echo "maintenance flag"
check "flag names the containers" 0 "[ pihole immich_server ]" -- run 'maintenance_begin pihole immich_server && maintenance_read && echo "[$MAINTENANCE_CONTAINERS]"'
printf 'pid 999999\npihole\n' >"$DECOLAB_RUN_DIR/maintenance"
check "orphaned flag is reported, nothing suppressed" 0 "orphaned: process 999999 is gone|" -- run 'maintenance_read; echo "$MAINTENANCE_PROBLEM|$MAINTENANCE_CONTAINERS"'
printf 'pihole\n' >"$DECOLAB_RUN_DIR/maintenance"
check "flag without PID is ignored" 0 "without PID" -- run 'maintenance_read; echo "$MAINTENANCE_PROBLEM"'
check "stale flag is reported" 0 "min old" -- run 'printf "pid %s\npihole\n" $$ > "$DECOLAB_RUN_DIR/maintenance"; touch -t 202001010000 "$DECOLAB_RUN_DIR/maintenance"; maintenance_read; echo "$MAINTENANCE_PROBLEM|$MAINTENANCE_CONTAINERS"'
check "maintenance_end removes the flag" 1 "" -- run 'maintenance_begin x; maintenance_end; test -e "$DECOLAB_RUN_DIR/maintenance"'
check "unwritable flag fails loudly" 1 "false alarms are possible" -- env DECOLAB_RUN_DIR="$t_tmp/nonexistent" bash -c '. "$1/lib/common.sh"; maintenance_begin x' _ "$t_root"

echo "textfile metrics"
check "writes the metric file" 0 "decolab_test 1" -- run 'echo "decolab_test 1" | textfile_write test && cat "$DECOLAB_TEXTFILE_DIR/test.prom"'
same "  ... without leftovers" "$(ls "$DECOLAB_TEXTFILE_DIR")" "test.prom"
check "unwritable directory fails loudly" 1 "cannot write" -- env DECOLAB_TEXTFILE_DIR="$t_tmp/nonexistent" bash -c '. "$1/lib/common.sh"; echo x | textfile_write test' _ "$t_root"

echo "settings"
check "is_yes" 0 "yes-no" -- run 'is_yes MODULE_IMMICH && printf yes; is_yes HARDENING || printf -- -no'
check "is_yes refuses odd names" 1 "" -- run 'is_yes "X;id"'
check "hw_wanted auto runs the detection" 0 "found-missing" -- run 'HW_FAN=auto; hw_wanted HW_FAN true && printf found; hw_wanted HW_FAN false || printf -- -missing'
check "hw_wanted yes/no ignore it" 0 "yes-no" -- run 'HW_FAN=yes; hw_wanted HW_FAN false && printf yes; HW_FAN=no; hw_wanted HW_FAN true || printf -- -no'
check "invalid configuration stops a script" 1 "is invalid" -- env DECOLAB_CONF="$t_tmp/none.conf" bash -c '. "$1/lib/common.sh"; decolab_init; echo reached' _ "$t_root"
refute "  ... before it does anything" "reached"

t_finish
