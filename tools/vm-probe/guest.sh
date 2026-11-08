#!/usr/bin/env bash
# guest.sh PHASE - the VM side of tools/vm-probe/vm-probe.sh. Runs as pi.
#
# Every phase follows INSTALL.md or RESTORE.md as a stranger would, and
# proves its result instead of trusting an exit code. Test data (accounts,
# tokens) is generated here and kept in ~/probe/creds, inside the VM only.
# Never meant for a real host: it formats the USB disk and fakes Tailscale.
# ok and fail always succeed, so "A && ok || fail" is if-then-else here;
# the package lists are split into words on purpose.
# shellcheck disable=SC2015,SC2086,SC2016  # child-shell code in single quotes
set -uo pipefail
phase=${1:?usage: guest.sh PHASE}
D=/opt/decolab
conf=$D/decolab.conf
creds=$HOME/probe/creds
export DEBIAN_FRONTEND=noninteractive
# sudo drops the environment: apt-get gets it through this
sudo() { if [ "$1" = apt-get ]; then command sudo DEBIAN_FRONTEND=noninteractive "$@"; else command sudo "$@"; fi; }
fails=""

say() { printf -- '-- %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails="$fails
  $*"; }
ok() { printf 'ok   %s\n' "$*"; }
end() {
  if [ -n "$fails" ]; then printf '\n%s FAILED:%s\n' "$phase" "$fails"; exit 1; fi
  printf '\n%s ok\n' "$phase"
  exit 0
}
# expect NAME CMD... - run CMD, record ok or the failure with its exit code
expect() {
  local name=$1 rc
  shift
  "$@"
  rc=$?
  if [ "$rc" = 0 ]; then ok "$name"; else fail "$name (exit $rc)"; fi
  return "$rc"
}
cfg() { sed -n "s/^$1=//p" "$conf"; }
gen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }
wait_for() { # SECONDS DESCRIPTION CMD... - until CMD succeeds
  local n=$1 what=$2
  shift 2
  for _ in $(seq 1 "$n"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  fail "$what: not within $n s"
  return 1
}
secrets() { cfg SECRETS_DIR; }

case $phase in

# --- the generic kernel: the cloud kernel has no USB drivers ---------------
kernel)
  cloud-init status --wait >/dev/null 2>&1
  sudo apt-get update -q >/dev/null
  expect "generic kernel installed" sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q install linux-image-arm64 >/dev/null
  # Boot it next: the cloud kernel cannot be removed while it runs.
  ver=$(find /boot -name 'vmlinuz-*' ! -name '*cloud*' | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
  if [ -z "$ver" ]; then
    fail "no generic kernel in /boot"
  else
    sudo sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux $ver\"|" /etc/default/grub
    sudo update-grub >/dev/null 2>&1 && ok "the next boot uses $ver" || fail "update-grub"
  fi
  end ;;

# --- INSTALL.md 2: system, packages, Docker, data disk; plus the probe's stubs
prepare)
  uname -r | grep cloud >/dev/null && fail "still the cloud kernel: $(uname -r)" || ok "kernel $(uname -r)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q purge 'linux-image-*cloud*' >/dev/null 2>&1
  say "system update"
  sudo apt-get update -q && sudo apt-get -y -q full-upgrade >/dev/null || fail "apt full-upgrade"
  # INSTALL.md step 2, the list as written there
  base="git python3 curl util-linux coreutils sudo logrotate arp-scan unattended-upgrades"
  # the conditional ones this configuration needs (USB, off-site, Vaultwarden, HARDENING, NVMe)
  extra="rsync restic argon2 nftables nvme-cli"
  # for the probe itself: test data, DNS checks, the repository's lint step
  probe="sqlite3 jq python3-pil bind9-dnsutils"
  expect "apt install (INSTALL.md list)" sudo apt-get -y -q install $base $extra $probe >/dev/null
  # Are the packages INSTALL.md names but this configuration skips in Debian?
  for p in librespeed-cli python3-luma.oled nut-client nut-server; do
    if apt-cache policy "$p" 2>/dev/null | sed -n 's/^ *Candidate: //p' | grep -v none >/dev/null; then
      ok "Debian has $p"
    else
      say "NOTE: Debian 13 has no package $p"
    fi
  done
  say "Docker from Docker's repository (docs.docker.com/engine/install/debian)"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -q >/dev/null
  expect "Docker installed" sudo apt-get -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  sudo usermod -aG docker pi
  say "Docker's address pool (INSTALL.md, step 2)"
  printf '{"default-address-pools": [{"base": "10.210.0.0/16", "size": 24}], "features": {"containerd-snapshotter": false}}\n' | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
  sudo docker info --format '{{json .DefaultAddressPools}}' | grep '"10.210.0.0/16"' >/dev/null && ok "Docker numbers from 10.210.0.0/16" || fail "Docker address pool"
  sudo docker info --format '{{.Driver}}' | grep -x overlay2 >/dev/null && ok "Docker's classic store (overlay2)" || fail "Docker storage: $(sudo docker info --format '{{.Driver}}')"
  # For tools/check.sh: the shellcheck CI pins (Debian's 0.10 reports
  # what 0.11 fixed)
  if ! command -v shellcheck >/dev/null; then
    t=$(mktemp -d)
    curl -fsSL -o "$t/sc.txz" https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.aarch64.tar.xz &&
      echo "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588  $t/sc.txz" | sha256sum -c - >/dev/null &&
      tar -xJf "$t/sc.txz" -C "$t" && sudo install -m 755 "$t/shellcheck-v0.11.0/shellcheck" /usr/local/bin/shellcheck || fail "shellcheck"
    rm -rf "$t"
  fi
  # gitleaks for tools/check.sh (pinned, as in CI)
  if ! command -v gitleaks >/dev/null; then
    t=$(mktemp -d)
    curl -fsSL -o "$t/gl.tgz" https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_arm64.tar.gz &&
      echo "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080  $t/gl.tgz" | sha256sum -c - >/dev/null &&
      tar -xzf "$t/gl.tgz" -C "$t" gitleaks && sudo install -m 755 "$t/gitleaks" /usr/local/bin/gitleaks || fail "gitleaks"
    rm -rf "$t"
  fi
  say "port 53: systemd-resolved's stub off (INSTALL.md, step 2)"
  if [ "$(systemctl is-active systemd-resolved)" = active ]; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/decolab.conf >/dev/null
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    sudo systemctl restart systemd-resolved
  fi
  [ -z "$(ss -Hlntu 'sport = :53')" ] && ok "port 53 is free" || fail "port 53 is still in use"
  getent hosts deb.debian.org >/dev/null && ok "the host still resolves names" || fail "no name resolution"
  say "Tailscale: the probe's stub (reports connected, joins nothing)"
  sudo install -m 755 ~/probe/tailscale-stub /usr/local/bin/tailscale
  say "data disk: the system disk is NVMe here"
  sudo mkdir -p /mnt/data && sudo chown pi: /mnt/data
  findmnt -no SOURCE / | grep nvme >/dev/null && ok "/ is on NVMe" || fail "/ is not on NVMe"
  say "USB disk"
  usb=$(lsblk -dnpo NAME,TRAN | awk '$2 == "usb" { print $1; exit }')
  if [ -z "$usb" ]; then
    fail "no USB disk"
  else
    # Only a disk without any file system is formatted, never in the restore
    # VM (it holds the backup). blkid needs root: without it, it sees nothing
    # (that wiped the backup once).
    if [ -z "$(sudo blkid -o value -s TYPE "$usb")" ]; then
      [ "$(hostname)" != decolab-probe-restore ] || { fail "the USB disk has no file system: no backup to restore"; end; }
      sudo mkfs.ext4 -q -L decolab-usb "$usb" && ok "USB disk formatted (it was empty)"
    else
      ok "USB disk has a file system ($(sudo blkid -o value -s LABEL "$usb")): kept"
    fi
    sudo mkdir -p /mnt/usb
    grep -q decolab-usb /etc/fstab || echo "LABEL=decolab-usb /mnt/usb ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
    sudo mount -a && findmnt /mnt/usb >/dev/null && ok "USB disk mounted" || fail "USB disk mount"
    sudo chown pi: /mnt/usb
  fi
  say "INSTALL.md 3: the checkout"
  sudo mkdir -p "$D" && sudo chown pi: "$D"
  if [ ! -d "$D/.git" ]; then
    git clone -q ~/probe/repo.bundle "$D" && git -C "$D" checkout -q "$(cat ~/probe/commit)" || fail "git clone"
  fi
  [ "$(git -C "$D" rev-parse --short HEAD)" = "$(cat ~/probe/commit)" ] && ok "checkout at $(cat ~/probe/commit)" || fail "checkout"
  end ;;

# --- INSTALL.md 4: the configuration through the wizard, as INSTALL.md says --
configure)
  ip4=$(ip -4 -o addr show scope global | awk '{ print $4; exit }')
  ifc=$(ip -4 -o addr show scope global | awk '{ print $2; exit }')
  rm -f "$conf"
  expect "decolab-config init --defaults" "$D/bin/decolab-config" init --defaults "$conf" </dev/null
  # what the wizard must have found on its own
  [ "$(cfg DECOLAB_USER)" = pi ] && ok "wizard: user pi" || fail "wizard: user $(cfg DECOLAB_USER)"
  [ "$(cfg DECOLAB_DIR)" = "$D" ] && ok "wizard: directory $D" || fail "wizard: directory $(cfg DECOLAB_DIR)"
  [ "$(cfg LAN_INTERFACE)" = "$ifc" ] && ok "wizard: interface $ifc" || fail "wizard: interface $(cfg LAN_INTERFACE)"
  [ "$(cfg HOST_LAN_IP)" = "${ip4%/*}" ] && ok "wizard: address ${ip4%/*}" || fail "wizard: address $(cfg HOST_LAN_IP)"
  [ "$(cfg LAN_SUBNET)" = 192.0.2.0/24 ] && ok "wizard: network 192.0.2.0/24" || fail "wizard: network $(cfg LAN_SUBNET)"
  [ "$(cfg TAILNET_NAME)" = tailprobe ] && ok "wizard: tailnet tailprobe" || fail "wizard: tailnet $(cfg TAILNET_NAME)"
  # then what a stranger changes by hand afterwards
  sed -i -e "s|^HARDENING=.*|HARDENING=yes|" -e "s|^SPEEDTEST=.*|SPEEDTEST=no|" -e "s|^SSH_PASSWORDS=.*|SSH_PASSWORDS=no|" \
    -e "s|^USB_BACKUP_DIR=.*|USB_BACKUP_DIR=/mnt/usb/decolab|" \
    -e "s|^RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY=/mnt/usb/restic|" "$conf"
  case ${ip4%/*} in 192.0.2.*) ok "address ${ip4%/*} in the documentation range" ;; *) fail "unexpected address $ip4" ;; esac
  grep -vE '^#|^$' "$conf" | sed 's/^/   /'
  expect "decolab-config check" "$D/bin/decolab-config" check "$conf"
  end ;;

# --- INSTALL.md 5 and 6 -----------------------------------------------------
install)
  cd "$D" || exit 1
  ./install.sh --dry-run --fresh </dev/null
  rc=$?
  [ "$rc" = 0 ] && ok "dry run: nothing blocked" || fail "dry run (exit $rc)"
  ./install.sh --fresh </dev/null
  rc=$?
  [ "$rc" = 0 ] && ok "install.sh --fresh" || fail "install.sh --fresh (exit $rc)"
  # INSTALL.md 6.1: the restic repository, once, as root, with the command there
  if [ -n "$(cfg RESTIC_REPOSITORY)" ]; then
    sudo restic -r "$(sed -n 's/^RESTIC_REPOSITORY=//p' decolab.conf)" \
      --password-file "$(sed -n 's/^SECRETS_DIR=//p' decolab.conf)/restic-password" init >/dev/null &&
      ok "restic repository created" || fail "restic init"
  fi
  # INSTALL.md 6.4: the USB disk, marked
  mkdir -p /mnt/usb/decolab && touch /mnt/usb/decolab/.decolab-usb-backup && ok "USB disk marked"
  say "containers"
  docker ps --format '{{.Names}} {{.Status}}' | sort | sed 's/^/   /'
  bad=$(docker ps -a --format '{{.Names}} {{.Status}}' | grep -vE ' Up .*(healthy|[0-9] (seconds|minutes|hours))' | grep -v '(healthy)' | grep -E 'unhealthy|Exited|Restarting|Created' || true)
  [ -z "$bad" ] && ok "no container down" || fail "containers: $bad"
  end ;;

# --- test data: what a household would have after a day ---------------------
seed)
  mkdir -p "$creds" && chmod 700 "$creds"
  S=$(secrets)
  say "Pi-hole: the block list was built at the first start"
  wait_for 600 "gravity.db" sh -c '[ "$(sqlite3 "file:/mnt/data/pihole/gravity.db?mode=ro" "SELECT count(*) FROM gravity" 2>/dev/null || echo 0)" -gt 1000 ]' &&
    ok "gravity: $(sqlite3 "file:/mnt/data/pihole/gravity.db?mode=ro" 'SELECT count(*) FROM gravity') domains"

  say "Uptime Kuma: no database setup page (the compose file sets SQLite), then the push monitors (INSTALL.md 6.3)"
  wait_for 180 "Kuma answers" curl -fs http://127.0.0.1:3001/setup-database-info
  curl -fs http://127.0.0.1:3001/setup-database-info | grep '"needSetup":false' >/dev/null &&
    ok "Kuma needs no database setup" || fail "Kuma asks for a database setup"
  wait_for 240 "kuma.db" test -s /mnt/data/uptime-kuma/kuma.db
  wait_for 240 "Kuma back up" curl -fs http://127.0.0.1:3001/api/entry-page
  cd "$D" || exit 1
  names=$(./install.sh --list-monitors)
  say "push monitors this configuration needs: $(printf "%s " $names)"
  bin/decolab-compose uptime-kuma stop >/dev/null 2>&1
  env_file=$S/kuma-push.env
  {
    echo "KUMA_BASE=http://127.0.0.1:3001/api/push"
    for n in $names; do echo "KUMA_$n=$(gen 24)"; done
  } >"$env_file.new" && chmod 600 "$env_file.new" && mv "$env_file.new" "$env_file"
  sqlite3 /mnt/data/uptime-kuma/kuma.db '.schema monitor' >"$creds/kuma-monitor-schema.sql"
  while IFS='=' read -r k v; do
    case $k in KUMA_BASE) continue ;; esac
    sqlite3 /mnt/data/uptime-kuma/kuma.db \
      "INSERT INTO monitor (name, type, push_token, active, interval, retry_interval, maxretries) VALUES ('${k#KUMA_}', 'push', '$v', 1, 86400, 3600, 0)" ||
      fail "Kuma: cannot insert monitor ${k#KUMA_} (schema in $creds/kuma-monitor-schema.sql)"
  done <"$env_file"
  bin/decolab-compose uptime-kuma start >/dev/null 2>&1
  wait_for 240 "Kuma back up" curl -fs http://127.0.0.1:3001/api/entry-page
  n=$(sqlite3 "file:/mnt/data/uptime-kuma/kuma.db?mode=ro" "SELECT count(*) FROM monitor WHERE type='push'")
  [ "${n:-0}" -ge 1 ] && ok "Kuma: $n push monitors" || fail "Kuma: no push monitor"
  ./install.sh </dev/null | grep "Uptime Kuma: create a push monitor" >/dev/null && fail "install.sh still asks for push monitors" || ok "install.sh is content with kuma-push.env"

  say "Vaultwarden: an invited account (admin page, then the registration a client makes)"
  tok=$(cat "$S/vaultwarden-admin-token" 2>/dev/null)
  [ -n "$tok" ] || fail "no vaultwarden-admin-token"
  jar=$creds/vw.cookies
  wait_for 120 "Vaultwarden answers" curl -fs http://127.0.0.1:8500/alive
  curl -fs -c "$jar" -o /dev/null --data-urlencode "token=$tok" http://127.0.0.1:8500/admin || fail "Vaultwarden admin login"
  curl -fs -b "$jar" -o /dev/null -H 'Content-Type: application/json' -d '{"email":"probe@example.org"}' http://127.0.0.1:8500/admin/invite || fail "Vaultwarden invite"
  # Vaultwarden 1.34+: the client first asks for a verification token
  # (without SMTP the answer carries it), then finishes the registration.
  # The client derives keys; the server stores what it gets. Test values only.
  vt=$(curl -fs -H 'Content-Type: application/json' -d '{"email":"probe@example.org","name":"probe","receiveMarketingEmails":false}' \
    http://127.0.0.1:8500/identity/accounts/register/send-verification-email | tr -d '"')
  [ -n "$vt" ] || fail "Vaultwarden: no verification token"
  body=$(VT=$vt python3 -I -c 'import json,base64,os
b=lambda n: base64.b64encode(os.urandom(n)).decode()
print(json.dumps({"email":"probe@example.org","name":"probe","emailVerificationToken":os.environ["VT"],
 "masterPasswordHash":b(32),"masterPasswordHint":None,
 "userSymmetricKey":"2."+b(16)+"|"+b(64)+"|"+b(32),"kdf":0,"kdfIterations":600000,
 "userAsymmetricKeys":{"publicKey":b(294),"encryptedPrivateKey":"2."+b(16)+"|"+b(1232)+"|"+b(32)}}))')
  code=$(curl -s -o "$creds/vw-register.out" -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" http://127.0.0.1:8500/identity/accounts/register/finish)
  [ "$code" = 200 ] && ok "Vaultwarden: account registered" || fail "Vaultwarden register: HTTP $code ($(head -c 200 "$creds/vw-register.out"))"
  # an invitation alone makes a user row too, without a password hash
  n=$(sqlite3 "file:/mnt/data/vaultwarden/db.sqlite3?mode=ro" "SELECT count(*) FROM users WHERE length(password_hash) > 0")
  [ "${n:-0}" -ge 1 ] && ok "Vaultwarden: $n registered user" || fail "Vaultwarden: no registered user"
  # INSTALL.md 6.2: the admin token goes into a password manager, the file away
  mv "$S/vaultwarden-admin-token" "$creds/" && ok "admin token moved out of SECRETS_DIR (INSTALL.md 6.2)"

  say "Immich: first admin, then one photo"
  wait_for 300 "Immich answers" curl -fs http://127.0.0.1:2283/api/server/ping
  pw=$(gen 24)
  printf 'admin@example.org %s\n' "$pw" >"$creds/immich"
  curl -fs -o /dev/null -H 'Content-Type: application/json' \
    -d "{\"email\":\"admin@example.org\",\"password\":\"$pw\",\"name\":\"Probe\"}" http://127.0.0.1:2283/api/auth/admin-sign-up || fail "Immich admin sign-up"
  at=$(curl -fs -H 'Content-Type: application/json' -d "{\"email\":\"admin@example.org\",\"password\":\"$pw\"}" \
    http://127.0.0.1:2283/api/auth/login | jq -r .accessToken)
  python3 -I -c 'from PIL import Image, ImageDraw; im=Image.new("RGB",(640,480),(201,162,39)); d=ImageDraw.Draw(im); d.rectangle((80,80,560,400),outline=(20,20,20),width=12); im.save("/tmp/probe.jpg", quality=90)'
  now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  code=$(curl -s -o "$creds/immich-upload.out" -w '%{http_code}' -H "Authorization: Bearer $at" \
    -F assetData=@/tmp/probe.jpg -F deviceAssetId=probe-1 -F deviceId=vm-probe -F "fileCreatedAt=$now" -F "fileModifiedAt=$now" \
    http://127.0.0.1:2283/api/assets)
  case $code in 200 | 201) ok "Immich: photo uploaded" ;; *) fail "Immich upload: HTTP $code ($(head -c 200 "$creds/immich-upload.out"))" ;; esac
  printf '%s\n' "$at" >"$creds/immich-token"

  say "Portainer: admin with the setup token from its log, then the environment (INSTALL.md 6.2)"
  # Without an admin it stops after five minutes; the install was longer ago.
  docker restart portainer >/dev/null
  wait_for 120 "Portainer's setup token" sh -c 'docker logs portainer 2>&1 | grep -q "^setup_token="'
  wait_for 60 "Portainer answers" curl -fs -o /dev/null http://127.0.0.1:9000/api/system/status
  st=$(docker logs portainer 2>&1 | sed -n 's/^setup_token=//p' | tail -1)
  pw=$(gen 24)
  printf 'admin %s\n' "$pw" >"$creds/portainer"
  curl -fs -o /dev/null -H "X-Setup-Token: $st" -H 'Content-Type: application/json' \
    -d "{\"Username\":\"admin\",\"Password\":\"$pw\"}" http://127.0.0.1:9000/api/users/admin/init &&
    ok "Portainer: admin created" || fail "Portainer admin init"
  jwt=$(curl -fs -H 'Content-Type: application/json' -d "{\"Username\":\"admin\",\"Password\":\"$pw\"}" \
    http://127.0.0.1:9000/api/auth | jq -r .jwt)
  curl -fs -o /dev/null -H "Authorization: Bearer $jwt" -F Name=local -F EndpointCreationType=1 \
    -F URL=tcp://socket-proxy:2375 http://127.0.0.1:9000/api/endpoints &&
    ok "Portainer: environment local -> socket-proxy:2375" || fail "Portainer environment"
  end ;;

# --- one night and one morning, by hand: every scheduled job once ----------
jobs)
  cd "$D" || exit 1
  run() { # AS SCRIPT [ARGS] - as pi or root, like the schedule
    local as=$1 s=$2 rc
    shift 2
    # shellcheck disable=SC2024 # the log is the probe's, not root's
    if [ "$as" = root ]; then sudo "scripts/$s" "$@" >"/tmp/job-$s.log" 2>&1; else "scripts/$s" "$@" >"/tmp/job-$s.log" 2>&1; fi
    rc=$?
    if [ "$rc" = 0 ]; then ok "$s"; else fail "$s (exit $rc): $(tail -3 "/tmp/job-$s.log" | tr '\n' ' ')"; fi
  }
  run pi backup.sh
  run pi verify-backup.sh
  run pi image-digests.sh
  run root backup-usb.sh
  run root backup-offsite.sh
  run pi restore-probe-vaultwarden.sh
  run pi restore-probe-immich.sh
  run pi restore-probe-kuma.sh
  run pi restore-probe-pihole.sh
  run root check-restic-integrity.sh
  run root restore-probe-vaultwarden-offsite.sh
  for s in check-services.sh check-cadvisor-coverage.sh check-pihole-blocking.sh check-unbound-dnssec.sh \
    check-portainer-docker.sh check-prometheus-alerts.sh check-immich-data.sh check-samba-login.sh \
    check-perses.sh check-nvme-health.sh check-tailscale-keys.sh prometheus-rules-sync.sh monitor.sh; do
    run pi "$s"
  done
  run root device-watch.sh
  run pi morning-report.sh
  run pi update-report.sh --quiet
  say "Uptime Kuma: what the pushes reported"
  sqlite3 "file:/mnt/data/uptime-kuma/kuma.db?mode=ro" "SELECT m.name, (SELECT status FROM heartbeat h WHERE h.monitor_id = m.id ORDER BY h.id DESC LIMIT 1) FROM monitor m WHERE m.type='push' ORDER BY m.name" |
    while IFS='|' read -r n st; do
      case $st in 1) echo "   up    $n" ;; 0) echo "   DOWN  $n" ;; *) echo "   none  $n" ;; esac
    done
  down=$(sqlite3 "file:/mnt/data/uptime-kuma/kuma.db?mode=ro" "SELECT count(*) FROM monitor m WHERE m.type='push' AND (SELECT status FROM heartbeat h WHERE h.monitor_id = m.id ORDER BY h.id DESC LIMIT 1) = 0")
  [ "${down:-1}" = 0 ] && ok "no push monitor reported down" || fail "$down push monitors reported down"
  find /mnt/usb/decolab/daily -mindepth 1 -maxdepth 1 | sort | sed 's/^/   usb: /'
  end ;;

# --- INSTALL.md 8: the firewall, on trial, confirmed from a new login --------
firewall-apply)
  cd "$D" || exit 1
  expect "decolab-firewall check" bin/decolab-firewall check
  expect "decolab-firewall apply" sudo bin/decolab-firewall apply
  sudo bin/decolab-firewall status
  end ;;
firewall-confirm)
  expect "a new SSH login after the apply" true
  expect "decolab-firewall confirm" sudo "$D/bin/decolab-firewall" confirm
  st=$(sudo "$D/bin/decolab-firewall" status)
  case $st in "confirmed; decolab-firewall.service: active") ok "firewall: $st" ;; *) fail "firewall: $st" ;; esac
  end ;;
after-reboot)
  ok "SSH answers after the reboot"
  st=$(sudo "$D/bin/decolab-firewall" status)
  case $st in "confirmed; decolab-firewall.service: active") ok "firewall after reboot: $st" ;; *) fail "firewall after reboot: $st" ;; esac
  sudo nft list table inet decolab >/dev/null && ok "nft table inet decolab loaded" || fail "nft table missing"
  sshd_root=$(sudo sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2 }')
  [ "$sshd_root" = no ] && ok "sshd: PermitRootLogin no" || fail "sshd: PermitRootLogin $sshd_root"
  sshd_pw=$(sudo sshd -T -C user=pi,host=localhost,addr=192.0.2.2 2>/dev/null | awk '$1 == "passwordauthentication" { print $2 }')
  [ "$sshd_pw" = no ] && ok "sshd: keys only (SSH_PASSWORDS=no)" || fail "sshd: PasswordAuthentication $sshd_pw"
  say "containers after the reboot (waiting up to 5 min)"
  wait_for 300 "all containers up" sh -c '! docker ps -a --format "{{.Status}}" | grep -qE "unhealthy|Exited|Restarting|Created|starting"'
  docker ps -a --format '{{.Names}} {{.Status}}' | sort | sed 's/^/   /'
  dig +short +time=3 @"$(cfg HOST_LAN_IP)" example.org | grep . >/dev/null && ok "Pi-hole answers on the LAN address" || fail "no DNS answer on the LAN address"
  # a container reaches the host for DNS, but not for SSH (node is in Kuma's image)
  ip=$(cfg HOST_LAN_IP)
  docker exec uptime-kuma node -e 'const r=new (require("dns").promises.Resolver)({timeout:3000,tries:1});r.setServers([process.argv[1]]);r.resolve4("example.org").then(()=>process.exit(0),()=>process.exit(1))' "$ip" &&
    ok "a container resolves through the host's DNS" || fail "a container gets no DNS from the host"
  if docker exec uptime-kuma node -e 'const s=require("net").connect(+process.argv[2],process.argv[1]);s.setTimeout(3000);s.on("connect",()=>process.exit(0));s.on("timeout",()=>process.exit(1));s.on("error",()=>process.exit(1))' "$ip" "$(cfg SSH_PORT)"; then
    fail "a container reaches SSH on the host"
  else ok "a container cannot reach SSH on the host"; fi
  for kv in fs.protected_symlinks=1 fs.protected_hardlinks=1 "net/ipv4/conf/$(cfg LAN_INTERFACE)/send_redirects=0"; do
    [ "$(/usr/sbin/sysctl -n "${kv%=*}" 2>/dev/null)" = "${kv##*=}" ] && ok "sysctl $kv" || fail "sysctl ${kv%=*} is $(/usr/sbin/sysctl -n "${kv%=*}" 2>&1)"
  done
  end ;;

# --- a second run must change nothing ----------------------------------------
second-run)
  cd "$D" || exit 1
  state=/var/lib/decolab
  before_ids=$(docker ps -q --no-trunc | sort)
  before_sum=$(sudo cat "$state/installed.tsv" | sha256sum)
  files=$(sudo cut -f1 "$state/installed.tsv" | grep '^/')
  before_files=$(for f in $files; do sudo sha256sum "$f" 2>/dev/null; done)
  ./install.sh </dev/null >/tmp/second-run.log 2>&1
  rc=$?
  tail -15 /tmp/second-run.log | sed 's/^/   /'
  [ "$rc" = 0 ] && ok "install.sh again: exit 0" || fail "install.sh again: exit $rc"
  [ "$(docker ps -q --no-trunc | sort)" = "$before_ids" ] && ok "no container was recreated" || fail "containers changed"
  [ "$(sudo cat "$state/installed.tsv" | sha256sum)" = "$before_sum" ] && ok "installed.tsv unchanged" || fail "installed.tsv changed"
  after_files=$(for f in $files; do sudo sha256sum "$f" 2>/dev/null; done)
  [ "$after_files" = "$before_files" ] && ok "$(echo "$files" | wc -l) installed files unchanged" || fail "installed files changed: $(diff <(echo "$before_files") <(echo "$after_files") | grep '^>' | head -3)"
  end ;;

# --- the contract tests on the rebuilt system ---------------------------------
tests)
  cd "$D" || exit 1
  tools/check.sh all >/tmp/check-all.log 2>&1
  rc=$?
  grep -E "FAIL|passed, [1-9]|test files|all checks|FAILED" /tmp/check-all.log | sed 's/^/   /'
  [ "$rc" = 0 ] && ok "tools/check.sh all" || fail "tools/check.sh all (exit $rc), see /tmp/check-all.log"
  end ;;

# --- RESTORE.md 1 to 6, on a new system with the old USB disk -----------------
restore)
  U=/mnt/usb/decolab
  B=$(find "$U/daily" -mindepth 1 -maxdepth 1 -type d ! -name '*-incomplete' | sort | tail -1)
  [ -n "$B" ] && ok "RESTORE.md 1: newest backup $(basename "$B")" || { fail "no backup on the USB disk"; end; }
  cd "$D" || exit 1
  # RESTORE.md 3, as written
  mkdir -p ~/restore && tar -xzf "$B/config.tar.gz" -C ~/restore
  cp ~/restore/config/decolab.conf decolab.conf
  expect "decolab-config check" bin/decolab-config check decolab.conf
  SECRETS_DIR=$(sed -n 's/^SECRETS_DIR=//p' decolab.conf)
  sudo install -d -m 700 -o "$USER" -g "$(id -gn)" "$SECRETS_DIR"
  cp -p ~/restore/config/secrets/* "$SECRETS_DIR/"
  chmod 600 "$SECRETS_DIR"/*
  rm -rf ~/restore
  # RESTORE.md 4
  ./install.sh --dry-run --restore </dev/null >/tmp/restore-dry.log 2>&1 && ok "install.sh --dry-run --restore" || { fail "dry run: $(grep -i block /tmp/restore-dry.log | head -3)"; tail -20 /tmp/restore-dry.log; }
  ./install.sh --restore </dev/null >/tmp/restore-install.log 2>&1
  rc=$?
  tail -8 /tmp/restore-install.log | sed 's/^/   /'
  [ "$rc" = 0 ] && ok "install.sh --restore" || fail "install.sh --restore (exit $rc)"
  [ -z "$(docker ps -q)" ] && ok "nothing started yet" || fail "containers run before the data is back"
  # RESTORE.md 5
  tar -xzf "$B/pihole.tar.gz" -C /mnt/data && tar -xzf "$B/vaultwarden.tar.gz" -C /mnt/data &&
    tar -xzf "$B/uptime-kuma.tar.gz" -C /mnt/data && tar -xzf "$B/portainer.tar.gz" -C /mnt/data && ok "archives unpacked" || fail "unpacking"
  rsync -a "$U/nas/" /mnt/data/nas/ && ok "share back" || fail "share"
  I=$U/immich
  for p in upload library profile; do
    if [ -d "$I/$p" ]; then rsync -a "$I/$p/" "/mnt/data/immich/library/$p/"; else echo "   not in the copy: $p"; fi
  done
  bin/decolab-compose immich up -d database >/tmp/immich-db-up.log 2>&1 ||
    fail "Immich database does not start: $(tail -3 /tmp/immich-db-up.log | tr '\n' ' ')"
  # shellcheck disable=SC1091
  . "$SECRETS_DIR/immich.env"
  until docker exec immich_postgres pg_isready -q -h 127.0.0.1 -U "$DB_USERNAME"; do sleep 2; done
  gzip -dc "$B/immich-db.sql.gz" | docker exec -i immich_postgres psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -q >/tmp/immich-restore.log 2>&1
  errs=$(grep ERROR /tmp/immich-restore.log | grep -v 'already exists' | head -3)
  [ -z "$errs" ] && ok "Immich dump loaded" || fail "Immich dump: $errs"
  bin/decolab-compose immich stop database >/dev/null 2>&1
  # RESTORE.md 6
  ./install.sh --restore-done </dev/null >/tmp/restore-done.log 2>&1
  rc=$?
  tail -8 /tmp/restore-done.log | sed 's/^/   /'
  [ "$rc" = 0 ] && ok "install.sh --restore-done" || fail "install.sh --restore-done (exit $rc)"
  end ;;

# --- RESTORE.md 7: check it, not just look at it -------------------------------
restore-check)
  cd "$D" || exit 1
  wait_for 600 "all containers up" sh -c '! docker ps -a --format "{{.Status}}" | grep -qE "unhealthy|Exited|Restarting|Created|starting"'
  docker ps -a --format '{{.Names}} {{.Status}}' | sort | sed 's/^/   /'
  ip=$(cfg HOST_LAN_IP)
  blocked=$(sqlite3 "file:/mnt/data/pihole/gravity.db?mode=ro" "SELECT domain FROM gravity LIMIT 1 OFFSET 500")
  ans=$(dig +short +time=3 @"$ip" "$blocked" | head -1)
  case $ans in 0.0.0.0 | "") ok "Pi-hole blocks $blocked" ;; *) fail "Pi-hole does not block $blocked ($ans)" ;; esac
  dig +short +time=3 @"$ip" example.org | grep . >/dev/null && ok "Pi-hole resolves example.org" || fail "no answer for example.org"
  kdf=$(curl -fs -H 'Content-Type: application/json' -d '{"email":"probe@example.org"}' http://127.0.0.1:8500/identity/accounts/prelogin | jq -r '.kdfIterations // .KdfIterations')
  [ "$kdf" = 600000 ] && ok "Vaultwarden knows the account (prelogin)" || fail "Vaultwarden prelogin: ${kdf:-no answer}"
  read -r email pw <~/probe/creds-from-run/immich 2>/dev/null || true
  if [ -n "${pw:-}" ]; then
    at=$(curl -fs -H 'Content-Type: application/json' -d "{\"email\":\"$email\",\"password\":\"$pw\"}" http://127.0.0.1:2283/api/auth/login | jq -r .accessToken)
    n=$(curl -fs -H "Authorization: Bearer $at" http://127.0.0.1:2283/api/server/statistics 2>/dev/null | jq -r .photos)
    id=$(curl -fs -H "Authorization: Bearer $at" -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:2283/api/search/metadata | jq -r '.assets.items[0].id')
    code=$(curl -s -o /tmp/orig.jpg -w '%{http_code}' -H "Authorization: Bearer $at" "http://127.0.0.1:2283/api/assets/$id/original")
    [ "$code" = 200 ] && [ -s /tmp/orig.jpg ] && ok "Immich serves the restored photo ($n photos)" || fail "Immich: original HTTP $code (photos: ${n:-?})"
  else
    fail "no Immich login from the first run"
  fi
  n=$(sqlite3 "file:/mnt/data/uptime-kuma/kuma.db?mode=ro" "SELECT count(*) FROM monitor WHERE type='push'")
  [ "${n:-0}" -ge 1 ] && ok "Kuma: $n push monitors back" || fail "Kuma: monitors missing"
  say "the night on the restored system"
  for s in backup.sh verify-backup.sh restore-probe-vaultwarden.sh restore-probe-immich.sh restore-probe-kuma.sh restore-probe-pihole.sh check-services.sh check-immich-data.sh; do
    if "scripts/$s" >"/tmp/job-$s.log" 2>&1; then ok "$s"; else fail "$s: $(tail -2 "/tmp/job-$s.log" | tr '\n' ' ')"; fi
  done
  end ;;

*) echo "unknown phase $phase" >&2; exit 2 ;;
esac
