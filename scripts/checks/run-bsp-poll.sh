#!/usr/bin/env bash
# run-bsp-poll.sh
# Cron wrapper for the bsp-poll passive check.
# Sources config.env and secrets.env, exports credentials as env vars,
# then runs the bsp-poll binary (which reads all other settings from bsp-poll.toml).
#
# Cron schedule is defined in bsp-poll.toml [schedule].cron.
# setup.sh installs the cron entry automatically — do not edit /etc/cron.d/ directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib.sh"

# Map config.env/secrets.env variable names to what bsp-poll expects
export QUESTDB_URL="http://${QUESTDB_HOST}:${QUESTDB_PORT}/exec"
export QUESTDB_USER="${QUESTDB_USER}"
export QUESTDB_PASS="${QUESTDB_PASS}"
export ICINGA_API_BASE="https://${ICINGA2_HOST}:${ICINGA2_PORT}/"
export ICINGA_API_USER="${ICINGA2_USER}"
export ICINGA_API_PASS="${ICINGA2_PASS}"

MASTER_HOST="$(hostname -f)"
SERVICE="BSP-poll Last Run"

# Run bsp-poll; capture output to detect whether it completed a cycle at all.
# Per-host 404s (e.g. master host has no BSP-poll service) cause a non-zero exit
# but are not a heartbeat failure — individual states are tracked per host.
BSP_OUTPUT="$("${SCRIPT_DIR}/bsp-poll" "$@" 2>&1)" || true
echo "$BSP_OUTPUT"

if echo "$BSP_OUTPUT" | grep -q "Shutdown complete"; then
    submit_passive_check "$MASTER_HOST" "$SERVICE" 0 "OK: bsp-poll completed at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
else
    submit_passive_check "$MASTER_HOST" "$SERVICE" 2 "CRITICAL: bsp-poll did not complete at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    exit 1
fi
