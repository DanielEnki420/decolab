#!/usr/bin/env bash
# Contract tests for config/**/*.template: install.sh renders each one with
# envsubst and an explicit variable list, so a template must declare exactly
# the variables it uses. An undeclared ${X} would stay in the file literally;
# a declared but unused one hints at a typo.
# Single quotes around $… are intended: awk and grep see them, not the shell.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

templates=$(cd "$t_root" && find config -name '*.template' | sort)
[ -n "$templates" ] || t_fail "templates found" "no config/**/*.template"

for t in $templates; do
  f=$t_root/$t
  decl=$(grep -m1 'with exactly these variables:' "$f" | sed 's/.*variables://' |
    grep -oE '\$\{[A-Z_]+\}' | sort -u | tr '\n' ' ')
  used=$(grep -v 'with exactly these variables:' "$f" | grep -oE '\$\{[A-Z_]+\}' | sort -u | tr '\n' ' ')
  if [ -z "$decl" ]; then
    t_fail "$t declares its variables" "missing line: install.sh renders this file with exactly these variables: ..."
  else
    same "$t uses exactly the declared variables" "$used" "$decl"
  fi
  # Only settings from decolab.conf, values install.sh measures (runtime.env)
  # and secrets it generates may appear.
  bad=""
  for v in $decl; do
    v=${v#\$\{}; v=${v%\}}
    case $v in
      DECOLAB_UID|DECOLAB_GID|DOCKER_GID|UPSMON_PASSWORD) ;;
      *) grep -qE "^${v}[[:space:]]" "$t_root/config/schema.txt" || bad="$bad $v" ;;
    esac
  done
  same "$t uses only known variables" "${bad# }" ""
  check "$t has no other shell expansion" 1 "" -- grep -nE '\$[A-Za-z(]' "$f"
done

echo "schedules"
for c in config/cron/cron.d-decolab.template:'${DECOLAB_USER}' config/cron/cron.d-decolab-root.template:root; do
  u=${c#*:} c=${c%%:*}
  check "$c: no variable lines" 1 "" -- grep -nE '^[A-Z_]+=' "$t_root/$c"
  check "$c: five time fields, the user $u and an absolute command" 0 "" -- awk -v u="$u" '
    /^#/ || /^[[:space:]]*$/ { next }
    NF < 7 || $6 != u || $7 !~ /^(\$\{DECOLAB_DIR\}|\/)/ { print FILENAME ":" NR ": " $0; bad = 1 }
    END { exit bad }' "$t_root/$c"
  check "$c: every job writes its own log in /var/log/decolab" 0 "" -- awk '
    /^#/ || /^[[:space:]]*$/ { next }
    $0 !~ />> \/var\/log\/decolab\/[a-z0-9-]+\.log 2>&1$/ { print NR ": " $0; bad = 1 }
    END { exit bad }' "$t_root/$c"
done
# cron ignores files in /etc/cron.d whose name has a dot
check "cron.d names have no dot" 1 "" -- sh -c "grep -h 'installed as' '$t_root'/config/cron/*.template -A1 | grep -oE '/etc/cron[.]d/[^ ]*' | sed 's,.*/,,; s/[.]$//' | grep '[.]'"

echo "install manifest"
# config/install-manifest.tsv is what install.sh places; the headers of the
# files say where they go. Both must agree, and nothing may be left out.
man=$t_root/config/install-manifest.tsv
check "six TAB-separated columns, known WHEN and AFTER" 0 "" -- awk -F'\t' '
  /^#/ || /^$/ { next }
  NF != 6 || $5 !~ /^(always|late|HARDENING|HW_FAN|HW_OLED|HW_NVME|HW_UPS)$/ ||
  $6 !~ /^(-|tmpfiles|systemd|udev|sysctl|nut|sudoers)$/ || $3 !~ /^0[0-7]{3}$/ { print NR ": " $0; bad = 1 }
  END { exit bad }' "$man"
listed=$(awk -F'\t' '!/^#/ && NF { print $1 }' "$man" | sort)
# The SSH drop-in is placed by bin/decolab-firewall apply (on trial), not by install.sh.
present=$(cd "$t_root" && find config/host config/systemd config/udev config/nut config/crowdsec config/cron config/samba config/firewall -type f |
  grep -vx config/firewall/sshd-decolab.conf | sort)
same "every host file is in the manifest" "$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$present"))" ""
same "every manifest file exists" "$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$present"))" ""
while IFS=$'\t' read -r src dest mode owner _; do
  case $src in '' | '#'*) continue ;; esac
  head=$(head -8 "$t_root/$src" | tr '\n' ' ' | sed 's/[#/]\{1,2\} / /g; s/  */ /g')
  case $head in *"${dest} "* | *"${dest}."* | *"${dest}:"* | *"${dest};"* | *"${dest})"*) t_ok "$src: header names $dest" ;;
    *) t_fail "$src: header names $dest" "header: $(printf '%s' "$head" | cut -c1-120)" ;; esac
  # "(440 root:root)" in a header must match the manifest
  hm=$(printf '%s' "$head" | grep -oE '\([0-7]{3} [a-z]+:[a-z]+\)' | head -1 | tr -d '()')
  [ -z "$hm" ] || same "$src: mode and owner as in the header" "$hm" "${mode#0} $owner"
done <"$man"

echo "references"
# Every program a schedule, unit, sudoers or NUT file names must exist and
# be executable: a renamed script would otherwise only fail at night.
refs=$(cd "$t_root" && grep -rhoE '\$\{DECOLAB_DIR\}/(scripts|bin|services)/[A-Za-z0-9_.-]+' config | sort -u)
[ -n "$refs" ] || t_fail "references found" "no \${DECOLAB_DIR}/... in config"
for r in $refs; do
  f=$t_root/${r#\$\{DECOLAB_DIR\}/}
  case $f in
    *.py) check "${r#*/} exists" 0 "" -- test -f "$f" ;;
    *) check "${r#*/} exists and is executable" 0 "" -- test -x "$f" ;;
  esac
done

t_finish
