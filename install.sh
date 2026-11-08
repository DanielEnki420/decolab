#!/usr/bin/env bash
# install.sh - set Decolab up on this host, or say what it would do.
#
#   ./install.sh --dry-run --fresh   check everything and show the plan; no
#                                    change, no sudo, no secret generated
#   ./install.sh --fresh             first installation: nothing to restore
#   ./install.sh --restore           rebuild from a backup (RESTORE.md): sets
#                                    the host up, starts nothing
#   ./install.sh --restore-done      the data is back and checked: start the
#                                    stacks and the schedules
#   ./install.sh                     every later run (the mode is remembered)
#
# Run it as DECOLAB_USER from DECOLAB_DIR, after copying decolab.conf.example
# to decolab.conf and adjusting it. It asks for sudo once, for the host files.
#
# What it never does, on purpose:
#   - install packages, Docker or Tailscale, or change group memberships: it
#     names what is missing and the command for it, then stops. Installing
#     Docker means running a vendor's script; that is your decision.
#   - touch SSH or the firewall. HARDENING=yes puts the files in place; the
#     firewall and the SSH drop-in come with bin/decolab-firewall apply, on
#     trial, with a way back. So SSH works after install.sh exactly as before.
#   - overwrite a file someone changed. Every file it writes is recorded with
#     its checksum ($DECOLAB_STATE_DIR/installed.tsv). A file still as written
#     is updated when the repository changes it, and the old one is kept as
#     FILE.decolab-old. A file changed on this host stays; install.sh shows
#     the difference and ends with exit code 2.
#   - generate a secret that data on this host depends on: a new database
#     password does not open a restored database. Missing secrets in restore
#     mode are an error; restore SECRETS_DIR from the backup first.
#   - start anything on a host that is waiting for its restore: the nightly
#     backup and the USB mirror would overwrite the good copies with an empty
#     system. Stacks, schedules and the watchdog come last, and only in fresh
#     mode or after --restore-done.
#
# Order: every check first (nothing changes if one fails), then secrets,
# host files, directories, services, stacks, and last the schedules and the
# watchdog. Running it again changes nothing that is in order.
#
# Exit codes: 0 done, 1 stopped by a check (nothing changed), 2 done, but
# files changed on this host were kept (see the summary).
#
# Test hooks, never needed on a real host: INSTALL_ROOT (prefix for every
# host path), INSTALL_SUDO (default "sudo"), INSTALL_DETECT_HW_FAN|HW_OLED|
# HW_NVME|HW_UPS (yes|no instead of detecting), INSTALL_ASK=0 (never ask).
# Compatible with bash 3.2 (macOS, for the tests) and bash 5 (Debian).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
# Debian keeps visudo, sysctl, upsd ... in sbin, which a user's PATH lacks.
# INSTALL_SBIN_PATH: for the tests, which must hide programs a host has
PATH=$PATH:${INSTALL_SBIN_PATH-/usr/local/sbin:/usr/sbin:/sbin}

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# A real run keeps its whole output as a log (no secret is ever printed:
# tokens are read without echo, differences of files with passwords are not
# shown). The prompts still reach the terminal: only stdout goes through tee.
if [ -z "${DECOLAB_INSTALL_LOG:-}" ]; then
  case " $* " in *" --dry-run "* | *" -h "* | *" --help "* | *" --list-monitors "*) ;; *)
    DECOLAB_INSTALL_LOG=$(mktemp "${TMPDIR:-/tmp}/decolab-install-log.XXXXXX") || exit 1
    export DECOLAB_INSTALL_LOG
    "$0" ${1+"$@"} 2>&1 | tee "$DECOLAB_INSTALL_LOG"
    rc=${PIPESTATUS[0]}
    logdir=${DECOLAB_LOG_DIR:-/var/log/decolab}
    if [ -d "$logdir" ] && [ -w "$logdir" ]; then
      cp "$DECOLAB_INSTALL_LOG" "$logdir/install-$(date +%Y%m%d-%H%M%S).log" && chmod 640 "$logdir"/install-*.log
    fi
    rm -f "$DECOLAB_INSTALL_LOG"
    exit "$rc" ;;
  esac
fi
dry=0 want_mode="" restore_done=0 list_monitors=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --fresh) want_mode=fresh ;;
    --restore) want_mode=restore ;;
    --restore-done) restore_done=1 ;;
    --list-monitors) list_monitors=1 ;; # the Kuma push monitors this config needs
    -h | --help) usage && exit 0 ;;
    *) echo "unknown argument: $1" >&2 && usage >&2 && exit 1 ;;
  esac
  shift
done
[ "$(id -u)" != 0 ] || { echo "Run install.sh as the Decolab user, not as root: it asks for sudo itself." >&2; exit 1; }

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
if ! decolab_config_load "$DECOLAB_CONF"; then
  echo "$DECOLAB_CONF is invalid: fix the lines above (bin/decolab-config check $DECOLAB_CONF)." >&2
  exit 1
fi
# shellcheck source=lib/compose.sh
. "$here/lib/compose.sh"

hostroot=${INSTALL_ROOT:-}
sudo=${INSTALL_SUDO-sudo}
ask=1
[ -t 0 ] || ask=0
[ "${INSTALL_ASK:-1}" != 0 ] || ask=0
[ "${INSTALL_ASK:-}" != always ] || ask=1 # tests: answers from a pipe
me=$(id -un)
work=$(mktemp -d "${TMPDIR:-/tmp}/decolab-install.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# --- output ------------------------------------------------------------------
# Lists are newline-separated strings: bash 3.2 cannot expand an empty array
# under set -u.
blockers="" todos="" kept="" changed=0
section() { printf '\n== %s ==\n' "$*"; }
item() { printf '  %-9s %s\n' "$1" "$2"; }
block() {
  blockers="$blockers$1"$'\n'
  item STOP "$1"
}
todo() { todos="$todos$1"$'\n'; }
# would WHAT - in a dry run, say it; otherwise do nothing (the caller acts)
would() { [ "$dry" = 1 ] && item would "$1"; }

as_root() {
  if [ -n "$sudo" ]; then $sudo "$@"; else "$@"; fi
}

# read_any FILE - also files only root may read
read_any() {
  if [ -r "$1" ]; then cat "$1"; else as_root cat "$1" 2>/dev/null; fi
}

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# perm_is PATH MODE - true if PATH has exactly MODE (find: GNU and BSD)
perm_is() { [ -n "$(find "$1" -prune -perm "$2" 2>/dev/null)" ]; }

# --- hardware ----------------------------------------------------------------
# detect HW_X - is the hardware there? (for HW_X=auto; called by hw_wanted)
# shellcheck disable=SC2329
detect() {
  local v
  eval "v=\${INSTALL_DETECT_$1:-}"
  case $v in yes) return 0 ;; no) return 1 ;; esac
  case $1 in
    HW_FAN) grep -qx pwmfan /sys/class/hwmon/hwmon*/name 2>/dev/null ;;
    HW_OLED) [ -e /dev/i2c-1 ] && i2cdetect -y 1 0x3c 0x3c 2>/dev/null | grep ' 3c' >/dev/null ;;
    HW_NVME) [ -b /dev/nvme0n1 ] ;;
    # Eaton/MGE, APC, CyberPower, Tripp Lite, Phoenixtec: USB HID UPSes
    HW_UPS) lsusb 2>/dev/null | grep -iE 'ID (0463|051d|0764|09ae|06da):' >/dev/null ;;
    *) return 1 ;;
  esac
}
wanted() { hw_wanted "$1" detect "$1"; }

hw_list=""
for h in HW_FAN HW_OLED HW_NVME HW_UPS; do
  if wanted "$h"; then hw_list="$hw_list $h"; fi
done

# kuma_monitors - the push monitors this installation reports to (each a
# KUMA_<NAME> token in kuma-push.env). tests/test-install.sh checks that every
# name a script pushes to is in here.
kuma_monitors() {
  printf '%s\n' MONITOR SAMBA DNSSEC PIHOLE PORTAINER PROMETHEUS PERSES CADVISOR \
    BACKUP VERIFY UPDATES PROBE_PIHOLE PROBE_KUMA
  is_yes MODULE_IMMICH && printf '%s\n' IMMICH PROBE_IMMICH
  is_yes MODULE_VAULTWARDEN && echo PROBE_VAULTWARDEN
  [ -z "$USB_BACKUP_DIR" ] || echo USB
  if [ -n "$RESTIC_REPOSITORY" ]; then
    printf '%s\n' OFFSITE RESTIC
    is_yes MODULE_VAULTWARDEN && echo PROBE_VAULTWARDEN_OFFSITE
  fi
  case " $hw_list " in *" HW_NVME "*) echo NVME ;; esac
  case " $hw_list " in *" HW_UPS "*) echo UPS ;; esac
  return 0
}
[ "$list_monitors" = 0 ] || { kuma_monitors && exit 0; }

# --- mode --------------------------------------------------------------------
mode_file=$DECOLAB_STATE_DIR/install-mode
confirmed=$DECOLAB_STATE_DIR/restore-confirmed
saved_mode=$(cat "$mode_file" 2>/dev/null)
mode=${want_mode:-$saved_mode}
[ "$restore_done" = 0 ] || mode=${mode:-restore}

printf 'Decolab install%s on %s as %s\n' "$([ "$dry" = 1 ] && echo ' (dry run: nothing is changed)')" \
  "$(hostname -s 2>/dev/null || echo host)" "$me"
section "Checks"
if [ -z "$mode" ]; then
  block "first run: say --fresh (nothing to restore) or --restore (rebuild from a backup, RESTORE.md)"
elif [ -n "$saved_mode" ] && [ -n "$want_mode" ] && [ "$saved_mode" != "$want_mode" ]; then
  block "this host was set up with --$saved_mode; --$want_mode would mix both (remove $mode_file only if you are sure)"
elif [ "$restore_done" = 1 ] && [ "$mode" != restore ]; then
  block "--restore-done belongs to a restore; this host was set up with --$mode"
else
  item ok "mode: $mode$([ "$mode" = restore ] && { [ -f "$confirmed" ] || [ "$restore_done" = 1 ]; } && echo ', restore confirmed')"
fi
late_ok=0
if [ "$mode" = fresh ] || [ -f "$confirmed" ] || [ "$restore_done" = 1 ]; then late_ok=1; fi

# --- checks: who and where ---------------------------------------------------
[ "$me" = "$DECOLAB_USER" ] || block "running as $me, but DECOLAB_USER is $DECOLAB_USER"
# shellcheck disable=SC2153 # set by decolab_config_load
target=$(cd "$DECOLAB_DIR" 2>/dev/null && pwd -P)
[ "$here" = "$target" ] || block "this checkout is $here, but DECOLAB_DIR is $DECOLAB_DIR"

# Root runs scripts from this checkout (cron.d-decolab-root, the watchdog).
# Harmless while only root and DECOLAB_USER can change them (the user is in
# the docker group, which is root already); a hole as soon as anyone else can.
# Group write is harmless only for a private group: named like the user, no
# members, nobody else's primary group (Debian 13 gives new files g+w,
# umask 0002, so a fresh clone has it). Any other group: a hole.
pgroup=$(id -gn "$DECOLAB_USER" 2>/dev/null)
pgid=$(id -g "$DECOLAB_USER" 2>/dev/null)
if [ "$pgroup" != "$DECOLAB_USER" ] || ! command -v getent >/dev/null 2>&1 ||
  [ -n "$(getent group "$pgroup" | cut -d: -f4)" ] ||
  [ "$(getent passwd | awk -F: -v g="$pgid" '$4 == g' | wc -l | tr -d ' ')" != 1 ]; then
  pgroup="" # not private: group write counts like world write
fi
group_writable() { # PATH - writable by a group other than the private one
  perm_is "$1" -020 && { [ -z "$pgroup" ] || [ -z "$(find "$1" -prune -group "$pgroup" 2>/dev/null)" ]; }
}
d=$here bad=""
while :; do
  if [ -z "$(find "$d" -prune \( -user root -o -user "$DECOLAB_USER" \) 2>/dev/null)" ]; then
    bad="$bad $d(owner)"
  fi
  if group_writable "$d" || perm_is "$d" -002; then
    # /tmp and the like are fine only with the sticky bit, and never for the checkout itself
    if [ "$d" = "$here" ] || ! perm_is "$d" -1000; then bad="$bad $d(writable)"; fi
  fi
  [ "$d" = / ] && break
  d=$(dirname "$d")
done
if [ -n "$pgroup" ]; then gw=(\( -perm -020 ! -group "$pgroup" \)); else gw=(-perm -020); fi
w=$(find "$here/scripts" "$here/bin" "$here/lib" "$here/services" "$here/install.sh" \( "${gw[@]}" -o -perm -002 \) -print 2>/dev/null | head -3 | tr '\n' ' ')
[ -z "$w" ] || bad="$bad $w(writable by others)"
if [ -n "$bad" ]; then
  block "root runs scripts from $here, so only root and $DECOLAB_USER may change it:$bad"
else
  item ok "$here: only root and $DECOLAB_USER can change it"
fi

# --- checks: programs --------------------------------------------------------
missing="" missing_cmds=""
need() { # COMMAND PACKAGE
  command -v "$1" >/dev/null 2>&1 && return 0
  case " $missing " in *" $2 "*) ;; *) missing="$missing $2" ;; esac
  missing_cmds="$missing_cmds $1"
}
for c in python3:python3 curl:curl flock:util-linux timeout:coreutils git:git sudo:sudo \
  visudo:sudo logrotate:logrotate arp-scan:arp-scan unattended-upgrade:unattended-upgrades; do
  need "${c%%:*}" "${c#*:}"
done
[ -z "$USB_BACKUP_DIR" ] || need rsync rsync
[ -z "$RESTIC_REPOSITORY" ] || need restic restic
is_yes SPEEDTEST && need librespeed-cli librespeed-cli
is_yes MODULE_VAULTWARDEN && need argon2 argon2
is_yes HARDENING && need nft nftables
case " $hw_list " in *" HW_UPS "*) need upsc nut-client && need upsd nut-server ;; esac
case " $hw_list " in *" HW_NVME "*) need nvme nvme-cli ;; esac
case " $hw_list " in *" HW_OLED "*)
  python3 -I -c 'import luma.oled, PIL' 2>/dev/null || { missing="$missing python3-luma.oled python3-pil" && missing_cmds="$missing_cmds luma.oled"; } ;;
esac
if [ -n "$missing" ]; then
  block "missing:$missing_cmds. Install them with:  sudo apt install$missing"
else
  item ok "programs"
fi

# Docker: never installed here (see the top).
if ! command -v docker >/dev/null 2>&1; then
  block "Docker is not installed: https://docs.docker.com/engine/install/debian/ (then log in again)"
else
  dgid=$(getent group docker 2>/dev/null | cut -d: -f3)
  if [ -z "$dgid" ]; then
    block "there is no docker group: is Docker installed completely?"
  elif ! id -G | tr ' ' '\n' | grep -x "$dgid" >/dev/null; then
    if getent group docker | cut -d: -f4 | tr ',' '\n' | grep -x "$me" >/dev/null; then
      block "$me is in the docker group, but this session started before: log out and in again"
    else
      block "$me is not in the docker group:  sudo usermod -aG docker $me  then log out and in again"
    fi
  elif ! docker info >/dev/null 2>&1; then
    block "Docker does not answer (sudo systemctl status docker)"
  else
    v=$(docker compose version --short 2>/dev/null)
    if [ -z "$v" ]; then
      block "the Docker Compose plugin is missing:  sudo apt install docker-compose-plugin"
    elif ! python3 -I -c 'import sys
v = [int(x) for x in sys.argv[1].lstrip("v").split("-")[0].split(".")[:2]]
sys.exit(0 if v >= [2, 20] else 1)' "$v" 2>/dev/null; then
      block "Docker Compose $v is too old: 2.20 or newer is needed"
    else
      item ok "Docker, Compose $v, $me in the docker group"
    fi
    # Before 28.0 a neighbour in the LAN could reach ports published on
    # 127.0.0.1 (Prometheus, Perses, Vaultwarden): Docker's docs, port publishing.
    dv=$(docker info --format '{{.ServerVersion}}' 2>/dev/null)
    if python3 -I -c 'import sys
sys.exit(0 if int(sys.argv[1].split(".")[0]) >= 28 else 1)' "$dv" 2>/dev/null; then
      item ok "Docker $dv"
    else
      block "Docker ${dv:-?} is too old: 28 or newer is needed (before, the LAN could reach ports bound to 127.0.0.1). Docker's own repository: INSTALL.md, step 2"
    fi
    # Docker's own pool (172.17-172.31) holds Decolab's fixed networks: a
    # network it numbers itself can take their range first, and the stack
    # with the fixed network does not start (seen on a fresh install).
    case $(docker info --format '{{json .DefaultAddressPools}}' 2>/dev/null) in
      *"\"$DOCKER_ADDRESS_POOL\""*) item ok "Docker numbers its networks from $DOCKER_ADDRESS_POOL" ;;
      *) block "Docker does not number its networks from DOCKER_ADDRESS_POOL ($DOCKER_ADDRESS_POOL): set it in /etc/docker/daemon.json (INSTALL.md, step 2)" ;;
    esac
    # cAdvisor finds containers through Docker's classic store; with
    # containerd's store it would need containerd's socket (root).
    case $(docker info --format '{{json .DriverStatus}}' 2>/dev/null) in
      *io.containerd.snapshotter*) block "Docker keeps images in containerd's store: cAdvisor would see no container. Switch it off in /etc/docker/daemon.json (INSTALL.md, step 2)" ;;
      *) item ok "Docker keeps images in its classic store" ;;
    esac
  fi
fi

# --- checks: data disk, Tailscale, settings ---------------------------------
# The data disk must really be mounted: an unmounted /mnt/data is an empty
# directory on the SD card, and Decolab would start fresh on it.
case " $hw_list " in *" HW_NVME "*)
  d=$DATA_DIR
  while [ ! -e "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
  src=$(findmnt -no SOURCE -T "$d" 2>/dev/null)
  case $src in
    */nvme*) item ok "DATA_DIR $DATA_DIR is on the NVMe disk ($src)" ;;
    *) block "DATA_DIR $DATA_DIR is not on the NVMe disk (it is on ${src:-unknown}): mount it first, or set HW_NVME=no" ;;
  esac ;;
esac

vw_domain=""
if is_yes TAILSCALE; then
  ts=$(tailscale status --json 2>/dev/null | python3 -I -c 'import json, sys
try:
    s = json.load(sys.stdin)
    print(s.get("BackendState", ""), s.get("Self", {}).get("DNSName", "").rstrip("."))
except Exception:
    print("")')
  # shellcheck disable=SC2086 # two words, split on purpose
  set -- $ts
  state=${1:-} dns=${2:-}
  if ! command -v tailscale >/dev/null 2>&1; then
    block "TAILSCALE=yes, but Tailscale is not installed: https://tailscale.com/download/linux"
  elif [ "$state" != Running ]; then
    block "Tailscale is not connected (${state:-no answer}): sudo tailscale up"
  else
    case $dns in
      *".$TAILNET_NAME.ts.net")
        item ok "Tailscale: $dns"
        vw_domain=$dns ;;
      *) block "this host is $dns in Tailscale, but TAILNET_NAME is $TAILNET_NAME" ;;
    esac
  fi
fi

# HARDENING=yes: install.sh only puts the files in place. The firewall
# itself is switched on by hand, on trial, with bin/decolab-firewall apply:
# only a new login can prove it lets you in (see there).
if is_yes HARDENING; then
  for u in ufw firewalld; do
    [ "$(systemctl is-active "$u" 2>/dev/null)" != active ] ||
      block "HARDENING=yes, but $u is active: Decolab's firewall replaces it. Switch $u off first, or set HARDENING=no"
  done
fi

# Pi-hole and Samba publish 53, 139 and 445 on every address. Another
# program on one of them (on Debian: systemd-resolved's stub resolver on 53)
# would let the core stack fail to start halfway through the install. Ports
# Decolab's own containers hold already (a second run) are fine.
if command -v ss >/dev/null 2>&1; then
  for p in 53 139 445; do
    [ -n "$(ss -Hlntu "sport = :$p" 2>/dev/null)" ] || continue
    [ -z "$(docker ps -q --filter "publish=$p" 2>/dev/null)" ] || continue
    if [ "$p" = 53 ] && [ "$(systemctl is-active systemd-resolved 2>/dev/null)" = active ]; then
      block "port 53 is held by systemd-resolved's stub listener: switch it off first (INSTALL.md, step 2)"
    else
      block "port $p is in use by another program (sudo ss -lntup 'sport = :$p' shows which)"
    fi
  done
else
  item warn "cannot check that ports 53, 139 and 445 are free (ss is missing)"
fi

# --- secrets: plan -----------------------------------------------------------
# The secrets a host needs, and whether they can be made new. "tied" means
# data on this host depends on it: never generated in restore mode, and in
# fresh mode only if that data does not exist yet.
secret_list() {
  echo "runtime.env measured"
  echo "compose-secrets.env free"
  echo "samba_password free"
  echo "panel-token free"
  is_yes MODULE_IMMICH && echo "immich.env tied"
  is_yes MODULE_VAULTWARDEN && echo "vaultwarden.env free"
  case " $hw_list " in *" HW_UPS "*) echo "nut.env free" ;; esac
  [ -z "$RESTIC_REPOSITORY" ] || echo "restic-password tied"
  [ "$NOTIFY" != telegram ] || echo "telegram.env asked"
  [ "$NOTIFY" != ntfy ] || echo "ntfy.env asked"
  return 0
}
section "Secrets in $SECRETS_DIR"
gen_secrets=""
while read -r name kind; do
  f=$SECRETS_DIR/$name
  if [ "$kind" = measured ]; then
    continue # written below, every run
  elif [ -e "$f" ]; then
    if perm_is "$f" 600; then item ok "$name"; else item fix "$name: mode is not 600"; fi
  elif [ "$kind" = asked ]; then
    if [ "$ask" = 1 ] || [ "$dry" = 1 ]; then
      item ask "$name: the notification details are asked for"
      gen_secrets="$gen_secrets $name"
    else
      case $name in
        ntfy.env) block "$name missing: create it (NTFY_URL=https://ntfy.sh/TOPIC, optional NTFY_TOKEN=..., mode 600) or run install.sh in a terminal" ;;
        *) block "$name missing: create it (TELEGRAM_BOT_TOKEN=..., TELEGRAM_CHAT_ID=..., mode 600) or run install.sh in a terminal" ;;
      esac
    fi
  elif [ "$mode" = restore ] && [ "$kind" = tied ]; then
    block "$name missing: restore $SECRETS_DIR from the backup first (RESTORE.md); a new one would not open the restored data"
  elif [ "$name" = immich.env ] && [ -n "$(ls -A "$DATA_DIR/immich/postgres" 2>/dev/null)" ]; then
    block "$name missing, but $DATA_DIR/immich/postgres holds a database: a new password would not open it. Restore $name, or move that database away"
  else
    item new "$name (generated)"
    gen_secrets="$gen_secrets $name"
  fi
done < <(secret_list)

# runtime.env: measured, not secret, but here because Compose reads it with
# the secrets. Rewritten whenever a value changed.
runtime="DECOLAB_UID=$(id -u)
DECOLAB_GID=$(id -g)
DOCKER_GID=${dgid:-0}"
[ -z "$vw_domain" ] || runtime="$runtime
VAULTWARDEN_DOMAIN=$vw_domain"
if [ "$(cat "$SECRETS_DIR/runtime.env" 2>/dev/null)" = "$runtime" ]; then
  item ok "runtime.env"
else
  item write "runtime.env (user and group ids$([ -n "$vw_domain" ] && echo ', Vaultwarden domain'))"
fi

# --- stop here if a check failed ----------------------------------------------
if [ -n "$blockers" ] && [ "$dry" = 0 ]; then
  printf '\nNothing was changed. Fix these first:\n%s' "$(printf '%s' "$blockers" | sed 's/^/  - /')"
  echo
  exit 1
fi

# --- secrets: write ----------------------------------------------------------
alnum() { python3 -I -c 'import secrets, string, sys
a = string.ascii_letters + string.digits
print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"; }

# put_secret NAME - CONTENT on stdin, written 0600 and atomically
put_secret() {
  local tmp
  tmp=$(umask 077 && mktemp "$SECRETS_DIR/.new.XXXXXX") || return 1
  cat >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SECRETS_DIR/$1"
}

make_secret() {
  case $1 in
    compose-secrets.env) printf 'PIHOLE_PASSWORD=%s\n' "$(alnum 32)" | put_secret "$1" ;;
    samba_password) alnum 32 | put_secret "$1" ;;
    panel-token)
      alnum 48 | put_secret "$1" || return 1
      todo "the panel asks for a token once per browser: it is in $SECRETS_DIR/panel-token" ;;
    immich.env) printf 'DB_PASSWORD=%s\nDB_USERNAME=immich\nDB_DATABASE_NAME=immich\n' "$(alnum 32)" | put_secret "$1" ;;
    nut.env) printf 'UPSMON_PASSWORD=%s\n' "$(alnum 32)" | put_secret "$1" ;;
    restic-password)
      alnum 48 | put_secret "$1" || return 1
      todo "restic-password was generated: copy $SECRETS_DIR/restic-password to your emergency sheet NOW. Without it the off-site copy cannot be read. Then create the repository once: restic init (INSTALL.md, step 6)." ;;
    vaultwarden.env)
      # Vaultwarden keeps only the Argon2 hash (its "bitwarden" preset). The
      # plain token is for you, once; single quotes: Compose would read the
      # $ signs of the hash as variables.
      local token hash
      token=$(alnum 48)
      hash=$(printf '%s' "$token" | argon2 "$(alnum 16)" -e -id -k 65540 -t 3 -p 4) || return 1
      # shellcheck disable=SC2016 # the literal prefix of an Argon2id hash
      case $hash in '$argon2id$'*) ;; *) return 1 ;; esac
      printf "ADMIN_TOKEN='%s'\n" "$hash" | put_secret "$1" || return 1
      printf '%s\n' "$token" | put_secret vaultwarden-admin-token
      todo "Vaultwarden admin token: in $SECRETS_DIR/vaultwarden-admin-token. Put it in your password manager, then delete that file." ;;
    telegram.env)
      local bot chat
      printf '  Telegram bot token (from @BotFather, not shown): '
      IFS= read -rs bot && echo
      printf '  Telegram chat id: '
      IFS= read -r chat
      [[ $bot =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { warn "that is no bot token" && return 1; }
      [[ $chat =~ ^-?[0-9]+$ ]] || { warn "that is no chat id" && return 1; }
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' "$bot" "$chat" | put_secret "$1" ;;
    ntfy.env)
      # A random topic: on a public server the topic is the only lock.
      local url tok suggest
      suggest="https://ntfy.sh/decolab-$(alnum 24)"
      printf '  ntfy topic URL [%s]: ' "$suggest"
      IFS= read -r url
      url=${url:-$suggest}
      printf '  ntfy access token (Enter for none, not shown): '
      IFS= read -rs tok && echo
      [[ $url =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._-]+)*/[A-Za-z0-9_-]{1,64}$ ]] || { warn "that is no topic URL like https://ntfy.sh/TOPIC" && return 1; }
      [ -z "$tok" ] || [[ $tok =~ ^[A-Za-z0-9._-]+$ ]] || { warn "that is no access token" && return 1; }
      { printf 'NTFY_URL=%s\n' "$url" && { [ -z "$tok" ] || printf 'NTFY_TOKEN=%s\n' "$tok"; }; } | put_secret "$1"
      echo "  Subscribe to $url in the ntfy app to get the messages." ;;
  esac
}

if [ "$dry" = 0 ]; then
  if [ ! -d "$SECRETS_DIR" ]; then
    if [ -w "$(dirname "$SECRETS_DIR")" ]; then
      mkdir -m 700 "$SECRETS_DIR"
    else
      as_root install -d -m 0700 -o "$me" -g "$(id -gn)" "$SECRETS_DIR"
    fi || { echo "cannot create $SECRETS_DIR" >&2 && exit 1; }
  fi
  for name in $gen_secrets; do
    make_secret "$name" || { echo "could not write $name: stopped" >&2 && exit 1; }
    changed=$((changed + 1))
  done
  while read -r name kind; do
    f=$SECRETS_DIR/$name
    [ ! -e "$f" ] || perm_is "$f" 600 || chmod 600 "$f"
  done < <(secret_list)
  if [ "$(cat "$SECRETS_DIR/runtime.env" 2>/dev/null)" != "$runtime" ]; then
    printf '%s\n' "$runtime" | put_secret runtime.env && changed=$((changed + 1))
  fi
  case " $gen_secrets " in *" telegram.env "* | *" ntfy.env "*)
    if notify "✅ Decolab" "install.sh on $(hostname -s 2>/dev/null): notifications work."; then
      item ok "$NOTIFY test message sent: check your phone"
    else
      todo "the $NOTIFY test message failed: check $SECRETS_DIR/$NOTIFY.env (see $DECOLAB_LOG_DIR/notify-errors.log)"
    fi ;;
  esac
fi

# --- host files --------------------------------------------------------------
# The values a template may use: decolab.conf, what install.sh measured, and
# the generated UPS password (not readable yet in a dry run).
render_env() {
  local k
  while read -r k _; do
    case $k in '' | '#'*) continue ;; esac
    eval "export $k=\"\${$k:-}\""
  done <"$here/config/schema.txt"
  export DECOLAB_UID DECOLAB_GID DOCKER_GID UPSMON_PASSWORD
  DECOLAB_UID=$(id -u) DECOLAB_GID=$(id -g) DOCKER_GID=${dgid:-0}
  UPSMON_PASSWORD=generated-in-the-real-run
  if [ -r "$SECRETS_DIR/nut.env" ]; then read_secrets "$SECRETS_DIR/nut.env" UPSMON_PASSWORD || return 1; fi
}

record=$DECOLAB_STATE_DIR/installed.tsv
rec=$work/installed.tsv
cp "$record" "$rec" 2>/dev/null || : >"$rec"
rec_get() { awk -F'\t' -v d="$1" '$1 == d { print $2 }' "$rec"; }
rec_set() {
  awk -F'\t' -v d="$1" '$1 != d' "$rec" >"$rec.new"
  printf '%s\t%s\n' "$1" "$2" >>"$rec.new"
  mv "$rec.new" "$rec"
}

# pkg_default PATH FILE - is FILE the unchanged default a Debian package
# shipped as PATH (for example /etc/nut/ups.conf)? Then it is no change of
# the user's, and Decolab may replace it, keeping it as .decolab-old.
pkg_default() {
  local want got
  command -v dpkg-query >/dev/null 2>&1 || return 1
  want=$(dpkg-query -W -f='${Conffiles}\n' 2>/dev/null | awk -v d="$1" '$1 == d { print $2; exit }')
  [ -n "$want" ] || return 1
  got=$(read_any "$2" | md5sum | cut -d' ' -f1)
  [ "$got" = "$want" ]
}

afters=""
after() { case " $afters " in *" $1 "*) ;; *) afters="$afters $1" ;; esac; }

# when_ok WHEN - is this manifest line wanted on this host now?
when_ok() {
  case $1 in
    always) return 0 ;;
    late) [ "$late_ok" = 1 ] ;;
    HARDENING) is_yes HARDENING ;;
    HW_*) case " $hw_list " in *" $1 "*) return 0 ;; esac; return 1 ;;
    *) return 1 ;;
  esac
}

# place SRC DEST MODE OWNER AFTER - one manifest line, see the top
place() {
  local src=$1 dest=$2 mode=$3 owner=$4 aft=$5 staged new cur old secret=0 user_file=0 n
  n=$(printf '%s' "$dest" | tr '/' '_')
  staged=$work/staged$n
  case $dest in
    SECRETS_DIR/*) dest=$SECRETS_DIR/${dest#SECRETS_DIR/} user_file=1 ;;
    *) dest=$hostroot$dest ;;
  esac
  owner=${owner//DECOLAB_USER/$me}
  if [ "${src%.template}" != "$src" ]; then
    (render_env && python3 -I "$here/lib/render.py" "$here/$src") >"$staged" || {
      item ERROR "$dest: $src does not render"
      blockers="$blockers$dest: $src does not render"$'\n'
      return 1
    }
    grep -q 'UPSMON_PASSWORD' "$here/$src" && secret=1
  else
    cp "$here/$src" "$staged"
  fi
  new=$(sha <"$staged")
  old=$(rec_get "$dest")
  if [ -e "$dest" ]; then
    if [ -r "$dest" ]; then
      cur=$(sha <"$dest")
    elif [ "$dry" = 1 ]; then
      item "?" "$dest: readable only with sudo, compared in the real run"
      return 0
    else
      cur=$(as_root cat "$dest" | sha)
    fi
  fi

  if [ -e "$dest" ] && [ "$cur" = "$new" ]; then
    [ "$old" = "$new" ] || { [ "$dry" = 1 ] || rec_set "$dest" "$new"; }
    if ! perm_is "$dest" "$mode"; then
      would "chmod $mode $dest" || { as_root chmod "$mode" "$dest" && item fixed "$dest: mode $mode"; }
    fi
    item ok "$dest"
    return 0
  fi
  local what=new
  [ -e "$dest" ] && what=update
  if [ -e "$dest" ] && [ -z "$old" ] && pkg_default "${dest#"$hostroot"}" "$dest"; then
    what="update"  # the package's own default, as shipped: ours replaces it
  elif [ -e "$dest" ] && [ "$cur" != "$old" ]; then
    # Changed on this host (or there before Decolab): never overwritten.
    item KEPT "$dest: changed on this host, not overwritten"
    kept="$kept$dest"$'\n'
    if [ "$secret" = 1 ]; then
      echo "            (difference not shown: the file holds a password)"
    else
      read_any "$dest" | diff -u - "$staged" | sed -e '1,2d' -e 's/^/            /' | head -40
    fi
    return 0
  fi

  if [ "$dry" = 1 ]; then
    item "$what" "$dest"
    return 0
  fi
  if [ "$aft" = sudoers ] && ! as_root visudo -cqf "$staged"; then
    item ERROR "$dest: visudo rejects it; not installed"
    return 1
  fi
  if [ "$user_file" = 1 ]; then
    # In place: the file is bind-mounted into a container, which follows
    # the inode; a new file would stay invisible to it until a re-create.
    cat "$staged" >"$dest" && chmod "$mode" "$dest" || return 1
  else
    [ "$what" = new ] || as_root cp -p "$dest" "$dest.decolab-old" || return 1
    as_root mkdir -p "$(dirname "$dest")" || return 1
    if [ -n "$hostroot" ]; then
      as_root install -m "$mode" "$staged" "$dest" || return 1
    else
      as_root install -m "$mode" -o "${owner%%:*}" -g "${owner#*:}" "$staged" "$dest" || return 1
    fi
    if [ "$aft" = sudoers ] && ! as_root visudo -cq; then
      # A broken sudoers file means no sudo at all: undo at once.
      if [ "$what" = update ]; then as_root mv "$dest.decolab-old" "$dest"; else as_root rm -f "$dest"; fi
      item ERROR "$dest: sudo's configuration became invalid; undone"
      return 1
    fi
  fi
  rec_set "$dest" "$new"
  changed=$((changed + 1))
  if [ "$what" = new ]; then item new "$dest"; else item update "$dest (the old one: $dest.decolab-old)"; fi
  [ "$aft" = - ] || after "$aft"
}

# manifest WHEN-FILTER - places the lines of config/install-manifest.tsv;
# "early" = all but the late ones, "late" = only those
manifest() {
  local src dest mode owner when aft fails=0
  while IFS=$'\t' read -r src dest mode owner when aft; do
    case $src in '' | '#'*) continue ;; esac
    if [ "$1" = late ]; then [ "$when" = late ] || continue; else [ "$when" != late ] || continue; fi
    if when_ok "$when"; then
      place "$src" "$dest" "$mode" "$owner" "$aft" || fails=$((fails + 1))
    elif [ -n "$(rec_get "$hostroot$dest")" ] && [ -e "$hostroot$dest" ]; then
      item unused "$hostroot$dest: no longer needed here ($when); remove it by hand if you like"
    fi
  done <"$here/config/install-manifest.tsv"
  return "$fails"
}

run_afters() {
  local a
  for a in $afters; do
    case $a in
      tmpfiles) as_root systemd-tmpfiles --create "$hostroot/etc/tmpfiles.d/decolab.conf" ;;
      systemd) as_root systemctl daemon-reload ;;
      udev) as_root udevadm control --reload && as_root udevadm trigger --subsystem-match=hwmon ;;
      sysctl) as_root sysctl --system >/dev/null ;;
      nut) as_root systemctl restart nut-server nut-monitor ;;
      sudoers) ;;
    esac || item ERROR "after the files: $a failed"
  done
  afters=""
}

save_record() {
  [ "$dry" = 0 ] || return 0
  if ! { cp "$rec" "$record.new" && mv "$record.new" "$record"; }; then
    item ERROR "cannot write $record: the next run will treat the files as changed"
  fi
}

section "Host files"
fails=0
[ "$dry" = 1 ] || { [ -z "$sudo" ] || item note "sudo may ask for your password"; }
manifest early || fails=$?
run_afters
save_record

# --- directories -------------------------------------------------------------
section "Directories"
# mkdir_own DIR - create DIR for DECOLAB_USER if it is missing. An existing
# one is never chowned: below DATA_DIR live databases of other users.
mkdir_own() {
  if [ -d "$1" ]; then
    item ok "$1"
  elif [ "$dry" = 1 ]; then
    item new "$1"
  elif mkdir -p "$1" 2>/dev/null || as_root install -d -m 0750 -o "$me" -g "$(id -gn)" "$1"; then
    item new "$1"
    changed=$((changed + 1))
  else
    item ERROR "cannot create $1"
    fails=$((fails + 1))
  fi
}
for d in "$DECOLAB_RUN_DIR" "$DECOLAB_LOG_DIR" "$DECOLAB_STATE_DIR" "$DECOLAB_TEXTFILE_DIR" \
  "$BACKUP_DIR" "$DATA_DIR/pihole" "$DATA_DIR/portainer" "$DATA_DIR/prometheus" \
  "$DATA_DIR/unbound/conf.d" "$DATA_DIR/unbound/var" "$DATA_DIR/nas"; do
  mkdir_own "$d"
done
is_yes MODULE_IMMICH && mkdir_own "$DATA_DIR/immich/library"
# After a restore the database expects a .immich marker in every folder, but
# the backup leaves out the ones Immich regenerates. Create only missing ones,
# and only when the photos are back (upload/.immich): a fresh Immich makes
# them itself, and a marker in an existing folder is Immich's business.
if is_yes MODULE_IMMICH && [ -f "$DATA_DIR/immich/library/upload/.immich" ]; then
  for d in thumbs encoded-video backups; do
    lib_d=$DATA_DIR/immich/library/$d
    [ -d "$lib_d" ] && continue
    if [ "$dry" = 1 ]; then
      item new "$lib_d (with .immich)"
    elif mkdir "$lib_d" && : >"$lib_d/.immich"; then
      item new "$lib_d (with .immich)"
      changed=$((changed + 1))
    else
      item ERROR "cannot create $lib_d"
      fails=$((fails + 1))
    fi
  done
fi
is_yes MODULE_VAULTWARDEN && mkdir_own "$DATA_DIR/vaultwarden"
is_yes MODULE_UPTIME_KUMA && mkdir_own "$DATA_DIR/uptime-kuma"

# The logs root writes to, created now by the user: root's ">>" would
# create them for root, and the jobs of the user could not write them.
if [ "$dry" = 0 ] && [ -d "$DECOLAB_LOG_DIR" ]; then
  grep -oE '/var/log/decolab/[a-z0-9-]+\.log' "$here/config/cron/cron.d-decolab-root.template" | sort -u |
    while read -r l; do
      [ -e "$DECOLAB_LOG_DIR/${l##*/}" ] || : >"$DECOLAB_LOG_DIR/${l##*/}"
    done
fi
if [ "$dry" = 0 ]; then
  if [ -n "$saved_mode" ] || printf '%s\n' "$mode" >"$mode_file"; then :; else item ERROR "cannot write $mode_file"; fi
  [ "$restore_done" = 0 ] || [ -f "$confirmed" ] || date '+%F %T' >"$confirmed"
fi

# Uptime Kuma joins the networks of the enabled modules (lib/compose.sh).
if is_yes MODULE_UPTIME_KUMA; then
  nets=$work/compose.networks.yml
  {
    echo "# Generated by install.sh: the networks Uptime Kuma joins. Do not edit."
    echo "services:"
    echo "  uptime-kuma:"
    echo "    networks:"
    echo "      core: {}"
    is_yes MODULE_IMMICH && echo "      immich: {}"
    is_yes MODULE_VAULTWARDEN && echo "      vaultwarden: {}"
    echo "networks:"
    echo "  core: {external: true, name: decolab_proxy_net}"
    is_yes MODULE_IMMICH && echo "  immich: {external: true, name: decolab-immich_default}"
    is_yes MODULE_VAULTWARDEN && echo "  vaultwarden: {external: true, name: decolab-vaultwarden_default}"
  } >"$nets"
  if cmp -s "$nets" "$DECOLAB_STATE_DIR/compose.networks.yml"; then
    item ok "$DECOLAB_STATE_DIR/compose.networks.yml"
  elif [ "$dry" = 1 ]; then
    item write "$DECOLAB_STATE_DIR/compose.networks.yml"
  else
    cp "$nets" "$DECOLAB_STATE_DIR/compose.networks.yml" && item write "$DECOLAB_STATE_DIR/compose.networks.yml" &&
      changed=$((changed + 1))
  fi
fi

# --- services ----------------------------------------------------------------
section "Services"
# enable UNIT [--now]
enable() {
  local s
  s=$(systemctl is-enabled "$1" 2>/dev/null)
  if [ "$s" = enabled ]; then
    item ok "$1"
  elif [ "$dry" = 1 ]; then
    item enable "$1"
  elif as_root systemctl enable "$@" >/dev/null 2>&1; then
    item enabled "$1"
    changed=$((changed + 1))
  else
    item ERROR "cannot enable $1"
    fails=$((fails + 1))
  fi
}
enable decolab-boot-notify.service
enable decolab-panel.service --now
case " $hw_list " in *" HW_FAN "*) enable decolab-fan.service --now ;; esac
case " $hw_list " in *" HW_OLED "*) enable decolab-oled.service --now ;; esac
if [ -n "$hw_list" ]; then item note "hardware:$hw_list"; else item note "no Pi hardware found (HW_*=auto)"; fi

# --- stacks --------------------------------------------------------------------
section "Stacks"
if [ "$late_ok" = 0 ]; then
  item wait "nothing started: restore the data (RESTORE.md), then ./install.sh --restore-done"
elif [ "$dry" = 1 ]; then
  item would "pull, then start: $(decolab_stacks 2>/dev/null | tr '\n' ' ')"
else
  stacks=$(decolab_stacks)
  # pull_stack STACK - up to 3 attempts: a registry may refuse for a moment
  # (Docker Hub's rate limit stopped a whole install once)
  pull_stack() {
    local try=1 max=${INSTALL_PULL_ATTEMPTS:-3} pause=${INSTALL_PULL_PAUSE_S:-60}
    while ! COMPOSE_TIMEOUT_S=3600 decolab_compose "$1" pull --quiet; do
      [ "$try" -lt "$max" ] || return 1
      try=$((try + 1))
      item wait "pulling $1 failed: attempt $try of $max in $pause s"
      sleep "$pause"
    done
  }
  # Everything is pulled before anything starts: pulling needs DNS, and
  # Pi-hole's start interrupts it.
  for s in $stacks; do
    pull_stack "$s" || { item ERROR "pulling $s failed $((${INSTALL_PULL_ATTEMPTS:-3})) times: nothing started" && fails=$((fails + 1)) && stacks=""; }
  done
  names=""
  for s in $stacks; do
    names="$names $(decolab_compose "$s" config 2>/dev/null | awk '$1 == "container_name:" { print $2 }' | tr '\n' ' ')"
  done
  if [ -n "$stacks" ]; then
    # shellcheck disable=SC2086 # container names have no spaces
    maintenance_begin $names
    trap 'maintenance_end; rm -rf "$work"' EXIT
    for s in $stacks; do
      COMPOSE_TIMEOUT_S=1800 decolab_compose "$s" up -d --pull never >/dev/null || { item ERROR "starting $s failed" && fails=$((fails + 1)); }
    done
    # shellcheck disable=SC2086
    bad=$(compose_wait_healthy "${INSTALL_HEALTH_WAIT_S:-300}" "${INSTALL_SETTLE_S:-30}" "${INSTALL_STEP_S:-5}" $names)
    maintenance_end
    trap 'rm -rf "$work"' EXIT
    if [ -n "$bad" ]; then
      item ERROR "not healthy:$bad (docker logs NAME)"
      fails=$((fails + 1))
    else
      item ok "running and healthy:$names"
    fi
  fi
fi

# --- last: schedules and the watchdog ------------------------------------------
section "Schedules and watchdog"
if [ "$late_ok" = 0 ]; then
  item wait "not yet: the nightly backup and the USB mirror would overwrite the good copies with an empty system"
else
  manifest late || fails=$((fails + $?))
  run_afters
  save_record
  enable decolab-watchdog.timer --now
fi

# --- summary -------------------------------------------------------------------
if is_yes MODULE_UPTIME_KUMA; then
  kuma_monitors | sort >"$work/want"
  grep -oE '^KUMA_[A-Z_]+' "$SECRETS_DIR/kuma-push.env" 2>/dev/null | sed 's/^KUMA_//' | sort >"$work/have"
  lack=$(comm -23 "$work/want" "$work/have" | tr '\n' ' ')
  [ -z "$lack" ] || todo "Uptime Kuma: create a push monitor for each of these and put its token in $SECRETS_DIR/kuma-push.env (KUMA_BASE=... and KUMA_NAME=token): $lack"
fi
if is_yes HARDENING && [ ! -f "$hostroot/var/lib/decolab/firewall-confirmed" ]; then
  todo "Firewall: in an SSH login from your LAN run  sudo $here/bin/decolab-firewall apply  then, within 5 minutes, from a NEW login:  sudo $here/bin/decolab-firewall confirm"
fi
if is_yes HARDENING && ! command -v cscli >/dev/null 2>&1; then
  todo "CrowdSec (optional, HARDENING): install it from its vendor repository (https://docs.crowdsec.net/u/getting_started/installation/linux); the configuration is already in place"
fi
if [ -n "$USB_BACKUP_DIR" ] && [ ! -f "$USB_BACKUP_DIR/.decolab-usb-backup" ]; then
  todo "USB copy: mount the USB disk at $USB_BACKUP_DIR, then mark it (only that disk):  touch $USB_BACKUP_DIR/.decolab-usb-backup"
fi
[ -z "$kept" ] || todo "kept because changed on this host: $(printf '%s' "$kept" | tr '\n' ' ')- compare with the repository version above, merge by hand, then run install.sh again"

section "Summary"
if [ -n "$blockers" ]; then
  printf 'Stopped by checks (nothing would be done until they are fixed):\n%s' "$(printf '%s' "$blockers" | sed 's/^/  - /')"
  echo
fi
if [ -n "$todos" ]; then
  printf 'For you to do:\n%s' "$(printf '%s' "$todos" | sed 's/^/  - /')"
  echo
fi
if [ "$dry" = 1 ]; then
  echo "Dry run: nothing was changed."
else
  echo "$changed change(s). The log of this run goes to $DECOLAB_LOG_DIR/install-*.log"
fi
[ -z "$blockers" ] || exit 1
[ "$fails" = 0 ] || exit 1
[ -z "$kept" ] || exit 2
exit 0
