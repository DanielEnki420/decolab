#!/usr/bin/env bash
# check-unbound-dnssec.sh - is DNSSEC really validated, not just answered?
#
# If validation breaks (bad trust anchor, root.key not writable, a wrong
# setting after an image change), Unbound keeps answering happily, only
# without protection against forged answers. Both conditions must hold:
#   1. a correctly signed domain comes back with the ad flag
#   2. a deliberately broken signature comes back as SERVFAIL
# 1 alone would also pass a resolver that does not validate at all.
#
# Uptime Kuma push monitor: DNSSEC (every 15 minutes).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=DNSSEC

# drill -D (not +dnssec: that is dig syntax and yields no ad flag in drill)
good=$(timeout 30 docker exec unbound drill -D -p 5335 cloudflare.com @127.0.0.1 2>&1)
bad=$(timeout 30 docker exec unbound drill -D -p 5335 dnssec-failed.org @127.0.0.1 2>&1)

detail=""
printf '%s\n' "$good" | grep -qE '^;; flags:.* ad[ ;]' || detail="ad flag missing for a validly signed domain"
printf '%s\n' "$bad" | grep -q 'rcode: SERVFAIL' || detail="${detail:+$detail; }a broken signature was NOT rejected"
[ -z "$detail" ] || check_fail "DNSSEC validation broken: $detail"
check_ok "DNSSEC validates (ad flag set, broken signature -> SERVFAIL)"
