#!/usr/bin/env bats
# Tests for scripts/lib/common.sh

load 'helpers/test_helper'

# Helper to source common.sh with all required vars set
_source_common() {
    source "${LIB_DIR}/common.sh"
}

# ═══════════════════════════════════════════════════════════════
# load_prompt tests
# ═══════════════════════════════════════════════════════════════

@test "load_prompt: loads custom prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/my-prompt.md"
    echo "Custom triage prompt" > "$prompt_file"

    run load_prompt "triage" "$prompt_file"
    assert_success
    assert_output "Custom triage prompt"
}

@test "load_prompt: falls back to default prompt when custom path is empty" {
    _source_common
    run load_prompt "triage" ""
    assert_success
    [ -n "$output" ]
}

@test "load_prompt: falls back to default prompt when custom file doesn't exist" {
    _source_common
    run load_prompt "triage" "/nonexistent/path.md"
    assert_success
    [ -n "$output" ]
}

# ─── REGRESSION: v1.0.1 — Prompt path resolution ────────────────

@test "REGRESSION v1.0.1: load_prompt resolves relative paths against CONFIG_DIR" {
    mkdir -p "${MOCK_CONFIG_DIR}/prompts"
    echo "Config-relative prompt" > "${MOCK_CONFIG_DIR}/prompts/triage.md"
    export CONFIG_DIR="$MOCK_CONFIG_DIR"

    _source_common
    run load_prompt "triage" "prompts/triage.md"
    assert_success
    assert_output "Config-relative prompt"
}

@test "REGRESSION v1.0.1: load_prompt works with absolute paths regardless of CONFIG_DIR" {
    local prompt_file="${TEST_TEMP_DIR}/absolute-prompt.md"
    echo "Absolute path prompt" > "$prompt_file"
    export CONFIG_DIR="/some/other/dir"

    _source_common
    run load_prompt "triage" "$prompt_file"
    assert_success
    assert_output "Absolute path prompt"
}

@test "REGRESSION v1.0.1: load_prompt falls back when CONFIG_DIR is empty and relative path given" {
    export CONFIG_DIR=""
    _source_common

    # Relative path can't resolve without CONFIG_DIR, should fall back to default
    run load_prompt "triage" "prompts/triage.md"
    assert_success
    [ -n "$output" ]
}

# ═══════════════════════════════════════════════════════════════
# get_implementation_tools tests
# ═══════════════════════════════════════════════════════════════

@test "get_implementation_tools: returns base tools when no extras" {
    export AGENT_EXTRA_TOOLS=""
    LABEL_EXTRA_TOOLS=""
    _source_common

    run get_implementation_tools
    assert_output "$AGENT_ALLOWED_TOOLS_IMPLEMENT"
}

@test "get_implementation_tools: appends AGENT_EXTRA_TOOLS" {
    export AGENT_EXTRA_TOOLS="Bash(npm:*)"
    LABEL_EXTRA_TOOLS=""
    _source_common

    run get_implementation_tools
    assert_output --partial "Bash(npm:*)"
}

@test "get_implementation_tools: appends LABEL_EXTRA_TOOLS" {
    export AGENT_EXTRA_TOOLS=""
    _source_common
    LABEL_EXTRA_TOOLS="Bash(curl:*),Bash(python3:*)"

    run get_implementation_tools
    assert_output --partial "Bash(curl:*)"
    assert_output --partial "Bash(python3:*)"
}

# ═══════════════════════════════════════════════════════════════
# detect_label_tools tests
# ═══════════════════════════════════════════════════════════════

@test "detect_label_tools: sets LABEL_EXTRA_TOOLS when matching label found" {
    create_mock "gh" "agent:image-gen"
    export AGENT_LABEL_TOOLS_agent_image_gen="Bash(curl:*),Bash(python3:*)"
    _source_common

    detect_label_tools
    assert_equal "$LABEL_EXTRA_TOOLS" "Bash(curl:*),Bash(python3:*)"
}

@test "detect_label_tools: LABEL_EXTRA_TOOLS empty when no matching labels" {
    create_mock "gh" "agent:triage"
    _source_common

    detect_label_tools
    assert_equal "$LABEL_EXTRA_TOOLS" ""
}

# ═══════════════════════════════════════════════════════════════
# parse_claude_output tests
# ═══════════════════════════════════════════════════════════════

@test "parse_claude_output: extracts result from json" {
    _source_common
    run parse_claude_output '{"result":"Hello from Claude","session_id":"abc"}'
    assert_output "Hello from Claude"
}

@test "parse_claude_output: extracts result_text on error" {
    _source_common
    run parse_claude_output '{"result_text":"Max turns reached","subtype":"error_max_turns"}'
    assert_output "Max turns reached"
}

@test "parse_claude_output: returns subtype when no result fields" {
    _source_common
    run parse_claude_output '{"subtype":"error_max_turns"}'
    assert_output "Agent stopped: error_max_turns"
}

@test "parse_claude_output: returns raw input when not json" {
    _source_common
    run parse_claude_output "plain text output"
    assert_output "plain text output"
}

# ═══════════════════════════════════════════════════════════════
# PR body regression test
# ═══════════════════════════════════════════════════════════════

# ─── REGRESSION: v1.0.5 — Duplicate Summary heading ─────────────

@test "REGRESSION v1.0.5: PR body template does not contain ### Summary heading" {
    # The PR body in handle_post_implementation should NOT have ### Summary
    run grep '### Summary' "${LIB_DIR}/common.sh"
    assert_failure  # grep should NOT find it
}

# ═══════════════════════════════════════════════════════════════
# Test gate regression tests
# ═══════════════════════════════════════════════════════════════

# ─── REGRESSION: v1.0.3 — AGENT_TEST_SETUP_COMMAND ──────────────

@test "REGRESSION v1.0.3: test setup command present in handle_post_implementation" {
    grep -q 'AGENT_TEST_SETUP_COMMAND' "${LIB_DIR}/common.sh"
}

@test "REGRESSION v1.0.3: test setup runs before test command in source" {
    local setup_line test_line
    setup_line=$(grep -n 'AGENT_TEST_SETUP_COMMAND' "${LIB_DIR}/common.sh" | grep -v "^#" | head -1 | cut -d: -f1)
    test_line=$(grep -n 'eval.*AGENT_TEST_COMMAND' "${LIB_DIR}/common.sh" | head -1 | cut -d: -f1)
    [ "$setup_line" -lt "$test_line" ]
}

# ─── REGRESSION: ERR trap double-report on controlled failures ──
# handle_post_implementation returns non-zero on controlled failures
# (test gate fail, Gate B halt, no commits made). Under `set -e` the
# unguarded call at the end of handle_implement would propagate that
# return to _on_unexpected_error via the ERR trap, which would
# double-post an "Agent Infrastructure Error" comment after the
# clean failure comment handle_post_implementation already posted.
# Observed on Webber #59 run 24280942202.
@test "REGRESSION: handle_post_implementation call in handle_implement is guarded" {
    # The call at the end of handle_implement must be wrapped in
    # `if ! handle_post_implementation ...; then ...; fi` (or equivalent
    # set-e suppression) so controlled return 1 values don't fire the
    # ERR trap.
    grep -q 'if ! handle_post_implementation' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}

@test "REGRESSION: cleanup_worktree runs after guarded handle_post_implementation" {
    # Even on controlled failure, cleanup must still happen so the
    # worktree doesn't leak on the runner. The guard should use an
    # if/fi block that falls through to cleanup_worktree, not a bare
    # `|| return` that would skip cleanup.
    local guard_line cleanup_line
    guard_line=$(grep -n 'if ! handle_post_implementation' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -1 | cut -d: -f1)
    cleanup_line=$(awk "NR > ${guard_line} && /cleanup_worktree/ {print NR; exit}" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
    [ -n "$cleanup_line" ]
    [ "$cleanup_line" -gt "$guard_line" ]
}

# ═══════════════════════════════════════════════════════════════
# log function tests
# ═══════════════════════════════════════════════════════════════

@test "log: writes timestamped message to log file" {
    _source_common
    log "Test message"

    assert [ -f "$AGENT_LOG_DIR/sandbox-pal-dispatch.log" ]
    grep -q "Test message" "$AGENT_LOG_DIR/sandbox-pal-dispatch.log"
}

@test "log: includes event type and issue number" {
    _source_common
    log "Test message"

    grep -q "\[test\] #99" "$AGENT_LOG_DIR/sandbox-pal-dispatch.log"
}

# ═══════════════════════════════════════════════════════════════
# Label management tests
# ═══════════════════════════════════════════════════════════════

@test "set_label: calls gh to add label" {
    create_mock "gh" ""
    _source_common

    set_label "agent:triage"

    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"add-label"* ]]
    [[ "$calls" == *"agent:triage"* ]]
}

# ═══════════════════════════════════════════════════════════════
# Circuit breaker tests
# ═══════════════════════════════════════════════════════════════

@test "check_circuit_breaker: passes when below limit" {
    create_mock "gh" "3"
    _source_common

    run check_circuit_breaker
    assert_success
}

# ═══════════════════════════════════════════════════════════════
# Shared memory tests
# ═══════════════════════════════════════════════════════════════

@test "load_shared_memory: returns empty when no memory file" {
    export AGENT_MEMORY_FILE=""
    _source_common

    run load_shared_memory
    assert_output ""
}

@test "load_shared_memory: loads memory file content" {
    local mem_file="${TEST_TEMP_DIR}/memory.md"
    echo "# Project Memory" > "$mem_file"
    export AGENT_MEMORY_FILE="$mem_file"
    _source_common

    run load_shared_memory
    assert_output --partial "Project Memory"
    assert_output --partial "Shared Project Memory"
}

@test "load_shared_memory: resolves workspace-relative path against WORKTREE_DIR" {
    local worktree="${TEST_TEMP_DIR}/worktree"
    mkdir -p "$worktree/claude-work"
    echo "# Committed Memory" > "$worktree/claude-work/shared-memory.md"
    export AGENT_MEMORY_FILE="claude-work/shared-memory.md"
    export WORKTREE_DIR="$worktree"
    _source_common

    run load_shared_memory
    assert_output --partial "Committed Memory"
    assert_output --partial "Shared Project Memory"
}

@test "load_shared_memory: relative path not in worktree returns empty" {
    export AGENT_MEMORY_FILE="claude-work/nonexistent.md"
    export WORKTREE_DIR="${TEST_TEMP_DIR}/empty-worktree"
    mkdir -p "$WORKTREE_DIR"
    _source_common

    run load_shared_memory
    assert_output ""
}

# ═══════════════════════════════════════════════════════════════
# validate prompt tests
# ═══════════════════════════════════════════════════════════════

@test "load_prompt: loads default validate prompt" {
    _source_common
    run load_prompt "validate" ""
    assert_success
    assert_output --partial "validating"
}

@test "load_prompt: loads custom validate prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/custom-validate.md"
    echo "Custom validate prompt" > "$prompt_file"

    run load_prompt "validate" "$prompt_file"
    assert_success
    assert_output "Custom validate prompt"
}

# ═══════════════════════════════════════════════════════════════
# run_claude model configuration tests
# ═══════════════════════════════════════════════════════════════

@test "run_claude: passes --model flag when AGENT_MODEL is set" {
    create_mock "claude" '{"result":"ok"}'
    create_mock "timeout" '{"result":"ok"}'
    export AGENT_MODEL="claude-opus-4-6"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    # Create a wrapper that captures claude args
    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
# Skip the timeout arg, capture the rest
shift  # timeout value
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"--model"* ]]
    [[ "$calls" == *"claude-opus-4-6"* ]]
}

@test "run_claude: omits --model flag when AGENT_MODEL is empty" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL=""
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" != *"--model"* ]]
}

@test "run_claude: per-workflow override passes as --model" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL=""
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" "claude-haiku-4-5"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"--model"* ]]
    [[ "$calls" == *"claude-haiku-4-5"* ]]
}

@test "run_claude: per-workflow override wins over AGENT_MODEL" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL="claude-opus-4-6"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" "claude-haiku-4-5"
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"claude-haiku-4-5"* ]]
    [[ "$calls" != *"claude-opus-4-6"* ]]
}

@test "run_claude: falls back to AGENT_MODEL when override arg is empty" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL="claude-opus-4-6"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" ""
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" == *"--model"* ]]
    [[ "$calls" == *"claude-opus-4-6"* ]]
}

# Guards against accidental regression to a pinned default. With no model vars
# set, --model must not appear so the CLI picks its current latest model.
@test "run_claude: default-default omits --model entirely (lets CLI pick latest)" {
    create_mock "claude" '{"result":"ok"}'
    export AGENT_MODEL=""
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_common

    local mock_bin="${TEST_TEMP_DIR}/bin"
    cat > "${mock_bin}/timeout" << 'MOCK'
#!/bin/bash
shift
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_timeout"
echo '{"result":"ok"}'
MOCK
    chmod +x "${mock_bin}/timeout"

    run run_claude "test prompt" "Read,Write" ""
    local calls
    calls=$(cat "${TEST_TEMP_DIR}/mock_calls_timeout" 2>/dev/null || echo "")
    [[ "$calls" != *"--model"* ]]
}

@test "defaults.sh: AGENT_MODEL and all per-workflow overrides default to empty (CLI picks latest)" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_MODEL AGENT_MODEL_TRIAGE AGENT_MODEL_IMPLEMENT AGENT_MODEL_REVIEW \
          AGENT_MODEL_ADVERSARIAL_PLAN AGENT_MODEL_POST_IMPL_REVIEW AGENT_MODEL_POST_IMPL_RETRY

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_MODEL" ""
    assert_equal "$AGENT_MODEL_TRIAGE" ""
    assert_equal "$AGENT_MODEL_IMPLEMENT" ""
    assert_equal "$AGENT_MODEL_REVIEW" ""
    assert_equal "$AGENT_MODEL_ADVERSARIAL_PLAN" ""
    assert_equal "$AGENT_MODEL_POST_IMPL_REVIEW" ""
    assert_equal "$AGENT_MODEL_POST_IMPL_RETRY" ""
}

# ═══════════════════════════════════════════════════════════════
# Adversarial review prompt tests
# ═══════════════════════════════════════════════════════════════

@test "load_prompt: loads default adversarial-plan prompt" {
    _source_common
    run load_prompt "adversarial-plan" ""
    assert_success
    assert_output --partial "adversarial"
}

@test "load_prompt: loads custom adversarial-plan prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/custom-adversarial.md"
    echo "Custom adversarial prompt" > "$prompt_file"

    run load_prompt "adversarial-plan" "$prompt_file"
    assert_success
    assert_output "Custom adversarial prompt"
}

@test "load_prompt: loads default post-impl-review prompt" {
    _source_common
    run load_prompt "post-impl-review" ""
    assert_success
    assert_output --partial "post-implementation"
}

@test "load_prompt: loads custom post-impl-review prompt from absolute path" {
    _source_common
    local prompt_file="${TEST_TEMP_DIR}/custom-post-impl.md"
    echo "Custom post-impl review prompt" > "$prompt_file"

    run load_prompt "post-impl-review" "$prompt_file"
    assert_success
    assert_output "Custom post-impl review prompt"
}

@test "load_prompt: loads default post-impl-retry prompt" {
    _source_common
    run load_prompt "post-impl-retry" ""
    assert_success
    assert_output --partial "review concerns"
}
