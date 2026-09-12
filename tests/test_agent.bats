#!/usr/bin/env bats
load 'helpers/test_helper'

_source_agent() {
    source "${LIB_DIR}/common.sh"
    export FIXTURE='{"subtype":"success","result":"done"}'
    export FIXTURE_EXIT=0
    export FIXTURE_STDERR=''
    engine_claude() {
        printf 'called\n' >> "${TEST_TEMP_DIR}/worker_calls"
        printf '%s' "$FIXTURE"
        [ -z "$FIXTURE_STDERR" ] || printf '%s\n' "$FIXTURE_STDERR" >&2
        return "$FIXTURE_EXIT"
    }
}

@test "agent: success preserves known telemetry and leaves absent telemetry unknown" {
    _source_agent
    run run_agent prompt Read '' '' TRIAGE
    assert_success
    [ "${#lines[@]}" -eq 1 ]
    echo "$output" | jq -e '.version == 1 and .engine == "claude" and .phase == "TRIAGE" and .status == "success" and .cost_usd == null and .usage.input_tokens == null and .denials_available == false'
    FIXTURE='{"result":"done","usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":2},"total_cost_usd":0,"permission_denials":[]}'
    run run_agent prompt
    echo "$output" | jq -e '.usage.cached_input_tokens == 2 and .usage.input_tokens == 7 and .cost_usd == 0 and .denials_available'
}

@test "REGRESSION v1.2.0: nonzero worker exit emits exactly one failed envelope despite useful stdout" {
    _source_agent
    FIXTURE_EXIT=1
    run run_agent prompt
    assert_success
    [ "${#lines[@]}" -eq 1 ]
    echo "$output" | jq -e '.status == "failed" and .process_exit_code == 1 and .result_text == "done"'
}

@test "REGRESSION v1.2.0: is_error with success subtype cannot expose structured data" {
    _source_agent
    FIXTURE='{"is_error":true,"subtype":"success","result":"quota exceeded","structured_output":{"action":"approved"}}'
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and .error.kind == "quota" and .structured_output == null and .process_exit_code == 0'
    run get_structured_output "$output"
    assert_output ''
}

@test "agent: timeout and cancellation remain distinct from success" {
    _source_agent
    FIXTURE_EXIT=124
    run run_agent prompt
    echo "$output" | jq -e '.status == "timed_out" and .process_exit_code == 124'
    run classify_agent_result "$output"
    assert_output recoverable
    FIXTURE_EXIT=143
    run run_agent prompt
    echo "$output" | jq -e '.status == "cancelled"'
    run classify_agent_result "$output"
    assert_output fail_fast
}

@test "agent: malformed, duplicate, empty and nonterminal output fail closed" {
    _source_agent
    for FIXTURE in '' '{' '{}' '[]' '{"result":"ok"}{"result":"ok"}' '{"type":"assistant"}'; do
        run run_agent prompt
        assert_success
        [ "${#lines[@]}" -eq 1 ]
        echo "$output" | jq -e '.status == "failed" and .error.kind == "transport"'
    done
}

@test "agent: auth and quota stop, rate limits and turn caps are recoverable" {
    _source_agent
    for detail in '401 unauthorized' 'credit balance depleted' 'billing account suspended'; do
        FIXTURE=$(jq -cn --arg text "$detail" '{is_error:true,subtype:"success",result:$text}')
        run run_agent prompt
        run classify_agent_result "$output"
        assert_output fail_fast
    done
    for FIXTURE in '{"is_error":true,"result":"429 rate limit"}' '{"subtype":"error_max_turns"}'; do
        run run_agent prompt
        run classify_agent_result "$output"
        assert_output recoverable
    done
}

@test "REGRESSION v1.2.1: a usage limit is its own kind, stops the phase, and keeps the reset hint" {
    _source_agent
    for detail in 'Usage limit reached · resets 4:50pm (America/Chicago)' 'session limit reached' "You've hit your limit" 'Opus limit reached'; do
        FIXTURE=$(jq -cn --arg text "$detail" '{is_error:true,subtype:"success",result:$text}')
        run run_agent prompt
        echo "$output" | jq -e '.status == "failed" and .error.kind == "usage_limit" and .structured_output == null'
        run classify_agent_result "$output"
        assert_output fail_fast
    done
    FIXTURE='{"is_error":true,"subtype":"success","api_error_status":429,"result":"Usage limit reached · resets 4:50pm"}'
    run run_agent prompt
    echo "$output" | jq -e '.error.kind == "usage_limit"'
    run parse_agent_output "$output"
    assert_output --partial 'usage limit'
    assert_output --partial 'resets 4:50pm'
    refute_output --partial 'quota exhausted'
}

@test "REGRESSION v1.2.1: billing stays terminal and a 429 is a rate limit even when it mentions quota" {
    _source_agent
    for detail in 'credit balance too low' 'billing account suspended' 'insufficient_quota' 'quota exceeded'; do
        FIXTURE=$(jq -cn --arg text "$detail" '{is_error:true,subtype:"success",result:$text}')
        run run_agent prompt
        echo "$output" | jq -e '.status == "failed" and .error.kind == "quota"'
        run classify_agent_result "$output"
        assert_output fail_fast
    done
    FIXTURE='{"is_error":true,"subtype":"success","api_error_status":429,"result":"429 quota_or_rate: rate limit, retry shortly"}'
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and .error.kind == "rate_limit"'
    run classify_agent_result "$output"
    assert_output recoverable
    # A cap the harness set is a cap, whatever the text beside it says.
    FIXTURE='{"subtype":"error_max_budget_usd","result":"Budget limit reached; usage limit for this phase"}'
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and .error.kind == "limit"'
    run classify_agent_result "$output"
    assert_output recoverable
}

@test "REGRESSION v1.2.1: every failure carries a redacted, bounded detail that reaches the failure message" {
    _source_agent
    export WORKER_TEST_SECRET='hunter2hunter2'
    FIXTURE=$(jq -cn --arg s "$WORKER_TEST_SECRET" '{is_error:true,subtype:"error_during_execution",terminal_reason:"api_error",api_error_status:529,result:("overloaded, then " + $s)}')
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and .error.kind == "unknown"'
    echo "$output" | jq -e '.error.detail | test("subtype=error_during_execution") and test("terminal_reason=api_error") and test("api_error_status=529") and test("overloaded") and (test("hunter2") | not)'
    run parse_agent_output "$output"
    assert_output --partial 'Agent phase failed: API error or worker failure'
    assert_output --partial 'terminal_reason=api_error'
    refute_output --partial 'hunter2'
    # Long error text is cut, not dropped, and never runs away in a comment.
    FIXTURE=$(jq -cn --arg s "$(head -c 2000 /dev/zero | tr '\0' x)" '{is_error:true,result:$s}')
    run run_agent prompt
    echo "$output" | jq -e '(.error.detail | length) < 400 and (.error.detail | test("x{300}"))'
    # A success carries no error object at all, exactly as before.
    FIXTURE='{"subtype":"success","result":"done"}'
    run run_agent prompt
    echo "$output" | jq -e '.status == "success" and .error == null'
    # Stderr-only failures keep their text as the detail.
    FIXTURE=''
    FIXTURE_EXIT=1
    FIXTURE_STDERR='fatal: could not reach the API'
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and (.error.detail | test("could not reach the API"))'
}

@test "agent: recovered denial does not fail a successful phase" {
    _source_agent
    FIXTURE='{"result":"done","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}'
    run run_agent prompt
    echo "$output" | jq -e '.status == "success" and .denials_available and (.permission_denials | length) == 1'
}

@test "agent: validates nested constraints and in-document references" {
    _source_agent
    cat > "$TEST_TEMP_DIR/schema.json" <<'JSON'
{"type":"object","required":["action","items"],"properties":{"action":{"enum":["approved"]},"items":{"type":"array","minItems":1,"items":{"$ref":"#/$defs/item"}}},"$defs":{"item":{"type":"object","required":["name"],"properties":{"name":{"type":"string","minLength":2}},"additionalProperties":false}}}
JSON
    FIXTURE='{"result":"ok","structured_output":{"action":"approved","items":[{"name":"yes"}]}}'
    run run_agent prompt Read '' "$TEST_TEMP_DIR/schema.json" TRIAGE
    echo "$output" | jq -e '.status == "success" and .schema_status == "valid"'
    FIXTURE='{"result":"ok","structured_output":{"action":"approved","items":[{"name":1}]}}'
    run run_agent prompt Read '' "$TEST_TEMP_DIR/schema.json" TRIAGE
    echo "$output" | jq -e '.status == "failed" and .error.kind == "schema" and .structured_output == null'
}

@test "REGRESSION v1.2.0: schema-enabled result never falls back to valid-looking text" {
    _source_agent
    echo '{"type":"object","required":["action"]}' > "$TEST_TEMP_DIR/schema.json"
    FIXTURE='{"result":"{\"action\":\"approved\"}"}'
    run run_agent prompt Read '' "$TEST_TEMP_DIR/schema.json" TRIAGE
    echo "$output" | jq -e '.status == "failed" and .schema_status == "invalid"'
    run run_agent prompt Read '' '' TRIAGE
    echo "$output" | jq -e '.status == "success" and .schema_status == "disabled"'
}

@test "agent: invalid and external schemas fail before worker execution" {
    _source_agent
    for schema in '{' '{"type":"not-a-type"}' '{"$schema":"https://invalid.example/draft"}' '{"$ref":"https://invalid.example/schema"}'; do
        printf '%s' "$schema" > "$TEST_TEMP_DIR/schema.json"
        run run_agent prompt Read '' "$TEST_TEMP_DIR/schema.json"
        echo "$output" | jq -e '.status == "failed" and .error.kind == "configuration" and .process_exit_code == null'
        [ ! -f "$TEST_TEMP_DIR/worker_calls" ]
    done
}

@test "agent: relative schemas resolve against configuration directory with spaces" {
    _source_agent
    export CONFIG_DIR="$TEST_TEMP_DIR/config with spaces"
    mkdir -p "$CONFIG_DIR"
    echo '{"type":"object"}' > "$CONFIG_DIR/schema.json"
    FIXTURE='{"result":"done","structured_output":{}}'
    run run_agent prompt Read '' schema.json TRIAGE
    echo "$output" | jq -e '.schema_status == "valid"'
}

@test "agent: capture paths are unique per invocation and secrets are scrubbed" {
    _source_agent
    FIXTURE='{"result":"ghp_abcdefghijklmnopqrstuvwxyz1234"}'
    run run_agent prompt Read '' '' TRIAGE
    refute_output --partial ghp_abcdefghijklmnopqrstuvwxyz1234
    run run_agent prompt Read '' '' TRIAGE
    local captures=("${AGENT_LOG_DIR}"/claude-stderr-TRIAGE-*.log)
    [ "${#captures[@]}" -eq 2 ]
}

_source_handlers() {
    _source_agent
    source "${LIB_DIR}/defaults.sh"
    source "${LIB_DIR}/review-gates.sh"
    local handler
    for handler in handle_new_issue handle_issue_reply handle_direct_implement handle_implement handle_pr_review handle_post_merge; do
        source <(sed -n "/^${handler}()/,/^}/p" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
    done
    export WORKTREE_BASE="$TEST_TEMP_DIR" REPO_DIR="$TEST_TEMP_DIR/repo"
    export AGENT_PLAN_CONTENT='approved plan' AGENT_ADVERSARIAL_PLAN_REVIEW=false
    set_heartbeat() { :; }
    detect_label_tools() { :; }
    check_circuit_breaker() { :; }
    ensure_repo() { :; }
    setup_worktree() { mkdir -p "$WORKTREE_DIR/.agent-data"; }
    run_worktree_setup() { mkdir -p "$WORKTREE_DIR/.agent-data"; }
    cleanup_worktree() { echo cleaned >> "$TEST_TEMP_DIR/cleaned"; }
    extract_debug_data() { :; }
    extract_plan_branch() { :; }
    stage_rules_files() { :; }
    apply_rules_files() { echo applied >> "$TEST_TEMP_DIR/advanced"; }
    handle_post_implementation() { echo published >> "$TEST_TEMP_DIR/advanced"; }
    notify() { :; }
    mark_issue_done() { :; }
    preserve_branch() { echo preserved >> "$TEST_TEMP_DIR/preserved"; }
    git() { printf 'fake-sha\n'; }
    gh() {
        printf '%s\n' "$*" >> "$TEST_TEMP_DIR/gh_calls"
        case "$*" in
            *'--json labels'*) echo 'agent:needs-info' ;;
            *'--json comments --jq'*) echo 0 ;;
            *'pr view'*) echo '{"title":"test","body":"body","headRefName":"agent/issue-99","mergedAt":"2026-09-07","author":{"login":"test-bot"},"comments":[],"reviews":[],"closingIssuesReferences":[{"number":99}]}' ;;
            *'issue view'*) echo '{"title":"test","body":"body","comments":[]}' ;;
        esac
        return 0
    }
    FIXTURE='{"is_error":true,"subtype":"success","result":"quota exceeded","structured_output":{"action":"approved","follow_up_issues":[{"title":"should not publish","body":"x"}]}}'
}

@test "REGRESSION v1.2.0: every dispatch consumer rejects semantic failure without advancing" {
    _source_handlers
    local handler
    for handler in handle_new_issue handle_issue_reply handle_direct_implement handle_implement handle_pr_review handle_post_merge; do
        rm -f "$TEST_TEMP_DIR/worker_calls" "$TEST_TEMP_DIR/gh_calls" "$TEST_TEMP_DIR/cleaned"
        run "$handler"
        assert_success
        [ -f "$TEST_TEMP_DIR/worker_calls" ]
        [ -f "$TEST_TEMP_DIR/cleaned" ]
        grep -q 'agent:failed' "$TEST_TEMP_DIR/gh_calls"
        ! grep -q 'issue create\|pr create\|agent:plan-review\|agent:pr-open' "$TEST_TEMP_DIR/gh_calls"
        [ ! -f "$TEST_TEMP_DIR/advanced" ]
    done
}

@test "REGRESSION v1.2.0: capped implementation cannot succeed with recovery gates disabled" {
    _source_handlers
    FIXTURE='{"subtype":"error_max_turns","result":"partial work"}'
    AGENT_TEST_COMMAND=''
    run handle_implement
    assert_success
    grep -q 'agent:failed' "$TEST_TEMP_DIR/gh_calls"
    [ -f "$TEST_TEMP_DIR/preserved" ]
    [ ! -f "$TEST_TEMP_DIR/advanced" ]
}

@test "REGRESSION v1.2.0: failed Gate A and Gate B cannot approve from partial structured output" {
    _source_handlers
    AGENT_ADVERSARIAL_PLAN_REVIEW=true
    run run_adversarial_plan_review
    assert_failure
    _ledger_init
    run run_post_impl_review
    assert_failure
    run run_post_impl_retry_session Read
    assert_failure
    [ -f "$TEST_TEMP_DIR/preserved" ]
}

@test "REGRESSION v1.2.0: test-fix quota error stops even if the worker made a commit" {
    _source_handlers
    AGENT_TEST_COMMAND=false
    git() { date +%s%N; }
    run run_test_gate Read test
    assert_failure
    [ "$(wc -l < "$TEST_TEMP_DIR/worker_calls")" -eq 1 ]
    [ -f "$TEST_TEMP_DIR/preserved" ]
}

@test "REGRESSION v1.2.0: JSON-escaped credential values are redacted after decoding" {
    _source_agent
    export WORKER_TEST_SECRET=$'secret"with\\escapes\nand-newline'
    FIXTURE=$(jq -cn --arg secret "$WORKER_TEST_SECRET" '{result:$secret}')
    run run_agent prompt
    assert_success
    echo "$output" | jq -e '.result_text == "[REDACTED:WORKER_TEST_SECRET]"'
}

@test "agent: auth errors reported only on stderr retain their cause" {
    _source_agent
    engine_claude() { echo '401 unauthorized' >&2; return 1; }
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and .error.kind == "auth" and .process_exit_code == 1'
}

@test "agent: missing validator dependency fails before invoking a worker" {
    _source_agent
    python3() { return 1; }
    run run_agent prompt
    echo "$output" | jq -e '.status == "failed" and .error.kind == "configuration" and .process_exit_code == null'
    [ ! -f "$TEST_TEMP_DIR/worker_calls" ]
}

@test "agent: installer inventory delivers both adapters and validator requirements" {
    source "${LIB_DIR}/install-assets.sh"
    local inventory
    inventory=$(list_install_assets "${SCRIPTS_DIR}/.." | tr '\0' '\n')
    for file in scripts/lib/agent.sh scripts/lib/engine-claude.sh scripts/lib/engine-codex.sh scripts/lib/agent-result.py scripts/lib/codex-worker.py scripts/requirements-worker.txt; do
        [[ "$inventory" == *"$file"* ]]
    done
}
