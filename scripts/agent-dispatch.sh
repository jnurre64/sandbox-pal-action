#!/bin/bash
# shellcheck disable=SC1091  # Sourced files are resolved at runtime
set -euo pipefail

# ─── Resolve script directory (for sourcing lib/ and prompts/) ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Ensure tools are in PATH ───────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export PATH="$HOME/.local/bin:$PATH"

# Allow claude -p to run even if called from within a Claude Code session
unset CLAUDECODE 2>/dev/null || true

# ─── Arguments ──────────────────────────────────────────────────
EVENT_TYPE="${1:?Usage: agent-dispatch.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"  # Issue or PR number

# ─── Load configuration ─────────────────────────────────────────
# Source project-specific config if it exists
AGENT_CONFIG="${AGENT_CONFIG:-$HOME/agent-infra/config.env}"
if [ -f "$AGENT_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$AGENT_CONFIG"
    # Resolve config directory for relative prompt paths
    CONFIG_DIR="$(cd "$(dirname "$AGENT_CONFIG")" && pwd)"
    export CONFIG_DIR
fi

# Source defaults (fills in anything not set by config.env)
# shellcheck source=lib/defaults.sh
source "${SCRIPT_DIR}/lib/defaults.sh"

# Enable high effort extended thinking for all agent runs
export CLAUDE_CODE_EFFORT_LEVEL="${AGENT_EFFORT_LEVEL}"

# ─── Derived values ─────────────────────────────────────────────
REPO_NAME=$(basename "$REPO")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)  # Used in sourced lib/common.sh for log filenames
export TIMESTAMP

# Per-runner isolation: RUNNER_NAME is set by GitHub Actions
RUNNER="${RUNNER_NAME:-default}"
REPO_DIR="$HOME/repos/${RUNNER}/${REPO_NAME}"
WORKTREE_BASE="$HOME/.claude/worktrees/${RUNNER}"
BRANCH_NAME="agent/issue-${NUMBER}"
WORKTREE_DIR="$WORKTREE_BASE/${REPO_NAME}-issue-${NUMBER}"

mkdir -p "$AGENT_LOG_DIR" "$WORKTREE_BASE"

# ─── Source library modules ──────────────────────────────────────
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/worktree.sh
source "${SCRIPT_DIR}/lib/worktree.sh"
# shellcheck source=lib/data-fetch.sh
source "${SCRIPT_DIR}/lib/data-fetch.sh"
# shellcheck source=lib/notify.sh
source "${SCRIPT_DIR}/lib/notify.sh"

# ═══════════════════════════════════════════════════════════════
# EVENT: New issue labeled "agent" → Triage + Plan (no implementation)
# ═══════════════════════════════════════════════════════════════
handle_new_issue() {
    log "Triaging issue (plan-only mode)..."
    detect_label_tools  # Check for label-based tool extensions before set_label strips them
    set_label "agent:triage"
    check_circuit_breaker
    ensure_repo
    setup_worktree

    # Fetch issue details
    local issue_json
    issue_json=$(gh issue view "$NUMBER" --repo "$REPO" --json title,body,comments)
    local issue_title issue_body comments
    issue_title=$(echo "$issue_json" | jq -r '.title')
    issue_body=$(echo "$issue_json" | jq -r '.body')
    comments=$(echo "$issue_json" | jq -r '.comments[] | "[\(.author.login)] \(.body)"' | tail -20)

    # Pass issue content via env to avoid shell injection
    export AGENT_ISSUE_TITLE="$issue_title"
    export AGENT_ISSUE_BODY="$issue_body"
    export AGENT_COMMENTS="$comments"

    mkdir -p "${WORKTREE_DIR}/.agent-data"

    local prompt
    prompt=$(load_prompt "triage" "$AGENT_PROMPT_TRIAGE")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Triage result: $claude_output"

    # Parse the action
    local triage_json action
    set +e
    triage_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
    if [ -z "$triage_json" ]; then
        triage_json="$claude_output"
    fi
    action=$(echo "$triage_json" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    if [ "$action" = "ask_questions" ]; then
        local questions
        questions=$(echo "$triage_json" | jq -r '.questions[]' 2>/dev/null | sed 's/^/- /')

        gh issue comment "$NUMBER" --repo "$REPO" --body "I have some questions before I can start working on this:

${questions}

I'll begin planning once these are answered." 2>/dev/null || true

        set_label "agent:needs-info"
        notify "questions_asked" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "$questions"
        log "Asked clarifying questions. Waiting for human reply."
        cleanup_worktree
    elif [ "$action" = "plan_ready" ]; then
        log "Plan written. Posting to issue..."

        local plan_file="${WORKTREE_DIR}/.agent-data/plan.md"
        if [ -f "$plan_file" ]; then
            local plan_content
            plan_content=$(cat "$plan_file")

            gh issue comment "$NUMBER" --repo "$REPO" --body "<!-- agent-plan -->
${plan_content}

---
*Add the \`agent:plan-approved\` label to start implementation, or comment with feedback.*" 2>/dev/null || true

            set_label "agent:plan-review"
            notify "plan_posted" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "${plan_content:0:1000}"
            log "Plan posted. Awaiting human approval."
        else
            log "Claude reported plan_ready but no plan file found."
            set_label "agent:failed"
            notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Plan file not found"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent created a plan but failed to write it to the expected file. Please re-label with \`agent\` to retry." 2>/dev/null || true
            cleanup_worktree
        fi
        # NOTE: worktree is intentionally NOT cleaned up — the implement phase reuses it
    else
        log "Could not parse triage response. Marking as failed."
        log "Raw output: $claude_output"
        set_label "agent:failed"
        notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Could not parse triage response"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent could not analyze this issue. Please review and re-label with \`agent\` to retry." 2>/dev/null || true
        cleanup_worktree
    fi
}

# ═══════════════════════════════════════════════════════════════
# EVENT: Human replied to agent question → Check and resume
# ═══════════════════════════════════════════════════════════════
handle_issue_reply() {
    log "Human replied. Checking context..."
    detect_label_tools  # Check for label-based tool extensions
    check_circuit_breaker
    ensure_repo

    # Determine which state we're in
    local labels
    labels=$(gh issue view "$NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null)
    local in_plan_review=false
    if echo "$labels" | grep -q "agent:plan-review"; then
        in_plan_review=true
        log "Human commented during plan review. Re-triaging with feedback..."
    elif ! echo "$labels" | grep -q "agent:needs-info"; then
        log "Issue does not have agent:needs-info or agent:plan-review label. Skipping."
        exit 0
    fi

    # If in plan-review, re-triage to incorporate feedback into an updated plan
    if [ "$in_plan_review" = true ]; then
        handle_new_issue
        return
    fi

    setup_worktree

    # Fetch full conversation
    local issue_json
    issue_json=$(gh issue view "$NUMBER" --repo "$REPO" --json title,body,comments)
    local issue_title issue_body comments
    issue_title=$(echo "$issue_json" | jq -r '.title')
    issue_body=$(echo "$issue_json" | jq -r '.body')
    comments=$(echo "$issue_json" | jq -r '.comments[] | "[\(.author.login)] \(.body)"' | tail -20)

    export AGENT_ISSUE_TITLE="$issue_title"
    export AGENT_ISSUE_BODY="$issue_body"
    export AGENT_COMMENTS="$comments"

    local prompt
    prompt=$(load_prompt "reply" "$AGENT_PROMPT_REPLY")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE")
    local claude_output
    claude_output=$(parse_claude_output "$result")

    local triage_json action
    triage_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
    if [ -z "$triage_json" ]; then
        triage_json="$claude_output"
    fi
    action=$(echo "$triage_json" | jq -r '.action // empty' 2>/dev/null || echo "")

    if [ "$action" = "ask_questions" ]; then
        local questions
        questions=$(echo "$triage_json" | jq -r '.questions[]' 2>/dev/null | sed 's/^/- /')
        gh issue comment "$NUMBER" --repo "$REPO" --body "Thanks for the reply! I have a few more questions:

${questions}" 2>/dev/null || true
        log "Asked follow-up questions."
    elif [ "$action" = "implement" ]; then
        set_label "agent:ready"
        log "All questions answered. Posting plan..."
        # Re-triage to generate a plan now that questions are answered
        handle_new_issue
        return
    else
        log "Could not parse reply-check response. Marking as failed."
        set_label "agent:failed"
    fi

    cleanup_worktree
}

# ═══════════════════════════════════════════════════════════════
# EVENT: Plan approved → Implement with TDD + pre-PR test gate
# ═══════════════════════════════════════════════════════════════
handle_implement() {
    log "Starting implementation of approved plan..."
    detect_label_tools  # Check for label-based tool extensions before set_label strips them
    set_label "agent:in-progress"
    check_circuit_breaker
    ensure_repo

    # Reuse existing worktree from plan phase, or create fresh one
    if [ -d "$WORKTREE_DIR" ]; then
        log "Reusing existing worktree at $WORKTREE_DIR"
        git -C "$WORKTREE_DIR" fetch origin main 2>/dev/null || true
        git -C "$WORKTREE_DIR" merge origin/main --no-edit 2>/dev/null || true
    else
        log "No existing worktree found. Creating fresh one."
        setup_worktree
    fi

    # Compare against origin/main (not HEAD) to detect ALL implementation commits,
    # including ones from previous failed runs that were retried on the same worktree.
    local start_sha
    start_sha=$(git -C "$WORKTREE_DIR" rev-parse origin/main 2>/dev/null || echo "")

    # Fetch issue details
    local issue_json
    issue_json=$(gh issue view "$NUMBER" --repo "$REPO" --json title,body,comments)
    local issue_title issue_body
    issue_title=$(echo "$issue_json" | jq -r '.title')
    notify "implement_started" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation starting"
    issue_body=$(echo "$issue_json" | jq -r '.body')

    # Find the approved plan from issue comments
    local plan_content
    plan_content=$(echo "$issue_json" | jq -r '
        [.comments[] | select(.body | test("<!-- agent-plan -->"))] | last | .body // ""
    ' 2>/dev/null)

    if [ -z "$plan_content" ]; then
        log "Could not find plan comment on issue. Marking as failed."
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent could not find the approved plan comment. Expected a comment with \`<!-- agent-plan -->\` marker. Please re-run the plan phase by labeling with \`agent\`." 2>/dev/null || true
        cleanup_worktree
        return
    fi

    local comments
    comments=$(echo "$issue_json" | jq -r '.comments[] | "[\(.author.login)] \(.body)"' | tail -20)

    # Extract debug data from issue comments
    local issue_comments_json
    issue_comments_json=$(echo "$issue_json" | jq '.comments' 2>/dev/null || echo "[]")
    local data_dir="${WORKTREE_DIR}/.agent-data"
    log "Extracting debug data from issue comments and body..."
    set +e
    extract_debug_data "$issue_comments_json" "$data_dir" "$issue_body"
    set -e

    export AGENT_ISSUE_TITLE="$issue_title"
    export AGENT_ISSUE_BODY="$issue_body"
    export AGENT_COMMENTS="$comments"
    export AGENT_ISSUE_NUMBER="$NUMBER"
    export AGENT_PLAN_CONTENT="$plan_content"
    export AGENT_DATA_COMMENT_FILE="${EXTRACTED_DATA_COMMENT_FILE:-}"
    export AGENT_GIST_FILES="${EXTRACTED_GIST_FILES:-}"
    export AGENT_DATA_ERRORS="${EXTRACTED_DATA_ERRORS:-}"

    local prompt
    prompt=$(load_prompt "implement" "$AGENT_PROMPT_IMPLEMENT")

    local impl_tools
    impl_tools=$(get_implementation_tools)

    local result
    result=$(run_claude "$prompt" "$impl_tools")

    log "Raw claude output length: ${#result}"
    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Implementation output: ${claude_output:0:500}"

    handle_post_implementation "$start_sha" "$issue_title" "$claude_output"
    cleanup_worktree
}

# ═══════════════════════════════════════════════════════════════
# EVENT: PR review with changes requested → Address feedback
# ═══════════════════════════════════════════════════════════════
handle_pr_review() {
    local pr_number="$NUMBER"
    log "Addressing PR review feedback..."
    check_circuit_breaker
    ensure_repo

    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$REPO" --json number,title,body,headRefName,comments,reviews)
    local branch
    branch=$(echo "$pr_json" | jq -r '.headRefName')
    local pr_title
    pr_title=$(echo "$pr_json" | jq -r '.title')
    notify "review_feedback" "$pr_title" "https://github.com/${REPO}/pull/${pr_number}" "Review feedback received, addressing changes"

    # Extract issue number from branch name (agent/issue-N)
    local issue_num
    issue_num=$(echo "$branch" | grep -oP 'issue-\K\d+' || echo "$pr_number")

    # Check label-based tool extensions from the linked issue
    detect_label_tools "$issue_num"

    # Update label on the linked issue
    NUMBER="$issue_num"
    set_label "agent:revision"
    NUMBER="$pr_number"

    local reviews
    reviews=$(echo "$pr_json" | jq -r '.reviews[] | "[\(.author.login)] (\(.state)): \(.body // "no comment")"' | tail -20)

    local review_comments
    review_comments=$(gh api "/repos/${REPO}/pulls/${pr_number}/comments" \
        --jq '.[] | "[\(.user.login)] on \(.path):\(.line // .original_line // "?"): \(.body)"' 2>/dev/null | tail -30)

    local pr_comments
    pr_comments=$(echo "$pr_json" | jq -r '.comments[] | "[\(.author.login)]: \(.body)"' | tail -20)

    local pr_body
    pr_body=$(echo "$pr_json" | jq -r '.body // ""')

    local pr_comments_json
    pr_comments_json=$(echo "$pr_json" | jq '.comments' 2>/dev/null || echo "[]")

    # Get the original issue context
    local issue_title="" issue_body=""
    if [ "$issue_num" != "$pr_number" ]; then
        local issue_json
        issue_json=$(gh issue view "$issue_num" --repo "$REPO" --json title,body 2>/dev/null || echo "{}")
        issue_title=$(echo "$issue_json" | jq -r '.title // ""')
        issue_body=$(echo "$issue_json" | jq -r '.body // ""')
    fi

    # Set up worktree from PR branch (BRANCH_NAME used by lib/worktree.sh)
    # shellcheck disable=SC2034
    BRANCH_NAME="$branch"
    WORKTREE_DIR="$WORKTREE_BASE/${REPO_NAME}-pr-${pr_number}"
    if [ -d "$WORKTREE_DIR" ]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    fi
    git -C "$REPO_DIR" fetch origin "$branch" 2>/dev/null || true
    git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -B "$branch" "origin/$branch"

    local start_sha
    start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

    local commit_history
    commit_history=$(git -C "$WORKTREE_DIR" log --oneline origin/main..HEAD 2>/dev/null | head -30)

    # Extract debug data from PR comments
    local data_dir="${WORKTREE_DIR}/.agent-data"
    log "Extracting debug data from PR comments and body..."
    set +e
    extract_debug_data "$pr_comments_json" "$data_dir" "$pr_body"
    set -e

    export AGENT_PR_TITLE="$pr_title"
    export AGENT_PR_BODY="$pr_body"
    export AGENT_REVIEWS="$reviews"
    export AGENT_REVIEW_COMMENTS="$review_comments"
    export AGENT_PR_COMMENTS="$pr_comments"
    export AGENT_ISSUE_TITLE="$issue_title"
    export AGENT_ISSUE_BODY="$issue_body"
    export AGENT_COMMIT_HISTORY="$commit_history"
    export AGENT_DATA_COMMENT_FILE="${EXTRACTED_DATA_COMMENT_FILE:-}"
    export AGENT_GIST_FILES="${EXTRACTED_GIST_FILES:-}"
    export AGENT_DATA_ERRORS="${EXTRACTED_DATA_ERRORS:-}"

    local prompt
    prompt=$(load_prompt "review" "$AGENT_PROMPT_REVIEW")

    local pr_tools
    pr_tools=$(get_implementation_tools)

    local result
    result=$(run_claude "$prompt" "$pr_tools")

    log "PR review raw output length: ${#result}"
    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "PR review output: ${claude_output:0:500}"

    # Push if new commits
    local new_commits
    if [ -n "$start_sha" ]; then
        new_commits=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
    else
        new_commits=$(git -C "$WORKTREE_DIR" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo "0")
    fi
    log "Commit check: $new_commits new commit(s) on $branch"

    if [ "$new_commits" -gt 0 ]; then
        git -C "$WORKTREE_DIR" push origin "$branch" 2>&1 | tee -a "$AGENT_LOG_DIR/agent-dispatch.log" || true
        gh issue edit "$issue_num" --repo "$REPO" --remove-label "agent:revision" --add-label "agent:pr-open" 2>/dev/null || true
        log "Pushed $new_commits review fix commit(s)."
    else
        gh pr comment "$pr_number" --repo "$REPO" \
            --body "I reviewed the feedback but wasn't able to make changes. Here's what I found:

${claude_output:0:2000}

You may need to provide more specific guidance or handle this manually." 2>/dev/null || true
        log "No commits made for review feedback."
    fi

    git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Dispatch based on event type
# ═══════════════════════════════════════════════════════════════
case "$EVENT_TYPE" in
    new_issue)
        handle_new_issue
        ;;
    implement)
        handle_implement
        ;;
    issue_reply)
        handle_issue_reply
        ;;
    pr_review)
        handle_pr_review
        ;;
    *)
        log "Unknown event type: $EVENT_TYPE"
        exit 1
        ;;
esac

log "Dispatch complete."
