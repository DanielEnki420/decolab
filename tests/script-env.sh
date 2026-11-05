# shellcheck shell=bash
# tests/script-env.sh - a sandbox for running Decolab's scripts in tests.
#
# Sourced after tests/lib.sh. Sets up a configuration (the example with all
# modules on and Telegram notifications), secrets in $t_tmp, and puts the
# fakes from tests/fakes first in PATH: docker, curl, systemctl, tailscale
# and timeout never reach the real ones. Every Uptime Kuma push and Telegram
# message ends up in $FAKE_CURL_LOG, where the helpers below look.
# t_root and t_tmp come from tests/lib.sh; the single-quoted fake code is
# evaluated later by the fakes.
# shellcheck disable=SC2154,SC2016

export PATH="$t_root/tests/fakes:$PATH"
export FAKE_CURL_LOG=$t_tmp/curl.log FAKE_DOCKER_LOG=$t_tmp/docker.log
export DECOLAB_RUN_DIR=$t_tmp/run DECOLAB_LOG_DIR=$t_tmp/log DECOLAB_TEXTFILE_DIR=$t_tmp/textfile
export DECOLAB_STATE_DIR=$t_tmp/state
mkdir -p "$DECOLAB_RUN_DIR" "$DECOLAB_LOG_DIR" "$DECOLAB_TEXTFILE_DIR" "$DECOLAB_STATE_DIR" "$t_tmp/secrets"
: >"$FAKE_CURL_LOG"
: >"$FAKE_DOCKER_LOG"

sed -e 's/^NOTIFY=.*/NOTIFY=telegram/' -e "s#^SECRETS_DIR=.*#SECRETS_DIR=$t_tmp/secrets#" \
  -e "s#^DATA_DIR=.*#DATA_DIR=$t_tmp/data#" -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$t_tmp/data/backups#" \
  "$t_root/decolab.conf.example" >"$t_tmp/decolab.conf"
export DECOLAB_CONF=$t_tmp/decolab.conf

{
  echo "KUMA_BASE=http://127.0.0.1:3001/api/push"
  for m in SAMBA DNSSEC IMMICH PERSES PROMETHEUS CADVISOR PORTAINER PIHOLE NVME \
    BACKUP VERIFY USB OFFSITE RESTIC PROBE_PIHOLE PROBE_VAULTWARDEN PROBE_VAULTWARDEN_OFFSITE \
    PROBE_IMMICH PROBE_KUMA UPDATES UPS; do
    echo "KUMA_$m=tok_$m"
  done
} >"$t_tmp/secrets/kuma-push.env"
printf 'TELEGRAM_BOT_TOKEN=1:fake\nTELEGRAM_CHAT_ID=-1\n' >"$t_tmp/secrets/telegram.env"
chmod 600 "$t_tmp/secrets/"*.env

# Kuma and Telegram always accept; FAKE_CURL_MORE answers everything else.
export FAKE_CURL='case $stdin in
  *api/push/*) printf "{\"ok\":true}" ;;
  *api.telegram.org*) printf "{\"ok\":true}" ;;
  *) eval "${FAKE_CURL_MORE:-exit 7}" ;;
esac'

# kuma MONITOR - the last push to MONITOR as "STATUS MESSAGE", empty if none
kuma() {
  awk -v t="/tok_$1\"" 'BEGIN { RS = "--\n" } index($0, t) { r = $0 } END { print r }' "$FAKE_CURL_LOG" |
    sed -n 's/^ARGS:.*--data-urlencode status=\([a-z]*\) --data-urlencode msg=\(.*\)$/\1 \2/p'
}

# telegrams - all notification texts sent so far, one per record
telegrams() {
  awk 'BEGIN { RS = "--\n" } /api.telegram.org/ { sub(/^.*--data-urlencode text=/, ""); sub(/\nSTDIN:.*/, ""); print }' "$FAKE_CURL_LOG"
}

# script NAME [ARGS] - runs scripts/NAME with stdin closed
script() {
  local name=$1
  shift
  "$t_root/scripts/$name" "$@" </dev/null
}
