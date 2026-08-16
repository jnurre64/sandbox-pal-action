#!/bin/bash
# shellcheck disable=SC1091  # Sourced files are resolved at runtime
set -euo pipefail

# ─── Resolve script directory (for sourcing lib/ and prompts/) ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Ensure tools are in PATH ───────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
export PATH="$HOME/.local/bin:${DOTNET_ROOT:-$HOME/.dotnet}:$PATH"

# Allow claude -p to run even if called from within a Claude Code session
unset CLAUDECODE 2>/dev/null || true

# ─── Arguments ──────────────────────────────────────────────────
EVENT_TYPE="${1:?Usage: sandbox-pal-dispatch.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"  # Issue or PR number

# ─── Global error trap ──────────────────────────────────────────
# Catch unexpected errors (config failures, missing tools, script bugs)
# and post a comment on the issue so failures aren't silent.
_on_unexpected_error() {
    local exit_code=$?
    local line=${1:-unknown}
    # EXIT trap fires on success too — only act on errors
    [ "$exit_code" -eq 0 ] && return 0
    # Best-effort: every command uses || true since gh/notify may be
    # unavailable (they might be the thing that's broken).
    # Capture common diagnostic context
    local diag_hints=""
    case "$exit_code" in
        127) diag_hints="**Likely cause:** A required command was not found. Check that \`claude\`, \`gh\`, \`jq\`, and project tools (e.g., \`dotnet\`, \`npm\`) are installed on the runner." ;;
        1)   diag_hints="**Likely cause:** A command or config assertion failed. Check the workflow run logs for the specific error message." ;;
        124) diag_hints="**Likely cause:** A command timed out." ;;
    esac

    gh issue comment "$NUMBER" --repo "$REPO" \
        --body "## Agent Infrastructure Error

The agent encountered an unexpected error and could not complete.

| Detail | Value |
|--------|-------|
| **Script** | \`sandbox-pal-dispatch.sh\` line $line |
| **Event** | \`$EVENT_TYPE\` |
| **Exit code** | $exit_code |
| **Runner** | ${RUNNER_NAME:-unknown} |

${diag_hints}

Check the [workflow run logs](https://github.com/${REPO}/actions) for details." 2>/dev/null || true

    # Try to set the failed label (set_label may not be loaded yet)
    if command -v set_label &>/dev/null; then
        set_label "agent:failed" 2>/dev/null || true
    else
        gh issue edit "$NUMBER" --repo "$REPO" --add-label "agent:failed" 2>/dev/null || true
    fi

    # Try to send a notification (notify may not be loaded yet)
    if command -v notify &>/dev/null; then
        notify "agent_failed" "Issue #${NUMBER}" \
            "https://github.com/${REPO}/issues/${NUMBER}" \
            "Unexpected error at line $line (exit code $exit_code)" 2>/dev/null || true
    fi
}
trap '_on_unexpected_error $LINENO' ERR
trap '_on_unexpected_error exit' EXIT

# ─── Load configuration ─────────────────────────────────────────
# Layered config: defaults (committed) → overrides (gitignored) → defaults.sh
#
# 1. config.defaults.env — committed, non-sensitive project config
# 2. config.env           — gitignored, optional sensitive overrides (GH_TOKEN, etc.)
# 3. defaults.sh          — fills in anything still unset
#
# Environment variables always take highest precedence.

# Source committed defaults first (standalone mode: .sandbox-pal-dispatch/config.defaults.env)
AGENT_DEFAULTS="${SCRIPT_DIR}/../config.defaults.env"
if [ -f "$AGENT_DEFAULTS" ]; then
    # shellcheck source=/dev/null
    source "$AGENT_DEFAULTS"
    CONFIG_DIR="$(cd "$(dirname "$AGENT_DEFAULTS")" && pwd)"
    export CONFIG_DIR
fi

# Source optional overrides (may contain secrets — never commit this file)
AGENT_CONFIG="${AGENT_CONFIG:-}"
if [ -n "$AGENT_CONFIG" ] && [ -f "$AGENT_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$AGENT_CONFIG"
    CONFIG_DIR="$(cd "$(dirname "$AGENT_CONFIG")" && pwd)"
    export CONFIG_DIR
elif [ -f "${SCRIPT_DIR}/../config.env" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/../config.env"
    CONFIG_DIR="$(cd "$(dirname "${SCRIPT_DIR}/../config.env")" && pwd)"
    export CONFIG_DIR
fi

# Source defaults (fills in anything not set by either config file)
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
# shellcheck source=lib/review-gates.sh
source "${SCRIPT_DIR}/lib/review-gates.sh"

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
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE" "$AGENT_MODEL_TRIAGE")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Triage result: $claude_output"

    # Parse the action
    local triage_json action
    set +e
    triage_json=$(echo "$claude_output" | grep -oE '[{][^{}]*"action"[^{}]*[}]' | tail -1)
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
            # Diagnose the failure
            local diag=""
            if [[ "$AGENT_ALLOWED_TOOLS_TRIAGE" != *"Write"* ]]; then
                diag="**Root cause:** The \`Write\` tool is not in \`AGENT_ALLOWED_TOOLS_TRIAGE\`. The agent needs \`Write\` to create the plan file. Add \`Write\` to the triage tool allowlist in your config."
            elif [ ! -d "${WORKTREE_DIR}/.agent-data" ]; then
                diag="**Root cause:** The \`.agent-data/\` directory does not exist in the worktree."
            else
                diag="The \`.agent-data/\` directory exists and \`Write\` is allowed, but the plan file was not created. This may be intermittent — retry by re-labeling with \`agent\`."
            fi
            set_label "agent:failed"
            notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Plan file not found"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "## Agent Error: Plan file not found

The agent reported that the plan was ready, but the expected file (\`.agent-data/plan.md\`) was not created.

${diag}

<details><summary>Diagnostic info</summary>

- **Triage tools:** \`${AGENT_ALLOWED_TOOLS_TRIAGE}\`
- **Worktree:** \`${WORKTREE_DIR}\`
- **Plan file path:** \`${plan_file}\`
</details>" 2>/dev/null || true
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

    # Check if this issue entered via direct implement
    local issue_json_check
    issue_json_check=$(gh issue view "$NUMBER" --repo "$REPO" --json comments --jq '
        [.comments[] | select(.body | test("<!-- agent-direct-implement -->"))] | length
    ' 2>/dev/null || echo "0")

    if [ "$issue_json_check" -gt 0 ]; then
        log "Issue entered via direct implement. Re-running validation..."
        handle_direct_implement
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
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE" "$AGENT_MODEL_TRIAGE")
    local claude_output
    claude_output=$(parse_claude_output "$result")

    local triage_json action
    set +e
    triage_json=$(echo "$claude_output" | grep -oE '[{][^{}]*"action"[^{}]*[}]' | tail -1)
    if [ -z "$triage_json" ]; then
        triage_json="$claude_output"
    fi
    action=$(echo "$triage_json" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

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

    # Fetch issue details FIRST — an interactive plan comment can override
    # the branch before any worktree exists.
    local issue_json
    issue_json=$(gh issue view "$NUMBER" --repo "$REPO" --json title,body,comments)
    local issue_title issue_body
    issue_title=$(echo "$issue_json" | jq -r '.title')
    notify "implement_started" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation starting"
    issue_body=$(echo "$issue_json" | jq -r '.body')

    # Find the approved plan — use pre-loaded content (from direct implement) or extract from comments
    local plan_content
    if [ -n "${AGENT_PLAN_CONTENT:-}" ]; then
        plan_content="$AGENT_PLAN_CONTENT"
        log "Using pre-loaded plan content (direct implement)"
    else
        plan_content=$(echo "$issue_json" | jq -r '
            [.comments[] | select(.body | test("<!-- agent-plan -->"))] | last | .body // ""
        ' 2>/dev/null)

        if [ -z "$plan_content" ]; then
            log "Could not find plan comment on issue. Marking as failed."
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent could not find the approved plan comment. Expected a comment with \`<!-- agent-plan -->\` marker. Please re-run the plan phase by labeling with \`agent\`." 2>/dev/null || true
            return
        fi
    fi

    # Interactive plan branch marker (work-issue v2 on-ramp)
    local plan_branch interactive_plan=""
    plan_branch=$(extract_plan_branch "$plan_content")
    if [ -n "$plan_branch" ]; then
        log "Interactive plan branch detected: $plan_branch"
        # shellcheck disable=SC2034
        BRANCH_NAME="$plan_branch"
        interactive_plan=1
    fi

    # Worktree: reuse the plan-phase worktree only for the autonomous flow;
    # an interactive branch always gets a fresh worktree on that branch.
    if [ -z "$interactive_plan" ] && [ -d "$WORKTREE_DIR" ]; then
        log "Reusing existing worktree at $WORKTREE_DIR"
        git -C "$WORKTREE_DIR" fetch origin main 2>/dev/null || true
        git -C "$WORKTREE_DIR" merge origin/main --no-edit 2>/dev/null || true
        run_worktree_setup
    else
        if [ -d "$WORKTREE_DIR" ]; then
            git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
        fi
        log "Creating worktree for branch $BRANCH_NAME"
        setup_worktree
    fi

    # Baseline for the commit count: for interactive branches the plan/spec
    # commits already exist on the branch, so measure from the branch head.
    local start_sha
    if [ -n "$interactive_plan" ]; then
        start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")
    else
        start_sha=$(git -C "$WORKTREE_DIR" rev-parse origin/main 2>/dev/null || echo "")
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

    # ── Adversarial plan review (Gate A) ─────────────────────────
    if ! run_adversarial_plan_review; then
        log "Adversarial plan review halted implementation."
        cleanup_worktree
        return
    fi

    local prompt
    prompt=$(load_prompt "implement" "$AGENT_PROMPT_IMPLEMENT")

    local impl_tools
    impl_tools=$(get_implementation_tools)

    local result
    result=$(run_claude "$prompt" "$impl_tools" "$AGENT_MODEL_IMPLEMENT")

    log "Raw claude output length: ${#result}"
    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Implementation output: ${claude_output:0:500}"

    # handle_post_implementation returns non-zero on controlled failures
    # (test gate fail, Gate B halt, no commits made). These are already
    # reported to the issue and labeled agent:failed — we just need to
    # clean up and exit without tripping set -e and the ERR trap, which
    # would double-post an "Agent Infrastructure Error" comment.
    if ! handle_post_implementation "$start_sha" "$issue_title" "$claude_output"; then
        log "Post-implementation handler reported a controlled failure."
    fi
    cleanup_worktree
}

# ═══════════════════════════════════════════════════════════════
# EVENT: Issue labeled "agent:implement" → Validate + Implement
# ═══════════════════════════════════════════════════════════════
handle_direct_implement() {
    # Config gate
    if [ "${AGENT_ALLOW_DIRECT_IMPLEMENT:-true}" != "true" ]; then
        log "Direct implement is disabled (AGENT_ALLOW_DIRECT_IMPLEMENT=${AGENT_ALLOW_DIRECT_IMPLEMENT})"
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "The \`agent:implement\` label is not enabled for this repository. Set \`AGENT_ALLOW_DIRECT_IMPLEMENT=true\` in config to enable it, or use the standard \`agent\` label for triage." 2>/dev/null || true
        return
    fi

    log "Direct implement: validating pre-written plan..."
    detect_label_tools
    set_label "agent:validating"
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

    # Extract debug data from issue comments and body
    local issue_comments_json
    issue_comments_json=$(echo "$issue_json" | jq '.comments' 2>/dev/null || echo "[]")
    local data_dir="${WORKTREE_DIR}/.agent-data"
    mkdir -p "$data_dir"
    log "Extracting debug data from issue comments and body..."
    set +e
    extract_debug_data "$issue_comments_json" "$data_dir" "$issue_body"
    set -e

    export AGENT_ISSUE_TITLE="$issue_title"
    export AGENT_ISSUE_BODY="$issue_body"
    export AGENT_COMMENTS="$comments"
    export AGENT_DATA_COMMENT_FILE="${EXTRACTED_DATA_COMMENT_FILE:-}"
    export AGENT_GIST_FILES="${EXTRACTED_GIST_FILES:-}"
    export AGENT_DATA_ERRORS="${EXTRACTED_DATA_ERRORS:-}"

    local prompt
    prompt=$(load_prompt "validate" "$AGENT_PROMPT_VALIDATE")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE" "$AGENT_MODEL_TRIAGE")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Validation result: $claude_output"

    # Parse the action
    local validate_json action
    set +e
    validate_json=$(echo "$claude_output" | grep -oE '[{][^{}]*"action"[^{}]*[}]' | tail -1)
    if [ -z "$validate_json" ]; then
        validate_json="$claude_output"
    fi
    action=$(echo "$validate_json" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    if [ "$action" = "valid" ]; then
        log "Plan validated. Proceeding to implementation..."
        notify "validation_passed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Plan validated, starting implementation"

        # Pre-load plan content from issue body and transition to implementation
        export AGENT_PLAN_CONTENT="$issue_body"
        handle_implement
    elif [ "$action" = "issues_found" ]; then
        local issues
        issues=$(echo "$validate_json" | jq -r '.issues[]' 2>/dev/null | sed 's/^/- /')

        gh issue comment "$NUMBER" --repo "$REPO" --body "<!-- agent-direct-implement -->
## Plan Validation Issues

I found some issues while validating the implementation plan against the current codebase:

${issues}

Please update the issue to address these and re-label with \`agent:implement\` to retry." 2>/dev/null || true

        set_label "agent:needs-info"
        notify "validation_issues" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "$issues"
        log "Validation found issues. Waiting for human to address."
        cleanup_worktree
    else
        log "Could not parse validation response. Marking as failed."
        log "Raw output: $claude_output"
        set_label "agent:failed"
        notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Could not parse validation response"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent could not validate the plan. Please review and re-label with \`agent:implement\` to retry." 2>/dev/null || true
        cleanup_worktree
    fi
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
    issue_num=$(echo "$branch" | sed -nE 's/.*issue-([0-9]+).*/\1/p')
    if [ -z "$issue_num" ]; then
        issue_num="$pr_number"
    fi

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

    # Remove any existing worktree using this branch (e.g., leftover from implement phase)
    local existing_wt
    existing_wt=$(git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null | grep -B2 "branch refs/heads/$branch" | grep "^worktree " | sed 's/^worktree //' || true)
    if [ -n "$existing_wt" ] && [ -d "$existing_wt" ]; then
        log "Removing existing worktree for branch $branch at $existing_wt"
        git -C "$REPO_DIR" worktree remove "$existing_wt" --force 2>/dev/null || true
    fi

    # Also remove our target path if it exists
    if [ -d "$WORKTREE_DIR" ]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    fi

    git -C "$REPO_DIR" worktree prune 2>/dev/null || true
    git -C "$REPO_DIR" fetch origin "$branch" 2>/dev/null || true
    git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -B "$branch" "origin/$branch"
    run_worktree_setup

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
    result=$(run_claude "$prompt" "$pr_tools" "$AGENT_MODEL_REVIEW")

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
        git -C "$WORKTREE_DIR" push origin "$branch" 2>&1 | tee -a "$AGENT_LOG_DIR/sandbox-pal-dispatch.log" || true
        gh issue edit "$issue_num" --repo "$REPO" --remove-label "agent:revision" --add-label "agent:pr-open" 2>/dev/null || true
        notify "review_pushed" "$pr_title" "https://github.com/${REPO}/pull/${pr_number}" "Pushed $new_commits review fix commit(s)"
        log "Pushed $new_commits review fix commit(s)."
    else
        gh pr comment "$pr_number" --repo "$REPO" \
            --body "I reviewed the feedback but wasn't able to make changes. Here's what I found:

${claude_output:0:2000}

You may need to provide more specific guidance or handle this manually." 2>/dev/null || true
        notify "agent_failed" "$pr_title" "https://github.com/${REPO}/pull/${pr_number}" "No commits made for review feedback"
        log "No commits made for review feedback."
    fi

    git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# EVENT: Agent PR merged → post-merge cleanup phase
# ═══════════════════════════════════════════════════════════════
# NOTE: tests/test_dispatch_post_merge.bats extracts this function body
# with `sed -n '/^handle_post_merge()/,/^}/p'` (there is no bash function
# parser in the test harness). That means the body must contain NO
# column-0 `}` before the function's real closing brace — an inner
# heredoc/case/etc. that lands a `}` at column 0 would truncate the
# sed extraction and silently break those tests.
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
    direct_implement)
        handle_direct_implement
        ;;
    post_merge)
        handle_post_merge
        ;;
    *)
        log "Unknown event type: $EVENT_TYPE"
        exit 1
        ;;
esac

log "Dispatch complete."
