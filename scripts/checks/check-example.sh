#!/usr/bin/env bash
# check-example.sh
# Template for writing a new passive check script.
# Copy this file, rename it, and implement the check logic.
#
# Usage: ./checks/check-example.sh --host <icinga-host> --service <icinga-service>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib.sh"

ICINGA_HOST="${HOSTNAME:-$(hostname -s)}"
ICINGA_SERVICE="Example Check"
WARN_THRESHOLD=80
CRIT_THRESHOLD=90

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)      ICINGA_HOST="$2";       shift ;;
        --service)   ICINGA_SERVICE="$2";    shift ;;
        --warn)      WARN_THRESHOLD="$2";    shift ;;
        --crit)      CRIT_THRESHOLD="$2";    shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

# ── Implement your check logic here ──────────────────────────────────────────
VALUE=42          # Replace with your actual metric collection
UNIT="units"
PERFDATA="value=${VALUE}${UNIT};${WARN_THRESHOLD};${CRIT_THRESHOLD};0;"

if (( VALUE >= CRIT_THRESHOLD )); then
    STATUS=2
    MESSAGE="CRITICAL: value is ${VALUE}${UNIT} (>= ${CRIT_THRESHOLD})"
elif (( VALUE >= WARN_THRESHOLD )); then
    STATUS=1
    MESSAGE="WARNING: value is ${VALUE}${UNIT} (>= ${WARN_THRESHOLD})"
else
    STATUS=0
    MESSAGE="OK: value is ${VALUE}${UNIT}"
fi
# ─────────────────────────────────────────────────────────────────────────────

submit_passive_check "$ICINGA_HOST" "$ICINGA_SERVICE" "$STATUS" "$MESSAGE" "$PERFDATA" > /dev/null
echo "$MESSAGE | $PERFDATA"
exit "$STATUS"
