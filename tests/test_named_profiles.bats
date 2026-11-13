#!/usr/bin/env bats
load 'helpers/test_helper'
load 'helpers/codex_worker'

_named() {
    export AGENT_CONFIG="$MOCK_CONFIG_DIR/config.env"
    printf '%s\n' 'AGENT_ENGINE_PROFILES=true' 'AGENT_ENGINE=claude' 'AGENT_ENGINE_POST_IMPL_REVIEW=codex' > "$AGENT_CONFIG"
    cp "$SCRIPTS_DIR/../agent-profiles.example.json" "$MOCK_CONFIG_DIR/agent-profiles.json"
    export CONFIG_DIR="$MOCK_CONFIG_DIR"
    source "$LIB_DIR/defaults.sh"
    source "$LIB_DIR/common.sh"
    export AGENT_ENGINE_PROFILES=true
}

@test "named profiles: capture switch and restore every effective phase without changing config" {
    _named
    export AGENT_ENGINE_POST_IMPL_REVIEW=codex AGENT_MODEL_CLAUDE=custom-claude AGENT_MODEL_CODEX=custom-codex
    export AGENT_TIMEOUT_CLAUDE=81 AGENT_TIMEOUT_CODEX=93 AGENT_BUDGET_USD_CLAUDE=12
    cp "$AGENT_CONFIG" "$TEST_TEMP_DIR/before"
    "$SCRIPTS_DIR/agent-profile.sh" show legacy --json > "$TEST_TEMP_DIR/legacy"
    run "$SCRIPTS_DIR/agent-profile.sh" capture my-hybrid
    assert_success
    for name in codex-only claude-only my-hybrid; do
        run "$SCRIPTS_DIR/agent-profile.sh" use "$name"
        assert_success
        "$SCRIPTS_DIR/agent-profile.sh" show --json > "$TEST_TEMP_DIR/$name"
    done
    jq -e '[.phases[].engine] | length == 10 and all(. == "codex")' "$TEST_TEMP_DIR/codex-only"
    jq -e '[.phases[].engine] | length == 10 and all(. == "claude")' "$TEST_TEMP_DIR/claude-only"
    diff <(jq '.phases | map_values(del(.profile,.selection_source))' "$TEST_TEMP_DIR/legacy") <(jq '.phases | map_values(del(.profile,.selection_source))' "$TEST_TEMP_DIR/my-hybrid")
    cmp "$AGENT_CONFIG" "$TEST_TEMP_DIR/before"
}

@test "named profiles: incoming selector survives unconditional config and saved selection wins config" {
    _named
    echo 'AGENT_PROFILE=claude-only' >> "$AGENT_CONFIG"
    echo codex-only > "$MOCK_CONFIG_DIR/.agent-profile"
    run env AGENT_PROFILE=legacy "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "legacy" and .selection_source == "incoming"' <<< "$output"
    run env AGENT_PROFILE= "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "codex-only" and .selection_source == "state"' <<< "$output"
    rm "$MOCK_CONFIG_DIR/.agent-profile"
    run env AGENT_PROFILE= "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "claude-only" and .selection_source == "config"' <<< "$output"
}

@test "named profiles: settings overlay wins base values and empty override inherits" {
    _named
    jq '.profiles.fast={engine:"codex",settings:{AGENT_MODEL_CODEX:"custom-fast",AGENT_TIMEOUT_CODEX:"75",AGENT_TIMEOUT_CODEX_IMPLEMENT:"",AGENT_EFFORT_CODEX:"low"}}' "$MOCK_CONFIG_DIR/agent-profiles.json" > "$TEST_TEMP_DIR/catalog"
    mv "$TEST_TEMP_DIR/catalog" "$MOCK_CONFIG_DIR/agent-profiles.json"
    export AGENT_MODEL_CODEX=base AGENT_TIMEOUT_CODEX_IMPLEMENT=91
    run "$SCRIPTS_DIR/agent-profile.sh" show fast --json
    assert_success
    jq -e '.phases.IMPLEMENT | .model == "custom-fast" and .policy.timeout == 75 and .policy.effort == "low" and .settings.sources.timeout == "profile:fast:AGENT_TIMEOUT_CODEX"' <<< "$output"
}

@test "named profiles: invalid catalogs reject schema types keys names engines and controls" {
    _named
    for expression in '.version=2' '.profiles=[]' '.profiles.bad={engine:"other"}' '.profiles.legacy={engine:"codex"}' '.profiles["bad/name"]={engine:"codex"}' '.profiles["codex-only"].phases={NOPE:"claude"}' '.profiles["codex-only"].settings={GH_TOKEN:"secret"}' '.profiles["codex-only"].settings={AGENT_TIMEOUT_CODEX:0}' '.profiles["codex-only"].settings={AGENT_BUDGET_USD_CODEX:"1"}' '.profiles["codex-only"].settings=null' '.default="unknown"'; do
        jq "$expression" "$SCRIPTS_DIR/../agent-profiles.example.json" > "$MOCK_CONFIG_DIR/agent-profiles.json"
        run "$SCRIPTS_DIR/agent-profile.sh" list
        assert_failure
        assert_output --partial 'Invalid agent profile catalog'
        refute_output --partial secret
    done
}

@test "named profiles: missing optional catalog is legacy but explicit missing and unknown fail" {
    _named
    rm "$MOCK_CONFIG_DIR/agent-profiles.json"
    run "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    run env AGENT_PROFILES_FILE=missing.json "$SCRIPTS_DIR/agent-profile.sh" list
    assert_failure
    run env AGENT_PROFILE=unknown "$SCRIPTS_DIR/agent-profile.sh" show
    assert_failure
    run env AGENT_PROFILE='../bad' "$SCRIPTS_DIR/agent-profile.sh" show
    assert_failure
}

@test "named profiles: adoption is explicit and failed switching preserves prior state" {
    _named
    echo legacy > "$MOCK_CONFIG_DIR/.agent-profile"
    echo AGENT_ENGINE_PROFILES=false >> "$AGENT_CONFIG"
    run "$SCRIPTS_DIR/agent-profile.sh" use codex-only
    assert_failure
    assert_output --partial 'AGENT_ENGINE_PROFILES=true'
    [ "$(cat "$MOCK_CONFIG_DIR/.agent-profile")" = legacy ]
}

@test "named profiles: capture ignores active profile refuses collisions and retains default" {
    _named
    export AGENT_PROFILE=codex-only
    jq '.default="claude-only"' "$MOCK_CONFIG_DIR/agent-profiles.json" > "$TEST_TEMP_DIR/catalog"
    mv "$TEST_TEMP_DIR/catalog" "$MOCK_CONFIG_DIR/agent-profiles.json"
    run "$SCRIPTS_DIR/agent-profile.sh" capture saved
    assert_success
    jq -e '.default == "claude-only" and .profiles.saved.engine == "claude" and .profiles.saved.phases.POST_IMPL_REVIEW == "codex" and .profiles.saved.settings == {}' "$MOCK_CONFIG_DIR/agent-profiles.json"
    cp "$MOCK_CONFIG_DIR/agent-profiles.json" "$TEST_TEMP_DIR/before"
    run "$SCRIPTS_DIR/agent-profile.sh" capture saved
    assert_failure
    cmp "$TEST_TEMP_DIR/before" "$MOCK_CONFIG_DIR/agent-profiles.json"
    [ ! -e "$MOCK_CONFIG_DIR/.agent-profile" ]
}

@test "named profiles: config root with spaces isolates relative catalog and state" {
    _named
    mkdir "$TEST_TEMP_DIR/second project"
    cp "$AGENT_CONFIG" "$TEST_TEMP_DIR/second project/config.env"
    cp "$MOCK_CONFIG_DIR/agent-profiles.json" "$TEST_TEMP_DIR/second project/catalog.json"
    run env AGENT_CONFIG="$TEST_TEMP_DIR/second project/config.env" AGENT_PROFILES_FILE=catalog.json AGENT_PROFILE_STATE_FILE=choice "$SCRIPTS_DIR/agent-profile.sh" use codex-only
    assert_success
    [ "$(cat "$TEST_TEMP_DIR/second project/choice")" = codex-only ]
    [ ! -e "$MOCK_CONFIG_DIR/.agent-profile" ]
}

@test "named profiles: concurrent switches leave complete state and write failure preserves it" {
    _named
    "$SCRIPTS_DIR/agent-profile.sh" use codex-only > "$TEST_TEMP_DIR/one" &
    first=$!
    "$SCRIPTS_DIR/agent-profile.sh" use claude-only > "$TEST_TEMP_DIR/two" &
    second=$!
    wait "$first"
    wait "$second"
    [[ "$(cat "$MOCK_CONFIG_DIR/.agent-profile")" =~ ^(claude|codex)-only$ ]]
    cp "$MOCK_CONFIG_DIR/.agent-profile" "$TEST_TEMP_DIR/before"
    run env AGENT_PROFILE_STATE_FILE=absent/state "$SCRIPTS_DIR/agent-profile.sh" use legacy
    assert_failure
    cmp "$TEST_TEMP_DIR/before" "$MOCK_CONFIG_DIR/.agent-profile"
}

@test "named profiles: frozen preflight agrees with preview despite later file edits" {
    _named
    _codex_worker
    export AGENT_PROFILE=codex-only AGENT_ENGINE_POST_IMPL_REVIEW=claude AGENT_TIMEOUT_CODEX=71
    agent_profiles_prepare
    preview=$(agent_profile_preview)
    agent_preflight_dispatch implement
    jq -e --argjson preview "$preview" 'to_entries | all(.[]; (.value | del(.schema_json)) == $preview.phases[.key])' <<< "$AGENT_PHASE_MAP"
    echo claude-only > "$MOCK_CONFIG_DIR/.agent-profile"
    echo broken > "$MOCK_CONFIG_DIR/agent-profiles.json"
    run run_agent prompt Read ignored '' IMPLEMENT
    assert_success
    jq -e '.status == "success" and .engine == "codex"' <<< "$output"
    [ ! -e "$TEST_TEMP_DIR/claude-auth" ]
}

@test "named profiles: read only commands never invoke external services or change selection" {
    _named
    create_mock gh 'unexpected' 99
    create_mock claude 'unexpected' 99
    create_mock codex 'unexpected' 99
    echo codex-only > "$MOCK_CONFIG_DIR/.agent-profile"
    run "$SCRIPTS_DIR/agent-profile.sh" list
    assert_success
    run "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    [ "$(cat "$MOCK_CONFIG_DIR/.agent-profile")" = codex-only ]
    [ -z "$(get_mock_calls gh)$(get_mock_calls claude)$(get_mock_calls codex)" ]
}

@test "named profiles: state with NUL or multiple names and concatenated JSON are rejected" {
    _named
    printf 'cod\0ex-only\n' > "$MOCK_CONFIG_DIR/.agent-profile"
    run "$SCRIPTS_DIR/agent-profile.sh" show
    assert_failure
    assert_output --partial 'Invalid saved'
    printf 'codex-only\nclaude-only\n' > "$MOCK_CONFIG_DIR/.agent-profile"
    run "$SCRIPTS_DIR/agent-profile.sh" show
    assert_failure
    rm "$MOCK_CONFIG_DIR/.agent-profile"
    cat "$SCRIPTS_DIR/../agent-profiles.example.json" >> "$MOCK_CONFIG_DIR/agent-profiles.json"
    run "$SCRIPTS_DIR/agent-profile.sh" list
    assert_failure
}

@test "named profiles: invalid selected values fail while inactive settings and routes stay inactive" {
    _named
    export AGENT_TIMEOUT_CLAUDE=invalid AGENT_ENGINE_TRIAGE=invalid AGENT_ENGINE=invalid
    run "$SCRIPTS_DIR/agent-profile.sh" show codex-only --json
    assert_success
    for value in 0 false; do
        run env AGENT_TIMEOUT_CODEX="$value" "$SCRIPTS_DIR/agent-profile.sh" use codex-only
        assert_failure
        [ ! -e "$MOCK_CONFIG_DIR/.agent-profile" ]
    done
    run env AGENT_BUDGET_USD_CODEX=0 "$SCRIPTS_DIR/agent-profile.sh" show codex-only
    assert_failure
    run env AGENT_CODEX_USE_NATIVE_POLICY=false "$SCRIPTS_DIR/agent-profile.sh" show codex-only
    assert_failure
}

@test "named profiles: catalog default and explicit legacy resolve with no provider CLI or bot identity" {
    _named
    jq '.default="codex-only"' "$MOCK_CONFIG_DIR/agent-profiles.json" > "$TEST_TEMP_DIR/catalog"
    mv "$TEST_TEMP_DIR/catalog" "$MOCK_CONFIG_DIR/agent-profiles.json"
    run env -u AGENT_BOT_USER "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "codex-only" and .selection_source == "catalog"' <<< "$output"
    echo legacy > "$MOCK_CONFIG_DIR/.agent-profile"
    run "$SCRIPTS_DIR/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "legacy" and .selection_source == "state"' <<< "$output"
}

@test "named profiles: configuration errors use controlled semantic failure before handler mutation" {
    _named
    mkdir -p "$TEST_TEMP_DIR/install" "$TEST_TEMP_DIR/home"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/install/scripts"
    create_mock gh ''
    create_mock claude 'unexpected worker'
    create_mock codex 'unexpected worker'
    echo broken > "$MOCK_CONFIG_DIR/agent-profiles.json"
    run env HOME="$TEST_TEMP_DIR/home" AGENT_PROFILE=codex-only AGENT_EXECUTION_MODE=orchestrator \
        bash "$TEST_TEMP_DIR/install/scripts/sandbox-pal-dispatch.sh" new_issue test-org/test-repo 99
    assert_success
    jq -e '.outcome == "agent:failed" and .exit_code == 0' <<< "${lines[${#lines[@]}-1]}"
    [ ! -e "$TEST_TEMP_DIR/mock_calls_claude" ]
    [ ! -e "$TEST_TEMP_DIR/mock_calls_codex" ]
    [ "$(grep -c -- '--add-label agent:failed' "$TEST_TEMP_DIR/mock_calls_gh")" = 1 ]
    ! grep -q 'issue comment\|pr create' "$TEST_TEMP_DIR/mock_calls_gh"
    [ ! -e "$AGENT_LOG_DIR/locks/test-repo-99.lock" ]
}

@test "named profiles: missing custom config follows runtime fallback in helper and dispatcher loader" {
    _named
    mkdir -p "$TEST_TEMP_DIR/runtime"
    cp -R "$SCRIPTS_DIR" "$TEST_TEMP_DIR/runtime/scripts"
    cp "$MOCK_CONFIG_DIR/agent-profiles.json" "$TEST_TEMP_DIR/runtime/agent-profiles.json"
    printf 'AGENT_ENGINE_PROFILES=true\nAGENT_PROFILE=claude-only\n' > "$TEST_TEMP_DIR/runtime/config.defaults.env"
    run env AGENT_CONFIG="$TEST_TEMP_DIR/absent/config.env" CONFIG_DIR="$MOCK_CONFIG_DIR" "$TEST_TEMP_DIR/runtime/scripts/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "claude-only"' <<< "$output"
    printf 'AGENT_PROFILE=codex-only\n' > "$TEST_TEMP_DIR/runtime/config.env"
    run env AGENT_CONFIG="$TEST_TEMP_DIR/absent/config.env" "$TEST_TEMP_DIR/runtime/scripts/agent-profile.sh" show --json
    assert_success
    jq -e '.profile == "codex-only"' <<< "$output"
}

@test "named profiles: invalid directory destination fails without writing into it" {
    _named
    mkdir "$MOCK_CONFIG_DIR/destination"
    run agent_profile_atomic_write "$MOCK_CONFIG_DIR/destination" codex-only
    assert_failure
    [ -z "$(ls -A "$MOCK_CONFIG_DIR/destination")" ]
    run agent_resolve_phase $'TRIAGE\nREPLY'
    assert_failure
}

@test "named profiles: named switches restore Claude adapter arguments and preserve direct explicit models" {
    _named
    _codex_worker
    export AGENT_MODEL_CLAUDE=claude-custom AGENT_MODEL_CODEX=codex-custom AGENT_TIMEOUT_CLAUDE=81 AGENT_TIMEOUT_CODEX=93
    export AGENT_BUDGET_USD_CLAUDE=12 AGENT_MAX_TURNS_CLAUDE=7 AGENT_EFFORT_CLAUDE=high
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_TEMP_DIR/claude-args"
echo '{"result":"done"}'
MOCK
    cat > "$TEST_TEMP_DIR/bin/timeout" <<'MOCK'
#!/bin/bash
printf '%s\n' "$1" > "$TEST_TEMP_DIR/timeout-arg"
shift
exec "$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude" "$TEST_TEMP_DIR/bin/timeout"
    "$SCRIPTS_DIR/agent-profile.sh" capture saved > /dev/null
    echo saved > "$MOCK_CONFIG_DIR/.agent-profile"
    run run_agent prompt Read '' '' IMPLEMENT
    assert_success
    jq -e '.engine == "claude" and .status == "success"' <<< "$output"
    cp "$TEST_TEMP_DIR/claude-args" "$TEST_TEMP_DIR/before-args"
    [ "$(cat "$TEST_TEMP_DIR/timeout-arg")" = 81 ]
    echo codex-only > "$MOCK_CONFIG_DIR/.agent-profile"
    run run_agent prompt Read explicit-model '' IMPLEMENT
    assert_success
    jq -e '.engine == "codex" and .status == "success"' <<< "$output"
    jq -e '.argv | index("--model=explicit-model") != null' "$TEST_TEMP_DIR/invocation.json"
    echo saved > "$MOCK_CONFIG_DIR/.agent-profile"
    run run_agent prompt Read '' '' IMPLEMENT
    assert_success
    jq -e '.engine == "claude" and .status == "success"' <<< "$output"
    # The generated settings file has a new name on every run (#135).
    cmp <(grep -v '/claude-settings-' "$TEST_TEMP_DIR/before-args") <(grep -v '/claude-settings-' "$TEST_TEMP_DIR/claude-args")
    grep -qx 12 "$TEST_TEMP_DIR/claude-args"
    grep -qx 7 "$TEST_TEMP_DIR/claude-args"
}
