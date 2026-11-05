#!/usr/bin/env bash
# check-portainer-docker.sh - can Portainer really reach Docker, not just
# show its web page?
#
# Portainer's environment URL can point to a path that does not exist in the
# container (for example the old unix socket after moving to the socket
# proxy). Its UI then shows frozen numbers for months while port 9000
# answers and every port check stays green. So this checks the causes that
# really break:
#   1. Portainer answers
#   2. the socket proxy delivers a real Docker API answer, and Portainer and
#      the proxy share the socket network (Portainer's only way to Docker)
#   3. the stored environment URL points to the proxy
# Deliberately NOT the status field in Portainer's database: it keeps old
# pages, a single earlier outage would stay there and alarm forever.
#
# Uptime Kuma push monitor: PORTAINER (every 15 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=PORTAINER
db=${PORTAINER_DB:-$DATA_DIR/portainer/portainer.db}

curl -sS -m 10 http://127.0.0.1:9000/api/status >/dev/null 2>&1 || check_fail "Portainer does not answer"

version=$(timeout 30 docker exec socket-proxy wget -q -O- http://127.0.0.1:2375/version 2>/dev/null |
  python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("Version", ""))' 2>/dev/null)
[ -n "$version" ] || check_fail "socket proxy gives no Docker API answer: Portainer cannot reach Docker"
nets() { docker inspect "$1" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null; }
case " $(nets portainer) " in *" decolab_socket_net "*) ;; *) check_fail "Portainer is not in decolab_socket_net" ;; esac
case " $(nets socket-proxy) " in *" decolab_socket_net "*) ;; *) check_fail "socket-proxy is not in decolab_socket_net" ;; esac

[ -r "$db" ] || check_fail "Portainer database $db not readable"
urls=$(python3 -I -c '
import re, sys
data = open(sys.argv[1], "rb").read()
for m in sorted(set(re.findall(rb"\"Type\":1[^}]*?\"URL\":\"([^\"]*)\"", data))):
    print(m.decode(errors="replace"))' "$db" 2>/dev/null)
[ -n "$urls" ] || check_fail "Portainer has no environment yet: add one as INSTALL.md (step 6) says"
case $urls in *unix://*) check_fail "environment points to a unix socket that does not exist in the container" ;; esac
case $urls in *socket-proxy*) ;; *) check_fail "environment URL does not point to socket-proxy: $(printf '%s' "$urls" | head -1)" ;; esac
check_ok "Docker API reachable through socket-proxy (v$version), environment URL correct"
