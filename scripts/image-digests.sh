#!/usr/bin/env bash
# image-digests.sh - which image runs in which container, daily at 03:45,
# BEFORE Watchtower (04:00).
#
# After a bad automatic update you need two answers: WHAT changed, and WHAT
# to go back to. Neither is kept anywhere else: Watchtower's own log is gone
# when its container restarts, and WATCHTOWER_CLEANUP deletes the old image
# right after the update. The original system once had no way back for
# exactly that reason.
#
# Writes $DECOLAB_STATE_DIR/image-digests/YYYY-MM-DD.txt (kept for
# IMAGE_DIGESTS_KEEP days, 90). To roll back a container:
#   diff the files of the day before and after the update
#   docker pull <repository>@<digest of the day before>
#   set that as image: in its compose file, start the stack again
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
decolab_init

dir=$DECOLAB_STATE_DIR/image-digests
keep=${IMAGE_DIGESTS_KEEP:-90}
mkdir -p "$dir" || die "cannot create $dir"
target=$dir/$(date +%F).txt
tmp=$target.$$.tmp
trap 'rm -f "$tmp"' EXIT

names=$(docker ps --format '{{.Names}}' 2>/dev/null | sort) || die "docker does not answer"
{
  echo "# Running images, $(date '+%F %T %Z'), written by scripts/image-digests.sh"
  echo "# container | image as configured | digest | updated by Watchtower"
  for c in $names; do
    image=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)
    # No RepoDigests: built locally, nothing to pull back. Said explicitly,
    # so nobody wonders about an empty column later.
    digest=$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$image" 2>/dev/null)
    case $digest in *@*) digest=${digest#*@} ;; *) digest="(built locally: no digest)" ;; esac
    wt=no
    [ "$(docker inspect -f '{{index .Config.Labels "com.centurylinklabs.watchtower.enable"}}' "$c" 2>/dev/null)" = true ] && wt=yes
    printf '%-26s %-60s %-72s %s\n' "$c" "$image" "$digest" "$wt"
  done
} >"$tmp" || die "cannot write $tmp"

# A cut-off list must not replace a good one: fewer than half the containers
# of the last list means something is wrong (Docker restarting, say).
count=$(grep -vc '^#' "$tmp")
last=$(find "$dir" -name '20??-??-??.txt' ! -name "${target##*/}" | sort | tail -1)
before=0
[ -z "$last" ] || before=$(grep -vc '^#' "$last")
if [ "$count" -eq 0 ] || [ "$count" -lt $((before / 2)) ]; then
  die "only $count containers (last list: $before): the old list stays"
fi
chmod 644 "$tmp" || die "cannot chmod $tmp"
mv -f "$tmp" "$target" || die "cannot write $target"

# Rotation by count, never by date: a clock that jumps cannot delete them all.
find "$dir" -name '20??-??-??.txt' | sort | awk -v k="$keep" '{ a[NR] = $0 } END { for (i = 1; i <= NR - k; i++) print a[i] }' |
  while read -r old; do rm -f "$old"; done
changed=""
[ -z "$last" ] || changed=$(diff <(grep -v '^#' "$last" | awk '{ print $1, $3 }') <(grep -v '^#' "$target" | awk '{ print $1, $3 }') |
  sed -n 's/^> \([^ ]*\) .*/\1/p' | tr '\n' ' ')
log "OK: $count containers${changed:+, new image since ${last##*/}: $changed}"
