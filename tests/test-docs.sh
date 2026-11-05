#!/usr/bin/env bash
# Contract tests for the documentation: what it names must exist. A guide
# that points to a missing script or a wrong flag fails a stranger at the
# worst moment (RESTORE.md is read when the Pi is gone).
# The checks run in child shells: single quotes around $… are intended.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$t_root" || exit 1
docs=()
while IFS= read -r f; do docs+=("$f"); done < <(git ls-files -co --exclude-standard -- '*.md')

echo "links"
check "every relative link points to a file" 0 "" -- python3 -I - "${docs[@]}" <<'PY'
import os, re, sys
bad = []
for doc in sys.argv[1:]:
    for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", open(doc).read()):
        if re.match(r"[a-z]+:", target):
            continue
        if not os.path.exists(os.path.join(os.path.dirname(doc), target)):
            bad.append(f"{doc}: {target}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

echo "named files"
check "every scripts/, bin/, tools/ path in the docs exists" 0 "" -- bash -c '
  bad=""
  # a pattern like scripts/restore-probe-*.sh must match at least one file
  for p in $(grep -ohE "\b(scripts|bin|tools|tests)/[a-z0-9_.*-]+[a-z0-9*]" "$@" | sort -u); do
    set -- $p
    [ -e "$1" ] || bad="$bad $p"
  done
  [ -z "$bad" ] || { echo "missing:$bad"; exit 1; }' _ "${docs[@]}"
check "every script named in the schedule exists" 0 "" -- bash -c '
  bad=""
  for s in $(grep -ohE "\`[a-z0-9-]+\.sh" docs/schedule.md | tr -d "\`" | sort -u); do
    [ -e "scripts/$s" ] || bad="$bad $s"
  done
  [ -z "$bad" ] || { echo "missing:$bad"; exit 1; }'

echo "schedule"
# Both ways: a job in cron that the page does not list is a job nobody knows of.
check "docs/schedule.md lists every scheduled script" 0 "" -- bash -c '
  bad=""
  for s in $(grep -vh "^#" config/cron/*.template | grep -oE "scripts/[a-z0-9-]+\.sh" | sed "s#scripts/##" | sort -u); do
    grep -q "\`$s" docs/schedule.md || bad="$bad $s"
  done
  [ -z "$bad" ] || { echo "not in docs/schedule.md:$bad"; exit 1; }'
check "docs/schedule.md lists no script that is not scheduled" 0 "" -- bash -c '
  bad=""
  for s in $(grep -ohE "\`[a-z0-9-]+\.sh" docs/schedule.md | tr -d "\`" | sort -u); do
    case $s in watchdog.sh) continue ;; esac  # a systemd timer, not cron
    grep -v "^#" config/cron/*.template | grep -q "scripts/$s" || bad="$bad $s"
  done
  [ -z "$bad" ] || { echo "not scheduled:$bad"; exit 1; }'
check "the times in docs/schedule.md are the cron times" 0 "" -- python3 -I - <<'PY'
import glob, re, sys
cron = {}
for f in glob.glob("config/cron/*.template"):
    for line in open(f):
        m = re.match(r"(\S+) (\S+) (\S+) (\S+) (\S+) .*scripts/([a-z0-9-]+\.sh)", line)
        if m and m.group(1).isdigit() and m.group(2).isdigit():
            cron.setdefault(m.group(6), set()).add("%02d:%02d" % (int(m.group(2)), int(m.group(1))))
page = open("docs/schedule.md").read()
bad = []
for row in page.splitlines():
    m = re.match(r"\| (\d\d:\d\d) \| `([a-z0-9-]+\.sh)", row)
    if m and m.group(1) not in cron.get(m.group(2), set()):
        bad.append(f"{m.group(2)}: page {m.group(1)}, cron {sorted(cron.get(m.group(2), []))}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY

echo "commands"
check "every install.sh flag in the guides exists" 0 "" -- bash -c '
  bad=""
  for f in $(grep -ohE "install\.sh( --[a-z-]+)+" INSTALL.md RESTORE.md | grep -oE -- "--[a-z-]+" | sort -u); do
    grep -q -- "^    $f)" install.sh || bad="$bad $f"
  done
  [ -z "$bad" ] || { echo "unknown:$bad"; exit 1; }'
check "every decolab-firewall command in the guides exists" 0 "" -- bash -c '
  bad=""
  for c in $(grep -ohE "decolab-firewall [a-z]+" INSTALL.md docs/security.md decolab.conf.example | cut -d" " -f2 | sort -u); do
    grep -qE "^#   (sudo )?decolab-firewall $c( |$)" bin/decolab-firewall || bad="$bad $c"
  done
  [ -z "$bad" ] || { echo "unknown:$bad"; exit 1; }'
check "every port published with tailscale serve is one Decolab listens on" 0 "" -- bash -c '
  bad=""
  for p in $(grep -oE "http://127\.0\.0\.1:[0-9]+" INSTALL.md | sed "s/.*://" | sort -u); do
    [ "$p" = 8090 ] && continue  # PANEL_PORT, the panel is no container
    grep -qE "\"(127\.0\.0\.1|\\$\{WEB_UI_ADDRESS\}):$p:" compose/core.yml stacks/*/compose.yml || bad="$bad $p"
  done
  [ -z "$bad" ] || { echo "not published:$bad"; exit 1; }'
check "the panel port in INSTALL.md is the example PANEL_PORT" 0 "PANEL_PORT=8090" -- grep "^PANEL_PORT=" decolab.conf.example

t_finish
