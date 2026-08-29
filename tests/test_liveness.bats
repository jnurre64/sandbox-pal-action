#!/usr/bin/env bats
# Tests for scripts/lib/liveness.sh (#94)
#
# Three independent liveness signals: a lock with pid/host/phase
# heartbeat, stale detection in a read-only status event, and a
# last-dispatch outcome record written before exit on every outcome.

load 'helpers/test_helper'

_source_liveness() {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/liveness.sh"
    export AGENT_LOCK_DIR="${TEST_TEMP_DIR}/locks"
}

# A pid that is certainly dead: a subshell that has already exited.
_dead_pid() {
    bash -c 'echo $$'
}

@test "acquire_dispatch_lock: writes a lock with pid, host, phase and start time" {
    _source_liveness
    acquire_dispatch_lock

    local lock="${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"
    [ -f "$lock" ]
    [ "$(jq -r '.pid' "$lock")" = "$$" ]
    [ "$(jq -r '.host' "$lock")" = "$(hostname)" ]
    [ "$(jq -r '.phase' "$lock")" = "starting" ]
    [ -n "$(jq -r '.started' "$lock")" ]
}

@test "acquire_dispatch_lock: refuses when a live pid on this host holds the lock" {
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"pid":1,"host":"%s","event":"implement","issue":"99","started":"x","phase":"implement","updated":"x"}' "$(hostname)" \
        > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"

    run acquire_dispatch_lock
    assert_failure
    assert_output --partial "held"
}

@test "acquire_dispatch_lock: reclaims a stale lock from a dead pid on this host" {
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"pid":%s,"host":"%s","event":"implement","issue":"99","started":"x","phase":"implement","updated":"x"}' \
        "$(_dead_pid)" "$(hostname)" \
        > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"

    acquire_dispatch_lock
    [ "$(jq -r '.pid' "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock")" = "$$" ]
}

@test "acquire_dispatch_lock: refuses a lock from another host even with an unknown pid" {
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"pid":%s,"host":"some-other-host","event":"implement","issue":"99","started":"x","phase":"implement","updated":"x"}' \
        "$(_dead_pid)" > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"

    run acquire_dispatch_lock
    assert_failure
}

@test "set_heartbeat: updates the lock's current phase" {
    _source_liveness
    acquire_dispatch_lock
    set_heartbeat "review-pass-2"

    [ "$(jq -r '.phase' "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock")" = "review-pass-2" ]
}

@test "release_dispatch_lock: removes our lock but never someone else's" {
    _source_liveness
    acquire_dispatch_lock
    release_dispatch_lock
    [ ! -f "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock" ]

    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"pid":1,"host":"%s"}' "$(hostname)" > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"
    release_dispatch_lock
    [ -f "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock" ]
}

@test "write_last_dispatch: records outcome, event and issue on failure exit codes too" {
    _source_liveness
    acquire_dispatch_lock
    DISPATCH_OUTCOME="agent:failed"
    write_last_dispatch 1

    local last="${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}-last-dispatch.json"
    [ -f "$last" ]
    [ "$(jq -r '.outcome' "$last")" = "agent:failed" ]
    [ "$(jq -r '.exit_code' "$last")" = "1" ]
    [ "$(jq -r '.event' "$last")" = "$EVENT_TYPE" ]
}

@test "write_last_dispatch: no-op when we never held the lock (a refused dispatch must not overwrite the running one's record)" {
    _source_liveness
    write_last_dispatch 0
    [ ! -f "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}-last-dispatch.json" ]
}

@test "handle_status: final stdout line is JSON reporting a live lock as stale=false with its phase" {
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"pid":%s,"host":"%s","event":"implement","issue":"99","started":"x","phase":"review-pass-1","updated":"y"}' \
        "$$" "$(hostname)" > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"

    run handle_status
    assert_success
    local last_line
    last_line=$(echo "$output" | tail -1)
    [ "$(echo "$last_line" | jq -r '.lock.stale')" = "false" ]
    [ "$(echo "$last_line" | jq -r '.lock.phase')" = "review-pass-1" ]
}

@test "handle_status: reports a dead pid's lock as stale=true and does not clean it up" {
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"pid":%s,"host":"%s","event":"implement","issue":"99","started":"x","phase":"implement","updated":"y"}' \
        "$(_dead_pid)" "$(hostname)" > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"

    run handle_status
    local last_line
    last_line=$(echo "$output" | tail -1)
    [ "$(echo "$last_line" | jq -r '.lock.stale')" = "true" ]
    [ -f "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock" ]
}

@test "handle_status: never writes the last-dispatch record" {
    _source_liveness
    handle_status >/dev/null
    [ ! -f "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}-last-dispatch.json" ]
}

@test "handle_status: includes the last-dispatch record when one exists" {
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    printf '{"event":"implement","outcome":"agent:pr-open","exit_code":0}' \
        > "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}-last-dispatch.json"

    run handle_status
    local last_line
    last_line=$(echo "$output" | tail -1)
    [ "$(echo "$last_line" | jq -r '.last_dispatch.outcome')" = "agent:pr-open" ]
}

@test "dispatch: liveness is sourced, status routed, and heartbeats cover the review loop" {
    grep -q "lib/liveness.sh" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "handle_status" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "acquire_dispatch_lock" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "set_heartbeat" "${SCRIPTS_DIR}/lib/review-gates.sh"
}
