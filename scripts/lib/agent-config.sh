#!/bin/bash
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/named-profiles.sh"

# Resolve only phases reachable by this event. No worker or GitHub mutations.
agent_reachable_phases() {
    local event="$1" implementation=false
    case "$event" in
        status) return ;;
        new_issue) echo TRIAGE ;;
        issue_reply)
            printf '%s\n' REPLY TRIAGE
            if [ "${AGENT_ALLOW_DIRECT_IMPLEMENT:-true}" = true ]; then
                echo VALIDATE
                implementation=true
            fi ;;
        direct_implement)
            if [ "${AGENT_ALLOW_DIRECT_IMPLEMENT:-true}" = true ]; then
                echo VALIDATE
                implementation=true
            fi ;;
        implement) implementation=true ;;
        pr_review)
            echo REVIEW
            # The revision's test gate can launch fix sessions.
            if [ "${AGENT_REVISION_TEST_GATE:-true}" = true ] && [ -n "${AGENT_TEST_COMMAND:-}" ] \
                && [[ ! "${AGENT_TEST_GATE_MAX_RETRIES:-2}" =~ ^0+$ ]]; then
                echo TEST_FIX
            fi ;;
        post_merge) [ "${AGENT_CLEANUP_ENABLED:-true}" != true ] || echo CLEANUP ;;
        *) echo 'Unknown dispatch event' >&2; return 1 ;;
    esac
    if [ "$implementation" = true ]; then
        [ "${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}" != true ] || echo ADVERSARIAL_PLAN
        echo IMPLEMENT
        # Match the gates' fallback for invalid retry counts, without arithmetic
        # evaluation of operator-provided strings (or octal parsing of 08).
        if [ -n "${AGENT_TEST_COMMAND:-}" ] && [[ ! "${AGENT_TEST_GATE_MAX_RETRIES:-2}" =~ ^0+$ ]]; then
            echo TEST_FIX
        fi
        if [ "${AGENT_POST_IMPL_REVIEW:-true}" = true ]; then
            echo POST_IMPL_REVIEW
            [[ "${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-3}" =~ ^0+$ ]] || echo POST_IMPL_RETRY
        fi
    fi
}

agent_resolve_phase() {
    local phase="$1" explicit_model="${2:-}" engine model var default_engine="${AGENT_ENGINE:-claude}"
    agent_profiles_prepare || return 1
    if ! agent_phase_valid "$phase"; then echo 'Unknown worker phase' >&2; return 1; fi
    if [ "${AGENT_SELECTED_PROFILE:-legacy}" != legacy ]; then default_engine=$(jq -r .engine <<< "$AGENT_NAMED_PROFILE"); fi
    case "$default_engine" in claude|codex) ;; *) echo 'AGENT_ENGINE must be claude or codex' >&2; return 1 ;; esac
    var="AGENT_ENGINE_${phase}"
    engine=$(agent_route_engine "$phase") || return 1
    case "$engine" in claude|codex) ;; *) echo "AGENT_ENGINE_${phase} must be claude or codex" >&2; return 1 ;; esac
    case "${AGENT_ENGINE_PROFILES:-false}" in
        true)
            model=$(agent_profile_setting "$engine" "$phase" MODEL | jq -r .value) || return 1
            model="${explicit_model:-$model}"
            jq -cn --arg engine "$engine" --arg model "$model" '{engine:$engine,model:$model}'
            return ;;
        false) ;;
        *) echo 'AGENT_ENGINE_PROFILES must be true or false' >&2; return 1 ;;
    esac
    var="AGENT_MODEL_${phase}"
    model="${explicit_model:-${!var:-}}"
    # Historical REPLY/VALIDATE inherited TRIAGE. Preserve that only when
    # both phases use the same engine; never leak a model across engines.
    if [ -z "$model" ] && [[ "$phase" = REPLY || "$phase" = VALIDATE ]] &&
        [ "$engine" = "${AGENT_ENGINE_TRIAGE:-$default_engine}" ]; then
        model="${AGENT_MODEL_TRIAGE:-}"
    fi
    var="AGENT_MODEL_${engine^^}"
    model="${model:-${!var:-}}"
    if [ -z "$model" ] && [ "$engine" = "$default_engine" ]; then
        model="${AGENT_MODEL:-}"
    fi
    # Reject recognizable cross-provider mistakes; custom provider model IDs
    # remain opaque and are passed unchanged to their selected CLI.
    case "$engine:$model" in
        codex:claude*|codex:sonnet*|codex:opus*|codex:haiku*|claude:gpt-*|claude:o[134]|claude:o[134]-*)
            echo "Model is incompatible with the ${engine} engine for ${phase:-worker}" >&2; return 1 ;;
    esac
    jq -cn --arg engine "$engine" --arg model "$model" '{engine:$engine,model:$model}'
}

# Explicit registry: only these settings accept engine/phase namespaces.
agent_setting_registry() {
    case "$1" in
        claude) printf '%s\n' MODEL EFFORT TIMEOUT BUDGET_USD PERMISSION_MODE MAX_TURNS ;;
        codex) printf '%s\n' MODEL EFFORT TIMEOUT ;;
        *) return 1 ;;
    esac
}

# Empty optional settings inherit; false and 0 are values, never absence.
# All indirect names are constructed from a validated engine/phase/setting.
agent_profile_setting() {
    local engine="$1" phase="$2" setting="$3" key value='' source=default overlay="${AGENT_NAMED_PROFILE:-}"
    overlay="${overlay:-'{}'}"
    case "$engine" in claude|codex) ;; *) return 1 ;; esac
    agent_phase_valid "$phase" || return 1
    case "$setting" in MODEL|EFFORT|TIMEOUT|BUDGET_USD|PERMISSION_MODE|MAX_TURNS) ;; *) return 1 ;; esac
    local keys=("AGENT_${setting}_${engine^^}_${phase}" "AGENT_${setting}_${engine^^}")
    if [ "$engine" = claude ]; then
        case "$setting" in
            MODEL)
                keys+=("AGENT_MODEL_${phase}")
                if [[ "$phase" = REPLY || "$phase" = VALIDATE ]] &&
                    [ "$(agent_route_engine TRIAGE)" = claude ]; then
                    keys+=(AGENT_MODEL_TRIAGE)
                fi
                keys+=(AGENT_MODEL) ;;
            EFFORT) keys+=("AGENT_EFFORT_${phase}" AGENT_EFFORT_LEVEL) ;;
            BUDGET_USD) keys+=("AGENT_BUDGET_USD_${phase}" AGENT_BUDGET_USD) ;;
            PERMISSION_MODE) keys+=("AGENT_PERMISSION_MODE_${phase}") ;;
            MAX_TURNS) keys+=(AGENT_MAX_TURNS) ;;
        esac
    fi
    [ "$setting" != TIMEOUT ] || keys+=(AGENT_TIMEOUT)
    for key in "${keys[@]}"; do
        if [ "${AGENT_SELECTED_PROFILE:-legacy}" != legacy ] && jq -e --arg key "$key" '.settings | has($key)' <<< "$overlay" >/dev/null 2>&1; then
            value=$(jq -r --arg key "$key" '.settings[$key]' <<< "$AGENT_NAMED_PROFILE")
            [ -n "$value" ] || continue
            source="profile:${AGENT_SELECTED_PROFILE}:$key"
            break
        elif [ -n "${!key:-}" ]; then
            value="${!key}" source="$key"
            break
        fi
    done
    if [ "$source" = default ]; then
        case "$setting:$engine" in
            TIMEOUT:*) value=3600 ;;
            MAX_TURNS:claude) value=200 ;;
            EFFORT:claude) value=high ;;
        esac
    fi
    jq -cn --arg value "$value" --arg source "$source" '{value:$value,source:$source}'
}

agent_phase_settings() {
    local engine="$1" phase="$2" setting entry var value settings='{}' sources='{}'
    case "$engine" in claude|codex) ;; *) echo 'Unknown worker engine' >&2; return 1 ;; esac
    if ! agent_phase_valid "$phase"; then echo 'Unknown worker phase' >&2; return 1; fi
    if [ "${AGENT_ENGINE_PROFILES:-false}" = true ]; then
        if [ "$engine" = codex ]; then
            # Presence, including an empty/false/zero assignment, is an explicit
            # unsupported request. Do not mistake it for inactive Claude policy.
            for setting in BUDGET_USD PERMISSION_MODE MAX_TURNS ALLOWED_TOOLS DISALLOWED_TOOLS EXTRA_TOOLS LABEL_TOOLS MCP_CONFIG STRICT_MCP; do
                for var in "AGENT_${setting}_CODEX" "AGENT_${setting}_CODEX_${phase}"; do
                    if [ "${!var+x}" ]; then
                        echo "${phase}: ${var} is unsupported by Codex; keep this control in the Claude namespace" >&2
                        return 1
                    fi
                done
            done
        fi
        while read -r setting; do
            entry=$(agent_profile_setting "$engine" "$phase" "$setting") || return 1
            value=$(jq -r .value <<< "$entry")
            var=$(jq -r .source <<< "$entry")
            settings=$(jq -c --arg key "${setting,,}" --arg value "$value" '. + {($key):$value}' <<< "$settings")
            sources=$(jq -c --arg key "${setting,,}" --arg value "$var" '. + {($key):$value}' <<< "$sources")
        done < <(agent_setting_registry "$engine")
    else
        local budget='' effort='' permission=''
        if [ -n "$phase" ]; then
            var="AGENT_BUDGET_USD_${phase}"; budget="${!var:-${AGENT_BUDGET_USD:-}}"
            var="AGENT_EFFORT_${phase}"; effort="${!var:-}"
            var="AGENT_PERMISSION_MODE_${phase}"; permission="${!var:-}"
        fi
        settings=$(jq -cn --arg budget "$budget" --arg effort "$effort" --arg permission "$permission" \
            --arg turns "${AGENT_MAX_TURNS:-200}" --arg timeout "${AGENT_TIMEOUT:-3600}" \
            '{budget_usd:$budget,effort:$effort,permission_mode:$permission,max_turns:$turns,timeout:$timeout}')
        sources='{"mode":"legacy","timeout":"AGENT_TIMEOUT"}'
    fi
    jq -c --argjson sources "$sources" '. + {sources:$sources}' <<< "$settings"
}

# The same record is validated and executed, whether called directly or by dispatch.
agent_resolve_config() {
    local phase="$1" resolved engine settings policy
    agent_profiles_prepare || return 1
    resolved=$(agent_resolve_phase "$phase" "${2:-}") || return 1
    engine=$(jq -r .engine <<< "$resolved")
    settings=$(agent_phase_settings "$engine" "$phase") || return 1
    if [ "$engine" = codex ] && [ "$(agent_sandbox_profile "$phase")" != none ]; then
        echo "${phase}: the strict sandbox profile wraps Claude phases only; use the Codex engine's own sandbox setting" >&2
        return 1
    fi
    agent_phase_token_check || return 1
    case "$engine" in
        claude) policy=$(engine_claude_policy "$phase" "$settings") || return 1 ;;
        codex) policy=$(engine_codex_policy "$phase" "$settings") || return 1 ;;
    esac
    jq -c --argjson settings "$settings" --argjson policy "$policy" \
        --arg profile "${AGENT_SELECTED_PROFILE:-legacy}" --arg selection_source "${AGENT_PROFILE_SOURCE:-legacy}" \
        '. + {settings:$settings,policy:$policy,profile:$profile,selection_source:$selection_source}' <<< "$resolved"
}

agent_check_schema() {
    local schema="$1"
    [ -n "$schema" ] || return 0
    if [[ "$schema" != /* ]] && [ -n "${CONFIG_DIR:-}" ]; then
        schema="${CONFIG_DIR}/${schema}"
    fi
    python3 "${AGENT_LIB_DIR}/agent-result.py" check-schema "$schema" 2>/dev/null
}

agent_preflight_dispatch() {
    local phases phase resolved engine schema var map='{}' checked_claude=false checked_codex=false
    agent_profiles_prepare || return 1
    phases=$(agent_reachable_phases "$1") || return 1
    [ -n "$phases" ] || return 0
    if ! python3 "${AGENT_LIB_DIR}/agent-result.py" check-dependency >/dev/null 2>&1; then
        echo 'Install worker dependencies: python3 -m pip install -r scripts/requirements-worker.txt' >&2
        return 1
    fi
    for phase in $phases; do
        resolved=$(agent_resolve_config "$phase") || return 1
        engine=$(jq -r .engine <<< "$resolved")
        # Validate the selected engine; never fall back to a different engine.
        if ! agent_engine_enabled "$engine"; then
            echo "${phase}: Unsupported worker engine" >&2
            return 1
        fi
        var="AGENT_JSON_SCHEMA_${phase}"
        if ! schema=$(agent_check_schema "${!var:-}"); then
            echo "${phase}: configured schema is missing, invalid, or unsupported" >&2
            return 1
        fi
        case "$engine" in
            claude)
                if [ "$checked_claude" = false ]; then
                    engine_claude_preflight || return 1
                    checked_claude=true
                fi ;;
            codex)
                if ! printf '%s' "$schema" | python3 "${AGENT_LIB_DIR}/codex-worker.py" check-phase-schema "$phase"; then
                    echo "${phase}: unsupported Codex phase schema" >&2; return 1
                fi
                if [ "$checked_codex" = false ]; then
                    engine_codex_preflight || return 1
                    checked_codex=true
                fi
                ;;
        esac
        resolved=$(jq --arg schema "$schema" '. + {schema_json:$schema}' <<< "$resolved")
        map=$(jq -c --arg phase "$phase" --argjson config "$resolved" '. + {($phase):$config}' <<< "$map")
    done
    # Readonly shell state prevents later harness code from changing policy.
    # It is not a sandbox boundary against workers or file content changes.
    AGENT_PHASE_MAP="$map"
    # shellcheck disable=SC2034  # Consumed by run_agent in agent.sh.
    readonly AGENT_PHASE_MAP
    # shellcheck disable=SC2034 # Shared snapshot consumed by named-profiles.sh.
    readonly AGENT_PROFILE_READY AGENT_SELECTED_PROFILE AGENT_PROFILE_SOURCE AGENT_PROFILE_CATALOG AGENT_NAMED_PROFILE AGENT_PROFILES_LOADED
    readonly AGENT_ENGINE_PROFILES
    local name
    for name in AGENT_CODEX_USE_NATIVE_POLICY AGENT_TIMEOUT AGENT_MAX_TURNS AGENT_MAX_TURNS_EXPLICIT AGENT_BUDGET_USD AGENT_EFFORT_LEVEL \
        AGENT_CLAUDE_AUTH_REFRESH_RETRIES AGENT_CLAUDE_AUTH_REFRESH_DELAY_SECONDS \
        AGENT_MCP_CONFIG AGENT_STRICT_MCP AGENT_SESSION_PERSISTENCE AGENT_ADD_DIRS \
        AGENT_MEMORY_FILE AGENT_MEMORY_DIR AGENT_DISALLOWED_TOOLS AGENT_EXTRA_TOOLS \
        AGENT_ADVERSARIAL_PLAN_REVIEW AGENT_POST_IMPL_REVIEW AGENT_POST_IMPL_REVIEW_MAX_RETRIES \
        AGENT_TEST_COMMAND AGENT_TEST_SETUP_COMMAND AGENT_TEST_GATE_MAX_RETRIES AGENT_REVISION_TEST_GATE \
        AGENT_ALLOW_DIRECT_IMPLEMENT AGENT_CLEANUP_ENABLED; do
        readonly "$name"
    done
    for phase in $phases; do
        local engine setting
        for engine in CLAUDE CODEX; do
            for setting in MODEL EFFORT TIMEOUT BUDGET_USD PERMISSION_MODE MAX_TURNS; do
                readonly "AGENT_${setting}_${engine}" "AGENT_${setting}_${engine}_${phase}"
            done
        done
        for name in AGENT_BUDGET_USD AGENT_EFFORT AGENT_PERMISSION_MODE; do
            readonly "${name}_${phase}"
        done
    done
    while IFS= read -r name; do
        case "$name" in
            AGENT_ENGINE*|AGENT_MODEL*|AGENT_ALLOWED_TOOLS_*|AGENT_LABEL_TOOLS_*|AGENT_BUDGET_USD_*|AGENT_EFFORT_*|AGENT_PERMISSION_MODE_*|AGENT_JSON_SCHEMA_*|AGENT_TIMEOUT_*|AGENT_MAX_TURNS_*)
                readonly "$name" ;;
        esac
    done < <(compgen -A variable AGENT_)
    log "Dispatch profile: ${AGENT_SELECTED_PROFILE} (selection: ${AGENT_PROFILE_SOURCE}); named profiles own all phase routes"
    for phase in $phases; do
        log "Worker ${phase}: $(jq -r --arg phase "$phase" '
            .[$phase] | .engine + " model=" + (if .model == "" then "CLI default" else .model end)
            + " timeout=" + .settings.timeout + "s limits="
            + (if .engine == "claude" then
                "turns:" + .settings.max_turns + ", dollars:"
                + (if .settings.budget_usd == "" then "uncapped" else .settings.budget_usd end)
              else "elapsed time; Claude budget/turn/permission/tool/label-tool/MCP controls inactive; native integrations"
              end)
            + " sources=" + (.settings.sources | tojson)' <<< "$map")"
    done
}
