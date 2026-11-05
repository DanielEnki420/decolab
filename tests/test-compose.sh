#!/usr/bin/env bash
# Contract tests for the compose files: they render with the example
# configuration and every variable they use is defined somewhere.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! docker compose version >/dev/null 2>&1; then
  t_fail "docker compose available" "install the docker CLI with the compose plugin"
  t_finish
  exit 1
fi

# What install.sh will generate, with dummy values
secrets=$t_tmp/secrets
mkdir -p "$secrets"
printf 'DECOLAB_UID=1000\nDECOLAB_GID=1000\nDOCKER_GID=990\nVAULTWARDEN_DOMAIN=pi.tail1234.ts.net\n' > "$secrets/runtime.env"
printf 'PIHOLE_PASSWORD=dummy\n' > "$secrets/compose-secrets.env"
printf 'DB_PASSWORD=dummy\nDB_USERNAME=immich\nDB_DATABASE_NAME=immich\n' > "$secrets/immich.env"
printf 'ADMIN_TOKEN=dummy\n' > "$secrets/vaultwarden.env"

render() { # COMPOSE-FILE [EXTRA-ENV-FILE]
  local extra=()
  [ -n "${2:-}" ] && extra=(--env-file "$2")
  SECRETS_DIR=$secrets docker compose --env-file "$t_root/decolab.conf.example" \
    --env-file "$secrets/runtime.env" --env-file "$secrets/compose-secrets.env" \
    "${extra[@]+"${extra[@]}"}" -f "$t_root/$1" config
}

for f in compose/core.yml stacks/immich/compose.yml stacks/vaultwarden/compose.yml \
  stacks/uptime-kuma/compose.yml stacks/watchtower/compose.yml; do
  envfile=""
  [ "$f" = stacks/immich/compose.yml ] && envfile=$secrets/immich.env
  check "$f renders" 0 "services:" -- render "$f" "$envfile"
  refute "$f uses no undefined variable" "variable is not set"
done

check "core: Pi-hole forwards only to Unbound" 0 'FTLCONF_dns_upstreams: 172.20.0.2#5335' -- render compose/core.yml
check "core: web UIs on WEB_UI_ADDRESS" 0 'host_ip: 127.0.0.1' -- render compose/core.yml
refute "core: no v5 Pi-hole variables" "WEBPASSWORD"
check "core: Unbound cannot change its config in the checkout" 0 "" -- bash -c '
  SECRETS_DIR=$2 docker compose --env-file "$1/decolab.conf.example" --env-file "$2/runtime.env" \
    --env-file "$2/compose-secrets.env" -f "$1/compose/core.yml" config --format json |
  python3 -I -c "import json,sys; v=[m for m in json.load(sys.stdin)[\"services\"][\"unbound\"][\"volumes\"] if m[\"target\"] == \"/usr/local/unbound/unbound.conf\"]; sys.exit(not (len(v) == 1 and v[0].get(\"read_only\")))"' _ "$t_root" "$secrets"
check "core: Pi-hole answers the LAN behind Docker's bridge" 0 "FTLCONF_dns_listeningMode: ALL" -- render compose/core.yml
# cAdvisor asks the proxy once, at start: it must wait until the proxy answers.
check "core: cAdvisor waits for a healthy read-only proxy" 0 "" -- bash -c '
  SECRETS_DIR=$2 docker compose --env-file "$1/decolab.conf.example" --env-file "$2/runtime.env" \
    --env-file "$2/compose-secrets.env" -f "$1/compose/core.yml" config --format json |
  python3 -I -c "import json,sys; s=json.load(sys.stdin)[\"services\"]; sys.exit(not (s[\"cadvisor\"][\"depends_on\"][\"socket-proxy-ro\"][\"condition\"] == \"service_healthy\" and \"healthcheck\" in s[\"socket-proxy-ro\"]))"' _ "$t_root" "$secrets"
# cAdvisor reads every file in its mounts (DAC_READ_SEARCH): not / and not
# containers/*/config.v2.json with their environment.
check "core: cAdvisor sees no host root and no container config" 0 "" -- bash -c '
  SECRETS_DIR=$2 docker compose --env-file "$1/decolab.conf.example" --env-file "$2/runtime.env" \
    --env-file "$2/compose-secrets.env" -f "$1/compose/core.yml" config --format json |
  python3 -I -c "import json,sys; v=[m[\"source\"] for m in json.load(sys.stdin)[\"services\"][\"cadvisor\"][\"volumes\"]]; sys.exit(not v or \"/\" in v or \"/var/lib/docker\" in v or any(x.startswith(\"/var/lib/docker/containers\") for x in v))"' _ "$t_root" "$secrets"
# install.sh creates DATA_DIR/prometheus for DECOLAB_USER; the image alone
# runs as nobody and could not write it (seen on a fresh Debian 13).
check "core: Prometheus runs as DECOLAB_USER" 0 "" -- bash -c '
  render() { SECRETS_DIR=$2 docker compose --env-file "$1/decolab.conf.example" --env-file "$2/runtime.env" \
    --env-file "$2/compose-secrets.env" -f "$1/compose/core.yml" config --format json; }
  render "$1" "$2" | python3 -I -c "import json,sys; u=json.load(sys.stdin)[\"services\"][\"prometheus\"].get(\"user\"); sys.exit(u != \"1000:1000\")"' _ "$t_root" "$secrets"
check "every service drops all capabilities" 0 "" -- bash -c '
  for f in "$1"/compose/core.yml "$1"/stacks/*/compose.yml; do
    n_services=$(grep -cE "^  [a-z0-9_-]+:$" <(sed -n "/^services:/,/^[a-z]/p" "$f"))
    n_drop=$(grep -cE "cap_drop: \[ALL\]" "$f")
    [ "$n_services" -eq "$n_drop" ] || { echo "$f: $n_services services, $n_drop cap_drop"; exit 1; }
  done' _ "$t_root"

# Decolab's promise: an image changes only with a Decolab release, through
# scripts/update.sh. Watchtower would change pinned images behind the
# compose files' back, and the next update.sh would quietly revert them.
check "every image is pinned by digest" 0 "" -- bash -c '
  bad=$(grep -hE "^[[:space:]]+image:" "$1"/compose/core.yml "$1"/stacks/*/compose.yml | grep -vE "@sha256:[0-9a-f]{64}")
  [ -z "$bad" ] || { echo "not pinned: $bad"; exit 1; }' _ "$t_root"
check "no service opts in to Watchtower" 0 "" -- bash -c '
  ! grep -n "watchtower.enable=true\|watchtower.enable: *\"\?true" "$1"/compose/core.yml "$1"/stacks/*/compose.yml | grep -v "^[^:]*:[0-9]*:#"' _ "$t_root"

echo "bin/decolab-compose"
# docker is the fake here: only the call itself is the contract.
sed "s#^SECRETS_DIR=.*#SECRETS_DIR=$secrets#" "$t_root/decolab.conf.example" >"$t_tmp/dc.conf"
dclog=$t_tmp/dc-docker.log
dc() { : >"$dclog"; env PATH="$t_root/tests/fakes:$PATH" FAKE_DOCKER_LOG="$dclog" DECOLAB_CONF="$t_tmp/dc.conf" \
  DECOLAB_STATE_DIR="$t_tmp/dc-state" "$t_root/bin/decolab-compose" "$@"; }
check "starts one service of a stack" 0 "" -- dc immich up -d database
check "  ... with all four env files, immich.env last" 0 "" -- grep -F -- \
  "--env-file $t_tmp/dc.conf --env-file $secrets/runtime.env --env-file $secrets/compose-secrets.env --env-file $secrets/immich.env -f $t_root/stacks/immich/compose.yml up -d database" "$dclog"
dc core ps >/dev/null 2>&1
check "core uses compose/core.yml, without immich.env" 0 "" -- bash -c 'grep -q -- "-f $1/compose/core.yml ps" "$2" && ! grep -q immich.env "$2"' _ "$t_root" "$dclog"
check "a stack without a command is refused" 2 "STACK:" -- dc core
check "an unknown stack is refused" 2 "STACK:" -- dc nope up -d
same "  ... before docker is called" "$(wc -c <"$dclog" | tr -d ' ')" "0"
sed 's/^PANEL_PORT=.*/PANEL_PORT=x/' "$t_tmp/dc.conf" >"$t_tmp/dc-bad.conf"
check "a broken configuration stops it" 1 "is invalid" -- env PATH="$t_root/tests/fakes:$PATH" FAKE_DOCKER_LOG="$dclog" \
  DECOLAB_CONF="$t_tmp/dc-bad.conf" "$t_root/bin/decolab-compose" core ps
same "  ... before docker is called" "$(wc -c <"$dclog" | tr -d ' ')" "0"

t_finish
