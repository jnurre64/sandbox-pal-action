#!/usr/bin/env bats
load 'helpers/test_helper'
load 'helpers/codex_worker'

_profiles() {
    _codex_worker
    source "$LIB_DIR/defaults.sh"
    source "$LIB_DIR/common.sh"
    export AGENT_ENGINE_PROFILES=true
    engine_claude_preflight() { echo checked >> "$TEST_TEMP_DIR/claude-auth"; }
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_TEMP_DIR/claude-args"
printf '%s\n' "${CLAUDE_CODE_EFFORT_LEVEL-unset}" > "$TEST_TEMP_DIR/claude-effort"
echo '{"result":"done"}'
MOCK
    cat > "$TEST_TEMP_DIR/bin/timeout" <<'MOCK'
#!/bin/bash
printf '%s\n' "$1" > "$TEST_TEMP_DIR/claude-timeout"
shift
exec "$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude" "$TEST_TEMP_DIR/bin/timeout"
}

@test "REGRESSION v1.2.0: profiles restore identical Claude invocation after Codex without rewriting settings" {
    _profiles
    AGENT_MODEL_CLAUDE_IMPLEMENT=claude-custom AGENT_MODEL_CODEX_IMPLEMENT=codex-custom
    AGENT_BUDGET_USD=12 AGENT_PERMISSION_MODE_IMPLEMENT=acceptEdits AGENT_EFFORT_IMPLEMENT=max
    AGENT_TIMEOUT_CLAUDE_IMPLEMENT=81 AGENT_TIMEOUT_CODEX_IMPLEMENT=93
    AGENT_MAX_TURNS_CLAUDE_IMPLEMENT=7 AGENT_EFFORT_CODEX_IMPLEMENT=medium
    run run_agent prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.status == "success" and .engine == "claude"'
    cp "$TEST_TEMP_DIR/claude-args" "$TEST_TEMP_DIR/original-args"
    grep -qx 12 "$TEST_TEMP_DIR/claude-args"
    grep -qx 7 "$TEST_TEMP_DIR/claude-args"
    grep -qx acceptEdits "$TEST_TEMP_DIR/claude-args"
    [ "$(cat "$TEST_TEMP_DIR/claude-timeout")" = 81 ]
    [ "$(cat "$TEST_TEMP_DIR/claude-effort")" = max ]
    AGENT_ENGINE=codex
    run run_agent prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.status == "success" and .engine == "codex"'
    jq -e '.argv | index("--model=codex-custom") != null and index("model_reasoning_effort=\"medium\"") != null and index("--max-turns") == null and index("--max-budget-usd") == null and index("--permission-mode") == null' "$TEST_TEMP_DIR/invocation.json"
    run agent_resolve_config IMPLEMENT
    echo "$output" | jq -e '.policy.timeout == 93'
    AGENT_ENGINE=claude
    run run_claude prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.status == "success"'
    # The generated settings file has a new name on every run (#135).
    cmp <(grep -v '/claude-settings-' "$TEST_TEMP_DIR/original-args") <(grep -v '/claude-settings-' "$TEST_TEMP_DIR/claude-args")
    [ "$(cat "$TEST_TEMP_DIR/claude-effort")" = max ]
    [ "$(cat "$TEST_TEMP_DIR/claude-timeout")" = 81 ]
}

@test "profiles: engine defaults outrank legacy phase models and direct explicit callers retain precedence" {
    _profiles
    AGENT_MODEL_CLAUDE=engine-default AGENT_MODEL_IMPLEMENT=legacy-phase
    AGENT_MODEL_TRIAGE=legacy-triage
    for phase in IMPLEMENT REPLY VALIDATE; do
        run agent_resolve_config "$phase"
        echo "$output" | jq -e '.model == "engine-default" and .settings.sources.model == "AGENT_MODEL_CLAUDE"'
    done
    AGENT_MODEL_CLAUDE_IMPLEMENT=engine-phase
    run run_claude prompt Read caller-model '' IMPLEMENT
    grep -qx caller-model "$TEST_TEMP_DIR/claude-args"
    run run_agent prompt Read '' '' IMPLEMENT
    grep -qx engine-phase "$TEST_TEMP_DIR/claude-args"
    AGENT_MODEL_CLAUDE=''
    for phase in REPLY VALIDATE; do
        run agent_resolve_config "$phase"
        echo "$output" | jq -e '.model == "legacy-triage"'
    done
    AGENT_ENGINE_TRIAGE=codex
    run agent_resolve_config REPLY
    echo "$output" | jq -e '.model == ""'
}

@test "profiles: Codex ignores unqualified model and effort and accepts opaque model IDs" {
    _profiles
    AGENT_ENGINE=codex AGENT_MODEL=sonnet AGENT_MODEL_IMPLEMENT=opus AGENT_EFFORT_IMPLEMENT=max
    AGENT_EFFORT_LEVEL=invalid-inactive AGENT_TIMEOUT_CLAUDE=invalid-inactive
    run agent_resolve_config IMPLEMENT
    echo "$output" | jq -e '.model == "" and .policy.effort == "" and .policy.timeout == 60'
    AGENT_MODEL_CODEX=custom-provider-id AGENT_EFFORT_CODEX=minimal
    run agent_resolve_config IMPLEMENT
    echo "$output" | jq -e '.model == "custom-provider-id" and .policy.effort == "minimal"'
}

@test "profiles: selected limits reject malformed false and zero values rather than falling back" {
    _profiles
    for key in AGENT_TIMEOUT_CLAUDE_IMPLEMENT AGENT_MAX_TURNS_CLAUDE_IMPLEMENT AGENT_BUDGET_USD_CLAUDE_IMPLEMENT; do
        for value in 0 00 false -1 invalid; do
            printf -v "$key" '%s' "$value"
            run agent_resolve_config IMPLEMENT
            assert_failure
        done
        unset "$key"
    done
    AGENT_ENGINE=codex AGENT_TIMEOUT_CODEX=0
    run agent_resolve_config IMPLEMENT
    assert_failure
    AGENT_TIMEOUT_CODEX=42 AGENT_TIMEOUT_CODEX_IMPLEMENT=''
    run agent_resolve_config IMPLEMENT
    echo "$output" | jq -e '.policy.timeout == 42'
    AGENT_TIMEOUT_CODEX_IMPLEMENT=false
    run agent_resolve_config IMPLEMENT
    assert_failure
    AGENT_ENGINE_PROFILES=typo
    run agent_resolve_config IMPLEMENT
    assert_failure
}

@test "profiles: unsupported explicit Codex keys fail even when empty and inactive phase keys do not" {
    _profiles
    AGENT_ENGINE=codex
    for setting in BUDGET_USD MAX_TURNS PERMISSION_MODE ALLOWED_TOOLS DISALLOWED_TOOLS EXTRA_TOOLS LABEL_TOOLS MCP_CONFIG STRICT_MCP; do
        for suffix in CODEX CODEX_IMPLEMENT; do
            key="AGENT_${setting}_${suffix}"
            printf -v "$key" '%s' ''
            run agent_resolve_config IMPLEMENT
            assert_failure
            assert_output --partial "$key is unsupported by Codex"
            unset "$key"
        done
    done
    AGENT_BUDGET_USD_CODEX_CLEANUP=9
    agent_preflight_dispatch implement
    [ ! -f "$TEST_TEMP_DIR/invocation.json" ]
    [ ! -f "$TEST_TEMP_DIR/claude-auth" ]
}

@test "profiles: native policy strict opt-out still rejects preserved Claude tool policy" {
    _profiles
    AGENT_ENGINE=codex AGENT_CODEX_USE_NATIVE_POLICY=false
    run agent_preflight_dispatch implement
    assert_failure
    assert_output --partial 'Claude tool allow/deny lists'
    [ ! -f "$TEST_TEMP_DIR/invocation.json" ]
}

@test "profiles: preflight freezes selected settings including previously unset names" {
    _profiles
    AGENT_MODEL_CLAUDE_IMPLEMENT=chosen AGENT_EFFORT_CLAUDE_IMPLEMENT=low
    AGENT_TIMEOUT_CLAUDE=91 AGENT_BUDGET_USD_CLAUDE=11 AGENT_MAX_TURNS_CLAUDE=8
    agent_preflight_dispatch implement
    run run_agent prompt Read caller-model '' IMPLEMENT
    echo "$output" | jq -e '.status == "success"'
    grep -qx chosen "$TEST_TEMP_DIR/claude-args"
    grep -qx 11 "$TEST_TEMP_DIR/claude-args"
    [ "$(cat "$TEST_TEMP_DIR/claude-timeout")" = 91 ]
    [ "$(cat "$TEST_TEMP_DIR/claude-effort")" = low ]
    for key in AGENT_TIMEOUT_CLAUDE AGENT_TIMEOUT_CODEX_IMPLEMENT AGENT_MAX_TURNS_CLAUDE_IMPLEMENT AGENT_ENGINE_PROFILES; do
        run eval "$key=changed"
        assert_failure
    done
    # Raw effort environment is not a way around the frozen policy.
    export CLAUDE_CODE_EFFORT_LEVEL=max
    run run_agent prompt Read '' '' IMPLEMENT
    [ "$(cat "$TEST_TEMP_DIR/claude-effort")" = low ]
}

@test "profiles: both hybrid directions retain explicit routing and selected phase effort" {
    _profiles
    AGENT_ENGINE=codex AGENT_ENGINE_POST_IMPL_REVIEW=claude
    AGENT_EFFORT_CLAUDE=max AGENT_EFFORT_CODEX=minimal
    AGENT_TIMEOUT_CLAUDE=70 AGENT_TIMEOUT_CODEX=80
    run agent_resolve_config POST_IMPL_REVIEW
    echo "$output" | jq -e '.engine == "claude" and .policy.effort == "max" and .policy.timeout == "70"'
    AGENT_ENGINE=claude AGENT_ENGINE_POST_IMPL_REVIEW=codex
    run agent_resolve_config POST_IMPL_REVIEW
    echo "$output" | jq -e '.engine == "codex" and .policy.effort == "minimal" and .policy.timeout == 80'
    AGENT_ENGINE=codex
    for phase in TRIAGE REPLY VALIDATE ADVERSARIAL_PLAN POST_IMPL_REVIEW; do
        run agent_resolve_config "$phase"
        echo "$output" | jq -e '.policy.sandbox == "read-only"'
    done
    for phase in IMPLEMENT REVIEW POST_IMPL_RETRY TEST_FIX CLEANUP; do
        run agent_resolve_config "$phase"
        echo "$output" | jq -e '.policy.sandbox == "workspace-write"'
    done
}

@test "profiles: disabled phases do not validate settings or require inactive engine auth" {
    _profiles
    AGENT_ENGINE_POST_IMPL_REVIEW=codex AGENT_POST_IMPL_REVIEW=false
    AGENT_EFFORT_CODEX=invalid AGENT_BUDGET_USD_CODEX=7
    export MOCK_AUTH_EXIT=1
    agent_preflight_dispatch implement
    [ ! -f "$TEST_TEMP_DIR/auth-called" ]
    jq -e 'has("POST_IMPL_REVIEW") | not' <<< "$AGENT_PHASE_MAP"
}

@test "profiles: direct unsupported configuration returns failure without starting either worker" {
    _profiles
    AGENT_ENGINE=codex AGENT_BUDGET_USD_CODEX_IMPLEMENT=7
    run run_agent prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.status == "failed" and .engine == "codex" and .error.kind == "configuration" and (.error.message | contains("AGENT_BUDGET_USD_CODEX_IMPLEMENT"))'
    [ ! -f "$TEST_TEMP_DIR/invocation.json" ]
    [ ! -f "$TEST_TEMP_DIR/claude-args" ]
}

@test "profiles: Codex uses selected invocation timeout even with a longer shared timeout" {
    _profiles
    AGENT_ENGINE=codex AGENT_TIMEOUT_CODEX_IMPLEMENT=1
    export MOCK_CODEX_MODE=hang
    run run_agent prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.status == "timed_out" and .engine == "codex"'
    _child_stopped
}

@test "REGRESSION v1.2.0: legacy empty effort environment and absence of effort flag survive resolution" {
    _profiles
    AGENT_ENGINE_PROFILES=false
    export CLAUDE_CODE_EFFORT_LEVEL=''
    run run_agent prompt Read '' '' IMPLEMENT
    echo "$output" | jq -e '.status == "success"'
    [ "$(cat "$TEST_TEMP_DIR/claude-effort")" = '' ]
    ! grep -q -- --effort "$TEST_TEMP_DIR/claude-args"
}

@test "profiles: examples preserve incoming values and keep adoption disabled" {
    _profiles
    unset AGENT_ENGINE_PROFILES
    export AGENT_ENGINE=codex AGENT_TIMEOUT_CODEX_IMPLEMENT=123 AGENT_MODEL_CLAUDE=custom
    source "$SCRIPTS_DIR/../config.defaults.env.example"
    source "$LIB_DIR/defaults.sh"
    [ "$AGENT_ENGINE_PROFILES" = false ]
    [ "$AGENT_ENGINE" = codex ]
    [ "$AGENT_TIMEOUT_CODEX_IMPLEMENT" = 123 ]
    [ "$AGENT_MODEL_CLAUDE" = custom ]
}

@test "profiles: reachable unsupported caps stop dispatch before workers or handler mutations" {
    mkdir -p "$TEST_TEMP_DIR/install"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/install/scripts"
    cp -R "$SCRIPTS_DIR/../schemas" "$TEST_TEMP_DIR/install/schemas"
    create_mock gh ''
    create_mock claude 'unexpected worker'
    create_mock codex 'unexpected worker'
    run env HOME="$TEST_TEMP_DIR/home" AGENT_ENGINE_PROFILES=true AGENT_ENGINE=codex \
        AGENT_BUDGET_USD_CODEX_TRIAGE=1 AGENT_EXECUTION_MODE=orchestrator \
        bash "$TEST_TEMP_DIR/install/scripts/sandbox-pal-dispatch.sh" new_issue test-org/test-repo 99
    assert_success
    echo "${lines[${#lines[@]}-1]}" | jq -e '.outcome == "agent:failed"'
    [ ! -f "$TEST_TEMP_DIR/mock_calls_claude" ]
    [ ! -f "$TEST_TEMP_DIR/mock_calls_codex" ]
    grep -q -- '--add-label agent:failed' "$TEST_TEMP_DIR/mock_calls_gh"
    ! grep -q 'issue comment\|pr create' "$TEST_TEMP_DIR/mock_calls_gh"
}
