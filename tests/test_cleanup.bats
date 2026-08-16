#!/usr/bin/env bats
# Tests for sweep_stale_agent_labels in scripts/cleanup.sh (#74)
#
# cleanup.sh executes main() on load, so functions are extracted with sed —
# function bodies in cleanup.sh must contain no column-0 `}`.

load 'helpers/test_helper'

_source_sweep() {
    DRY_RUN="${DRY_RUN:-true}"
    VERBOSE=false
    LOG_FILE="${TEST_TEMP_DIR}/cleanup.log"
    AUDIT_LOG="${TEST_TEMP_DIR}/audit.jsonl"
    COUNTER_DIR="${TEST_TEMP_DIR}/counters"
    mkdir -p "$COUNTER_DIR"
    echo 0 > "$COUNTER_DIR/issues_relabeled"
    # shellcheck disable=SC1090
    source <(sed -n '/^increment()/,/^}/p; /^counter()/,/^}/p; /^log()/,/^}/p; /^verbose()/,/^}/p; /^audit()/,/^}/p; /^AGENT_STATE_LABELS=/p; /^sweep_stale_agent_labels()/,/^}/p' "${SCRIPTS_DIR}/cleanup.sh")
}

# gh mock: one closed issue (#7) carries stale labels; it was closed by
# PR #12. The pr view response is set per-test via MOCK_PR_JSON.
_mock_gh() {
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        case "$1 $2" in
            "issue list") echo "7" ;;
            "issue view") echo "12" ;;
            "pr view")    echo "$MOCK_PR_JSON" ;;
            *) : ;;
        esac
    }
}

@test "sweep: AGENT_STATE_LABELS does not include agent:done" {
    _source_sweep
    [[ "$AGENT_STATE_LABELS" != *"agent:done"* ]]
}

@test "sweep: dry run reports but performs no issue edits" {
    DRY_RUN=true
    _source_sweep
    _mock_gh
    export MOCK_PR_JSON='{"author":{"login":"test-bot"},"mergedAt":"2026-08-01T00:00:00Z"}'
    run sweep_stale_agent_labels
    assert_success
    assert_output --partial "[DRY RUN]"
    run cat "${TEST_TEMP_DIR}/gh_calls"
    refute_output --partial "issue edit"
}

@test "sweep: dry run still counts the issue" {
    DRY_RUN=true
    _source_sweep
    _mock_gh
    export MOCK_PR_JSON='{"author":{"login":"test-bot"},"mergedAt":"2026-08-01T00:00:00Z"}'
    sweep_stale_agent_labels
    assert_equal "$(counter issues_relabeled)" "1"
}

@test "sweep: merged bot PR -> labels stripped and agent:done added" {
    DRY_RUN=false
    _source_sweep
    _mock_gh
    export MOCK_PR_JSON='{"author":{"login":"test-bot"},"mergedAt":"2026-08-01T00:00:00Z"}'
    run sweep_stale_agent_labels
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 7 --repo test-org/test-repo --remove-label agent:pr-open"
    assert_output --partial "issue edit 7 --repo test-org/test-repo --add-label agent:done"
}

@test "sweep: closing PR not merged -> labels stripped, no agent:done" {
    DRY_RUN=false
    _source_sweep
    _mock_gh
    export MOCK_PR_JSON='{"author":{"login":"test-bot"},"mergedAt":null}'
    run sweep_stale_agent_labels
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 7 --repo test-org/test-repo --remove-label agent:pr-open"
    refute_output --partial "add-label agent:done"
}

@test "sweep: merged non-bot PR -> labels stripped, no agent:done" {
    DRY_RUN=false
    _source_sweep
    _mock_gh
    export MOCK_PR_JSON='{"author":{"login":"some-human"},"mergedAt":"2026-08-01T00:00:00Z"}'
    run sweep_stale_agent_labels
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    refute_output --partial "add-label agent:done"
}

@test "sweep: empty AGENT_BOT_USER degrades gracefully (any merged closing PR counts)" {
    DRY_RUN=false
    export AGENT_BOT_USER=""
    _source_sweep
    _mock_gh
    export MOCK_PR_JSON='{"author":{"login":"whoever"},"mergedAt":"2026-08-01T00:00:00Z"}'
    run sweep_stale_agent_labels
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 7 --repo test-org/test-repo --add-label agent:done"
}

@test "sweep: no stale issues -> no edits, clean exit" {
    DRY_RUN=false
    _source_sweep
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        return 0
    }
    run sweep_stale_agent_labels
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    refute_output --partial "issue edit"
}
