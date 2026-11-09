# Architecture

How the pieces of Decolab fit together. For what runs when, see
[schedule.md](schedule.md); for the threat model, [security.md](security.md).

## Layers

```
decolab.conf  ──►  install.sh  ──►  /etc (cron, systemd units, firewall)
  (KEY=VALUE,        │                    │
   validated)        ├──►  SECRETS_DIR    │
                     │     (generated)    ▼
                     └──►  docker compose stacks ──► services
                                                       ▲
              scripts/ (cron) ── check, back up, probe ┘
                     │
                     └──► notify (Telegram / ntfy) and Prometheus metrics
```

1. **Configuration.** One plain `decolab.conf` (`KEY=VALUE`).
   `lib/config.sh` reads it as data, never executes it, and checks every key
   against `config/schema.txt`. `bin/decolab-config init` writes it with a
   short question-and-answer session.
2. **Installation.** `install.sh` is idempotent: it creates users,
   directories and secrets, renders templates from `config/` with
   `lib/render.py` (only declared variables, values through the
   environment), installs cron jobs and systemd units, and starts the
   stacks. It never overwrites a file that was changed on the host; it
   reports the difference instead.
3. **Services.** Docker Compose stacks: `compose/core.yml` (Unbound,
   Pi-hole, Prometheus, cAdvisor, Perses, Portainer, Samba and two Docker
   socket proxies) and `stacks/` (Immich, Vaultwarden, Uptime Kuma,
   Watchtower). Every image is pinned by digest.
   `bin/decolab-compose` starts a stack with its env files.
4. **Host services.** Small Python programs in `services/` (fan control,
   OLED display) and `panel/server.py`, a read-only dashboard
   ([panel.md](panel.md)). Python uses the standard library only.
5. **Operations.** Shell scripts in `scripts/`, run by cron: backup (local,
   USB, off-site with restic), nightly restore probes, health checks,
   watchdog, update report. They share `lib/common.sh` (logging,
   notifications, maintenance flag) and write metrics for Prometheus
   ([metrics.md](metrics.md)).
6. **Host hardening.** `bin/decolab-firewall` (nftables allow list with a
   trial and confirmation step) and `bin/decolab-harden-unit` (systemd
   sandboxing), both opt-in through `HARDENING=yes`.

## Updates and releases

`bin/decolab-checkout` and `scripts/update.sh` check out only release tags
signed by a key in `/etc/decolab/release-signers`. Every night
`scripts/image-digests.sh` records which image ran when, so RESTORE.md can go
back to the image before an update.

## Tests

`tests/` holds contract tests: each runs a script or the panel against a
temporary directory or container and checks what it promises. `tools/check.sh`
runs them together with shellcheck, ruff, mypy, the private-data guard and
gitleaks; CI runs the same on every push.
