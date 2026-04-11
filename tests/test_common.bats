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

# ═══════════════════════════════════════════════════════════════
# log function tests
# ═══════════════════════════════════════════════════════════════

@test "log: writes timestamped message to log file" {
    _source_common
    log "Test message"

    assert [ -f "$AGENT_LOG_DIR/agent-dispatch.log" ]
    grep -q "Test message" "$AGENT_LOG_DIR/agent-dispatch.log"
}

@test "log: includes event type and issue number" {
    _source_common
    log "Test message"

    grep -q "\[test\] #99" "$AGENT_LOG_DIR/agent-dispatch.log"
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
