# Security policy

## Reporting a vulnerability

Please report security problems **privately**, through GitHub's private
vulnerability reporting: the repository's *Security* tab, then *Report a
vulnerability*
(<https://github.com/DanielEnki420/decolab/security/advisories/new>). Do not open a public issue for them.

Helpful in a report: the Decolab release, what an attacker needs (a device
in the LAN, in the tailnet, a login on the Pi), and the steps to reproduce.

Decolab is a hobby project, provided as is (see the licenses). Reports are
read and fixed as time allows; there is no guaranteed response time and no
bug bounty. A fix comes as a new release, with the problem named in its
notes once the release is out.

## Supported versions

Only the newest release. Its images are pinned by digest, so a security fix
in a service (Pi-hole, Immich, Vaultwarden ...) reaches you as a new Decolab
release, not by itself. `scripts/update-report.sh` tells you when a newer
release exists.

## Scope

In scope: Decolab's own code (install.sh, the scripts, the panel, the
firewall, the compose files and their settings).

Out of scope: the services Decolab runs (report those to their
publishers), Debian, Docker and Tailscale themselves, and setups that
contradict the documentation (for example `WEB_UI_ADDRESS=HOST_LAN_IP`
without `HARDENING=yes`, or ports forwarded from the internet).

What Decolab protects against, and what it does not:
[docs/security.md](docs/security.md).
