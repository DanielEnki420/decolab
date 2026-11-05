#!/usr/bin/env bash
# check-prometheus-alerts.sh - does Prometheus do its job? It checks:
#   1. are all scrape targets up?
#   2. are the alert rules loaded?  <- without this, 1 and 3 are worthless:
#      Prometheus silently runs on with zero rules if the rule file is
#      missing or unreadable, and is "healthy" all the while
#   3. is an alert firing?
#
# There is deliberately no Alertmanager, one more service that could fail
# silently. This script is the alert path: it pushes to Uptime Kuma, so if it
# stops, the monitor turns red by itself.
#
# Uptime Kuma push monitor: PROMETHEUS (every 15 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=PROMETHEUS
prom=${PROM_URL:-http://127.0.0.1:9090}
get() { curl -sS -m 15 "$prom$1" 2>/dev/null; }

curl -sS -m 10 "$prom/-/healthy" >/dev/null 2>&1 || check_fail "Prometheus does not answer"

# Python reads the JSON from a pipe and the program from -c. (A heredoc
# program plus a here-string for the data cannot work: the last redirection
# wins and Python silently gets the JSON as its program.)
read -r total down jobs <<<"$(get '/api/v1/targets?state=any' | python3 -I -c '
import json, sys
try:
    t = json.load(sys.stdin)["data"]["activeTargets"]
except Exception:
    t = []
bad = [x for x in t if x["health"] != "up"]
print(len(t), len(bad), ",".join(sorted({x["labels"].get("job", "?") for x in bad})) or "-")')"
[ "${total:-0}" -gt 0 ] || check_fail "Prometheus has no scrape targets (or the list is unreadable)"
[ "${down:-1}" = 0 ] || check_fail "$down of $total targets down: $jobs"

# Every rule in the repository's file must be loaded. A rule that went
# missing is a regression and must show, not slip through.
want=$(grep -cE '^[[:space:]]+- alert:' "$decolab_root/config/prometheus/rules.yml")
rules=$(get /api/v1/rules | python3 -I -c 'import json, sys
try:
    print(sum(len(g["rules"]) for g in json.load(sys.stdin)["data"]["groups"]))
except Exception:
    print(0)')
[ "${rules:-0}" -ge "$want" ] || check_fail "only ${rules:-0} of $want alert rules loaded: rules.yml missing or unreadable?"

read -r firing names <<<"$(get /api/v1/alerts | python3 -I -c 'import json, sys
try:
    a = [x for x in json.load(sys.stdin)["data"]["alerts"] if x.get("state") == "firing"]
except Exception:
    a = []
print(len(a), ",".join(sorted({x["labels"].get("alertname", "?") for x in a})) or "-")')"
[ "${firing:-0}" = 0 ] || check_fail "$firing alert(s) firing: $names"
check_ok "$total targets up, $rules rules loaded, no alert firing"
