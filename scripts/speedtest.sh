#!/usr/bin/env bash
# speedtest.sh [--manual] - internet speed for Prometheus and the panel,
# every 6 hours (cron.d-decolab). The measurement itself is lib/speedtest.py;
# its header explains the choices.
#
# Off while SPEEDTEST=no: then it also deletes speedtest.prom, so no stale
# values stay in the dashboards (and the "measurement missing" rule, which
# needs the metric, stays quiet).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init

if ! is_yes SPEEDTEST; then
  rm -f "$DECOLAB_TEXTFILE_DIR/speedtest.prom"
  log "speed test is off (SPEEDTEST=no)"
  exit 0
fi
export DECOLAB_TEXTFILE_DIR DECOLAB_STATE_DIR DECOLAB_RUN_DIR
export SPEEDTEST_SERVERS=${SPEEDTEST_SERVERS:-$decolab_root/config/speedtest-servers.json}
exec python3 -I "$decolab_root/lib/speedtest.py" "$@"
