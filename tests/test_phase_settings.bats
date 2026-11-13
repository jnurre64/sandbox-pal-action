#!/usr/bin/env bats
# Tests for the pipeline-owned settings file (#135): a phase is launched
# with --settings (its permission rules, generated per phase) and
# --setting-sources, so what it loads is chosen by the pipeline and not
# inherited from whoever operates the machine.

load 'helpers/test_helper'

_setup_mock_claude() {
    source "${LIB_DIR}/common.sh"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    # The settings file is removed after the run, so the mock keeps a copy.
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TEMP_DIR}/claude_args"
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--settings" ]; then
        printf '%s\n' "$2" > "${TEST_TEMP_DIR}/settings_path"
        cp "$2" "${TEST_TEMP_DIR}/settings_seen.json"
    fi
    shift
done
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
}

_arg_after() {
    grep -x -A1 -- "$1" "${TEST_TEMP_DIR}/claude_args" | tail -n 1
}

# ─── Rule splitting ──────────────────────────────────────────────

@test "rules: a comma-separated tool list becomes one rule per line" {
    source "${LIB_DIR}/common.sh"
    run agent_split_tool_rules "Read,Write,Bash(git add:*),Bash(ls:*)"
    assert_success
    assert_output "Read
Write
Bash(git add:*)
Bash(ls:*)"
}

@test "rules: a comma inside parentheses does not split the rule" {
    source "${LIB_DIR}/common.sh"
    run agent_split_tool_rules "Read,Bash(curl *a,b*),Grep"
    assert_success
    assert_output "Read
Bash(curl *a,b*)
Grep"
}

@test "rules: surrounding spaces and empty entries are dropped" {
    source "${LIB_DIR}/common.sh"
    run agent_split_tool_rules " Read , ,Grep,"
    assert_success
    assert_output "Read
Grep"
}

@test "rules: an empty list yields nothing" {
    source "${LIB_DIR}/common.sh"
    run agent_split_tool_rules ""
    assert_success
    assert_output ""
}

# ─── The generated file ──────────────────────────────────────────

@test "settings: the phase is launched with a --settings file" {
    _setup_mock_claude
    run run_claude "prompt" "Read,Bash(echo:*)" "" "" "TRIAGE"
    assert_success
    grep -qx -- "--settings" "${TEST_TEMP_DIR}/claude_args"
    jq -e . "${TEST_TEMP_DIR}/settings_seen.json" >/dev/null
}

@test "settings: the phase's allowed tools are the file's allow rules" {
    _setup_mock_claude
    run run_claude "prompt" "Read,Bash(git add:*),Bash(curl *a,b*)" "" "" "IMPLEMENT"
    assert_success
    run jq -c '.permissions.allow' "${TEST_TEMP_DIR}/settings_seen.json"
    assert_output '["Read","Bash(git add:*)","Bash(curl *a,b*)"]'
}

@test "settings: the disallowed tools are the file's deny rules" {
    _setup_mock_claude
    export AGENT_DISALLOWED_TOOLS="mcp__github__*,WebFetch"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    run jq -c '.permissions.deny' "${TEST_TEMP_DIR}/settings_seen.json"
    assert_output '["mcp__github__*","WebFetch"]'
}

@test "settings: the rules are not repeated on the command line" {
    _setup_mock_claude
    run run_claude "prompt" "Read,Bash(echo:*)" "" "" "TRIAGE"
    assert_success
    ! grep -qE -- "^--(allowedTools|disallowedTools)$" "${TEST_TEMP_DIR}/claude_args"
}

@test "settings: the generated file is removed after the phase" {
    _setup_mock_claude
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ ! -e "$(cat "${TEST_TEMP_DIR}/settings_path")" ]
}

@test "settings: the generated file is removed when the phase fails" {
    _setup_mock_claude
    cat >> "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
exit 1
MOCK
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    [ ! -e "$(cat "${TEST_TEMP_DIR}/settings_path")" ]
}

@test "settings: the generated file is private to the operator" {
    _setup_mock_claude
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
while [ "$#" -gt 0 ]; do
    [ "$1" = "--settings" ] && stat -c '%a' "$2" > "${TEST_TEMP_DIR}/settings_mode"
    shift
done
echo '{"result":"ok"}'
MOCK
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(cat "${TEST_TEMP_DIR}/settings_mode")" = "600" ]
}

# ─── AGENT_SETTINGS_FILE: a repo's own base settings ─────────────

@test "base file: AGENT_SETTINGS_FILE is the base the phase rules are added to" {
    _setup_mock_claude
    cat > "${TEST_TEMP_DIR}/base.json" <<'JSON'
{"env":{"PROJECT_FLAG":"1"},"permissions":{"allow":["Bash(make:*)"],"deny":["Read(./secrets/**)"]}}
JSON
    export AGENT_SETTINGS_FILE="${TEST_TEMP_DIR}/base.json"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    run jq -c '[.env.PROJECT_FLAG, .permissions.allow, .permissions.deny]' "${TEST_TEMP_DIR}/settings_seen.json"
    assert_output '["1",["Bash(make:*)","Read"],["Read(./secrets/**)","mcp__github__*"]]'
}

@test "base file: a relative AGENT_SETTINGS_FILE resolves against the config directory" {
    _setup_mock_claude
    echo '{"env":{"FROM_BASE":"yes"}}' > "${MOCK_CONFIG_DIR}/phase-settings.json"
    export CONFIG_DIR="$MOCK_CONFIG_DIR" AGENT_SETTINGS_FILE="phase-settings.json"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    run jq -r '.env.FROM_BASE' "${TEST_TEMP_DIR}/settings_seen.json"
    assert_output "yes"
}

@test "base file: a missing AGENT_SETTINGS_FILE fails the phase as a configuration error" {
    _setup_mock_claude
    export AGENT_SETTINGS_FILE="${TEST_TEMP_DIR}/absent.json"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r '.status' <<< "$output")" = "failed" ]
    [ "$(jq -r '.error.kind' <<< "$output")" = "configuration" ]
    [[ "$(jq -r '.error.message' <<< "$output")" == *"AGENT_SETTINGS_FILE"* ]]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}

@test "base file: an AGENT_SETTINGS_FILE that is not a JSON object fails the phase" {
    _setup_mock_claude
    echo '["not","an","object"]' > "${TEST_TEMP_DIR}/base.json"
    export AGENT_SETTINGS_FILE="${TEST_TEMP_DIR}/base.json"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r '.error.kind' <<< "$output")" = "configuration" ]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}

# ─── --setting-sources ───────────────────────────────────────────

@test "sources: every source is named by default, so an update changes nothing" {
    _setup_mock_claude
    unset AGENT_SETTING_SOURCES
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(_arg_after --setting-sources)" = "user,project,local" ]
}

@test "sources: AGENT_SETTING_SOURCES=project leaves the operator's user settings out" {
    _setup_mock_claude
    export AGENT_SETTING_SOURCES="project"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(_arg_after --setting-sources)" = "project" ]
}

@test "sources: an explicitly empty AGENT_SETTING_SOURCES omits the flag" {
    _setup_mock_claude
    export AGENT_SETTING_SOURCES=""
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    assert_success
    ! grep -qx -- "--setting-sources" "${TEST_TEMP_DIR}/claude_args"
}

@test "sources: an unknown source fails the phase as a configuration error" {
    _setup_mock_claude
    export AGENT_SETTING_SOURCES="project,everything"
    run run_claude "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r '.error.kind' <<< "$output")" = "configuration" ]
    [[ "$(jq -r '.error.message' <<< "$output")" == *"AGENT_SETTING_SOURCES"* ]]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}
