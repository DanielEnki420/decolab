#!/usr/bin/env bash
# Contract tests for the maintenance jobs: prometheus-rules-sync.sh, ...
# docker is a fake; the files Prometheus "sees" live in $inside and are
# replaced by the host's only when the fake container restarts.
# Single quotes around $… are intended: the fakes evaluate them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

echo "prometheus-rules-sync.sh"
host_dir=$t_root/config/prometheus
export INSIDE=$t_tmp/inside SYNC_STEP_S=1 SYNC_WAIT_S=3
mkdir -p "$INSIDE"
# A container that still reads the old files: one alert rule less.
stale() {
  cp "$host_dir/prometheus.yml" "$INSIDE/prometheus.yml"
  awk '!done && /- alert:/ { sub(/- alert:/, "- disabled:"); done = 1 } 1' "$host_dir/rules.yml" >"$INSIDE/rules.yml"
}
fresh() { cp "$host_dir/prometheus.yml" "$host_dir/rules.yml" "$INSIDE/"; }
export FAKE_DOCKER='sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }
case $1 in
  exec) [ -z "${DOWN:-}" ] || exit 1
    case "$*" in
      *sha256sum*) f=${*: -1}; sum "$INSIDE/${f##*/}" ;;
      *alert:*) grep -cE "^[[:space:]]+- alert:" "$INSIDE/rules.yml" ;;
    esac ;;
  inspect) echo "image-of-$4" ;;
  run) printf "%s\n" "$@" >"$INSIDE.run"; [ -z "${PROMTOOL_BAD:-}" ] || { echo "FAILED: rules.yml: yaml: line 7"; exit 1; } ;;
  restart) [ -e "$DECOLAB_RUN_DIR/maintenance" ] && grep -qx prometheus "$DECOLAB_RUN_DIR/maintenance" && echo flagged >"$INSIDE.flag"
    [ -n "${STALE:-}" ] || cp "'"$host_dir"'/prometheus.yml" "'"$host_dir"'/rules.yml" "$INSIDE/" ;;
esac'
rules=$(grep -cE '^[[:space:]]+- alert:' "$host_dir/rules.yml")
restarts() { grep -c '^restart' "$FAKE_DOCKER_LOG"; }

fresh
check "the same files: nothing to do" 0 "nothing to do" -- script prometheus-rules-sync.sh
same "  no restart" "$(restarts)" "0"

stale
check "the container reads old rules: synced" 0 "synced (rules.yml ): $((rules - 1)) -> $rules alert rules" -- script prometheus-rules-sync.sh
same "  one restart" "$(restarts)" "1"
same "  announced in the maintenance flag while restarting" "$(cat "$INSIDE.flag" 2>/dev/null)" "flagged"
check "  ... and the flag is gone afterwards" 0 "" -- test ! -e "$DECOLAB_RUN_DIR/maintenance"
check "  promtool ran without network, on the host files, read-only" 0 "" -- bash -c 'grep -x none "$1" && grep -x "$2/rules.yml:/etc/prometheus/rules.yml:ro" "$1" && grep -x image-of-prometheus "$1"' _ "$INSIDE.run" "$host_dir"
check "  a message with the counts" 0 "Alert rules synced: $((rules - 1)) -> $rules" -- telegrams

: >"$FAKE_CURL_LOG"
stale
check "invalid new files: no restart" 1 "promtool rejects the new files" -- env PROMTOOL_BAD=1 "$t_root/scripts/prometheus-rules-sync.sh"
same "  no restart" "$(restarts)" "1"
check "  a message" 0 "was NOT loaded" -- telegrams

check "the restart does not bring the new files: reported" 1 "still the old files after the restart" -- env STALE=1 "$t_root/scripts/prometheus-rules-sync.sh"
check "  ... and the flag is gone" 0 "" -- test ! -e "$DECOLAB_RUN_DIR/maintenance"

check "Prometheus does not answer: nothing done" 1 "does not answer" -- env DOWN=1 "$t_root/scripts/prometheus-rules-sync.sh"
check "a backup holds the lock: postponed, no restart" 0 "postponed" -- env FAKE_FLOCK_BUSY=1 "$t_root/scripts/prometheus-rules-sync.sh"
same "  no restart" "$(restarts)" "2"

: >"$FAKE_CURL_LOG"
fresh
printf '\n# changed\n' >>"$INSIDE/prometheus.yml"
check "only prometheus.yml differs: synced" 0 "synced (prometheus.yml ): $rules -> $rules" -- script prometheus-rules-sync.sh
same "  ... no message: the rules did not change" "$(telegrams)" ""

echo "image-digests.sh"
dir=$DECOLAB_STATE_DIR/image-digests
today=$dir/$(date +%F).txt
export CONTAINERS="pihole portainer uptime-kuma panel" LOCAL=panel WT=portainer DIGEST_OF_PIHOLE=sha256:1111
export FAKE_DOCKER='case $1 in
  ps) [ -z "${DOWN:-}" ] || exit 1; printf "%s\n" $CONTAINERS ;;
  inspect) case "$*" in
      *Config.Image*) echo "repo/$4:1" ;;
      *watchtower*) [ "$4" = "$WT" ] && echo true || echo false ;;
    esac ;;
  image) n=${5#repo/}; n=${n%:1}; [ "$n" = "$LOCAL" ] && exit 0
    if [ "$n" = pihole ]; then echo "repo/$n@$DIGEST_OF_PIHOLE"; else echo "repo/$n@sha256:abcd"; fi ;;
esac'
check "writes today's list" 0 "OK: 4 containers" -- script image-digests.sh
check "  with digests, the Watchtower column, local builds named" 0 "" -- bash -c 'grep -qE "^pihole +repo/pihole:1 +sha256:1111 +no$" "$1" && grep -qE "^portainer .* yes$" "$1" && grep -q "^panel .*(built locally: no digest)" "$1"' _ "$today"
same "  readable by everyone (no secrets in it)" "$(find "$today" -perm 644 | wc -l | tr -d ' ')" "1"
mv "$today" "$dir/2020-01-01.txt"
check "a new pihole image since the last list: named" 0 "new image since 2020-01-01.txt: pihole" -- env DIGEST_OF_PIHOLE=sha256:2222 "$t_root/scripts/image-digests.sh"
printf "x repo/x sha256:1 no\n%.0s" $(seq 1 10) >"$dir/2020-01-02.txt"
rm -f "$today"
check "fewer than half the containers of the last list: the old list stays" 1 "only 4 containers (last list: 10)" -- script image-digests.sh
check "  ... nothing written" 0 "" -- test ! -e "$today"
check "docker does not answer" 1 "docker does not answer" -- env DOWN=1 "$t_root/scripts/image-digests.sh"
rm -f "$dir"/*
for d in $(seq 1 95); do printf "x repo/x sha256:1 no\n" >"$dir/2020-$(printf '%02d' $(( (d - 1) / 28 + 1 )))-$(printf '%02d' $(( (d - 1) % 28 + 1 ))).txt"; done
check "rotation keeps 90 lists by count" 0 "OK" -- script image-digests.sh
same "  90 left, today's among them" "$(find "$dir" -name '*.txt' | wc -l | tr -d ' ') $(test -e "$today" && echo today)" "90 today"

t_finish
