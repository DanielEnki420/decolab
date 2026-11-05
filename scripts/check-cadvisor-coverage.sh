#!/usr/bin/env bash
# check-cadvisor-coverage.sh - does cAdvisor really watch the containers?
#
# cAdvisor runs without privileges behind a read-only Docker API proxy. That
# brings two silent failures that a privileged cAdvisor cannot have:
#   1. Boot order: cAdvisor registers its Docker factory once at start and
#      never retries. If the proxy is not up yet, cAdvisor keeps running but
#      reports almost no containers. depends_on does not help: after a
#      reboot Docker starts containers in any order.
#   2. A missing capability (DAC_READ_SEARCH) removes only the
#      container_fs_* metrics. No crash, no error, just empty panels.
# In both cases the container runs, its healthcheck is green and up == 1.
# So this measures the effect, not reachability. It also writes the number
# of running containers for the rule CadvisorSeesTooFew.
#
# Uptime Kuma push monitor: CADVISOR (every 15 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=CADVISOR
# A container that just started may not be seen yet (housekeeping: 30 s).
tolerance=${CADVISOR_TOLERANCE:-2}

running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
[ "$running" -gt 0 ] 2>/dev/null || check_fail "docker ps lists no containers: check the Docker daemon"
textfile_write cadvisor <<METRICS || true
# HELP decolab_docker_containers_running Containers running according to docker ps.
# TYPE decolab_docker_containers_running gauge
decolab_docker_containers_running $running
METRICS

# Prometheus first: otherwise every following check would fail for the
# wrong reason and blame cAdvisor.
curl -sS -m 10 "${PROM_URL:-http://127.0.0.1:9090}/-/healthy" >/dev/null 2>&1 ||
  check_fail "Prometheus not reachable: cannot check cAdvisor"
up=$(prom_query 'up{job="cadvisor"}')
[ "$up" = 1 ] || check_fail "Prometheus cannot reach cAdvisor (up=${up:-empty})"

seen=$(prom_query 'count(count by (name) (container_last_seen{name!=""}))')
seen=${seen%%.*}
[ -n "$seen" ] || check_fail "no container_last_seen metric: Docker factory not registered (proxy not reachable at start?)"
[ "$seen" -ge $((running - tolerance)) ] ||
  check_fail "cAdvisor sees only $seen of $running containers. Fix: docker restart cadvisor"

fs=$(prom_query 'count(container_fs_usage_bytes)')
[ "${fs%%.*}" -gt 0 ] 2>/dev/null || check_fail "container_fs_usage_bytes missing: check cap_add DAC_READ_SEARCH"
net=$(prom_query 'count(container_network_receive_bytes_total)')
[ "${net%%.*}" -gt 0 ] 2>/dev/null || check_fail "container_network_receive_bytes_total missing"

# Regression lock: "just make it privileged, then it works" must show.
[ "$(docker inspect cadvisor -f '{{.HostConfig.Privileged}}' 2>/dev/null)" = false ] ||
  check_fail "cAdvisor runs privileged again (all capabilities)"
docker inspect cadvisor -f '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null | tr ' ' '\n' |
  grep -qE 'docker\.sock$|^/var/run$|^/run$' && check_fail "cAdvisor mounts the Docker socket again: that is root on the host"
check_ok "cAdvisor sees $seen of $running containers, fs=${fs%%.*} net=${net%%.*}, unprivileged"
