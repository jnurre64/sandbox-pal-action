# Per-Merge Agent Label Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an agent PR merges, the linked issue's `agent:*` state labels are replaced with a terminal `agent:done` label immediately and robustly; a weekly sweep catches any stragglers.

**Architecture:** Three layers. (1) A new `agent:done` label and `mark_issue_done()` helper in the label state machine (`scripts/lib/common.sh`). (2) `handle_post_merge` in `scripts/sandbox-pal-dispatch.sh` restructured so the label transition runs first — before the circuit breaker, worktree, and Claude doc-cleanup session — for **all** linked issues, ungated from `AGENT_CLEANUP_ENABLED`. (3) A new `sweep_stale_agent_labels` task in the weekly `scripts/cleanup.sh` cron as a safety net for repos without the post-merge caller wired.

**Tech Stack:** Bash (`set -euo pipefail`), `gh` CLI, `jq`, BATS-Core tests, ShellCheck.

**Spec:** `docs/superpowers/specs/2026-08-16-per-merge-label-cleanup-design.md` — read it first. Also read the GitHub issue: https://github.com/jnurre64/sandbox-pal-action/issues/74

**Branch:** `feature/74-per-merge-label-cleanup` (already pushed with this plan). PR to `main` when done, closing #74.

## Global Constraints

- All shell scripts must pass `shellcheck` with **zero warnings** (repo CLAUDE.md).
- All scripts use `set -euo pipefail`; label `gh` operations must be best-effort (`2>/dev/null || true`) so bookkeeping never kills a dispatch or the cron.
- **sed-extraction constraint:** `tests/test_dispatch_post_merge.bats` extracts `handle_post_merge` with `sed -n '/^handle_post_merge()/,/^}/p'`, and the new `tests/test_cleanup.bats` extracts `cleanup.sh` functions the same way. Function bodies must contain **no column-0 `}`** before the closing brace.
- Regression tests for the lingering-label bug are tagged `REGRESSION v1.2.0` (latest release when the bug existed).
- Run tests with: `./tests/bats/bin/bats tests/<file>.bats` (or all: `./tests/bats/bin/bats tests/`). Run `bash scripts/check-test-prereqs.sh` first if unsure about the environment.
- Commit messages follow the repo pattern `feat(#74): ...` / `fix(#74): ...` / `docs(#74): ...` / `test(#74): ...`, ending with the `Co-Authored-By: Claude` trailer used by your harness.

---

### Task 1: `agent:done` label plumbing

**Files:**
- Modify: `labels.txt` (append one line)
- Modify: `scripts/lib/common.sh:3-39` (Provides comment, `ALL_AGENT_LABELS`, new helper after `set_label`)
- Test: `tests/test_common.bats` (append at end of file)

**Interfaces:**
- Consumes: existing `set_label`/`remove_all_agent_labels` (use globals `NUMBER`, `REPO`).
- Produces: `mark_issue_done <issue-number>` — replaces all agent state labels on that issue with `agent:done`, best-effort creating the label first. Used by Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_common.bats`:

```bash
# ═══════════════════════════════════════════════════════════════
# REGRESSION: v1.2.0 — terminal agent:done label (#74)
# Closed issues kept stale agent:* state labels after PR merge.
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION v1.2.0: ALL_AGENT_LABELS includes agent:done" {
    _source_common
    local found=false
    for label in "${ALL_AGENT_LABELS[@]}"; do
        [ "$label" = "agent:done" ] && found=true
    done
    [ "$found" = "true" ]
}

@test "labels.txt: defines agent:done" {
    run grep -E '^agent:done\|' "${SCRIPTS_DIR}/../labels.txt"
    assert_success
}

@test "mark_issue_done: best-effort creates the label, then sets agent:done on the given issue" {
    _source_common
    gh() { echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"; }
    mark_issue_done "55"
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "label create agent:done"
    assert_output --partial "issue edit 55 --repo test-org/test-repo --add-label agent:done"
}

@test "mark_issue_done: strips prior state labels before adding agent:done" {
    _source_common
    gh() { echo "$@" >> "${TEST_TEMP_DIR}/gh_calls"; }
    mark_issue_done "55"
    run cat "${TEST_TEMP_DIR}/gh_calls"
    assert_output --partial "issue edit 55 --repo test-org/test-repo --remove-label agent:pr-open"
}

@test "mark_issue_done: leaves the caller's NUMBER untouched" {
    _source_common
    gh() { :; }
    NUMBER="99"
    mark_issue_done "55"
    assert_equal "$NUMBER" "99"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_common.bats`
Expected: the 5 new tests FAIL (`agent:done` not in array, no labels.txt line, `mark_issue_done: command not found`); all pre-existing tests PASS.

- [ ] **Step 3: Implement**

Append to `labels.txt` (after the `agent:review-unresolved` line):

```
agent:done|6F42C1|Agent PR merged — work complete
```

In `scripts/lib/common.sh`, add `agent:done` as the last entry of `ALL_AGENT_LABELS`:

```bash
ALL_AGENT_LABELS=(
    agent
    agent:triage
    agent:needs-info
    agent:ready
    agent:in-progress
    agent:pr-open
    agent:revision
    agent:failed
    agent:plan-review
    agent:plan-approved
    agent:implement
    agent:validating
    agent:review-unresolved
    agent:done
)
```

Add after `set_label()` (after line 39):

```bash
# Terminal transition (#74): replace all agent:* state labels on the given
# issue with agent:done. Called when an agent PR merges. The label is
# created best-effort first so repos provisioned before agent:done existed
# in labels.txt still get marked. Membership of agent:done in
# ALL_AGENT_LABELS means any later set_label (e.g. re-triage after a
# reopen) strips it naturally.
mark_issue_done() {
    local issue="$1"
    gh label create "agent:done" --color "6F42C1" \
        --description "Agent PR merged — work complete" \
        --force --repo "$REPO" 2>/dev/null || true
    (NUMBER="$issue"; set_label "agent:done")
}
```

Also update the `# Provides:` header comment at `scripts/lib/common.sh:3` to include `mark_issue_done` in the list.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_common.bats && shellcheck scripts/lib/common.sh`
Expected: all PASS, shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add labels.txt scripts/lib/common.sh tests/test_common.bats
git commit -m "feat(#74): terminal agent:done label and mark_issue_done helper"
```

---

### Task 2: Label transition first in `handle_post_merge`

**Files:**
- Modify: `scripts/sandbox-pal-dispatch.sh:726-836` (`handle_post_merge` — full function replacement below)
- Test: `tests/test_dispatch_post_merge.bats` (one test replaced, four added)

**Interfaces:**
- Consumes: `mark_issue_done <issue>` from Task 1.
- Produces: behavior change — `AGENT_CLEANUP_ENABLED=false` no longer skips label work; all `closingIssuesReferences` are transitioned. `AGENT_ISSUE_NUMBER` (exported to the cleanup prompt) stays the **first** linked issue, as today.

- [ ] **Step 1: Update and add tests**

In `tests/test_dispatch_post_merge.bats`, add below `_source_dispatch_functions` (top of file, after the harness function):

```bash
# Merged bot PR closing two issues — used by the #74 regression tests
PR_JSON_MERGED='{"title":"t","body":"b","headRefName":"agent/issue-41","mergedAt":"2026-08-01T00:00:00Z","author":{"login":"test-bot"},"closingIssuesReferences":[{"number":41},{"number":42}]}'
```

**Replace** the test `"post_merge: disabled config gate returns 0 without calling gh"` (the disabled gate now runs label work by design) with:

```bash
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
```

Add these four tests at the end of the file:

```bash
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
```

Leave the existing `"post_merge: unmerged PR is skipped"`, `"post_merge: non-bot-authored PR is skipped"`, `"defaults: ..."` and `"dispatch: ..."` tests as they are.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `./tests/bats/bin/bats tests/test_dispatch_post_merge.bats`
Expected: the replaced disabled-gate test and the three `agent:done`-asserting tests FAIL (current code returns before any label work when disabled, and only handles `closingIssuesReferences[0]` at the end). The `"no label edits"` test may already pass — that's fine, it pins the guard behavior.

- [ ] **Step 3: Replace `handle_post_merge`**

In `scripts/sandbox-pal-dispatch.sh`, keep the `NOTE` comment block (lines 717-725) about the sed-extraction constraint exactly as is. Replace the whole function body (lines 726-836) with:

```bash
handle_post_merge() {
    local pr_number="$NUMBER"
    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$REPO" --json title,body,headRefName,mergedAt,author,closingIssuesReferences)

    local merged_at pr_author branch pr_title
    merged_at=$(echo "$pr_json" | jq -r '.mergedAt // empty')
    if [ -z "$merged_at" ]; then
        log "PR #${pr_number} is not merged. Skipping cleanup."
        return 0
    fi
    pr_author=$(echo "$pr_json" | jq -r '.author.login // empty')
    if [ "$pr_author" != "$AGENT_BOT_USER" ]; then
        log "PR #${pr_number} was not authored by ${AGENT_BOT_USER}. Skipping cleanup."
        return 0
    fi
    branch=$(echo "$pr_json" | jq -r '.headRefName')
    pr_title=$(echo "$pr_json" | jq -r '.title')

    # Linked issues: all closingIssuesReferences, else branch-name conventions
    local linked_issues
    linked_issues=$(echo "$pr_json" | jq -r '.closingIssuesReferences[]?.number' 2>/dev/null || true)
    if [ -z "$linked_issues" ]; then
        linked_issues=$(echo "$branch" | sed -nE 's/.*issue-([0-9]+).*/\1/p')
    fi
    if [ -z "$linked_issues" ]; then
        linked_issues=$(echo "$branch" | sed -nE 's|^feature/([0-9]+)-.*|\1|p')
    fi

    # Terminal label transition FIRST (#74) — before the circuit breaker,
    # worktree, or Claude session can fail and strand stale state labels.
    # Deliberately NOT gated by AGENT_CLEANUP_ENABLED: that flag controls
    # the doc-cleanup session below, not label bookkeeping.
    local done_issue
    for done_issue in $linked_issues; do
        mark_issue_done "$done_issue"
        log "Issue #${done_issue}: agent state labels replaced with agent:done"
    done

    if [ "${AGENT_CLEANUP_ENABLED}" != "true" ]; then
        log "Post-merge doc cleanup: disabled (AGENT_CLEANUP_ENABLED=${AGENT_CLEANUP_ENABLED})"
        return 0
    fi

    log "Post-merge cleanup for PR #${pr_number} (branch ${branch})..."
    check_circuit_breaker
    ensure_repo

    local first_issue
    first_issue=$(echo "$linked_issues" | head -n 1)

    # Delete the merged remote branch (best-effort)
    git -C "$REPO_DIR" push origin --delete "$branch" 2>/dev/null \
        || log "WARN: could not delete remote branch $branch (may be already gone)"

    # Fresh worktree on a chore branch off latest main
    # shellcheck disable=SC2034
    BRANCH_NAME="chore/agent-cleanup-pr-${pr_number}"
    WORKTREE_DIR="$WORKTREE_BASE/${REPO_NAME}-postmerge-${pr_number}"
    setup_worktree

    local start_sha
    start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

    export AGENT_PR_TITLE="$pr_title"
    export AGENT_PR_BODY
    AGENT_PR_BODY=$(echo "$pr_json" | jq -r '.body // ""')
    export AGENT_MERGED_BRANCH="$branch"
    export AGENT_ISSUE_NUMBER="${first_issue:-}"
    export AGENT_REVIEW_LEDGER=""
    if [ -f "${WORKTREE_DIR}/.agent-data/review-ledger.json" ]; then
        AGENT_REVIEW_LEDGER=$(cat "${WORKTREE_DIR}/.agent-data/review-ledger.json")
    fi

    local prompt
    prompt=$(load_prompt "cleanup" "$AGENT_PROMPT_CLEANUP")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_CLEANUP" "$AGENT_MODEL_CLEANUP")
    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Cleanup output: ${claude_output:0:500}"

    # Follow-up issues from the session's structured output
    local json_block fu_count i=0
    json_block=$(_extract_review_json "$claude_output")
    set +e
    fu_count=$(printf '%s' "$json_block" | jq -r '(.follow_up_issues // []) | length' 2>/dev/null)
    set -e
    [ -z "$fu_count" ] && fu_count=0
    while [ "$i" -lt "$fu_count" ]; do
        local fu_title fu_body
        fu_title=$(printf '%s' "$json_block" | jq -r ".follow_up_issues[$i].title")
        fu_body=$(printf '%s' "$json_block" | jq -r ".follow_up_issues[$i].body")
        gh issue create --repo "$REPO" --title "$fu_title" --body "${fu_body}

---
_Filed automatically by the post-merge cleanup of PR #${pr_number}._" 2>/dev/null \
            || log "WARN: follow-up issue creation failed: $fu_title"
        i=$((i + 1))
    done

    # Push doc commits directly to main; fall back to a chore PR on failure
    local commit_count
    commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
    if [ "$commit_count" -gt 0 ]; then
        if ! git -C "$WORKTREE_DIR" push origin "HEAD:main" 2>/dev/null; then
            log "Direct push to main failed; opening a chore PR instead"
            git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null || true
            gh pr create --repo "$REPO" --head "$BRANCH_NAME" \
                --title "chore: post-merge cleanup for PR #${pr_number}" \
                --body "Tracking-doc updates from the automated post-merge cleanup of PR #${pr_number}." 2>/dev/null || true
        fi
    fi

    notify "cleanup_done" "$pr_title" "https://github.com/${REPO}/pull/${pr_number}" \
        "Post-merge cleanup complete (${commit_count} doc commit(s), ${fu_count} follow-up issue(s))"
    cleanup_worktree
}
```

Diff vs the old body, for review orientation: the `AGENT_CLEANUP_ENABLED` gate moved from the top to after the new label-transition block; issue resolution moved up and now collects **all** references into `linked_issues`; the old trailing `# Strip agent labels from the closed issue` block (`(NUMBER="$issue_num"; remove_all_agent_labels)`) is **deleted**; `AGENT_ISSUE_NUMBER` now comes from `first_issue`. Everything from `check_circuit_breaker` through `cleanup_worktree` is otherwise unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_dispatch_post_merge.bats && shellcheck scripts/sandbox-pal-dispatch.sh`
Expected: all PASS, shellcheck silent. Also confirm the sed constraint held:
`sed -n '/^handle_post_merge()/,/^}/p' scripts/sandbox-pal-dispatch.sh | tail -1` must print exactly `}` and the extraction must contain the `cleanup_worktree` line (i.e., the whole body was captured).

- [ ] **Step 5: Commit**

```bash
git add scripts/sandbox-pal-dispatch.sh tests/test_dispatch_post_merge.bats
git commit -m "fix(#74): transition linked issues to agent:done before the cleanup session"
```

---

### Task 3: Weekly stale-label sweep in `cleanup.sh`

**Files:**
- Modify: `scripts/cleanup.sh` (config sourcing after the Arguments section; counter init; new Task 5 function; summary section; `main()`)
- Test: Create `tests/test_cleanup.bats`

**Interfaces:**
- Consumes: `cleanup.sh`'s existing `log`, `verbose`, `audit`, `increment`, `counter`, `DRY_RUN`.
- Produces: `sweep_stale_agent_labels` (no args; reads `REPO`, `AGENT_BOT_USER`, `AGENT_STATE_LABELS`); counter `issues_relabeled`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_cleanup.bats`:

```bash
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
```

Note: `AGENT_BOT_USER=test-bot` comes from `tests/helpers/test_helper.bash` `setup()`; the mock returns issue `7` for **every** per-label `issue list` query — the function's dedup must collapse that to a single issue.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_cleanup.bats`
Expected: all FAIL (`sweep_stale_agent_labels: command not found` / empty `AGENT_STATE_LABELS`).

- [ ] **Step 3: Implement in `scripts/cleanup.sh`**

**(a)** Immediately after the Arguments block (after the `for arg ...done` loop, before `# ─── Token Configuration ───`), insert:

```bash
# ─── Agent config (optional) ────────────────────────────────────
# AGENT_BOT_USER (used by the stale-label sweep) lives in the runner's
# agent config. Absence is fine — the sweep degrades gracefully: with no
# bot user configured, any merged closing PR counts as agent work.
AGENT_CONFIG="${AGENT_CONFIG:-$HOME/agent-infra/config.env}"
if [ -f "$AGENT_CONFIG" ]; then
    # shellcheck disable=SC1090
    source "$AGENT_CONFIG"
fi
AGENT_BOT_USER="${AGENT_BOT_USER:-}"
```

**(b)** In the counter-file init block, after `echo 0 > "$COUNTER_DIR/logs_cleaned"`, add:

```bash
echo 0 > "$COUNTER_DIR/issues_relabeled"
```

**(c)** After the `cleanup_old_workflow_runs` function (before `# ─── Task 4: Log Self-Maintenance ───`), insert (renaming is not needed — keep the existing "Task 4" header for logs and use "Task 5" here, placement before it is fine):

```bash
# ─── Task 5: Stale Agent Label Sweep (#74) ─────────────────────
# Closed issues should not carry agent:* state labels. The per-merge
# post-merge handler normally replaces them with agent:done, but repos
# without the post-merge caller wired (or missed webhook deliveries,
# or manually closed issues) leak stale state. Sweep: strip agent:*
# state labels from closed issues; add agent:done only when a merged
# agent PR closed the issue.
# NOTE: tests/test_cleanup.bats extracts this function with sed — no
# column-0 `}` inside the body.

AGENT_STATE_LABELS="agent agent:triage agent:needs-info agent:ready agent:plan-review agent:plan-approved agent:in-progress agent:pr-open agent:revision agent:failed agent:implement agent:validating agent:review-unresolved"

sweep_stale_agent_labels() {
    log "INFO" "Checking closed issues with stale agent labels..."

    local stale_numbers="" label nums
    for label in $AGENT_STATE_LABELS; do
        nums=$(gh issue list --repo "$REPO" --state closed --label "$label" \
            --json number --jq '.[].number' --limit 100 2>/dev/null || true)
        stale_numbers=$(printf '%s\n%s\n' "$stale_numbers" "$nums")
    done
    stale_numbers=$(echo "$stale_numbers" | grep -E '^[0-9]+$' | sort -un || true)

    if [ -z "$stale_numbers" ]; then
        verbose "No closed issues with stale agent labels"
        return 0
    fi

    local issue_number
    while IFS= read -r issue_number; do
        # Did a merged agent PR close this issue? Then it earns agent:done.
        local closing_prs pr_num is_done="false"
        closing_prs=$(gh issue view "$issue_number" --repo "$REPO" \
            --json closedByPullRequestsReferences \
            --jq '.closedByPullRequestsReferences[]?.number' 2>/dev/null || true)
        for pr_num in $closing_prs; do
            local pr_info pr_author pr_merged
            pr_info=$(gh pr view "$pr_num" --repo "$REPO" --json author,mergedAt 2>/dev/null || echo '{}')
            pr_author=$(echo "$pr_info" | jq -r '.author.login // empty')
            pr_merged=$(echo "$pr_info" | jq -r '.mergedAt // empty')
            if [ -z "$pr_merged" ]; then
                continue
            fi
            if [ -z "$AGENT_BOT_USER" ] || [ "$pr_author" = "$AGENT_BOT_USER" ]; then
                is_done="true"
                break
            fi
        done

        if [ "$DRY_RUN" = true ]; then
            log "INFO" "[DRY RUN] Would strip stale agent labels from closed issue #${issue_number} (agent:done: ${is_done})"
        else
            for label in $AGENT_STATE_LABELS; do
                gh issue edit "$issue_number" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
            done
            if [ "$is_done" = "true" ]; then
                gh label create "agent:done" --color "6F42C1" \
                    --description "Agent PR merged — work complete" \
                    --force --repo "$REPO" 2>/dev/null || true
                gh issue edit "$issue_number" --repo "$REPO" --add-label "agent:done" 2>/dev/null || true
            fi
            log "INFO" "Stripped stale agent labels from closed issue #${issue_number} (agent:done: ${is_done})"
        fi

        audit "$(jq -nc \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson issue "$issue_number" \
            --argjson done "$([ "$is_done" = "true" ] && echo true || echo false)" \
            '{ts: $ts, action: "sweep_agent_labels", issue: $issue, agent_done: $done}')"

        increment issues_relabeled
    done <<< "$stale_numbers"
}
```

**(d)** In `print_summary`, after the `### Workflow Runs` block, add:

```
### Stale Agent Labels
- Issues relabeled: $(counter issues_relabeled)
```

**(e)** In `main()`, call `sweep_stale_agent_labels` after `cleanup_old_workflow_runs` (keep `cleanup_old_logs` last).

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_cleanup.bats && shellcheck scripts/cleanup.sh`
Expected: all PASS, shellcheck silent. Also verify extraction integrity:
`sed -n '/^sweep_stale_agent_labels()/,/^}/p' scripts/cleanup.sh | tail -1` prints exactly `}` and the extraction includes the `increment issues_relabeled` line.

- [ ] **Step 5: Commit**

```bash
git add scripts/cleanup.sh tests/test_cleanup.bats
git commit -m "feat(#74): weekly sweep strips stale agent labels from closed issues"
```

---

### Task 4: Documentation

**Files:**
- Modify: `docs/architecture.md` (label table ~line 89; state diagram ~line 42; post-merge flow ~lines 237-250)
- Modify: `docs/operations.md` (label table ~line 92; happy-path lines ~99-105)
- Modify: `docs/getting-started.md` (~line 299 and label diagram ~line 325)
- Modify: `docs/configuration.md` (`AGENT_CLEANUP_ENABLED` section ~line 231)
- Modify: `docs/troubleshooting.md` (new section)

The line numbers are anchors from investigation — re-locate by searching for the quoted text if they've drifted.

- [ ] **Step 1: architecture.md**

In the label reference table (search for `| \`agent:pr-open\` | PR created, awaiting review |`), add after the `agent:review-unresolved` row:

```markdown
| `agent:done` | Terminal: the agent's PR merged; linked issue closed and cleaned |
```

In the state diagram near line 42 (the `agent:pr-open .... PR created, awaiting review` block), add a line after `agent:pr-open`:

```
              agent:done ....... PR merged — terminal state
```

In the post-merge flow (search for `check AGENT_CLEANUP_ENABLED (skip if disabled)` around line 245), rewrite that flow so it reads, in order: guard merged+bot-author → resolve **all** linked issues → replace their state labels with `agent:done` → *then* check `AGENT_CLEANUP_ENABLED` (skip only the doc-cleanup session if disabled) → circuit breaker → worktree → Claude session → follow-up issues → doc push. Keep the surrounding formatting style of the file.

- [ ] **Step 2: operations.md**

In the label table (search for `| \`agent:pr-open\` | PR created, awaiting human review | Dispatch script |`), add:

```markdown
| `agent:done` | Terminal: agent PR merged, issue cleaned | Dispatch script / weekly sweep |
```

Update the happy path line (search for `agent:in-progress\` -> \`agent:pr-open\` -> merged`) to end with:

```
... -> `agent:pr-open` -> merged -> `agent:done`
```

- [ ] **Step 3: getting-started.md**

Line ~299: change `- The label progresses through `agent:in-progress` to `agent:pr-open`` to:

```markdown
- The label progresses through `agent:in-progress` to `agent:pr-open`, and to `agent:done` once the PR merges
```

In the label diagram (~line 325), after the `agent:pr-open       PR created, awaiting review` line's revision loop, add:

```
                agent:done          PR merged — terminal state
```

- [ ] **Step 4: configuration.md**

In the `AGENT_CLEANUP_ENABLED` section (~line 231), after the existing description/table, add:

```markdown
This flag gates only the doc-cleanup Claude session. The `agent:done` label
transition on linked issues runs for every merged agent PR regardless of
this setting — label bookkeeping is not cleanup.
```

- [ ] **Step 5: troubleshooting.md**

Add a new section (alongside the other symptom-shaped headings):

```markdown
### Closed issue still shows an agent:* state label

A closed issue carrying `agent:pr-open` (or another state label) means the
per-merge transition didn't run. Check, in order:

1. The consuming repo has a post-merge caller workflow wired to
   `sandbox-pal-post-merge.yml` (the `caller-post-merge.yml` template).
   Repos set up before this workflow existed won't have it — re-run setup
   or copy the template.
2. The merged PR was authored by the bot account (`AGENT_BOT_USER`) —
   human-authored PRs are skipped by design.
3. The `agent:done` label exists on the repo
   (`scripts/create-labels.sh <owner/repo>` provisions it; the dispatch
   also creates it best-effort on first use).

The weekly cleanup cron sweeps any stragglers: stale state labels on closed
issues are stripped, with `agent:done` applied when a merged agent PR
closed the issue.
```

- [ ] **Step 6: Commit**

```bash
git add docs/architecture.md docs/operations.md docs/getting-started.md docs/configuration.md docs/troubleshooting.md
git commit -m "docs(#74): agent:done terminal label, post-merge ordering, stale-label troubleshooting"
```

---

### Task 5: Full verification and push

- [ ] **Step 1: Full check suite**

Run: `shellcheck scripts/*.sh scripts/lib/*.sh && ./tests/bats/bin/bats tests/`
Expected: shellcheck silent; all BATS tests PASS (including every pre-existing file — the harness sources `common.sh` widely, so the `ALL_AGENT_LABELS` change must not break anything).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feature/74-per-merge-label-cleanup
```

- [ ] **Step 3: Open the PR**

```bash
gh pr create --repo jnurre64/sandbox-pal-action \
  --head feature/74-per-merge-label-cleanup \
  --title "Per-merge agent label cleanup: terminal agent:done + weekly sweep" \
  --body "Closes #74.

- New terminal \`agent:done\` label; \`mark_issue_done()\` in the label state machine
- \`handle_post_merge\` transitions **all** linked issues to \`agent:done\` first — before the circuit breaker, worktree, and Claude doc-cleanup session; \`AGENT_CLEANUP_ENABLED\` now gates only the doc session
- Weekly \`cleanup.sh\` sweep strips stale \`agent:*\` state labels from closed issues (\`agent:done\` only when a merged agent PR closed the issue)
- Docs + REGRESSION v1.2.0 BATS tests

See \`docs/superpowers/specs/2026-08-16-per-merge-label-cleanup-design.md\` for the approved design."
```

(Use `GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token)` for jnurre64 repos if the default token lacks access.)
