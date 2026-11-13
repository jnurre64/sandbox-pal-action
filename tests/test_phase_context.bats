#!/usr/bin/env bats
# Tests for the phase context files (#135, second half of #118): the
# issue, plan, PR and review text a phase needs is written under
# .agent-data/context/ so it can be read with the Read tool. A phase that
# cannot run a shell command still knows what it is working on.

load 'helpers/test_helper'

_context_dir() {
    printf '%s\n' "${WORKTREE_DIR}/.agent-data/context"
}

_setup() {
    source "${LIB_DIR}/common.sh"
    git -C "$WORKTREE_DIR" init -q
}

# ─── write_phase_context ─────────────────────────────────────────

@test "context: the issue title, body and comments are written as files" {
    _setup
    export AGENT_ISSUE_NUMBER="42" AGENT_ISSUE_TITLE="Crash on save"
    export AGENT_ISSUE_BODY=$'Steps:\n1. Save\n2. Crash' AGENT_COMMENTS="[alice] also on load"
    write_phase_context
    [ "$(cat "$(_context_dir)/issue-number.txt")" = "42" ]
    [ "$(cat "$(_context_dir)/issue-title.txt")" = "Crash on save" ]
    [ "$(cat "$(_context_dir)/issue-body.md")" = $'Steps:\n1. Save\n2. Crash' ]
    [ "$(cat "$(_context_dir)/comments.md")" = "[alice] also on load" ]
}

@test "context: text is written verbatim, never expanded or interpreted" {
    _setup
    export AGENT_ISSUE_BODY='$(touch pwned) `id` $HOME %s \n "quoted" -n'
    write_phase_context
    [ "$(cat "$(_context_dir)/issue-body.md")" = '$(touch pwned) `id` $HOME %s \n "quoted" -n' ]
    [ ! -e "${WORKTREE_DIR}/pwned" ]
}

@test "context: plan, PR, review and test-gate values each get a file" {
    _setup
    export AGENT_PLAN_CONTENT="## Implementation Plan" AGENT_PR_TITLE="Fix save" AGENT_PR_BODY="Closes #42"
    export AGENT_COMMIT_HISTORY="- abc123 first" AGENT_REVIEWS="[bob] CHANGES_REQUESTED"
    export AGENT_REVIEW_COMMENTS="a.gd:3 nit" AGENT_PR_COMMENTS="[bob] please fix"
    export AGENT_REVIEW_LEDGER='{"cycles":[]}' AGENT_REVIEW_CONCERNS="missing test"
    export AGENT_TEST_OUTPUT="1 failed" AGENT_TEST_EXIT_CODE="1" AGENT_MERGED_BRANCH="agent/issue-42"
    export AGENT_TEST_COMMAND="make test" AGENT_TEST_SETUP_COMMAND="make deps"
    write_phase_context
    local dir
    dir=$(_context_dir)
    [ "$(cat "$dir/plan.md")" = "## Implementation Plan" ]
    [ "$(cat "$dir/pr-title.txt")" = "Fix save" ]
    [ "$(cat "$dir/pr-body.md")" = "Closes #42" ]
    [ "$(cat "$dir/commit-history.txt")" = "- abc123 first" ]
    [ "$(cat "$dir/reviews.md")" = "[bob] CHANGES_REQUESTED" ]
    [ "$(cat "$dir/review-comments.md")" = "a.gd:3 nit" ]
    [ "$(cat "$dir/pr-comments.md")" = "[bob] please fix" ]
    [ "$(cat "$dir/review-ledger.json")" = '{"cycles":[]}' ]
    [ "$(cat "$dir/review-concerns.md")" = "missing test" ]
    [ "$(cat "$dir/test-output.txt")" = "1 failed" ]
    [ "$(cat "$dir/test-exit-code.txt")" = "1" ]
    [ "$(cat "$dir/merged-branch.txt")" = "agent/issue-42" ]
    [ "$(cat "$dir/test-command.txt")" = "make test" ]
    [ "$(cat "$dir/test-setup-command.txt")" = "make deps" ]
}

@test "context: an unset or empty value has no file" {
    _setup
    unset AGENT_PLAN_CONTENT
    export AGENT_ISSUE_TITLE="A title" AGENT_COMMENTS=""
    write_phase_context
    [ -f "$(_context_dir)/issue-title.txt" ]
    [ ! -e "$(_context_dir)/plan.md" ]
    [ ! -e "$(_context_dir)/comments.md" ]
}

@test "context: a value that went away takes its file with it" {
    _setup
    export AGENT_REVIEW_CONCERNS="first pass concerns" AGENT_ISSUE_TITLE="A title"
    write_phase_context
    [ -f "$(_context_dir)/review-concerns.md" ]
    unset AGENT_REVIEW_CONCERNS
    write_phase_context
    [ ! -e "$(_context_dir)/review-concerns.md" ]
    [ -f "$(_context_dir)/issue-title.txt" ]
}

@test "context: a changed value replaces the file's contents" {
    _setup
    export AGENT_PLAN_CONTENT="first plan, quite long"
    write_phase_context
    export AGENT_PLAN_CONTENT="revised"
    write_phase_context
    [ "$(cat "$(_context_dir)/plan.md")" = "revised" ]
}

@test "context: attached data is listed in one index file" {
    _setup
    export AGENT_DATA_COMMENT_FILE="/w/.agent-data/latest-data-comment.md"
    export AGENT_GIST_FILES=" /w/.agent-data/gist-abc.txt /w/.agent-data/save.json"
    export AGENT_DATA_ERRORS="${TEST_TEMP_DIR}/data-errors.txt"
    echo "FAILED: https://example.invalid/x" > "$AGENT_DATA_ERRORS"
    write_phase_context
    run cat "$(_context_dir)/attached-data.md"
    assert_line "Latest data comment: /w/.agent-data/latest-data-comment.md"
    assert_line "- /w/.agent-data/gist-abc.txt"
    assert_line "- /w/.agent-data/save.json"
    assert_line "Download errors: ${TEST_TEMP_DIR}/data-errors.txt"
}

@test "context: no index file when nothing was attached" {
    _setup
    export AGENT_DATA_COMMENT_FILE="" AGENT_GIST_FILES=""
    export AGENT_DATA_ERRORS="${TEST_TEMP_DIR}/data-errors.txt"   # named, but never created
    write_phase_context
    [ ! -e "$(_context_dir)/attached-data.md" ]
}

@test "context: the directory is kept out of commits" {
    _setup
    export AGENT_ISSUE_BODY="private issue text"
    write_phase_context
    write_phase_context   # idempotent: the exclude line is added once
    run git -C "$WORKTREE_DIR" status --porcelain --untracked-files=all
    refute_output --partial "context"
    [ "$(grep -cx '.agent-data/context/' "${WORKTREE_DIR}/.git/info/exclude")" = "1" ]
}

@test "context: nothing is written without a worktree" {
    source "${LIB_DIR}/common.sh"
    export WORKTREE_DIR="${TEST_TEMP_DIR}/absent" AGENT_ISSUE_TITLE="A title"
    run write_phase_context
    assert_success
    [ ! -e "${TEST_TEMP_DIR}/absent" ]
}

# ─── Wiring ──────────────────────────────────────────────────────

@test "context: every phase launch writes the files before the worker starts" {
    _setup
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
cat .agent-data/context/issue-title.txt > "${TEST_TEMP_DIR}/title_seen" 2>/dev/null
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
    export AGENT_ISSUE_TITLE="Seen by the worker"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(cat "${TEST_TEMP_DIR}/title_seen")" = "Seen by the worker" ]
}

@test "context: the environment variables are still exported for one release" {
    _setup
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s' "$AGENT_ISSUE_TITLE" > "${TEST_TEMP_DIR}/title_env"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
    export AGENT_ISSUE_TITLE="Still in the environment"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(cat "${TEST_TEMP_DIR}/title_env")" = "Still in the environment" ]
}

@test "context: a reused worktree does not keep the last dispatch's files" {
    grep -q '/.agent-data/context"$' "${LIB_DIR}/worktree.sh"
}

# ─── Prompts ─────────────────────────────────────────────────────

@test "prompts: no shipped prompt asks the phase to echo an environment variable" {
    run grep -rnE 'echo "?\$AGENT_' "$PROMPTS_DIR"
    assert_failure
}

@test "prompts: no shipped prompt leaves a context variable for the shell to expand" {
    run grep -rnE '\$AGENT_[A-Z_]+' "$PROMPTS_DIR"
    assert_failure
}

@test "prompts: every context file a prompt names is one the dispatcher writes" {
    source "${LIB_DIR}/common.sh"
    local known name
    known=$(agent_context_file_names)
    while IFS= read -r name; do
        grep -qx -- "$name" <<< "$known" || fail "prompt names unknown context file: $name"
    done < <(grep -rhoE '\.agent-data/context/[A-Za-z0-9._-]+' "$PROMPTS_DIR" | sed 's|.*/||' | sort -u)
}

@test "prompts: every phase prompt points at the context directory" {
    local prompt
    for prompt in triage reply validate implement review adversarial-plan post-impl-review post-impl-retry test-fix cleanup; do
        grep -q '\.agent-data/context/' "${PROMPTS_DIR}/${prompt}.md" || fail "${prompt}.md does not name .agent-data/context/"
    done
}

# ─── Referenced issues and pull requests ─────────────────────────

_setup_refs() {
    _setup
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/gh" <<'MOCK'
#!/bin/bash
echo "$*" >> "${TEST_TEMP_DIR}/gh_calls"
case "$*" in
    "api repos/test-org/test-repo/issues/7")
        echo '{"number":7,"title":"Older bug","state":"closed","html_url":"https://github.com/test-org/test-repo/issues/7","body":"Body of seven with $(danger)"}' ;;
    "api repos/test-org/test-repo/issues/12")
        echo '{"number":12,"title":"The fix","state":"open","html_url":"https://github.com/test-org/test-repo/pull/12","body":null,"pull_request":{"url":"x"}}' ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/gh"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
    unset AGENT_CONTEXT_REFS_MAX
}

_refs_dir() {
    printf '%s\n' "${WORKTREE_DIR}/.agent-data/context/references"
}

@test "references: an issue named as #N in the text is fetched into a file" {
    _setup_refs
    fetch_referenced_context "Same symptom as #7, see there."
    run cat "$(_refs_dir)/7.md"
    assert_line "# #7: Older bug"
    assert_line "Type: issue"
    assert_line "State: closed"
    assert_line 'Body of seven with $(danger)'
}

@test "references: a pull request is labelled as one, and an empty body is tolerated" {
    _setup_refs
    fetch_referenced_context "Follow-up to #12"
    run cat "$(_refs_dir)/12.md"
    assert_line "# #12: The fix"
    assert_line "Type: pull request"
}

@test "references: a full URL to this repository's issue or pull request counts" {
    _setup_refs
    fetch_referenced_context "See https://github.com/test-org/test-repo/issues/7 and https://github.com/test-org/test-repo/pull/12."
    [ -f "$(_refs_dir)/7.md" ]
    [ -f "$(_refs_dir)/12.md" ]
}

@test "references: the item being worked on is not fetched as its own reference" {
    _setup_refs
    fetch_referenced_context "This is #99 itself, related to #7"
    [ -f "$(_refs_dir)/7.md" ]
    ! grep -q 'issues/99' "${TEST_TEMP_DIR}/gh_calls"
}

@test "references: another repository's items and non-references are left alone" {
    _setup_refs
    fetch_referenced_context "other-org/other#7, https://github.com/other-org/other/issues/12, colour #777abc, heading# 7, a&#12;b"
    [ ! -e "${TEST_TEMP_DIR}/gh_calls" ]
}

@test "references: each item is fetched once, however often it is named" {
    _setup_refs
    fetch_referenced_context "#7 and again #7"
    fetch_referenced_context "#7 once more"
    [ "$(grep -c 'issues/7$' "${TEST_TEMP_DIR}/gh_calls")" = "1" ]
}

@test "references: AGENT_CONTEXT_REFS_MAX bounds how many are fetched" {
    _setup_refs
    export AGENT_CONTEXT_REFS_MAX=1
    fetch_referenced_context "#7 then #12"
    [ -f "$(_refs_dir)/7.md" ]
    [ ! -e "$(_refs_dir)/12.md" ]
}

@test "references: AGENT_CONTEXT_REFS_MAX=0 turns the pre-fetch off" {
    _setup_refs
    export AGENT_CONTEXT_REFS_MAX=0
    fetch_referenced_context "#7"
    [ ! -e "${TEST_TEMP_DIR}/gh_calls" ]
}

@test "references: a failed fetch is skipped and never fails the dispatch" {
    _setup_refs
    run fetch_referenced_context "#404 and #7"
    assert_success
    [ ! -e "$(_refs_dir)/404.md" ]
    [ -f "$(_refs_dir)/7.md" ]
}

@test "references: the phase launch does not remove fetched references" {
    _setup_refs
    fetch_referenced_context "#7"
    write_phase_context
    [ -f "$(_refs_dir)/7.md" ]
}

@test "references: every handler that reads an issue or pull request pre-fetches" {
    [ "$(grep -c '^    fetch_referenced_context ' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")" -ge 5 ]
}
