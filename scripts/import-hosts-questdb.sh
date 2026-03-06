#!/usr/bin/env bash
# import-hosts-questdb.sh
# Queries QuestDB for hosts and creates/updates them in Icinga2 via the API.
#
# Usage:
#   ./import-hosts-questdb.sh [--dry-run] [--query "SELECT ..."]
#
# The query must return at minimum:
#   host_name TEXT  - Icinga2 host object name
#   address   TEXT  - IP or hostname to check
#
# Optional columns:
#   display_name TEXT
#   os           TEXT  - sets vars.os
#   location     TEXT  - sets vars.location
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

DRY_RUN=false
CUSTOM_QUERY=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --query)      CUSTOM_QUERY="$2"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
    shift
done

DEFAULT_QUERY="SELECT DISTINCT host AS host_name, '127.0.0.1' AS address FROM cpu"
QUERY="${CUSTOM_QUERY:-${DEFAULT_QUERY}}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Querying QuestDB at ${QUESTDB_HOST}:${QUESTDB_PORT}..."
RESPONSE="$(questdb_query "$QUERY")"

# Check for QuestDB error
if echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'dataset' in d else 1)" 2>/dev/null; then
    :
else
    echo "QuestDB error: $RESPONSE" >&2
    exit 1
fi

# Parse columns and rows
COLUMNS=$(echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(' '.join(col['name'] for col in d['columns']))
")
log "Columns: ${COLUMNS}"

# Process each host row
CREATED=0
UPDATED=0
FAILED=0

while IFS= read -r row; do
    [[ -z "$row" ]] && continue

    HOST_NAME=$(echo "$row"    | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('host_name',''))")
    ADDRESS=$(echo "$row"      | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('address',''))")
    DISPLAY=$(echo "$row"      | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('display_name', d.get('host_name','')))")
    OS=$(echo "$row"           | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('os',''))")
    LOCATION=$(echo "$row"     | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('location',''))")

    if [[ -z "$HOST_NAME" || -z "$ADDRESS" ]]; then
        log "SKIP: missing host_name or address in row: $row"
        ((FAILED++)) || true
        continue
    fi

    # Build vars object
    VARS_JSON="{"
    [[ -n "$OS" ]]       && VARS_JSON+="\"os\": \"${OS}\","
    [[ -n "$LOCATION" ]] && VARS_JSON+="\"location\": \"${LOCATION}\","
    VARS_JSON="${VARS_JSON%,}}"  # remove trailing comma

    ZONE_JSON=""
    [[ -n "${ICINGA2_HOST_ZONE:-}" ]] && ZONE_JSON="\"zone\": \"${ICINGA2_HOST_ZONE}\","

    BODY="$(cat <<JSON
{
  "templates": ["${ICINGA2_HOST_TEMPLATE}"],
  "attrs": {
    "display_name": "${DISPLAY}",
    "address": "${ADDRESS}",
    "check_command": "dummy",
    "enable_active_checks": false,
    "enable_passive_checks": true,
    ${ZONE_JSON}
    "vars": ${VARS_JSON}
  }
}
JSON
)"

    if $DRY_RUN; then
        log "[DRY-RUN] Would upsert host: ${HOST_NAME} (${ADDRESS})"
        continue
    fi

    # Try PUT (create). If exists (422), use POST to update attrs.
    RESULT=$(icinga2_api PUT "/v1/objects/hosts/${HOST_NAME}" "$BODY" 2>&1)
    HTTP_CODE=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('results',[{}])[0].get('code',0))" 2>/dev/null || echo 0)

    if echo "$RESULT" | grep -q '"code":200'; then
        log "CREATED: ${HOST_NAME} (${ADDRESS})"
        ((CREATED++)) || true
    elif echo "$RESULT" | grep -q '"code":422'; then
        # Already exists — update with POST
        UPDATE_BODY="$(cat <<JSON
{
  "attrs": {
    "display_name": "${DISPLAY}",
    "address": "${ADDRESS}"
  }
}
JSON
)"
        icinga2_api POST "/v1/objects/hosts/${HOST_NAME}" "$UPDATE_BODY" > /dev/null
        log "UPDATED: ${HOST_NAME} (${ADDRESS})"
        ((UPDATED++)) || true
    else
        log "FAILED: ${HOST_NAME} — ${RESULT}"
        ((FAILED++)) || true
    fi

done < <(echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
cols = [c['name'] for c in d['columns']]
for row in d['dataset']:
    print(json.dumps(dict(zip(cols, row))))
")

log "Done. Created=${CREATED} Updated=${UPDATED} Failed=${FAILED}"
