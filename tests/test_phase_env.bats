#!/usr/bin/env bats
# Tests for #142: a phase is launched without the dispatcher's credentials.
# The dispatcher does all GitHub and notification work itself, so no phase
# needs them, and a tool allow list is not what keeps a token from a phase.

load 'helpers/test_helper'

# A claude stub that records the environment it was launched with.
_setup_env_recording_claude() {
    source "${LIB_DIR}/common.sh"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    mkdir -p "${TEST_TEMP_DIR}/bin"
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
[ "${1:-}" = "--help" ] && exit 0
env > "${TEST_TEMP_DIR}/phase_env"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/claude"
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
    unset AGENT_PHASE_KEEP_ENV AGENT_PHASE_SCRUB_ENV
}

_export_credentials() {
    export GH_TOKEN="gh-secret" GITHUB_TOKEN="github-secret" GH_ENTERPRISE_TOKEN="ghe-secret"
    export AGENT_GIST_PAT="gist-secret" AGENT_DISCORD_BOT_TOKEN="discord-bot-secret"
    export AGENT_SLACK_BOT_TOKEN="slack-bot-secret" AGENT_SLACK_APP_TOKEN="slack-app-secret"
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.example.invalid/secret"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="o/r=https://discord.example.invalid/map-secret"
    export AGENT_NOTIFY_SLACK_WEBHOOK="https://slack.example.invalid/secret"
    export AGENT_NOTIFY_SLACK_WEBHOOK_MAP="o/r=https://slack.example.invalid/map-secret"
    export ACTIONS_RUNTIME_TOKEN="runtime-secret" ACTIONS_ID_TOKEN_REQUEST_TOKEN="oidc-secret"
}

@test "phase env: a Claude phase is launched without the dispatcher's credentials" {
    _setup_env_recording_claude
    _export_credentials

    run run_agent "prompt" "" "" "" "IMPLEMENT"

    assert_success
    [ -f "${TEST_TEMP_DIR}/phase_env" ]
    run grep -E 'secret' "${TEST_TEMP_DIR}/phase_env"
    assert_failure
    run grep -E '^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|AGENT_GIST_PAT|ACTIONS_RUNTIME_TOKEN)=' "${TEST_TEMP_DIR}/phase_env"
    assert_failure
}

@test "phase env: everything that is not a dispatcher credential still reaches the phase" {
    _setup_env_recording_claude
    _export_credentials
    export ANTHROPIC_API_KEY="engine-credential" AGENT_ISSUE_TITLE="A title" PROJECT_TOOLCHAIN_HOME="/opt/toolchain"

    run run_agent "prompt" "" "" "" "IMPLEMENT"

    grep -qx 'ANTHROPIC_API_KEY=engine-credential' "${TEST_TEMP_DIR}/phase_env"
    grep -qx 'AGENT_ISSUE_TITLE=A title' "${TEST_TEMP_DIR}/phase_env"
    grep -qx 'PROJECT_TOOLCHAIN_HOME=/opt/toolchain' "${TEST_TEMP_DIR}/phase_env"
    grep -q '^PATH=' "${TEST_TEMP_DIR}/phase_env"
}

@test "phase env: AGENT_PHASE_KEEP_ENV restores a named variable and nothing else" {
    _setup_env_recording_claude
    _export_credentials
    export AGENT_PHASE_KEEP_ENV="GH_TOKEN"

    run run_agent "prompt" "" "" "" "IMPLEMENT"

    grep -qx 'GH_TOKEN=gh-secret' "${TEST_TEMP_DIR}/phase_env"
    ! grep -q '^GITHUB_TOKEN=' "${TEST_TEMP_DIR}/phase_env"
    ! grep -q '^AGENT_GIST_PAT=' "${TEST_TEMP_DIR}/phase_env"
}

@test "phase env: AGENT_PHASE_SCRUB_ENV removes further named variables" {
    _setup_env_recording_claude
    export DEPLOY_KEY="deploy-secret" REGISTRY_PASSWORD="registry-secret"
    export AGENT_PHASE_SCRUB_ENV="DEPLOY_KEY REGISTRY_PASSWORD"

    run run_agent "prompt" "" "" "" "IMPLEMENT"

    run grep -E 'secret' "${TEST_TEMP_DIR}/phase_env"
    assert_failure
}

@test "phase env: the dispatcher keeps its credentials after the phase returns" {
    _setup_env_recording_claude
    _export_credentials

    run_agent "prompt" "" "" "" "IMPLEMENT" > "${TEST_TEMP_DIR}/result"

    [ -f "${TEST_TEMP_DIR}/phase_env" ]
    assert_equal "$GH_TOKEN" "gh-secret"
    assert_equal "$GITHUB_TOKEN" "github-secret"
    assert_equal "$AGENT_NOTIFY_DISCORD_WEBHOOK" "https://discord.example.invalid/secret"
}

@test "phase env: a name that is not a variable name fails the phase before launch" {
    _setup_env_recording_claude
    export AGENT_PHASE_SCRUB_ENV='GOOD_NAME bad-name;x'

    run run_agent "prompt" "" "" "" "IMPLEMENT"

    [ ! -f "${TEST_TEMP_DIR}/phase_env" ]
    run agent_scrub_phase_env
    assert_failure
    assert_output --partial "AGENT_PHASE_SCRUB_ENV"
}

@test "phase env: a Codex phase is launched without the dispatcher's credentials" {
    _setup_env_recording_claude
    _export_credentials
    export CODEX_API_KEY="engine-credential"
    cat > "${TEST_TEMP_DIR}/bin/python3" <<'MOCK'
#!/bin/bash
env > "${TEST_TEMP_DIR}/codex_env"
cat > /dev/null
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/python3"
    agent_engine_enabled() { return 0; }

    run engine_codex "prompt" "" "model" "" "IMPLEMENT" '{"sandbox":"workspace-write","timeout":60}'

    assert_success
    run grep -E 'secret' "${TEST_TEMP_DIR}/codex_env"
    assert_failure
    grep -qx 'CODEX_API_KEY=engine-credential' "${TEST_TEMP_DIR}/codex_env"
}

@test "provenance: startup names the credentials phases will not receive, never their values" {
    source "${LIB_DIR}/common.sh"
    unset AGENT_PHASE_SCRUB_ENV
    _export_credentials
    export AGENT_PHASE_KEEP_ENV="GITHUB_TOKEN"

    run log_config_provenance

    assert_output --partial "Phase environment: withheld"
    assert_output --partial "GH_TOKEN"
    assert_output --partial "kept by AGENT_PHASE_KEEP_ENV: GITHUB_TOKEN"
    refute_output --partial "secret"
}
