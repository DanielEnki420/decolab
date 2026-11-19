#!/usr/bin/env bash
# Contract tests for the VM probe's container check (tools/vm-probe/guest.sh).
# The probe itself runs in a throwaway VM; its "containers" phase only asks
# docker, so it runs here against the fake docker with fixed "docker ps" rows.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export PATH="$t_root/tests/fakes:$PATH"
guest=$t_root/tools/vm-probe/guest.sh
rows=$t_tmp/ps
export FAKE_DOCKER="cat '$rows'"

# ps_rows ROW... - what "docker ps -a" prints, one "NAME STATUS" per argument
ps_rows() { printf '%s\n' "$@" >"$rows"; }

ps_rows "pihole Up 2 days (healthy)" "samba Up About an hour" "kuma Up 5 minutes (healthy)"
check "all up and healthy: ok" 0 "no container down or unhealthy" -- bash "$guest" containers

ps_rows "pihole Up 2 days (healthy)" "vaultwarden Up 3 hours (unhealthy)"
check "an unhealthy container is named" 1 "vaultwarden Up 3 hours (unhealthy)" -- bash "$guest" containers
refute "  ... the healthy one is not" "pihole"

ps_rows "immich Up 8 seconds (health: starting)"
check "a health check still starting is named" 1 "immich Up 8 seconds (health: starting)" -- bash "$guest" containers

ps_rows "kuma Exited (1) 2 minutes ago"
check "an exited container is named" 1 "kuma Exited (1)" -- bash "$guest" containers

ps_rows "perses Restarting (1) 4 seconds ago"
check "a restarting container is named" 1 "perses Restarting" -- bash "$guest" containers

ps_rows "samba Created"
check "a created, never started container is named" 1 "samba Created" -- bash "$guest" containers

ps_rows "samba Up 2 hours (Paused)"
check "a paused container is named" 1 "samba Up 2 hours (Paused)" -- bash "$guest" containers

FAKE_DOCKER='exit 1' check "docker fails: reported, not taken as none" 1 "docker ps failed" -- bash "$guest" containers

t_finish
