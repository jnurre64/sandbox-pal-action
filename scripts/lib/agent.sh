#!/bin/bash
AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091  # Runtime sibling path.
source "${AGENT_LIB_DIR}/engine-claude.sh"
# shellcheck disable=SC1091
source "${AGENT_LIB_DIR}/engine-codex.sh"
# shellcheck disable=SC1091
source "${AGENT_LIB_DIR}/agent-config.sh"

# stdout is always one envelope, including preflight and process failures.
# Keep the existing argument order while consumers migrate to the neutral API.
run_agent() (
    set -euo pipefail
    local prompt="$1" allowed_tools="${2:-$AGENT_ALLOWED_TOOLS_IMPLEMENT}"
    local model="${3:-}" schema="${4:-}" phase="${5:-}"
    local schema_json="" error stderr_log raw exit_code=0 normalized
    local resolved engine=claude
    if [ -n "${AGENT_PHASE_MAP:-}" ]; then
        resolved=$(jq -c --arg phase "$phase" '.[$phase] // empty' <<< "$AGENT_PHASE_MAP")
        if [ -z "$resolved" ]; then
            agent_failure "$phase" configuration 'Phase was not preflighted for this dispatch'
            return
        fi
        schema_json=$(jq -r .schema_json <<< "$resolved")
    elif ! resolved=$(agent_resolve_config "$phase" "$model" 2>&1); then
        local route
        if route=$(agent_resolve_phase "$phase" "$model" 2>/dev/null); then
            engine=$(jq -r .engine <<< "$route")
        fi
        agent_failure "$phase" configuration "$(redact_secrets <<< "$resolved")" "$engine"
        return
    fi
    engine=$(jq -r .engine <<< "$resolved")
    model=$(jq -r .model <<< "$resolved")
    if [ "$engine" = codex ] && [ "$#" -ge 2 ]; then
        # An explicitly empty native tool argument must not inherit a Claude
        # implementation allowlist in a mixed implementation/review dispatch.
        allowed_tools="$2"
    fi
    if ! agent_engine_enabled "$engine"; then
        agent_failure "$phase" configuration 'Unsupported worker engine' "$engine"
        return
    fi
    if ! python3 "${AGENT_LIB_DIR}/agent-result.py" check-dependency >/dev/null 2>&1; then
        agent_failure "$phase" configuration 'Install worker dependencies: python3 -m pip install -r scripts/requirements-worker.txt' "$engine"
        return
    fi
    if [ -n "$schema" ] && [ -z "${AGENT_PHASE_MAP:-}" ]; then
        if [[ "$schema" != /* ]] && [ -n "${CONFIG_DIR:-}" ]; then
            schema="${CONFIG_DIR}/${schema}"
        fi
        if ! schema_json=$(python3 "${AGENT_LIB_DIR}/agent-result.py" check-schema "$schema" 2>/dev/null); then
            agent_failure "$phase" configuration 'Configured schema is missing, invalid, or uses unsupported external references' "$engine"
            return
        fi
    fi
    if [ "$engine" = codex ]; then
        local policy
        policy=$(jq -c '.policy // null' <<< "$resolved")
        if [ "$policy" = null ]; then
            agent_failure "$phase" configuration 'Missing preflighted Codex policy' codex
        elif raw=$(engine_codex "$prompt" "$allowed_tools" "$model" "$schema_json" "$phase" "$policy") &&
            jq -se --arg phase "$phase" 'length == 1 and (.[0] | .version == 1 and .engine == "codex" and .phase == $phase and (.status == "success" or .status == "failed" or .status == "timed_out" or .status == "cancelled"))' <<< "$raw" >/dev/null 2>&1; then
            printf '%s\n' "$raw"
        else
            agent_failure "$phase" transport 'Unable to invoke or normalize Codex worker' codex
        fi
        return
    fi
    # Unique restricted capture files; never reuse a phase's previous output.
    # shellcheck disable=SC2153  # AGENT_LOG_DIR comes from dispatch configuration.
    stderr_log=$(mktemp "${AGENT_LOG_DIR}/claude-stderr-${phase:-phase}-XXXXXX.log") || {
        agent_failure "$phase" configuration 'Cannot create worker capture file'
        return
    }
    raw=$(engine_claude "$prompt" "$allowed_tools" "$model" "$schema_json" "$phase" "$(jq -c .policy <<< "$resolved")" 2>"$stderr_log") || exit_code=$?
    error=$(redact_secrets < "$stderr_log")
    printf '%s\n' "$error" > "$stderr_log"
    # The normalizer scrubs decoded fields before schema validation and JSON
    # serialization, so escaped credentials cannot evade capture redaction.
    if normalized=$(printf '%s' "$raw" | python3 "${AGENT_LIB_DIR}/agent-result.py" normalize "$phase" "$exit_code" "$schema_json" "$stderr_log" 2>/dev/null); then
        printf '%s\n' "$normalized"
    else
        agent_failure "$phase" transport 'Unable to normalize worker result'
    fi
)

agent_failure() {
    jq -cn --arg phase "$1" --arg kind "$2" --arg message "$3" --arg engine "${4:-claude}" '{
        version:1, engine:$engine, phase:$phase, process_exit_code:null,
        status:"failed", error:{kind:$kind,message:$message}, result_text:"",
        structured_output:null, schema_status:"not_checked", permission_denials:[],
        denials_available:false, usage:{input_tokens:null,output_tokens:null,cached_input_tokens:null},cost_usd:null
    }'
}

agent_succeeded() {
    printf '%s' "$1" | jq -e '.version == 1 and .status == "success"' >/dev/null 2>&1
}

# A failure names its cause and, in brackets, the evidence the adapter kept
# (subtype, terminal reason, API status, the first line of the error text —
# already redacted and bounded), so the log line and the issue comment carry
# enough to diagnose the stop without the run's stdout.
parse_agent_output() {
    printf '%s' "$1" | jq -r 'if .status == "success" then .result_text
        else "Agent phase failed: " + (.error.message // "unknown failure")
            + (if (.error.detail // "") != "" then " [" + .error.detail + "]" else "" end) end'
}

# fail_fast covers auth, quota (billing), usage_limit (a closed subscription window —
# retrying now would only burn the fix-up phases against the same wall), permission,
# configuration, schema and unknown; recoverable is what the fix-up phases exist for.
classify_agent_result() {
    printf '%s' "$1" | jq -r 'if .version != 1 then "fail_fast"
        elif .status == "success" then "ok"
        elif .status == "timed_out" or .error.kind == "rate_limit" or .error.kind == "limit" then "recoverable"
        else "fail_fast" end' 2>/dev/null || printf 'fail_fast\n'
}

# A failed read/decision phase must never advance based on partial JSON.
require_agent_success() {
    local result="$1" phase="$2"
    agent_succeeded "$result" && return 0
    local detail
    detail=$(parse_agent_output "$result")
    log "${phase}: ${detail}"
    set_label "agent:failed"
    gh issue comment "$NUMBER" --repo "$REPO" --body "Agent ${phase} failed: ${detail}" 2>/dev/null || true
    return 1
}
