#!/usr/bin/env bats
load 'helpers/test_helper'

_source_config() {
    source "${LIB_DIR}/defaults.sh"
    source "${LIB_DIR}/common.sh"
    engine_claude_preflight() { echo checked >> "$TEST_TEMP_DIR/auth-checks"; }
    engine_claude() {
        printf '%s\n' "$3" > "$TEST_TEMP_DIR/model"
        printf '%s\n' "$4" > "$TEST_TEMP_DIR/schema"
        echo '{"result":"done","structured_output":{"action":"approved"}}'
    }
}

@test "engine configuration: default Claude and engine-specific model precedence" {
    _source_config
    AGENT_MODEL=legacy
    run agent_resolve_phase IMPLEMENT
    echo "$output" | jq -e '.engine == "claude" and .model == "legacy"'
    AGENT_MODEL_CLAUDE=engine-default
    run agent_resolve_phase IMPLEMENT
    echo "$output" | jq -e '.model == "engine-default"'
    AGENT_MODEL_IMPLEMENT=phase-model
    run agent_resolve_phase IMPLEMENT
    echo "$output" | jq -e '.model == "phase-model"'
}

@test "engine configuration: mixed phases never inherit the other engine model" {
    _source_config
    AGENT_MODEL=sonnet
    AGENT_ENGINE_POST_IMPL_REVIEW=codex
    run agent_resolve_phase POST_IMPL_REVIEW
    echo "$output" | jq -e '.engine == "codex" and .model == ""'
    AGENT_MODEL_CODEX=gpt-custom
    run agent_resolve_phase POST_IMPL_REVIEW
    echo "$output" | jq -e '.model == "gpt-custom"'
    AGENT_MODEL_POST_IMPL_REVIEW=opus
    run agent_resolve_phase POST_IMPL_REVIEW
    assert_failure
    AGENT_ENGINE=codex
    AGENT_ENGINE_IMPLEMENT=claude
    AGENT_MODEL=gpt-custom
    run agent_resolve_phase IMPLEMENT
    echo "$output" | jq -e '.engine == "claude" and .model == ""'
}

@test "engine configuration: reply and validation retain same-engine triage model inheritance" {
    _source_config
    AGENT_MODEL_TRIAGE=sonnet
    for phase in REPLY VALIDATE; do
        run agent_resolve_phase "$phase"
        echo "$output" | jq -e '.model == "sonnet"'
    done
    AGENT_ENGINE_REPLY=codex
    run agent_resolve_phase REPLY
    echo "$output" | jq -e '.engine == "codex" and .model == ""'
    AGENT_MODEL_REPLY=gpt-custom
    run agent_resolve_phase REPLY
    echo "$output" | jq -e '.model == "gpt-custom"'
}

@test "engine configuration: invalid engine and phase fail without evaluating variable names" {
    _source_config
    AGENT_ENGINE=invalid
    run agent_resolve_phase TRIAGE
    assert_failure
    AGENT_ENGINE=claude
    AGENT_ENGINE_TRIAGE=invalid
    run agent_resolve_phase TRIAGE
    assert_failure
    run agent_resolve_phase 'x[$(touch sentinel)]'
    assert_failure
}

@test "preflight: implementation includes both gates and enabled bounded fixes" {
    _source_config
    AGENT_TEST_COMMAND=true
    run agent_reachable_phases implement
    assert_output $'ADVERSARIAL_PLAN\nIMPLEMENT\nTEST_FIX\nPOST_IMPL_REVIEW\nPOST_IMPL_RETRY'
    AGENT_TEST_GATE_MAX_RETRIES=0
    AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0
    run agent_reachable_phases direct_implement
    assert_output $'VALIDATE\nADVERSARIAL_PLAN\nIMPLEMENT\nPOST_IMPL_REVIEW'
    AGENT_TEST_GATE_MAX_RETRIES=invalid
    AGENT_POST_IMPL_REVIEW_MAX_RETRIES=invalid
    run agent_reachable_phases implement
    assert_output --partial TEST_FIX
    assert_output --partial POST_IMPL_RETRY
}

@test "preflight: reply covers retriage and direct implementation with config gates" {
    _source_config
    run agent_reachable_phases issue_reply
    assert_output --partial REPLY
    assert_output --partial TRIAGE
    assert_output --partial VALIDATE
    assert_output --partial IMPLEMENT
    AGENT_ALLOW_DIRECT_IMPLEMENT=false
    run agent_reachable_phases issue_reply
    assert_output $'REPLY\nTRIAGE'
    run agent_reachable_phases direct_implement
    assert_output ''
    AGENT_CLEANUP_ENABLED=false
    run agent_reachable_phases post_merge
    assert_success
    assert_output ''
}

@test "preflight: unused Codex phases require no Codex authentication" {
    _source_config
    AGENT_ENGINE_POST_IMPL_REVIEW=codex
    agent_preflight_dispatch new_issue
    [ "$(wc -l < "$TEST_TEMP_DIR/auth-checks")" -eq 1 ]
    jq -e 'keys == ["TRIAGE"]' <<< "$AGENT_PHASE_MAP"
}

@test "preflight: a reachable Codex retry fails before any worker and never falls back" {
    _source_config
    AGENT_TEST_COMMAND=true
    AGENT_ENGINE_TEST_FIX=codex
    engine_codex_preflight() { echo 'Codex authentication is unavailable' >&2; return 1; }
    run agent_preflight_dispatch implement
    assert_failure
    assert_output --partial 'Codex authentication is unavailable'
    [ ! -f "$TEST_TEMP_DIR/model" ]
    engine_codex() { agent_failure TEST_FIX configuration 'Codex authentication is unavailable' codex; }
    run run_agent prompt Read '' '' TEST_FIX
    echo "$output" | jq -e '.engine == "codex" and .status == "failed" and .error.kind == "configuration"'
    [ ! -f "$TEST_TEMP_DIR/model" ]
}

@test "preflight: checks later schemas before the first paid worker" {
    _source_config
    AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="$TEST_TEMP_DIR/missing.json"
    run agent_preflight_dispatch implement
    assert_failure
    assert_output --partial 'POST_IMPL_REVIEW: configured schema'
    [ ! -f "$TEST_TEMP_DIR/model" ]
}

@test "preflight: snapshots schema and model and rejects unplanned phases" {
    _source_config
    AGENT_JSON_SCHEMA_TRIAGE="$TEST_TEMP_DIR/schema.json"
    echo '{"type":"object"}' > "$AGENT_JSON_SCHEMA_TRIAGE"
    AGENT_MODEL_CLAUDE=sonnet
    agent_preflight_dispatch new_issue
    echo '{"not":"valid"}' > "$AGENT_JSON_SCHEMA_TRIAGE"
    run run_agent prompt Read malicious-model "$AGENT_JSON_SCHEMA_TRIAGE" TRIAGE
    echo "$output" | jq -e '.status == "success" and .schema_status == "valid"'
    [ "$(cat "$TEST_TEMP_DIR/model")" = sonnet ]
    jq -e '.type == "object"' "$TEST_TEMP_DIR/schema"
    run run_agent prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.error.kind == "configuration" and .process_exit_code == null'
    # Both configured and previously-unset phase policies become readonly.
    run eval 'AGENT_PERMISSION_MODE_TRIAGE=bypassPermissions'
    assert_failure
}

@test "preflight: status skips model dependency and credential validation" {
    _source_config
    AGENT_ENGINE=invalid
    python3() { return 1; }
    run agent_preflight_dispatch status
    assert_success
    [ ! -f "$TEST_TEMP_DIR/auth-checks" ]
}

@test "preflight: Claude auth requires loggedIn without exposing diagnostics" {
    _source_config
    source "${LIB_DIR}/engine-claude.sh"
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/bin/bash
cat "$TEST_TEMP_DIR/auth.json"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    echo '{"loggedIn":false,"email":"private@example.com"}' > "$TEST_TEMP_DIR/auth.json"
    run engine_claude_preflight
    assert_failure
    refute_output --partial private@example.com
    echo '{"loggedIn":true}' > "$TEST_TEMP_DIR/auth.json"
    run engine_claude_preflight
    assert_success
    echo malformed > "$TEST_TEMP_DIR/auth.json"
    run engine_claude_preflight
    assert_failure
}

@test "preflight: invalid policy in later phase prevents earlier worker execution" {
    _source_config
    AGENT_BUDGET_USD_POST_IMPL_RETRY=invalid
    run agent_preflight_dispatch implement
    assert_failure
    assert_output --partial 'POST_IMPL_RETRY: budget'
    [ ! -f "$TEST_TEMP_DIR/model" ]
}

@test "preflight: dispatch failure records semantic outcome and preserves existing worktree" {
    # Execute the real entry point in an isolated installation/home. All GitHub
    # calls are mocked, and a reachable Codex phase must stop before any worker.
    mkdir -p "$TEST_TEMP_DIR/install" "$TEST_TEMP_DIR/home/.claude/worktrees/default/test-repo-issue-99"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/install/scripts"
    cp -R "$SCRIPTS_DIR/../schemas" "$TEST_TEMP_DIR/install/schemas"
    echo preserved > "$TEST_TEMP_DIR/home/.claude/worktrees/default/test-repo-issue-99/sentinel"
    create_mock gh ''
    create_mock claude 'unexpected worker'
    run env HOME="$TEST_TEMP_DIR/home" AGENT_ENGINE=codex AGENT_EXECUTION_MODE=orchestrator \
        bash "$TEST_TEMP_DIR/install/scripts/sandbox-pal-dispatch.sh" new_issue test-org/test-repo 99
    assert_success
    echo "${lines[${#lines[@]}-1]}" | jq -e '.outcome == "agent:failed" and .exit_code == 0'
    jq -e '.outcome == "agent:failed"' "$AGENT_LOG_DIR/locks/test-repo-99-last-dispatch.json"
    [ ! -f "$AGENT_LOG_DIR/locks/test-repo-99.lock" ]
    [ "$(cat "$TEST_TEMP_DIR/home/.claude/worktrees/default/test-repo-issue-99/sentinel")" = preserved ]
    [ ! -f "$TEST_TEMP_DIR/mock_calls_claude" ]
    ! grep -q 'issue comment\|pr create' "$TEST_TEMP_DIR/mock_calls_gh"
}

@test "preflight: real status entry point never checks workers or contacts GitHub" {
    mkdir -p "$TEST_TEMP_DIR/install"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/install/scripts"
    create_mock gh ''
    create_mock claude 'unexpected auth check'
    run env HOME="$TEST_TEMP_DIR/home" AGENT_ENGINE=invalid AGENT_EXECUTION_MODE=orchestrator \
        bash "$TEST_TEMP_DIR/install/scripts/sandbox-pal-dispatch.sh" status test-org/test-repo 99
    assert_success
    [ ! -f "$TEST_TEMP_DIR/mock_calls_claude" ]
    [ ! -f "$TEST_TEMP_DIR/mock_calls_gh" ]
    [ ! -f "$AGENT_LOG_DIR/locks/test-repo-99-last-dispatch.json" ]
}

@test "reachable phases: a PR revision can reach TEST_FIX when its test gate is on" {
    _source_config
    AGENT_TEST_COMMAND="make test" run agent_reachable_phases pr_review
    assert_line REVIEW
    assert_line TEST_FIX
    AGENT_TEST_COMMAND="make test" AGENT_REVISION_TEST_GATE=false run agent_reachable_phases pr_review
    refute_line TEST_FIX
    AGENT_TEST_COMMAND="" run agent_reachable_phases pr_review
    refute_line TEST_FIX
}

@test "pr_review: the revision test gate runs before the push and reports on the linked issue" {
    local body gate push
    body=$(sed -n '/^handle_pr_review()/,/^}/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
    gate=$(grep -n 'NUMBER="\$issue_num" run_test_gate' <<< "$body" | head -1 | cut -d: -f1)
    push=$(grep -n 'push origin "\$branch"' <<< "$body" | head -1 | cut -d: -f1)
    [ -n "$gate" ] && [ -n "$push" ] && [ "$gate" -lt "$push" ]
    grep -q 'AGENT_REVISION_TEST_GATE' <<< "$body"
}

@test "pr_review: the dispatcher posts the revision summary; the prompt no longer asks the phase to post (#154)" {
    local body
    body=$(sed -n '/^handle_pr_review()/,/^}/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
    grep -q 'revision-summary.md' <<< "$body"
    grep -q '## Revision summary' <<< "$body"
    grep -q 'revision-summary.md' "${PROMPTS_DIR}/review.md"
    ! grep -qi 'post a comment on the PR' "${PROMPTS_DIR}/review.md"
}
