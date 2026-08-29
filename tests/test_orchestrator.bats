#!/usr/bin/env bats
# Tests for orchestrator mode (#95): interactive-session-driven dispatch.
# Contract: in orchestrator mode, stdout carries exactly one compact JSON
# line (the result); everything human-readable goes to stderr and the log.

load 'helpers/test_helper'

_source_orchestrator() {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/liveness.sh"
    export AGENT_LOCK_DIR="${TEST_TEMP_DIR}/locks"
}

@test "log: writes to stdout in actions mode (default)" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="actions"
    local out
    out=$(log "hello from actions" 2>/dev/null)
    [[ "$out" == *"hello from actions"* ]]
}

@test "log: writes to stderr, not stdout, in orchestrator mode" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="orchestrator"
    local out err
    out=$(log "hello from orchestrator" 2>/dev/null)
    err=$(log "hello from orchestrator" 2>&1 >/dev/null)
    [ -z "$out" ]
    [[ "$err" == *"hello from orchestrator"* ]]
}

@test "emit_orchestrator_result: one compact JSON line with outcome and pr_url" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="orchestrator"
    DISPATCH_OUTCOME="agent:pr-open"
    DISPATCH_PR_URL="https://github.com/test-org/test-repo/pull/7"

    run emit_orchestrator_result 0
    assert_success
    [ "${#lines[@]}" -eq 1 ]
    [ "$(echo "$output" | jq -r '.outcome')" = "agent:pr-open" ]
    [ "$(echo "$output" | jq -r '.pr_url')" = "https://github.com/test-org/test-repo/pull/7" ]
    [ "$(echo "$output" | jq -r '.event')" = "$EVENT_TYPE" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "0" ]
}

@test "emit_orchestrator_result: silent in actions mode" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="actions"
    run emit_orchestrator_result 0
    assert_output ""
}

@test "emit_orchestrator_result: silent for the status event (status emits its own line)" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="orchestrator"
    export EVENT_TYPE="status"
    run emit_orchestrator_result 0
    assert_output ""
}

@test "emit_orchestrator_result: reports lock-refused when the dispatch was refused" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="orchestrator"
    DISPATCH_LOCK_REFUSED=1
    run emit_orchestrator_result 0
    [ "$(echo "$output" | jq -r '.outcome')" = "lock-refused" ]
}

@test "emit_orchestrator_result: derives error outcome from a failure exit code" {
    _source_orchestrator
    export AGENT_EXECUTION_MODE="orchestrator"
    run emit_orchestrator_result 3
    [ "$(echo "$output" | jq -r '.outcome')" = "error" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "3" ]
}

@test "write_last_dispatch: includes the PR URL when one was created" {
    _source_orchestrator
    acquire_dispatch_lock
    DISPATCH_PR_URL="https://github.com/test-org/test-repo/pull/7"
    write_last_dispatch 0
    [ "$(jq -r '.pr_url' "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}-last-dispatch.json")" = "https://github.com/test-org/test-repo/pull/7" ]
}

@test "skills: the four orchestrator skills exist" {
    [ -f "${TEST_ROOT}/../.claude/skills/sp-work/SKILL.md" ]
    [ -f "${TEST_ROOT}/../.claude/skills/sp-status/SKILL.md" ]
    [ -f "${TEST_ROOT}/../.claude/skills/sp-revise/SKILL.md" ]
    [ -f "${TEST_ROOT}/../.claude/skills/sp-post-merge/SKILL.md" ]
}

@test "skills: sp-work carries the operator-discipline line and the liveness verification rule" {
    grep -qi "never implement" "${TEST_ROOT}/../.claude/skills/sp-work/SKILL.md"
    grep -qi "unverified" "${TEST_ROOT}/../.claude/skills/sp-work/SKILL.md"
}

@test "skills: sp-status is read-only by contract" {
    grep -qi "read-only" "${TEST_ROOT}/../.claude/skills/sp-status/SKILL.md"
}

@test "REGRESSION v1.2.0: a failing status event never posts comments or labels" {
    _source_orchestrator
    export EVENT_TYPE="status"
    # shellcheck disable=SC1090
    source <(sed -n '/^_on_unexpected_error()/,/^}/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
    gh() { echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"; }

    _on_unexpected_error 42 1 || true

    [ ! -f "${TEST_TEMP_DIR}/gh_calls" ]
}

@test "dispatch: refusal flags the result and the exit trap emits the orchestrator line" {
    grep -q "DISPATCH_LOCK_REFUSED=1" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "emit_orchestrator_result" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}
