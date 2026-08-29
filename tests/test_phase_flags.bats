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
