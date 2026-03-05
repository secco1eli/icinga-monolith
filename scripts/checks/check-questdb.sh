#!/usr/bin/env bash
# check-questdb.sh
# Passive check: verify QuestDB is reachable and query latency is within bounds.
# Submits result directly to Icinga2.
#
# Usage:
#   ./checks/check-questdb.sh [--host <icinga-host>] [--service <icinga-service>] \
#                             [--warn-ms 500] [--crit-ms 2000]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib.sh"

ICINGA_HOST="${HOSTNAME:-$(hostname -s)}"
ICINGA_SERVICE="QuestDB"
WARN_MS=500
CRIT_MS=2000

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)     ICINGA_HOST="$2";    shift ;;
        --service)  ICINGA_SERVICE="$2"; shift ;;
        --warn-ms)  WARN_MS="$2";        shift ;;
        --crit-ms)  CRIT_MS="$2";        shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

START_NS=$(date +%s%N)
HTTP_CODE=$(curl -sSo /dev/null -w "%{http_code}" \
    -G "http://${QUESTDB_HOST}:${QUESTDB_PORT}/exec" \
    --data-urlencode "query=SELECT 1" \
    --connect-timeout 5 \
    --max-time 10 2>/dev/null || echo 0)
END_NS=$(date +%s%N)

ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

if [[ "$HTTP_CODE" != "200" ]]; then
    submit_passive_check "$ICINGA_HOST" "$ICINGA_SERVICE" 2 \
        "CRITICAL: QuestDB unreachable (HTTP ${HTTP_CODE}) at ${QUESTDB_HOST}:${QUESTDB_PORT}" \
        "response_time=${ELAPSED_MS}ms;${WARN_MS};${CRIT_MS};0;" > /dev/null
    echo "CRITICAL: QuestDB unreachable"
    exit 2
elif (( ELAPSED_MS > CRIT_MS )); then
    submit_passive_check "$ICINGA_HOST" "$ICINGA_SERVICE" 2 \
        "CRITICAL: QuestDB response ${ELAPSED_MS}ms (threshold ${CRIT_MS}ms)" \
        "response_time=${ELAPSED_MS}ms;${WARN_MS};${CRIT_MS};0;" > /dev/null
    echo "CRITICAL: ${ELAPSED_MS}ms"
    exit 2
elif (( ELAPSED_MS > WARN_MS )); then
    submit_passive_check "$ICINGA_HOST" "$ICINGA_SERVICE" 1 \
        "WARNING: QuestDB response ${ELAPSED_MS}ms (threshold ${WARN_MS}ms)" \
        "response_time=${ELAPSED_MS}ms;${WARN_MS};${CRIT_MS};0;" > /dev/null
    echo "WARNING: ${ELAPSED_MS}ms"
    exit 1
else
    submit_passive_check "$ICINGA_HOST" "$ICINGA_SERVICE" 0 \
        "OK: QuestDB responded in ${ELAPSED_MS}ms" \
        "response_time=${ELAPSED_MS}ms;${WARN_MS};${CRIT_MS};0;" > /dev/null
    echo "OK: ${ELAPSED_MS}ms"
    exit 0
fi
