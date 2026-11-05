#!/usr/bin/env bash
# update.sh [--dry-run] [--only STACK] [--force] - apply this checkout's
# compose files to the running containers.
#
# Decolab's images are pinned by digest: an image changes only when a new
# Decolab release changes a compose file. So this is no scheduled job. It is
# what you run after "git pull" of a release:
#   scripts/update.sh --dry-run     what would change, nothing done
#   scripts/update.sh               do it
#
# What it does, in this order, and why:
#   1. checks first, refuses on any failure: env files there, every compose
#      file valid, compose/ and stacks/ unchanged against git (put your own
#      additions in local/), on a release tag (else --force), disk space
#   2. compares, per container, the image in the compose file with the one
#      running: only those that differ are touched (and named in the
#      maintenance flag, so the watchers do not report them)
#   3. pulls everything BEFORE touching anything: a failed pull changes
#      nothing, and pulling needs DNS, which Pi-hole's restart interrupts
#   4. a backup at most 6 hours old, made now if there is none: an update
#      may migrate a database (Immich, Vaultwarden, Kuma), and going back
#      after a migration is only possible with the backup
#   5. recreates, stack by stack, under the shared lock (never during a
#      backup), waits until every changed container is healthy
#   6. records what ran before in $DECOLAB_STATE_DIR/last-update.json and
#      deletes NO image: the old ones are the way back
# Way back: git checkout <the commit before> && scripts/update.sh --force.
# NOT safe after a database migration: restore the backup instead (RESTORE.md).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init
# shellcheck source=lib/compose.sh
. "$decolab_root/lib/compose.sh"

dry=0 force=0 only=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --force) force=1 ;;
    --only) only=${2:-} && shift ;;
    *) die "unknown argument $1 (use --dry-run, --only STACK, --force)" ;;
  esac
  shift
done
[ "$(id -u)" != 0 ] || die "run this as the Decolab user, not as root"

stacks=$(decolab_stacks)
if [ -n "$only" ]; then
  case $'\n'$stacks$'\n' in *$'\n'"$only"$'\n'*) stacks=$only ;; *) die "no stack '$only' here (stacks: $(printf '%s' "$stacks" | tr '\n' ' '))" ;; esac
fi

# --- 1. checks ---------------------------------------------------------------
problems=""
problem() {
  case $problems in *"- $1"$'\n'*) return 0 ;; esac # once, also if several stacks share it
  problems="$problems- $1"$'\n'
}
for s in $stacks; do
  while read -r f; do [ -s "$f" ] || problem "env file missing: $f (install.sh writes it)"; done < <(compose_env_files "$s")
done
for s in $stacks; do
  out=$(decolab_compose "$s" config -q 2>&1) || problem "$s: compose file invalid: $(printf '%s' "$out" | tail -1)"
done
if git -C "$decolab_root" rev-parse --git-dir >/dev/null 2>&1; then
  commit=$(git -C "$decolab_root" rev-parse --short HEAD)
  dirty=$(git -C "$decolab_root" status --porcelain -- compose stacks lib/compose.sh 2>/dev/null | head -5 | tr '\n' ' ')
  [ -z "$dirty" ] || problem "changed against git: $dirty(put your own additions in local/)"
  release=$(git -C "$decolab_root" describe --exact-match --tags HEAD 2>/dev/null)
  [ -n "$release" ] || [ "$force" = 1 ] || problem "this checkout is no release ($commit): check out a release tag, or use --force"
  # signed by a release key (bin/decolab-checkout checks it before the checkout)
  signers=${DECOLAB_RELEASE_SIGNERS:-/etc/decolab/release-signers}
  if [ -n "$release" ] && [ "$force" != 1 ] &&
    ! git -C "$decolab_root" -c gpg.ssh.allowedSignersFile="$signers" verify-tag "refs/tags/$release" >/dev/null 2>&1; then
    problem "release $release is not signed by a key in $signers: check releases out with bin/decolab-checkout"
  fi
else
  commit=unknown release=""
fi
root_dir=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
free_mb=$(df -Pk "${root_dir:-/}" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')
[ "${free_mb:-0}" -ge "${UPDATE_MIN_FREE_MB:-2048}" ] || problem "only ${free_mb:-?} MB free for Docker (at least ${UPDATE_MIN_FREE_MB:-2048})"
if [ -n "$problems" ]; then
  printf '%s' "$problems"
  die "nothing done"
fi

# --- 2. what would change ----------------------------------------------------
# "STACK CONTAINER WANTED RUNNING" per service; RUNNING "-" if missing.
plan=""
for s in $stacks; do
  json=$(decolab_compose "$s" config --format json 2>/dev/null) || die "$s: cannot read the compose file"
  while read -r name image; do
    [ -n "$name" ] || continue
    running=$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null) || running=-
    [ "$running" = "$image" ] || plan="$plan$s $name $image ${running:--}"$'\n'
  done < <(printf '%s' "$json" | python3 -I -c 'import json, sys
for k, v in json.load(sys.stdin).get("services", {}).items():
    print(v.get("container_name", k), v.get("image", ""))')
done
if [ -z "$plan" ]; then
  log "everything runs what the compose files say (${release:-$commit}): nothing to do"
  exit 0
fi
printf '%s' "$plan" | while read -r s name image running; do
  log "would recreate $name ($s): ${running##*@} -> ${image##*@}"
done
[ "$dry" = 0 ] || { log "dry run: nothing done"; exit 0; }
changed_stacks=$(printf '%s' "$plan" | awk '{ print $1 }' | uniq | tr '\n' ' ')
changed=$(printf '%s' "$plan" | awk '{ print $2 }' | tr '\n' ' ')

# --- 3. pull first -------------------------------------------------------------
for s in $changed_stacks; do
  log "pulling $s"
  COMPOSE_TIMEOUT_S=3600 decolab_compose "$s" pull --quiet || die "pulling $s failed: nothing changed"
done

# --- 4. a fresh backup -------------------------------------------------------
latest=$(backup_latest)
age=999
[ -z "$latest" ] || age=$(backup_age_h "$latest")
if [ "$age" -gt "${UPDATE_BACKUP_MAX_H:-6}" ]; then
  log "newest backup is ${age} h old: making one first"
  "$decolab_root/scripts/backup.sh" || die "the backup failed: nothing changed"
fi

# --- 5. recreate ---------------------------------------------------------------
job_lock "${UPDATE_LOCK_WAIT_S:-3600}" || die "a backup or probe holds the lock: nothing changed"
state=$DECOLAB_STATE_DIR/last-update.json
before=$(python3 -I -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["to"])
except Exception:
    print("unknown")' "$state" 2>/dev/null)
printf '%s' "$plan" | python3 -I -c 'import json, sys, time
rows = [l.split() for l in sys.stdin if l.strip()]
json.dump({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "from": sys.argv[2], "to": sys.argv[3],
           "containers": {r[1]: {"stack": r[0], "before": r[3], "after": r[2]} for r in rows}},
          open(sys.argv[1] + ".tmp", "w"), indent=2)' "$state" "$before" "${release:-$commit}" ||
  warn "cannot write $state.tmp"
mv "$state.tmp" "$state" 2>/dev/null || warn "cannot write $state"

# shellcheck disable=SC2086 # container names have no spaces
maintenance_begin $changed
trap maintenance_end EXIT
failed=""
for s in $changed_stacks; do
  log "recreating $s"
  COMPOSE_TIMEOUT_S=1800 decolab_compose "$s" up -d --pull never || failed="$failed $s(up)"
done

# shellcheck disable=SC2086 # container names have no spaces
failed="$failed$(compose_wait_healthy "${UPDATE_HEALTH_WAIT_S:-300}" "${UPDATE_SETTLE_S:-30}" "${UPDATE_STEP_S:-5}" $changed)"
maintenance_end
trap - EXIT

if [ -n "$failed" ]; then
  notify "🔴 Decolab update" "${before} -> ${release:-$commit}: NOT healthy:$failed. Logs: docker logs <container>. Way back: $state"
  die "not healthy:$failed"
fi
notify "✅ Decolab update" "${before} -> ${release:-$commit}: recreated $changed"
log "OK: ${before} -> ${release:-$commit}, recreated $changed"
