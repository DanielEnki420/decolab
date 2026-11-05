# Restoring Decolab from a backup

Use this when the Pi, its SD card or its data disk is gone and you rebuild on
new hardware. Read it once **before** you need it. The restore probes prove
every night that the backups can be restored, but only you can practise the
steps.

## What is backed up where

| Copy | Where | What | Kept |
|---|---|---|---|
| Local, 03:00 | `BACKUP_DIR/<YYYY-MM-DD_HH-MM>/` | `pihole.tar.gz`, `vaultwarden.tar.gz`, `uptime-kuma.tar.gz`, `portainer.tar.gz`, `immich-db.sql.gz`, `config.tar.gz` | 7 (by count) |
| USB, 03:50 | `USB_BACKUP_DIR/` | `daily/` (the local backups), `immich/` (photo originals), `nas/` (Samba share), `deleted/` (what a mirror run replaced) | 90 / 30 days |
| Off-site, 04:10 | `RESTIC_REPOSITORY` (restic, encrypted) | the newest local backup, the photo originals, the Samba share | 7 daily, 4 weekly, 6 monthly |

`config.tar.gz` holds `decolab.conf` and every secret: database passwords,
the panel token, the restic password, the Telegram and Kuma tokens. It is
the key to everything else.

**The one thing that is not in any backup on its own:** the restic password.
It is inside `config.tar.gz`, and that is inside the encrypted repository.
If the Pi and the USB disk are both lost, you need the copy on your
emergency sheet (INSTALL.md, step 6). You also need a way into the off-site
server, for example an SSH key you keep somewhere else.

Not backed up, on purpose: Pi-hole's query history, Prometheus' metrics,
Immich's thumbnails and transcoded videos (Immich makes them again).

## 1. Choose the backup

Take the newest complete one: a directory named only by its date. A
directory ending in `-incomplete` had errors that night; use the one before.

- **USB disk:** `USB_BACKUP_DIR/daily/<date>/`
- **Off-site**, on any machine with restic:

  ```bash
  restic -r REPOSITORY snapshots --tag decolab
  restic -r REPOSITORY restore latest --tag decolab --target ~/decolab-restore
  ```

  restic asks for the password from your emergency sheet. The restored files
  keep their full paths, for example
  `~/decolab-restore/mnt/data/backups/<date>/`.

Below, `B` stands for that backup directory, and `U` for the folder that
holds the share: `USB_BACKUP_DIR` on the USB disk, or
`~/decolab-restore/mnt/data` (your `DATA_DIR`) in the restic target.

## 2. Set up the new system

Follow [INSTALL.md](INSTALL.md) steps 1 to 3: system, Docker, Tailscale,
data disk, the checkout in `DECOLAB_DIR`. Use the **same user name** and the
same Decolab release as before, if you know it.

If the Pi was in your tailnet: remove the old machine in the Tailscale admin
console first. Then the new one gets the same name, and `TAILNET_NAME`
still fits.

## 3. Put the configuration and the secrets back

```bash
cd /opt/decolab
mkdir -p ~/restore && tar -xzf B/config.tar.gz -C ~/restore
cp ~/restore/config/decolab.conf decolab.conf
bin/decolab-config check decolab.conf
SECRETS_DIR=$(sed -n 's/^SECRETS_DIR=//p' decolab.conf)
sudo install -d -m 700 -o "$USER" -g "$(id -gn)" "$SECRETS_DIR"
cp -p ~/restore/config/secrets/* "$SECRETS_DIR/"
chmod 600 "$SECRETS_DIR"/*
rm -rf ~/restore
```

Stay in `/opt/decolab` and in this shell for the next steps: they use
`$SECRETS_DIR`.

Change `decolab.conf` only where the new hardware differs, for example
`LAN_INTERFACE` or `HOST_LAN_IP`.

## 4. Set the host up, start nothing

```bash
./install.sh --dry-run --restore
./install.sh --restore
```

`--restore` does everything except starting the stacks, the schedules and
the watchdog. A nightly backup on an empty system would overwrite good
copies. It never generates a secret that data depends on: if one is missing,
step 3 is not complete, and it stops.

## 5. Put the data back

As your user, not root: every service keeps its files as this user. Replace
`/mnt/data` with your `DATA_DIR`.

```bash
tar -xzf B/pihole.tar.gz      -C /mnt/data
tar -xzf B/vaultwarden.tar.gz -C /mnt/data   # if MODULE_VAULTWARDEN=yes
tar -xzf B/uptime-kuma.tar.gz -C /mnt/data   # if MODULE_UPTIME_KUMA=yes
tar -xzf B/portainer.tar.gz   -C /mnt/data
rsync -a U/nas/ /mnt/data/nas/
```

**Immich** (if `MODULE_IMMICH=yes`): the photos and the database belong
together. Restore both before Immich starts:

```bash
# from the USB disk:    I=USB_BACKUP_DIR/immich
# from restic:          I=~/decolab-restore/mnt/data/immich/library
for p in upload library profile; do
  if [ -d "$I/$p" ]; then rsync -a "$I/$p/" "/mnt/data/immich/library/$p/"; else echo "not in the copy: $p"; fi
done

bin/decolab-compose immich up -d database
. "$SECRETS_DIR/immich.env"          # DB_USERNAME, DB_DATABASE_NAME
until docker exec immich_postgres pg_isready -q -h 127.0.0.1 -U "$DB_USERNAME"; do sleep 2; done
gzip -dc B/immich-db.sql.gz | docker exec -i immich_postgres \
  psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -q
bin/decolab-compose immich stop database
```

The backup leaves out the folders Immich regenerates (thumbs, encoded-video,
backups), but the restored database expects them. `install.sh --restore-done`
in step 6 creates the missing ones with their `.immich` marker.

Messages that something "already exists" are expected: the image creates the
database extensions itself, and so does the dump. Any other `ERROR` means the
dump did not load. Stop there and try the backup before.

## 6. Start everything

```bash
./install.sh --restore-done
```

This starts the stacks, the schedules and the watchdog, and remembers that
the restore is done.

## 7. Check it, not just look at it

- **DNS:** `getent hosts example.org` on a client that uses the Pi, and a
  domain from your block list must not resolve.
- **Vaultwarden:** log in from a device, and open an entry.
- **Immich:** open an old album. A photo that shows only as grey means the
  files are missing or in the wrong folder.
- **Uptime Kuma:** your monitors are there. The push monitors turn green
  after their next run.
- **The next morning:** the morning report lists the first backup and the
  restore probes of the new system.

## Going back after a failed update

`update.sh` keeps the old images. But after a database migration
(Immich, Vaultwarden or Kuma started with the new version), the old image
cannot read the database any more. Then: stop that stack
(`bin/decolab-compose STACK down`), move its data folder aside, check out the
release before (`git checkout v1.0.0`) and restore that one service as in
step 5 from the backup `update.sh` made before the update. Then run
`./install.sh` and `scripts/update.sh`: the old images are still there.
