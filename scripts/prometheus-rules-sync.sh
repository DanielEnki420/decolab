#!/usr/bin/env bash
# prometheus-rules-sync.sh - make Prometheus see the configuration files on
# the host.
#
# config/prometheus/prometheus.yml and rules.yml are single-file bind
# mounts. Docker binds the inode, not the path: "git pull" (and every editor
# that saves by rename) writes a new file, and the container keeps reading
# the old one for good. The original system once had 11 rules on the host
# and 10 in the container; only the check that counts the LOADED rules
# noticed.
#
# Hourly: compares checksums (host against container), so it catches every
# cause, not only git. On a difference it first checks the new files with
# promtool in a throw-away container of the SAME image (the running one has
# a read-only root and cannot be used for that), and restarts Prometheus
# only if they are valid. Never restarts into a broken configuration.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init

container=prometheus
host_dir=$decolab_root/config/prometheus
files="prometheus.yml rules.yml"

for f in $files; do
  [ -s "$host_dir/$f" ] || die "$host_dir/$f is missing"
done

# sha256_of FILE - its checksum (sha256sum on Linux, shasum on a Mac)
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'
}

# sums WHERE - "file checksum" lines, from the host or from the container
sums() {
  local f
  for f in $files; do
    if [ "$1" = host ]; then
      printf '%s %s\n' "$f" "$(sha256_of "$host_dir/$f")"
    else
      printf '%s %s\n' "$f" "$(docker exec "$container" sha256sum "/etc/prometheus/$f" 2>/dev/null | awk '{ print $1 }')"
    fi
  done
}

host=$(sums host)
inside=$(sums container)
# A line without a checksum: the container did not answer.
case $inside$'\n' in *" "$'\n'*) die "$container does not answer: nothing done" ;; esac
if [ "$host" = "$inside" ]; then
  log "the same files: nothing to do"
  exit 0
fi
changed=$(diff <(printf '%s\n' "$host") <(printf '%s\n' "$inside") | sed -n 's/^< \([^ ]*\) .*/\1/p' | tr '\n' ' ')
log "differs: $changed"

# A backup or an update is running: no restart in the middle of it. The
# next run in an hour does it.
job_lock 5 || {
  log "a heavy job is running: postponed"
  exit 0
}

image=$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null)
[ -n "$image" ] || die "image of $container unknown: no restart"
if ! check=$(timeout 120 docker run --rm --network none --pull=never --entrypoint promtool \
  -v "$host_dir/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$host_dir/rules.yml:/etc/prometheus/rules.yml:ro" \
  "$image" check config /etc/prometheus/prometheus.yml 2>&1); then
  log "promtool: $(printf '%s' "$check" | tail -3 | tr '\n' ' ')"
  notify "🔴 Prometheus" "The changed configuration ($changed) is invalid and was NOT loaded. Prometheus keeps running with the old one."
  die "promtool rejects the new files: no restart"
fi

rules() { docker exec "$container" grep -cE '^[[:space:]]+- alert:' /etc/prometheus/rules.yml 2>/dev/null; }
before=$(rules)

# Prometheus is a container monitor.sh watches: say so before restarting.
maintenance_begin "$container"
trap maintenance_end EXIT
docker restart "$container" >/dev/null 2>&1 || die "restarting $container failed"

# Wait until it reads the new files, or the flag would end before it is back.
i=0
while [ "$i" -lt "${SYNC_WAIT_S:-90}" ] && [ "$(sums container)" != "$host" ]; do
  sleep "${SYNC_STEP_S:-3}"
  i=$((i + ${SYNC_STEP_S:-3}))
done
if [ "$(sums container)" != "$host" ]; then
  notify "🔴 Prometheus" "The restart did NOT bring in the changed files ($changed): the container still sees the old ones."
  die "still the old files after the restart"
fi
after=$(rules)
log "synced ($changed): $before -> $after alert rules"
[ "$before" = "$after" ] || notify "📏 Prometheus" "Alert rules synced: $before -> $after."
exit 0
