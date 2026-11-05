#!/usr/bin/env bash
# check-perses.sh - sign of life of Perses for Uptime Kuma.
#
# From the host, not as an HTTP monitor in Kuma: Perses listens on 127.0.0.1
# only and Kuma cannot reach it. Putting Kuma into perses_net would undo the
# separation: Kuma holds the notification and push tokens and is the most
# valuable target on the host. Side effect: this tests exactly the binding
# tailscale serve uses.
#
# Uptime Kuma push monitor: PERSES (every 2 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=PERSES
url=${PERSES_URL:-http://127.0.0.1:8800}

health=$(curl -sS -m 10 "$url/api/v1/health" 2>&1) || check_fail "Perses does not answer on $url"
python3 -I -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1]).get("database") is True else 1)' "$health" \
  2>/dev/null || check_fail "Perses reports no database: ${health:0:120}"

# A Perses without dashboards is "healthy" and useless, for example when a
# provisioning file no longer loads. Expected: every file in the repository.
want=$(find "$decolab_root/config/perses/provisioning" -name 'dashboard-*.json' | wc -l | tr -d ' ')
answer=$(curl -sS -m 10 "$url/api/v1/projects/decolab/dashboards" 2>/dev/null) || answer=""
have=$(printf '%s' "$answer" |
  python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
[ "${have:-0}" = "$want" ] || check_fail "${have:-0} of $want dashboards loaded"
check_ok "$have dashboards loaded"
