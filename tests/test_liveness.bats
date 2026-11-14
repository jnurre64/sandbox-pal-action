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

@test "acquire_dispatch_lock: refuses while another process holds the lock's mutex" {
    command -v flock >/dev/null || skip "flock not installed"
    _source_liveness
    mkdir -p "$AGENT_LOCK_DIR"
    local lock="${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock"
    # Another dispatch is between its check and its write: it holds the mutex
    # and has not written the lock file yet.
    flock -n "${lock}.mutex" sleep 5 &
    local holder=$!
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "${lock}.mutex" ] && break; sleep 0.1; done
    sleep 0.2

    run acquire_dispatch_lock
    kill "$holder" 2>/dev/null || true
    assert_failure
    assert_output --partial "refusing"
    [ ! -f "$lock" ]
}

@test "acquire_dispatch_lock: the mutex is free again after release" {
    command -v flock >/dev/null || skip "flock not installed"
    _source_liveness
    acquire_dispatch_lock
    release_dispatch_lock
    [ -z "$DISPATCH_MUTEX_FD" ]
    flock -n "${AGENT_LOCK_DIR}/${REPO_NAME}-${NUMBER}.lock.mutex" true
}

@test "dispatch: AGENT_DISPATCH_PAUSED exits with outcome paused before the lock, GitHub or a worker" {
    mkdir -p "$TEST_TEMP_DIR/install"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/install/scripts"
    create_mock gh ''
    create_mock claude 'unexpected worker'
    run env HOME="$TEST_TEMP_DIR/home" AGENT_DISPATCH_PAUSED=true AGENT_EXECUTION_MODE=orchestrator \
        bash "$TEST_TEMP_DIR/install/scripts/sandbox-pal-dispatch.sh" implement test-org/test-repo 99
    assert_success
    echo "${lines[${#lines[@]}-1]}" | jq -e '.outcome == "paused" and .exit_code == 0'
    [ ! -f "$AGENT_LOG_DIR/locks/test-repo-99.lock" ]
    [ ! -f "$AGENT_LOG_DIR/locks/test-repo-99-last-dispatch.json" ]
    [ ! -f "$TEST_TEMP_DIR/mock_calls_claude" ]
    [ ! -f "$TEST_TEMP_DIR/mock_calls_gh" ]
}

@test "dispatch: status still answers while paused" {
    mkdir -p "$TEST_TEMP_DIR/install"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/install/scripts"
    create_mock gh ''
    run env HOME="$TEST_TEMP_DIR/home" AGENT_DISPATCH_PAUSED=true AGENT_EXECUTION_MODE=orchestrator \
        bash "$TEST_TEMP_DIR/install/scripts/sandbox-pal-dispatch.sh" status test-org/test-repo 99
    assert_success
    echo "${lines[${#lines[@]}-1]}" | jq -e '.outcome != "paused"'
    refute_output --partial "AGENT_DISPATCH_PAUSED"
}
