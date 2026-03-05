#!/usr/bin/env bash
# passive-check.sh
# Generic wrapper to submit a passive check result to Icinga2.
#
# Usage:
#   ./passive-check.sh --host <host> [--service <service>] \
#                      --status <ok|warning|critical|unknown> \
#                      --output "Check output text" \
#                      [--perfdata "metric=value;warn;crit;min;max"]
#
# Or pipe a check plugin's output:
#   /usr/lib/nagios/plugins/check_disk -w 20% -c 10% -p / | \
#     ./passive-check.sh --host myserver --service "disk /" --from-stdin
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

HOST=""
SERVICE=""
STATUS=""
OUTPUT=""
PERFDATA=""
FROM_STDIN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       HOST="$2";     shift ;;
        --service)    SERVICE="$2";  shift ;;
        --status)     STATUS="$2";   shift ;;
        --output)     OUTPUT="$2";   shift ;;
        --perfdata)   PERFDATA="$2"; shift ;;
        --from-stdin) FROM_STDIN=true ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

[[ -z "$HOST" ]] && { echo "Error: --host is required"; exit 1; }

# Read from stdin (nagios plugin output format: "STATUS: text | perfdata")
if $FROM_STDIN; then
    RAW="$(cat)"
    OUTPUT="$(echo "$RAW" | cut -d'|' -f1 | sed 's/^[A-Z]*: //' | tr -d '\n')"
    PERFDATA="$(echo "$RAW" | grep '|' | cut -d'|' -f2 | tr -d '\n')"
    # Infer status from first word
    FIRST_WORD="$(echo "$RAW" | awk '{print $1}' | tr -d ':')"
    case "${FIRST_WORD^^}" in
        OK)       STATUS="ok" ;;
        WARNING)  STATUS="warning" ;;
        CRITICAL) STATUS="critical" ;;
        *)        STATUS="unknown" ;;
    esac
fi

[[ -z "$STATUS" ]] && { echo "Error: --status is required (or use --from-stdin)"; exit 1; }
[[ -z "$OUTPUT" ]] && { echo "Error: --output is required (or use --from-stdin)"; exit 1; }

# Map status string to exit code
case "${STATUS,,}" in
    ok|0)       EXIT_CODE=0 ;;
    warning|1)  EXIT_CODE=1 ;;
    critical|2) EXIT_CODE=2 ;;
    unknown|3)  EXIT_CODE=3 ;;
    *) echo "Error: unknown status '${STATUS}'"; exit 1 ;;
esac

RESULT=$(submit_passive_check "$HOST" "$SERVICE" "$EXIT_CODE" "$OUTPUT" "$PERFDATA")

if echo "$RESULT" | grep -q '"code":200'; then
    echo "OK: passive check submitted for ${HOST}${SERVICE:+/${SERVICE}}"
else
    echo "Error submitting check result: $RESULT" >&2
    exit 1
fi
