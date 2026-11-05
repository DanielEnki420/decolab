#!/usr/bin/env bash
# Contract tests for bin/decolab-firewall and config/firewall/decolab-firewall-boot:
# the rule set, the checks that keep the current login, the trial with its
# way back, confirm only from a new login, and monitor.sh's view of it.
# Host commands (nft, ss, ps, ip, systemctl, systemd-run, sshd) are stubs;
# every host path lies below FW_ROOT. The rule set itself was checked with
# the real nft (nft -c, and loaded in a separate network namespace: the
# listing in tests/data/nft-list-decolab.txt).
# shellcheck disable=SC2016 # single-quoted fake code is evaluated by the stubs
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/script-env.sh
. "$t_root/tests/script-env.sh"

fw=$t_root/bin/decolab-firewall
bootsh=$t_root/config/firewall/decolab-firewall-boot
stub=$t_tmp/bin
mkdir -p "$stub"
export PATH="$stub:$PATH"
export FW_ROOT=$t_tmp/host FW_BOOT=$bootsh FW_ROLLBACK_S=300
H=$FW_ROOT
mkdir -p "$H/var/lib/decolab" "$H/etc/ssh/sshd_config.d"
calls=$t_tmp/calls.log

# ps: the process tree. Our own processes are unknown to the table and hang
# below FAKE_PS_TOP; the table rows are "pid ppid comm etimes".
cat >"$stub/ps" <<'EOF'
#!/bin/bash
field=$2 pid=$4
row=$(printf '%s\n' "$FAKE_PS" | awk -v p="$pid" '$1 == p')
[ -n "$row" ] || row="$pid ${FAKE_PS_TOP:-1} bash 5"
set -- $row
case $field in
  comm=) echo "$3" ;;
  ppid=) echo "$2" ;;
  etimes=) echo "$4" ;;
esac
EOF
cat >"$stub/ss" <<'EOF'
#!/bin/sh
case "$*" in
  *-ltnH*) printf '%s\n' "${FAKE_SS_LISTEN-LISTEN 0 128 0.0.0.0:22 0.0.0.0:*}" ;;
  *established*) printf '%s\n' "$FAKE_SS_EST" ;;
esac
EOF
cat >"$stub/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_IP-2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0}"
EOF
cat >"$stub/nft" <<'EOF'
#!/bin/sh
echo "nft $*" >>"$CALLS"
case "$*" in
  "-c -f"*) [ -z "${FAKE_NFT_BAD:-}" ] || { echo "Error: syntax error" >&2; exit 1; } ;;
  "list table inet decolab") cat "${FAKE_NFT_LIST:-/dev/null}" ;;
esac
exit 0
EOF
cat >"$stub/sshd" <<'EOF'
#!/bin/sh
echo "sshd $*" >>"$CALLS"
[ -z "${FAKE_SSHD_BAD:-}" ] || { echo "bad option" >&2; exit 1; }
# -T: what the drop-in says (FAKE_SSHD_OVERRIDE: a Match block that allows
# passwords anyway)
case "$*" in *-T*)
  if [ -z "${FAKE_SSHD_OVERRIDE:-}" ] && grep -qx "PasswordAuthentication no" "$FW_ROOT/etc/ssh/sshd_config.d/01-decolab.conf" 2>/dev/null
  then echo "passwordauthentication no"; else echo "passwordauthentication yes"; fi ;;
esac
EOF
cat >"$stub/systemd-run" <<'EOF'
#!/bin/sh
echo "systemd-run $*" >>"$CALLS"
[ -n "${FAKE_NO_TIMER:-}" ] || touch "$FAKE_UNITS/timer"
EOF
cat >"$stub/logger" <<'EOF'
#!/bin/sh
EOF
cat >"$stub/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && shift
exec "$@"
EOF
chmod +x "$stub"/*
export CALLS=$calls FAKE_UNITS=$t_tmp/units
mkdir -p "$FAKE_UNITS"
export FAKE_SYSTEMCTL='echo "systemctl $*" >>"$CALLS"
case "$1 $2" in
  "is-active decolab-firewall-rollback.timer") [ -e "$FAKE_UNITS/timer" ] && echo active || { echo inactive; exit 3; } ;;
  "stop decolab-firewall-rollback.timer") rm -f "$FAKE_UNITS/timer" ;;
  "is-active ufw") echo "${FAKE_UFW:-inactive}" ;;
  "is-active firewalld") echo inactive ;;
  "is-enabled nftables.service") echo "${FAKE_NFTABLES:-disabled}" ;;
  "is-active decolab-firewall.service") echo "${FAKE_FW_UNIT:-active}" ;;
  "enable decolab-firewall.service") touch "$FAKE_UNITS/enabled" ;;
  "disable decolab-firewall.service") rm -f "$FAKE_UNITS/enabled" ;;
esac'

lan="192.0.2"
ts="100.101"; ts="$ts.102.103" # a made-up tailnet address, built at run time (guard)
# login FROM AGE - this command runs in an SSH login from FROM, AGE seconds old
login() {
  export FAKE_PS_TOP=4000 FAKE_PS="4000 3999 sshd-session $2
3999 1 sshd-session $2"
  export FAKE_SS_EST="0 0 $lan.10:22 $1:51515 users:((\"sshd-session\",pid=3999,fd=4),(\"sshd-session\",pid=4000,fd=4))"
}
fresh() {
  rm -rf "$H/var/lib/decolab"/* "$H/etc/decolab" "$H/etc/ssh/sshd_config.d"/* "${FAKE_UNITS:?}"/*
  : >"$calls"
}
sed -i.bak -e 's/^HARDENING=.*/HARDENING=yes/' "$DECOLAB_CONF"

echo "rule set"
check "renders" 0 "table inet decolab {" -- "$fw" rules
rules=$out
check "  input drops by default" 0 "hook input priority filter - 1; policy drop;" -- printf '%s' "$rules"
check "  SSH from the LAN over IPv4" 0 "ip saddr @lan4 tcp dport 22 accept" -- printf '%s' "$rules"
check "  ... and over IPv6" 0 "ip6 saddr @lan6 tcp dport 22 accept" -- printf '%s' "$rules"
check "  the LAN set is LAN_SUBNET" 0 "elements = { $lan.0/24 }" -- printf '%s' "$rules"
check "  forward ends in drop" 0 "    drop
  }" -- printf '%s' "$rules"
check "  replaces only its own table" 0 "table inet decolab {}
delete table inet decolab" -- printf '%s' "$rules"
check "  never flushes everything" 1 "" -- grep -qE '^[^#]*flush' <<<"$rules"
check "  internal interfaces by name, not 'all but eth0'" 1 "" -- grep -qE '!= ?"?eth|! -i' <<<"$rules"
check "  containers reach the host for DNS only" 0 'iifname { "docker0", "br-*" } meta l4proto { tcp, udp } th dport 53 accept' -- printf '%s' "$rules"
check "  ... no blanket accept from containers" 1 "" -- grep -qE 'iifname \{ "docker0", "br-\*" \} accept' <<<"$rules"
check "  web interfaces closed with WEB_UI_ADDRESS=127.0.0.1" 1 "" -- grep -q "8053" <<<"$rules"
sed -i.bak "s/^WEB_UI_ADDRESS=.*/WEB_UI_ADDRESS=$lan.10/" "$DECOLAB_CONF"
check "  open to the LAN with WEB_UI_ADDRESS=HOST_LAN_IP" 0 "ip saddr @lan4 tcp dport { 8053, 9000, 3001, 2283, 8090 } accept" -- "$fw" rules
# The list in decolab-firewall must be exactly the ports the compose files
# publish on WEB_UI_ADDRESS.
published=$(cd "$t_root" && grep -ohE '"\$\{WEB_UI_ADDRESS\}:[0-9]+' compose/core.yml stacks/*/compose.yml | sed 's/.*://' | sort -n | tr '\n' ' ')
listed=$(grep -oE 'dport \{ [0-9, ]+ \} accept' <<<"$out" | tail -1 | grep -oE '[0-9]+' | grep -vx 8090 | sort -n | tr '\n' ' ')
same "  every web interface port of the compose files, no other" "$listed" "$published"
sed -i.bak "s/^WEB_UI_ADDRESS=.*/WEB_UI_ADDRESS=127.0.0.1/" "$DECOLAB_CONF"
check "  Tailscale's UDP port with TAILSCALE=yes" 0 "udp dport 41641 accept" -- "$fw" rules
check "  the real nft listed this rule set (data file present)" 0 "policy drop;" -- cat "$t_root/tests/data/nft-list-decolab.txt"

echo "check: keep the current login"
fresh
login "$lan.50" 600
check "from the LAN: fine" 0 "OK: apply would keep this login (ssh from $lan.50)" -- "$fw" check
# As a normal user, ss shows no process of root's sshd: then check takes the
# address from SSH_CONNECTION (seen on Debian 13: check always refused).
export FAKE_SS_EST="0 0 $lan.10:22 $lan.50:51515"
SSH_CONNECTION="$lan.50 51515 $lan.10 22" check "not root, ss without the process: SSH_CONNECTION" 0 "OK: apply would keep this login (ssh from $lan.50)" -- "$fw" check
SSH_CONNECTION="203.0.113.7 51515 $lan.10 22" check "  ... from outside the LAN: refused" 1 "outside LAN_SUBNET" -- "$fw" check
check "  ... without SSH_CONNECTION: cannot tell, refused" 1 "cannot see from where this SSH login comes" -- env -u SSH_CONNECTION "$fw" check
login "fe80::1234" 600
check "from IPv6 link-local: fine" 0 "OK" -- "$fw" check
login "203.0.113.7" 600
check "from outside the LAN: refused" 1 "outside LAN_SUBNET" -- "$fw" check
login "$ts" 600
check "over Tailscale with TAILSCALE=yes: fine" 0 "OK" -- "$fw" check
login "$lan.50" 600
FAKE_UFW=active check "UFW active: refused" 1 "ufw is active" -- "$fw" check
FAKE_NFTABLES=enabled check "Debian's nftables.service enabled: refused" 1 "nftables.service is enabled" -- "$fw" check
FAKE_SS_LISTEN="" check "sshd not on SSH_PORT: refused" 1 "nothing listens on SSH_PORT 22" -- "$fw" check
FAKE_IP="2: eth0 inet 198.51.100.4/24" check "HOST_LAN_IP not on this host: refused" 1 "is on no interface" -- "$fw" check
FAKE_NFT_BAD=1 check "nft rejects the rules: refused" 1 "nft rejects the rule set" -- "$fw" check
export FAKE_PS="" FAKE_PS_TOP=1
check "no login, no terminal: refused" 1 "neither an SSH login nor a terminal" -- "$fw" check </dev/null
sed -i.bak 's/^HARDENING=.*/HARDENING=no/' "$DECOLAB_CONF"
login "$lan.50" 600
check "HARDENING=no: refused" 1 "HARDENING=no" -- "$fw" check
sed -i.bak 's/^HARDENING=.*/HARDENING=yes/' "$DECOLAB_CONF"

echo "apply: on trial, the way back first"
fresh
login "$lan.50" 600
check "applies" 0 "ON TRIAL" -- "$fw" apply
applied=$out
check "  the timer is armed before any rule is loaded" 0 "" -- awk '/^systemd-run/ { t = NR } /^nft -f/ { n = NR } END { exit !(t && n && t < n) }' "$calls"
check "  the timer runs the way back in 300 s" 0 "" -- grep -qE -- '--on-active=300( |$)' "$calls"
check "  ... decolab-firewall-boot off" 0 "decolab-firewall-boot off" -- grep systemd-run "$calls"
check "  pending" 0 "" -- test -s "$H/var/lib/decolab/firewall-pending"
check "  SSH drop-in in place, checked by sshd -t" 0 "sshd -t" -- cat "$calls"
check "  ... named 01- (sshd keeps the first value)" 0 "" -- test -f "$H/etc/ssh/sshd_config.d/01-decolab.conf"
check "  SSH_PASSWORDS=yes: passwords untouched" 1 "" -- grep -q "^PasswordAuthentication" "$H/etc/ssh/sshd_config.d/01-decolab.conf"
check "  nothing permanent: no rules file" 1 "" -- test -e "$H/etc/decolab/firewall.nft"
check "  nothing permanent: unit not enabled" 1 "" -- test -e "$FAKE_UNITS/enabled"
check "  says how to confirm" 0 "NEW SSH login" -- printf '%s' "$applied"
fresh
FAKE_NO_TIMER=1 check "timer not armed: nothing loaded" 1 "could not be armed: nothing changed" -- "$fw" apply
check "  no nft -f" 1 "" -- grep -q "^nft -f" "$calls"
check "  not pending" 1 "" -- test -e "$H/var/lib/decolab/firewall-pending"
fresh
FAKE_SSHD_BAD=1 check "sshd rejects the drop-in: firewall still on trial" 0 "left out, SSH unchanged" -- "$fw" apply
check "  no drop-in" 1 "" -- test -e "$H/etc/ssh/sshd_config.d/01-decolab.conf"
dropin=$H/etc/ssh/sshd_config.d/01-decolab.conf
echo "SSH_PASSWORDS=no: keys only, proven by the login that confirms"
sed -i.bak 's/^SSH_PASSWORDS=.*/SSH_PASSWORDS=no/' "$DECOLAB_CONF"
keys=$H$(python3 -I -c 'import pwd, sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$(sed -n 's/^DECOLAB_USER=//p' "$DECOLAB_CONF")")/.ssh/authorized_keys
fresh
login "$lan.50" 600
check "no key for the user: refused" 1 "holds no key" -- "$fw" apply
mkdir -p "${keys%/*}" && echo "ssh-ed25519 AAAAC3NzaTEST probe" >"$keys"
fresh
login "$lan.50" 600
check "with a key: on trial, passwords off" 0 "with your key: passwords are off" -- "$fw" apply
check "  PasswordAuthentication no in the drop-in" 0 "" -- grep -qx "PasswordAuthentication no" "$dropin"
check "  ... and KbdInteractiveAuthentication no" 0 "" -- grep -qx "KbdInteractiveAuthentication no" "$dropin"
check "  sshd asked what it really does for the user" 0 "" -- grep -q "^sshd -T -C user=" "$calls"
login "$lan.51" 0
check "  the new login (a key, passwords are off) confirms" 0 "CONFIRMED" -- "$fw" confirm
fresh
login "$lan.50" 600
FAKE_SSHD_OVERRIDE=1 check "sshd still allows passwords (a Match block): switched off again" 1 "still allows passwords" -- "$fw" apply
check "  drop-in gone, passwords as before" 1 "" -- test -e "$dropin"
check "  not on trial" 1 "" -- test -e "$H/var/lib/decolab/firewall-pending"
fresh
login "$lan.50" 600
FAKE_SSHD_BAD=1 check "sshd rejects the drop-in: switched off again" 1 "cannot take effect" -- "$fw" apply
check "  not on trial" 1 "" -- test -e "$H/var/lib/decolab/firewall-pending"
sed -i.bak 's/^SSH_PASSWORDS=.*/SSH_PASSWORDS=yes/' "$DECOLAB_CONF"
rm -f "$keys"

fresh
login "203.0.113.7" 600
check "refused checks: nothing changed" 1 "Nothing changed" -- "$fw" apply
same "  not a single call" "$(grep -cE '^(nft -f|systemd-run)' "$calls")" "0"

echo "confirm: only from a new login over the LAN"
fresh
login "$lan.50" 600
"$fw" apply >/dev/null
check "the login that applied: refused" 1 "started before the apply" -- "$fw" confirm
check "  still on trial" 0 "" -- test -e "$FAKE_UNITS/timer"
login "$ts" 0
check "a new login over Tailscale: refused (LAN not proven)" 1 "LAN way in is not proven" -- "$fw" confirm
login "$lan.51" 0
check "a new login from the LAN: confirmed" 0 "CONFIRMED from $lan.51" -- "$fw" confirm
check "  timer stopped" 1 "" -- test -e "$FAKE_UNITS/timer"
check "  unit enabled" 0 "" -- test -e "$FAKE_UNITS/enabled"
check "  ... and started now, not only at the next boot" 0 "" -- grep -qx "systemctl start decolab-firewall.service" "$calls"
check "  rules file in place" 0 "" -- grep -q "policy drop" "$H/etc/decolab/firewall.nft"
check "  confirmed, not pending" 0 "" -- test -f "$H/var/lib/decolab/firewall-confirmed" -a ! -e "$H/var/lib/decolab/firewall-pending"
check "nothing pending: nothing to confirm" 1 "nothing to confirm" -- "$fw" confirm
fresh
login "$lan.50" 600
"$fw" apply >/dev/null
login "$ts" 0
check "over Tailscale with --tailscale-ok: confirmed" 0 "CONFIRMED" -- "$fw" confirm --tailscale-ok
fresh
login "$lan.50" 600
"$fw" apply >/dev/null
rm -f "$FAKE_UNITS/timer"
login "$lan.51" 0
check "the trial already ended: refused" 1 "the trial is over" -- "$fw" confirm
check "  nothing made permanent" 1 "" -- test -e "$FAKE_UNITS/enabled"
fresh
login "$lan.50" 600
"$fw" apply >/dev/null
export FAKE_PS="" FAKE_PS_TOP=1
check "confirm from a console: refused" 1 "only from an SSH login" -- "$fw" confirm

echo "the way back (decolab-firewall-boot)"
fresh
mkdir -p "$H/etc/decolab" && echo "table inet decolab {}" >"$H/etc/decolab/firewall.nft"
check "boot: loads the confirmed rules" 0 "loaded" -- "$bootsh" boot
check "  with nft -f" 0 "" -- grep -q "^nft -f $H/etc/decolab/firewall.nft" "$calls"
date +%s >"$H/var/lib/decolab/firewall-pending"
: >"$H/etc/ssh/sshd_config.d/01-decolab.conf"
touch "$FAKE_UNITS/enabled"
: >"$calls"
check "boot after an unconfirmed apply: off" 0 "was not confirmed" -- "$bootsh" boot
check "  table deleted" 0 "" -- grep -q "^nft delete table inet decolab" "$calls"
check "  no rules loaded" 1 "" -- grep -q "^nft -f" "$calls"
check "  SSH drop-in removed" 1 "" -- test -e "$H/etc/ssh/sshd_config.d/01-decolab.conf"
check "  unit disabled" 1 "" -- test -e "$FAKE_UNITS/enabled"
mkdir -p "$H/boot/firmware" && : >"$H/boot/firmware/decolab-firewall-off"
: >"$calls"
check "break-glass file on the boot partition: off" 0 "break-glass" -- "$bootsh" boot
check "  nothing loaded" 1 "" -- grep -q "^nft -f" "$calls"
rm -f "$H/boot/firmware/decolab-firewall-off"
check "off by hand" 0 "OFF" -- "$fw" off

echo "monitor.sh sees it"
export FAKE_DOCKER='case "$*" in *"{{.State.Status}}"*) echo running ;; esac' MONITOR_FW_STATE=$H/var/lib/decolab
fresh
check "HARDENING=yes, nothing confirmed: alarm" 1 "no firewall is confirmed" -- script monitor.sh
date +%s >"$H/var/lib/decolab/firewall-confirmed"
export FAKE_NFT_LIST=$t_root/tests/data/nft-list-decolab.txt
rm -f "$DECOLAB_STATE_DIR"/monitor* 2>/dev/null
check "confirmed, unit active, table complete: no firewall alarm" 0 "containers running" -- script monitor.sh
FAKE_FW_UNIT=failed check "unit failed: alarm" 1 "decolab-firewall.service is 'failed'" -- script monitor.sh
grep -v '^[[:space:]]*drop$' "$FAKE_NFT_LIST" >"$t_tmp/nodrop.txt"
FAKE_NFT_LIST=$t_tmp/nodrop.txt check "no final drop: alarm" 1 "incomplete" -- script monitor.sh
sed 's/policy drop;/policy accept;/' "$t_root/tests/data/nft-list-decolab.txt" >"$t_tmp/accept.txt"
FAKE_NFT_LIST=$t_tmp/accept.txt check "input accepts by default: alarm" 1 "incomplete" -- script monitor.sh
FAKE_NFT_LIST=/dev/null check "table missing: alarm" 1 "missing or unreadable" -- script monitor.sh
rm -f "$H/var/lib/decolab/firewall-confirmed"
echo $(($(date +%s) - 900)) >"$H/var/lib/decolab/firewall-pending"
check "a trial pending for 15 minutes: alarm" 1 "pending for more than 10 minutes" -- script monitor.sh

t_finish
