#!/usr/bin/env bats
# Tests for scripts/lib/review-gates.sh

load 'helpers/test_helper'

# Helper to source review-gates.sh (requires common.sh first)
_source_review_gates() {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/review-gates.sh"
}

# ═══════════════════════════════════════════════════════════════
# run_adversarial_plan_review — Gate A
# ═══════════════════════════════════════════════════════════════

@test "Gate A: skipped when AGENT_ADVERSARIAL_PLAN_REVIEW=false" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="false"
    _source_review_gates

    run run_adversarial_plan_review
    assert_success

    # run_claude should never have been called — no mock_calls file
    [ ! -f "${TEST_TEMP_DIR}/mock_calls_timeout" ]
}

@test "Gate A: approved response returns 0" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    _source_review_gates

    # Mock run_claude to return approved
    run_claude() {
        echo '{"result":"{\"action\": \"approved\"}"}'
    }

    run run_adversarial_plan_review
    assert_success
}

@test "Gate A: corrected response returns 0 and updates AGENT_PLAN_CONTENT" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Original plan"
    create_mock "gh" ""
    _source_review_gates

    # Mock run_claude to return corrected
    run_claude() {
        echo '{"result":"{\"action\": \"corrected\", \"corrections\": [\"Fixed metric\"], \"revised_plan\": \"Corrected plan\"}"}'
    }

    run_adversarial_plan_review
    assert_equal "$AGENT_PLAN_CONTENT" "Corrected plan"
}

@test "Gate A: corrected response posts comment with marker" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Original plan"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"corrected\", \"corrections\": [\"Fixed metric\"], \"revised_plan\": \"Corrected plan\"}"}'
    }

    run_adversarial_plan_review
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent-adversarial-review"* ]]
}

@test "Gate A: needs_clarification response returns 1" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"needs_clarification\", \"questions\": [\"What does X mean?\"]}"}'
    }

    run run_adversarial_plan_review
    assert_failure
}

@test "Gate A: needs_clarification sets agent:needs-info label" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"needs_clarification\", \"questions\": [\"What does X mean?\"]}"}'
    }

    run_adversarial_plan_review || true
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent:needs-info"* ]]
}

@test "Gate A: malformed JSON returns 1 and sets agent:failed" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"not valid json at all"}'
    }

    run run_adversarial_plan_review
    assert_failure
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent:failed"* ]]
}

# ═══════════════════════════════════════════════════════════════
# run_post_impl_review — Gate B
# ═══════════════════════════════════════════════════════════════

@test "Gate B review: skipped when AGENT_POST_IMPL_REVIEW=false" {
    export AGENT_POST_IMPL_REVIEW="false"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    run run_post_impl_review
    assert_success
}

@test "Gate B review: approved output sets POST_IMPL_REVIEW_JSON and returns 0" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"findings\": []}"}'; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.action')" = "approved" ]
}

@test "Gate B review: concerns output sets POST_IMPL_REVIEW_JSON and returns 0" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"concerns\", \"findings\": [{\"severity\": \"blocking\", \"description\": \"weak test\"}]}"}'; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[0].severity')" = "blocking" ]
}

@test "Gate B review: exports current ledger to the session env" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"seed"}]}'
    run_claude() { echo "{\"result\":\"{\\\"action\\\": \\\"approved\\\", \\\"echo_ledger\\\": $(echo "$AGENT_REVIEW_LEDGER" | jq -c '.cycles')}\"}"; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.echo_ledger')" = "1" ]
}

@test "Gate B review: legacy 'concerns' array is mapped to blocking findings" {
    # Finding 3: a pre-ledger custom AGENT_PROMPT_POST_IMPL_REVIEW override
    # may still emit the legacy {"action":"concerns","concerns":[...]}
    # schema. Without translation, _ledger_merge_review reads only
    # .findings (absent here), sees zero findings, and the loop declares
    # the review clean even though the legacy session flagged concerns.
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"concerns\", \"concerns\": [\"legacy concern one\", \"legacy concern two\"]}"}'; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings | length')" = "2" ]
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[0].severity')" = "blocking" ]
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[0].description')" = "legacy concern one" ]
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[1].description')" = "legacy concern two" ]
}

@test "Gate B review: unparseable output sets agent:failed and returns 1" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    create_mock "gh" ""
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"I could not decide"}'; }
    run run_post_impl_review
    assert_failure
}

# ═══════════════════════════════════════════════════════════════
# run_post_impl_review_loop
# ═══════════════════════════════════════════════════════════════

_setup_loop_worktree() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    _source_review_gates
}

@test "review loop: clean first pass returns 0" {
    _setup_loop_worktree
    run_claude() { echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"reopened\": [], \"findings\": []}"}'; }
    run run_post_impl_review_loop "Read,Edit"
    assert_success
}

@test "review loop: converges on second pass after a fix" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3
    LOOP_CALL_FILE="${TEST_TEMP_DIR}/calls"
    echo 0 > "$LOOP_CALL_FILE"
    run_claude() {
        local n; n=$(cat "$LOOP_CALL_FILE"); echo $((n + 1)) > "$LOOP_CALL_FILE"
        case "$n" in
            0) echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"gap\"}]}"}' ;;
            1) echo '{"result":"{\"action\": \"addressed\", \"dispositions\": [{\"id\": \"F1\", \"status\": \"fixed\", \"note\": \"done\"}]}"}' ;;
            *) echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [\"F1\"], \"reopened\": [], \"findings\": []}"}' ;;
        esac
    }
    run run_post_impl_review_loop "Read,Edit"
    assert_success
    # 3 sessions: review, retry, review
    [ "$(cat "$LOOP_CALL_FILE")" = "3" ]
}

@test "review loop: rejection with justification exits loop at next clean review" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3
    LOOP_CALL_FILE="${TEST_TEMP_DIR}/calls"
    echo 0 > "$LOOP_CALL_FILE"
    run_claude() {
        local n; n=$(cat "$LOOP_CALL_FILE"); echo $((n + 1)) > "$LOOP_CALL_FILE"
        case "$n" in
            0) echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"gap\"}]}"}' ;;
            1) echo '{"result":"{\"action\": \"addressed\", \"dispositions\": [{\"id\": \"F1\", \"status\": \"rejected\", \"note\": \"by design\"}]}"}' ;;
            *) echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"reopened\": [], \"findings\": []}"}' ;;
        esac
    }
    run run_post_impl_review_loop "Read,Edit"
    assert_success
    run jq -r '.findings[0].status' "${WORKTREE_DIR}/.agent-data/review-ledger.json"
    assert_output "rejected"
}

@test "review loop: cap-hit returns 2 with findings still open" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1
    LOOP_CALL_FILE="${TEST_TEMP_DIR}/calls"
    echo 0 > "$LOOP_CALL_FILE"
    run_claude() {
        local n; n=$(cat "$LOOP_CALL_FILE"); echo $((n + 1)) > "$LOOP_CALL_FILE"
        case "$n" in
            1) echo '{"result":"{\"action\": \"addressed\", \"dispositions\": []}"}' ;;
            *) echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"still broken '"$RANDOM"'\"}]}"}' ;;
        esac
    }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 2 ]
}

@test "review loop: non-integer MAX_RETRIES falls back to 3 and still trips the cap" {
    # Finding 4: `[ "$retries" -ge "abc" ]` errors under `set -e`-less
    # comparison and silently evaluates false, so a garbage
    # AGENT_POST_IMPL_REVIEW_MAX_RETRIES value never trips the cap and the
    # loop runs forever (one paid session per iteration). Every pass here
    # returns fresh concerns (a unique $RANDOM finding, so the ledger
    # never converges on its own) — the loop must still terminate with rc 2
    # once retries reach the invalid-value fallback of 3.
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES="abc"
    run_claude() {
        if [[ "$*" == *"post-impl-retry"* ]]; then :; fi
        echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"still broken '"$RANDOM"'\"}]}"}'
    }
    run_post_impl_retry_session() { RETRY_DISPOSITIONS_JSON="[]"; return 0; }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 2 ]
}

@test "review loop: MAX_RETRIES=0 returns 2 on first concerns (no retry session)" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0
    run_claude() { echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"gap\"}]}"}'; }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 2 ]
}

@test "review loop: parse failure returns 1" {
    _setup_loop_worktree
    create_mock "gh" ""
    run_claude() { echo '{"result":"garbage"}'; }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 1 ]
}

@test "review loop: ledger is committed on the branch" {
    _setup_loop_worktree
    run_claude() { echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"reopened\": [], \"findings\": []}"}'; }
    run_post_impl_review_loop "Read,Edit"
    run git -C "$WORKTREE_DIR" log --format='%s' -1
    assert_output --partial "review ledger"
}

@test "defaults: AGENT_POST_IMPL_REVIEW_MAX_RETRIES defaults to 3" {
    unset AGENT_POST_IMPL_REVIEW_MAX_RETRIES
    source "${LIB_DIR}/defaults.sh"
    assert_equal "$AGENT_POST_IMPL_REVIEW_MAX_RETRIES" "3"
}

# ═══════════════════════════════════════════════════════════════
# Regression guards
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION review-gates: both gates disabled produces unchanged flow" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="false"
    export AGENT_POST_IMPL_REVIEW="false"
    _source_review_gates

    # Gate A skips
    run run_adversarial_plan_review
    assert_success

    # Gate B skips
    run run_post_impl_review
    assert_success
}

@test "REGRESSION review-gates: Gate A corrected preserves revised_plan in AGENT_PLAN_CONTENT" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Original plan with wrong metric"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"corrected\", \"corrections\": [\"Changed metric A to metric B\"], \"revised_plan\": \"Plan with correct metric B\"}"}'
    }

    run_adversarial_plan_review
    assert_equal "$AGENT_PLAN_CONTENT" "Plan with correct metric B"
}

@test "REGRESSION review-gates: Gate A uses triage tools (read-only)" {
    # Verify the function uses AGENT_ALLOWED_TOOLS_TRIAGE, not implementation tools
    grep -q 'AGENT_ALLOWED_TOOLS_TRIAGE' "${LIB_DIR}/review-gates.sh"
}

@test "REGRESSION review-gates: Gate B uses triage tools (read-only)" {
    # Both review functions should use read-only tools
    local triage_count
    triage_count=$(grep -c 'AGENT_ALLOWED_TOOLS_TRIAGE' "${LIB_DIR}/review-gates.sh")
    [ "$triage_count" -ge 2 ]
}

# ═══════════════════════════════════════════════════════════════
# JSON extraction — narrative preamble / fence / postamble
# Regression guard for Webber #59: Claude ignored "JSON only" rule and
# wrote a verification summary before the final JSON object. The
# previous parser passed the full text to jq and failed to extract
# .action, flagging a clean "approved" review as unparseable.
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION Gate A: approved JSON with narrative preamble (Webber #59)" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    _source_review_gates

    # Claude ignored "JSON only" and narrated its verification before the JSON.
    # This is the exact failure shape seen on Webber issue #59.
    run_claude() {
        echo '{"result":"I verified all claims.\n\n**Verified:**\n- Line 302 confirmed\n- Line 3732 confirmed\n\n**No issues found.**\n\n{\"action\": \"approved\"}"}'
    }

    run run_adversarial_plan_review
    assert_success
}

@test "REGRESSION Gate A: approved JSON wrapped in markdown code fence" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    _source_review_gates

    run_claude() {
        echo '{"result":"```json\n{\"action\": \"approved\"}\n```"}'
    }

    run run_adversarial_plan_review
    assert_success
}

@test "REGRESSION Gate A: approved JSON with trailing explanation" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"approved\"}\n\nLet me know if you need anything else."}'
    }

    run run_adversarial_plan_review
    assert_success
}

@test "REGRESSION Gate A: multiple JSON-looking objects, last one is authoritative" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    _source_review_gates

    # Claude might show an example object earlier in the narrative, then
    # the real answer at the end. The last top-level {...} wins.
    run_claude() {
        echo '{"result":"For example, a flagging response might look like {\"action\": \"needs_clarification\"}. But here my decision is:\n\n{\"action\": \"approved\"}"}'
    }

    run run_adversarial_plan_review
    assert_success
}

@test "REGRESSION Gate A: corrected JSON with narrative preamble preserves revised_plan" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Plan using metric A"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"After reviewing, I found the plan used the wrong metric.\n\n{\"action\": \"corrected\", \"corrections\": [\"Changed metric A to metric B\"], \"revised_plan\": \"Plan using metric B\"}"}'
    }

    run_adversarial_plan_review
    assert_equal "$AGENT_PLAN_CONTENT" "Plan using metric B"
}

@test "REGRESSION Gate B: concerns JSON with narrative preamble sets POST_IMPL_REVIEW_JSON" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init

    run_claude() {
        echo '{"result":"I reviewed the diff. Here are my findings:\n\n{\"action\": \"concerns\", \"findings\": [{\"severity\": \"blocking\", \"description\": \"Tests use simplified topology\"}, {\"severity\": \"blocking\", \"description\": \"Missing edge case for empty queue\"}]}"}'
    }

    run_post_impl_review
    [[ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[0].description')" == *"simplified topology"* ]]
    [[ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[1].description')" == *"empty queue"* ]]
}

@test "REGRESSION review-gates: truly garbage output still fails (no false positive)" {
    export AGENT_ADVERSARIAL_PLAN_REVIEW="true"
    export AGENT_PLAN_CONTENT="Test plan"
    create_mock "gh" ""
    _source_review_gates

    # No JSON at all — should still hit the unparseable path and fail
    run_claude() {
        echo '{"result":"I cannot complete this review. No JSON output here."}'
    }

    run run_adversarial_plan_review
    assert_failure
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent:failed"* ]]
}

# ═══════════════════════════════════════════════════════════════
# Review ledger helpers
# ═══════════════════════════════════════════════════════════════

_setup_ledger() {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
}

@test "ledger: init creates empty ledger file" {
    _setup_ledger
    [ -f "${TEST_TEMP_DIR}/.agent-data/review-ledger.json" ]
    run jq -r '.cycles' "$LEDGER_FILE"
    assert_output "0"
}

@test "ledger: init preserves an existing ledger" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    mkdir -p "${TEST_TEMP_DIR}/.agent-data"
    echo '{"cycles":2,"findings":[{"id":"F1","severity":"blocking","description":"x","status":"open","justification":""}]}' \
        > "${TEST_TEMP_DIR}/.agent-data/review-ledger.json"
    _ledger_init
    run jq -r '.cycles' "$LEDGER_FILE"
    assert_output "2"
}

@test "ledger: merge_review appends findings with sequential ids and bumps cycles" {
    _setup_ledger
    _ledger_merge_review '{"action":"concerns","findings":[{"severity":"blocking","description":"missing test"},{"severity":"non-blocking","description":"style nit"}]}'
    run jq -r '.cycles' "$LEDGER_FILE"
    assert_output "1"
    run jq -r '.findings[0].id' "$LEDGER_FILE"
    assert_output "F1"
    run jq -r '.findings[1].id' "$LEDGER_FILE"
    assert_output "F2"
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "open"
}

@test "ledger: merge_review marks verified_fixed and continues id sequence" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"}]}'
    _ledger_merge_review '{"verified_fixed":["F1"],"findings":[{"severity":"blocking","description":"b"}]}'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "fixed"
    run jq -r '.findings[1].id' "$LEDGER_FILE"
    assert_output "F2"
}

@test "ledger: merge_review reopens rejected findings listed in reopened" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"}]}'
    _ledger_apply_dispositions '[{"id":"F1","status":"rejected","note":"not a bug"}]'
    _ledger_merge_review '{"reopened":["F1"],"findings":[]}'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "open"
}

@test "ledger: apply_dispositions sets status and justification on open findings only" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"},{"severity":"blocking","description":"b"}]}'
    _ledger_apply_dispositions '[{"id":"F1","status":"fixed","note":"done"},{"id":"F2","status":"rejected","note":"by design"}]'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "fixed"
    run jq -r '.findings[1].justification' "$LEDGER_FILE"
    assert_output "by design"
    # A second disposition on an already-fixed finding is ignored
    _ledger_apply_dispositions '[{"id":"F1","status":"rejected","note":"flip"}]'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "fixed"
}

@test "ledger: blocking_open_count counts only open blocking findings" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"},{"severity":"non-blocking","description":"b"},{"severity":"blocking","description":"c"}]}'
    _ledger_apply_dispositions '[{"id":"F1","status":"fixed","note":""}]'
    run _ledger_blocking_open_count
    assert_output "1"
}

@test "ledger: pr_summary renders cycles and findings" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"missing test"}]}'
    run _ledger_pr_summary
    assert_output --partial "Review cycles:"
    assert_output --partial "F1"
    assert_output --partial "missing test"
}

@test "ledger: outstanding_summary lists only open blocking findings" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"real gap"},{"severity":"non-blocking","description":"nit"}]}'
    run _ledger_outstanding_summary
    assert_output --partial "real gap"
    refute_output --partial "nit"
}

@test "ledger: commit adds only the ledger file to git" {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    _source_review_gates
    _ledger_init
    echo "unrelated" > "${WORKTREE_DIR}/other.txt"
    _ledger_commit "review pass 1"
    run git -C "$WORKTREE_DIR" log --format='%s' -1
    assert_output --partial "review pass 1"
    run git -C "$WORKTREE_DIR" status --porcelain
    assert_output --partial "other.txt"
}

# ═══════════════════════════════════════════════════════════════
# run_post_impl_retry_session
# ═══════════════════════════════════════════════════════════════

@test "retry session: parses dispositions and returns 0" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"}]}'
    run_claude() { echo '{"result":"{\"action\": \"addressed\", \"dispositions\": [{\"id\": \"F1\", \"status\": \"fixed\", \"note\": \"added test\"}]}"}'; }
    run_post_impl_retry_session "Read,Edit"
    [ "$(printf '%s' "$RETRY_DISPOSITIONS_JSON" | jq -r '.[0].id')" = "F1" ]
}

@test "retry session: unparseable output yields empty dispositions but returns 0" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"I did some fixes"}'; }
    run_post_impl_retry_session "Read,Edit"
    assert_equal "$RETRY_DISPOSITIONS_JSON" "[]"
}

@test "retry session: failing test gate returns 1" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    export AGENT_TEST_COMMAND="false"
    create_mock "gh" ""
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"addressed\", \"dispositions\": []}"}'; }
    run run_post_impl_retry_session "Read,Edit"
    assert_failure
}

@test "retry session: exports open blocking findings as AGENT_REVIEW_CONCERNS" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"needs coverage"},{"severity":"non-blocking","description":"nit"}]}'
    run_claude() { echo "{\"result\":\"{\\\"action\\\": \\\"addressed\\\", \\\"dispositions\\\": []}\"}"; }
    run_post_impl_retry_session "Read,Edit"
    [[ "$AGENT_REVIEW_CONCERNS" == *"needs coverage"* ]]
    [[ "$AGENT_REVIEW_CONCERNS" != *"nit"* ]]
}

# ═══════════════════════════════════════════════════════════════
# run_test_gate — pre-PR test gate with bounded fix sessions (#73)
# ═══════════════════════════════════════════════════════════════

_setup_test_gate() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    export BRANCH_NAME="agent/issue-99"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    (cd "$WORKTREE_DIR" && echo base > base.txt && git add base.txt && git commit -qm "base")
    export AGENT_TEST_GATE_MAX_RETRIES="2"
    create_mock "gh" ""
    _source_review_gates
    notify() { :; }
    preserve_branch() { echo "preserve" >> "${TEST_TEMP_DIR}/preserve_calls"; return 0; }
}

@test "test gate: disabled when AGENT_TEST_COMMAND is empty" {
    _setup_test_gate
    export AGENT_TEST_COMMAND=""
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
}

@test "test gate: passing tests return 0 with no fix session" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="true"
    run_claude() { echo "session" >> "${TEST_TEMP_DIR}/claude_calls"; echo '{"result":"x"}'; }
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
    [ ! -f "${TEST_TEMP_DIR}/claude_calls" ]
}

@test "REGRESSION issue-73: fix session that heals the suite returns 0" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="test -f fixed.txt"
    run_claude() {
        echo "session" >> "${TEST_TEMP_DIR}/claude_calls"
        (cd "$WORKTREE_DIR" && echo ok > fixed.txt && git add fixed.txt && git commit -qm "fix(tests): create fixed.txt")
        echo '{"result":"fixed the suite"}'
    }
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
    [ "$(wc -l < "${TEST_TEMP_DIR}/claude_calls")" -eq 1 ]
}

@test "REGRESSION issue-73: no-commit fix session breaks the loop early" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="false"
    run_claude() { echo "session" >> "${TEST_TEMP_DIR}/claude_calls"; echo '{"result":"cannot fix: broken config"}'; }
    run run_test_gate "Read,Edit" "Test issue"
    assert_failure
    # cap is 2 but only ONE session ran — no commits means no point retrying
    [ "$(wc -l < "${TEST_TEMP_DIR}/claude_calls")" -eq 1 ]
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
}

@test "REGRESSION issue-73: cap reached after max fix sessions with commits" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="false"
    run_claude() {
        echo "session" >> "${TEST_TEMP_DIR}/claude_calls"
        (cd "$WORKTREE_DIR" && echo fix >> churn.txt && git add churn.txt && git commit -qm "fix(tests): attempt")
        echo '{"result":"tried a fix"}'
    }
    run run_test_gate "Read,Edit" "Test issue"
    assert_failure
    [ "$(wc -l < "${TEST_TEMP_DIR}/claude_calls")" -eq 2 ]
}

@test "REGRESSION issue-73: retries=0 fails immediately but still preserves the branch" {
    _setup_test_gate
    export AGENT_TEST_GATE_MAX_RETRIES="0"
    export AGENT_TEST_COMMAND="false"
    run_claude() { echo "session" >> "${TEST_TEMP_DIR}/claude_calls"; echo '{"result":"x"}'; }
    run run_test_gate "Read,Edit" "Test issue"
    assert_failure
    [ ! -f "${TEST_TEMP_DIR}/claude_calls" ]
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
}

@test "REGRESSION issue-73: failure comment names the preserved branch and sets agent:failed" {
    _setup_test_gate
    export AGENT_TEST_GATE_MAX_RETRIES="0"
    export AGENT_TEST_COMMAND="false"
    run run_test_gate "Read,Edit" "Test issue"
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent/issue-99"* ]]
    [[ "$calls" == *"agent:failed"* ]]
    [[ "$calls" == *"Test Failure (Pre-PR Gate)"* ]]
}

@test "REGRESSION issue-73: non-integer AGENT_TEST_GATE_MAX_RETRIES falls back to 2" {
    _setup_test_gate
    export AGENT_TEST_GATE_MAX_RETRIES="lots"
    export AGENT_TEST_COMMAND="true"
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
    assert_output --partial "using 2"
}

@test "REGRESSION issue-73: test setup command runs before the test command" {
    local body setup_line test_line
    body=$(sed -n '/^run_test_gate()/,/^}/p' "${LIB_DIR}/review-gates.sh")
    setup_line=$(echo "$body" | grep -n 'AGENT_TEST_SETUP_COMMAND' | head -1 | cut -d: -f1)
    test_line=$(echo "$body" | grep -n 'eval "\$AGENT_TEST_COMMAND"' | head -1 | cut -d: -f1)
    [ -n "$setup_line" ] && [ -n "$test_line" ]
    [ "$setup_line" -lt "$test_line" ]
}

@test "REGRESSION issue-73: Gate B parse failure preserves the branch and names it" {
    _setup_test_gate
    export AGENT_POST_IMPL_REVIEW="true"
    _ledger_init
    run_claude() { echo '{"result":"not valid json at all"}'; }
    run run_post_impl_review
    assert_failure
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent/issue-99"* ]]
}

@test "REGRESSION issue-73: retry-session test failure preserves the branch" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="false"
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"addressed\", \"dispositions\": []}"}'; }
    run run_post_impl_retry_session "Read,Edit"
    assert_failure
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
}
