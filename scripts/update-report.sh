#!/usr/bin/env bash
# update-report.sh [--quiet] - what is there to update? Installs nothing,
# restarts nothing, pulls no image: it only says what to do.
#
# Daily with --quiet (no message; keeps the Uptime Kuma monitor UPDATES
# fresh, so a run that stops is noticed after a day, not a week), Mondays
# with a message.
#
#   red     a security update open for more than UPDATE_RED_DAYS (7) days:
#           unattended-upgrades should have installed it by itself
#   yellow  any other update or a reboot waiting
#   green   nothing to do (one line)
#
# Covers: Debian packages, a reboot, the Docker engine (never automatic,
# config/host/apt-origins.conf), a newer Decolab release (git ls-remote of
# this checkout's origin, if it has one), and Watchtower's week, if you
# installed it. Decolab's own images change only with a release.
#
# Overridable for tests: UPDATE_APT_LIST (file instead of apt list),
# UPDATE_REBOOT_FILE, UPDATE_TODAY (YYYY-MM-DD).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
quiet=0
[ "${1:-}" != --quiet ] || quiet=1
today=${UPDATE_TODAY:-$(date +%F)}
red_days=${UPDATE_RED_DAYS:-7}

# --- Debian packages ---------------------------------------------------------
if [ -n "${UPDATE_APT_LIST:-}" ]; then
  apt=$(cat "$UPDATE_APT_LIST" 2>/dev/null) || die "cannot read $UPDATE_APT_LIST"
else
  apt=$(apt list --upgradable 2>/dev/null) || die "apt list failed"
fi
apt=$(printf '%s\n' "$apt" | grep -E '^[a-z0-9][a-z0-9.+-]*/' || true)
n_apt=$(printf '%s' "$apt" | grep -c '/' || true)
security=$(printf '%s\n' "$apt" | awk -F'[/ ]' '$2 ~ /-security/ { print $1 }' | sort -u)
n_security=$(printf '%s' "$security" | grep -c . || true)
docker_waiting=$(printf '%s\n' "$apt" | awk -F/ '$1 ~ /^(docker-ce|docker-ce-cli|containerd\.io)$/ { print $1 }' | tr '\n' ' ')

# Since when is each open security update known? A package keeps its first
# day until it is installed; the state file holds "package day" lines.
since_file=$DECOLAB_STATE_DIR/security-updates-since
oldest=0
new_since=""
for p in $security; do
  d=$(awk -v p="$p" '$1 == p { print $2 }' "$since_file" 2>/dev/null | head -1)
  case $d in 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) d=$today ;; esac
  new_since="$new_since$p $d"$'\n'
  days=$(python3 -I -c 'import datetime, sys
print((datetime.date.fromisoformat(sys.argv[1]) - datetime.date.fromisoformat(sys.argv[2])).days)' "$today" "$d")
  [ "$days" -le "$oldest" ] || oldest=$days
done
if ! { printf '%s' "$new_since" >"$since_file.tmp" && mv "$since_file.tmp" "$since_file"; }; then
  warn "cannot write $since_file"
fi

reboot=no
[ ! -e "${UPDATE_REBOOT_FILE:-/var/run/reboot-required}" ] || reboot=yes

# --- Decolab release ---------------------------------------------------------
# Only a tag list from the origin you cloned from; nothing about this
# installation is sent anywhere.
release="" newest=""
if git -C "$decolab_root" rev-parse --git-dir >/dev/null 2>&1; then
  # the highest release tag on this commit, else the last one before it
  release=$(git -C "$decolab_root" tag --points-at HEAD 'v*' 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' |
    sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
  release=${release:+v$release}
  [ -n "$release" ] || release=$(git -C "$decolab_root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null)
  if git -C "$decolab_root" remote get-url origin >/dev/null 2>&1; then
    newest=$(timeout 30 git -C "$decolab_root" ls-remote --tags --refs origin 'v*' 2>/dev/null |
      sed -n 's#.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    newest=${newest:+v$newest}
  fi
fi
newer_release=""
if [ -n "$newest" ] && [ -n "$release" ] && [ "$newest" != "$release" ] &&
  [ "$(printf '%s\n%s\n' "$release" "$newest" | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "${newest#v}" ]; then
  newer_release=$newest
fi

# --- Watchtower (only if you installed it for your own containers) -----------
wt=""
if docker inspect watchtower >/dev/null 2>&1; then
  wt=$(docker logs watchtower --since 168h 2>&1 | python3 -I -c 'import re, sys
out = sys.stdin.read()
runs = len(re.findall(r"Session done|Update session completed", out))
upd = sum(int(n) for n in re.findall(r"updated=(\d+)", out))
fail = sum(int(n) for n in re.findall(r"failed=(\d+)", out))
print(runs, upd, fail)')
fi

# --- verdict -----------------------------------------------------------------
lines=() todo=()
lines+=("apt: $n_apt open ($n_security security$([ "$n_security" -eq 0 ] || echo ", open for $oldest days"))")
[ "$n_security" -eq 0 ] || lines+=("  $(printf '%s' "$security" | head -8 | tr '\n' ' ')")
if [ "$reboot" = yes ]; then lines+=("reboot needed: yes") && todo+=("reboot"); fi
if [ -n "$docker_waiting" ]; then
  lines+=("Docker engine: ${docker_waiting% } waiting")
  todo+=("Docker engine by hand: sudo apt upgrade (restarts every container)")
fi
[ "$n_security" -eq 0 ] || [ "$oldest" -le "$red_days" ] ||
  todo+=("security updates are not installing by themselves: check unattended-upgrades")
if [ -n "$newer_release" ]; then
  lines+=("Decolab: $newer_release available (running $release)")
  todo+=("read the release notes, then: bin/decolab-checkout $newer_release && ./install.sh && scripts/update.sh --dry-run")
elif [ -n "$release" ]; then
  lines+=("Decolab: $release")
fi
if [ -n "$wt" ]; then
  read -r wt_runs wt_upd wt_fail <<<"$wt"
  lines+=("Watchtower this week: $wt_upd updated, $wt_fail failed$([ "$wt_runs" -gt 0 ] || echo ", NO run found")")
fi

red=0 yellow=0
[ "$n_security" -eq 0 ] || [ "$oldest" -le "$red_days" ] || red=1
if [ "$n_apt" -gt 0 ] || [ "$reboot" = yes ] || [ -n "$newer_release" ]; then yellow=1; fi
if [ -n "$wt" ] && { [ "${wt_fail:-0}" -gt 0 ] || [ "${wt_runs:-0}" -eq 0 ]; }; then yellow=1; fi

if [ "$red" = 1 ]; then
  title="🔴 Updates" verdict=red
elif [ "$yellow" = 1 ]; then
  title="🔄 Updates" verdict=yellow
else
  title="✅ Updates" verdict=green
fi
if [ "$verdict" = green ]; then
  text="$today: everything is current"
else
  text=$(printf '%s\n' "${lines[@]}")
  [ ${#todo[@]} -eq 0 ] || text+=$'\n\n'"To do: $(printf '%s; ' "${todo[@]}" | sed 's/; $//')"
fi

# Uptime Kuma: red = down (an alarm), yellow and green = up with the verdict.
kuma_push UPDATES "$([ "$red" = 1 ] && echo down || echo up)" "$verdict: $n_apt apt, $n_security security${newer_release:+, Decolab $newer_release}" ||
  warn "the result did not reach Uptime Kuma"
log "$verdict | $(printf '%s' "$text" | tr '\n' ' ')"
[ "$quiet" = 0 ] || exit 0
notify "$title" "$text" || die "sending failed"
