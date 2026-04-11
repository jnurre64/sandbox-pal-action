#!/bin/bash
# ─── Review gates: adversarial plan review + post-implementation review ──
# Provides: run_adversarial_plan_review, run_post_impl_review,
#           handle_post_impl_review_retry

# ─── Gate A: Adversarial Plan Review ────────────────────────────
# Runs a fresh Claude session to check the plan against the issue.
# Returns 0 to proceed, 1 to halt implementation.
# Side effects: may update AGENT_PLAN_CONTENT (if corrected),
#               may post issue comment, may set labels.
run_adversarial_plan_review() {
    if [ "${AGENT_ADVERSARIAL_PLAN_REVIEW}" != "true" ]; then
        log "Adversarial plan review: skipped (disabled)"
        return 0
    fi

    log "Running adversarial plan review..."
    local prompt
    prompt=$(load_prompt "adversarial-plan" "${AGENT_PROMPT_ADVERSARIAL_PLAN}")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Adversarial review result: ${claude_output:0:500}"

    # Parse the action from the response
    # claude_output is the result string from parse_claude_output, which may be
    # a JSON object directly, or a JSON string that needs to be decoded.
    local action
    set +e
    action=$(echo "$claude_output" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    case "$action" in
        approved)
            log "Adversarial plan review: approved"
            return 0
            ;;
        corrected)
            log "Adversarial plan review: corrections made"
            local corrections revised_plan
            corrections=$(echo "$claude_output" | jq -r '.corrections[]' 2>/dev/null | sed 's/^/- /')
            revised_plan=$(echo "$claude_output" | jq -r '.revised_plan // empty' 2>/dev/null)

            if [ -n "$revised_plan" ]; then
                export AGENT_PLAN_CONTENT="$revised_plan"
            fi

            gh issue comment "$NUMBER" --repo "$REPO" --body "<!-- agent-adversarial-review -->
## Adversarial Plan Review: Minor Corrections

The pre-implementation review found minor inconsistencies between the plan and the issue. The following corrections were applied automatically:

${corrections}

Implementation will proceed with the corrected plan." 2>/dev/null || true

            return 0
            ;;
        needs_clarification)
            log "Adversarial plan review: needs clarification"
            local questions
            questions=$(echo "$claude_output" | jq -r '.questions[]' 2>/dev/null | sed 's/^/- /')

            gh issue comment "$NUMBER" --repo "$REPO" --body "<!-- agent-adversarial-review -->
## Adversarial Plan Review: Clarification Needed

The pre-implementation review found ambiguities that need to be resolved before implementation can proceed:

${questions}

Please respond to these questions. Implementation will resume after clarification." 2>/dev/null || true

            set_label "agent:needs-info"
            return 1
            ;;
        *)
            log "Adversarial plan review: could not parse response"
            log "Raw output: $claude_output"
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent adversarial plan review could not parse its output. Please re-label with \`agent:plan-approved\` to retry." 2>/dev/null || true
            return 1
            ;;
    esac
}

# ─── Gate B: Post-Implementation Review ─────────────────────────
# Runs a fresh Claude session to check the diff against the issue/plan.
# Returns 0 to proceed, 1 if concerns found.
# Side effects: sets POST_IMPL_REVIEW_CONCERNS on failure.
POST_IMPL_REVIEW_CONCERNS=""

run_post_impl_review() {
    if [ "${AGENT_POST_IMPL_REVIEW}" != "true" ]; then
        log "Post-implementation review: skipped (disabled)"
        return 0
    fi

    log "Running post-implementation review..."
    local prompt
    prompt=$(load_prompt "post-impl-review" "${AGENT_PROMPT_POST_IMPL_REVIEW}")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Post-impl review result: ${claude_output:0:500}"

    local action
    set +e
    action=$(echo "$claude_output" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    case "$action" in
        approved)
            log "Post-implementation review: approved"
            return 0
            ;;
        concerns)
            log "Post-implementation review: concerns found"
            POST_IMPL_REVIEW_CONCERNS=$(echo "$claude_output" | jq -r '.concerns[]' 2>/dev/null | sed 's/^/- /')
            return 1
            ;;
        *)
            log "Post-implementation review: could not parse response"
            log "Raw output: $claude_output"
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent post-implementation review could not parse its output. Please check the branch and create a PR manually if the implementation looks correct." 2>/dev/null || true
            return 1
            ;;
    esac
}

# ─── Gate B Retry: Address Concerns and Re-Review ───────────────
# Called when run_post_impl_review returns 1 (concerns found).
# Runs a new implementation session to fix concerns, then re-reviews.
# Returns 0 if retry succeeds, 1 if it fails.
# Side effects: sets REVIEW_RETRY_CONCERNS, REVIEW_RETRY_COMMITS on success.
export REVIEW_RETRY_CONCERNS=""
export REVIEW_RETRY_COMMITS=""

handle_post_impl_review_retry() {
    local impl_tools="$1"

    if [ "${AGENT_POST_IMPL_REVIEW_MAX_RETRIES}" -eq 0 ]; then
        log "Post-impl review retry: disabled (MAX_RETRIES=0)"
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" --body "## Post-Implementation Review: Concerns Found

The post-implementation review identified concerns:

${POST_IMPL_REVIEW_CONCERNS}

Retries are disabled. Please review the branch manually." 2>/dev/null || true
        return 1
    fi

    log "Post-impl review retry: attempting to address concerns..."

    # Capture pre-retry state
    local retry_start_sha
    retry_start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

    # Export concerns for the retry prompt
    export AGENT_REVIEW_CONCERNS="$POST_IMPL_REVIEW_CONCERNS"

    local prompt
    prompt=$(load_prompt "post-impl-retry" "${AGENT_PROMPT_POST_IMPL_RETRY}")

    local result
    result=$(run_claude "$prompt" "$impl_tools")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Retry output: ${claude_output:0:500}"

    # Capture post-retry state
    local retry_end_sha
    retry_end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

    # Re-run tests if configured
    if [ -n "$AGENT_TEST_COMMAND" ]; then
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Test setup command exited with non-zero (continuing)"
        fi

        log "Post-impl retry: re-running tests..."
        local test_output test_exit
        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e

        if [ "$test_exit" -ne 0 ]; then
            log "Post-impl retry: tests failed after retry"
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "## Post-Implementation Review: Retry Failed

Tests failed after addressing review concerns.

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
            return 1
        fi
    fi

    # Re-run post-implementation review
    log "Post-impl retry: re-running review..."
    if run_post_impl_review; then
        log "Post-impl retry: review passed on retry"
        # Export for use by handle_post_implementation in common.sh
        export REVIEW_RETRY_CONCERNS="${AGENT_REVIEW_CONCERNS}"
        export REVIEW_RETRY_COMMITS="${retry_start_sha:0:7}..${retry_end_sha:0:7}"
        return 0
    else
        log "Post-impl retry: review still has concerns after retry"
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" --body "## Post-Implementation Review: Concerns Persist After Retry

The post-implementation review still has concerns after the agent attempted to address them.

**Original concerns:**
${AGENT_REVIEW_CONCERNS}

**Remaining concerns:**
${POST_IMPL_REVIEW_CONCERNS}

Please review the branch manually." 2>/dev/null || true
        return 1
    fi
}
