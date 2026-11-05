# The panel (stage 1)

A read-only dashboard: `panel/server.py`, Python standard library only, run by
`decolab-panel.service` on `WEB_UI_ADDRESS:PANEL_PORT` (default 8090).

It shows; it does not act. No route reboots, restarts, updates or writes.

## Access

- The token is in `SECRETS_DIR/panel-token` (made by install.sh). A browser
  asks for it once and keeps it as an HttpOnly cookie for 30 days. Scripts
  send `Authorization: Bearer TOKEN`.
- Only this host's names are accepted in the `Host` header: localhost,
  127.0.0.1, the host name, `HOST_LAN_IP`, and with Tailscale
  `HOST.TAILNET_NAME.ts.net`. Anything else gets 421 (DNS rebinding).
- With `WEB_UI_ADDRESS=127.0.0.1`, publish it through `tailscale serve` or an
  SSH tunnel. The firewall opens it to the LAN only when
  `WEB_UI_ADDRESS=HOST_LAN_IP`.

## API

All routes are `GET`; every other method gets 405. Everything but `health`
needs the token. What a host does not have is `{"available": false}` (or
`null` for a single value), never an error.

| Route | Content |
|---|---|
| `/api/v1/health` | `{"ok": true, "version": ...}`, no token |
| `/api/v1/system` | host name, model, kernel, uptime, load, CPU (per core), memory, swap, disks, temperatures, fan, network |
| `/api/v1/history` | the last 60 samples (every 5 s): `t`, `cpu`, `ram`, `cpu_temp`, `nvme_temp`, `rx`, `tx` |
| `/api/v1/containers` | the containers of this installation and any extra ones, from Prometheus (cAdvisor) |
| `/api/v1/alerts` | Prometheus alerts: firing ones with name and summary, pending ones counted |
| `/api/v1/services` | the web interfaces to link to, by the enabled modules |
| `/api/v1/backup` | newest complete backup in `BACKUP_DIR`, its age, a run in progress |
| `/api/v1/speedtest` | the last 60 measurements, if `SPEEDTEST=yes` |

`tests/test-panel.sh` is the contract: the Rust panel of stage 2 must pass
it unchanged.

## Why it cannot touch Docker

The panel runs as the Decolab user, who is in the docker group. Its unit
forbids UNIX sockets (`RestrictAddressFamilies=AF_INET AF_INET6`), so
`/var/run/docker.sock` is out of reach, and allows traffic only to localhost
and `LAN_SUBNET`. Container state comes from Prometheus instead.
