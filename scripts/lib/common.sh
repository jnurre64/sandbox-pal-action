#!/bin/bash
# ─── Common functions: logging, labels, circuit breaker, memory, claude runner ──
# Provides: log, set_label, remove_all_agent_labels, check_circuit_breaker,
#           load_shared_memory, detect_label_tools, get_implementation_tools,
#           load_prompt, run_claude, parse_claude_output, handle_post_implementation

# ─── Logging ─────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$EVENT_TYPE] #$NUMBER: $*" | tee -a "$AGENT_LOG_DIR/agent-dispatch.log"
}

# ─── Label state machine ────────────────────────────────────────
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
)

remove_all_agent_labels() {
    for label in "${ALL_AGENT_LABELS[@]}"; do
        gh issue edit "$NUMBER" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
    done
}

set_label() {
    remove_all_agent_labels
    gh issue edit "$NUMBER" --repo "$REPO" --add-label "$1" 2>/dev/null || true
}

# ─── Circuit breaker ────────────────────────────────────────────
check_circuit_breaker() {
    local one_hour_ago
    one_hour_ago=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
    local recent_bot_comments
    recent_bot_comments=$(gh api "/repos/${REPO}/issues/${NUMBER}/comments?since=${one_hour_ago}" \
        --jq "[.[] | select(.user.login == \"${AGENT_BOT_USER}\")] | length" 2>/dev/null || echo "0")

    if [ "$recent_bot_comments" -ge "$AGENT_CIRCUIT_BREAKER_LIMIT" ]; then
        log "CIRCUIT BREAKER: ${recent_bot_comments} bot comments in the last hour. Halting."
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent halted: too many comments in the last hour. This may indicate a loop. Please investigate and re-label with \`agent\` to retry." 2>/dev/null || true
        exit 1
    fi
}

# ─── Shared project memory ──────────────────────────────────────
load_shared_memory() {
    local mem_file="$AGENT_MEMORY_FILE"
    # Support workspace-relative paths (for committed memory files)
    if [ -n "$mem_file" ] && [ ! -f "$mem_file" ] && [ -f "${WORKTREE_DIR:-}/$mem_file" ]; then
        mem_file="$WORKTREE_DIR/$mem_file"
    fi
    if [ -n "$mem_file" ] && [ -f "$mem_file" ]; then
        echo "# Shared Project Memory (from interactive sessions)
The following memory was accumulated from working on this project. Use it for context but do NOT attempt to update memory files — only interactive sessions manage memory.

$(cat "$mem_file")"
    else
        echo ""
    fi
}

# ─── Label-based tool detection ──────────────────────────────────
# Checks issue labels and appends tools based on AGENT_LABEL_TOOLS_* config.
# Must be called BEFORE set_label() strips modifier labels.
# Sets LABEL_EXTRA_TOOLS global with any matched tools.
LABEL_EXTRA_TOOLS=""

detect_label_tools() {
    local issue_num="${1:-$NUMBER}"
    local labels
    labels=$(gh issue view "$issue_num" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
    LABEL_EXTRA_TOOLS=""

    while IFS= read -r label; do
        [ -z "$label" ] && continue
        # Sanitize label name: colons and hyphens become underscores
        local sanitized
        sanitized=$(echo "$label" | tr ':' '_' | tr '-' '_')
        local var_name="AGENT_LABEL_TOOLS_${sanitized}"
        local tools="${!var_name:-}"
        if [ -n "$tools" ]; then
            log "Label '$label' adds tools: $tools"
            if [ -n "$LABEL_EXTRA_TOOLS" ]; then
                LABEL_EXTRA_TOOLS="${LABEL_EXTRA_TOOLS},${tools}"
            else
                LABEL_EXTRA_TOOLS="$tools"
            fi
        fi
    done <<< "$labels"
}

# ─── Extra tools (project-specific + label-based) ───────────────
get_implementation_tools() {
    local tools="$AGENT_ALLOWED_TOOLS_IMPLEMENT"
    if [ -n "$AGENT_EXTRA_TOOLS" ]; then
        tools="${tools},${AGENT_EXTRA_TOOLS}"
    fi
    if [ -n "$LABEL_EXTRA_TOOLS" ]; then
        tools="${tools},${LABEL_EXTRA_TOOLS}"
    fi
    echo "$tools"
}

# ─── Load prompt from file or use default ────────────────────────
# Usage: load_prompt "triage" "$AGENT_PROMPT_TRIAGE"
# Resolves relative paths against CONFIG_DIR (where config.env lives).
# Falls back to prompts/<name>.md relative to the scripts directory.
load_prompt() {
    local prompt_name="$1"
    local custom_path="$2"
    local resolved_path=""

    # Resolve the custom path (relative paths resolved against CONFIG_DIR)
    if [ -n "$custom_path" ]; then
        if [[ "$custom_path" = /* ]]; then
            resolved_path="$custom_path"
        elif [ -n "${CONFIG_DIR:-}" ]; then
            resolved_path="${CONFIG_DIR}/${custom_path}"
        else
            resolved_path="$custom_path"
        fi
    fi

    if [ -n "$resolved_path" ] && [ -f "$resolved_path" ]; then
        cat "$resolved_path"
    elif [ -f "${SCRIPT_DIR}/../prompts/${prompt_name}.md" ]; then
        cat "${SCRIPT_DIR}/../prompts/${prompt_name}.md"
    else
        log "ERROR: No prompt found for '${prompt_name}' (checked '${resolved_path:-<not set>}' and ${SCRIPT_DIR}/../prompts/${prompt_name}.md)"
        exit 1
    fi
}

# ─── Run Claude and capture structured output ────────────────────
run_claude() {
    local prompt="$1"
    local allowed_tools="${2:-$AGENT_ALLOWED_TOOLS_IMPLEMENT}"
    local memory
    memory=$(load_shared_memory)

    cd "$WORKTREE_DIR"
    local stderr_log="$AGENT_LOG_DIR/claude-stderr-${REPO_NAME}-${NUMBER}-${TIMESTAMP}.log"
    local claude_args=(
        -p "$prompt"
        --allowedTools "$allowed_tools"
        --disallowedTools "$AGENT_DISALLOWED_TOOLS"
        --max-turns "$AGENT_MAX_TURNS"
        --output-format json
    )
    if [ -n "${AGENT_MODEL:-}" ]; then
        claude_args+=(--model "$AGENT_MODEL")
    fi
    if [ -n "$memory" ]; then
        claude_args+=(--append-system-prompt "$memory")
    fi

    timeout "$AGENT_TIMEOUT" claude "${claude_args[@]}" 2>"$stderr_log" || {
        local exit_code=$?
        log "Claude exited with code $exit_code. Stderr: $(head -20 "$stderr_log")"
        echo '{"result":"Claude timed out or errored (exit code '"$exit_code"')","error":true}'
    }
}

# ─── Parse Claude JSON output ────────────────────────────────────
# Extracts the text result from claude's --output-format json response.
parse_claude_output() {
    local result="$1"
    local claude_output
    claude_output=$(echo "$result" | jq -r '.result // .result_text // empty' 2>/dev/null)
    if [ -z "$claude_output" ]; then
        claude_output=$(echo "$result" | jq -r '.subtype // empty' 2>/dev/null)
        [ -n "$claude_output" ] && claude_output="Agent stopped: $claude_output"
    fi
    if [ -z "$claude_output" ]; then
        claude_output="$result"
    fi
    echo "$claude_output"
}

# ─── Check for new commits and handle push/PR ────────────────────
# Usage: handle_post_implementation "$start_sha" "$issue_title" "$claude_output"
handle_post_implementation() {
    local start_sha="$1"
    local issue_title="$2"
    local claude_output="$3"

    local commit_count
    if [ -n "$start_sha" ]; then
        commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
    else
        commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "origin/main..HEAD" 2>/dev/null || echo "0")
    fi

    if [ "$commit_count" -gt 0 ]; then
        # ── Pre-PR test gate ──────────────────────────────────────
        if [ -n "$AGENT_TEST_COMMAND" ]; then
            # Run optional setup command first (e.g., npm install, godot --headless --import)
            if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
                log "Running test setup: $AGENT_TEST_SETUP_COMMAND"
                (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Test setup command exited with non-zero (continuing)"
            fi

            log "Running pre-PR test gate ($commit_count commits)..."
            local test_output test_exit
            set +e
            test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
            test_exit=$?
            set -e

            if [ "$test_exit" -ne 0 ]; then
                log "Pre-PR test gate FAILED (exit code $test_exit)."
                gh issue comment "$NUMBER" --repo "$REPO" \
                    --body "## Test Failure (Pre-PR Gate)

Tests failed after implementation. Setting \`agent:failed\`.

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
                set_label "agent:failed"
                notify "tests_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR test gate failed (exit code $test_exit)"
                return 1
            fi
        fi

        notify "tests_passed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR tests passed ($commit_count commits)"

        # ── Post-implementation review (Gate B) ──────────────────
        if ! run_post_impl_review; then
            local impl_tools
            impl_tools=$(get_implementation_tools)
            if ! handle_post_impl_review_retry "$impl_tools"; then
                log "Post-implementation review halted PR creation."
                return 1
            fi
            # Update commit count after retry may have added commits
            if [ -n "$start_sha" ]; then
                commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
            fi
        fi

        log "Pushing $commit_count commit(s)..."
        git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null

        # Build PR body with commit log as fallback for sparse Claude output
        local commit_log
        commit_log=$(git -C "$WORKTREE_DIR" log --format="- %s" origin/main..HEAD 2>/dev/null | head -20)

        # Build review annotation if Gate B triggered a retry
        local review_annotation=""
        if [ -n "${REVIEW_RETRY_CONCERNS:-}" ]; then
            review_annotation="
### Post-Implementation Review

The adversarial post-implementation review identified concerns that were addressed before this PR was created:

**Concerns raised:**
${REVIEW_RETRY_CONCERNS}

**Commits addressing concerns:** ${REVIEW_RETRY_COMMITS}

"
        fi

        local pr_body="## Automated PR for #${NUMBER}

This PR was created by the Claude Code agent.

${claude_output:0:2000}
${review_annotation}
### Commits
${commit_log}

---
Please review carefully. The agent will address review feedback automatically.

Closes #${NUMBER}"

        # Create PR
        local pr_url
        pr_url=$(gh pr create --repo "$REPO" \
            --head "$BRANCH_NAME" \
            --title "Agent: ${issue_title}" \
            --body "$pr_body" 2>/dev/null || echo "FAILED")

        if [ "$pr_url" != "FAILED" ]; then
            log "PR created: $pr_url"
            notify "pr_created" "$issue_title" "$pr_url" "PR created with $commit_count commit(s)"
            set_label "agent:pr-open"
        else
            log "Failed to create PR."
            set_label "agent:failed"
            notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation complete but PR creation failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent completed implementation but failed to create a PR. Please check the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
        fi
    else
        log "No commits made. Marking as failed."
        set_label "agent:failed"
        notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "No commits made during implementation"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent attempted implementation but made no changes. This issue may need more context or may be too complex. Re-label with \`agent\` to retry.

Agent output:
\`\`\`
${claude_output:0:1000}
\`\`\`" 2>/dev/null || true
        return 1
    fi
}
