#!/bin/bash
# ─── Git worktree management ────────────────────────────────────
# Provides: ensure_repo, setup_worktree, run_worktree_setup, cleanup_worktree

# Ensure the base repo is cloned and up to date.
ensure_repo() {
    if [ ! -d "$REPO_DIR/.git" ]; then
        log "Cloning $REPO..."
        git clone "https://github.com/${REPO}.git" "$REPO_DIR"
    fi
    git -C "$REPO_DIR" fetch origin --prune 2>/dev/null || true
}

# Create a fresh worktree for the current issue/PR.
# If the branch exists on remote, checks it out; otherwise creates from origin/main.
setup_worktree() {
    # Remove existing worktree at our target path
    if [ -d "$WORKTREE_DIR" ]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    fi

    # Prune stale worktree references (e.g., from crashed previous runs)
    git -C "$REPO_DIR" worktree prune 2>/dev/null || true

    # Delete local branch if it exists
    git -C "$REPO_DIR" branch -D "$BRANCH_NAME" 2>/dev/null || true

    # Fetch latest to ensure we have current main and know if remote branch exists
    git -C "$REPO_DIR" fetch origin --prune 2>/dev/null || true

    # Check if branch exists on remote
    if git -C "$REPO_DIR" ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
        git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -B "$BRANCH_NAME" "origin/$BRANCH_NAME"
    else
        git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" origin/main
    fi

    run_worktree_setup
}

# Run project-specific setup in the worktree (e.g., Godot import, npm install).
# Called after worktree creation to ensure the environment is ready for tests.
run_worktree_setup() {
    if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
        log "Running worktree setup: $AGENT_TEST_SETUP_COMMAND"
        (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Worktree setup command exited with non-zero (continuing)"
    fi
}

# Remove the worktree for the current issue/PR.
cleanup_worktree() {
    git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
}
