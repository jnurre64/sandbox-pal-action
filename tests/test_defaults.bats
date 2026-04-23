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
    grep -q 'rev-parse origin/main' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "REGRESSION v1.0.4: handle_implement does NOT use rev-parse HEAD for start_sha" {
    # The specific line in handle_implement should NOT use HEAD
    # (handle_pr_review still uses HEAD which is correct for that flow)
    local implement_section
    implement_section=$(sed -n '/^handle_implement/,/^handle_pr_review/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")

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

# ─── REGRESSION: direct-implement — plan content pre-loading ────

@test "REGRESSION direct-implement: handle_implement checks AGENT_PLAN_CONTENT before extracting from comments" {
    # Verify the dispatch script checks for pre-loaded plan content
    grep -q 'AGENT_PLAN_CONTENT' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "REGRESSION direct-implement: handle_implement logs when using pre-loaded plan" {
    grep -q 'Using pre-loaded plan content' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

# ═══════════════════════════════════════════════════════════════
# handle_direct_implement handler
# ═══════════════════════════════════════════════════════════════

@test "dispatch script: has handle_direct_implement function" {
    grep -q 'handle_direct_implement()' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "dispatch script: direct_implement case in dispatch switch" {
    grep -q 'direct_implement)' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "dispatch script: handle_direct_implement checks AGENT_ALLOW_DIRECT_IMPLEMENT" {
    local handler_section
    handler_section=$(sed -n '/^handle_direct_implement/,/^handle_/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -60)

    echo "$handler_section" | grep -q 'AGENT_ALLOW_DIRECT_IMPLEMENT'
}

@test "dispatch script: handle_direct_implement sets agent:validating label" {
    local handler_section
    handler_section=$(sed -n '/^handle_direct_implement/,/^handle_/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -60)

    echo "$handler_section" | grep -q 'agent:validating'
}

@test "dispatch script: handle_direct_implement uses validate prompt" {
    local handler_section
    handler_section=$(sed -n '/^handle_direct_implement/,/^handle_/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -80)

    echo "$handler_section" | grep -q 'AGENT_PROMPT_VALIDATE'
}

@test "dispatch script: handle_direct_implement posts comment with direct-implement marker on failure" {
    local handler_section
    handler_section=$(sed -n '/^handle_direct_implement/,/^handle_/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -80)

    echo "$handler_section" | grep -q 'agent-direct-implement'
}

@test "dispatch script: handle_direct_implement calls handle_implement on success" {
    local handler_section
    handler_section=$(sed -n '/^handle_direct_implement/,/^handle_/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -80)

    echo "$handler_section" | grep -q 'handle_implement'
}

# ─── REGRESSION: direct-implement — reply re-entry ──────────────

@test "REGRESSION direct-implement: handle_issue_reply checks for direct-implement marker" {
    local reply_section
    reply_section=$(sed -n '/^handle_issue_reply/,/^handle_implement/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")

    echo "$reply_section" | grep -q 'agent-direct-implement'
}

@test "REGRESSION direct-implement: handle_issue_reply calls handle_direct_implement when marker found" {
    local reply_section
    reply_section=$(sed -n '/^handle_issue_reply/,/^handle_implement/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")

    echo "$reply_section" | grep -q 'handle_direct_implement'
}

# ═══════════════════════════════════════════════════════════════
# Adversarial review gate configuration
# ═══════════════════════════════════════════════════════════════

@test "defaults.sh: AGENT_ADVERSARIAL_PLAN_REVIEW defaults to true" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_ADVERSARIAL_PLAN_REVIEW

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_ADVERSARIAL_PLAN_REVIEW" "true"
}

@test "defaults.sh: AGENT_POST_IMPL_REVIEW defaults to true" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_POST_IMPL_REVIEW

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_POST_IMPL_REVIEW" "true"
}

@test "defaults.sh: AGENT_POST_IMPL_REVIEW_MAX_RETRIES defaults to 1" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_POST_IMPL_REVIEW_MAX_RETRIES

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_POST_IMPL_REVIEW_MAX_RETRIES" "1"
}

@test "defaults.sh: AGENT_MODEL defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_MODEL" ""
}

@test "defaults.sh: AGENT_MODEL_TRIAGE defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL_TRIAGE

    source "${LIB_DIR}/defaults.sh"

    [ "${AGENT_MODEL_TRIAGE+set}" = "set" ] || { echo "AGENT_MODEL_TRIAGE not set by defaults.sh"; return 1; }
    assert_equal "$AGENT_MODEL_TRIAGE" ""
}

@test "defaults.sh: AGENT_MODEL_IMPLEMENT defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL_IMPLEMENT

    source "${LIB_DIR}/defaults.sh"

    [ "${AGENT_MODEL_IMPLEMENT+set}" = "set" ] || { echo "AGENT_MODEL_IMPLEMENT not set by defaults.sh"; return 1; }
    assert_equal "$AGENT_MODEL_IMPLEMENT" ""
}

@test "defaults.sh: AGENT_MODEL_REVIEW defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL_REVIEW

    source "${LIB_DIR}/defaults.sh"

    [ "${AGENT_MODEL_REVIEW+set}" = "set" ] || { echo "AGENT_MODEL_REVIEW not set by defaults.sh"; return 1; }
    assert_equal "$AGENT_MODEL_REVIEW" ""
}

@test "defaults.sh: AGENT_MODEL_ADVERSARIAL_PLAN defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL_ADVERSARIAL_PLAN

    source "${LIB_DIR}/defaults.sh"

    [ "${AGENT_MODEL_ADVERSARIAL_PLAN+set}" = "set" ] || { echo "AGENT_MODEL_ADVERSARIAL_PLAN not set by defaults.sh"; return 1; }
    assert_equal "$AGENT_MODEL_ADVERSARIAL_PLAN" ""
}

@test "defaults.sh: AGENT_MODEL_POST_IMPL_REVIEW defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL_POST_IMPL_REVIEW

    source "${LIB_DIR}/defaults.sh"

    [ "${AGENT_MODEL_POST_IMPL_REVIEW+set}" = "set" ] || { echo "AGENT_MODEL_POST_IMPL_REVIEW not set by defaults.sh"; return 1; }
    assert_equal "$AGENT_MODEL_POST_IMPL_REVIEW" ""
}

@test "defaults.sh: AGENT_MODEL_POST_IMPL_RETRY defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL_POST_IMPL_RETRY

    source "${LIB_DIR}/defaults.sh"

    [ "${AGENT_MODEL_POST_IMPL_RETRY+set}" = "set" ] || { echo "AGENT_MODEL_POST_IMPL_RETRY not set by defaults.sh"; return 1; }
    assert_equal "$AGENT_MODEL_POST_IMPL_RETRY" ""
}

@test "defaults.sh: AGENT_PROMPT_ADVERSARIAL_PLAN defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_PROMPT_ADVERSARIAL_PLAN

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_PROMPT_ADVERSARIAL_PLAN" ""
}

@test "defaults.sh: AGENT_PROMPT_POST_IMPL_REVIEW defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_PROMPT_POST_IMPL_REVIEW

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_PROMPT_POST_IMPL_REVIEW" ""
}

@test "defaults.sh: AGENT_PROMPT_POST_IMPL_RETRY defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_PROMPT_POST_IMPL_RETRY

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_PROMPT_POST_IMPL_RETRY" ""
}

# ═══════════════════════════════════════════════════════════════
# Review gates integration
# ═══════════════════════════════════════════════════════════════

@test "dispatch script: sources review-gates.sh" {
    grep -q 'review-gates.sh' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "dispatch script: handle_implement calls run_adversarial_plan_review" {
    local implement_section
    implement_section=$(sed -n '/^handle_implement/,/^handle_direct_implement/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")

    echo "$implement_section" | grep -q 'run_adversarial_plan_review'
}

@test "dispatch script: run_adversarial_plan_review runs BEFORE implementation claude session" {
    local implement_section
    implement_section=$(sed -n '/^handle_implement/,/^handle_direct_implement/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")

    local review_line impl_line
    review_line=$(echo "$implement_section" | grep -n 'run_adversarial_plan_review' | head -1 | cut -d: -f1)
    impl_line=$(echo "$implement_section" | grep -n 'run_claude.*prompt.*impl_tools' | head -1 | cut -d: -f1)

    [ "$review_line" -lt "$impl_line" ]
}

@test "common.sh: handle_post_implementation calls run_post_impl_review" {
    grep -q 'run_post_impl_review' "${LIB_DIR}/common.sh"
}

@test "common.sh: run_post_impl_review runs AFTER tests pass and BEFORE push" {
    local tests_line review_line push_line
    tests_line=$(grep -n 'tests_passed' "${LIB_DIR}/common.sh" | head -1 | cut -d: -f1)
    review_line=$(grep -n 'run_post_impl_review' "${LIB_DIR}/common.sh" | head -1 | cut -d: -f1)
    push_line=$(grep -n 'git.*push.*origin' "${LIB_DIR}/common.sh" | head -1 | cut -d: -f1)

    [ "$tests_line" -lt "$review_line" ]
    [ "$review_line" -lt "$push_line" ]
}

@test "common.sh: PR body includes review annotation when REVIEW_RETRY_CONCERNS is set" {
    grep -q 'REVIEW_RETRY_CONCERNS' "${LIB_DIR}/common.sh"
    grep -q 'Post-Implementation Review' "${LIB_DIR}/common.sh"
}
