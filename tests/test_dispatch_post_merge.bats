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

@test "post_merge: disabled config gate returns 0 without calling gh" {
    export AGENT_CLEANUP_ENABLED="false"
    _source_dispatch_functions
    run handle_post_merge
    assert_success
    [ ! -f "${TEST_TEMP_DIR}/mock_calls_gh" ]
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
