#!/usr/bin/env bash
# Contract tests for "decolab-config init": the questions, the suggestions it
# finds on the host, and that it writes only a valid file and never over one.
# Single quotes around $… are intended: the code runs in a child shell.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cfg=$t_root/bin/decolab-config

# A made-up Pi: documentation addresses, built from halves for tools/guard.sh.
net="192.0" net="$net.2"
pi="$net.57"
lan="10.2" lan="${lan}10.4"
sys=$t_tmp/sys
mkdir -p "$sys/etc/ssh/sshd_config.d" "$t_tmp/home/.ssh"
ln -s /usr/share/zoneinfo/Europe/Berlin "$sys/etc/localtime"
printf 'Port 22\n' > "$sys/etc/ssh/sshd_config"
printf '# moved\nPort 2201\n' > "$sys/etc/ssh/sshd_config.d/10-port.conf"
tsjson='{"Self":{},"MagicDNSSuffix":"tail5678.ts.net","Version":"1"}'

# run NAME [VAR=VALUE...] -- ARGS : init with the fake host; stdin passes through
host() {
  env PATH="$t_root/tests/fakes:$PATH" HOME="$t_tmp/home" DECOLAB_SYSROOT="$sys" \
    SUDO_USER=alice \
    FAKE_IP_ROUTE="default via $net.1 dev eth0 proto dhcp src $pi metric 100" \
    FAKE_IP_ADDR="2: eth0    inet $pi/24 brd $net.255 scope global dynamic noprefixroute eth0" \
    FAKE_TAILSCALE_JSON="$tsjson" "$@"
}
val() { sed -n "s/^$1=//p" "$2"; }

f=$t_tmp/a.conf
check "defaults: writes a file" 0 "Wrote $f" -- host "$cfg" init --defaults "$f"
check "the file passes check" 0 "OK:" -- "$cfg" check "$f"
same "user from SUDO_USER" "$(val DECOLAB_USER "$f")" alice
same "interface from the default route" "$(val LAN_INTERFACE "$f")" eth0
same "address of that interface" "$(val HOST_LAN_IP "$f")" "$pi"
same "network computed from address and prefix" "$(val LAN_SUBNET "$f")" "$net.0/24"
same "time zone from /etc/localtime" "$(val TZ "$f")" Europe/Berlin
same "SSH port: a drop-in wins over sshd_config" "$(val SSH_PORT "$f")" 2201
same "tailnet from tailscale status" "$(val TAILNET_NAME "$f")" tail5678
check "tailnet from Self.DNSName alone" 0 "" -- host env FAKE_TAILSCALE_JSON='{"BackendState":"Running","Self":{"DNSName":"pi.tail9abc.ts.net.","Online":true},"Peer":{}}' "$cfg" init --defaults "$t_tmp/dns.conf"
same "tailnet from Self.DNSName alone" "$(val TAILNET_NAME "$t_tmp/dns.conf")" tail9abc
same "web interfaces stay on 127.0.0.1 with Tailscale" "$(val WEB_UI_ADDRESS "$f")" 127.0.0.1
same "Vaultwarden on with Tailscale" "$(val MODULE_VAULTWARDEN "$f")" yes
same "backups below the data disk" "$(val BACKUP_DIR "$f")" /mnt/data/backups
same "optional copies stay empty" "$(val USB_BACKUP_DIR "$f")|$(val RESTIC_REPOSITORY "$f")" "|"
check "DHCP address: says to reserve it" 0 "reserve it for this Pi" -- host "$cfg" init --defaults "$t_tmp/a2.conf"
check "comments of the example stay" 0 "" -- grep -q "^# Pool for Docker networks" "$f"
same "file mode 644" "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" 644
same "no temporary file left behind" "$(find "$t_tmp" -maxdepth 1 -name '.decolab-conf*' | wc -l | tr -d ' ')" 0

printf 'KEEP=me\n' > "$t_tmp/old.conf"
check "never overwrites a file" 1 "already exists" -- host "$cfg" init --defaults "$t_tmp/old.conf"
same "the old file is unchanged" "$(cat "$t_tmp/old.conf")" "KEEP=me"
ln -s "$t_tmp/nowhere" "$t_tmp/link.conf"
check "never writes through a dangling link" 1 "already exists" -- host "$cfg" init --defaults "$t_tmp/link.conf"

f=$t_tmp/pool.conf
check "LAN inside the default Docker pool" 0 "" -- host env FAKE_IP_ROUTE="default via $lan.1 dev end0" \
  FAKE_IP_ADDR="3: end0    inet $lan.9/22 brd ${lan%.4}.7.255 scope global end0" "$cfg" init --defaults "$f"
same "Docker pool moves out of the LAN" "$(val DOCKER_ADDRESS_POOL "$f")" "${lan%0.4}1.0.0/16"
same "network of a /22" "$(val LAN_SUBNET "$f")" "$lan.0/22"
check "static address: no DHCP note" 0 "" -- host env FAKE_IP_ROUTE="default via $lan.1 dev end0" \
  FAKE_IP_ADDR="3: end0    inet $lan.9/22 brd ${lan%.4}.7.255 scope global end0" "$cfg" init --defaults "$t_tmp/pool2.conf"
refute "static address: no DHCP note" "reserve it"

f=$t_tmp/nots.conf
check "no Tailscale found" 0 "Wrote" -- host env FAKE_TAILSCALE_JSON= "$cfg" init --defaults "$f"
same "Tailscale off" "$(val TAILSCALE "$f")|$(val TAILNET_NAME "$f")" "no|"
same "Vaultwarden off without Tailscale" "$(val MODULE_VAULTWARDEN "$f")" no
same "web interfaces on the LAN address" "$(val WEB_UI_ADDRESS "$f")" "$pi"
same "then hardening is suggested" "$(val HARDENING "$f")" yes
same "no key in authorized_keys: passwords stay" "$(val SSH_PASSWORDS "$f")" yes
printf 'ssh-ed25519 AAAA test\n' > "$t_tmp/home/.ssh/authorized_keys"
check "with a key" 0 "" -- host env FAKE_TAILSCALE_JSON= "$cfg" init --defaults "$t_tmp/key.conf"
same "with a key: keys only is suggested" "$(val SSH_PASSWORDS "$t_tmp/key.conf")" no
rm "$t_tmp/home/.ssh/authorized_keys"

check "no default route: nothing written" 1 "LAN_INTERFACE" -- host env FAKE_IP_ROUTE= "$cfg" init --defaults "$t_tmp/none.conf"
same "no default route: no file" "$(test -e "$t_tmp/none.conf" && echo yes || echo no)" no
check "root without SUDO_USER: no suggestion" 1 "DECOLAB_USER" -- host env SUDO_USER=root "$cfg" init --defaults "$t_tmp/root.conf"

# Interactive: answers come line by line, an empty line takes the suggestion,
# the end of the input takes the suggestion of every remaining question.
f=$t_tmp/ask.conf
check "a wrong answer is asked again" 0 "must not be root" -- host bash -c 'printf "root\nbob\n" | "$1" init "$2"' _ "$cfg" "$f"
same "the second answer counts" "$(val DECOLAB_USER "$f")" bob
check "the question shows the suggestion" 0 "Time zone [Europe/Berlin]:" -- host bash -c 'printf "" | "$1" init "$2"' _ "$cfg" "$t_tmp/ask2.conf"
# order with Tailscale: user dir data tz iface ip subnet ssh tailscale tailnet webui
f=$t_tmp/ask3.conf
check "a host address as network" 0 "did you mean $net.0/24" -- host bash -c 'printf "\n\n\n\n\n\n%s\n\n" "$3.5/24" | "$1" init "$2"' _ "$cfg" "$f" "$net"
same "the suggestion after the wrong answer" "$(val LAN_SUBNET "$f")" "$net.0/24"
# without Tailscale: ... ssh tailscale webui immich vaultwarden
check "Vaultwarden without Tailscale is refused" 0 "needs TAILSCALE=yes" -- host env FAKE_TAILSCALE_JSON= bash -c 'printf "\n\n\n\n\n\n\n\n\n\n\nyes\nno\n" | "$1" init "$2"' _ "$cfg" "$t_tmp/ask4.conf"
same "Vaultwarden ends up off" "$(val MODULE_VAULTWARDEN "$t_tmp/ask4.conf")" no
# ... hardening(16) backup_dir(17): a backup folder inside the repository
check "answers that clash: nothing written" 1 "must not be inside DECOLAB_DIR" -- host bash -c 'printf "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n%s\n" "$3/bk" | "$1" init "$2"' _ "$cfg" "$t_tmp/clash.conf" "$t_root"
same "clash: no file" "$(test -e "$t_tmp/clash.conf" && echo yes || echo no)" no
check "an optional copy can be left empty with -" 0 "Wrote" -- host bash -c 'printf "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n/media/usb\n-\n" | "$1" init "$2"' _ "$cfg" "$t_tmp/usb.conf"
refute "- is not taken as a path" "is not a restic repository"
same "USB copy set, restic empty" "$(val USB_BACKUP_DIR "$t_tmp/usb.conf")|$(val RESTIC_REPOSITORY "$t_tmp/usb.conf")" "/media/usb|"

check "input ends on a question without suggestion: stops" 1 "input ended" -- host env FAKE_IP_ROUTE= bash -c 'printf "" | "$1" init "$2"' _ "$cfg" "$t_tmp/eof.conf"
check "input ends on an unusable suggestion: stops" 1 "no usable suggestion" -- host env SUDO_USER=Alice bash -c 'printf "" | "$1" init "$2"' _ "$cfg" "$t_tmp/eof2.conf"
check "usage error" 2 "" -- "$cfg" init a b
t_finish
