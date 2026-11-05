#!/usr/bin/env bash
# check-nvme-health.sh - reads the SMART values of the NVMe disk.
#
# Everything lives on this one disk. SSDs announce their death:
# percentage_used and media_errors rise before anything fails. That warning
# is only worth something if someone looks.
#
# Needs a sudoers rule for exactly "nvme smart-log DEVICE" (install.sh).
# NVME_SOURCE (a file with smart-log output) is the test hook: failure cases
# cannot be produced on real hardware without damaging it.
#
# Uptime Kuma push monitor: NVME (every 6 hours).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
device=${NVME_DEVICE:-/dev/nvme0n1}
hw_wanted HW_NVME test -b "$device" || exit 0
CHECK_MONITOR=NVME

if [ -n "${NVME_SOURCE:-}" ]; then
  smart=$(cat "$NVME_SOURCE" 2>/dev/null) || check_fail "test source $NVME_SOURCE not readable"
else
  smart=$(timeout 20 sudo -n nvme smart-log "$device" 2>/dev/null) ||
    check_fail "SMART data not readable (nvme-cli missing, sudoers rule gone, or the disk is dead)"
fi
[ -n "$smart" ] || check_fail "SMART output empty"

field() { printf '%s\n' "$smart" | grep -m1 "^$1" | grep -oE '[0-9]+' | head -1; }
warning=$(field critical_warning)
media=$(field media_errors)
used=$(field percentage_used)
spare=$(field 'available_spare[[:space:]]')
spare_min=$(field available_spare_threshold)
log_entries=$(field num_err_log_entries)
temp=$(field temperature)
hours=$(field power_on_hours)

# A missing value is an error, never "all good".
for pair in "critical_warning:$warning" "media_errors:$media" "percentage_used:$used" "available_spare:$spare"; do
  [[ ${pair#*:} =~ ^[0-9]+$ ]] || check_fail "SMART field ${pair%%:*} missing or unreadable: output format changed?"
done

problems=""
[ "$warning" -eq 0 ] || problems="$problems critical_warning=$warning (bit field, see nvme smart-log);"
[ "$media" -eq 0 ] || problems="$problems $media media errors: data integrity at risk;"
[ "${log_entries:-0}" -eq 0 ] || problems="$problems $log_entries entries in the error log;"
[ "$used" -lt 80 ] || problems="$problems wear $used %: plan a replacement;"
if [[ ${spare_min:-} =~ ^[0-9]+$ ]] && [ "$spare" -lt "$spare_min" ]; then
  problems="$problems spare blocks $spare % below the threshold $spare_min %: failure is imminent;"
fi
[ -z "$problems" ] || check_fail "${problems# }"
check_ok "healthy: wear $used %, spare $spare %, 0 media errors, ${temp:-?} °C, ${hours:-?} h"
