# What runs when

Times are local (`TZ` in decolab.conf). The schedules are
`/etc/cron.d/decolab` (as `DECOLAB_USER`) and `/etc/cron.d/decolab-root`
(as root), made by install.sh from `config/cron/`. Logs are in
`/var/log/decolab/<script>.log`. Every job reports failures itself; the
morning report also says when all went well.

## Every night

| Time | Job | As |
|---|---|---|
| 03:00 | `backup.sh`: local backup, without stopping a container | user |
| 03:30 | `verify-backup.sh`: is the new backup complete and readable? | user |
| 03:45 | `image-digests.sh`: which image ran when (for going back) | user |
| 03:50 | `backup-usb.sh`: copy onto the USB disk (if set) | root |
| 04:10 | `backup-offsite.sh`: restic, off-site (if set) | root |
| 05:50 | `restore-probe-vaultwarden.sh` | user |
| 05:55 | `restore-probe-immich.sh` | user |
| 06:00 | `restore-probe-kuma.sh` | user |
| 06:05 | `restore-probe-pihole.sh` | user |
| 06:15 | `morning-report.sh`: one message, every morning | user |

## Sundays

| Time | Job | As |
|---|---|---|
| 06:30 | `check-restic-integrity.sh`: restic reads a part of the off-site data | root |
| 07:00 | `restore-probe-vaultwarden-offsite.sh`: the Vaultwarden probe from the off-site copy | root |

## During the day

| When | Job |
|---|---|
| every minute | `ups-metrics.sh` (UPS) |
| every 2 minutes | `check-perses.sh` |
| every 10 minutes | `check-samba-login.sh`, and the watchdog (systemd timer, root) |
| every 15 minutes | `monitor.sh`, `check-services.sh`, `check-cadvisor-coverage.sh`, `check-pihole-blocking.sh`, `check-unbound-dnssec.sh`, `check-portainer-docker.sh`, `check-prometheus-alerts.sh`, `device-watch.sh` (root) |
| every 30 minutes | `check-immich-data.sh` |
| hourly, :40 | `prometheus-rules-sync.sh` |
| every 6 hours | `check-nvme-health.sh` (:17), `speedtest.sh` (01:37, 07:37, 13:37, 19:37) |
| 08:15 | `check-tailscale-keys.sh` |
| 08:25 | `update-report.sh --quiet`, Mondays 09:20 with a message |

Jobs for a module or a device that is switched off end at once and do nothing.
The backup and the jobs after it share one lock: they never run at the same
time, and an update waits for them.
