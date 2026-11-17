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
    source "${LIB_DIR}/rules-staging.sh"
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

# ═══════════════════════════════════════════════════════════════
# Backlog batch 2: cleanup recursion, duplicate and dropped follow-ups
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION v1.4.1: a merged cleanup PR does not get a cleanup of its own (#113)" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    setup_worktree() { echo called >> "${TEST_TEMP_DIR}/worktree_calls"; }
    gh() { echo '{"title":"chore: post-merge cleanup for PR #452","body":"","headRefName":"chore/agent-cleanup-pr-452","mergedAt":"2026-08-30T00:00:00Z","author":{"login":"test-bot"},"closingIssuesReferences":[]}'; }
    run handle_post_merge
    assert_success
    assert_output --partial "is a post-merge cleanup PR"
    [ ! -f "${TEST_TEMP_DIR}/worktree_calls" ]
}

@test "REGRESSION v1.4.1: a merged PR with no linked issue gets no cleanup session (#113)" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    setup_worktree() { echo called >> "${TEST_TEMP_DIR}/worktree_calls"; }
    gh() { echo '{"title":"docs: status","body":"","headRefName":"docs/status-update","mergedAt":"2026-08-30T00:00:00Z","author":{"login":"test-bot"},"closingIssuesReferences":[]}'; }
    run handle_post_merge
    assert_success
    assert_output --partial "no linked issue"
    [ ! -f "${TEST_TEMP_DIR}/worktree_calls" ]
}

_mock_gh_followups() {
    gh() {
        echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"
        case "$1 $2" in
            "issue list") echo '[{"number":7,"title":"Fix the Widget cache"}]' ;;
            "issue create") echo "https://github.com/test-org/test-repo/issues/50" ;;
        esac
        return 0
    }
}

@test "REGRESSION v1.4.1: a follow-up whose title matches an open issue is not filed again (#80)" {
    _source_dispatch_functions
    _mock_gh_followups
    export AGENT_REVIEW_LEDGER=""
    file_follow_up_issues '{"follow_up_issues":[{"title":"fix the widget cache ","body":"b1"},{"title":"Add a pause test","body":"b2"},{"title":"Add a pause test","body":"b2 again"}]}' 12
    [ "$FOLLOWUP_FILED_COUNT" -eq 1 ]
    [ "$(grep -c '^issue create' "${TEST_TEMP_DIR}/gh_calls")" -eq 1 ]
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue create --repo test-org/test-repo --title Add a pause test"
    refute_output --partial "--title fix the widget cache"
}

@test "REGRESSION v1.4.1: the cleanup accounts for every ledger finding on the merged PR (#85)" {
    _source_dispatch_functions
    _mock_gh_followups
    export AGENT_REVIEW_LEDGER='{"issue":41,"cycles":2,"findings":[
        {"id":"F1","severity":"blocking","status":"fixed","description":"done"},
        {"id":"F2","severity":"non-blocking","status":"open","description":"pause test"},
        {"id":"F3","severity":"non-blocking","status":"open","description":"widget cache"},
        {"id":"F4","severity":"blocking","status":"rejected","description":"style"},
        {"id":"F5","severity":"non-blocking","status":"open","description":"forgotten"}]}'
    run file_follow_up_issues '{"follow_up_issues":[{"title":"Add a pause test","body":"b"},{"title":"Fix the widget cache","body":"b"}],"not_filed":[{"finding":"F4","reason":"style nit"}]}' 12
    assert_success
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "pr comment 12 --repo test-org/test-repo"
    assert_output --partial "4 finding(s)"
    assert_output --partial "issues/50"
    assert_output --partial "Already tracked: #7"
    assert_output --partial "F4: style nit"
    assert_output --partial "1 finding(s) are not accounted for"
}

@test "follow-ups: AGENT_FOLLOWUP_LABELS is applied to filed issues" {
    _source_dispatch_functions
    _mock_gh_followups
    export AGENT_REVIEW_LEDGER="" AGENT_FOLLOWUP_LABELS="follow-up,agent-review"
    file_follow_up_issues '{"follow_up_issues":[{"title":"Add a pause test","body":"b"}]}' 12
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "--label follow-up,agent-review"
}

@test "follow-ups: the cleanup prompt and schema carry the accounting contract" {
    jq -e '.properties.not_filed.type == "array"' "${SCRIPTS_DIR}/../schemas/cleanup.json"
    grep -q 'not_filed' "${PROMPTS_DIR}/cleanup.md"
    grep -q 'open-issues.md' "${PROMPTS_DIR}/cleanup.md"
    grep -q 'open-issues.md' "${LIB_DIR}/phase-context.sh"
    grep -q 'file_follow_up_issues' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}
