#!/usr/bin/env bats
# Tests for dispatch hygiene (#99): scratch-file lifetimes, no
# issue/PR body read-modify-writes, and config provenance at startup.

load 'helpers/test_helper'

_source_common() {
    source "${LIB_DIR}/common.sh"
}

@test "REGRESSION v1.2.0: setup_worktree clears every dispatch-scoped scratch artefact" {
    # A reused worktree must not post a previous dispatch's plan, report
    # its denials, or apply its staged rules edits.
    grep -q 'permission-denials.log' "${LIB_DIR}/worktree.sh"
    grep -q 'plan.md' "${LIB_DIR}/worktree.sh"
    grep -q 'agent-data/rules' "${LIB_DIR}/worktree.sh"
}

@test "guard: no script read-modify-writes an issue or PR body" {
    # Tracking state in a body corrupts over time (encoding round-trips,
    # lost concurrent edits). Append a comment or use a repo file instead.
    ! grep -rE "gh (issue|pr) edit[^|]*--body" "${SCRIPTS_DIR}/" --include="*.sh"
}

@test "provenance: logs the config sources and every phase model" {
    _source_common
    export AGENT_DEFAULTS="/path/to/config.defaults.env"
    export AGENT_CONFIG=""
    export AGENT_EXECUTION_MODE="actions"
    export AGENT_MODEL="opus"
    export AGENT_MODEL_TRIAGE="sonnet"
    export AGENT_MODEL_IMPLEMENT=""

    run log_config_provenance
    assert_output --partial "config.defaults.env"
    assert_output --partial "triage=sonnet"
    assert_output --partial "implement="
    assert_output --partial "mode=actions"
}

@test "provenance: printed once at startup for every event including status" {
    grep -q "log_config_provenance" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    # It must run before the status early-exit so status reports it too
    local dispatch_line status_line
    dispatch_line=$(grep -n "log_config_provenance" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | head -1 | cut -d: -f1)
    status_line=$(grep -n 'handle_status' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh" | tail -1 | cut -d: -f1)
    [ "$dispatch_line" -lt "$status_line" ]
}
