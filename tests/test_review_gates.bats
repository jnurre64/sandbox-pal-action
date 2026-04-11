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
