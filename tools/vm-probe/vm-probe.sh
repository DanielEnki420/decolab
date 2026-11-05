#!/usr/bin/env bash
# vm-probe.sh - rebuild Decolab from scratch in a throw-away VM on a Mac
#
#   tools/vm-probe/vm-probe.sh run       build the VM, install, prove it (phases below)
#   tools/vm-probe/vm-probe.sh resume PHASE  go on from PHASE after a fix to the probe's own scripts
#   tools/vm-probe/vm-probe.sh restore   a second, fresh VM rebuilt from the first one's USB disk
#   tools/vm-probe/vm-probe.sh ssh [VM [CMD]]  log in, or run CMD (VM: decolab-probe, decolab-probe-restore)
#   tools/vm-probe/vm-probe.sh delete    stop both VMs and remove their disks
#
# Why: "the Pi can be replaced" is a claim until someone rebuilds it on
# hardware that never saw it, by the documentation alone. This does that
# with QEMU (arm64, Apple's hypervisor) and Debian 13's cloud image:
#   - the system disk is NVMe, the backup disk is a USB disk, as on a Pi 5
#     (the cloud kernel has no USB drivers: a first phase swaps in Debian's
#     generic kernel, which a Pi's system has as well)
#   - the network is the documentation range 192.0.2.0/24 (QEMU user
#     networking): no address of your own LAN ends up anywhere
#   - Tailscale is a stub that reports "connected"; nothing joins a tailnet
#   - Telegram is off; Uptime Kuma, Immich and Vaultwarden get test data
# The guest side is tools/vm-probe/guest.sh; every phase writes its log to
# the work directory and ends with "PHASE ok" or the reason it failed. The
# VM's console is in WORK/VM/console.log.
#
# Needs: macOS on Apple silicon, QEMU (brew install qemu), a clean git
# checkout (the VM gets HEAD, nothing uncommitted), about 25 GB free disk
# and a few GB of downloads (the Debian image, packages, container images).
# Work directory: VM_PROBE_DIR (default ~/VMs/decolab-probe). Only test
# data lives there; delete removes the VMs, the directory stays with logs.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${VM_PROBE_DIR:-$HOME/VMs/decolab-probe}
vm1=decolab-probe vm2=decolab-probe-restore
port1=2222 port2=2223
image_url=https://cloud.debian.org/images/cloud/trixie/latest
image=debian-13-genericcloud-arm64.qcow2

die() { printf 'vm-probe: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }
usage() { sed -n '4,8s/^# \{0,1\}//p' "$0" >&2; exit 2; }

[ "$(uname -s)" = Darwin ] || die "this runs on macOS"
command -v qemu-system-aarch64 >/dev/null 2>&1 || die "QEMU is missing: brew install qemu"
qemu_share=$(cd "$(dirname "$(command -v qemu-system-aarch64)")/../share/qemu" && pwd) || die "no QEMU share directory"
mkdir -p "$work/logs" || exit 1

port_of() { if [ "$1" = "$vm2" ]; then echo "$port2"; else echo "$port1"; fi; }
ssh_vm() { # VM ARGS... - ssh as pi, with the probe's own key and known_hosts
  local vm=$1
  shift
  ssh -i "$work/id_ed25519" -p "$(port_of "$vm")" -o UserKnownHostsFile="$work/known_hosts" \
    -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
    -o ServerAliveInterval=30 pi@127.0.0.1 "$@"
}
vm_running() { [ -f "$work/$1/qemu.pid" ] && kill -0 "$(cat "$work/$1/qemu.pid")" 2>/dev/null; }

# --- the Debian image, checked against Debian's own checksum list -----------
get_image() {
  local sums=$work/SHA512SUMS want
  curl -fsSL -o "$sums" "$image_url/SHA512SUMS" || die "cannot fetch SHA512SUMS"
  want=$(awk -v f="$image" '$2 == f { print $1 }' "$sums")
  [ -n "$want" ] || die "$image is not in SHA512SUMS"
  if [ ! -f "$work/$image" ] || [ "$(shasum -a 512 "$work/$image" | cut -d' ' -f1)" != "$want" ]; then
    say "downloading $image"
    curl -fsSL -o "$work/$image.part" "$image_url/$image" || die "download failed"
    [ "$(shasum -a 512 "$work/$image.part" | cut -d' ' -f1)" = "$want" ] || die "checksum of $image does not match"
    mv "$work/$image.part" "$work/$image"
  fi
}

# --- cloud-init seed: user pi with the probe's key, nothing else ------------
make_seed() { # VM
  local d=$work/$1/seed
  [ -f "$work/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C decolab-probe -f "$work/id_ed25519" || exit 1
  rm -rf "$d" && mkdir -p "$d"
  cat >"$d/user-data" <<EOF
#cloud-config
hostname: $1
users:
  - name: pi
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$work/id_ed25519.pub")
EOF
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$1" "$(date +%s)" "$1" >"$d/meta-data"
  rm -f "$work/$1/seed.iso"
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$work/$1/seed.iso" "$d" || die "cannot build the seed"
}

# create_vm VM - a fresh NVMe system disk (64 GB) and the seed
create_vm() {
  local vm=$1
  vm_running "$vm" && die "$vm runs already (delete stops it, but also removes the USB disk)"
  get_image
  rm -rf "${work:?}/$vm"
  mkdir -p "$work/$vm" || exit 1
  ssh-keygen -q -R "[127.0.0.1]:$(port_of "$vm")" -f "$work/known_hosts" >/dev/null 2>&1
  make_seed "$vm"
  cp "$work/$image" "$work/$vm/root.qcow2" || exit 1
  qemu-img resize -q "$work/$vm/root.qcow2" 64G || die "cannot resize the system disk"
  cp "$qemu_share/edk2-arm-vars.fd" "$work/$vm/efi-vars.fd" || die "no EFI variables"
  truncate -s 64m "$work/$vm/efi-vars.fd" || exit 1
  [ -f "$work/usb.qcow2" ] || qemu-img create -q -f qcow2 "$work/usb.qcow2" 16G || die "cannot create the USB disk"
}

# start_vm VM - in the background; the console goes to WORK/VM/console.log
start_vm() {
  local vm=$1 d=$work/$1
  say "starting $vm"
  qemu-system-aarch64 -name "$vm" -M virt -accel hvf -cpu host -smp 4 -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file="$qemu_share/edk2-aarch64-code.fd" \
    -drive if=pflash,format=raw,file="$d/efi-vars.fd" \
    -device nvme,serial=decolab-root,drive=root -drive if=none,id=root,file="$d/root.qcow2" \
    -device qemu-xhci -device usb-storage,drive=usb,serial=decolab-usb -drive if=none,id=usb,file="$work/usb.qcow2" \
    -drive if=virtio,media=cdrom,readonly=on,file="$d/seed.iso" \
    -netdev user,id=n,net=192.0.2.0/24,hostfwd=tcp:127.0.0.1:"$(port_of "$vm")"-:22 -device virtio-net-pci,netdev=n \
    -display none -serial file:"$d/console.log" -daemonize -pidfile "$d/qemu.pid" || die "QEMU does not start $vm"
  wait_ssh "$vm" 300
}

stop_vm() { # VM
  vm_running "$1" || return 0
  ssh_vm "$1" 'sudo systemctl poweroff' >/dev/null 2>&1
  for _ in $(seq 1 60); do vm_running "$1" || return 0; sleep 1; done
  kill "$(cat "$work/$1/qemu.pid")" 2>/dev/null
  sleep 2
}

wait_ssh() { # VM SECONDS
  for _ in $(seq 1 "$2"); do
    ssh_vm "$1" true 2>/dev/null && return 0
    vm_running "$1" || die "$1 stopped (console: $work/$1/console.log)"
    sleep 1
  done
  die "$1 answers no SSH after $2 s (console: $work/$1/console.log)"
}

reboot_vm() { # VM - QEMU restarts the guest by itself
  ssh_vm "$1" 'sudo systemctl reboot' >/dev/null 2>&1
  sleep 10
  wait_ssh "$1" 300
}

# phase VM NAME - runs guest.sh NAME in the VM, log in logs/VM-NAME.log
phase() {
  local vm=$1 name=$2 log=$work/logs/$1-$2.log rc
  say "$vm: $name"
  ssh_vm "$vm" "bash ~/probe/guest.sh $name" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  [ "$rc" = 0 ] || die "$vm: phase $name failed (exit $rc), log: $log"
}

# push VM - the committed history as a git bundle (INSTALL.md 3 clones it),
# and the guest scripts of HEAD, into ~/probe
push() {
  [ -z "$(git -C "$root" status --porcelain)" ] || die "the checkout has uncommitted changes: the VM gets HEAD only"
  git -C "$root" bundle create -q "$work/repo.bundle" HEAD main || die "cannot bundle the repository"
  ssh_vm "$1" 'mkdir -p ~/probe' || exit 1
  ssh_vm "$1" 'cat > ~/probe/repo.bundle' <"$work/repo.bundle" || exit 1
  push_guest "$1"
  git -C "$root" rev-parse --short HEAD | ssh_vm "$1" 'cat > ~/probe/commit'
}
push_guest() { # VM - only the probe's own scripts of HEAD
  git -C "$root" show HEAD:tools/vm-probe/guest.sh | ssh_vm "$1" 'cat > ~/probe/guest.sh' || exit 1
  git -C "$root" show HEAD:tools/vm-probe/tailscale-stub | ssh_vm "$1" 'cat > ~/probe/tailscale-stub' || exit 1
}

# run_from PHASE - the first run's phases, from PHASE on
# The jobs run after the firewall, as the nights do after INSTALL.md step 8.
run_phases="prepare configure install seed firewall-apply firewall-confirm jobs reboot after-reboot second-run tests"
run_from() {
  local p go=0
  for p in $run_phases; do
    [ "$p" = "$1" ] && go=1
    [ "$go" = 1 ] || continue
    # The confirm must come from a NEW login that started after the apply:
    # every phase is its own SSH login.
    if [ "$p" = reboot ]; then reboot_vm "$vm1"; else phase "$vm1" "$p"; fi
  done
  [ "$go" = 1 ] || die "no phase $1 (phases: $run_phases)"
  say "all phases ok; logs in $work/logs"
}

# boot VM - new VM, the generic kernel (USB), back up with the repository
boot() {
  create_vm "$1"
  start_vm "$1"
  push "$1"
  phase "$1" kernel
  reboot_vm "$1"
}

case ${1:-} in
  run)
    for vm in "$vm1" "$vm2"; do stop_vm "$vm"; done
    rm -f "$work/usb.qcow2" "$work/known_hosts" # a first run starts with an empty USB disk
    boot "$vm1"
    run_from prepare
    ;;
  resume)
    # after a fix to the probe itself: the installed state stays, the
    # probe's scripts are replaced. A fix to Decolab needs a new run.
    [ -n "${2:-}" ] || usage
    vm_running "$vm1" || die "$vm1 is not running: tools/vm-probe/vm-probe.sh run"
    [ -z "$(git -C "$root" status --porcelain)" ] || die "the checkout has uncommitted changes: the VM gets HEAD only"
    push_guest "$vm1"
    run_from "$2"
    ;;
  restore)
    [ -f "$work/usb.qcow2" ] || die "no USB disk of a first run"
    # the test logins of the first run, to check the restored services with;
    # then the first VM goes away, as a broken Pi would
    if vm_running "$vm1"; then
      ssh_vm "$vm1" 'tar -C ~/probe -cf - creds' >"$work/creds-from-run.tar" || die "cannot fetch the test logins"
      stop_vm "$vm1"
    fi
    [ -s "$work/creds-from-run.tar" ] || die "no test logins of the first run"
    # a second VM of an earlier restore goes: each restore starts fresh
    stop_vm "$vm2"
    boot "$vm2"
    ssh_vm "$vm2" 'mkdir -p ~/probe/creds-from-run && tar -xf - -C ~/probe/creds-from-run --strip-components=1' <"$work/creds-from-run.tar" || exit 1
    phase "$vm2" prepare
    phase "$vm2" restore
    phase "$vm2" restore-check
    say "restore ok; logs in $work/logs"
    ;;
  ssh)
    shift
    vm=${1:-$vm1}
    [ $# -gt 0 ] && shift
    ssh_vm "$vm" "$@" ;;
  delete)
    for vm in "$vm1" "$vm2"; do
      stop_vm "$vm"
      rm -rf "${work:?}/$vm"
    done
    rm -f "$work/usb.qcow2" "$work/repo.bundle" "$work/creds-from-run.tar" "$work/known_hosts"
    echo "deleted; logs stay in $work/logs"
    ;;
  *) usage ;;
esac
