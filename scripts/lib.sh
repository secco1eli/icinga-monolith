#!/usr/bin/env bash
# Shared library for Icinga2 scripts
# Source this file: source "$(dirname "$0")/../scripts/lib.sh"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config (non-sensitive settings)
if [[ -f "${_LIB_DIR}/config.env" ]]; then
    # shellcheck source=config.env
    source "${_LIB_DIR}/config.env"
fi

# Load secrets (credentials — gitignored, never committed)
if [[ -f "${_LIB_DIR}/secrets.env" ]]; then
    # shellcheck source=/dev/null
    source "${_LIB_DIR}/secrets.env"
fi

# ─── Icinga2 API helpers ──────────────────────────────────────────────────────

# Resolve API password: use config, or extract from icinga2 api-users.conf
icinga2_pass() {
    if [[ -n "${ICINGA2_PASS:-}" ]]; then
        echo "$ICINGA2_PASS"
        return
    fi
    # Extract password for ICINGA2_USER from icinga2 config
    local conf="/etc/icinga2/conf.d/api-users.conf"
    if [[ -f "$conf" ]]; then
        # Find the block for our user and grab its password
        awk -v user="${ICINGA2_USER}" '
            /object ApiUser/ { in_block = ($3 == "\"" user "\"") }
            in_block && /password/ { gsub(/[" ]/, "", $3); print $3; exit }
        ' "$conf"
    fi
}

# POST to Icinga2 API
# Usage: icinga2_api POST /v1/objects/hosts/myhost '{"templates":[...],...}'
icinga2_api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local pass
    pass="$(icinga2_pass)"

    curl -sSk \
        -u "${ICINGA2_USER}:${pass}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -X "$method" \
        ${body:+--data "$body"} \
        "https://${ICINGA2_HOST}:${ICINGA2_PORT}${path}"
}

# Query QuestDB REST API, returns raw JSON response
# Usage: questdb_query "SELECT ..."
questdb_query() {
    local query="$1"
    curl -sSf \
        ${QUESTDB_USER:+-u "${QUESTDB_USER}:${QUESTDB_PASS}"} \
        -G "http://${QUESTDB_HOST}:${QUESTDB_PORT}/exec" \
        --data-urlencode "query=${query}" \
        --data-urlencode "fmt=json"
}

# Submit a passive check result to Icinga2
# Usage: submit_passive_check <host> <service|""> <exit_code> <output> [perf_data]
#   exit_code: 0=OK 1=WARNING 2=CRITICAL 3=UNKNOWN
#   service: pass empty string "" for host checks
submit_passive_check() {
    local host="$1"
    local service="${2:-}"
    local exit_code="$3"
    local output="$4"
    local perf_data="${5:-}"

    local type="Host"
    local filter="host.name==\"${host}\""
    if [[ -n "$service" ]]; then
        type="Service"
        filter="host.name==\"${host}\" && service.name==\"${service}\""
    fi

    local body
    body="$(cat <<JSON
{
  "type": "${type}",
  "filter": "${filter}",
  "exit_status": ${exit_code},
  "plugin_output": $(printf '%s' "$output" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "performance_data": $(printf '%s' "$perf_data" | python3 -c 'import json,sys; d=sys.stdin.read(); print("[]" if not d else json.dumps(d.split()))'),
  "check_source": "passive-script"
}
JSON
)"

    icinga2_api POST /v1/actions/process-check-result "$body"
}
