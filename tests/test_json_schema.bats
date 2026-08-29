#!/usr/bin/env bats
# Tests for structured phase output via --json-schema (#96).
# The CLI validates the phase's final output against a schema and returns
# it in the envelope's .structured_output — a guaranteed-shape object
# instead of text parsing.

load 'helpers/test_helper'

_source_common() {
    source "${LIB_DIR}/common.sh"
}

SCHEMAS=(triage reply validate adversarial-plan post-impl-review post-impl-retry cleanup)

@test "schemas: all seven phase schemas exist, are valid JSON, and require action" {
    local s
    for s in "${SCHEMAS[@]}"; do
        [ -f "${SCRIPTS_DIR}/../schemas/${s}.json" ]
        jq -e '.required | index("action")' "${SCRIPTS_DIR}/../schemas/${s}.json" >/dev/null
    done
}

@test "run_claude: passes --json-schema with the minified schema when a schema file is given" {
    _source_common
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    echo '{"type": "object", "required": ["action"]}' > "${TEST_TEMP_DIR}/s.json"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TEMP_DIR:-/tmp}/claude_args"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    run run_claude "prompt" "" "" "${TEST_TEMP_DIR}/s.json"
    grep -q -- "--json-schema" "${TEST_TEMP_DIR}/claude_args"
    grep -q '{"type":"object","required":\["action"\]}' "${TEST_TEMP_DIR}/claude_args"
}

@test "run_claude: no --json-schema flag when the schema argument is empty" {
    _source_common
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TEMP_DIR:-/tmp}/claude_args"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    run run_claude "prompt" "" ""
    ! grep -q -- "--json-schema" "${TEST_TEMP_DIR}/claude_args"
}

@test "run_claude: missing schema file is skipped with a warning, not a failure" {
    _source_common
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TEMP_DIR:-/tmp}/claude_args"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"

    run run_claude "prompt" "" "" "${TEST_TEMP_DIR}/does-not-exist.json"
    assert_output --partial '"result":"ok"'
    ! grep -q -- "--json-schema" "${TEST_TEMP_DIR}/claude_args"
}

@test "get_structured_output: returns the compact validated object from the envelope" {
    _source_common
    run get_structured_output '{"result":"...","structured_output":{"action":"plan_ready","summary":"s"}}'
    assert_output '{"action":"plan_ready","summary":"s"}'
}

@test "get_structured_output: empty when structured_output is absent or null" {
    _source_common
    run get_structured_output '{"result":"plain text"}'
    assert_output ""
    run get_structured_output '{"result":"x","structured_output":null}'
    assert_output ""
}

@test "defaults: schema vars default to the shipped schemas and empty explicitly disables" {
    export SCRIPT_DIR="${SCRIPTS_DIR}"
    export AGENT_BOT_USER="test-bot"
    export AGENT_JSON_SCHEMA_VALIDATE=""
    source "${LIB_DIR}/defaults.sh"

    [[ "$AGENT_JSON_SCHEMA_TRIAGE" == *"schemas/triage.json" ]]
    [ -z "$AGENT_JSON_SCHEMA_VALIDATE" ]
}

@test "dispatch: schemas are wired to the machine-consumed phases and structured output is preferred" {
    grep -q "AGENT_JSON_SCHEMA_TRIAGE" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "AGENT_JSON_SCHEMA_POST_IMPL_REVIEW" "${SCRIPTS_DIR}/lib/review-gates.sh"
    grep -q "get_structured_output" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "get_structured_output" "${SCRIPTS_DIR}/lib/review-gates.sh"
}
