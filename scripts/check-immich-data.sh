#!/usr/bin/env bash
# check-immich-data.sh - checks the PHOTOS, not whether Immich answers.
#
# /api/server/ping only says "the process runs". The point of Immich is not
# to lose photos, so:
#   1. the database answers a real query
#   2. the number of assets has not dropped by more than 5 % since the last
#      run (small drops are normal: people delete photos)
#   3. the upload directory is writable from inside the container, the way
#      Immich itself writes (host permissions say nothing about that)
#
# Uptime Kuma push monitor: IMMICH (every 30 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
is_yes MODULE_IMMICH || exit 0
CHECK_MONITOR=IMMICH
state=$DECOLAB_STATE_DIR/immich-asset-count

read_secrets "$SECRETS_DIR/immich.env" DB_USERNAME DB_DATABASE_NAME || check_fail "cannot read immich.env"
count=$(timeout 30 docker exec immich_postgres psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -t -A \
  -c 'SELECT count(*) FROM asset;' 2>/dev/null)
[[ $count =~ ^[0-9]+$ ]] || check_fail "database does not answer (got '${count:-nothing}')"

prev=$(cat "$state" 2>/dev/null || true)
if [[ $prev =~ ^[0-9]+$ ]] && [ "$prev" -gt 0 ] && [ "$count" -lt $((prev * 95 / 100)) ]; then
  # The state file keeps the old number, so the alarm stays until someone
  # looks (or deletes the file after a deliberate clean-up).
  check_fail "assets dropped from $prev to $count (more than 5 %): check for data loss"
fi
echo "$count" >"$state" || check_fail "cannot write $state"

# The upload path inside the container is /data (see stacks/immich).
timeout 30 docker exec immich_server sh -c 'touch /data/upload/.decolab-writetest && rm -f /data/upload/.decolab-writetest' \
  >/dev/null 2>&1 || check_fail "Immich cannot write its upload directory: new photos would not arrive"
check_ok "$count assets, database answers, upload directory writable"
