#!/usr/bin/env bats
# Tests for scripts/lib/defaults.sh and dispatch script configuration

load 'helpers/test_helper'

# ═══════════════════════════════════════════════════════════════
# defaults.sh loading tests
# ═══════════════════════════════════════════════════════════════

@test "defaults.sh: fails when AGENT_BOT_USER is not set" {
    unset AGENT_BOT_USER

    run bash -c "source '${LIB_DIR}/defaults.sh'"
    assert_failure
    assert_output --partial "AGENT_BOT_USER"
}

@test "defaults.sh: uses default values when not overridden" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MAX_TURNS
    unset AGENT_TIMEOUT
    unset AGENT_CIRCUIT_BREAKER_LIMIT

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_MAX_TURNS" "200"
    assert_equal "$AGENT_TIMEOUT" "3600"
    assert_equal "$AGENT_CIRCUIT_BREAKER_LIMIT" "8"
}

@test "defaults.sh: config.env values override defaults" {
    # Create a config file with overrides
    cat > "${MOCK_CONFIG_DIR}/config.env" << 'EOF'
AGENT_BOT_USER="custom-bot"
AGENT_MAX_TURNS=500
AGENT_TIMEOUT=9000
EOF

    source "${MOCK_CONFIG_DIR}/config.env"
    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_BOT_USER" "custom-bot"
    assert_equal "$AGENT_MAX_TURNS" "500"
    assert_equal "$AGENT_TIMEOUT" "9000"
}

# ─── REGRESSION: v1.0.2 — Write tool in triage toolset ──────────

@test "REGRESSION v1.0.2: triage toolset includes Write tool" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_ALLOWED_TOOLS_TRIAGE

    source "${LIB_DIR}/defaults.sh"

    # Write must be in the default triage toolset for plan output
    [[ "$AGENT_ALLOWED_TOOLS_TRIAGE" == *"Write"* ]]
}

@test "REGRESSION v1.0.2: triage toolset includes Read and Grep" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_ALLOWED_TOOLS_TRIAGE

    source "${LIB_DIR}/defaults.sh"

    [[ "$AGENT_ALLOWED_TOOLS_TRIAGE" == *"Read"* ]]
    [[ "$AGENT_ALLOWED_TOOLS_TRIAGE" == *"Grep"* ]]
}

# ═══════════════════════════════════════════════════════════════
# AGENT_TEST_SETUP_COMMAND configuration
# ═══════════════════════════════════════════════════════════════

# ─── REGRESSION: v1.0.3 — Test setup command ────────────────────

@test "REGRESSION v1.0.3: AGENT_TEST_SETUP_COMMAND defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_TEST_SETUP_COMMAND

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_TEST_SETUP_COMMAND" ""
}

@test "REGRESSION v1.0.3: AGENT_TEST_SETUP_COMMAND can be set via config" {
    export AGENT_BOT_USER="test-bot"
    export AGENT_TEST_SETUP_COMMAND="godot --headless --import --quit"

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_TEST_SETUP_COMMAND" "godot --headless --import --quit"
}

# ═══════════════════════════════════════════════════════════════
# Label-to-tool mapping configuration
# ═══════════════════════════════════════════════════════════════

@test "defaults.sh: documents label-to-tool mapping pattern" {
    # Verify the defaults file contains documentation about the pattern
    grep -q "AGENT_LABEL_TOOLS_" "${LIB_DIR}/defaults.sh"
}

# ═══════════════════════════════════════════════════════════════
# Dispatch script configuration loading
# ═══════════════════════════════════════════════════════════════

@test "dispatch script: sets CONFIG_DIR when sourcing config" {
    # Create a mock config
    cat > "${MOCK_CONFIG_DIR}/config.env" << 'EOF'
AGENT_BOT_USER="test-bot"
EOF

    export AGENT_CONFIG="${MOCK_CONFIG_DIR}/config.env"

    # Source just the config loading part
    if [ -f "$AGENT_CONFIG" ]; then
        source "$AGENT_CONFIG"
        CONFIG_DIR="$(cd "$(dirname "$AGENT_CONFIG")" && pwd)"
    fi

    assert_equal "$CONFIG_DIR" "$MOCK_CONFIG_DIR"
}

# ─── REGRESSION: v1.0.4 — start_sha uses origin/main ────────────

@test "REGRESSION v1.0.4: handle_implement uses origin/main for start_sha" {
    # Verify the dispatch script compares against origin/main, not HEAD
    grep -q 'rev-parse origin/main' "${SCRIPTS_DIR}/agent-dispatch.sh"
}

@test "REGRESSION v1.0.4: handle_implement does NOT use rev-parse HEAD for start_sha" {
    # The specific line in handle_implement should NOT use HEAD
    # (handle_pr_review still uses HEAD which is correct for that flow)
    local implement_section
    implement_section=$(sed -n '/^handle_implement/,/^handle_pr_review/p' "${SCRIPTS_DIR}/agent-dispatch.sh")

    # The start_sha line in handle_implement should reference origin/main
    echo "$implement_section" | grep 'start_sha=' | grep -q 'origin/main'
}

# ═══════════════════════════════════════════════════════════════
# Direct implement configuration
# ═══════════════════════════════════════════════════════════════

@test "defaults.sh: AGENT_ALLOW_DIRECT_IMPLEMENT defaults to true" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_ALLOW_DIRECT_IMPLEMENT

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_ALLOW_DIRECT_IMPLEMENT" "true"
}

@test "defaults.sh: AGENT_ALLOW_DIRECT_IMPLEMENT can be overridden to false" {
    export AGENT_BOT_USER="test-bot"
    export AGENT_ALLOW_DIRECT_IMPLEMENT="false"

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_ALLOW_DIRECT_IMPLEMENT" "false"
}

@test "defaults.sh: AGENT_PROMPT_VALIDATE defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_PROMPT_VALIDATE

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_PROMPT_VALIDATE" ""
}
