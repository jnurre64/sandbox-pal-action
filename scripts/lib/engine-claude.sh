#!/bin/bash
# shellcheck disable=SC2030,SC2031  # Effort is intentionally local to each invocation.
# ─── Run Claude and capture structured output ────────────────────
engine_claude() (
    set -euo pipefail
    local prompt="$1"
    local allowed_tools="${2:-$AGENT_ALLOWED_TOOLS_IMPLEMENT}"
    local model_override="${3:-}"
    local schema_file="${4:-}"
    local phase="${5:-}"
    local policy="${6:-}" memory
    if [ -z "$policy" ]; then
        local settings
        settings=$(agent_phase_settings claude "$phase") || return 1
        policy=$(engine_claude_policy "$phase" "$settings") || return 1
    fi
    local budget effort permission_mode turns invocation_timeout effort_env
    local permission_prompts bg_wait_ceiling_ms setting_sources settings_base settings_file
    setting_sources=$(jq -r .setting_sources <<< "$policy")
    settings_base=$(jq -r .settings_file <<< "$policy")
    permission_prompts=$(jq -r .permission_prompts <<< "$policy")
    bg_wait_ceiling_ms=$(jq -r .bg_wait_ceiling_ms <<< "$policy")
    budget=$(jq -r .budget_usd <<< "$policy")
    effort=$(jq -r .effort <<< "$policy")
    permission_mode=$(jq -r .permission_mode <<< "$policy")
    turns=$(jq -r .max_turns <<< "$policy")
    invocation_timeout=$(jq -r .timeout <<< "$policy")
    effort_env=$(jq -r .effort_env <<< "$policy")
    if [ "$(jq -r .set_effort_env <<< "$policy")" = true ]; then
        export CLAUDE_CODE_EFFORT_LEVEL="$effort_env"
    else
        unset CLAUDE_CODE_EFFORT_LEVEL
    fi
    # `-p` waits for background work before it returns. Bound that wait
    # so a stuck background task ends the phase with a result, not with
    # the outer `timeout` killing the CLI and losing the envelope (#136).
    if [ -n "$bg_wait_ceiling_ms" ]; then
        export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$bg_wait_ceiling_ms"
    fi
    memory=$(load_shared_memory)

    # The phase's permission rules travel in a settings file the pipeline
    # writes for this one run, so they do not depend on what the operator's
    # own settings happen to allow (#135). It is removed when this subshell
    # exits, however the phase ended.
    settings_file=$(mktemp "${AGENT_LOG_DIR}/claude-settings-${phase:-phase}-XXXXXX.json") || return 1
    # shellcheck disable=SC2064  # Expand the path now: it is local to this call.
    trap "rm -f '${settings_file}'" EXIT
    engine_claude_settings "$settings_base" "$allowed_tools" "${AGENT_DISALLOWED_TOOLS:-}" > "$settings_file" || return 1

    cd "$WORKTREE_DIR" || return 1
    local claude_args=(
        -p "$prompt"
        --settings "$settings_file"
        --max-turns "$turns"
        --output-format json
    )
    # Which settings layers the phase reads besides that file. Naming all
    # three is the CLI's own default; `project` leaves out the operator's
    # user settings (their rules, hooks, plugins and user-level skills).
    [ -z "$setting_sources" ] || claude_args+=(--setting-sources "$setting_sources")
    local effective_model="$model_override"
    if [ -n "$effective_model" ]; then
        claude_args+=(--model "$effective_model")
    fi
    # Path gating is separate from tool rules: a command matching an
    # allow rule is still denied when it touches a path outside the
    # working directory. Sibling repos, scratch areas and package
    # caches need --add-dir (#93).
    if [ -n "${AGENT_ADD_DIRS:-}" ]; then
        local add_dir
        for add_dir in $AGENT_ADD_DIRS; do
            claude_args+=(--add-dir "$add_dir")
        done
    fi
    # The memory directory is usually out-of-tree; without --add-dir the
    # Read of a pointed-at memory file would be path-gated (#97).
    local memory_dir
    memory_dir=$(_resolve_memory_dir)
    if [ -n "$memory_dir" ]; then
        claude_args+=(--add-dir "$memory_dir")
    fi
    [ -z "$budget" ] || claude_args+=(--max-budget-usd "$budget")
    [ -z "$effort" ] || claude_args+=(--effort "$effort")
    [ -z "$permission_mode" ] || claude_args+=(--permission-mode "$permission_mode")
    # Nobody can answer a prompt in a headless phase. Saying so makes a
    # denial final and reported, where the model would otherwise spend
    # turns retrying variants (#136).
    if [ -n "$permission_prompts" ] && engine_claude_has_flag --permission-prompts; then
        claude_args+=(--permission-prompts "$permission_prompts")
    fi
    # Gate the MCP tool surface explicitly: without --strict-mcp-config a
    # phase silently inherits the operator's personal MCP servers —
    # "inherit identity, memory and skills; gate the tool surface."
    if [ -n "${AGENT_MCP_CONFIG:-}" ]; then
        claude_args+=(--mcp-config "$AGENT_MCP_CONFIG" --strict-mcp-config)
    elif [ "${AGENT_STRICT_MCP:-}" = "true" ]; then
        claude_args+=(--strict-mcp-config)
    fi
    # Headless phases should not accumulate resumable sessions
    if [ "${AGENT_SESSION_PERSISTENCE:-false}" != "true" ]; then
        claude_args+=(--no-session-persistence)
    fi
    if [ -n "$memory" ]; then
        claude_args+=(--append-system-prompt "$memory")
    fi
    # run_agent has resolved and checked this schema before invocation.
    if [ -n "$schema_file" ]; then
        claude_args+=(--json-schema "$schema_file")
    fi
    # Last step before launch: the phase gets no dispatcher credentials (#142).
    agent_scrub_phase_env || return 1
    timeout "$invocation_timeout" claude "${claude_args[@]}"
)

# Print one permission rule per line from a tool list as the AGENT_*_TOOLS
# settings write it: separated by commas or spaces. A separator inside
# parentheses belongs to the rule, e.g. Bash(git add:*) or Bash(curl *a,b*).
agent_split_tool_rules() {
    local list="$1" rule="" char depth=0 i
    for ((i = 0; i < ${#list}; i++)); do
        char="${list:i:1}"
        case "$char" in
            '(') depth=$((depth + 1)) ;;
            ')') [ "$depth" -eq 0 ] || depth=$((depth - 1)) ;;
            ','|' '|$'\t'|$'\n')
                if [ "$depth" -eq 0 ]; then
                    [ -z "$rule" ] || printf '%s\n' "$rule"
                    rule=""
                    continue
                fi ;;
        esac
        rule+="$char"
    done
    [ -z "$rule" ] || printf '%s\n' "$rule"
}

# Print the settings JSON for one phase: the repo's own base file ($1, may
# be empty) with the phase's allowed ($2) and disallowed ($3) tools added
# to its permission rules.
engine_claude_settings() {
    local base_file="$1" allow deny base='{}'
    allow=$(agent_split_tool_rules "$2" | jq -Rn '[inputs | select(length > 0)]') || return 1
    deny=$(agent_split_tool_rules "$3" | jq -Rn '[inputs | select(length > 0)]') || return 1
    if [ -n "$base_file" ]; then
        base=$(jq -c 'if type == "object" then . else error("not an object") end' "$base_file" 2>/dev/null) || {
            echo 'AGENT_SETTINGS_FILE must be a JSON object' >&2; return 1
        }
    fi
    jq --argjson allow "$allow" --argjson deny "$deny" '
        .permissions = ((.permissions // {})
            | .allow = ((.allow // []) + $allow)
            | .deny = ((.deny // []) + $deny))' <<< "$base"
}

# Whether the installed CLI lists flag $1 in its help, so a newer flag is
# not passed to a CLI that would reject it. The help is captured whole,
# never piped into `grep -q` (pipefail and SIGPIPE, #129).
engine_claude_has_flag() {
    local help
    help=$(timeout 15 claude --help 2>/dev/null || true)
    [[ "$help" =~ (^|[[:space:],])"$1"([[:space:],=]|$) ]]
}

# Authentication status is a local check: never print identity/credential data.
# Invocations still classify revoked credentials and quota failures separately.
engine_claude_preflight() {
    command -v claude >/dev/null 2>&1 || { echo 'Claude CLI is missing' >&2; return 1; }
    command -v timeout >/dev/null 2>&1 || { echo 'timeout is missing' >&2; return 1; }
    if ! timeout 15 claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
        echo 'Claude authentication is unavailable; configure API credentials or a saved Claude login' >&2
        return 1
    fi
}

engine_claude_policy() {
    local phase="$1" settings="$2" value effort_env set_effort_env=false
    value=$(jq -r .timeout <<< "$settings")
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" =~ ^0+$ ]]; then
        echo "${phase}: timeout must be a positive integer number of seconds" >&2; return 1
    fi
    value=$(jq -r .max_turns <<< "$settings")
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" =~ ^0+$ ]]; then
        echo "${phase}: max turns must be a positive integer" >&2; return 1
    fi
    value=$(jq -r .budget_usd <<< "$settings")
    if [ -n "$value" ] && { [[ ! "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$value" =~ ^0+([.]0+)?$ ]]; }; then
        echo "${phase}: budget must be a positive dollar amount" >&2; return 1
    fi
    value=$(jq -r .effort <<< "$settings")
    effort_env="${CLAUDE_CODE_EFFORT_LEVEL-${AGENT_EFFORT_LEVEL:-high}}"
    if [ "${CLAUDE_CODE_EFFORT_LEVEL+x}" ]; then set_effort_env=true; fi
    if [ "${AGENT_ENGINE_PROFILES:-false}" = true ]; then
        effort_env="$value" set_effort_env=true
    fi
    case "${value:-${effort_env:-${AGENT_EFFORT_LEVEL:-high}}}" in low|medium|high|xhigh|max) ;; *) echo "${phase}: unsupported Claude effort" >&2; return 1 ;; esac
    value=$(jq -r .permission_mode <<< "$settings")
    case "$value" in ''|default|acceptEdits|auto|bypassPermissions|manual|dontAsk|plan) ;; *) echo "${phase}: unsupported Claude permission mode" >&2; return 1 ;; esac
    local permission_prompts="${AGENT_PERMISSION_PROMPTS-none}" bg_wait_var bg_wait_ceiling_ms
    case "$permission_prompts" in ''|none|host) ;; *) echo "${phase}: unsupported permission prompt target (use none, host or empty)" >&2; return 1 ;; esac
    bg_wait_var="AGENT_BG_WAIT_CEILING_MS_${phase}"
    bg_wait_ceiling_ms="${!bg_wait_var-${AGENT_BG_WAIT_CEILING_MS-600000}}"
    if [[ ! "$bg_wait_ceiling_ms" =~ ^[0-9]*$ ]]; then
        echo "${phase}: background-wait ceiling must be a whole number of milliseconds" >&2; return 1
    fi
    # Settings layers and the repo's base settings file (#135). Checked here
    # so a mistake stops the dispatch before any phase is launched.
    local setting_sources="${AGENT_SETTING_SOURCES-user,project,local}" setting_source
    local settings_file="${AGENT_SETTINGS_FILE:-}"
    for setting_source in ${setting_sources//,/ }; do
        case "$setting_source" in user|project|local) ;; *)
            echo "${phase}: AGENT_SETTING_SOURCES takes user, project and local, separated by commas" >&2; return 1 ;;
        esac
    done
    if [[ "$setting_sources" =~ [[:space:]] ]] || [[ "$setting_sources" =~ (^,|,,|,$) ]]; then
        echo "${phase}: AGENT_SETTING_SOURCES takes user, project and local, separated by commas" >&2; return 1
    fi
    if [ -n "$settings_file" ]; then
        if [[ "$settings_file" != /* ]] && [ -n "${CONFIG_DIR:-}" ]; then
            settings_file="${CONFIG_DIR}/${settings_file}"
        fi
        if ! engine_claude_settings "$settings_file" "" "" >/dev/null 2>&1; then
            echo "${phase}: AGENT_SETTINGS_FILE must name a readable file holding a JSON object" >&2; return 1
        fi
    fi
    jq -c --arg effort_env "$effort_env" --argjson set_effort_env "$set_effort_env" \
        --arg permission_prompts "$permission_prompts" --arg bg_wait_ceiling_ms "$bg_wait_ceiling_ms" \
        --arg setting_sources "$setting_sources" --arg settings_file "$settings_file" \
        '. + {effort_env:$effort_env,set_effort_env:$set_effort_env,
              permission_prompts:$permission_prompts,bg_wait_ceiling_ms:$bg_wait_ceiling_ms,
              setting_sources:$setting_sources,settings_file:$settings_file}' <<< "$settings"
}

engine_claude_check_policy() {
    local settings
    settings=$(agent_phase_settings claude "$1") || return 1
    engine_claude_policy "$1" "$settings" >/dev/null
}
