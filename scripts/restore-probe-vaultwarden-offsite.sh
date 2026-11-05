#!/usr/bin/env bash
# restore-probe-vaultwarden-offsite.sh - the Vaultwarden probe, from the
# newest off-site (restic) snapshot instead of the local backup. Runs as root
# on Sundays (cron.d-decolab-root): the repository is reached with root's SSH key.
exec "$(dirname "$0")/restore-probe-vaultwarden.sh" --offsite
