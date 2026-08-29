#!/usr/bin/env bats
# Tests for scripts/lib/rules-staging.sh (#92)
#
# A headless phase cannot write .claude/** (built-in path guard in
# Claude Code), so the harness stages rules files into .agent-data/rules/
# for the phase to edit, then copies back and commits what changed.

load 'helpers/test_helper'

_source_rules_staging() {
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/rules-staging.sh"
}

# Build a worktree-like git repo with a rules file in it
_setup_rules_repo() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    mkdir -p "${WORKTREE_DIR}/.claude/rules"
    echo "original rule text" > "${WORKTREE_DIR}/.claude/rules/style.md"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "test@test"
    git -C "$WORKTREE_DIR" config user.name "test"
    git -C "$WORKTREE_DIR" add -A
    git -C "$WORKTREE_DIR" commit -qm "initial"
}

@test "stage_rules_files: copies rules files into the staging directory" {
    _source_rules_staging
    _setup_rules_repo

    stage_rules_files

    [ -f "${WORKTREE_DIR}/.agent-data/rules/style.md" ]
    grep -q "original rule text" "${WORKTREE_DIR}/.agent-data/rules/style.md"
}

@test "stage_rules_files: no-op when the repo has no .claude/rules directory" {
    _source_rules_staging
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    mkdir -p "$WORKTREE_DIR"

    stage_rules_files

    [ ! -d "${WORKTREE_DIR}/.agent-data/rules" ]
}

@test "apply_rules_files: copies back a modified staged file and commits it" {
    _source_rules_staging
    _setup_rules_repo
    stage_rules_files
    echo "edited by the phase" > "${WORKTREE_DIR}/.agent-data/rules/style.md"

    apply_rules_files

    grep -q "edited by the phase" "${WORKTREE_DIR}/.claude/rules/style.md"
    git -C "$WORKTREE_DIR" log -1 --format=%s | grep -q "rules"
    [ "$RULES_APPLIED" = "style.md" ]
}

@test "REGRESSION v1.2.0: a staged file with no counterpart in .claude/rules/ is not applied" {
    _source_rules_staging
    _setup_rules_repo
    stage_rules_files
    echo "invented by the phase" > "${WORKTREE_DIR}/.agent-data/rules/invented.md"

    apply_rules_files

    [ ! -f "${WORKTREE_DIR}/.claude/rules/invented.md" ]
}

@test "apply_rules_files: ignores staged names outside the allow-list pattern" {
    _source_rules_staging
    _setup_rules_repo
    echo "spaced original" > "${WORKTREE_DIR}/.claude/rules/bad name.md"
    git -C "$WORKTREE_DIR" add -A && git -C "$WORKTREE_DIR" commit -qm "add spaced"
    stage_rules_files
    echo "edited" > "${WORKTREE_DIR}/.agent-data/rules/bad name.md"

    apply_rules_files

    grep -q "spaced original" "${WORKTREE_DIR}/.claude/rules/bad name.md"
}

@test "apply_rules_files: no commit when nothing differs" {
    _source_rules_staging
    _setup_rules_repo
    stage_rules_files
    local before
    before=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

    apply_rules_files

    [ "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" = "$before" ]
    [ -z "$RULES_APPLIED" ]
}

@test "dispatch: rules staging is sourced and wired around the write phases" {
    grep -q "lib/rules-staging.sh" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "stage_rules_files" "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    grep -q "apply_rules_files" "${SCRIPTS_DIR}/lib/common.sh"
}
