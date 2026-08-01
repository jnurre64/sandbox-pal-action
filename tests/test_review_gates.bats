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

@test "Gate B: skipped when AGENT_POST_IMPL_REVIEW=false" {
    export AGENT_POST_IMPL_REVIEW="false"
    _source_review_gates

    run run_post_impl_review
    assert_success
    [ ! -f "${TEST_TEMP_DIR}/mock_calls_timeout" ]
}

@test "Gate B: approved response returns 0" {
    export AGENT_POST_IMPL_REVIEW="true"
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"approved\"}"}'
    }

    run run_post_impl_review
    assert_success
}

@test "Gate B: concerns response returns 1 and sets POST_IMPL_REVIEW_CONCERNS" {
    export AGENT_POST_IMPL_REVIEW="true"
    _source_review_gates

    run_claude() {
        echo '{"result":"{\"action\": \"concerns\", \"concerns\": [\"Tests use simplified topology\"]}"}'
    }

    run_post_impl_review || true
    [ -n "$POST_IMPL_REVIEW_CONCERNS" ]
}

@test "Gate B: malformed JSON returns 1 and sets agent:failed" {
    export AGENT_POST_IMPL_REVIEW="true"
    create_mock "gh" ""
    _source_review_gates

    run_claude() {
        echo '{"result":"garbage output"}'
    }

    run run_post_impl_review
    assert_failure
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent:failed"* ]]
}

# ═══════════════════════════════════════════════════════════════
# handle_post_impl_review_retry
# ═══════════════════════════════════════════════════════════════

@test "Retry: skipped when MAX_RETRIES=0" {
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES="0"
    export POST_IMPL_REVIEW_CONCERNS="Tests are weak"
    create_mock "gh" ""
    _source_review_gates

    run handle_post_impl_review_retry "Read,Write"
    assert_failure
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent:failed"* ]]
}

@test "Retry: runs retry session and re-reviews on success" {
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES="1"
    export POST_IMPL_REVIEW_CONCERNS="Tests are weak"
    export AGENT_TEST_COMMAND=""
    _source_review_gates

    # Use file-based counter since run_claude is called in subshells via $()
    echo "0" > "${TEST_TEMP_DIR}/call_count"
    run_claude() {
        local count
        count=$(cat "${TEST_TEMP_DIR}/call_count")
        count=$((count + 1))
        echo "$count" > "${TEST_TEMP_DIR}/call_count"
        if [ "$count" -eq 1 ]; then
            # Retry implementation session
            echo '{"result":"Fixed the tests"}'
        else
            # Re-review passes
            echo '{"result":"{\"action\": \"approved\"}"}'
        fi
    }
    # Mock git commands
    git() {
        case "$2" in
            rev-parse) echo "abc1234" ;;
            *) echo "" ;;
        esac
    }

    run handle_post_impl_review_retry "Read,Write"
    assert_success
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

@test "REGRESSION Gate B: concerns JSON with narrative preamble sets POST_IMPL_REVIEW_CONCERNS" {
    export AGENT_POST_IMPL_REVIEW="true"
    _source_review_gates

    run_claude() {
        echo '{"result":"I reviewed the diff. Here are my findings:\n\n{\"action\": \"concerns\", \"concerns\": [\"Tests use simplified topology\", \"Missing edge case for empty queue\"]}"}'
    }

    run_post_impl_review || true
    [[ "$POST_IMPL_REVIEW_CONCERNS" == *"simplified topology"* ]]
    [[ "$POST_IMPL_REVIEW_CONCERNS" == *"empty queue"* ]]
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
