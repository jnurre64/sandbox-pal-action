#!/usr/bin/env bats
# Canary for the strict sandbox profile (#137): the real sandbox runtime,
# the configuration the dispatcher generates, and the five things the
# profile promises. No model call is made.
#
# Skipped where the runtime is not installed or cannot start (for example
# a CI runner without bubblewrap, or a kernel that forbids unprivileged
# user namespaces). Set AGENT_SANDBOX_SRT when `srt` is not on PATH.

load 'helpers/test_helper'

_setup_canary() {
    source "${LIB_DIR}/common.sh"
    command -v "${AGENT_SANDBOX_SRT:-srt}" >/dev/null 2>&1 || skip "sandbox runtime (srt) not installed"
    agent_sandbox_check 2>/dev/null || skip "sandbox runtime dependencies missing"

    # Outside /tmp, which the profile leaves writable.
    CANARY_ROOT=$(mktemp -d "${HOME}/.sandbox-pal-canary-XXXXXX")
    export CANARY_ROOT
    mkdir -p "${CANARY_ROOT}/secrets"
    echo "planted-secret-value" > "${CANARY_ROOT}/secrets/token"
    git init -q "${CANARY_ROOT}/clone"
    git -C "${CANARY_ROOT}/clone" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
    export WORKTREE_DIR="${CANARY_ROOT}/worktree"
    git -C "${CANARY_ROOT}/clone" worktree add -q "$WORKTREE_DIR" -b work
    export AGENT_SANDBOX_DENY_READ="${CANARY_ROOT}/secrets"
    unset AGENT_SANDBOX_ALLOWED_DOMAINS AGENT_SANDBOX_ALLOW_WRITE AGENT_SANDBOX_UNIX_SOCKETS GIT_CONFIG_COUNT

    agent_sandbox_config > "${CANARY_ROOT}/sandbox.json"
    agent_sandbox_write_excludes "${CANARY_ROOT}/excludes"
    agent_sandbox_git_env "${CANARY_ROOT}/excludes"
    cd "$WORKTREE_DIR"
    agent_sandbox_run "${CANARY_ROOT}/sandbox.json" true >/dev/null 2>&1 || skip "sandbox runtime cannot start on this machine"
}

teardown() {
    [ -z "${CANARY_ROOT:-}" ] || rm -rf "$CANARY_ROOT"
    rm -rf "$TEST_TEMP_DIR"
}

_in_sandbox() {
    agent_sandbox_run "${CANARY_ROOT}/sandbox.json" bash -c "$1"
}

@test "canary: a planted secret outside the worktree cannot be read" {
    _setup_canary
    run _in_sandbox "cat '${CANARY_ROOT}/secrets/token'"
    assert_failure
    refute_output --partial "planted-secret-value"
}

@test "canary: the same secret is readable outside the sandbox (the test can fail)" {
    _setup_canary
    run cat "${CANARY_ROOT}/secrets/token"
    assert_output "planted-secret-value"
}

@test "canary: a request to a host off the allowlist fails" {
    _setup_canary
    command -v curl >/dev/null 2>&1 || skip "curl not installed"
    run _in_sandbox "curl -s -m 10 -o /dev/null -w '%{http_code}' https://example.com"
    [ "$output" != "200" ]
}

@test "canary: a write outside the worktree fails" {
    _setup_canary
    run _in_sandbox "echo escaped > '${CANARY_ROOT}/outside.txt'"
    assert_failure
    [ ! -e "${CANARY_ROOT}/outside.txt" ]
}

@test "canary: git add -A and git commit work in the worktree" {
    _setup_canary
    run _in_sandbox "echo change > file.txt && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m 'in sandbox' && git log --format=%s -n 1"
    assert_success
    assert_output "in sandbox"
    [ "$(git -C "$WORKTREE_DIR" show --name-only --format= HEAD)" = "file.txt" ]
}

@test "canary: a write to the clone's git hooks fails" {
    _setup_canary
    run _in_sandbox "echo '#!/bin/sh' > '${CANARY_ROOT}/clone/.git/hooks/pre-commit'"
    assert_failure
    [ ! -e "${CANARY_ROOT}/clone/.git/hooks/pre-commit" ]
}

@test "canary: a write to the clone's git config fails" {
    _setup_canary
    local before
    before=$(cat "${CANARY_ROOT}/clone/.git/config")
    run _in_sandbox "echo '[core]' >> '${CANARY_ROOT}/clone/.git/config'"
    assert_failure
    [ "$(cat "${CANARY_ROOT}/clone/.git/config")" = "$before" ]
}

@test "canary: the Claude settings file cannot be written" {
    _setup_canary
    local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    [ -e "$settings" ] || skip "no Claude settings file on this machine"
    local before
    before=$(sha256sum < "$settings")
    run _in_sandbox "echo >> '$settings'"
    assert_failure
    [ "$(sha256sum < "$settings")" = "$before" ]
}
