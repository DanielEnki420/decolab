#!/usr/bin/env bash
# Contract tests for the service configurations: each one is checked by the
# service's own tool, from the exact image the compose file pins.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! docker info >/dev/null 2>&1; then
  t_fail "docker daemon reachable" "these tests run the services' own check tools in containers"
  t_finish
  exit 1
fi

image() { grep -m1 -oE "image: $1[^ ]*" "$t_root/compose/core.yml" | cut -d' ' -f2; }
unbound_img=$(image madnuttah/unbound)
prom_img=$(image prom/prometheus)
perses_img=$(image persesdev/perses)

echo "unbound"
# unbound-checkconf insists on a trust anchor file; the entrypoint creates the
# real one at start. This is the published root KSK DS record.
mkdir -p "$t_tmp/ubvar"
echo '. IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D' > "$t_tmp/ubvar/root.key"
ubcheck() {
  docker run --rm --network none --entrypoint /usr/local/unbound/unbound.d/sbin/unbound-checkconf \
    -v "$1:/usr/local/unbound/unbound.conf:ro" -v "$t_tmp/ubvar/root.key:/usr/local/unbound/iana.d/root.key:ro" \
    "$unbound_img" /usr/local/unbound/unbound.conf
}
check "unbound.conf passes unbound-checkconf" 0 "no errors" -- ubcheck "$t_root/config/unbound/unbound.conf"
sed 's/^    do-ip6: no$/    do-ip6: maybe/' "$t_root/config/unbound/unbound.conf" > "$t_tmp/bad-unbound.conf"
check "  ... and rejects a broken copy" 1 "expected yes or no" -- ubcheck "$t_tmp/bad-unbound.conf"
check "unbound answers only dns_net and itself" 0 "" -- bash -c '
  [ "$(grep -c "^    access-control: .* allow$" "$1")" -eq 2 ] &&
  grep -q "^    access-control: 172.20.0.0/24 allow$" "$1"' _ "$t_root/config/unbound/unbound.conf"

echo "prometheus"
promtool() {
  docker run --rm --network none --entrypoint /bin/promtool \
    -v "$t_root/config/prometheus:/etc/prometheus:ro" "$prom_img" "$@"
}
check "prometheus.yml passes promtool" 0 "SUCCESS" -- promtool check config /etc/prometheus/prometheus.yml
check "rules.yml passes promtool" 0 "SUCCESS: 13 rules found" -- promtool check rules /etc/prometheus/rules.yml

echo "perses"
plint() {
  docker run --rm --network none --entrypoint /bin/percli -v "$1:/p:ro" "$perses_img" lint -d /p
}
check "dashboards pass percli lint" 0 "" -- plint "$t_root/config/perses/provisioning"
mkdir -p "$t_tmp/plint" && cp "$t_root/config/perses/provisioning/"* "$t_tmp/plint/"
python3 -I -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); del d["spec"]["panels"]["statCpuTemp"]; json.dump(d,open(p,"w"))' \
  "$t_tmp/plint/dashboard-system.json"
check "  ... and rejects a layout pointing to a missing panel" 1 "" -- plint "$t_tmp/plint"

# percli lint does not notice an unknown panel type or a missing project:
# Perses would silently not load such a dashboard. So start Perses with the
# real configuration and ask it which dashboards it has.
name=decolab-test-perses-$$
# Plugins are unpacked at start: they need a writable place (anonymous volume).
docker run -d --name "$name" -p 127.0.0.1::8080 --read-only -v /etc/perses/plugins \
  --tmpfs /perses/db:uid=65532,gid=65532 --tmpfs /tmp:uid=65532,gid=65532 \
  -v "$t_root/config/perses/config.yaml:/etc/perses/config.yaml:ro" \
  -v "$t_root/config/perses/provisioning:/perses/provisioning:ro" \
  "$perses_img" --config=/etc/perses/config.yaml --log.level=warning >/dev/null
port=$(docker port "$name" 8080/tcp | head -1 | sed 's/.*://')
dashboards=""
for _ in $(seq 1 60); do
  answer=$(curl -s -m 2 "http://127.0.0.1:$port/api/v1/projects/decolab/dashboards" 2>/dev/null) || answer=""
  dashboards=$(printf '%s' "$answer" |
    python3 -I -c 'import json,sys
try: print(" ".join(sorted(d["metadata"]["name"] for d in json.load(sys.stdin))))
except Exception: pass')
  [ "$dashboards" = "containers internet services system ups" ] && break
  sleep 1
done
same "Perses loads all five dashboards" "$dashboards" "containers internet services system ups"
answer=$(curl -s -m 5 "http://127.0.0.1:$port/api/v1/plugins") || answer=""
plugins=$(printf '%s' "$answer" | python3 -I -c 'import json,sys
print(" ".join(sorted({m["metadata"]["name"] for m in json.load(sys.stdin)})))' 2>/dev/null)
same "only the six enabled plugins are served" "$plugins" "BarChart Markdown Prometheus StatChart Table TimeSeriesChart"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
  -d '{"kind":"GlobalDatasource","metadata":{"name":"x"},"spec":{"plugin":{"kind":"PrometheusDatasource","spec":{}}}}' \
  "http://127.0.0.1:$port/api/v1/globaldatasources")
same "read-only: creating a data source is refused" "$code" "405"
docker rm -f -v "$name" >/dev/null 2>&1

echo "metric names"
used=$(cat "$t_root/config/prometheus/rules.yml" "$t_root"/config/perses/provisioning/*.json |
  grep -oE 'decolab_[a-z0-9_]+' | sort -u)
missing=""
for m in $used; do grep -q "\`$m\`" "$t_root/docs/metrics.md" || missing="$missing $m"; done
same "every decolab_ metric in rules and dashboards is documented" "${missing# }" ""
check "no German left in the dashboards" 1 "" -- grep -lE '[äöüÄÖÜß]|Verlauf|Kennzahlen' "$t_root"/config/perses/provisioning/*.json

t_finish
