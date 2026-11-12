#!/usr/bin/env bats
# Tests for per-phase invocation flags (#98): budget, effort,
# permission-mode, strict MCP config, session persistence.
# Every flag is optional and defaults to current behaviour — budget in
# particular is limitless unless explicitly set.

load 'helpers/test_helper'

_setup_mock_claude() {
    source "${LIB_DIR}/common.sh"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TEMP_DIR:-/tmp}/claude_args"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
}

@test "budget: AGENT_BUDGET_USD_<PHASE> passes --max-budget-usd for that phase" {
    _setup_mock_claude
    export AGENT_BUDGET_USD_TRIAGE="8"
    run run_claude "prompt" "" "" "" "TRIAGE"
    grep -q -- "--max-budget-usd" "${TEST_TEMP_DIR}/claude_args"
    grep -qx "8" "${TEST_TEMP_DIR}/claude_args"
}

@test "budget: limitless by default — no --max-budget-usd when unset" {
    _setup_mock_claude
    run run_claude "prompt" "" "" "" "TRIAGE"
    ! grep -q -- "--max-budget-usd" "${TEST_TEMP_DIR}/claude_args"
}

@test "budget: AGENT_BUDGET_USD is a global fallback for phases without their own" {
    _setup_mock_claude
    export AGENT_BUDGET_USD="42"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    grep -qx "42" "${TEST_TEMP_DIR}/claude_args"
}

@test "effort: AGENT_EFFORT_<PHASE> passes --effort" {
    _setup_mock_claude
    export AGENT_EFFORT_IMPLEMENT="xhigh"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    grep -q -- "--effort" "${TEST_TEMP_DIR}/claude_args"
    grep -qx "xhigh" "${TEST_TEMP_DIR}/claude_args"
}

@test "permission mode: AGENT_PERMISSION_MODE_<PHASE> passes --permission-mode" {
    _setup_mock_claude
    export AGENT_PERMISSION_MODE_TRIAGE="dontAsk"
    run run_claude "prompt" "" "" "" "TRIAGE"
    grep -q -- "--permission-mode" "${TEST_TEMP_DIR}/claude_args"
    grep -qx "dontAsk" "${TEST_TEMP_DIR}/claude_args"
}

@test "flags: none of the per-phase flags appear when nothing is configured" {
    _setup_mock_claude
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    ! grep -qE -- "--max-budget-usd|--effort|--permission-mode|--mcp-config|--strict-mcp-config" "${TEST_TEMP_DIR}/claude_args"
}

@test "mcp: AGENT_MCP_CONFIG passes --mcp-config with --strict-mcp-config" {
    _setup_mock_claude
    echo '{"mcpServers":{}}' > "${TEST_TEMP_DIR}/mcp.json"
    export AGENT_MCP_CONFIG="${TEST_TEMP_DIR}/mcp.json"
    run run_claude "prompt" "" "" "" "TRIAGE"
    grep -q -- "--mcp-config" "${TEST_TEMP_DIR}/claude_args"
    grep -q -- "--strict-mcp-config" "${TEST_TEMP_DIR}/claude_args"
}

@test "mcp: AGENT_STRICT_MCP=true alone strips the operator's personal MCP servers" {
    _setup_mock_claude
    export AGENT_STRICT_MCP="true"
    run run_claude "prompt" "" "" "" "TRIAGE"
    grep -q -- "--strict-mcp-config" "${TEST_TEMP_DIR}/claude_args"
    ! grep -q -- "--mcp-config" "${TEST_TEMP_DIR}/claude_args"
}

@test "sessions: --no-session-persistence is passed by default" {
    _setup_mock_claude
    run run_claude "prompt" "" "" "" "TRIAGE"
    grep -q -- "--no-session-persistence" "${TEST_TEMP_DIR}/claude_args"
}

@test "sessions: AGENT_SESSION_PERSISTENCE=true keeps resumable sessions" {
    _setup_mock_claude
    export AGENT_SESSION_PERSISTENCE="true"
    run run_claude "prompt" "" "" "" "TRIAGE"
    ! grep -q -- "--no-session-persistence" "${TEST_TEMP_DIR}/claude_args"
}

@test "wiring: every phase call site names its phase" {
    grep -q '"IMPLEMENT")' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q '"TRIAGE")' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q '"POST_IMPL_REVIEW")' "${SCRIPTS_DIR}/lib/review-gates.sh"
    grep -q '"TEST_FIX")' "${SCRIPTS_DIR}/lib/review-gates.sh"
}

@test "legacy characterization: direct explicit model wins and global effort remains environment only" {
    _setup_mock_claude
    export AGENT_MODEL_IMPLEMENT=phase-model AGENT_MODEL_CLAUDE=engine-model
    export CLAUDE_CODE_EFFORT_LEVEL=high AGENT_BUDGET_USD=9
    run run_claude prompt Read caller-model '' IMPLEMENT
    assert_success
    grep -qx caller-model "$TEST_TEMP_DIR/claude_args"
    grep -qx 9 "$TEST_TEMP_DIR/claude_args"
    ! grep -q -- --effort "$TEST_TEMP_DIR/claude_args"
    run run_agent prompt Read '' '' IMPLEMENT
    grep -qx phase-model "$TEST_TEMP_DIR/claude_args"
}

@test "legacy characterization: phase-less caller does not gain phase flags" {
    _setup_mock_claude
    export AGENT_BUDGET_USD=9 AGENT_EFFORT_IMPLEMENT=max
    run run_claude prompt Read
    assert_success
    ! grep -qE -- '--effort|--max-budget-usd|--permission-mode' "$TEST_TEMP_DIR/claude_args"
}

# ─── Permission prompts and background-wait ceiling (#136) ───────

# A claude stub whose --help lists the flags in $1, and which records the
# argv and the wait ceiling of the phase launch.
_setup_probed_claude() {
    source "${LIB_DIR}/common.sh"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    export MOCK_HELP_FLAGS="$1"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
if [ "${1:-}" = "--help" ]; then
    printf '  %s <value>\n' $MOCK_HELP_FLAGS
    exit 0
fi
printf '%s\n' "$@" > "${TEST_TEMP_DIR}/claude_args"
printf '%s\n' "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-unset}" > "${TEST_TEMP_DIR}/claude_bg_wait"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
    unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
}

@test "permission prompts: --permission-prompts none by default when the CLI has the flag" {
    _setup_probed_claude "--permission-mode --permission-prompts"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    run grep -x -A1 -- "--permission-prompts" "${TEST_TEMP_DIR}/claude_args"
    assert_line --index 1 "none"
}

@test "permission prompts: the flag is left out for a CLI that does not list it" {
    _setup_probed_claude "--permission-mode --permission-prompt-tool"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    assert_success
    [ -f "${TEST_TEMP_DIR}/claude_args" ]
    ! grep -qx -- "--permission-prompts" "${TEST_TEMP_DIR}/claude_args"
}

@test "permission prompts: AGENT_PERMISSION_PROMPTS chooses the target, and empty leaves the flag out" {
    _setup_probed_claude "--permission-prompts"
    export AGENT_PERMISSION_PROMPTS="host"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    run grep -x -A1 -- "--permission-prompts" "${TEST_TEMP_DIR}/claude_args"
    assert_line --index 1 "host"

    export AGENT_PERMISSION_PROMPTS=""
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    ! grep -qx -- "--permission-prompts" "${TEST_TEMP_DIR}/claude_args"
}

@test "permission prompts: an unknown target is a configuration failure before any launch" {
    _setup_probed_claude "--permission-prompts"
    export AGENT_PERMISSION_PROMPTS="anyone"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    assert_output --partial "unsupported permission prompt target"
    [ ! -f "${TEST_TEMP_DIR}/claude_args" ]
}

@test "bg wait: the phase gets a ten-minute background-wait ceiling by default" {
    _setup_probed_claude ""
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    run cat "${TEST_TEMP_DIR}/claude_bg_wait"
    assert_output "600000"
}

@test "bg wait: AGENT_BG_WAIT_CEILING_MS sets it and AGENT_BG_WAIT_CEILING_MS_<PHASE> wins for that phase" {
    _setup_probed_claude ""
    export AGENT_BG_WAIT_CEILING_MS="120000"
    export AGENT_BG_WAIT_CEILING_MS_IMPLEMENT="900000"
    run run_claude "prompt" "" "" "" "TRIAGE"
    run cat "${TEST_TEMP_DIR}/claude_bg_wait"
    assert_output "120000"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    run cat "${TEST_TEMP_DIR}/claude_bg_wait"
    assert_output "900000"
}

@test "bg wait: an empty setting leaves the CLI's own ceiling alone" {
    _setup_probed_claude ""
    export AGENT_BG_WAIT_CEILING_MS=""
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    run cat "${TEST_TEMP_DIR}/claude_bg_wait"
    assert_output "unset"
}

@test "bg wait: a non-numeric ceiling is a configuration failure before any launch" {
    _setup_probed_claude ""
    export AGENT_BG_WAIT_CEILING_MS_IMPLEMENT="10m"
    run run_claude "prompt" "" "" "" "IMPLEMENT"
    assert_output --partial "background-wait ceiling must be a whole number of milliseconds"
    [ ! -f "${TEST_TEMP_DIR}/claude_args" ]
}
