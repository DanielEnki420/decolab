# Installing Decolab

This takes about an hour, most of it waiting for images. Nothing here needs
a graphical desktop: an SSH login is enough.

> **Status:** not released yet. Test it on a spare Pi first.
> Decolab is provided as is, without support (see [SECURITY.md](SECURITY.md)
> for security reports).

## 1. What you need

| | |
|---|---|
| Hardware | Raspberry Pi 5 (4 GB or more; 8 GB with Immich), an NVMe disk for the data (recommended; `HW_NVME=no` without one), a fixed address in your LAN (reserve it in your router) |
| System | Raspberry Pi OS Lite (64-bit) or Debian 13 for arm64 |
| Architecture | **arm64 only.** Some images are pinned to their arm64 build. |
| Optional | a USB disk for a second copy, an SFTP server or other restic target for the off-site copy, a Tailscale account, a Telegram bot, a NUT-capable UPS |

## 2. Prepare the system

As the user that will own Decolab (not root):

```bash
sudo apt update && sudo apt full-upgrade
sudo apt install git python3 curl util-linux coreutils sudo logrotate arp-scan unattended-upgrades
```

Depending on `decolab.conf`, also: `rsync` (USB copy), `restic` (off-site),
`argon2` (Vaultwarden), `nftables` (`HARDENING=yes`), `nut-client nut-server`
(UPS), `nvme-cli` (NVMe), `python3-luma.oled python3-pil` (OLED),
`librespeed-cli` (`SPEEDTEST=yes`). If a package is not in your release's
repository, install it from its project, or switch the module off. You do not
have to get this list right: the dry run in step 5 names every missing one
with the command for it.

**Docker** 28 or newer (with the Compose plugin, 2.20 or newer) from Docker's own
repository: <https://docs.docker.com/engine/install/debian/>. Then:

```bash
sudo usermod -aG docker "$USER"
```

Log out and in again, so the new group applies.

Two Docker settings, before anything runs in Docker:

- Docker numbers the networks it creates from its own range (172.17 to
  172.31), where Decolab's fixed networks are. Give it the range of
  `DOCKER_ADDRESS_POOL` (step 4; `10.210.0.0/16` unless your LAN uses it).
- A fresh Docker 29 keeps images in containerd's store. cAdvisor then sees
  no container: it would need containerd's socket, which is as good as root.
  Keep Docker's classic store. (Switching later hides every image already
  pulled, so do it now.)

```bash
printf '{"default-address-pools": [{"base": "10.210.0.0/16", "size": 24}], "features": {"containerd-snapshotter": false}}\n' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

If `/etc/docker/daemon.json` exists already, add both settings to it instead.

**Tailscale** (if you want `TAILSCALE=yes`, needed for Vaultwarden):
<https://tailscale.com/download/linux>, then `sudo tailscale up`. In the
admin console, switch on MagicDNS and HTTPS certificates: `tailscale serve`
needs both. `TAILNET_NAME` in step 4 is the part before `.ts.net` of this
host's name (`tailscale status --json` shows it as `DNSName`).

**Data disk:** format the NVMe disk and mount it, for example at
`/mnt/data`, with an entry in `/etc/fstab` (by UUID). Then give it to your
user: `sudo chown "$USER": /mnt/data`. install.sh checks that `DATA_DIR` is
really on the NVMe disk; without one, set `HW_NVME=no`.

**Port 53** must be free for Pi-hole. Raspberry Pi OS leaves it free. On
Debian with systemd-resolved (the cloud images have it), switch off its stub
resolver and let the host use the resolvers it was given:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' | sudo tee /etc/systemd/resolved.conf.d/decolab.conf
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
```

The dry run stops if another program holds port 53, 139 or 445.

install.sh does none of this on purpose: installing Docker means running a
vendor's script, and that is your decision. It names what is missing and the
command for it.

## 3. Get Decolab

```bash
sudo mkdir -p /opt/decolab && sudo chown "$USER": /opt/decolab
git clone https://github.com/OWNER/decolab.git /opt/decolab   # OWNER: see the repository page
cd /opt/decolab
git tag                 # the releases
git checkout v0.1.0     # or the newest of them
```

`/opt/decolab` must belong to you and must not be writable by anyone else:
root runs scripts from here (backups, the watchdog). install.sh refuses
otherwise.

## 4. Configure

```bash
bin/decolab-config init
```

It finds what it can on the Pi (your user, the time zone, the LAN interface
and address, the SSH port, your tailnet) and asks for the rest, each time
with a suggestion in `[brackets]` that Enter accepts. Every answer is checked
at once; the file is written only when all of them fit together, and an
existing `decolab.conf` is never overwritten. Read the file once afterwards:
it explains every key.

To write it by hand instead:

```bash
cp decolab.conf.example decolab.conf
nano decolab.conf
bin/decolab-config check decolab.conf
```

The keys you must look at:

| Key | |
|---|---|
| `DECOLAB_USER`, `DECOLAB_DIR` | your user, and `/opt/decolab` |
| `LAN_SUBNET`, `HOST_LAN_IP`, `LAN_INTERFACE` | your network (the example uses `192.0.2.0/24`, a documentation range) |
| `WEB_UI_ADDRESS` | `127.0.0.1` (web interfaces only through Tailscale or an SSH tunnel, recommended) or `HOST_LAN_IP` (the whole LAN; then also `HARDENING=yes`) |
| `TAILSCALE`, `TAILNET_NAME` | the part before `.ts.net` of your tailnet |
| `MODULE_*` | Immich, Vaultwarden, Uptime Kuma: yes or no |
| `BACKUP_DIR`, `USB_BACKUP_DIR`, `RESTIC_REPOSITORY` | where the copies go |
| `NOTIFY` | `telegram` or `none` |

The file holds no secrets. The check is strict on purpose: one `KEY=VALUE`
per line, no quotes, no `$`. Shell, systemd and Docker Compose must all read
it the same way.

## 5. Dry run

```bash
./install.sh --dry-run --fresh
```

This checks everything and shows the plan. It changes nothing, asks for no
sudo and generates no secret. Fix what it lists under "blocked", then run it
again until nothing is blocked.

## 6. Install

```bash
./install.sh --fresh
```

It asks for sudo once (for the files under `/etc`). With `NOTIFY=telegram`
it asks for the bot token and chat id and sends a test message. Then it
generates the secrets into `SECRETS_DIR` and puts the host files in place.
It starts the stacks, and last the schedules and the watchdog. Running it
again changes nothing that is in order.

At the end it prints **"For you to do"**. Do those steps now, in particular:

1. **The restic password** (if `RESTIC_REPOSITORY` is set). Copy
   `SECRETS_DIR/restic-password` onto your emergency sheet, on paper or in a
   password manager on another device. Without it the off-site copy cannot be
   read, and the only other copy is on this Pi. Then create the repository,
   once (not on a restore: there it exists). As root, because the nightly
   job runs as root; for an SFTP target root's SSH key must get in:

   ```bash
   cd /opt/decolab
   sudo restic -r "$(sed -n 's/^RESTIC_REPOSITORY=//p' decolab.conf)" \
     --password-file "$(sed -n 's/^SECRETS_DIR=//p' decolab.conf)/restic-password" init
   ```
2. **Vaultwarden's admin token**: into your password manager, then delete the
   file, as the message says. The other logins are in `SECRETS_DIR` too:
   Pi-hole's web password in `compose-secrets.env` (`PIHOLE_PASSWORD`), the
   Samba password in `samba_password`. Immich, Uptime Kuma and Portainer ask
   you to create their admin account on first visit: do that right away.
   Until then **whoever opens the page first becomes the admin**. So create
   them over an SSH tunnel, before step 7 publishes them in your tailnet or
   `WEB_UI_ADDRESS=HOST_LAN_IP` opens them to the LAN:
   `ssh -L 2283:127.0.0.1:2283 -L 3001:127.0.0.1:3001 -L 9000:127.0.0.1:9000 pi@HOST`,
   then `http://localhost:2283`, `:3001`, `:9000` on your computer.
   **Portainer** first asks for a setup token, which only its log shows:
   `docker logs portainer 2>&1 | grep setup_token=`. Without an admin
   account it stops after five minutes; then `docker restart portainer`
   gives a new token. Then add the environment by hand, not with "Get
   started" (that one uses a socket Portainer does not have): *Environments,
   Add environment, Docker Standalone, API*, name `local`, URL
   `socket-proxy:2375`, without TLS.
3. **Uptime Kuma push monitors** (Kuma's web interface: open it as in
   step 7, and create its admin account first): `./install.sh --list-monitors` lists the
   monitors this configuration reports to. Create a push monitor in Kuma for
   each one, and put the tokens into `SECRETS_DIR/kuma-push.env`:

   ```
   KUMA_BASE=http://127.0.0.1:3001/api/push
   KUMA_BACKUP=token-of-the-backup-monitor
   ...
   ```

   Then set it to mode 600 and run `./install.sh` again. It reports each name
   that is still missing.
4. **The USB disk** (if `USB_BACKUP_DIR` is set): mount it, then mark it, and
   only that disk: `touch USB_BACKUP_DIR/.decolab-usb-backup`. An unmarked
   directory is never written to.

## 7. Reach the web interfaces

With `WEB_UI_ADDRESS=127.0.0.1` the interfaces listen on the Pi only. Once
Immich, Uptime Kuma and Portainer have their admin account (step 6), publish
the ones you want into your tailnet, over HTTPS:

```bash
sudo tailscale serve --bg --https=8090 http://127.0.0.1:8090   # Decolab panel
sudo tailscale serve --bg --https=8500 http://127.0.0.1:8500   # Vaultwarden (needs HTTPS)
sudo tailscale serve --bg --https=2283 http://127.0.0.1:2283   # Immich
sudo tailscale serve --bg --https=3001 http://127.0.0.1:3001   # Uptime Kuma
sudo tailscale serve --bg --https=8053 http://127.0.0.1:8053   # Pi-hole
sudo tailscale serve --bg --https=9000 http://127.0.0.1:9000   # Portainer
sudo tailscale serve --bg --https=8800 http://127.0.0.1:8800   # Perses dashboards
```

Then open `https://HOST.TAILNET.ts.net:8090` from a device in your tailnet.
The panel asks for its token once: it is in `SECRETS_DIR/panel-token`.
Without Tailscale, use an SSH tunnel: `ssh -L 8090:127.0.0.1:8090 pi@HOST`.

`bin/decolab-tailnet-ports TAILNET-IP` shows which ports of this Pi a device
of your tailnet may really reach. It reads the packet filter the Pi applies,
not the rules in the admin console.

**Use Pi-hole as DNS:** set `HOST_LAN_IP` as the DNS server in your router's
DHCP settings.

## 8. Firewall and SSH hardening (HARDENING=yes)

install.sh puts the files in place but switches nothing on. In an SSH login
from your LAN (`confirm` accepts only a new login over the LAN: that is the
proof that the LAN can still reach SSH):

```bash
cd /opt/decolab
bin/decolab-firewall check          # would it lock out this login?
sudo bin/decolab-firewall apply     # on trial, for 5 minutes
```

Then open a **new** SSH login from the LAN, within 5 minutes:

```bash
sudo /opt/decolab/bin/decolab-firewall confirm
```

With `SSH_PASSWORDS=no` the trial also turns SSH passwords off: open the new
login with your key. apply refuses without a key in `~/.ssh/authorized_keys`.

If the new login does not work, do nothing: after 5 minutes the firewall
switches itself off again (and passwords work again). The way back at any time is
`sudo /opt/decolab/bin/decolab-firewall off`. Without SSH, put a file named
`decolab-firewall-off` on the SD card's boot partition (`/boot/firmware`,
readable from any computer) and reboot.

## 9. Check that it works

- The morning report (06:15, with `NOTIFY=telegram`) lists the night's
  backup, the restore probes and anything that is not in order.
- Uptime Kuma shows every push monitor green after its first run. The restore
  probes run between 05:50 and 06:05, so their monitors turn green the next
  morning.
- `tools/check.sh test` runs the contract tests on the Pi too (needs Docker).

What runs when: [docs/schedule.md](docs/schedule.md). Rebuilding from a
backup: [RESTORE.md](RESTORE.md).

## Updating

Decolab's images are pinned by digest, so nothing changes on its own. An
update is a new release of this repository:

```bash
bin/decolab-checkout v1.1.0               # fetches, checks the signature, checks out
./install.sh                              # host files and schedules of the release
scripts/update.sh --dry-run               # which containers would change
scripts/update.sh
```

Release tags are signed. `decolab-checkout` checks the signature against
`/etc/decolab/release-signers`, the keys install.sh placed from the release
you run now, and refuses an unsigned tag or another key: root runs scripts
from this checkout, so nothing unsigned may get there. A new release key
arrives the same way, inside a release signed by the old one.

`update.sh` checks everything first and pulls every image before it touches
anything. It makes a backup if the last one is older than 6 hours, then
recreates only the containers whose image changed. It waits until each one is
healthy and deletes no image: the old ones are the way back. After a database
migration (Immich, Vaultwarden, Kuma) the way back is the backup, not the old
image: see [RESTORE.md](RESTORE.md). `scripts/update-report.sh` (Mondays, by
Telegram) says what is open: Debian packages, a reboot, the Docker engine and
a newer Decolab release.
