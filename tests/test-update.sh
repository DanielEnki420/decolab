#!/usr/bin/env bash
# Contract tests for scripts/update.sh. It runs in a copy of the tree with
# its own git history (release tag v1.0.0), so the checks against git are
# real. docker is a fake: the "running" image of each container is the file
# $RUNNING/<name>; "compose up" sets it to what the compose file says.
# Single quotes around $… are intended: the fakes evaluate them.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

tree=$t_tmp/tree
mkdir -p "$tree"
cp -R "$t_root/lib" "$t_root/bin" "$t_root/config" "$t_root/scripts" "$t_root/compose" "$t_root/stacks" "$tree/"
# backup.sh as a stub: that update.sh calls it is the contract here.
cat >"$tree/scripts/backup.sh" <<EOF
#!/bin/sh
echo ran >>"$t_tmp/backup.calls"
mkdir -p "$t_tmp/data/backups/\$(date +%Y-%m-%d_%H-%M)"
EOF
commit() { git -C "$tree" add -A && git -C "$tree" -c user.name=t -c user.email=t@example.org commit -qm "$1"; }
# Release tags are signed (bin/decolab-checkout, update.sh): a throwaway key
ssh-keygen -q -t ed25519 -N '' -C release -f "$t_tmp/release-key"
ssh-keygen -q -t ed25519 -N '' -C other -f "$t_tmp/other-key"
printf 'release@example.org namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$t_tmp/release-key.pub")" >"$t_tmp/release-signers"
export DECOLAB_RELEASE_SIGNERS=$t_tmp/release-signers DECOLAB_CHECKOUT_FETCH=no
stag() { # TAG [KEY] - a signed release tag
  git -C "$tree" -c gpg.format=ssh -c user.signingkey="${2:-$t_tmp/release-key}" \
    -c user.name=t -c user.email=release@example.org tag -s -m "$1" "$1"
}
git -C "$tree" init -q && commit release && stag v1.0.0
printf 'DECOLAB_UID=1000\nDECOLAB_GID=1000\nDOCKER_GID=990\n' >"$t_tmp/secrets/runtime.env"
printf 'PIHOLE_PASSWORD=x\n' >"$t_tmp/secrets/compose-secrets.env"
sed 's/^MODULE_IMMICH=.*/MODULE_IMMICH=no/; s/^MODULE_UPTIME_KUMA=.*/MODULE_UPTIME_KUMA=no/' "$DECOLAB_CONF" >"$t_tmp/update.conf"
export DECOLAB_CONF=$t_tmp/update.conf RUNNING=$t_tmp/running UPDATE_MIN_FREE_MB=1 \
  UPDATE_STEP_S=1 UPDATE_SETTLE_S=2 UPDATE_HEALTH_WAIT_S=4
mkdir -p "$RUNNING" "$t_tmp/data/backups"

# The services of a compose file: "json" as compose config prints it (the
# parts update.sh reads), or "lines" of container and image.
cat >"$t_tmp/svc.py" <<'PY'
import json, re, sys
services, name = {}, None
for line in open(sys.argv[1]):
    m = re.match(r"  ([a-z0-9_-]+):$", line)
    if m:
        name = m.group(1)
        services[name] = {}
        continue
    m = re.match(r"    (container_name|image): *(\S+)", line)
    if m and name:
        services[name][m.group(1)] = m.group(2)
if sys.argv[2] == "json":
    json.dump({"services": services}, sys.stdout)
else:
    for k, v in services.items():
        print(v.get("container_name", k), v.get("image", ""))
PY
export FAKE_DOCKER='file=$(for a in "$@"; do case $a in (*.yml) echo "$a" ;; esac; done | head -1)
stack=core
case $file in */stacks/*) stack=${file%/compose.yml} stack=${stack##*/} ;; esac
svc() { python3 -I "$(dirname "$RUNNING")/svc.py" "$file" "$1"; }
case $1 in
  info) dirname "$RUNNING" ;;
  inspect)
    case "$*" in
      *Config.Image*) cat "$RUNNING/$4" 2>/dev/null || exit 1 ;;
      *State.Status*) echo "${STATE:-running none 0}" ;;
      *) [ "$2" != watchtower ] ;;
    esac ;;
  compose)
    case "$*" in
      *" config -q"*) [ -z "${CONFIG_BAD:-}" ] || { echo "yaml: line 3: did not find expected key"; exit 1; } ;;
      *"config --format json"*) svc json ;;
      *" pull"*) echo "pull $stack" >>"$RUNNING.log"; [ -z "${PULL_BAD:-}" ] ;;
      *" up -d"*) cp "$DECOLAB_RUN_DIR/maintenance" "$RUNNING.flag" 2>/dev/null
        echo "up $stack" >>"$RUNNING.log"
        [ -n "${UP_STALE:-}" ] || svc lines | while read -r n i; do echo "$i" >"$RUNNING/$n"; done ;;
    esac ;;
esac'
run_release() { # everything runs what the compose files of the copy say
  local f
  rm -rf "$RUNNING" && mkdir -p "$RUNNING"
  for f in "$tree/compose/core.yml" "$tree/stacks/vaultwarden/compose.yml"; do
    python3 -I "$t_tmp/svc.py" "$f" lines | while read -r n i; do echo "$i" >"$RUNNING/$n"; done
  done
  rm -f "$RUNNING.log" "$RUNNING.flag" "$t_tmp/backup.calls"
}
fresh_backup() { rm -rf "$t_tmp/data/backups" && mkdir -p "$t_tmp/data/backups/$(date +%Y-%m-%d_%H-%M)"; }
up() { "$tree/scripts/update.sh" "$@" </dev/null; }
# release 1.1.0: a new Pi-hole and a new Vaultwarden
new_release() {
  sed -i.bak 's#\(image: pihole/pihole:latest@sha256:\)[0-9a-f]*#\1'"$(printf 'a%.0s' $(seq 64))"'#' "$tree/compose/core.yml"
  sed -i.bak 's#\(image: vaultwarden/server@sha256:\)[0-9a-f]*#\1'"$(printf 'b%.0s' $(seq 64))"'#' "$tree/stacks/vaultwarden/compose.yml"
  rm -f "$tree/compose/core.yml.bak" "$tree/stacks/vaultwarden/compose.yml.bak"
  commit "release 1.1.0" && stag v1.1.0
}

echo "update.sh"
run_release && fresh_backup
check "everything runs the release: nothing to do" 0 "nothing to do" -- up
check "  ... named by its release" 0 "(v1.0.0)" -- up

new_release
check "--dry-run names what would change" 0 "would recreate pihole (core): sha256:30f8" -- up --dry-run
check "  ... and Vaultwarden" 0 "would recreate vaultwarden (vaultwarden)" -- up --dry-run
refute "  ... nothing else" "would recreate portainer"
check "  ... and does nothing" 0 "" -- test ! -e "$RUNNING.log"

check "the update: up" 0 "OK: unknown -> v1.1.0, recreated pihole vaultwarden" -- up
same "  pulled before anything was recreated" "$(tr '\n' ' ' <"$RUNNING.log")" "pull core pull vaultwarden up core up vaultwarden "
same "  the maintenance flag named exactly the changed containers" "$(sed 1d "$RUNNING.flag" | tr '\n' ' ')" "pihole vaultwarden "
check "  ... and is gone" 0 "" -- test ! -e "$DECOLAB_RUN_DIR/maintenance"
check "  the way back is written down" 0 '"before": "pihole/pihole:latest@sha256:30f8' -- cat "$DECOLAB_STATE_DIR/last-update.json"
check "  a message" 0 "recreated pihole vaultwarden" -- telegrams
check "  no image was deleted (the old ones are the way back)" 0 "" -- bash -c '! grep -E "^(image (prune|rm)|rmi|system prune)" "$1"' _ "$FAKE_DOCKER_LOG"
check "  the fresh backup was enough: no new one" 0 "" -- test ! -e "$t_tmp/backup.calls"
check "  now current" 0 "(v1.1.0): nothing to do" -- up

git -C "$tree" checkout -q v1.0.0
check "the way back: v1.0.0 again (no release tag needed with --force)" 0 "recreated pihole vaultwarden" -- up --force
check "  ... and knows where it came from" 0 '"from": "v1.1.0"' -- cat "$DECOLAB_STATE_DIR/last-update.json"
git -C "$tree" checkout -q v1.1.0

run_release
git -C "$tree" checkout -q v1.0.0 && run_release && git -C "$tree" checkout -q v1.1.0
rm -rf "$t_tmp/data/backups" && mkdir -p "$t_tmp/data/backups/2020-01-01_03-00"
check "an old backup: a new one first" 0 "making one first" -- up
same "  backup.sh ran once" "$(wc -l <"$t_tmp/backup.calls" | tr -d ' ')" "1"

git -C "$tree" checkout -q v1.0.0 && run_release && git -C "$tree" checkout -q v1.1.0 && fresh_backup
check "a pull fails: nothing changed" 1 "pulling core failed: nothing changed" -- env PULL_BAD=1 "$tree/scripts/update.sh"
check "  ... nothing recreated" 0 "" -- bash -c '! grep -q "^up" "$1"' _ "$RUNNING.log"
check "a container does not come back: reported" 1 "not healthy: pihole(running unhealthy) vaultwarden(running unhealthy)" -- env STATE="running unhealthy 0" "$tree/scripts/update.sh"
check "  ... a message" 0 "NOT healthy" -- telegrams
check "  ... the flag is gone all the same" 0 "" -- test ! -e "$DECOLAB_RUN_DIR/maintenance"
git -C "$tree" checkout -q v1.0.0 && run_release && git -C "$tree" checkout -q v1.1.0
check "a container that keeps restarting is not healthy" 1 "not healthy" -- env STATE="restarting none 3" "$tree/scripts/update.sh"
git -C "$tree" checkout -q v1.0.0 && run_release && git -C "$tree" checkout -q v1.1.0
check "a backup holds the lock: nothing recreated" 1 "holds the lock: nothing changed" -- env FAKE_FLOCK_BUSY=1 UPDATE_LOCK_WAIT_S=1 "$tree/scripts/update.sh"

echo "# mine" >>"$tree/compose/core.yml"
check "a changed compose file: refused" 1 "changed against git:  M compose/core.yml" -- up
git -C "$tree" checkout -q -- compose/core.yml
git -C "$tree" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m "after the release"
check "a checkout that is no release: refused" 1 "is no release" -- up
check "  ... unless --force" 0 "would recreate" -- up --force --dry-run
git -C "$tree" checkout -q v1.1.0
check "an invalid compose file: refused" 1 "compose file invalid: yaml: line 3" -- env CONFIG_BAD=1 "$tree/scripts/update.sh"
mv "$t_tmp/secrets/runtime.env" "$t_tmp/runtime.env.away"
check "an env file missing: refused" 1 "env file missing: $t_tmp/secrets/runtime.env" -- up
mv "$t_tmp/runtime.env.away" "$t_tmp/secrets/runtime.env"
check "too little disk space: refused" 1 "MB free for Docker" -- env UPDATE_MIN_FREE_MB=999999999 "$tree/scripts/update.sh"
check "--only one stack" 0 "would recreate vaultwarden" -- up --only vaultwarden --dry-run
refute "  ... not the others" "pihole"
check "--only a stack that is not here" 1 "no stack 'immich' here" -- up --only immich
check "as root: refused" 1 "not as root" -- bash -c 'id() { echo 0; }; export -f id; "$1"' _ "$tree/scripts/update.sh"
check "no scheduled update in the cron templates" 0 "" -- bash -c '! grep -hE "^[^#].*/scripts/update\.sh" "$1"/config/cron/*.template' _ "$t_root"

echo "signed releases"
co() { "$tree/bin/decolab-checkout" "$@"; }
git -C "$tree" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m "release 1.2.0"
git -C "$tree" tag v1.2.0
git -C "$tree" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m "release 1.3.0"
stag v1.3.0 "$t_tmp/other-key"
git -C "$tree" checkout -q v1.1.0
check "checkout: a signed release" 0 "checked out v1.0.0 (signature good)" -- co v1.0.0
same "  ... is checked out" "$(git -C "$tree" rev-parse HEAD)" "$(git -C "$tree" rev-parse 'v1.0.0^{commit}')"
check "checkout: an unsigned tag is refused" 1 "v1.2.0 is not signed by a key in $DECOLAB_RELEASE_SIGNERS: not checked out" -- co v1.2.0
check "checkout: another key is refused" 1 "v1.3.0 is not signed by a key" -- co v1.3.0
same "  ... nothing checked out" "$(git -C "$tree" rev-parse HEAD)" "$(git -C "$tree" rev-parse 'v1.0.0^{commit}')"
git -C "$tree" checkout -q v1.1.0
git -C "$tree" branch v1.0.0 "v1.2.0^{commit}" 2>/dev/null
co v1.0.0 >/dev/null 2>&1
same "checkout: the tag, not a branch of the same name" "$(git -C "$tree" rev-parse HEAD)" "$(git -C "$tree" rev-parse 'refs/tags/v1.0.0^{commit}')"
git -C "$tree" branch -D v1.0.0 >/dev/null 2>&1
check "checkout: no release key installed" 1 "no release key in" -- env DECOLAB_RELEASE_SIGNERS=/nonexistent "$tree/bin/decolab-checkout" v1.0.0
check "checkout: not a version" 2 "" -- co main
git -C "$tree" checkout -q v1.2.0
check "update.sh: an unsigned release is refused" 1 "release v1.2.0 is not signed by a key" -- up --dry-run
git -C "$tree" checkout -q v1.3.0
check "update.sh: another key is refused" 1 "release v1.3.0 is not signed by a key" -- up --dry-run
git -C "$tree" checkout -q v1.1.0

t_finish
