#!/bin/bash
# ─── Review gates: adversarial plan review + post-implementation review ──
# Provides: run_adversarial_plan_review, run_test_gate, run_post_impl_review, run_post_impl_retry_session, run_post_impl_review_loop, ledger helpers

# ─── JSON extraction helper ─────────────────────────────────────
# Claude sometimes prefixes a narrative preamble or wraps the JSON in
# a markdown fence even when told not to. Extract the last balanced
# {...} block so jq-based field lookups still work.
#
# Strategy: try parsing the whole text first (cheap path for compliant
# responses); on failure, walk the text with awk, tracking brace depth,
# and emit the last top-level object. Limitation: literal braces inside
# quoted string values can fool the depth counter. The review gate
# schemas (action/concerns/questions/corrections) use simple scalars and
# string arrays, so this is acceptable in practice.
_extract_review_json() {
    local text="$1"
    local whole_action
    set +e
    whole_action=$(printf '%s' "$text" | jq -r '.action // empty' 2>/dev/null)
    set -e
    if [ -n "$whole_action" ]; then
        printf '%s' "$text"
        return 0
    fi

    printf '%s' "$text" | awk '
        BEGIN { depth = 0; in_obj = 0; buf = ""; last = "" }
        {
            line = $0
            n = length(line)
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "{") {
                    if (depth == 0) { buf = ""; in_obj = 1 }
                    depth++
                }
                if (in_obj) buf = buf c
                if (c == "}") {
                    if (depth > 0) depth--
                    if (depth == 0 && in_obj) {
                        last = buf
                        in_obj = 0
                        buf = ""
                    }
                }
            }
            if (in_obj) buf = buf "\n"
        }
        END { if (last != "") print last }
    '
}

# ─── Review ledger ──────────────────────────────────────────────
# A structured findings file that rides the work branch across review
# cycles. Path: ${WORKTREE_DIR}/.agent-data/review-ledger.json
# Schema: {"issue": N, "cycles": N, "findings": [{"id","severity","description","status","justification"}]}
#   severity: "blocking" | "non-blocking"
#   status:   "open" | "fixed" | "rejected"
LEDGER_FILE=""

_ledger_init() {
    LEDGER_FILE="${WORKTREE_DIR}/.agent-data/review-ledger.json"
    mkdir -p "$(dirname "$LEDGER_FILE")"
    local current_issue="${NUMBER:-}"
    if [ -f "$LEDGER_FILE" ] && jq -e '.findings' "$LEDGER_FILE" >/dev/null 2>&1; then
        # The ledger rides the work branch, so a branch cut after a merge
        # inherits the previous PR's ledger. One stamped with another issue,
        # or with no stamp at all, is a stale leftover — not history.
        if jq -e --arg n "$current_issue" \
            '.issue != null and (.issue | tostring) == $n' "$LEDGER_FILE" >/dev/null 2>&1; then
            return 0
        fi
        log "Discarding stale review ledger (stamped: $(jq -r '.issue // "unstamped"' "$LEDGER_FILE"); current issue: ${current_issue:-unset})"
    fi
    jq -n --arg issue "$current_issue" \
        '{issue: ($issue | tonumber? // $issue), cycles: 0, findings: []}' > "$LEDGER_FILE"
}

# Merge one review pass's parsed JSON output into the ledger.
# $1 = {"action":..., "verified_fixed":["F1"], "reopened":["F2"], "findings":[{"severity","description"}]}
_ledger_merge_review() {
    local review_json="$1"
    local tmp="${LEDGER_FILE}.tmp"
    jq --argjson r "$review_json" '
        .cycles += 1
        | .findings |= map(
            .id as $id
            | if ((($r.verified_fixed // []) | index($id)) != null) and .status == "open"
              then .status = "fixed"
              elif ((($r.reopened // []) | index($id)) != null)
              then .status = "open"
              else . end)
        | (.findings | length) as $base
        | .findings += ((($r.findings // []) | to_entries) | map(
            {id: ("F" + (($base + .key + 1) | tostring)),
             severity: (if .value.severity == "blocking" then "blocking" else "non-blocking" end),
             description: (.value.description // ""),
             status: "open",
             justification: ""}))
    ' "$LEDGER_FILE" > "$tmp" && mv "$tmp" "$LEDGER_FILE"
}

# Apply a retry session's dispositions to open findings.
# $1 = [{"id":"F1","status":"fixed"|"rejected","note":"..."}]
_ledger_apply_dispositions() {
    local dispositions_json="$1"
    local tmp="${LEDGER_FILE}.tmp"
    jq --argjson d "$dispositions_json" '
        .findings |= map(
            .id as $id
            | ((($d // []) | map(select(.id == $id))) | first) as $m
            | if $m != null and .status == "open"
                   and ($m.status == "fixed" or $m.status == "rejected")
              then . + {status: $m.status, justification: ($m.note // "")}
              else . end)
    ' "$LEDGER_FILE" > "$tmp" && mv "$tmp" "$LEDGER_FILE"
}

_ledger_blocking_open_count() {
    jq -r '[.findings[] | select(.severity == "blocking" and .status == "open")] | length' "$LEDGER_FILE"
}

_ledger_pr_summary() {
    jq -r '
        "**Review cycles:** \(.cycles)\n\n" +
        (if (.findings | length) == 0
         then "_No findings recorded._"
         else ([.findings[] |
            "- **\(.id)** [\(.severity) / \(.status)]: \(.description)"
            + (if (.justification // "") != "" then "\n  - justification: \(.justification)" else "" end)]
            | join("\n"))
         end)
    ' "$LEDGER_FILE"
}

_ledger_outstanding_summary() {
    jq -r '[.findings[] | select(.severity == "blocking" and .status == "open")
            | "- **\(.id)**: \(.description)"] | join("\n")' "$LEDGER_FILE"
}

# Commit ONLY the ledger file (it may sit under a gitignored .agent-data/).
# Best-effort by design (a ledger commit failure must never abort the
# review loop) — but a silent `|| true` made every failure invisible.
_ledger_commit() {
    local msg="$1"
    git -C "$WORKTREE_DIR" add -f "$LEDGER_FILE" 2>/dev/null \
        || log "WARN: ledger add failed for ${LEDGER_FILE}"
    git -C "$WORKTREE_DIR" commit -m "chore(agent): review ledger — ${msg}" -- "$LEDGER_FILE" 2>/dev/null \
        || log "WARN: ledger commit failed (${msg})"
}

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
    set_heartbeat "adversarial-plan"
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE" "$AGENT_MODEL_ADVERSARIAL_PLAN" "$AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN")
    log_permission_denials "$result" "adversarial-plan"

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Adversarial review result: ${claude_output:0:500}"

    # claude_output may be a bare JSON object, a JSON object with narrative
    # preamble/postamble, or wrapped in a markdown fence. _extract_review_json
    # returns the last balanced {...} block so jq lookups succeed in all cases.
    local json_block action
    json_block=$(get_structured_output "$result")
    [ -z "$json_block" ] && json_block=$(_extract_review_json "$claude_output")
    set +e
    action=$(printf '%s' "$json_block" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    case "$action" in
        approved)
            log "Adversarial plan review: approved"
            return 0
            ;;
        corrected)
            log "Adversarial plan review: corrections made"
            local corrections revised_plan
            corrections=$(printf '%s' "$json_block" | jq -r '.corrections[]' 2>/dev/null | sed 's/^/- /')
            revised_plan=$(printf '%s' "$json_block" | jq -r '.revised_plan // empty' 2>/dev/null)

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
            questions=$(printf '%s' "$json_block" | jq -r '.questions[]' 2>/dev/null | sed 's/^/- /')

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

# ─── Pre-PR test gate with bounded fix sessions ─────────────────
# Runs AGENT_TEST_COMMAND in the worktree. On failure, up to
# AGENT_TEST_GATE_MAX_RETRIES fresh Claude fix sessions are fed the
# failing output (AGENT_TEST_OUTPUT / AGENT_TEST_EXIT_CODE) and the
# tests are re-run after each. A fix session that produces no new
# commits ends the loop early: nothing changed, so re-running the same
# command would fail the same way (issue #73 — e.g. the test command
# itself is broken in repo config, which no in-repo fix can cure).
# On final failure the work branch is pushed (preserve_branch), the
# failure comment links it, agent:failed is set, and 1 is returned.
# Returns 0 when the gate passes or is disabled.
#
# NOTE: tests extract this function body with
# `sed -n '/^run_test_gate()/,/^}/p'` — keep any column-0 `}` out of
# the body before the function's real closing brace.
run_test_gate() {
    local impl_tools="$1"
    local issue_title="$2"

    if [ -z "$AGENT_TEST_COMMAND" ]; then
        return 0
    fi

    # Validate the cap like AGENT_POST_IMPL_REVIEW_MAX_RETRIES: a
    # non-integer would error the -ge comparison on every iteration.
    local max_retries="$AGENT_TEST_GATE_MAX_RETRIES"
    if ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
        log "WARN: AGENT_TEST_GATE_MAX_RETRIES='${max_retries}' is not a non-negative integer; using 2"
        max_retries=2
    fi

    local attempt=0 test_output test_exit stop_reason=""
    while true; do
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            log "Running test setup: $AGENT_TEST_SETUP_COMMAND"
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Test setup command exited with non-zero (continuing)"
        fi

        log "Running pre-PR test gate (attempt $((attempt + 1)))..."
        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e

        if [ "$test_exit" -eq 0 ]; then
            if [ "$attempt" -gt 0 ]; then
                log "Pre-PR test gate green after ${attempt} fix session(s)"
            fi
            return 0
        fi

        if [ "$attempt" -ge "$max_retries" ]; then
            stop_reason="fix-session cap (${max_retries}) reached"
            break
        fi

        attempt=$((attempt + 1))
        log "Pre-PR test gate failed (exit ${test_exit}); starting fix session ${attempt}/${max_retries}..."

        export AGENT_TEST_OUTPUT
        AGENT_TEST_OUTPUT=$(echo "$test_output" | tail -100)
        export AGENT_TEST_EXIT_CODE="$test_exit"

        local before_sha
        before_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

        local prompt result
        prompt=$(load_prompt "test-fix" "${AGENT_PROMPT_TEST_FIX}")
        set_heartbeat "test-fix-${attempt}"
        result=$(run_claude "$prompt" "$impl_tools" "$AGENT_MODEL_TEST_FIX")
        log_permission_denials "$result" "test-fix"
        log "Test-fix session output: $(parse_claude_output "$result" | head -c 300)"

        local after_sha
        after_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")
        if [ "$after_sha" = "$before_sha" ]; then
            stop_reason="fix session ${attempt} made no commits (failure likely not fixable from inside the repo, e.g. a broken test command in config)"
            break
        fi
    done

    log "Pre-PR test gate FAILED: ${stop_reason}"
    preserve_branch || true
    gh issue comment "$NUMBER" --repo "$REPO" \
        --body "## Test Failure (Pre-PR Gate)

Tests failed after implementation (${stop_reason}). Setting \`agent:failed\`.

**Your work is safe:** the implementation commits are pushed to the \`${BRANCH_NAME}\` branch. Re-applying \`agent:plan-approved\` resumes from that branch instead of starting over.
$(denials_report_section)

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
    set_label "agent:failed"
    notify "tests_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR test gate failed after ${attempt} fix session(s)"
    return 1
}

# ─── Gate B: Post-Implementation Review (one pass) ──────────────
# Runs a fresh Claude session reviewing the diff against issue/plan/ledger.
# Sets POST_IMPL_REVIEW_JSON (action=approved|concerns) and returns 0 on
# any parseable output; returns 1 only on parse failure (labels + comments).
POST_IMPL_REVIEW_JSON=""

run_post_impl_review() {
    if [ "${AGENT_POST_IMPL_REVIEW}" != "true" ]; then
        log "Post-implementation review: skipped (disabled)"
        POST_IMPL_REVIEW_JSON='{"action":"approved","findings":[]}'
        return 0
    fi

    log "Running post-implementation review..."
    export AGENT_REVIEW_LEDGER
    AGENT_REVIEW_LEDGER=$(cat "$LEDGER_FILE" 2>/dev/null || echo '{"cycles":0,"findings":[]}')

    local prompt
    prompt=$(load_prompt "post-impl-review" "${AGENT_PROMPT_POST_IMPL_REVIEW}")

    local result
    set_heartbeat "post-impl-review"
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE" "$AGENT_MODEL_POST_IMPL_REVIEW" "$AGENT_JSON_SCHEMA_POST_IMPL_REVIEW")
    log_permission_denials "$result" "post-impl-review"

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Post-impl review result: ${claude_output:0:500}"

    if [ "$(classify_claude_result "$result")" = "fail_fast" ]; then
        log "Post-implementation review: API error (fail-fast)"
        preserve_branch || true
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent post-implementation review hit an API error (${claude_output}). No later phase can recover this — re-dispatch once the API issue is resolved. The implementation commits are pushed to the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
        return 1
    fi

    local json_block action
    json_block=$(get_structured_output "$result")
    [ -z "$json_block" ] && json_block=$(_extract_review_json "$claude_output")
    set +e
    action=$(printf '%s' "$json_block" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    case "$action" in
        approved|concerns)
            # Legacy compatibility: a pre-ledger custom
            # AGENT_PROMPT_POST_IMPL_REVIEW override may still emit the
            # old {"action":"concerns","concerns":["..."]} schema instead
            # of the ledger-era .findings array. _ledger_merge_review only
            # reads .findings, so without this translation a legacy
            # "concerns" response would merge as zero findings and the
            # loop would declare the review clean. Map each legacy concern
            # string to a blocking finding when .findings is absent/empty.
            json_block=$(printf '%s' "$json_block" | jq -c '
                if .action == "concerns"
                   and ((.findings // []) | length) == 0
                   and ((.concerns // []) | length) > 0
                then .findings = [(.concerns // [])[] | {severity: "blocking", description: .}]
                else . end
            ' 2>/dev/null)
            POST_IMPL_REVIEW_JSON=$(printf '%s' "$json_block" | jq -c '.' 2>/dev/null)
            log "Post-implementation review: $action"
            return 0
            ;;
        *)
            # A missing structured_output with a schema configured is a
            # schema/prompt mismatch, not an agent failure — operators
            # respond to those differently (#96).
            local parse_note=""
            if [ -n "${AGENT_JSON_SCHEMA_POST_IMPL_REVIEW:-}" ]; then
                parse_note=" A structured-output schema was configured but the envelope carried no validated object — likely a schema/prompt mismatch (check AGENT_JSON_SCHEMA_POST_IMPL_REVIEW against the review prompt's output contract), not an implementation failure."
            fi
            log "Post-implementation review: could not parse response${parse_note}"
            log "Raw output: $claude_output"
            preserve_branch || true
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent post-implementation review could not parse its output.${parse_note} The implementation commits are pushed to the \`${BRANCH_NAME}\` branch — check it and create a PR manually if the implementation looks correct." 2>/dev/null || true
            return 1
            ;;
    esac
}

# ─── Gate B retry session (one fix pass) ────────────────────────
RETRY_DISPOSITIONS_JSON="[]"

run_post_impl_retry_session() {
    local impl_tools="$1"
    log "Review loop: retry session addressing open blocking findings..."

    export AGENT_REVIEW_LEDGER
    AGENT_REVIEW_LEDGER=$(cat "$LEDGER_FILE")
    # Legacy env for custom prompt overrides that predate the ledger
    export AGENT_REVIEW_CONCERNS
    AGENT_REVIEW_CONCERNS=$(jq -r '[.findings[] | select(.severity == "blocking" and .status == "open")
        | "- \(.id): \(.description)"] | join("\n")' "$LEDGER_FILE")

    local prompt
    prompt=$(load_prompt "post-impl-retry" "${AGENT_PROMPT_POST_IMPL_RETRY}")

    local result
    set_heartbeat "post-impl-retry"
    result=$(run_claude "$prompt" "$impl_tools" "$AGENT_MODEL_POST_IMPL_RETRY" "$AGENT_JSON_SCHEMA_POST_IMPL_RETRY")
    log_permission_denials "$result" "post-impl-retry"

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Retry output: ${claude_output:0:500}"

    if [ "$(classify_claude_result "$result")" = "fail_fast" ]; then
        log "Review-loop retry session: API error (fail-fast)"
        preserve_branch || true
        set_label "agent:failed"
        gh issue comment "$NUMBER" --repo "$REPO" \
            --body "Agent review-loop retry session hit an API error (${claude_output}). No later phase can recover this — re-dispatch once the API issue is resolved. The work so far is pushed to the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
        return 1
    fi

    # Re-run tests if configured (a retry must never ship a red suite)
    if [ -n "$AGENT_TEST_COMMAND" ]; then
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Test setup command exited with non-zero (continuing)"
        fi
        log "Review loop retry: re-running tests..."
        local test_output test_exit
        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e
        if [ "$test_exit" -ne 0 ]; then
            log "Review loop retry: tests failed after retry"
            preserve_branch || true
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "## Post-Implementation Review: Retry Failed

Tests failed after addressing review findings. The work (including retry commits) is pushed to the \`${BRANCH_NAME}\` branch.

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
            return 1
        fi
    fi

    local json_block action
    json_block=$(get_structured_output "$result")
    [ -z "$json_block" ] && json_block=$(_extract_review_json "$claude_output")
    set +e
    action=$(printf '%s' "$json_block" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e
    if [ "$action" = "addressed" ]; then
        RETRY_DISPOSITIONS_JSON=$(printf '%s' "$json_block" | jq -c '.dispositions // []' 2>/dev/null || echo "[]")
    else
        RETRY_DISPOSITIONS_JSON="[]"
        log "Retry session output had no parseable dispositions; findings stay open for the next review pass"
    fi
    return 0
}

# ─── Gate B: capped review loop ────────────────────────────────────
# review → (fix → review)* until no open blocking findings, capped at
# AGENT_POST_IMPL_REVIEW_MAX_RETRIES fix sessions.
# Returns: 0 = clean, 1 = hard failure (already labeled/commented),
#          2 = cap reached with blocking findings still open.
run_post_impl_review_loop() {
    local impl_tools="$1"

    if [ "${AGENT_POST_IMPL_REVIEW}" != "true" ]; then
        log "Post-implementation review loop: skipped (disabled)"
        return 0
    fi

    # A non-integer AGENT_POST_IMPL_REVIEW_MAX_RETRIES would make
    # `[ "$retries" -ge "$max_retries" ]` below error out (exit non-zero,
    # i.e. never true) on every iteration, so the cap would never trip and
    # the loop would run forever. Validate up front and fall back to the
    # documented default of 3.
    local max_retries="$AGENT_POST_IMPL_REVIEW_MAX_RETRIES"
    if ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
        log "WARN: AGENT_POST_IMPL_REVIEW_MAX_RETRIES='${max_retries}' is not a non-negative integer; using 3"
        max_retries=3
    fi

    _ledger_init
    local retries=0
    while true; do
        set_heartbeat "review-pass-$((retries + 1))"
        if ! run_post_impl_review; then
            return 1
        fi
        _ledger_merge_review "$POST_IMPL_REVIEW_JSON"
        _ledger_commit "review pass $((retries + 1))"

        local open
        open=$(_ledger_blocking_open_count)
        if [ "$open" -eq 0 ]; then
            log "Review loop: clean after $((retries + 1)) review pass(es), ${retries} retry session(s)"
            return 0
        fi

        if [ "$retries" -ge "$max_retries" ]; then
            log "Review loop: cap reached (${max_retries} retries) with ${open} open blocking finding(s)"
            return 2
        fi

        retries=$((retries + 1))
        set_heartbeat "retry-${retries}"
        if ! run_post_impl_retry_session "$impl_tools"; then
            return 1
        fi
        _ledger_apply_dispositions "$RETRY_DISPOSITIONS_JSON"
        _ledger_commit "retry ${retries} dispositions"
    done
}
