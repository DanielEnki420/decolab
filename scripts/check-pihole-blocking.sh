#!/usr/bin/env bash
# check-pihole-blocking.sh - does Pi-hole really BLOCK?
#
# A port check only proves that port 53 answers. With empty block lists (a
# failed gravity update, an emptied database) Pi-hole keeps answering, it
# just blocks nothing, and nobody notices until ads appear everywhere. Both
# conditions are needed:
#   1. known ad domains are blocked (0.0.0.0, or NXDOMAIN in NX blocking mode)
#   2. a normal domain still resolves normally
# Without 2, a broken Pi-hole that answers 0.0.0.0 to everything would pass.
#
# Knows the maintenance flag (lib/common.sh). The flag is read only AFTER a
# failed check: the check and the job that pauses Pi-hole may start in the
# same second. While a valid
# flag names pihole, the check waits for the pause to end and then checks for
# real, giving FTL time to load its block lists.
#
# Uptime Kuma push monitor: PIHOLE (every 15 minutes, under flock).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
CHECK_MONITOR=PIHOLE
# The block test domains must be on the default block list (install.sh).
ad_domains=${PIHOLE_TEST_AD_DOMAINS:-doubleclick.net googleadservices.com ads.google.com}
normal_domain=${PIHOLE_TEST_NORMAL_DOMAIN:-example.com}
wait_max=${PIHOLE_WAIT_MAX_S:-360} startup_max=${PIHOLE_STARTUP_MAX_S:-180} step=${PIHOLE_STEP_S:-15}

ask() { timeout 30 docker exec pihole dig @127.0.0.1 "$@" 2>/dev/null; }

# Prints the result. Line 1: message for Kuma; exit code 0 = ok.
blocking_test() (
  blocked=0 total=0
  for d in $ad_domains; do
    total=$((total + 1))
    r=$(ask "$d" +short | head -1)
    if [ "$r" = 0.0.0.0 ]; then
      blocked=$((blocked + 1))
    elif [ -z "$r" ]; then
      # NX blocking mode answers "no such domain". An empty answer alone is
      # not enough: a dead resolver (SERVFAIL, timeout) gives one too, so
      # NXDOMAIN must be in the header. These domains exist in real DNS.
      ask "$d" +noall +comments | grep 'status: NXDOMAIN' >/dev/null && blocked=$((blocked + 1))
    fi
  done
  normal=$(ask "$normal_domain" +short | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  if [ "$blocked" -eq "$total" ] && [ -n "$normal" ] && [ "$normal" != 0.0.0.0 ]; then
    echo "$blocked/$total ad domains blocked, normal resolution works"
    exit 0
  fi
  detail=""
  [ "$blocked" -eq "$total" ] || detail="only $blocked/$total ad domains blocked (block lists empty?)"
  [ -n "$normal" ] && [ "$normal" != 0.0.0.0 ] ||
    detail="${detail:+$detail; }normal resolution broken ($normal_domain -> '${normal:-nothing}')"
  echo "$detail"
  exit 1
)

paused() { # valid flag that names pihole
  maintenance_read
  [ -z "$MAINTENANCE_PROBLEM" ] && case $MAINTENANCE_CONTAINERS in *" pihole "*) true ;; *) false ;; esac
}

after=""
result=$(blocking_test) && check_ok "$result"
if paused && timeout 30 docker container inspect pihole >/dev/null 2>&1; then
  log "maintenance: Pi-hole paused on purpose ($result), waiting for the pause to end"
  end=$(($(date +%s) + wait_max))
  while paused && [ "$(date +%s)" -lt "$end" ]; do sleep "$step"; done
  if paused; then
    check_ok "maintenance: Pi-hole paused on purpose, check skipped this time ($result)"
  fi
  # Pause over: check for real, give FTL time to start.
  end=$(($(date +%s) + startup_max))
  after=" (checked again after the maintenance pause)"
  while :; do
    result=$(blocking_test) && check_ok "$result$after"
    [ "$(date +%s)" -lt "$end" ] || break
    sleep "$step"
  done
fi
maintenance_read
case $MAINTENANCE_NAMED in *" pihole "*) [ -n "$MAINTENANCE_PROBLEM" ] && result="$result [$MAINTENANCE_PROBLEM]" ;; esac
check_fail "$result$after"
