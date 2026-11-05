#!/usr/bin/env bash
# Contract tests for the correctness checks (scripts/check-*.sh, monitor.sh,
# watchdog.sh): what they push to Uptime Kuma and send as notifications for
# healthy and broken states. All tools are fakes (tests/script-env.sh).
# Single quotes around $… are intended: the fakes evaluate them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

echo "samba"
pw="sambapass"; pw="${pw}9271"
printf '%s\n' "$pw" >"$t_tmp/secrets/samba_password"
export FAKE_DOCKER='cat >/dev/null; printf "\n\tSharename       Type      Comment\n\t---------       ----      -------\n\tNAS             Disk      \n"'
check "real login with the share: up" 0 "OK: login works" -- script check-samba-login.sh
same "  Kuma got up" "$(kuma SAMBA | cut -d' ' -f1)" "up"
check "  the password never was an argument" 1 "" -- grep -F "$pw" "$FAKE_DOCKER_LOG"
export FAKE_DOCKER='cat >/dev/null; echo "session setup failed: NT_STATUS_LOGON_FAILURE"; exit 1'
check "failed login: down with the reason" 1 "NT_STATUS_LOGON_FAILURE" -- script check-samba-login.sh
same "  Kuma got down" "$(kuma SAMBA)" "down login failed: NT_STATUS_LOGON_FAILURE"
export FAKE_DOCKER='cat >/dev/null; printf "\tIPC$            IPC       IPC Service\n"'
check "login without the share: down" 1 "login failed" -- script check-samba-login.sh

echo "dnssec"
good=';; flags: qr rd ra ad ; QUERY: 1, ANSWER: 2'
export FAKE_DOCKER='case "$*" in *cloudflare.com*) echo "$GOOD" ;; *dnssec-failed.org*) echo ";; ->>HEADER<<- opcode: QUERY, rcode: SERVFAIL, id: 1" ;; esac'
export GOOD=$good
check "validates and rejects: up" 0 "DNSSEC validates" -- script check-unbound-dnssec.sh
export FAKE_DOCKER='case "$*" in *cloudflare.com*) echo "$GOOD" ;; *) echo ";; ->>HEADER<<- rcode: NOERROR" ;; esac'
check "broken signature accepted: down" 1 "was NOT rejected" -- script check-unbound-dnssec.sh
export GOOD=';; flags: qr rd ra ; QUERY: 1'
check "no ad flag: down" 1 "ad flag missing" -- script check-unbound-dnssec.sh

echo "immich"
printf 'DB_USERNAME=immich\nDB_DATABASE_NAME=immich\nDB_PASSWORD=x\n' >"$t_tmp/secrets/immich.env" && chmod 600 "$t_tmp/secrets/immich.env"
export FAKE_DOCKER='case "$*" in *psql*) echo "$COUNT" ;; *touch*) exit 0 ;; esac' COUNT=1000
check "assets counted, upload writable: up" 0 "1000 assets" -- script check-immich-data.sh
same "  count remembered" "$(cat "$DECOLAB_STATE_DIR/immich-asset-count")" "1000"
export COUNT=960
check "4 % fewer photos is normal" 0 "960 assets" -- script check-immich-data.sh
export COUNT=900
check "more than 5 % fewer photos: down" 1 "dropped from 960 to 900" -- script check-immich-data.sh
same "  the old count stays, so the alarm stays" "$(cat "$DECOLAB_STATE_DIR/immich-asset-count")" "960"
export FAKE_DOCKER='case "$*" in *psql*) echo "connection refused" ;; esac'
check "database does not answer: down" 1 "database does not answer" -- script check-immich-data.sh
export FAKE_DOCKER='case "$*" in *psql*) echo 960 ;; *touch*) exit 1 ;; esac'
check "upload not writable: down" 1 "cannot write its upload directory" -- script check-immich-data.sh
: >"$FAKE_CURL_LOG"
check "module off: quiet, no push" 0 "" -- env DECOLAB_CONF="$t_tmp/noimmich.conf" bash -c 'sed "s/^MODULE_IMMICH=.*/MODULE_IMMICH=no/" "$1" > "$2"; "$3"' _ "$DECOLAB_CONF" "$t_tmp/noimmich.conf" "$t_root/scripts/check-immich-data.sh"
same "  ... nothing pushed" "$(kuma IMMICH)" ""

echo "perses"
n=$(find "$t_root/config/perses/provisioning" -name 'dashboard-*.json' | wc -l | tr -d ' ')
export N=$n FAKE_CURL_MORE='case "$*" in *health*) echo "{\"database\":true}" ;; *dashboards*) python3 -c "import json; print(json.dumps([{}] * $N))" ;; esac'
check "health and all dashboards: up" 0 "$n dashboards loaded" -- script check-perses.sh
export N=$((n - 1))
check "a dashboard missing: down" 1 "$((n - 1)) of $n dashboards" -- script check-perses.sh
export FAKE_CURL_MORE='exit 7'
check "Perses does not answer: down" 1 "does not answer" -- script check-perses.sh

echo "prometheus alerts"
rules=$(grep -cE '^[[:space:]]+- alert:' "$t_root/config/prometheus/rules.yml")
prom() { # TARGETS_HEALTH RULE_COUNT FIRING_ALERTNAME
  export P_HEALTH=$1 P_RULES=$2 P_FIRING=$3
  export FAKE_CURL_MORE='case "$*" in
    *healthy*) echo ok ;;
    *targets*) echo "{\"data\":{\"activeTargets\":[{\"health\":\"up\",\"labels\":{\"job\":\"node\"}},{\"health\":\"$P_HEALTH\",\"labels\":{\"job\":\"cadvisor\"}}]}}" ;;
    *rules*) python3 -c "import json; print(json.dumps({\"data\":{\"groups\":[{\"rules\":[{}] * $P_RULES}]}}))" ;;
    *alerts*) if [ -n "$P_FIRING" ]; then echo "{\"data\":{\"alerts\":[{\"state\":\"firing\",\"labels\":{\"alertname\":\"$P_FIRING\"}}]}}"; else echo "{\"data\":{\"alerts\":[]}}"; fi ;;
  esac'
}
prom up "$rules" ""
check "targets up, all rules, no alert: up" 0 "2 targets up, $rules rules loaded" -- script check-prometheus-alerts.sh
prom down "$rules" ""
check "a target down: down, named" 1 "1 of 2 targets down: cadvisor" -- script check-prometheus-alerts.sh
prom up 0 ""
check "no rules loaded: down" 1 "only 0 of $rules alert rules loaded" -- script check-prometheus-alerts.sh
prom up "$rules" DiskAlmostFull
check "an alert firing: down, named" 1 "1 alert(s) firing: DiskAlmostFull" -- script check-prometheus-alerts.sh

echo "cadvisor"
cad() { # SEEN PRIVILEGED
  export C_SEEN=$1 C_PRIV=$2
  export FAKE_DOCKER='case "$*" in "ps -q") printf "a\nb\nc\nd\ne\n" ;; *Privileged*) echo "$C_PRIV" ;; *Mounts*) echo "/ /sys /var/lib/docker" ;; esac'
  export FAKE_CURL_MORE='case "$*" in
    *healthy*) echo ok ;;
    *up\{job*) echo "{\"data\":{\"result\":[{\"value\":[0,\"1\"]}]}}" ;;
    *container_last_seen*) echo "{\"data\":{\"result\":[{\"value\":[0,\"$C_SEEN\"]}]}}" ;;
    *) echo "{\"data\":{\"result\":[{\"value\":[0,\"42\"]}]}}" ;;
  esac'
}
cad 5 false
check "sees all containers: up" 0 "sees 5 of 5 containers" -- script check-cadvisor-coverage.sh
check "  writes the running count" 0 "decolab_docker_containers_running 5" -- cat "$DECOLAB_TEXTFILE_DIR/cadvisor.prom"
cad 2 false
check "sees too few: down" 1 "sees only 2 of 5" -- script check-cadvisor-coverage.sh
cad 5 true
check "privileged again: down" 1 "runs privileged again" -- script check-cadvisor-coverage.sh

echo "services"
export FAKE_SYSTEMCTL='case "$*" in *--state=failed*) printf "%s" "$FAILED" ;; list-units*) printf "a.service\nb.service\n" ;; *NRestarts*b.service*) echo "${RESTARTS:-0}" ;; *) echo 0 ;; esac'
export FAILED="" RESTARTS=0
: >"$FAKE_CURL_LOG"
check "nothing failed: ok, no message" 0 "OK: no failed service" -- script check-services.sh
same "  ... no message" "$(telegrams)" ""
check "  metrics written" 0 "decolab_systemd_units_failed 0" -- cat "$DECOLAB_TEXTFILE_DIR/services.prom"
export FAILED="x.service loaded failed failed X" RESTARTS=12
check "failed unit and restart loop: reported" 1 "failed=1" -- script check-services.sh
check "  one message" 0 "x.service" -- telegrams
check "  the loop is counted" 0 "decolab_systemd_units_restart_loop 1" -- cat "$DECOLAB_TEXTFILE_DIR/services.prom"
check "same situation again: no second message" 1 "" -- script check-services.sh
same "  ... still one message" "$(telegrams | grep -c 'x.service')" "1"
export FAILED="" RESTARTS=0
check "solved: all-clear message" 0 "" -- script check-services.sh
check "  ... sent" 0 "fine again" -- telegrams
check "still fine: no second all-clear" 0 "" -- script check-services.sh
same "  ... still one" "$(telegrams | grep -c 'fine again')" "1"

echo "pihole"
export PIHOLE_WAIT_MAX_S=2 PIHOLE_STARTUP_MAX_S=1 PIHOLE_STEP_S=1
export FAKE_DOCKER='case "$*" in *example.com*) echo "${NORMAL-198.51.100.7}" ;; *+short*) echo "${ADS-0.0.0.0}" ;; *+comments*) echo ";; ->>HEADER<<- opcode: QUERY, status: ${STATUS:-NOERROR}" ;; "container inspect pihole") exit 0 ;; esac'
check "ads blocked, normal resolves: up" 0 "3/3 ad domains blocked" -- script check-pihole-blocking.sh
export ADS="" STATUS=NXDOMAIN
check "NX blocking mode counts as blocked" 0 "3/3 ad domains blocked" -- script check-pihole-blocking.sh
export STATUS=SERVFAIL
check "empty answer without NXDOMAIN is not blocked" 1 "only 0/3 ad domains blocked" -- script check-pihole-blocking.sh
export ADS=0.0.0.0 NORMAL=0.0.0.0
check "everything 0.0.0.0: down" 1 "normal resolution broken" -- script check-pihole-blocking.sh
export ADS=198.51.100.9 NORMAL=198.51.100.7
printf 'pid %s\npihole\n' "$$" >"$DECOLAB_RUN_DIR/maintenance"
check "paused for maintenance: check skipped, not down" 0 "check skipped this time" -- script check-pihole-blocking.sh
printf 'pid 999999\npihole\n' >"$DECOLAB_RUN_DIR/maintenance"
check "orphaned flag: down, and it says so" 1 "orphaned" -- script check-pihole-blocking.sh
rm -f "$DECOLAB_RUN_DIR/maintenance"
unset ADS NORMAL STATUS

echo "nvme"
nvme() { # media_errors percentage_used [drop-field]
  {
    echo "critical_warning                        : 0"
    echo "temperature                             : 38 °C (311 K)"
    echo "available_spare                         : 100%"
    echo "available_spare_threshold               : 10%"
    echo "percentage_used                         : $2%"
    echo "media_errors                            : $1"
    echo "num_err_log_entries                     : 0"
    echo "power_on_hours                          : 1234"
  } | grep -v "^${3:-none}" >"$t_tmp/smart.txt"
}
export NVME_SOURCE=$t_tmp/smart.txt
nvme 0 3
check "healthy disk: up" 0 "healthy: wear 3 %, spare 100 %" -- env DECOLAB_CONF="$t_tmp/nvme.conf" bash -c 'sed "s/^HW_NVME=.*/HW_NVME=yes/" "$1" > "$2"; "$3"' _ "$DECOLAB_CONF" "$t_tmp/nvme.conf" "$t_root/scripts/check-nvme-health.sh"
nvme 2 3
check "media errors: down" 1 "2 media errors" -- env DECOLAB_CONF="$t_tmp/nvme.conf" "$t_root/scripts/check-nvme-health.sh"
nvme 0 85
check "worn out: down" 1 "wear 85 %" -- env DECOLAB_CONF="$t_tmp/nvme.conf" "$t_root/scripts/check-nvme-health.sh"
nvme 0 3 media_errors
check "a field missing is an error, not health" 1 "media_errors missing" -- env DECOLAB_CONF="$t_tmp/nvme.conf" "$t_root/scripts/check-nvme-health.sh"
unset NVME_SOURCE

echo "tailscale keys"
in_days() { python3 -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int(sys.argv[1]), hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
FAKE_TAILSCALE_JSON=$(printf '{"Self":{"HostName":"host"},"Peer":{"a":{"HostName":"phone","KeyExpiry":"%s"}}}' "$(in_days 100)")
export FAKE_TAILSCALE_JSON
: >"$FAKE_CURL_LOG"
check "all keys have time: ok" 0 "next key expiry in 100 days" -- script check-tailscale-keys.sh
FAKE_TAILSCALE_JSON=$(printf '{"Self":{"HostName":"host","KeyExpiry":"%s"},"Peer":{}}' "$(in_days 5)")
check "a key expires: warning" 1 "expire within 14 days: host(5d)" -- script check-tailscale-keys.sh
check "  message names the device" 0 "host(5d)" -- telegrams
check "  metric counts it" 0 "decolab_tailscale_keys_expiring 1" -- cat "$DECOLAB_TEXTFILE_DIR/tailscale.prom"
export FAKE_TAILSCALE_JSON=""
check "tailscale gives nothing: error, not silence" 1 "empty or broken" -- script check-tailscale-keys.sh

echo "portainer"
mkdir -p "$t_tmp/data/portainer"
printf 'xx{"Id":1,"Name":"local","Type":1,"URL":"%s","x":1}yy' "${PURL:-tcp://socket-proxy:2375}" >"$t_tmp/data/portainer/portainer.db"
export FAKE_CURL_MORE='case "$*" in *9000/api/status*) echo "{}" ;; esac'
export FAKE_DOCKER='case "$*" in *wget*) echo "{\"Version\":\"29.0.0\"}" ;; *Networks*) echo "decolab_proxy_net decolab_socket_net " ;; esac'
check "API and URL right: up" 0 "socket-proxy (v29.0.0)" -- script check-portainer-docker.sh
printf 'xx{"Id":1,"Name":"local","Type":1,"URL":"unix:///var/run/docker.sock","x":1}yy' >"$t_tmp/data/portainer/portainer.db"
check "URL points to a socket: down" 1 "unix socket" -- script check-portainer-docker.sh
export FAKE_DOCKER='case "$*" in *wget*) exit 1 ;; esac'
check "proxy gives no API answer: down" 1 "no Docker API answer" -- script check-portainer-docker.sh

echo "monitor"
export FAKE_DOCKER='case "$*" in *"{{.State.Status}}"*) c=${!#}; case " $DOWN " in *" $c:"*) s=" $DOWN "; s=${s#*" $c:"}; echo "${s%% *}" ;; *) echo running ;; esac ;; esac'
export DOWN="" MONITOR_REMIND_S=7200
: >"$FAKE_CURL_LOG"
check "everything runs: ok" 0 "containers running" -- script monitor.sh
export DOWN="pihole:exited"
printf 'pid %s\npihole\n' "$$" >"$DECOLAB_RUN_DIR/maintenance"
check "paused for maintenance: ok, but logged" 0 "maintenance: pihole paused" -- script monitor.sh
same "  ... no message" "$(telegrams)" ""
rm -f "$DECOLAB_RUN_DIR/maintenance"
check "stopped without maintenance: alert" 1 "pihole: exited" -- script monitor.sh
check "  ... message" 0 "pihole: exited" -- telegrams
check "same problem again: no second message" 1 "" -- script monitor.sh
same "  ... still one" "$(telegrams | grep -c 'pihole: exited')" "1"
printf 'pid %s\nvaultwarden\n' "$$" >"$DECOLAB_RUN_DIR/maintenance"
export DOWN="vaultwarden:missing"
check "missing is never maintenance" 1 "vaultwarden: missing" -- script monitor.sh
rm -f "$DECOLAB_RUN_DIR/maintenance"
export DOWN=""
check "solved: all-clear" 0 "" -- script monitor.sh
check "  ... sent" 0 "All problems are solved" -- telegrams

echo "watchdog"
: >"$FAKE_DOCKER_LOG"
export FAKE_CURL_MORE='case "$*" in *8053*) echo 000 ;; *) echo 200 ;; esac' FAKE_DOCKER='exit 0'
check "a dead UI gets its container restarted" 0 "DOWN: pihole" -- script watchdog.sh
check "  ... restart pihole" 0 "restart pihole" -- cat "$FAKE_DOCKER_LOG"
check "  ... reported" 0 "pihole DOWN" -- telegrams
: >"$FAKE_DOCKER_LOG"
printf 'pid %s\npihole\n' "$$" >"$DECOLAB_RUN_DIR/maintenance"
check "a container in maintenance is not touched" 0 "maintenance: pihole is being backed up" -- script watchdog.sh
check "  ... no restart" 1 "" -- grep 'restart pihole' "$FAKE_DOCKER_LOG"
rm -f "$DECOLAB_RUN_DIR/maintenance"
export FAKE_CURL_MORE='echo 200' FAKE_DOCKER='case "$*" in ps*created*) echo immich_server ;; esac'
: >"$FAKE_DOCKER_LOG"
check "a created container is started" 0 "CREATED: immich_server" -- script watchdog.sh
check "  ... docker start" 0 "start immich_server" -- cat "$FAKE_DOCKER_LOG"

t_finish
