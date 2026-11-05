# shellcheck shell=bash
# shellcheck disable=SC2034  # the settings are read by _ini_render through eval
# lib/config-init.sh - write a first decolab.conf by asking a few questions
#
# Used by "bin/decolab-config init". Finds what it can on this host (user,
# time zone, LAN interface and address, SSH port, tailnet) and asks only for
# the rest, each time with a suggestion that Enter accepts. Every answer is
# checked at once with the same rules as "decolab-config check"; the file is
# written from decolab.conf.example, so its comments stay, and checked again
# as a whole before it replaces nothing: an existing file is never touched.
#
# Overridable for tests: DECOLAB_SYSROOT (prefix for /etc and /sys reads),
# and PATH (ip, tailscale, timedatectl).
# Compatible with bash 3.2 (macOS) and bash 5.

# shellcheck source=lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

_ini_root=${DECOLAB_SYSROOT:-}
_ini_defaults=0 # 1 = accept every suggestion, ask nothing
_ini_notes=""

_ini_note() { _ini_notes="$_ini_notes  - $1"$'\n'; }

# --- detection (each prints a suggestion or nothing) -------------------------

_ini_user() {
  local u=${SUDO_USER:-}
  [ -n "$u" ] || u=$(id -un 2>/dev/null || true)
  [ "$u" = root ] && u=""
  printf '%s' "$u"
}

_ini_tz() {
  local tz=""
  if [ -z "$_ini_root" ] && command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [ -z "$tz" ] && [ -L "$_ini_root/etc/localtime" ]; then
    tz=$(readlink "$_ini_root/etc/localtime")
    tz=${tz#*zoneinfo/}
  fi
  if [ -z "$tz" ] && [ -r "$_ini_root/etc/timezone" ]; then
    IFS= read -r tz < "$_ini_root/etc/timezone" || true
  fi
  printf '%s' "${tz:-UTC}"
}

# default route -> "IFACE ADDRESS/PREFIX FLAGS"
_ini_lan() {
  local dev="" line w prev="" addr="" dyn=""
  command -v ip >/dev/null 2>&1 || return 0
  line=$(ip -4 route show default 2>/dev/null | head -n 1)
  for w in $line; do
    [ "$prev" = dev ] && dev=$w
    prev=$w
  done
  [ -n "$dev" ] || return 0
  line=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | head -n 1)
  prev=""
  for w in $line; do
    [ "$prev" = inet ] && addr=$w
    [ "$w" = dynamic ] && dyn=dynamic
    prev=$w
  done
  printf '%s %s %s' "$dev" "$addr" "$dyn"
}

_ini_ssh_port() {
  local f p=""
  for f in "$_ini_root"/etc/ssh/sshd_config.d/*.conf "$_ini_root/etc/ssh/sshd_config"; do
    [ -r "$f" ] || continue
    # sshd takes the first Port it reads; drop-ins are read first
    p=$(sed -n 's/^[[:space:]]*[Pp]ort[[:space:]]\{1,\}\([0-9]\{1,5\}\)[[:space:]]*$/\1/p' "$f" | head -n 1)
    [ -n "$p" ] && break
  done
  printf '%s' "${p:-22}"
}

_ini_tailnet() {
  local j s
  command -v tailscale >/dev/null 2>&1 || return 0
  j=$(tailscale status --json 2>/dev/null || true)
  s=$(printf '%s' "$j" | sed -n 's/.*"MagicDNSSuffix"[[:space:]]*:[[:space:]]*"\([a-z0-9-]*\)\.ts\.net".*/\1/p' | head -n 1)
  # older versions: only the host's own name, as install.sh reads it
  [ -n "$s" ] || s=$(printf '%s' "$j" | sed -n 's/.*"Self"[[:space:]]*:[[:space:]]*{[^}]*"DNSName"[[:space:]]*:[[:space:]]*"[a-z0-9-]*\.\([a-z0-9-]*\)\.ts\.net\.\{0,1\}".*/\1/p' | head -n 1)
  printf '%s' "$s"
}

# first pool of 10.210.0.0/16, 10.211.0.0/16, ... that misses the LAN
_ini_pool() { # LAN_NET LAN_SIZE
  local i
  for i in 210 211 212 213 214 215 216 217 218 219; do
    if [ -z "${1:-}" ] || ! _cfg_overlap $((10 << 24 | i << 16)) 65536 "$1" "$2"; then
      printf '10.%s.0.0/16' "$i"
      return 0
    fi
  done
  printf '10.210.0.0/16'
}

# --- asking ------------------------------------------------------------------

# _ini_ask KEY TYPE DEFAULT QUESTION [optional]
#   Sets the shell variable KEY. Asks again until the answer is valid.
#   "-" as answer to an optional question leaves it empty.
_ini_ask() {
  local key=$1 type=$2 def=$3 q=$4 opt=${5:-} a hint eof=0
  hint=$def
  [ -z "$def" ] && [ -n "$opt" ] && hint="empty"
  while :; do
    if [ "$_ini_defaults" = 1 ]; then
      a=$def
    else
      if [ -n "$hint" ]; then
        printf '%s [%s]: ' "$q" "$hint" >&2
      else
        printf '%s: ' "$q" >&2
      fi
      if ! IFS= read -r a; then
        printf '\n' >&2
        eof=1
        a=$def
        [ -n "$a" ] || [ -n "$opt" ] || { printf 'no answer for %s (input ended)\n' "$key" >&2; return 1; }
      fi
      [ -n "$a" ] || a=$def
      [ "$a" = - ] && [ -n "$opt" ] && a=""
    fi
    if [ -z "$a" ]; then
      if [ -n "$opt" ]; then
        printf -v "$key" '%s' ""
        return 0
      fi
      printf '  %s: an answer is needed\n' "$key" >&2
    elif ! [[ $a =~ ^[A-Za-z0-9._/:@+,-]*$ ]]; then
      printf '  %s: only letters, digits and . _ / : @ + , - are allowed\n' "$key" >&2
    else
      _cfg_file=answer
      if _cfg_check_type "" "$key" "$type" "$a"; then
        printf -v "$key" '%s' "$a"
        return 0
      fi
    fi
    # an invalid suggestion with --defaults or after the input ended would
    # loop forever
    if [ "$_ini_defaults" = 1 ] || [ "$eof" = 1 ]; then
      printf '  %s: no usable suggestion; run without --defaults\n' "$key" >&2
      return 1
    fi
  done
}

_ini_section() { [ "$_ini_defaults" = 1 ] || printf '\n== %s ==\n' "$1" >&2; }

# --- writing -----------------------------------------------------------------

# copy the example, put our values in; keys stay in the example's order
_ini_render() { # EXAMPLE OUT
  local line key
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      [A-Z]*=*)
        key=${line%%=*}
        if _cfg_known_key "$key"; then
          eval "printf '%s=%s\n' \"\$key\" \"\${$key-}\""
          continue
        fi ;;
    esac
    printf '%s\n' "$line"
  done < "$1" > "$2"
}

# print loader messages with the draft's path replaced by the target's
_ini_relabel() { # TEXT DRAFT TARGET
  local line
  [ -n "$1" ] || return 0
  while IFS= read -r line; do
    printf '%s\n' "${line//"$2"/$3}" >&2
  done <<< "$1"
}

# --- main --------------------------------------------------------------------

decolab_config_init() { # [--defaults] FILE
  local out lan dev addr dyn net host repo example tmp k d errs home
  if [ "${1:-}" = --defaults ]; then _ini_defaults=1; shift; fi
  out=${1:?usage: decolab_config_init [--defaults] FILE}
  repo=$(cd "$DECOLAB_LIB_DIR/.." && pwd -P)
  example=$repo/decolab.conf.example

  if [ -e "$out" ] || [ -L "$out" ]; then
    printf '%s already exists; nothing written.\n' "$out" >&2
    printf 'To compare: bin/decolab-config init new.conf, then: diff %s new.conf\n' "$out" >&2
    return 1
  fi
  _cfg_reset
  _cfg_load_schema || return 1

  [ "$_ini_defaults" = 1 ] || printf 'Decolab setup: Enter accepts the suggestion in [brackets].\n' >&2

  _ini_section System
  _ini_ask DECOLAB_USER user "$(_ini_user)" "Linux user that owns Decolab (not root)" || return 1
  k=/opt/decolab
  [[ $repo =~ ^(/[A-Za-z0-9._+-]+)+$ ]] && k=$repo
  _ini_ask DECOLAB_DIR abspath "$k" "Where this repository lives" || return 1
  _ini_ask DATA_DIR abspath /mnt/data "Data disk (NVMe) for photos, databases and shares" || return 1
  if [ -d "$_ini_root$DATA_DIR" ] && command -v mountpoint >/dev/null 2>&1 \
    && ! mountpoint -q "$_ini_root$DATA_DIR"; then
    _ini_note "$DATA_DIR is not a separate disk yet: mount the NVMe there first (INSTALL.md, step 2)."
  fi
  SECRETS_DIR=/etc/decolab/secrets
  _ini_ask TZ tz "$(_ini_tz)" "Time zone" || return 1

  _ini_section Network
  lan=$(_ini_lan)
  # shellcheck disable=SC2086  # "IFACE ADDR FLAGS"
  set -- $lan
  dev=${1:-} addr=${2:-} dyn=${3:-}
  net="" host=""
  if [ -n "$addr" ]; then
    k=0
    _cfg_cidr "$addr" || k=$? # 2 = a host address: the network is still known
    if [ "$k" != 1 ]; then
      host=${addr%/*}
      net="$(_cfg_int_to_ip "$_cfg_net")/$_cfg_len"
    fi
  fi
  [ -n "$dev" ] || _ini_note "No default route found: enter the LAN interface and address yourself."
  _ini_ask LAN_INTERFACE iface "$dev" "LAN network interface" || return 1
  _ini_ask HOST_LAN_IP ipv4 "$host" "Fixed LAN address of this Pi" || return 1
  _ini_ask LAN_SUBNET cidr "$net" "LAN network" || return 1
  [ "$dyn" = dynamic ] && _ini_note "$HOST_LAN_IP came from DHCP: reserve it for this Pi in your router."
  _ini_ask SSH_PORT port "$(_ini_ssh_port)" "SSH port" || return 1
  _cfg_cidr "$LAN_SUBNET" || true
  DOCKER_ADDRESS_POOL=$(_ini_pool "$_cfg_net" "$_cfg_size")
  PANEL_PORT=8090

  _ini_section "Remote access"
  k=$(_ini_tailnet)
  if [ -n "$k" ]; then
    _ini_ask TAILSCALE yesno yes "Use Tailscale for the web interfaces (HTTPS)" || return 1
  else
    _ini_ask TAILSCALE yesno no "Use Tailscale for the web interfaces (HTTPS; not found on this host)" || return 1
  fi
  TAILNET_NAME=""
  if [ "$TAILSCALE" = yes ]; then
    _ini_ask TAILNET_NAME tailnet "$k" "Tailnet name (the part before .ts.net)" || return 1
    [ -n "$k" ] || _ini_note "Tailscale is not running here yet: install.sh checks TAILNET_NAME against it."
  fi
  if [ "$TAILSCALE" = yes ]; then
    k=127.0.0.1
  else
    k=$HOST_LAN_IP
  fi
  _ini_ask WEB_UI_ADDRESS ipv4 "$k" "Address the web interfaces listen on (127.0.0.1 or $HOST_LAN_IP)" || return 1

  _ini_section Modules
  _ini_ask MODULE_IMMICH yesno yes "Immich (photos)" || return 1
  k=no
  [ "$TAILSCALE" = yes ] && k=yes
  while :; do
    _ini_ask MODULE_VAULTWARDEN yesno "$k" "Vaultwarden (passwords; needs Tailscale)" || return 1
    [ "$MODULE_VAULTWARDEN" = no ] || [ "$TAILSCALE" = yes ] && break
    printf '  MODULE_VAULTWARDEN: needs TAILSCALE=yes: the web vault only works over HTTPS\n' >&2
    [ "$_ini_defaults" = 1 ] && return 1
  done
  _ini_ask MODULE_UPTIME_KUMA yesno yes "Uptime Kuma (status page and alerts)" || return 1
  HW_FAN=auto HW_OLED=auto HW_NVME=auto HW_UPS=auto
  _ini_ask SPEEDTEST yesno yes "Internet speed test every 6 hours (about 4 GB a day on 1 Gbit/s)" || return 1

  _ini_section Hardening
  k=no
  [ "$WEB_UI_ADDRESS" = "$HOST_LAN_IP" ] && k=yes
  _ini_ask HARDENING yesno "$k" "Kernel hardening, and a firewall you switch on yourself later" || return 1
  SSH_PASSWORDS=yes
  if [ "$HARDENING" = yes ]; then
    k=yes
    # the keys of DECOLAB_USER, not of whoever runs this (root under sudo)
    home=""
    command -v getent >/dev/null 2>&1 && home=$(getent passwd "$DECOLAB_USER" | cut -d: -f6)
    [ -n "$home" ] || home=${HOME:-/nonexistent}
    [ -s "$home/.ssh/authorized_keys" ] && k=no
    _ini_ask SSH_PASSWORDS yesno "$k" "Keep SSH password logins (no = keys only)" || return 1
    if [ "$SSH_PASSWORDS" = no ] && [ "$k" = yes ]; then
      _ini_note "SSH_PASSWORDS=no, but ~/.ssh/authorized_keys is empty: add your key before the firewall's apply."
    fi
  fi

  _ini_section Backups
  _ini_ask BACKUP_DIR abspath "$DATA_DIR/backups" "Backup folder" || return 1
  _ini_ask BACKUP_KEEP_DAYS days 7 "Keep nightly backups for how many days" || return 1
  _ini_ask USB_BACKUP_DIR abspath "" "Second copy on a USB disk (path, or - for none)" optional || return 1
  _ini_ask RESTIC_REPOSITORY restic "" "Off-site copy, restic repository (or - for none)" optional || return 1

  _ini_section Notifications
  _ini_ask NOTIFY notify none "Notifications: telegram or none (install.sh asks for the bot token)" || return 1

  # The draft lives in a private directory, never next to the target: a name
  # others can guess there could be a planted link (root follows it under sudo).
  d=$(mktemp -d "${TMPDIR:-/tmp}/decolab-init.XXXXXX") || return 1
  tmp=$d/decolab.conf
  _ini_render "$example" "$tmp"
  if ! errs=$(decolab_config_load "$tmp" 2>&1); then
    _ini_relabel "$errs" "$tmp" "$out"
    rm -rf "$d"
    printf 'Nothing written: the answers do not fit together (see above).\n' >&2
    return 1
  fi
  _ini_relabel "$errs" "$tmp" "$out" # warnings
  decolab_config_load "$tmp" 2>/dev/null || true # for the count
  # noclobber: the shell creates the file with O_EXCL, so neither a file, a
  # directory nor a link that appeared since the check above is followed
  if ! (umask 022 && set -o noclobber && cat "$tmp" > "$out") 2>/dev/null; then
    rm -rf "$d"
    printf '%s appeared meanwhile or cannot be created; nothing written.\n' "$out" >&2
    return 1
  fi
  rm -rf "$d"

  printf '\nWrote %s (%s settings).\n' "$out" "$DECOLAB_CONFIG_COUNT" >&2
  if [ -n "$_ini_notes" ]; then printf 'Before you install:\n%s' "$_ini_notes" >&2; fi
  printf 'Next: read it once, then run ./install.sh --dry-run --fresh\n' >&2
}
