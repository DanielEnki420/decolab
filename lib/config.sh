# shellcheck shell=bash
# lib/config.sh - strict reader and validator for decolab.conf
#
# The configuration is DATA, never code: this file is parsed line by line and
# is never sourced or evaluated. Values may only contain a small set of
# characters, so shell, systemd, Docker Compose and Python all read it
# the same way.
#
# Usage:
#   . lib/config.sh
#   decolab_config_load decolab.conf || exit 1
#   echo "$DATA_DIR"
#
# On success every key of config/schema.txt is set as a shell variable (not
# exported) and DECOLAB_CONFIG_COUNT holds their number. Errors go to stderr
# as "FILE:LINE: KEY: message", all at once; DECOLAB_CONFIG_ERRORS counts them.
# Compatible with bash 3.2 (macOS) and bash 5 (Raspberry Pi OS / Debian).

DECOLAB_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DECOLAB_SCHEMA=${DECOLAB_SCHEMA:-$DECOLAB_LIB_DIR/../config/schema.txt}
DECOLAB_ZONEINFO=${DECOLAB_ZONEINFO:-/usr/share/zoneinfo}

# Public results for callers (see usage above).
# shellcheck disable=SC2034
DECOLAB_CONFIG_COUNT=0 DECOLAB_CONFIG_ERRORS=0

# --- internal state ----------------------------------------------------------
# bash 3.2 has no associative arrays: per-key data lives in variables named
# _cfgt_<KEY> (type), _cfgr_<KEY> (required), _cfgv_<KEY> (value),
# _cfgl_<KEY> (line number), _cfgs_<KEY> (1 = seen).

_cfg_reset() {
  local k
  for k in ${_cfg_keys:-}; do
    unset "_cfgt_$k" "_cfgr_$k" "_cfgv_$k" "_cfgl_$k" "_cfgs_$k" "_cfgok_$k"
  done
  _cfg_keys=""
  _cfg_errors=0
  _cfg_file=""
}

_cfg_error() { # LINE KEY MESSAGE  (LINE may be empty)
  local where=$_cfg_file
  [ -n "$1" ] && where="$where:$1"
  if [ -n "$2" ]; then
    printf '%s: %s: %s\n' "$where" "$2" "$3" >&2
  else
    printf '%s: %s\n' "$where" "$3" >&2
  fi
  _cfg_errors=$((_cfg_errors + 1))
}

_cfg_warn() { # KEY MESSAGE
  printf '%s: %s: warning: %s\n' "$_cfg_file" "$1" "$2" >&2
}

_cfg_load_schema() {
  local line key type req rest n=0
  if [ ! -r "$DECOLAB_SCHEMA" ]; then
    printf 'decolab-config: schema not readable: %s\n' "$DECOLAB_SCHEMA" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in '' | '#'*) continue ;; esac
    # shellcheck disable=SC2086  # word splitting of the schema line is intended
    set -- $line
    key=${1:-} type=${2:-} req=${3:-} rest=${4:-}
    if [ -z "$req" ] || [ -n "$rest" ] || ! [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] \
      || ! [[ $type =~ ^[a-z0-9]+$ ]]; then
      printf 'decolab-config: %s:%s: expected "KEY TYPE required|optional"\n' "$DECOLAB_SCHEMA" "$n" >&2
      return 1
    fi
    case $req in required | optional) ;; *)
      printf 'decolab-config: %s:%s: "%s" is not required|optional\n' "$DECOLAB_SCHEMA" "$n" "$req" >&2
      return 1 ;;
    esac
    printf -v "_cfgt_$key" '%s' "$type"
    printf -v "_cfgr_$key" '%s' "$req"
    _cfg_keys="$_cfg_keys $key"
  done < "$DECOLAB_SCHEMA"
}

_cfg_known_key() {
  case " $_cfg_keys " in *" $1 "*) return 0 ;; esac
  return 1
}

# --- value helpers -----------------------------------------------------------

# IPv4 "a.b.c.d" -> integer in _cfg_int. Rejects leading zeros (ambiguous: octal).
_cfg_ip_to_int() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' i o
  [[ $1 =~ $re ]] || return 1
  _cfg_int=0
  for i in 1 2 3 4; do
    o=${BASH_REMATCH[$i]}
    case $o in 0) ;; 0*) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
    _cfg_int=$((_cfg_int * 256 + o))
  done
}

_cfg_int_to_ip() {
  printf '%d.%d.%d.%d' $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255))
}

# CIDR -> _cfg_net (int), _cfg_len (prefix), _cfg_size (addresses).
# Returns 1 if malformed, 2 if the address is not the network address.
_cfg_cidr() {
  local ip=${1%/*} len=${1#*/}
  case $1 in */*) ;; *) return 1 ;; esac
  case $len in '' | *[!0-9]* | 0?*) return 1 ;; esac
  [ "$len" -le 32 ] || return 1
  _cfg_ip_to_int "$ip" || return 1
  _cfg_len=$len
  _cfg_size=$((1 << (32 - len)))
  _cfg_net=$((_cfg_int / _cfg_size * _cfg_size))
  [ "$_cfg_net" -eq "$_cfg_int" ] || return 2
}

_cfg_overlap() { # NET1 SIZE1 NET2 SIZE2
  [ "$1" -lt $(($3 + $4)) ] && [ "$3" -lt $(($1 + $2)) ]
}

_cfg_path_inside() { # PATH BASE -> true if PATH is BASE or below it
  case "$1/" in "$2/"*) return 0 ;; esac
  return 1
}

# --- type checks -------------------------------------------------------------

_cfg_check_type() { # LINE KEY TYPE VALUE
  local line=$1 key=$2 type=$3 v=$4 re
  case $type in
    user)
      re='^[a-z_][a-z0-9_-]{0,31}$'
      if ! [[ $v =~ $re ]]; then
        _cfg_error "$line" "$key" "'$v' is not a valid Linux user name"
      elif [ "$v" = root ]; then
        _cfg_error "$line" "$key" "must not be root"
      else return 0; fi ;;
    abspath)
      re='^(/[A-Za-z0-9._+-]+)+$'
      if ! [[ $v =~ $re ]]; then
        _cfg_error "$line" "$key" "'$v' must be an absolute path (no spaces, no ':', no trailing '/')"
      else
        case "$v/" in
          */./* | */../*) _cfg_error "$line" "$key" "'$v' must not contain '.' or '..' components" ;;
          *) return 0 ;;
        esac
      fi ;;
    tz)
      re='^(UTC|[A-Za-z]+(/[A-Za-z0-9_+-]+){1,2})$'
      if ! [[ $v =~ $re ]]; then
        _cfg_error "$line" "$key" "'$v' is not a time zone like Europe/Berlin"
      elif [ -d "$DECOLAB_ZONEINFO" ] && [ ! -f "$DECOLAB_ZONEINFO/$v" ]; then
        _cfg_error "$line" "$key" "unknown time zone '$v'"
      else return 0; fi ;;
    iface)
      # first character no dot or dash: ".." or "-x" would pass otherwise
      re='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$'
      if [[ $v =~ $re ]]; then return 0; fi
      _cfg_error "$line" "$key" "'$v' is not a network interface name" ;;
    ipv4)
      if _cfg_ip_to_int "$v"; then return 0; fi
      _cfg_error "$line" "$key" "'$v' is not an IPv4 address" ;;
    cidr)
      _cfg_cidr "$v"
      case $? in
        0) return 0 ;;
        2) _cfg_error "$line" "$key" "'$v' is not a network address (did you mean $(_cfg_int_to_ip "$_cfg_net")/$_cfg_len?)" ;;
        *) _cfg_error "$line" "$key" "'$v' is not an IPv4 network like 192.0.2.0/24" ;;
      esac ;;
    port)
      re='^[1-9][0-9]{0,4}$'
      if [[ $v =~ $re ]] && [ "$v" -le 65535 ]; then return 0; fi
      _cfg_error "$line" "$key" "'$v' is not a port (1-65535)" ;;
    yesno)
      case $v in yes | no) return 0 ;; esac
      _cfg_error "$line" "$key" "'$v' must be yes or no" ;;
    auto)
      case $v in auto | yes | no) return 0 ;; esac
      _cfg_error "$line" "$key" "'$v' must be auto, yes or no" ;;
    days)
      re='^[1-9][0-9]{0,2}$'
      if [[ $v =~ $re ]] && [ "$v" -le 365 ]; then return 0; fi
      _cfg_error "$line" "$key" "'$v' must be a number of days (1-365)" ;;
    tailnet)
      re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
      if [[ $v =~ $re ]]; then return 0; fi
      case $v in
        *.ts.net) _cfg_error "$line" "$key" "give only the part before .ts.net ('${v%.ts.net}')" ;;
        *) _cfg_error "$line" "$key" "'$v' is not a tailnet name like tail1234" ;;
      esac ;;
    notify)
      case $v in telegram | none) return 0 ;; esac
      _cfg_error "$line" "$key" "'$v' must be telegram or none" ;;
    restic)
      case $v in
        /*) _cfg_check_type "$line" "$key" abspath "$v" && return 0 ;;
        sftp:?* | rest:?* | s3:?* | b2:?* | azure:?* | gs:?* | swift:?* | rclone:?*) return 0 ;;
        *) _cfg_error "$line" "$key" "'$v' is not a restic repository (absolute path or sftp:, rest:, s3:, b2:, azure:, gs:, swift:, rclone:)" ;;
      esac ;;
    *)
      _cfg_error "" "$key" "schema names unknown type '$type'" ;;
  esac
  return 1
}

# --- parser ------------------------------------------------------------------

_cfg_parse() { # FILE
  local line n=0 key value re_line='^([^=]*)=(.*)$' re_key='^[A-Z][A-Z0-9_]*$'
  local re_chars='^[A-Za-z0-9._/:@+,-]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in
      *$'\r'*) _cfg_error "$n" "" "Windows line ending (CR) found; save the file with LF line endings"; continue ;;
    esac
    case $line in
      '#'*) continue ;;
      *[![:space:]]*) ;;
      *) continue ;; # empty or whitespace only
    esac
    case $line in
      [[:space:]]*) _cfg_error "$n" "" "line must start with the key, not with whitespace"; continue ;;
    esac
    if ! [[ $line =~ $re_line ]]; then
      _cfg_error "$n" "" "expected KEY=VALUE"
      continue
    fi
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    if ! [[ $key =~ $re_key ]]; then
      _cfg_error "$n" "" "'$key' is not a valid key (upper case letters, digits, _; no spaces around '=')"
      continue
    fi
    if ! _cfg_known_key "$key"; then
      _cfg_error "$n" "$key" "unknown setting (typo? see config/schema.txt)"
      continue
    fi
    if [ -n "$(eval "printf %s \"\${_cfgs_$key:-}\"")" ]; then
      _cfg_error "$n" "$key" "set twice (first on line $(eval "printf %s \"\$_cfgl_$key\""))"
      continue
    fi
    printf -v "_cfgs_$key" '%s' 1
    printf -v "_cfgl_$key" '%s' "$n"
    if ! [[ $value =~ $re_chars ]]; then
      _cfg_error "$n" "$key" "value contains characters that are not allowed (no quotes, spaces, \$, #; only letters, digits and . _ / : @ + , -)"
      continue
    fi
    printf -v "_cfgv_$key" '%s' "$value"
  done < "$1"
}

# _cfg_val KEY -> value in _cfg_value; returns 1 if the key has no valid value
_cfg_val() {
  local ok
  eval "ok=\${_cfgok_$1:-}; _cfg_value=\${_cfgv_$1:-}"
  [ "$ok" = 1 ]
}

_cfg_line() { eval "printf %s \"\${_cfgl_$1:-}\""; }

# --- cross checks ------------------------------------------------------------

_cfg_cross_checks() {
  local lan_net lan_size pool_net pool_size v d

  if _cfg_val LAN_SUBNET; then
    _cfg_cidr "$_cfg_value"; lan_net=$_cfg_net lan_size=$_cfg_size
    if [ "$_cfg_len" -lt 8 ] || [ "$_cfg_len" -gt 30 ]; then
      _cfg_error "$(_cfg_line LAN_SUBNET)" LAN_SUBNET "prefix /$_cfg_len is not a usable LAN (use /8 to /30)"
    fi
    if _cfg_val HOST_LAN_IP; then
      _cfg_ip_to_int "$_cfg_value"
      if ! _cfg_overlap "$_cfg_int" 1 "$lan_net" "$lan_size"; then
        _cfg_error "$(_cfg_line HOST_LAN_IP)" HOST_LAN_IP "'$_cfg_value' is not inside LAN_SUBNET"
      elif [ "$_cfg_int" -eq "$lan_net" ] || [ "$_cfg_int" -eq $((lan_net + lan_size - 1)) ]; then
        _cfg_error "$(_cfg_line HOST_LAN_IP)" HOST_LAN_IP "'$_cfg_value' is the network or broadcast address of LAN_SUBNET"
      fi
    fi
  fi

  if _cfg_val DOCKER_ADDRESS_POOL; then
    _cfg_cidr "$_cfg_value"; pool_net=$_cfg_net pool_size=$_cfg_size
    if [ "$_cfg_len" -gt 24 ] || [ "$_cfg_len" -lt 8 ]; then
      _cfg_error "$(_cfg_line DOCKER_ADDRESS_POOL)" DOCKER_ADDRESS_POOL "prefix /$_cfg_len does not fit Docker's /24 networks (use /8 to /24)"
    fi
    if [ -n "${lan_net:-}" ] && _cfg_overlap "$pool_net" "$pool_size" "$lan_net" "$lan_size"; then
      _cfg_error "$(_cfg_line DOCKER_ADDRESS_POOL)" DOCKER_ADDRESS_POOL "overlaps LAN_SUBNET; Docker networks would hide LAN devices"
    fi
    # Tailscale uses 100.64.0.0/10 for its devices
    if _cfg_val TAILSCALE && [ "$_cfg_value" = yes ] \
      && _cfg_overlap "$pool_net" "$pool_size" $((100 << 24 | 64 << 16)) $((1 << 22)); then
      _cfg_error "$(_cfg_line DOCKER_ADDRESS_POOL)" DOCKER_ADDRESS_POOL "overlaps Tailscale's 100.64.0.0/10"
    fi
  fi

  # Decolab's fixed Docker networks (DNS, Uptime Kuma) live in 172.20.0.0/23.
  local fixed_net=$((172 << 24 | 20 << 16)) fixed_size=512
  if [ -n "${lan_net:-}" ] && _cfg_overlap "$lan_net" "$lan_size" "$fixed_net" "$fixed_size"; then
    _cfg_error "$(_cfg_line LAN_SUBNET)" LAN_SUBNET "overlaps 172.20.0.0/23, which Decolab uses for its fixed Docker networks"
  fi
  if [ -n "${pool_net:-}" ] && _cfg_overlap "$pool_net" "$pool_size" "$fixed_net" "$fixed_size"; then
    _cfg_error "$(_cfg_line DOCKER_ADDRESS_POOL)" DOCKER_ADDRESS_POOL "overlaps 172.20.0.0/23, which Decolab uses for its fixed Docker networks"
  fi

  if _cfg_val WEB_UI_ADDRESS; then
    v=$_cfg_value
    _cfg_val HOST_LAN_IP || true
    if [ "$v" != 127.0.0.1 ] && [ "$v" != "$_cfg_value" ]; then
      _cfg_error "$(_cfg_line WEB_UI_ADDRESS)" WEB_UI_ADDRESS "must be 127.0.0.1 or HOST_LAN_IP"
    elif [ "$v" = 127.0.0.1 ] && _cfg_val TAILSCALE && [ "$_cfg_value" = no ]; then
      _cfg_warn WEB_UI_ADDRESS "127.0.0.1 without Tailscale: the web interfaces are only reachable through an SSH tunnel"
    fi
  fi

  # The panel's port must not collide with a port a container publishes
  # (compose files) or with SSH: the panel would not start.
  if _cfg_val PANEL_PORT; then
    v=$_cfg_value
    _cfg_val SSH_PORT || true
    case " 53 139 445 2283 3001 8053 8500 8800 9000 9090 $_cfg_value " in
      *" $v "*) _cfg_error "$(_cfg_line PANEL_PORT)" PANEL_PORT "port $v is already used by SSH or a container" ;;
    esac
  fi

  if _cfg_val MODULE_VAULTWARDEN && [ "$_cfg_value" = yes ] && _cfg_val TAILSCALE && [ "$_cfg_value" = no ]; then
    _cfg_error "$(_cfg_line MODULE_VAULTWARDEN)" MODULE_VAULTWARDEN "needs TAILSCALE=yes: the web vault only works over HTTPS"
  fi

  if _cfg_val TAILSCALE; then
    v=$_cfg_value
    _cfg_val TAILNET_NAME || true
    if [ "$v" = yes ] && [ -z "$_cfg_value" ]; then
      _cfg_error "$(_cfg_line TAILSCALE)" TAILSCALE "TAILSCALE=yes needs TAILNET_NAME"
    elif [ "$v" = no ] && [ -n "$_cfg_value" ]; then
      _cfg_warn TAILNET_NAME "ignored because TAILSCALE=no"
    fi
  fi

  if _cfg_val DECOLAB_DIR; then
    d=$_cfg_value
    for v in SECRETS_DIR BACKUP_DIR; do
      if _cfg_val "$v" && _cfg_path_inside "$_cfg_value" "$d"; then
        _cfg_error "$(_cfg_line "$v")" "$v" "must not be inside DECOLAB_DIR ($d): it could end up in git"
      fi
    done
  fi

  if _cfg_val BACKUP_DIR; then
    d=$_cfg_value
    if _cfg_val DATA_DIR && [ "$_cfg_value" = "$d" ]; then
      _cfg_error "$(_cfg_line BACKUP_DIR)" BACKUP_DIR "must not be DATA_DIR itself"
    fi
    if _cfg_val USB_BACKUP_DIR && [ -n "$_cfg_value" ] \
      && { _cfg_path_inside "$_cfg_value" "$d" || _cfg_path_inside "$d" "$_cfg_value"; }; then
      _cfg_error "$(_cfg_line USB_BACKUP_DIR)" USB_BACKUP_DIR "must be a separate place from BACKUP_DIR"
    fi
  fi
}

# --- public entry point ------------------------------------------------------

decolab_config_load() { # FILE
  local file=${1:?usage: decolab_config_load FILE} key type req value line seen isset
  _cfg_reset
  _cfg_load_schema || return 1
  _cfg_file=$file
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    _cfg_error "" "" "cannot read file"
    DECOLAB_CONFIG_ERRORS=$_cfg_errors
    return 1
  fi
  _cfg_parse "$file"

  for key in $_cfg_keys; do
    eval "type=\$_cfgt_$key req=\$_cfgr_$key line=\${_cfgl_$key:-} seen=\${_cfgs_$key:-}"
    if [ -z "$seen" ]; then
      _cfg_error "" "$key" "missing (every setting from config/schema.txt must be present)"
      continue
    fi
    eval "isset=\${_cfgv_$key+1} value=\${_cfgv_$key:-}"
    [ -n "$isset" ] || continue # invalid characters, already reported by the parser
    if [ -z "$value" ]; then
      if [ "$req" = required ]; then
        _cfg_error "$line" "$key" "must not be empty"
      else
        printf -v "_cfgok_$key" '%s' 1
      fi
      continue
    fi
    if _cfg_check_type "$line" "$key" "$type" "$value"; then
      printf -v "_cfgok_$key" '%s' 1
    fi
  done

  _cfg_cross_checks
  # shellcheck disable=SC2034  # public result, read by callers
  DECOLAB_CONFIG_ERRORS=$_cfg_errors
  [ "$_cfg_errors" -eq 0 ] || return 1

  DECOLAB_CONFIG_COUNT=0
  for key in $_cfg_keys; do
    eval "value=\$_cfgv_$key"
    printf -v "$key" '%s' "$value"
    DECOLAB_CONFIG_COUNT=$((DECOLAB_CONFIG_COUNT + 1))
  done
}
