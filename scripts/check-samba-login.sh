#!/usr/bin/env bash
# check-samba-login.sh - tests a REAL Samba login, not whether the container
# runs. A container healthcheck stays "healthy" while every login fails (for
# example after a broken password setting): it never logs in.
#
# Uptime Kuma push monitor: SAMBA (every 10 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=SAMBA

pwfile=$SECRETS_DIR/samba_password
[ -r "$pwfile" ] || check_fail "password file $pwfile not readable"

# The password travels on stdin into the container and reaches smbclient as
# PASSWD in its environment: never as an argument, which every user could
# read in the process list of the host.
# shellcheck disable=SC2016  # expanded inside the container
out=$(timeout 30 docker exec -i samba sh -c 'IFS= read -r PASSWD; export PASSWD; exec smbclient -L localhost -U "$1"' \
  _ "$DECOLAB_USER" <"$pwfile" 2>&1)
rc=$?
# smbclient also returns 0 on partial success: the share must be listed.
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -E '^[[:space:]]+NAS[[:space:]]+Disk' >/dev/null; then
  check_ok "login works, share NAS visible"
fi
reason=$(printf '%s' "$out" | grep -oE 'NT_STATUS_[A-Z_]+' | head -1)
check_fail "login failed: ${reason:-exit $rc}"
