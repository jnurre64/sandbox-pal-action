#!/usr/bin/env bats
# Tests for handle_post_merge in scripts/sandbox-pal-dispatch.sh

load 'helpers/test_helper'

# handle_post_merge lives in the dispatch script; extract it by sourcing the
# libs and defining the function body via a sourced test double is fragile —
# instead these tests exercise the pure helpers and the config gate through
# a stub harness that sources the dispatch script's function definitions.
_source_dispatch_functions() {
    export SCRIPT_DIR="${SCRIPTS_DIR}"
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    source "${LIB_DIR}/notify.sh"
    source "${LIB_DIR}/review-gates.sh"
    # shellcheck disable=SC1090
    source <(sed -n '/^handle_post_merge()/,/^}/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
}

# Merged bot PR closing two issues — used by the #74 regression tests
PR_JSON_MERGED='{"title":"t","body":"b","headRefName":"agent/issue-41","mergedAt":"2026-08-01T00:00:00Z","author":{"login":"test-bot"},"closingIssuesReferences":[{"number":41},{"number":42}]}'

@test "REGRESSION v1.2.0: disabled cleanup still transitions labels to agent:done (#74)" {
    export AGENT_CLEANUP_ENABLED="false"
    _source_dispatch_functions
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        if [ "$1" = "pr" ]; then echo "$PR_JSON_MERGED"; fi
        return 0
    }
    run handle_post_merge
    assert_success
    assert_output --partial "doc cleanup: disabled"
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 41 --repo test-org/test-repo --add-label agent:done"
}

@test "post_merge: unmerged PR is skipped" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    gh() { echo '{"title":"t","body":"","headRefName":"agent/issue-9","mergedAt":null,"author":{"login":"test-bot"},"closingIssuesReferences":[]}'; }
    run handle_post_merge
    assert_success
}

@test "post_merge: non-bot-authored PR is skipped" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    gh() { echo '{"title":"t","body":"","headRefName":"feature/9-x","mergedAt":"2026-08-01T00:00:00Z","author":{"login":"some-human"},"closingIssuesReferences":[]}'; }
    run handle_post_merge
    assert_success
}

@test "defaults: cleanup config vars exist with safe defaults" {
    unset AGENT_CLEANUP_ENABLED AGENT_MODEL_CLEANUP AGENT_PROMPT_CLEANUP AGENT_ALLOWED_TOOLS_CLEANUP
    source "${LIB_DIR}/defaults.sh"
    assert_equal "$AGENT_CLEANUP_ENABLED" "true"
    [ -n "$AGENT_ALLOWED_TOOLS_CLEANUP" ]
}

@test "dispatch: post_merge is a recognized event type" {
    run grep -E '^\s+post_merge\)' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    assert_success
}

@test "REGRESSION v1.2.0: every linked issue gets agent:done, not just the first (#74)" {
    export AGENT_CLEANUP_ENABLED="false"
    _source_dispatch_functions
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        if [ "$1" = "pr" ]; then echo "$PR_JSON_MERGED"; fi
        return 0
    }
    run handle_post_merge
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 41 --repo test-org/test-repo --add-label agent:done"
    assert_output --partial "issue edit 42 --repo test-org/test-repo --add-label agent:done"
}

@test "post_merge: label transition runs before circuit breaker and worktree" {
    export AGENT_CLEANUP_ENABLED="false"
    _source_dispatch_functions
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        if [ "$1" = "pr" ]; then echo "$PR_JSON_MERGED"; fi
        return 0
    }
    run handle_post_merge
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    # check_circuit_breaker calls `gh api ...` — must not have run on the disabled path
    refute_output --partial "api "
}

@test "post_merge: branch-name fallback still marks the issue when closingIssuesReferences is empty" {
    export AGENT_CLEANUP_ENABLED="false"
    _source_dispatch_functions
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        if [ "$1" = "pr" ]; then echo '{"title":"t","body":"","headRefName":"agent/issue-9","mergedAt":"2026-08-01T00:00:00Z","author":{"login":"test-bot"},"closingIssuesReferences":[]}'; fi
        return 0
    }
    run handle_post_merge
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 9 --repo test-org/test-repo --add-label agent:done"
}

@test "post_merge: unmerged and non-bot PRs get no label edits" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        if [ "$1" = "pr" ]; then echo '{"title":"t","body":"","headRefName":"feature/9-x","mergedAt":null,"author":{"login":"some-human"},"closingIssuesReferences":[{"number":9}]}'; fi
        return 0
    }
    run handle_post_merge
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    refute_output --partial "add-label"
}
