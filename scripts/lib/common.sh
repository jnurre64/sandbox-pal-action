#!/bin/bash
# ─── Common functions: logging, labels, circuit breaker, memory, claude runner ──
# Provides: log, set_label, remove_all_agent_labels, mark_issue_done,
#           check_circuit_breaker,
#           load_shared_memory, detect_label_tools, get_implementation_tools,
#           load_prompt, extract_plan_branch, redact_secrets,
#           extract_permission_denials, log_permission_denials,
#           denials_report_section, run_claude, parse_claude_output,
#           classify_claude_result, preserve_branch,
#           handle_post_implementation

# ─── Logging ─────────────────────────────────────────────────────
log() {
    # In orchestrator mode stdout is a machine contract — its final line
    # is the dispatch result JSON — so human-readable output goes to
    # stderr (and the log file) instead (#95).
    if [ "${AGENT_EXECUTION_MODE:-actions}" = "orchestrator" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$EVENT_TYPE] #$NUMBER: $*" | tee -a "$AGENT_LOG_DIR/sandbox-pal-dispatch.log" >&2
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$EVENT_TYPE] #$NUMBER: $*" | tee -a "$AGENT_LOG_DIR/sandbox-pal-dispatch.log"
    fi
}

# ─── Config provenance ───────────────────────────────────────────
# Printed once, before the first phase — the top of the run is the only
# place where the printed values are guaranteed to be the values used,
# since a later checkout can replace config files on disk but not this
# run's in-memory values (#99). Runs for status too, so an operator can
# ask what the harness WOULD use without paying for a dispatch.
log_config_provenance() {
    local defaults_src="(none)" overrides_src="(none)"
    [ -n "${AGENT_DEFAULTS:-}" ] && defaults_src="$AGENT_DEFAULTS"
    if [ -n "${AGENT_CONFIG:-}" ]; then
        overrides_src="$AGENT_CONFIG"
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/../config.env" ]; then
        overrides_src="${SCRIPT_DIR}/../config.env"
    fi
    log "Config: defaults=${defaults_src} overrides=${overrides_src} mode=${AGENT_EXECUTION_MODE:-actions}"
    local overwritten=""
    if declare -F agent_config_overwrite_report >/dev/null; then
        overwritten=$(agent_config_overwrite_report)
    fi
    if [ -n "$overwritten" ]; then
        # shellcheck disable=SC2016 # The assignment form is shown literally.
        log "WARN: config overwrote exported environment: ${overwritten}. The file's value is in use. To let the environment win, write the assignment as "'VAR="${VAR:-default}"'"."
    fi
    log "Models: default=${AGENT_MODEL:-cli-default} triage=${AGENT_MODEL_TRIAGE:-} implement=${AGENT_MODEL_IMPLEMENT:-} review=${AGENT_MODEL_REVIEW:-} cleanup=${AGENT_MODEL_CLEANUP:-} adversarial-plan=${AGENT_MODEL_ADVERSARIAL_PLAN:-} test-fix=${AGENT_MODEL_TEST_FIX:-} post-impl-review=${AGENT_MODEL_POST_IMPL_REVIEW:-} post-impl-retry=${AGENT_MODEL_POST_IMPL_RETRY:-}"
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
    agent:review-unresolved
    agent:done
)

remove_all_agent_labels() {
    for label in "${ALL_AGENT_LABELS[@]}"; do
        gh issue edit "$NUMBER" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
    done
}

set_label() {
    # The last agent label set is the best outcome summary a dispatch
    # has — record it for the last-dispatch liveness record (#94).
    # shellcheck disable=SC2034  # read by liveness.sh's write_last_dispatch
    DISPATCH_OUTCOME="$1"
    remove_all_agent_labels
    gh issue edit "$NUMBER" --repo "$REPO" --add-label "$1" 2>/dev/null || true
}

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
    # Save/restore NUMBER rather than a subshell so shellcheck's
    # SC2030/SC2031 subshell-modification warnings don't fire on every
    # later use of NUMBER in this file. set_label is all-best-effort, so
    # the restore below always runs.
    local saved_number="${NUMBER-}"
    NUMBER="$issue"
    set_label "agent:done"
    NUMBER="$saved_number"
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
# Resolve AGENT_MEMORY_DIR to an absolute path (workspace-relative
# supported), or empty when unset or missing.
_resolve_memory_dir() {
    local dir="${AGENT_MEMORY_DIR:-}"
    if [ -z "$dir" ]; then
        echo ""
        return 0
    fi
    if [ ! -d "$dir" ] && [ -d "${WORKTREE_DIR:-}/$dir" ]; then
        dir="$WORKTREE_DIR/$dir"
    fi
    if [ -d "$dir" ]; then
        (cd "$dir" && pwd)
    else
        echo ""
    fi
}

# A memory index alone is a table of contents for a book the agent
# cannot open — AGENT_MEMORY_DIR makes the pointed-at files readable
# too (#97). The index is still injected via --append-system-prompt;
# memory stays read-only either way.
load_shared_memory() {
    local mem_dir
    mem_dir=$(_resolve_memory_dir)
    local mem_file="$AGENT_MEMORY_FILE"
    # A memory directory's index is its MEMORY.md unless
    # AGENT_MEMORY_FILE names a different one
    if [ -z "$mem_file" ] && [ -n "$mem_dir" ] && [ -f "${mem_dir}/MEMORY.md" ]; then
        mem_file="${mem_dir}/MEMORY.md"
    fi
    # Support workspace-relative paths (for committed memory files)
    if [ -n "$mem_file" ] && [ ! -f "$mem_file" ] && [ -f "${WORKTREE_DIR:-}/$mem_file" ]; then
        mem_file="$WORKTREE_DIR/$mem_file"
    fi
    if [ -n "$mem_file" ] && [ -f "$mem_file" ]; then
        local dir_note=""
        if [ -n "$mem_dir" ]; then
            dir_note="
The index below points at files in the memory directory ${mem_dir}/ — when a pointer is relevant to your task, Read that file for the full memory. The directory is read-only to you."
        fi
        echo "# Shared Project Memory (from interactive sessions)
The following memory was accumulated from working on this project. Use it for context but do NOT attempt to update memory files — only interactive sessions manage memory.${dir_note}

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

# ─── Interactive plan branch marker ─────────────────────────────
# An interactively-authored plan comment may carry
#   <!-- agent-branch: feature/123-some-slug -->
# naming the pre-pushed feature branch the implementation must build on.
# Prints the branch name, or nothing when absent/unsafe.
#
# Plan comments are not author-filtered (anyone who can comment on the
# issue can shape this marker), so validation is deliberately strict:
# charset-safe, namespaced (so it can't redirect to `main`/`master` or
# any other un-namespaced branch), and no segment may start with `-`
# (which could be interpreted as an option by a downstream git/gh
# invocation).
extract_plan_branch() {
    local plan="$1"
    local branch
    branch=$(printf '%s' "$plan" \
        | grep -oE '<!-- agent-branch: [^ >]+ -->' | sed -n 1p \
        | sed -E 's/<!-- agent-branch: ([^ >]+) -->/\1/')

    [ -z "$branch" ] && return 0
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
    [ "$branch" = "main" ] && return 0
    [ "$branch" = "master" ] && return 0
    [[ "$branch" == */* ]] || return 0

    local seg
    IFS='/' read -ra _extract_plan_branch_segs <<< "$branch"
    for seg in "${_extract_plan_branch_segs[@]}"; do
        [[ "$seg" == -* ]] && return 0
    done

    printf '%s' "$branch"
}

# ─── Redact secrets from phase output ────────────────────────────
# stdin → stdout filter. Scrubs two match classes: well-known token
# shapes, and the literal value of every credential-looking variable in
# the process environment (which a phase inherits and can read). Deny
# rules are the first line of defence; this is the second — a denied
# command is echoed verbatim to explain the denial, which is exactly
# where a credential shows up in a log or comment.
redact_secrets() {
    local text
    text=$(cat)
    text=$(printf '%s' "$text" | sed -E \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED_TOKEN]/g' \
        -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED_TOKEN]/g' \
        -e 's/([Aa]uthorization:[[:space:]]*([Tt]oken|[Bb]earer|[Bb]asic)[[:space:]]+)[^[:space:]"'\'']+/\1[REDACTED]/g')
    local var_name var_value
    while read -r var_name; do
        case "$var_name" in
            *TOKEN*|*SECRET*|*PASSWORD*|*API_KEY*|*APIKEY*|*CREDENTIAL*)
                var_value="${!var_name-}"
                # Short values are skipped: replacing a 2-char password
                # everywhere it appears would mangle ordinary text.
                if [ "${#var_value}" -ge 8 ]; then
                    text="${text//"$var_value"/[REDACTED:${var_name}]}"
                fi
                ;;
        esac
    done < <(compgen -e)
    printf '%s\n' "$text"
}

# ─── Surface permission denials ──────────────────────────────────
# Denied tool calls are the largest silent time sink in a headless
# loop: the phase retries variants and burns its turn cap on nothing,
# looking from outside like a phase that was merely slow. Every denial
# is an allow-list gap to fix in config, not noise. (#93)

# Envelope → one line per denial: "tool_name: command|file_path|pattern"
extract_permission_denials() {
    local result="$1"
    printf '%s' "$result" | jq -r '
        (.permission_denials // [])[]
        | .tool_name + ": "
          + ((.tool_input.command // .tool_input.file_path // .tool_input.pattern // "unknown") | tostring)
    ' 2>/dev/null || true
}

# Log each denial and append it (phase-tagged) to the dispatch-scoped
# denials file, which the run summary and failure comments read.
# Call in non-captured context only — log() writes to stdout.
log_permission_denials() {
    local result="$1" phase="${2:-phase}"
    local denials
    denials=$(extract_permission_denials "$result")
    [ -z "$denials" ] && return 0
    log "WARN: ${phase}: permission denial(s) — each is an allow-list gap costing turns:"
    local line
    while IFS= read -r line; do
        log "  denied: $line"
        if [ -n "${WORKTREE_DIR:-}" ] && [ -d "$WORKTREE_DIR" ]; then
            mkdir -p "${WORKTREE_DIR}/.agent-data"
            printf '[%s] %s\n' "$phase" "$line" >> "${WORKTREE_DIR}/.agent-data/permission-denials.log"
        fi
    done <<< "$denials"
    return 0
}

# Markdown block of the run's accumulated denials, for PR bodies and
# failure comments. Empty when nothing was denied.
denials_report_section() {
    local denials_file="${WORKTREE_DIR}/.agent-data/permission-denials.log"
    [ -s "$denials_file" ] || return 0
    # shellcheck disable=SC2016  # literal markdown code fence, not an expansion
    printf '\n### Permission Denials\n\nEach denial is an allow-list gap that cost the agent turns — fix it in config (see docs/customization.md):\n\n```\n%s\n```\n' \
        "$(head -30 "$denials_file")"
}

# Runner modules are also loaded for consumers that source common.sh directly.
# shellcheck disable=SC1091  # Runtime sibling path.
source "$(dirname "${BASH_SOURCE[0]}")/agent.sh"

# Compatibility entry point for existing local callers.
run_claude() { run_agent "$@"; }

# ─── Structured output ───────────────────────────────────────────
# The schema-validated object from the envelope, compact, or empty when
# the phase ran without a schema (or the CLI predates --json-schema).
# Handlers prefer this and fall back to text extraction, so custom
# prompts and disabled schemas keep working unchanged.
get_structured_output() {
    local result="$1"
    printf '%s' "$result" \
        | jq -c 'select(.version != 1 or .status == "success") | .structured_output // empty | select(. != null)' 2>/dev/null \
        || true
}

# ─── Parse Claude JSON output ────────────────────────────────────
# Extracts the text result from claude's --output-format json response.
# `is_error` is authoritative and `subtype` is not a cause: an API-error
# envelope carries is_error:true together with subtype:"success", so the
# error check must come first and a non-error_* subtype is never
# interpolated as a reason.
parse_claude_output() {
    local result="$1"
    if [ "$(printf '%s' "$result" | jq -r '.version // empty' 2>/dev/null)" = "1" ]; then
        parse_agent_output "$result"
        return
    fi
    if [ "$(echo "$result" | jq -r '.is_error // false' 2>/dev/null)" = "true" ]; then
        local detail
        detail=$(echo "$result" | jq -r \
            '[.terminal_reason, .api_error_status, (.result // .result_text)]
             | map(select(. != null and . != "") | tostring) | join(" — ")' 2>/dev/null)
        echo "Agent phase failed: API error${detail:+ — ${detail}}"
        return 0
    fi
    local claude_output
    claude_output=$(echo "$result" | jq -r '.result // .result_text // empty' 2>/dev/null)
    if [ -z "$claude_output" ]; then
        claude_output=$(echo "$result" | jq -r '.subtype // empty' 2>/dev/null)
        case "$claude_output" in
            error_*) claude_output="Agent stopped: $claude_output" ;;
            *) claude_output="" ;;
        esac
    fi
    if [ -z "$claude_output" ]; then
        claude_output="$result"
    fi
    echo "$claude_output"
}

# ─── Classify how a phase ended ──────────────────────────────────
# fail_fast:   an API error — no later phase can recover it, so the
#              pipeline should stop rather than burn a fix-up phase.
# recoverable: a turn/budget cap or timeout — exactly what the fix-up
#              phases exist for.
# ok:          a normal ending.
classify_claude_result() {
    local result="$1"
    if [ "$(printf '%s' "$result" | jq -r '.version // empty' 2>/dev/null)" = "1" ]; then
        classify_agent_result "$result"
        return
    fi
    if [ "$(echo "$result" | jq -r '.is_error // false' 2>/dev/null)" = "true" ]; then
        echo "fail_fast"
        return 0
    fi
    local subtype
    subtype=$(echo "$result" | jq -r '.subtype // empty' 2>/dev/null || echo "")
    case "$subtype" in
        error_*) echo "recoverable" ;;
        *)
            # run_claude's synthetic timeout envelope carries .error, not .is_error
            if [ "$(echo "$result" | jq -r '.error // false' 2>/dev/null)" = "true" ]; then
                echo "recoverable"
            else
                echo "ok"
            fi
            ;;
    esac
}

# ─── Commits on the work branch ──────────────────────────────────
# Up to $1 commits that are on the work branch and not on origin/main,
# newest first, one per line in `git log` format $2. Empty when there are
# none. The limit is `-n`, never `| head`: under `set -o pipefail` a
# producer piped into head dies of SIGPIPE (exit 141) as soon as it has
# more to write than head takes (#129).
branch_commit_lines() {
    local limit="$1" format="$2"
    git -C "$WORKTREE_DIR" log --format="$format" -n "$limit" origin/main..HEAD 2>/dev/null || true
}

# ─── Preserve implementation work on the remote ──────────────────
# Best-effort push of the work branch so a controlled failure never
# strands finished commits in a worktree that the next dispatch's
# setup_worktree will delete (issue #73). setup_worktree checks out
# origin/$BRANCH_NAME when it exists, so a preserved branch turns a
# re-dispatch into a resume instead of a restart.
preserve_branch() {
    if git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null; then
        log "Preserved work branch: pushed ${BRANCH_NAME} to origin"
        return 0
    fi
    log "WARN: could not push ${BRANCH_NAME} to origin — commits remain only in the local worktree"
    return 1
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
        # Preserve finished work on the remote BEFORE any gate can fail.
        # A gate failure used to strand unpushed commits in a worktree
        # that the next dispatch's setup_worktree deletes (issue #73);
        # setup_worktree resumes from origin/$BRANCH_NAME when it exists.
        preserve_branch || true

        local impl_tools review_rc=0
        impl_tools=$(get_implementation_tools)

        # ── Pre-PR test gate (bounded fix sessions) ───────────────
        if ! run_test_gate "$impl_tools" "$issue_title"; then
            return 1
        fi

        notify "tests_passed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR tests passed ($commit_count commits)"

        # ── Post-implementation review loop (Gate B) ─────────────
        run_post_impl_review_loop "$impl_tools" || review_rc=$?
        if [ "$review_rc" -eq 1 ]; then
            log "Post-implementation review loop halted PR creation."
            return 1
        fi
        # Copy back and commit any staged rules edits (#92) before the
        # push, so they ride the PR like any other change.
        apply_rules_files

        # Retry sessions, ledger commits and rules staging may have
        # added commits
        if [ -n "$start_sha" ]; then
            commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
        fi

        log "Pushing $commit_count commit(s)..."
        git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null

        # Build PR body with commit log as fallback for sparse Claude output
        local commit_log
        commit_log=$(branch_commit_lines 20 '- %s')

        # Ledger summary for the PR body
        local ledger_summary="" unresolved_header=""
        if [ -f "${WORKTREE_DIR}/.agent-data/review-ledger.json" ]; then
            # shellcheck disable=SC2034  # read by review-gates.sh's _ledger_pr_summary/_ledger_outstanding_summary
            LEDGER_FILE="${WORKTREE_DIR}/.agent-data/review-ledger.json"
            ledger_summary="
### Adversarial Review Ledger

$(_ledger_pr_summary)
"
            if [ "$review_rc" -eq 2 ]; then
                unresolved_header="## ⚠ Review Unresolved

The adversarial review loop hit its retry cap with blocking findings still open. Do not merge before arbitrating these:

$(_ledger_outstanding_summary)

---
"
            fi
        fi

        local pr_body test_status="Not configured" review_status="Disabled"
        if [ -n "${AGENT_TEST_COMMAND:-}" ]; then
            test_status="Passed"
        fi
        if [ "${AGENT_POST_IMPL_REVIEW:-false}" = true ]; then
            review_status="Approved"
            if [ "$review_rc" -eq 2 ]; then
                review_status="Unresolved — retry limit reached; human arbitration required"
            fi
        fi
        pr_body="${unresolved_header}## Automated PR for #${NUMBER}

This PR was created by the agent pipeline.

### Dispatcher gate results

- Pre-PR tests: ${test_status}
- Post-implementation review: ${review_status}

GitHub CI is reported separately by the PR checks.

### Implementation worker report

Captured before the dispatcher ran its gates and opened this PR:

${claude_output:0:2000}
${ledger_summary}$(denials_report_section)
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
            # shellcheck disable=SC2034  # read by liveness.sh result/record
            DISPATCH_PR_URL="$pr_url"
            log "PR created: $pr_url"
            notify "pr_created" "$issue_title" "$pr_url" "PR created with $commit_count commit(s)"
            set_label "agent:pr-open"
            if [ "$review_rc" -eq 2 ]; then
                gh issue edit "$NUMBER" --repo "$REPO" --add-label "agent:review-unresolved" 2>/dev/null || true
                gh pr edit "$pr_url" --repo "$REPO" --add-label "agent:review-unresolved" 2>/dev/null || true
                notify "review_unresolved" "$issue_title" "$pr_url" "Review loop hit its cap — blocking findings need human arbitration"
            fi
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
