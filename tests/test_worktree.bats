#!/usr/bin/env bats
# Tests for scripts/lib/worktree.sh (source-level verification)
# Note: worktree operations require real git repos. These tests verify
# the source code structure rather than running git commands.

load 'helpers/test_helper'

@test "worktree.sh: defines ensure_repo function" {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    declare -f ensure_repo > /dev/null
}

@test "worktree.sh: defines setup_worktree function" {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    declare -f setup_worktree > /dev/null
}

@test "worktree.sh: defines cleanup_worktree function" {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    declare -f cleanup_worktree > /dev/null
}

@test "worktree.sh: setup_worktree prunes stale worktrees" {
    grep -q "worktree prune" "${LIB_DIR}/worktree.sh"
}

@test "worktree.sh: setup_worktree checks for remote branch before creating" {
    grep -q "ls-remote.*heads.*BRANCH_NAME" "${LIB_DIR}/worktree.sh"
}

@test "worktree.sh: cleanup_worktree uses --force" {
    grep -q "worktree remove.*--force" "${LIB_DIR}/worktree.sh"
}

@test "worktree.sh: defines run_worktree_setup function" {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    declare -f run_worktree_setup > /dev/null
}

@test "worktree.sh: run_worktree_setup runs AGENT_TEST_SETUP_COMMAND when set" {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    export AGENT_TEST_SETUP_COMMAND="echo setup_ran"
    export WORKTREE_DIR="$TEST_TEMP_DIR/worktree"

    run run_worktree_setup
    assert_success
    assert_output --partial "setup_ran"
}

@test "worktree.sh: run_worktree_setup no-ops when AGENT_TEST_SETUP_COMMAND is empty" {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    export AGENT_TEST_SETUP_COMMAND=""
    export WORKTREE_DIR="$TEST_TEMP_DIR/worktree"

    run run_worktree_setup
    assert_success
    assert_output ""
}

@test "worktree.sh: setup_worktree calls run_worktree_setup" {
    grep -q "run_worktree_setup" "${LIB_DIR}/worktree.sh"
}

# ─── Unsaved work is never discarded ─────────────────────────────
# Real repositories: an "origin", a clone of it (REPO_DIR) and worktrees.
_setup_worktree_repos() {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    export AGENT_TEST_SETUP_COMMAND=""
    local origin="${TEST_TEMP_DIR}/origin.git" seed="${TEST_TEMP_DIR}/seed"
    git init -q --bare -b main "$origin"
    git init -q -b main "$seed"
    git -C "$seed" config user.email t@t && git -C "$seed" config user.name t
    (cd "$seed" && echo base > base.txt && printf '.agent-data/\n' > .gitignore && git add -A && git commit -qm base)
    git -C "$seed" push -q "$origin" main
    export REPO_DIR="${TEST_TEMP_DIR}/repo"
    git clone -q "$origin" "$REPO_DIR"
    git -C "$REPO_DIR" config user.email t@t && git -C "$REPO_DIR" config user.name t
    export WORKTREE_BASE="${TEST_TEMP_DIR}/worktrees"
    export WORKTREE_DIR="${WORKTREE_BASE}/test-repo-issue-99"
    export BRANCH_NAME="agent/issue-99"
    mkdir -p "$WORKTREE_BASE"
}

@test "worktree: a clean worktree on published commits has no unsaved work, even with .agent-data files" {
    _setup_worktree_repos
    setup_worktree
    mkdir -p "$WORKTREE_DIR/.agent-data" && echo plan > "$WORKTREE_DIR/.agent-data/plan.md"
    run worktree_has_unsaved_work
    assert_failure
    cleanup_worktree
    [ ! -d "$WORKTREE_DIR" ]
}

@test "worktree: cleanup keeps a worktree with uncommitted changes" {
    _setup_worktree_repos
    setup_worktree
    echo wip > "$WORKTREE_DIR/new-source.txt"
    run cleanup_worktree
    assert_success
    assert_output --partial "Keeping worktree"
    [ "$(cat "$WORKTREE_DIR/new-source.txt")" = wip ]
}

@test "worktree: cleanup keeps a worktree whose commits are on no remote branch, and removes it once pushed" {
    _setup_worktree_repos
    setup_worktree
    (cd "$WORKTREE_DIR" && echo work > work.txt && git add work.txt && git commit -qm work)
    cleanup_worktree
    [ -d "$WORKTREE_DIR" ]
    git -C "$WORKTREE_DIR" push -q -u origin "$BRANCH_NAME"
    cleanup_worktree
    [ ! -d "$WORKTREE_DIR" ]
}

@test "worktree: setup moves an interrupted worktree aside instead of deleting it, then starts clean" {
    _setup_worktree_repos
    setup_worktree
    (cd "$WORKTREE_DIR" && echo work > work.txt && git add work.txt && git commit -qm "unpublished work")
    echo wip > "$WORKTREE_DIR/uncommitted.txt"

    run setup_worktree
    assert_success
    assert_output --partial "Kept unsaved work"
    # The new worktree is fresh from origin/main
    [ -d "$WORKTREE_DIR" ]
    [ ! -f "$WORKTREE_DIR/work.txt" ]
    # The old one survives, with its commit, its uncommitted file and a branch
    local kept
    kept=$(find "${WORKTREE_BASE}/.recovered" -mindepth 1 -maxdepth 1 -type d)
    [ "$(cat "$kept/work.txt")" = work ]
    [ "$(cat "$kept/uncommitted.txt")" = wip ]
    git -C "$REPO_DIR" for-each-ref --format='%(refname:short)' refs/heads | grep -q '^recovered/agent/issue-99-'
}

@test "worktree: setup keeps unpublished commits of a branch that has no worktree left" {
    _setup_worktree_repos
    git -C "$REPO_DIR" branch "$BRANCH_NAME" origin/main
    git -C "$REPO_DIR" checkout -q "$BRANCH_NAME"
    (cd "$REPO_DIR" && echo lone > lone.txt && git add lone.txt && git commit -qm lone)
    local sha
    sha=$(git -C "$REPO_DIR" rev-parse HEAD)
    git -C "$REPO_DIR" checkout -q --detach origin/main
    run setup_worktree
    assert_success
    git -C "$REPO_DIR" branch --contains "$sha" | grep -q 'recovered/agent/issue-99-'
}

@test "worktree: recovered worktrees older than AGENT_WORKTREE_RECOVERED_DAYS are pruned; 0 keeps them" {
    _setup_worktree_repos
    local root="${WORKTREE_BASE}/.recovered"
    mkdir -p "$root/old-one" "$root/new-one"
    touch -d '40 days ago' "$root/old-one"
    AGENT_WORKTREE_RECOVERED_DAYS=0 _prune_recovered_worktrees "$root"
    [ -d "$root/old-one" ]
    AGENT_WORKTREE_RECOVERED_DAYS=30 _prune_recovered_worktrees "$root"
    [ ! -d "$root/old-one" ]
    [ -d "$root/new-one" ]
}

@test "worktree: a failing setup command fails the setup" {
    _setup_worktree_repos
    export AGENT_TEST_SETUP_COMMAND="false"
    run setup_worktree
    assert_failure
    assert_output --partial "worktree setup command failed"
    export AGENT_TEST_SETUP_COMMAND="false || true"
    run setup_worktree
    assert_success
}

@test "dispatch: no handler force-removes a worktree directly" {
    ! grep -n 'worktree remove' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
}
