#!/usr/bin/env bats
# Tests for scripts/lib/config-load.sh (#132): a sourced config file that
# overwrites an exported AGENT_* variable is reported by name. The file
# still wins; the report is what makes a lost override visible.

load 'helpers/test_helper'

# A runtime tree in the temp dir: scripts/lib is the real library, and the
# config files beside scripts/ are the test's own.
_runtime() {
    RUNTIME="${TEST_TEMP_DIR}/runtime"
    mkdir -p "${RUNTIME}/scripts"
    ln -s "$LIB_DIR" "${RUNTIME}/scripts/lib"
    unset AGENT_CONFIG AGENT_PROFILE
}

# Load config in a clean strict-mode shell with the given exported
# variables, then print the overwrite report and one variable's value.
_load() {
    local show="$1"; shift
    run env "$@" bash -c "set -euo pipefail
        SCRIPT_DIR='${RUNTIME}/scripts'
        source \"\$SCRIPT_DIR/lib/config-load.sh\"
        agent_load_project_config
        echo \"report=\$(agent_config_overwrite_report)\"
        echo \"value=\${${show}:-}\""
}

@test "REGRESSION v1.3.0: a plain assignment that overwrites an exported AGENT_ variable is reported by name and file" {
    _runtime
    echo 'AGENT_BUDGET_USD_IMPLEMENT="80"' > "${RUNTIME}/config.defaults.env"

    _load AGENT_BUDGET_USD_IMPLEMENT AGENT_BUDGET_USD_IMPLEMENT=150

    assert_success
    assert_line "report=AGENT_BUDGET_USD_IMPLEMENT (config.defaults.env)"
    # Reported, not changed: the file's value is still the one in force.
    assert_line "value=80"
}

@test "config-load: a default-style assignment keeps the exported value and reports nothing" {
    _runtime
    echo 'AGENT_BUDGET_USD_IMPLEMENT="${AGENT_BUDGET_USD_IMPLEMENT:-80}"' > "${RUNTIME}/config.defaults.env"

    _load AGENT_BUDGET_USD_IMPLEMENT AGENT_BUDGET_USD_IMPLEMENT=150

    assert_success
    assert_line "report="
    assert_line "value=150"
}

@test "config-load: a plain assignment of the same value reports nothing" {
    _runtime
    echo 'AGENT_BUDGET_USD_IMPLEMENT="150"' > "${RUNTIME}/config.defaults.env"

    _load AGENT_BUDGET_USD_IMPLEMENT AGENT_BUDGET_USD_IMPLEMENT=150

    assert_line "report="
}

@test "config-load: an overwrite by the overrides file names that file, and each variable is reported once" {
    _runtime
    echo 'AGENT_MAX_TURNS="20"' > "${RUNTIME}/config.defaults.env"
    printf '%s\n' 'AGENT_MAX_TURNS="30"' 'AGENT_TIMEOUT="900"' > "${RUNTIME}/config.env"

    _load AGENT_TIMEOUT AGENT_MAX_TURNS=5 AGENT_TIMEOUT=60

    assert_line "report=AGENT_MAX_TURNS (config.defaults.env), AGENT_TIMEOUT (config.env)"
    assert_line "value=900"
}

@test "config-load: the report never contains a value" {
    _runtime
    echo 'AGENT_NOTIFY_DISCORD_WEBHOOK="https://file.example.invalid/hook"' > "${RUNTIME}/config.env"

    _load AGENT_NOTIFY_LEVEL AGENT_NOTIFY_DISCORD_WEBHOOK=https://env.example.invalid/hook

    assert_line "report=AGENT_NOTIFY_DISCORD_WEBHOOK (config.env)"
    refute_output --partial "example.invalid"
}

@test "config-load: only exported AGENT_ variables are watched" {
    _runtime
    printf '%s\n' 'GH_TOKEN="from-file"' 'AGENT_PROFILE="from-file"' > "${RUNTIME}/config.env"

    # GH_TOKEN belongs in config.env. AGENT_PROFILE has its own
    # environment-first selector, so its overwrite loses nothing.
    _load AGENT_NOTIFY_LEVEL GH_TOKEN=from-env AGENT_PROFILE=from-env

    assert_line "report="
}

@test "provenance: warns when config overwrote exported variables" {
    source "${LIB_DIR}/common.sh"
    agent_config_overwrite_report() { echo "AGENT_BUDGET_USD_IMPLEMENT (config.defaults.env)"; }

    run log_config_provenance

    assert_output --partial "WARN: config overwrote exported environment: AGENT_BUDGET_USD_IMPLEMENT (config.defaults.env)"
    assert_output --partial '${VAR:-default}'
}

@test "provenance: no overwrite warning when nothing was overwritten" {
    source "${LIB_DIR}/common.sh"
    agent_config_overwrite_report() { :; }

    run log_config_provenance

    refute_output --partial "WARN"
}
