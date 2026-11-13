#!/usr/bin/env bats
# Tests for the strict sandbox profile (#137): a phase that asks for it
# is launched under the sandbox runtime with a generated configuration,
# and a profile that cannot start fails the phase before any worker runs.
# The runtime is mocked here; tests/test_sandbox_canary.bats runs the
# real one where it is installed.

load 'helpers/test_helper'

_setup() {
    source "${LIB_DIR}/common.sh"
    export HOME="${TEST_TEMP_DIR}/home"
    mkdir -p "$HOME/.ssh" "$HOME/.config/gh" "$HOME/.claude" "${TEST_TEMP_DIR}/bin"
    git init -q "${TEST_TEMP_DIR}/clone"
    git -C "${TEST_TEMP_DIR}/clone" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
    rmdir "$WORKTREE_DIR"
    git -C "${TEST_TEMP_DIR}/clone" worktree add -q "$WORKTREE_DIR" -b work
    unset AGENT_SANDBOX AGENT_SANDBOX_TRIAGE AGENT_SANDBOX_IMPLEMENT AGENT_SANDBOX_SRT CLAUDE_CONFIG_DIR
    unset AGENT_SANDBOX_ALLOWED_DOMAINS AGENT_SANDBOX_DENY_READ AGENT_SANDBOX_ALLOW_WRITE
    unset AGENT_SANDBOX_UNIX_SOCKETS AGENT_PHASE_GH_TOKEN_FILE AGENT_CONFIG GIT_CONFIG_COUNT
    export PATH="${TEST_TEMP_DIR}/bin:${PATH}"
}

# A runtime that records how it was called, keeps a copy of its
# configuration, and runs the command after `--` unsandboxed.
_mock_runtime() {
    local tool
    cat > "${TEST_TEMP_DIR}/bin/srt" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" >> "${TEST_TEMP_DIR}/srt_args"
[ "$1" = "-s" ] && cp "$2" "${TEST_TEMP_DIR}/srt_config.json"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
[ "${SRT_FAILS:-}" != "" ] && { echo "$SRT_FAILS" >&2; exit 1; }
exec "$@"
MOCK
    for tool in bwrap socat rg; do
        printf '#!/bin/bash\nexit 0\n' > "${TEST_TEMP_DIR}/bin/${tool}"
    done
    cat > "${TEST_TEMP_DIR}/bin/claude" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "${TEST_TEMP_DIR}/claude_args"
env > "${TEST_TEMP_DIR}/claude_env"
echo '{"result":"ok"}'
MOCK
    chmod +x "${TEST_TEMP_DIR}/bin/"*
}

_git_dir() {
    git -C "${TEST_TEMP_DIR}/clone" rev-parse --path-format=absolute --git-common-dir
}

# ─── Choosing a profile ──────────────────────────────────────────

@test "profile: none by default, so an install that sets nothing is unchanged" {
    _setup
    run agent_sandbox_profile TRIAGE
    assert_output "none"
}

@test "profile: AGENT_SANDBOX applies to every phase" {
    _setup
    export AGENT_SANDBOX=strict
    run agent_sandbox_profile IMPLEMENT
    assert_output "strict"
}

@test "profile: AGENT_SANDBOX_<PHASE> overrides the global setting either way" {
    _setup
    export AGENT_SANDBOX=strict AGENT_SANDBOX_IMPLEMENT=none
    run agent_sandbox_profile IMPLEMENT
    assert_output "none"
    export AGENT_SANDBOX=none AGENT_SANDBOX_TRIAGE=strict
    run agent_sandbox_profile TRIAGE
    assert_output "strict"
}

@test "profile: an unknown profile is refused" {
    _setup
    export AGENT_SANDBOX=loose
    run agent_sandbox_profile TRIAGE
    assert_failure
    assert_output --partial "AGENT_SANDBOX"
}

@test "profile: gpu is named as not available yet" {
    _setup
    export AGENT_SANDBOX=gpu
    run agent_sandbox_profile TRIAGE
    assert_failure
    assert_output --partial "not available"
}

# ─── The generated configuration ─────────────────────────────────

@test "config: only the worktree, the clone's git directory, the temp directory and the Claude directory are writable" {
    _setup
    run agent_sandbox_config
    assert_success
    run jq -c '.filesystem.allowWrite' <<< "$output"
    assert_output "$(jq -cn --arg w "$(cd "$WORKTREE_DIR" && pwd -P)" --arg g "$(_git_dir)" --arg c "$HOME/.claude" '[$w,"/tmp",$c,$g] | unique')"
}

@test "config: the clone's hooks and config cannot be written" {
    _setup
    run agent_sandbox_config
    [ "$(jq --arg g "$(_git_dir)" '.filesystem.denyWrite | (index($g + "/hooks") != null) and (index($g + "/config") != null)' <<< "$output")" = "true" ]
}

@test "config: Claude settings, skills, plugins and hooks cannot be written" {
    _setup
    run agent_sandbox_config
    local name
    for name in settings.json settings.local.json CLAUDE.md skills plugins commands agents hooks; do
        [ "$(jq --arg p "$HOME/.claude/$name" '.filesystem.denyWrite | index($p) != null' <<< "$output")" = "true" ] || fail "$name is writable"
    done
}

@test "config: CLAUDE_CONFIG_DIR moves the Claude directory" {
    _setup
    export CLAUDE_CONFIG_DIR="${TEST_TEMP_DIR}/claude-config"
    run agent_sandbox_config
    [ "$(jq --arg c "$CLAUDE_CONFIG_DIR" '(.filesystem.allowWrite | index($c) != null) and (.filesystem.denyWrite | index($c + "/settings.json") != null)' <<< "$output")" = "true" ]
}

@test "config: the dispatch log directory cannot be written" {
    _setup
    run agent_sandbox_config
    [ "$(jq --arg l "$AGENT_LOG_DIR" '.filesystem.denyWrite | index($l) != null' <<< "$output")" = "true" ]
}

@test "config: credential stores that exist are hidden; ones that do not are not listed" {
    _setup
    run agent_sandbox_config
    [ "$(jq --arg h "$HOME" '.filesystem.denyRead | (index($h + "/.ssh") != null) and (index($h + "/.config/gh") != null)' <<< "$output")" = "true" ]
    [ "$(jq --arg h "$HOME" '.filesystem.denyRead | index($h + "/.aws")' <<< "$output")" = "null" ]
}

@test "config: .env files and the install's config.env are hidden" {
    _setup
    export AGENT_CONFIG="${TEST_TEMP_DIR}/config.env"
    echo 'SECRET=1' > "$AGENT_CONFIG"
    run agent_sandbox_config
    [ "$(jq --arg c "$AGENT_CONFIG" '.filesystem.denyRead | (index("**/.env") != null) and (index($c) != null)' <<< "$output")" = "true" ]
}

@test "config: the phase token's file is hidden from the phase" {
    _setup
    echo 'tok_readonly_12345' > "${TEST_TEMP_DIR}/phase-token"
    export AGENT_PHASE_GH_TOKEN_FILE="${TEST_TEMP_DIR}/phase-token"
    run agent_sandbox_config
    [ "$(jq --arg t "$AGENT_PHASE_GH_TOKEN_FILE" '.filesystem.denyRead | index($t) != null' <<< "$output")" = "true" ]
}

@test "config: AGENT_SANDBOX_DENY_READ and AGENT_SANDBOX_ALLOW_WRITE add paths" {
    _setup
    export AGENT_SANDBOX_DENY_READ="/srv/tokens /srv/keys" AGENT_SANDBOX_ALLOW_WRITE="/var/cache/build"
    run agent_sandbox_config
    [ "$(jq '.filesystem.denyRead | (index("/srv/tokens") != null) and (index("/srv/keys") != null)' <<< "$output")" = "true" ]
    [ "$(jq '.filesystem.allowWrite | index("/var/cache/build") != null' <<< "$output")" = "true" ]
}

@test "config: the network reaches the model provider and GitHub, and nothing else" {
    _setup
    run agent_sandbox_config
    [ "$(jq '.network.allowedDomains | (index("api.anthropic.com") != null) and (index("github.com") != null) and (index("api.github.com") != null)' <<< "$output")" = "true" ]
    [ "$(jq '.network.allowedDomains | map(select(test("npmjs|pypi|\\*$"))) | length' <<< "$output")" = "0" ]
}

@test "config: AGENT_SANDBOX_ALLOWED_DOMAINS adds a repo's own hosts" {
    _setup
    export AGENT_SANDBOX_ALLOWED_DOMAINS="registry.npmjs.org, *.example.org"
    run agent_sandbox_config
    [ "$(jq '.network.allowedDomains | (index("registry.npmjs.org") != null) and (index("*.example.org") != null)' <<< "$output")" = "true" ]
}

@test "config: Unix sockets stay blocked unless a repo opts in" {
    _setup
    run agent_sandbox_config
    [ "$(jq '.network | has("allowAllUnixSockets")' <<< "$output")" = "false" ]
    export AGENT_SANDBOX_UNIX_SOCKETS=true
    run agent_sandbox_config
    [ "$(jq '.network.allowAllUnixSockets' <<< "$output")" = "true" ]
}

# ─── Git inside the sandbox ──────────────────────────────────────

@test "excludes: the phantom paths are ignored, after the operator's own excludes" {
    _setup
    mkdir -p "$HOME/.config/git"
    echo '*.swp' > "$HOME/.config/git/ignore"
    agent_sandbox_write_excludes "${TEST_TEMP_DIR}/excludes"
    run cat "${TEST_TEMP_DIR}/excludes"
    assert_line '*.swp'
    assert_line '.bashrc'
    assert_line '.mcp.json'
    assert_line '.claude/commands'
}

@test "excludes: they reach git through the environment and add to what is there" {
    _setup
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=someone
    agent_sandbox_git_env "/path/to/excludes"
    [ "$GIT_CONFIG_COUNT" = "2" ]
    [ "$GIT_CONFIG_KEY_0" = "user.name" ]
    [ "$GIT_CONFIG_KEY_1" = "core.excludesFile" ]
    [ "$GIT_CONFIG_VALUE_1" = "/path/to/excludes" ]
}

# ─── Launch ──────────────────────────────────────────────────────

@test "launch: without a profile the runtime is not involved" {
    _setup
    _mock_runtime
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(jq -r .status <<< "$output")" = "success" ]
    [ ! -e "${TEST_TEMP_DIR}/srt_args" ]
}

@test "launch: strict runs the worker under the runtime with the generated configuration" {
    _setup
    _mock_runtime
    export AGENT_SANDBOX=strict
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    assert_success
    [ "$(jq -r .status <<< "$output")" = "success" ]
    grep -qx -- "claude" "${TEST_TEMP_DIR}/srt_args"
    grep -qx -- "--settings" "${TEST_TEMP_DIR}/claude_args"
    jq -e '.filesystem.allowWrite and .network.allowedDomains' "${TEST_TEMP_DIR}/srt_config.json" >/dev/null
}

@test "launch: only the phases that ask for strict are wrapped" {
    _setup
    _mock_runtime
    export AGENT_SANDBOX_IMPLEMENT=strict
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    [ ! -e "${TEST_TEMP_DIR}/srt_args" ]
    run run_agent "prompt" "Read" "" "" "IMPLEMENT"
    grep -qx -- "claude" "${TEST_TEMP_DIR}/srt_args"
}

@test "launch: the worker's git is given the phantom-path excludes" {
    _setup
    _mock_runtime
    export AGENT_SANDBOX=strict
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    grep -q '^GIT_CONFIG_KEY_0=core.excludesFile$' "${TEST_TEMP_DIR}/claude_env"
}

@test "launch: the generated sandbox files are removed afterwards" {
    _setup
    _mock_runtime
    export AGENT_SANDBOX=strict
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    assert_success
    run find "$AGENT_LOG_DIR" -name 'sandbox-*'
    assert_output ""
}

@test "launch: AGENT_SANDBOX_SRT names the runtime when it is not on PATH" {
    _setup
    _mock_runtime
    mkdir -p "${TEST_TEMP_DIR}/opt"
    mv "${TEST_TEMP_DIR}/bin/srt" "${TEST_TEMP_DIR}/opt/srt"
    export AGENT_SANDBOX=strict AGENT_SANDBOX_SRT="${TEST_TEMP_DIR}/opt/srt"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r .status <<< "$output")" = "success" ]
    grep -qx -- "claude" "${TEST_TEMP_DIR}/srt_args"
}

# ─── Failing closed ──────────────────────────────────────────────

@test "fail closed: a missing runtime is a configuration error and no worker starts" {
    _setup
    _mock_runtime
    rm "${TEST_TEMP_DIR}/bin/srt"
    export AGENT_SANDBOX=strict AGENT_SANDBOX_SRT="${TEST_TEMP_DIR}/nowhere/srt"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r .error.kind <<< "$output")" = "configuration" ]
    [[ "$(jq -r .error.message <<< "$output")" == *"srt"* ]]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}

@test "fail closed: a runtime that cannot start is a configuration error and no worker starts" {
    _setup
    _mock_runtime
    export AGENT_SANDBOX=strict SRT_FAILS="bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r .error.kind <<< "$output")" = "configuration" ]
    [[ "$(jq -r .error.message <<< "$output")" == *"could not start"*"RTM_NEWADDR"* ]]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}

@test "fail closed: an unknown profile fails the phase" {
    _setup
    _mock_runtime
    export AGENT_SANDBOX=relaxed
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r .error.kind <<< "$output")" = "configuration" ]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}

@test "fail closed: strict on a Codex phase is refused, not silently skipped" {
    _setup
    export AGENT_SANDBOX=strict AGENT_ENGINE=codex
    run agent_resolve_config TRIAGE
    assert_failure
    assert_output --partial "Claude phases only"
}

# ─── The phase's own GitHub token ────────────────────────────────

@test "phase token: the file's value reaches the phase as GH_TOKEN, replacing nothing of the dispatcher's" {
    _setup
    _mock_runtime
    printf 'tok_readonly_12345\n' > "${TEST_TEMP_DIR}/phase-token"
    export AGENT_PHASE_GH_TOKEN_FILE="${TEST_TEMP_DIR}/phase-token" GH_TOKEN="dispatcher_write_token"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    assert_success
    grep -qx 'GH_TOKEN=tok_readonly_12345' "${TEST_TEMP_DIR}/claude_env"
    ! grep -q 'dispatcher_write_token' "${TEST_TEMP_DIR}/claude_env"
    [ "$GH_TOKEN" = "dispatcher_write_token" ]
}

@test "phase token: without the setting a phase has no GitHub token" {
    _setup
    _mock_runtime
    export GH_TOKEN="dispatcher_write_token"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    ! grep -q '^GH_TOKEN=' "${TEST_TEMP_DIR}/claude_env"
}

@test "phase token: a relative path resolves against the config directory" {
    _setup
    _mock_runtime
    printf 'tok_relative_12345' > "${MOCK_CONFIG_DIR}/phase-token"
    export CONFIG_DIR="$MOCK_CONFIG_DIR" AGENT_PHASE_GH_TOKEN_FILE="phase-token"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    grep -qx 'GH_TOKEN=tok_relative_12345' "${TEST_TEMP_DIR}/claude_env"
}

@test "phase token: a missing or empty file fails the phase as a configuration error" {
    _setup
    _mock_runtime
    export AGENT_PHASE_GH_TOKEN_FILE="${TEST_TEMP_DIR}/absent-token"
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    [ "$(jq -r .error.kind <<< "$output")" = "configuration" ]
    [[ "$(jq -r .error.message <<< "$output")" == *"AGENT_PHASE_GH_TOKEN_FILE"* ]]
    [ ! -e "${TEST_TEMP_DIR}/claude_args" ]
}

@test "phase token: its value is redacted from anything the dispatcher prints" {
    _setup
    printf 'tok_readonly_12345\n' > "${TEST_TEMP_DIR}/phase-token"
    export AGENT_PHASE_GH_TOKEN_FILE="${TEST_TEMP_DIR}/phase-token"
    run redact_secrets <<< "the worker echoed tok_readonly_12345 into its output"
    refute_output --partial "tok_readonly_12345"
    assert_output --partial "[REDACTED:PHASE_GH_TOKEN]"
}

@test "phase token: the value never appears in the phase's command line" {
    _setup
    _mock_runtime
    printf 'tok_readonly_12345\n' > "${TEST_TEMP_DIR}/phase-token"
    export AGENT_PHASE_GH_TOKEN_FILE="${TEST_TEMP_DIR}/phase-token" AGENT_SANDBOX=strict
    run run_agent "prompt" "Read" "" "" "TRIAGE"
    ! grep -q 'tok_readonly_12345' "${TEST_TEMP_DIR}/claude_args" "${TEST_TEMP_DIR}/srt_args" "${TEST_TEMP_DIR}/srt_config.json"
}
