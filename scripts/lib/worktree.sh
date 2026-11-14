#!/bin/bash
# ─── Git worktree management ────────────────────────────────────
# Provides: ensure_repo, setup_worktree, run_worktree_setup, cleanup_worktree,
#           worktree_has_unsaved_work, retire_worktree

# Ensure the base repo is cloned and up to date.
ensure_repo() {
    if [ ! -d "$REPO_DIR/.git" ]; then
        log "Cloning $REPO..."
        git clone "https://github.com/${REPO}.git" "$REPO_DIR"
    fi
    git -C "$REPO_DIR" fetch origin --prune 2>/dev/null || true
}

# True when removing this worktree would lose work: changed or untracked files
# outside .agent-data (ignored files do not count), or commits that no remote
# branch contains. An interrupted worker leaves exactly this behind.
worktree_has_unsaved_work() {
    local dir="${1:-$WORKTREE_DIR}"
    [ -d "$dir" ] || return 1
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
    if [ -n "$(git -C "$dir" status --porcelain -- . ':!.agent-data' 2>/dev/null)" ]; then
        return 0
    fi
    [ -z "$(git -C "$dir" branch -r --contains HEAD 2>/dev/null)" ]
}

# Get a worktree out of the way without losing work. A worktree with nothing
# unsaved is removed. One with unsaved work is moved to
# <worktree base>/.recovered/<name>-<time> and its branch renamed to
# recovered/<branch>-<time>, so the dispatch can start clean and a person can
# still pick the work up. Fails, removing nothing, if the move fails.
retire_worktree() {
    local dir="${1:-$WORKTREE_DIR}"
    [ -d "$dir" ] || return 0
    if ! worktree_has_unsaved_work "$dir"; then
        git -C "$REPO_DIR" worktree remove "$dir" --force 2>/dev/null || true
        return 0
    fi
    local root stamp dest branch
    root="$(dirname "$dir")/.recovered"
    stamp="$(date +%s)-$$"
    dest="${root}/$(basename "$dir")-${stamp}"
    branch=$(git -C "$dir" symbolic-ref --short -q HEAD || true)
    mkdir -p "$root"
    if ! git -C "$REPO_DIR" worktree move "$dir" "$dest" 2>/dev/null; then
        log "ERROR: $dir holds uncommitted or unpublished work and could not be moved aside. Nothing was removed; save the work and remove the worktree by hand."
        return 1
    fi
    if [ -n "$branch" ]; then
        git -C "$REPO_DIR" branch -m "$branch" "recovered/${branch}-${stamp}" 2>/dev/null || true
    fi
    log "Kept unsaved work: moved $dir to $dest${branch:+ (branch recovered/${branch}-${stamp})}"
    _prune_recovered_worktrees "$root"
    return 0
}

# Recovered worktrees older than AGENT_WORKTREE_RECOVERED_DAYS (default 30) are
# removed with their branch, so an unattended machine does not fill its disk.
# 0 keeps them for ever.
_prune_recovered_worktrees() {
    local root="$1" days="${AGENT_WORKTREE_RECOVERED_DAYS:-30}" old branch
    [[ "$days" =~ ^[0-9]+$ ]] || days=30
    [ "$days" -gt 0 ] && [ -d "$root" ] || return 0
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        branch=$(git -C "$old" symbolic-ref --short -q HEAD 2>/dev/null || true)
        git -C "$REPO_DIR" worktree remove "$old" --force 2>/dev/null || rm -rf "$old"
        case "$branch" in recovered/*) git -C "$REPO_DIR" branch -D "$branch" 2>/dev/null || true ;; esac
        log "Removed recovered worktree older than ${days} days: $old"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -mtime "+${days}" 2>/dev/null)
    return 0
}

# Create a fresh worktree for the current issue/PR.
# If the branch exists on remote, checks it out; otherwise creates from origin/main.
setup_worktree() {
    # Fetch first: whether existing work is published is judged against the remote.
    git -C "$REPO_DIR" fetch origin --prune 2>/dev/null || true

    # Clear our target path. Never discards an interrupted worker's unsaved work.
    retire_worktree "$WORKTREE_DIR" || return 1

    # Prune stale worktree references (e.g., from crashed previous runs)
    git -C "$REPO_DIR" worktree prune 2>/dev/null || true

    # Delete the local branch if it exists, unless it holds commits no remote has.
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
        if [ -z "$(git -C "$REPO_DIR" branch -r --contains "refs/heads/$BRANCH_NAME" 2>/dev/null)" ]; then
            local kept
            kept="recovered/${BRANCH_NAME}-$(date +%s)-$$"
            git -C "$REPO_DIR" branch -m "$BRANCH_NAME" "$kept" 2>/dev/null || true
            log "Kept unpublished commits of $BRANCH_NAME as branch $kept"
        else
            git -C "$REPO_DIR" branch -D "$BRANCH_NAME" 2>/dev/null || true
        fi
    fi

    # Check if branch exists on remote
    if git -C "$REPO_DIR" ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
        git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -B "$BRANCH_NAME" "origin/$BRANCH_NAME"
    else
        git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" origin/main
    fi

    # Dispatch-scoped scratch artefacts must not outlive a dispatch: a
    # reused worktree would otherwise report the previous run's denials,
    # post its plan verbatim, or apply its staged rules edits (#99).
    rm -f "${WORKTREE_DIR}/.agent-data/permission-denials.log" \
          "${WORKTREE_DIR}/.agent-data/plan.md"
    rm -rf "${WORKTREE_DIR}/.agent-data/rules" \
           "${WORKTREE_DIR}/.agent-data/context"

    run_worktree_setup
}

# Run project-specific setup in the worktree (e.g., Godot import, npm install).
# Called after worktree creation to ensure the environment is ready for tests.
run_worktree_setup() {
    if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
        log "Running worktree setup: $AGENT_TEST_SETUP_COMMAND"
        if ! (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1; then
            # A phase in a worktree whose setup failed runs on a broken or
            # unprotected checkout. Append `|| true` to the command to opt out.
            log "ERROR: worktree setup command failed; the dispatch stops here."
            return 1
        fi
    fi
}

# Remove the worktree for the current issue/PR.
# Remove the worktree for the current issue/PR, unless that would lose work:
# one with uncommitted changes or commits no remote branch contains is left
# in place. The next dispatch for the issue resumes it or moves it aside.
cleanup_worktree() {
    [ -d "$WORKTREE_DIR" ] || return 0
    if worktree_has_unsaved_work "$WORKTREE_DIR"; then
        log "Keeping worktree with uncommitted or unpublished work: $WORKTREE_DIR"
        return 0
    fi
    git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
}
