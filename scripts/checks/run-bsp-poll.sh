#!/usr/bin/env bash
# run-bsp-poll.sh
# Sources config.env and secrets.env, then runs the bsp-poll binary.
# Designed to be called from cron:
#   */2 * * * * root /opt/icinga-scripts/checks/run-bsp-poll.sh --once
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

exec "${SCRIPT_DIR}/bsp-poll" "$@"
