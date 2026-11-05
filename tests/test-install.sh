#!/usr/bin/env bash
# Contract tests for install.sh: a foreign configuration (user, paths and
# network of nobody real), every host path below $t_tmp/root, host commands
# as stubs. What a real host adds (owners, sudo, systemd) is the VM probe's
# job (package G); here: the plan, the checks, the secrets, the record of
# written files, and that a second run changes nothing.
# shellcheck disable=SC2016 # single-quoted fake code is evaluated by the fakes
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

me=$(id -un)
gid=$(id -g)
stub=$t_tmp/bin
mkdir -p "$stub"
export PATH="$stub:$t_root/tests/fakes:$PATH"

# Host programs: present, doing nothing. argon2 answers like the real one.
for c in arp-scan logrotate unattended-upgrade librespeed-cli rsync restic \
  systemd-tmpfiles udevadm sysctl lsusb nvme upsc upsd i2cdetect nft; do
  printf '#!/bin/sh\necho "${0##*/} $*" >>"%s"\n' "$t_tmp/host.log" >"$stub/$c"
done
cat >"$stub/argon2" <<'EOF'
#!/bin/sh
# argon2 SALT -e -id ...: hash of stdin, encoded
printf '$argon2id$v=19$m=65540,t=3,p=4$%s$%s\n' "$1" "$(cat | shasum -a 256 | cut -c1-43)"
EOF
cat >"$stub/visudo" <<'EOF'
#!/bin/sh
# FAKE_VISUDO_BAD: a file name part that visudo rejects
case "$*" in *"${FAKE_VISUDO_BAD:-nothing-is-bad}"*) echo "syntax error" >&2; exit 1 ;; esac
exit 0
EOF
cat >"$stub/getent" <<'EOF'
#!/bin/sh
# the docker group as the test says; anything else as the host says (a
# host with private groups, like Debian's, must stay one in the tests)
if [ "$1 $2" = "group docker" ]; then
  printf 'docker:x:%s:%s\n' "${FAKE_DOCKER_GID}" "${FAKE_DOCKER_MEMBERS}"
elif [ -x /usr/bin/getent ]; then
  exec /usr/bin/getent "$@"
else
  exit 2
fi
EOF
cat >"$stub/ss" <<'EOF'
#!/bin/sh
# ss -Hlntu "sport = :N": a listener on N if N is in FAKE_SS_PORTS
for a in "$@"; do n=${a##*:}; done
case " ${FAKE_SS_PORTS:-} " in *" $n "*) echo "tcp LISTEN 0 4096 127.0.0.53%lo:$n 0.0.0.0:*" ;; esac
EOF
cat >"$stub/findmnt" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_FINDMNT:-/dev/nvme0n1p1}"
EOF
chmod +x "$stub"/*

export FAKE_DOCKER_GID=$gid FAKE_DOCKER_MEMBERS=$me
export FAKE_DOCKER_LOG=$t_tmp/docker.log
export FAKE_DOCKER_POOLS='[{"Base":"10.210.0.0/16","Size":24}]'
export FAKE_DOCKER_DRIVER='[["Backing Filesystem","extfs"],["Supports d_type","true"]]'
export FAKE_DOCKER='case "$*" in
  "compose version --short") echo 2.29.1 ;;
  info) echo ok ;;
  "info --format {{json .DefaultAddressPools}}") echo "$FAKE_DOCKER_POOLS" ;;
  "info --format {{json .DriverStatus}}") echo "$FAKE_DOCKER_DRIVER" ;;
  "info --format {{.ServerVersion}}") echo "${FAKE_DOCKER_VERSION:-29.1.2}" ;;
  inspect\ -f*) echo "running none 0" ;;
  inspect*) exit 1 ;;
esac'
export FAKE_SYSTEMCTL_DIR=$t_tmp/units
export FAKE_SYSTEMCTL='mkdir -p "$FAKE_SYSTEMCTL_DIR"
case $1 in
  is-active) [ "$2" = systemd-resolved ] && [ -n "${FAKE_RESOLVED:-}" ] && { echo active; exit 0; }
    [ "$2" = ufw ] && [ -n "${FAKE_UFW:-}" ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
  is-enabled) if [ -e "$FAKE_SYSTEMCTL_DIR/$2" ]; then echo enabled; else echo disabled; exit 1; fi ;;
  enable) touch "$FAKE_SYSTEMCTL_DIR/$2" ;;
esac
echo "$*" >>"$FAKE_SYSTEMCTL_DIR/log"'
tsjson() { printf '{"BackendState":"Running","Self":{"DNSName":"decolab.%s.ts.net."}}' "$1"; }
export FAKE_TAILSCALE_JSON
FAKE_TAILSCALE_JSON=$(tsjson tail1234)
export INSTALL_SUDO="" INSTALL_ASK=0 INSTALL_HEALTH_WAIT_S=1 INSTALL_SETTLE_S=0 INSTALL_STEP_S=1
export INSTALL_DETECT_HW_FAN=no INSTALL_DETECT_HW_OLED=no INSTALL_DETECT_HW_NVME=no INSTALL_DETECT_HW_UPS=no

# box NAME [SED-EXPR...] - a fresh host: config from the example with
# everything below $t_tmp/NAME; sets B (the box) and the DECOLAB_* paths
box() {
  B=$t_tmp/$1
  shift
  rm -rf "$B"
  mkdir -p "$B/root" "$B/log" "$B/state" "$B/run" "$B/textfile"
  export INSTALL_ROOT=$B/root DECOLAB_LOG_DIR=$B/log DECOLAB_STATE_DIR=$B/state
  export DECOLAB_RUN_DIR=$B/run DECOLAB_TEXTFILE_DIR=$B/textfile DECOLAB_CONF=$B/decolab.conf
  local args=(-e "s#^DECOLAB_USER=.*#DECOLAB_USER=$me#" -e "s#^DECOLAB_DIR=.*#DECOLAB_DIR=$t_root#"
    -e "s#^DATA_DIR=.*#DATA_DIR=$B/data#" -e "s#^SECRETS_DIR=.*#SECRETS_DIR=$B/secrets#"
    -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$B/data/backups#")
  local e
  for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "$t_root/decolab.conf.example" >"$DECOLAB_CONF"
  : >"$FAKE_DOCKER_LOG"
  rm -rf "$FAKE_SYSTEMCTL_DIR"
}
inst() { "$t_root/install.sh" "$@" </dev/null; }
# tree - every file of the box with its checksum and mode (logs aside)
tree() {
  (cd "$B" && find . -path ./log -prune -o -type f -print | sort | while read -r f; do
    printf '%s %s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -c1-16)" "$(find "$f" -prune -perm 600 | wc -l | tr -d ' ')$(find "$f" -prune -perm 644 | wc -l | tr -d ' ')"
  done)
}

echo "dry run with a foreign configuration"
box dry
check "dry run passes" 0 "Dry run: nothing was changed" -- inst --dry-run --fresh
check "  lists the host files" 0 "new       $B/root/etc/tmpfiles.d/decolab.conf" -- printf '%s' "$out"
check "  names the schedules" 0 "$B/root/etc/cron.d/decolab-root" -- printf '%s' "$out"
check "  names the stacks" 0 "pull, then start: core immich vaultwarden uptime-kuma" -- printf '%s' "$out"
check "  plans the secrets" 0 "new       immich.env (generated)" -- printf '%s' "$out"
same "  writes nothing" "$(find "$B/root" "$B/state" -type f | wc -l | tr -d ' ')" 0
check "  creates no secrets directory" 1 "" -- test -e "$B/secrets"
check "  no docker change" 1 "" -- grep -E 'pull|up -d' "$FAKE_DOCKER_LOG"
check "  no log file" 1 "" -- sh -c "ls '$B/log'/install-* 2>/dev/null | grep ."
check "first run needs a mode" 1 "say --fresh" -- inst --dry-run

echo "the checks stop a real run before any change"
box checks
FAKE_DOCKER_GID=4711 FAKE_DOCKER_MEMBERS=nobody check "not in the docker group" 1 "usermod -aG docker $me" -- inst --fresh
FAKE_DOCKER_GID=4711 check "in the group, but not in this session" 1 "log out and in again" -- inst --fresh
same "  nothing written" "$(find "$B/root" "$B/state" -type f | wc -l | tr -d ' ')" 0
check "  no secrets directory" 1 "" -- test -e "$B/secrets"
# hidden from PATH, the fake and a real one alike (an installed host has it)
mv "$stub/arp-scan" "$t_tmp/arp-scan.away"
nopath=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/arp-scan" ] || printf '%s:' "$d"; done)
PATH=${nopath%:} INSTALL_SBIN_PATH="" check "a missing program names the apt command" 1 "sudo apt install arp-scan" -- inst --fresh
mv "$t_tmp/arp-scan.away" "$stub/arp-scan"
mv "$stub/upsd" "$t_tmp/upsd.away"
INSTALL_DETECT_HW_UPS=yes check "UPS found: NUT is needed" 1 "nut-server" -- inst --dry-run --fresh
mv "$t_tmp/upsd.away" "$stub/upsd"
FAKE_TAILSCALE_JSON=$(tsjson tail9999) check "another tailnet" 1 "TAILNET_NAME is tail1234" -- inst --fresh
FAKE_TAILSCALE_JSON='{"BackendState":"Stopped"}' check "Tailscale not connected" 1 "not connected (Stopped)" -- inst --fresh
INSTALL_DETECT_HW_NVME=yes FAKE_FINDMNT=/dev/mmcblk0p2 check "NVMe there, data disk not mounted" 1 "not on the NVMe disk" -- inst --fresh
FAKE_DOCKER_VERSION=27.5.1 check "Docker 27: stop" 1 "Docker 27.5.1 is too old: 28 or newer" -- inst --fresh
FAKE_DOCKER_POOLS=null check "Docker without DOCKER_ADDRESS_POOL: stop" 1 "Docker does not number its networks from DOCKER_ADDRESS_POOL (10.210.0.0/16)" -- inst --fresh
FAKE_DOCKER_POOLS='[{"Base":"10.99.0.0/16","Size":24}]' check "  ... nor with another pool" 1 "does not number its networks" -- inst --fresh
check "  with it: fine" 0 "Docker numbers its networks from 10.210.0.0/16" -- inst --dry-run --fresh
FAKE_DOCKER_DRIVER='[["driver-type","io.containerd.snapshotter.v1"]]' check "Docker with containerd's image store: stop" 1 "cAdvisor would see no container" -- inst --fresh
check "  the classic store: fine" 0 "Docker keeps images in its classic store" -- inst --dry-run --fresh
FAKE_SS_PORTS=53 FAKE_RESOLVED=1 check "port 53 held by systemd-resolved: stop" 1 "systemd-resolved's stub listener" -- inst --fresh
FAKE_SS_PORTS=445 check "port 445 held by another program: stop" 1 "port 445 is in use" -- inst --fresh
FAKE_SS_PORTS=53 FAKE_DOCKER='case "$*" in "compose version --short") echo 2.29.1 ;; info) echo ok ;; "info --format {{json .DefaultAddressPools}}") echo "$FAKE_DOCKER_POOLS" ;; "info --format {{json .DriverStatus}}") echo "$FAKE_DOCKER_DRIVER" ;; "info --format {{.ServerVersion}}") echo 29.1.2 ;;
  "ps -q --filter publish=53") echo abc123 ;; inspect\ -f*) echo "running none 0" ;; inspect*) exit 1 ;; esac' \
  check "  ... by Decolab's own Pi-hole: fine" 0 "" -- inst --dry-run --fresh
INSTALL_DETECT_HW_NVME=yes check "  mounted: fine" 0 "is on the NVMe disk (/dev/nvme0n1p1)" -- inst --dry-run --fresh
box hard 's/^HARDENING=.*/HARDENING=yes/'
FAKE_UFW=1 check "HARDENING=yes with UFW active: stop" 1 "but ufw is active" -- inst --fresh
check "HARDENING=yes: files in place, firewall left to a trial" 0 "sudo $t_root/bin/decolab-firewall apply" -- inst --fresh
check "  the way back is installed" 0 "" -- test -x "$B/root/usr/local/sbin/decolab-firewall-boot"
check "  the unit is there" 0 "" -- test -f "$B/root/etc/systemd/system/decolab-firewall.service"
check "  ... but install.sh does not enable it" 1 "" -- test -e "$FAKE_SYSTEMCTL_DIR/decolab-firewall.service"
check "  no SSH drop-in from install.sh" 1 "" -- sh -c "ls '$B/root/etc/ssh/sshd_config.d/' 2>/dev/null | grep ."
check "  no rules loaded by install.sh" 1 "" -- grep -q "^nft" "$t_tmp/host.log"
box tg 's/^NOTIFY=.*/NOTIFY=telegram/'
check "Telegram without a terminal: say how" 1 "telegram.env missing: create it" -- inst --fresh
check "  the dry run would ask" 0 "the bot token and chat id are asked for" -- inst --dry-run --fresh
box pg
mkdir -p "$B/data/immich/postgres" && : >"$B/data/immich/postgres/PG_VERSION"
check "a database without its password: stop" 1 "would not open it" -- inst --fresh
# The checkout itself: only root and the user may change what root runs.
co=$t_tmp/checkout
mkdir -p "$co" && (cd "$t_root" && tar cf - --exclude .git .) | (cd "$co" && tar xf -)
box co "s#^DECOLAB_DIR=.*#DECOLAB_DIR=$co#"
chmod o+w "$co/scripts"
check "scripts writable by others: stop" 1 "only root and $me may change it" -- "$co/install.sh" --dry-run --fresh
chmod o-w "$co/scripts"
# Group write: only harmless for a private group (Debian 13's umask 0002).
# Here the group is a shared one (macOS: staff), so it must stop.
chmod g+w "$co/scripts/backup.sh"
if [ "$(id -gn)" != "$me" ]; then
  check "a script writable by a shared group: stop" 1 "backup.sh (writable by others)" -- "$co/install.sh" --dry-run --fresh
fi
chmod g-w "$co/scripts/backup.sh"
chmod g+w "$co"
if [ "$(id -gn)" != "$me" ]; then
  check "the checkout writable by a shared group: stop" 1 "checkout(writable)" -- "$co/install.sh" --dry-run --fresh
fi
chmod g-w "$co"
check "  fixed: fine" 0 "only root and $me can change it" -- "$co/install.sh" --dry-run --fresh
check "run from another checkout" 1 "but DECOLAB_DIR is $co" -- inst --dry-run --fresh

echo "a fresh installation"
box fresh 's#^USB_BACKUP_DIR=.*#USB_BACKUP_DIR=/media/usb#' 's#^RESTIC_REPOSITORY=.*#RESTIC_REPOSITORY=/srv/restic#'
check "runs" 0 "change(s)" -- inst --fresh
first=$out
for f in compose-secrets.env samba_password panel-token immich.env vaultwarden.env restic-password runtime.env; do
  check "  $f is there, mode 600" 0 "" -- sh -c "[ -n \"\$(find '$B/secrets/$f' -perm 600)\" ]"
done
check "  no nut.env without a UPS" 1 "" -- test -e "$B/secrets/nut.env"
check "  Immich login complete" 0 "" -- grep -qE '^DB_PASSWORD=[A-Za-z0-9]{32}$' "$B/secrets/immich.env"
check "  Vaultwarden keeps only the hash, quoted for Compose" 0 "" -- grep -qE "^ADMIN_TOKEN='[\$]argon2id[\$]" "$B/secrets/vaultwarden.env"
check "  the plain admin token is for the user" 0 "password manager" -- printf '%s' "$first"
check "  restic password: to the emergency sheet" 0 "emergency sheet" -- printf '%s' "$first"
check "  panel token: 48 random characters" 0 "" -- grep -qE '^[A-Za-z0-9]{48}$' "$B/secrets/panel-token"
check "  ... and where to find it" 0 "$B/secrets/panel-token" -- printf '%s' "$first"
check "  the panel is enabled and started" 0 "" -- grep -qx "enable decolab-panel.service --now" "$FAKE_SYSTEMCTL_DIR/log"
check "  ... its unit rendered with the LAN" 0 "" -- grep -qx "IPAddressAllow=localhost $(sed -n 's/^LAN_SUBNET=//p' "$DECOLAB_CONF")" "$B/root/etc/systemd/system/decolab-panel.service"
check "  the restart message reports a firewall that failed to load" 0 "systemctl is-failed -q decolab-firewall.service || exit 0; exec $t_root/bin/decolab-notify" -- cat "$B/root/etc/systemd/system/decolab-boot-notify.service"
check "  runtime.env measured" 0 "" -- grep -qx "VAULTWARDEN_DOMAIN=decolab.tail1234.ts.net" "$B/secrets/runtime.env"
check "  every manifest line for this host is placed" 0 "" -- test -f "$B/root/etc/cron.d/decolab-root"
check "  templates rendered" 0 "" -- grep -q "^30 3 \* \* \* $me $t_root/scripts/verify-backup.sh" "$B/root/etc/cron.d/decolab"
check "  samba.yml in SECRETS_DIR" 0 "" -- grep -q "$me" "$B/secrets/samba.yml"
check "  no hardware files without hardware" 1 "" -- test -e "$B/root/etc/nut/ups.conf"
check "  every written file recorded" 0 "" -- test "$(wc -l <"$B/state/installed.tsv")" -ge 10
check "  Kuma's networks" 0 "" -- grep -q "name: decolab-immich_default" "$B/state/compose.networks.yml"
check "  data directories" 0 "" -- test -d "$B/data/uptime-kuma" -a -d "$B/data/immich/library" -a -d "$B/data/vaultwarden"
check "  root's logs created by the user" 0 "" -- test -f "$B/log/device-watch.log"
check "  everything pulled before anything starts" 0 "" -- awk '/ pull /{p=NR} / up -d /{if(!u)u=NR} END{exit !(p && u && p < u)}' "$FAKE_DOCKER_LOG"
check "  Kuma started last" 0 "" -- sh -c "grep ' up -d ' '$FAKE_DOCKER_LOG' | tail -1 | grep -q uptime-kuma"
check "  Immich gets its login" 0 "" -- grep -q "env-file $B/secrets/immich.env .*stacks/immich/compose.yml" "$FAKE_DOCKER_LOG"
check "  the watchdog last" 0 "" -- sh -c "tail -1 '$FAKE_SYSTEMCTL_DIR/log' | grep -q 'enable decolab-watchdog.timer --now'"
check "  mode remembered" 0 "" -- grep -qx fresh "$B/state/install-mode"
check "  todo: Kuma monitors with names" 0 "PROBE_VAULTWARDEN_OFFSITE" -- printf '%s' "$first"

echo "a registry that refuses for a moment"
# the first FAKE_PULL_FAILS pulls fail, as Docker Hub's rate limit does
pullfake='case "$*" in *" pull --quiet") n=$(wc -l <"$PULLS" | tr -d " "); echo x >>"$PULLS"
  [ "$n" -ge "$FAKE_PULL_FAILS" ] || { echo "toomanyrequests" >&2; exit 1; } ;; esac'
export PULLS=$t_tmp/pulls INSTALL_PULL_PAUSE_S=0
box pullretry
: >"$PULLS"
FAKE_PULL_FAILS=2 FAKE_DOCKER="$FAKE_DOCKER
$pullfake" check "refused twice, then fine: installed" 0 "pulling core failed: attempt 3 of 3" -- inst --fresh
check "  ... and started" 0 "" -- grep -q " up -d " "$FAKE_DOCKER_LOG"
box pullfail
: >"$PULLS"
FAKE_PULL_FAILS=99 FAKE_DOCKER="$FAKE_DOCKER
$pullfake" check "refused three times: error" 1 "pulling core failed 3 times: nothing started" -- inst --fresh
check "  ... nothing started" 1 "" -- grep -q " up -d " "$FAKE_DOCKER_LOG"
check "  todo: mark the USB disk" 0 ".decolab-usb-backup" -- printf '%s' "$first"
log=$(find "$B/log" -name 'install-*.log' | head -1)
check "  a log of the run" 0 "" -- test -s "$log"
leak=""
for f in "$B"/secrets/*; do
  [ "${f##*/}" != runtime.env ] || continue # measured ids and a host name, no secret
  while IFS= read -r line; do
    v=${line#*=} v=${v#\'} v=${v%\'}
    [ ${#v} -ge 12 ] || continue
    grep -qF -- "$v" "$log" && leak="$leak ${f##*/}"
  done <"$f"
done
same "  no secret in the log" "$leak" ""

echo "a second run changes nothing"
before=$(tree)
check "runs" 0 "0 change(s)" -- inst
same "  same files, same content, same modes" "$(tree)" "$before"
check "  not a single new or update line" 1 "" -- sh -c "printf '%s' \"\$1\" | grep -E '^  (new|update|write|enabled) '" _ "$out"

echo "Immich's regenerated folders after a restore"
lib=$B/data/immich/library
check "fresh: no folder of Immich's made up" 1 "" -- test -e "$lib/thumbs"
mkdir -p "$lib/upload" "$lib/thumbs" && : >"$lib/upload/.immich"
check "photos back: the missing folders with markers" 0 "new       $lib/encoded-video (with .immich)" -- inst
check "  ... all three" 0 "" -- test -f "$lib/encoded-video/.immich" -a -f "$lib/backups/.immich"
check "  an existing folder is left alone" 1 "" -- test -e "$lib/thumbs/.immich"
check "  a second run: nothing" 0 "0 change(s)" -- inst
rm -rf "$lib/upload" "$lib/thumbs" "$lib/encoded-video" "$lib/backups"

echo "files changed on the host are kept"
lr=$B/root/etc/logrotate.d/decolab
echo "# my own line" >>"$lr"
mine=$(shasum <"$lr")
check "a changed file: exit 2" 2 "KEPT      $lr: changed on this host" -- inst
check "  the difference is shown" 0 "-# my own line" -- printf '%s' "$out"
same "  and the file untouched" "$(shasum <"$lr")" "$mine"
check "  named in the summary" 0 "kept because changed on this host: $lr" -- printf '%s' "$out"
# The repository changed a file that is still as install.sh wrote it: as if
# an older version were installed and recorded.
tf=$B/root/etc/tmpfiles.d/decolab.conf
echo "# older release" >"$tf"
awk -F'\t' -v d="$tf" -v h="$(shasum -a 256 <"$tf" | cut -d' ' -f1)" 'BEGIN{OFS="\t"} $1 == d { $2 = h } { print }' \
  "$B/state/installed.tsv" >"$B/state/x" && mv "$B/state/x" "$B/state/installed.tsv"
check "an untouched file is updated" 2 "update    $tf (the old one: $tf.decolab-old)" -- inst
check "  the old one kept" 0 "" -- grep -q "older release" "$tf.decolab-old"
check "  the new one in place" 0 "" -- grep -q "^d /run/decolab" "$tf"
: >"$t_tmp/host.log"
check "  a run without change" 2 "" -- inst
check "    ... not without one" 1 "" -- grep -q systemd-tmpfiles "$t_tmp/host.log"
echo "# older release" >"$tf"
awk -F'\t' -v d="$tf" -v h="$(shasum -a 256 <"$tf" | cut -d' ' -f1)" 'BEGIN{OFS="\t"} $1 == d { $2 = h } { print }' \
  "$B/state/installed.tsv" >"$B/state/x" && mv "$B/state/x" "$B/state/installed.tsv"
inst >/dev/null
check "    ... but after one" 0 "" -- grep -q "systemd-tmpfiles --create $B/root/etc/tmpfiles.d/decolab.conf" "$t_tmp/host.log"

echo "sudoers are checked by visudo"
box sudo
INSTALL_DETECT_HW_NVME=yes FAKE_VISUDO_BAD=staged_etc_sudoers.d_decolab-nvme check "rejected: not installed" 1 "visudo rejects it; not installed" -- inst --fresh
check "  no sudoers file" 1 "" -- test -e "$B/root/etc/sudoers.d/decolab-nvme"
INSTALL_DETECT_HW_NVME=yes check "accepted: installed 0440" 0 "new       $B/root/etc/sudoers.d/decolab-nvme" -- inst
check "  mode 440" 0 "" -- sh -c "[ -n \"\$(find '$B/root/etc/sudoers.d/decolab-nvme' -perm 440)\" ]"
INSTALL_DETECT_HW_UPS=yes check "with a UPS: NUT files and password" 0 "new       $B/root/etc/nut/upsmon.conf" -- inst
ups=$out
upw=$(sed 's/.*=//' "$B/secrets/nut.env")
check "  the UPS password is not in the output" 1 "" -- grep -qF -- "$upw" <<<"$ups"
check "  upsmon.conf 640" 0 "" -- sh -c "[ -n \"\$(find '$B/root/etc/nut/upsmon.conf' -perm 640)\" ]"
echo "# mine" >>"$B/root/etc/nut/upsd.users"
INSTALL_DETECT_HW_UPS=yes check "  a changed file with a password: kept, no difference shown" 2 "difference not shown: the file holds a password" -- inst
check "  ... really not shown" 1 "" -- grep -qF -- "$upw" <<<"$out"
check "  rendered with it" 0 "" -- grep -q "upsmon $(sed 's/.*=//' "$B/secrets/nut.env") primary" "$B/root/etc/nut/upsmon.conf"

echo "restore mode"
box rest
check "secrets missing: restore them first" 1 "restore $B/secrets from the backup first" -- inst --restore
check "  nothing written" 1 "" -- test -e "$B/secrets"
mkdir -p "$B/secrets" && chmod 700 "$B/secrets"
printf 'DB_PASSWORD=restored\nDB_USERNAME=immich\nDB_DATABASE_NAME=immich\n' >"$B/secrets/immich.env"
chmod 600 "$B/secrets/immich.env"
check "secrets back: the host is set up" 0 "restore the data (RESTORE.md), then ./install.sh --restore-done" -- inst --restore
check "  the restored password stays" 0 "" -- grep -qx DB_PASSWORD=restored "$B/secrets/immich.env"
check "  no schedule yet" 1 "" -- test -e "$B/root/etc/cron.d/decolab"
check "  no root schedule yet" 1 "" -- test -e "$B/root/etc/cron.d/decolab-root"
check "  nothing started" 1 "" -- grep -E 'pull|up -d' "$FAKE_DOCKER_LOG"
check "  no watchdog" 1 "" -- test -e "$FAKE_SYSTEMCTL_DIR/decolab-watchdog.timer"
check "a fresh run on it is refused" 1 "set up with --restore" -- inst --fresh
check "--restore-done starts it all" 0 "" -- inst --restore-done
check "  now the schedules" 0 "" -- test -f "$B/root/etc/cron.d/decolab-root" -a -f "$B/root/etc/cron.d/decolab"
check "  and the stacks" 0 "" -- grep -q 'up -d' "$FAKE_DOCKER_LOG"
check "  and the watchdog" 0 "" -- test -e "$FAKE_SYSTEMCTL_DIR/decolab-watchdog.timer"
check "  confirmed for later runs" 0 "" -- test -f "$B/state/restore-confirmed"
check "  later runs need no flag" 0 "0 change(s)" -- inst

echo "Uptime Kuma monitors"
box mon 's#^USB_BACKUP_DIR=.*#USB_BACKUP_DIR=/media/usb#' 's#^RESTIC_REPOSITORY=.*#RESTIC_REPOSITORY=/srv/restic#'
all=$(INSTALL_DETECT_HW_NVME=yes INSTALL_DETECT_HW_UPS=yes inst --list-monitors | sort)
pushed=$(cd "$t_root" && {
  grep -ohE 'CHECK_MONITOR=[A-Z_]+|kuma_push [A-Z_]+|probe_init [a-z-]+ [A-Z_]+' scripts/*.sh lib/*.sh | sed 's/.* //; s/.*=//'
  grep -ohE 'monitor=[A-Z_]+' scripts/restore-probe-vaultwarden*.sh | sed 's/.*=//'
} | sort -u)
same "every monitor a script pushes to is listed" "$(comm -23 <(printf '%s\n' "$pushed") <(printf '%s\n' "$all"))" ""
same "  and nothing else" "$(comm -13 <(printf '%s\n' "$pushed") <(printf '%s\n' "$all"))" ""
box mon2 's/^MODULE_IMMICH=.*/MODULE_IMMICH=no/'
check "a module off: its monitors are not asked for" 1 "" -- sh -c "'$t_root/install.sh' --list-monitors | grep IMMICH"

t_finish
