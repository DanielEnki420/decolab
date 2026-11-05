#!/usr/bin/env bash
# Contract tests for bin/decolab-config: what a user sees for good and bad files.
# Single quotes around $… are intended: the code runs in a child shell.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cfg=$t_root/bin/decolab-config
example=$t_root/decolab.conf.example

# conf NAME [KEY=VALUE | -KEY | +RAW-LINE]...
#   Writes $t_tmp/NAME.conf: the example with KEY replaced, KEY removed or a
#   raw line appended. Prints the path.
conf() {
  local f=$t_tmp/$1.conf arg line key
  shift
  cp "$example" "$f"
  for arg in "$@"; do
    case $arg in
      +*) printf '%s\n' "${arg#+}" >> "$f" ;;
      -*)
        key=${arg#-}
        grep -v "^$key=" "$f" > "$f.new"; mv "$f.new" "$f" ;;
      *=*)
        key=${arg%%=*}
        : > "$f.new"
        while IFS= read -r line || [ -n "$line" ]; do
          case $line in "$key="*) printf '%s\n' "$arg" ;; *) printf '%s\n' "$line" ;; esac >> "$f.new"
        done < "$f"
        mv "$f.new" "$f" ;;
    esac
  done
  printf '%s' "$f"
}

echo "valid files"
check "example is valid" 0 "OK:" -- "$cfg" check "$example"
check "example has all 29 settings" 0 "(29 settings)" -- "$cfg" check "$example"
check "restic sftp target" 0 "OK:" -- "$cfg" check "$(conf restic RESTIC_REPOSITORY=sftp:backup@storage.example.com:/decolab)"
check "restic local path" 0 "OK:" -- "$cfg" check "$(conf restic2 RESTIC_REPOSITORY=/mnt/usb/restic)"
check "tailscale with name" 0 "OK:" -- "$cfg" check "$(conf ts TAILSCALE=yes TAILNET_NAME=tail5678)"
check "unused tailnet name only warns" 0 "warning: ignored because TAILSCALE=no" -- "$cfg" check "$(conf tsno TAILSCALE=no MODULE_VAULTWARDEN=no)"
check "loopback UI without Tailscale warns" 0 "only reachable through an SSH tunnel" -- "$cfg" check "$(conf lo TAILSCALE=no TAILNET_NAME= MODULE_VAULTWARDEN=no)"
check "LAN-wide web UI" 0 "OK:" -- "$cfg" check "$(conf lanui WEB_UI_ADDRESS=192.0.2.10)"

echo "schema and example agree"
schema_keys=$(grep -v -e '^#' -e '^[[:space:]]*$' "$t_root/config/schema.txt" | awk '{print $1}' | sort)
example_keys=$(grep -E '^[A-Z]' "$example" | cut -d= -f1 | sort)
if [ "$schema_keys" = "$example_keys" ]; then t_ok "same keys in schema.txt and example"; else
  t_fail "same keys in schema.txt and example" "$(diff <(echo "$schema_keys") <(echo "$example_keys") | tr '\n' ' ')"
fi

echo "the file is data, never code"
marker=$t_tmp/executed
check "command substitution rejected" 1 "characters that are not allowed" -- "$cfg" check "$(conf cmd 'DECOLAB_USER=$(touch '"$marker"')')"
if [ -e "$marker" ]; then t_fail "command substitution not executed" "marker file was created"; else t_ok "command substitution not executed"; fi
check "backticks rejected" 1 "characters that are not allowed" -- "$cfg" check "$(conf bt 'DECOLAB_USER=`id`')"
check "quotes rejected" 1 "characters that are not allowed" -- "$cfg" check "$(conf q 'DATA_DIR="/mnt/data"')"
check "inline comment rejected" 1 "characters that are not allowed" -- "$cfg" check "$(conf ic 'TZ=Europe/Berlin # home')"

echo "format errors"
check "missing file" 1 "cannot read file" -- "$cfg" check "$t_tmp/none.conf"
check "duplicate key" 1 "set twice" -- "$cfg" check "$(conf dup '+SSH_PORT=22')"
check "unknown key" 1 "SSH_PROT: unknown setting" -- "$cfg" check "$(conf typo '+SSH_PROT=22')"
check "missing key" 1 "SSH_PORT: missing" -- "$cfg" check "$(conf miss -SSH_PORT)"
check "lower-case key" 1 "is not a valid key" -- "$cfg" check "$(conf lc -SSH_PORT '+ssh_port=22')"
check "spaces around =" 1 "is not a valid key" -- "$cfg" check "$(conf sp -SSH_PORT '+SSH_PORT = 22')"
check "leading whitespace" 1 "must start with the key" -- "$cfg" check "$(conf lw -SSH_PORT '+  SSH_PORT=22')"
check "line without =" 1 "expected KEY=VALUE" -- "$cfg" check "$(conf noeq '+SSH_PORT')"
crlf=$(conf crlf); printf 'SSH_PORT=22\r\n' >> "$crlf"
check "CRLF line ending" 1 "Windows line ending" -- "$cfg" check "$crlf"
check "required value empty" 1 "DATA_DIR: must not be empty" -- "$cfg" check "$(conf empty DATA_DIR=)"
check "all errors at once" 1 "has 2 error(s)" -- "$cfg" check "$(conf two SSH_PORT=0 HW_FAN=maybe)"

echo "value types"
check "user root" 1 "must not be root" -- "$cfg" check "$(conf root DECOLAB_USER=root)"
check "bad user name" 1 "not a valid Linux user name" -- "$cfg" check "$(conf un DECOLAB_USER=Pi-User)"
check "interface name like an option" 1 "is not a network interface name" -- "$cfg" check "$(conf if1 LAN_INTERFACE=-x)"
check "interface name .." 1 "is not a network interface name" -- "$cfg" check "$(conf if2 LAN_INTERFACE=..)"
check "a VLAN interface is fine" 0 "" -- "$cfg" check "$(conf if3 LAN_INTERFACE=eth0.10)"
check "relative path" 1 "must be an absolute path" -- "$cfg" check "$(conf rel DATA_DIR=mnt/data)"
check "trailing slash" 1 "must be an absolute path" -- "$cfg" check "$(conf ts2 DATA_DIR=/mnt/data/)"
check "dot-dot path" 1 "'.' or '..'" -- "$cfg" check "$(conf dd DATA_DIR=/mnt/../etc)"
check "colon in path" 1 "must be an absolute path" -- "$cfg" check "$(conf colon DATA_DIR=/mnt/a:b)"
check "unknown time zone" 1 "unknown time zone" -- "$cfg" check "$(conf tz TZ=Mars/Olympus)"
check "octet over 255" 1 "not an IPv4 address" -- "$cfg" check "$(conf oct HOST_LAN_IP=192.0.2.256)"
check "leading zero octet" 1 "not an IPv4 address" -- "$cfg" check "$(conf lz HOST_LAN_IP=192.0.2.010)"
check "misaligned network" 1 "did you mean 192.0.2.0/24" -- "$cfg" check "$(conf mis LAN_SUBNET=192.0.2.5/24)"
check "port 0" 1 "not a port" -- "$cfg" check "$(conf p0 SSH_PORT=0)"
check "port 70000" 1 "not a port" -- "$cfg" check "$(conf p7 SSH_PORT=70000)"
check "days 0" 1 "number of days" -- "$cfg" check "$(conf d0 BACKUP_KEEP_DAYS=0)"
check "days 400" 1 "number of days" -- "$cfg" check "$(conf d4 BACKUP_KEEP_DAYS=400)"
check "yes/no only" 1 "must be yes or no" -- "$cfg" check "$(conf yn HARDENING=true)"
check "auto/yes/no only" 1 "must be auto, yes or no" -- "$cfg" check "$(conf au HW_FAN=maybe)"
check "notify choice" 1 "must be telegram or none" -- "$cfg" check "$(conf nt NOTIFY=email)"
check "tailnet with .ts.net" 1 "part before .ts.net" -- "$cfg" check "$(conf tsn TAILSCALE=yes TAILNET_NAME=tail1234.ts.net)"
check "bad restic target" 1 "not a restic repository" -- "$cfg" check "$(conf rb RESTIC_REPOSITORY=ftp:host)"

echo "settings that contradict each other"
check "host outside LAN" 1 "not inside LAN_SUBNET" -- "$cfg" check "$(conf out HOST_LAN_IP=198.51.100.10)"
check "host is network address" 1 "network or broadcast" -- "$cfg" check "$(conf na HOST_LAN_IP=192.0.2.0)"
check "Docker pool overlaps LAN" 1 "overlaps LAN_SUBNET" -- "$cfg" check "$(conf ov DOCKER_ADDRESS_POOL=192.0.2.0/24)"
check "Docker pool too small" 1 "does not fit" -- "$cfg" check "$(conf small DOCKER_ADDRESS_POOL=198.51.100.0/25)"
cgnat="100.100"; cgnat="$cgnat.0.0/16"
check "Docker pool in Tailscale range" 1 "overlaps Tailscale" -- "$cfg" check "$(conf cg TAILSCALE=yes TAILNET_NAME=tail1234 DOCKER_ADDRESS_POOL=$cgnat)"
check "Tailscale without tailnet" 1 "needs TAILNET_NAME" -- "$cfg" check "$(conf tsw TAILNET_NAME=)"
check "Vaultwarden without Tailscale" 1 "needs TAILSCALE=yes" -- "$cfg" check "$(conf vw TAILSCALE=no TAILNET_NAME=)"
check "panel on a container's port" 1 "PANEL_PORT: port 8053 is already used" -- "$cfg" check "$(conf panelpi PANEL_PORT=8053)"
check "panel on the SSH port" 1 "PANEL_PORT: port 22 is already used" -- "$cfg" check "$(conf panelssh PANEL_PORT=22)"
check "panel on a free port" 0 "OK:" -- "$cfg" check "$(conf panelok PANEL_PORT=8091)"
check "web UI on a foreign address" 1 "must be 127.0.0.1 or HOST_LAN_IP" -- "$cfg" check "$(conf ui WEB_UI_ADDRESS=192.0.2.20)"
fixed="172.20"; fixed="$fixed.1.0/24"; fixedhost="172.20"; fixedhost="$fixedhost.1.5"
check "LAN on Decolab's fixed networks" 1 "LAN_SUBNET: overlaps 172.20.0.0/23" -- "$cfg" check "$(conf fx LAN_SUBNET=$fixed HOST_LAN_IP=$fixedhost)"
check "Docker pool on fixed networks" 1 "DOCKER_ADDRESS_POOL: overlaps 172.20.0.0/23" -- "$cfg" check "$(conf fxp DOCKER_ADDRESS_POOL=$fixed)"
check "secrets inside repo" 1 "SECRETS_DIR: must not be inside DECOLAB_DIR" -- "$cfg" check "$(conf sec SECRETS_DIR=/opt/decolab/secrets)"
check "backups inside repo" 1 "BACKUP_DIR: must not be inside DECOLAB_DIR" -- "$cfg" check "$(conf bkr BACKUP_DIR=/opt/decolab/backups)"
check "backups on data dir itself" 1 "must not be DATA_DIR itself" -- "$cfg" check "$(conf bkd BACKUP_DIR=/mnt/data)"
check "USB copy same as backups" 1 "separate place from BACKUP_DIR" -- "$cfg" check "$(conf usb USB_BACKUP_DIR=/mnt/data/backups)"

echo "library use"
check "loader sets the values" 0 "/mnt/data|7|pi" -- bash -c '. "$1/lib/config.sh" && decolab_config_load "$2" && printf "%s|%s|%s" "$DATA_DIR" "$BACKUP_KEEP_DAYS" "$DECOLAB_USER"' _ "$t_root" "$example"
check "loader sets nothing on error" 0 "unset" -- bash -c '. "$1/lib/config.sh"; decolab_config_load "$2" 2>/dev/null; printf "%s" "${DATA_DIR-unset}"' _ "$t_root" "$(conf libbad SSH_PORT=0)"

t_finish
