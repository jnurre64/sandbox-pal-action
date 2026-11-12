#!/bin/bash
# shellcheck disable=SC1091,SC2034 # Globals are consumed by dispatcher and helper.
# Library: preserve the caller's shell options; entry points enable strict mode.

# ─── Exported variables a config file overwrote (#132) ───────────
# A plain `VAR=value` in a sourced config file overwrites an exported
# value, so a per-dispatch override such as `AGENT_BUDGET_USD_IMPLEMENT=150
# sandbox-pal-dispatch.sh …` is lost without a trace. The loader does not
# change who wins; it records each loss so startup can report it. Only
# AGENT_* names are watched: credentials belong in the overrides file.
# AGENT_PROFILE is left out because its selector reads the incoming value.
# Bash 3.2 has no associative arrays, so each incoming value is kept in
# its own _AGENT_ENV_IN_<NAME> variable.
_AGENT_ENV_WATCHED=()
AGENT_ENV_OVERWRITTEN=""

_agent_env_snapshot() {
    local name
    _AGENT_ENV_WATCHED=()
    AGENT_ENV_OVERWRITTEN=""
    while IFS= read -r name; do
        case "$name" in
            AGENT_PROFILE|AGENT_PROFILE_INCOMING) ;;
            AGENT_*)
                _AGENT_ENV_WATCHED+=("$name")
                printf -v "_AGENT_ENV_IN_${name}" '%s' "${!name}"
                ;;
        esac
    done < <(compgen -e | sort)
}

# Record the watched variables that file $1 changed. Each variable is
# recorded once, against the first file that changed it.
_agent_env_note_overwrites() {
    local file="$1" name incoming
    local -a still_watched=()
    for name in ${_AGENT_ENV_WATCHED[@]+"${_AGENT_ENV_WATCHED[@]}"}; do
        incoming="_AGENT_ENV_IN_${name}"
        if [ "${!name-}" = "${!incoming}" ]; then
            still_watched+=("$name")
        else
            AGENT_ENV_OVERWRITTEN+="${AGENT_ENV_OVERWRITTEN:+, }${name} (${file##*/})"
        fi
    done
    _AGENT_ENV_WATCHED=(${still_watched[@]+"${still_watched[@]}"})
}

# Names only, never values: some AGENT_* variables hold webhook URLs.
agent_config_overwrite_report() {
    printf '%s' "$AGENT_ENV_OVERWRITTEN"
}

# Shared dispatcher/helper loading; only the new selector guarantees env priority.
agent_load_project_config() {
    CONFIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    AGENT_PROFILE_INCOMING="${AGENT_PROFILE:-}"
    _agent_env_snapshot
    # Source committed defaults first (standalone mode: .sandbox-pal-dispatch/config.defaults.env)
    AGENT_DEFAULTS="${SCRIPT_DIR}/../config.defaults.env"
    if [ -f "$AGENT_DEFAULTS" ]; then
        # shellcheck source=/dev/null
        source "$AGENT_DEFAULTS"
        _agent_env_note_overwrites "$AGENT_DEFAULTS"
        CONFIG_DIR="$(cd "$(dirname "$AGENT_DEFAULTS")" && pwd)"
        export CONFIG_DIR
    fi

    # Source optional overrides (may contain secrets — never commit this file)
    AGENT_CONFIG="${AGENT_CONFIG:-}"
    if [ -n "$AGENT_CONFIG" ] && [ -f "$AGENT_CONFIG" ]; then
        # shellcheck source=/dev/null
        source "$AGENT_CONFIG"
        _agent_env_note_overwrites "$AGENT_CONFIG"
        CONFIG_DIR="$(cd "$(dirname "$AGENT_CONFIG")" && pwd)"
        export CONFIG_DIR
    elif [ -f "${SCRIPT_DIR}/../config.env" ]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/../config.env"
        _agent_env_note_overwrites "${SCRIPT_DIR}/../config.env"
        CONFIG_DIR="$(cd "$(dirname "${SCRIPT_DIR}/../config.env")" && pwd)"
        export CONFIG_DIR
    fi

    # Preview needs no bot identity; dispatch retains the required assertion.
    if [ "${1:-}" = preview ]; then AGENT_BOT_USER="${AGENT_BOT_USER:-profile-preview}"; fi

    # Source defaults (fills in anything not set by either config file)
    # shellcheck source=lib/defaults.sh
    source "${SCRIPT_DIR}/lib/defaults.sh"

    CONFIG_DIR="${CONFIG_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    export CONFIG_DIR
}
