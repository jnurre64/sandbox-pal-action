#!/bin/bash
# ─── Rules staging: work around the .claude/** write guard ────────
# Provides: stage_rules_files, apply_rules_files
#
# A headless phase cannot edit anything under .claude/ — a built-in,
# path-based guard in Claude Code, not an allow-list gap. Edit and
# Bash both fail, silently from the phase's point of view, and only
# bypassPermissions lifts it (dropping every deny rule with it). So the
# phase never touches the real file: the harness copies .claude/rules/
# into .agent-data/rules/ (an ordinary, unguarded path), the phase edits
# those copies, and the harness copies back whatever differs and commits
# it. The phase authors the words; the harness does the writing. (#92)

RULES_SOURCE_DIR=".claude/rules"
RULES_STAGING_DIR=".agent-data/rules"
RULES_APPLIED=""

# Copy every rules file into the staging directory. No-op when the
# repo has no rules directory.
stage_rules_files() {
    RULES_APPLIED=""
    local src="${WORKTREE_DIR}/${RULES_SOURCE_DIR}"
    local dst="${WORKTREE_DIR}/${RULES_STAGING_DIR}"
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    local f staged=0
    for f in "$src"/*.md; do
        [ -f "$f" ] || continue
        cp "$f" "${dst}/$(basename "$f")"
        staged=$((staged + 1))
    done
    [ "$staged" -gt 0 ] && log "Staged ${staged} rules file(s) into ${RULES_STAGING_DIR}/ for the phase to edit"
    return 0
}

# Copy back staged files that differ and commit them. A staged file is
# honoured only if .claude/rules/ already holds a file of that name and
# the name matches ^[A-Za-z0-9._-]+\.md$ — no traversal out of the
# staging directory, no rules file invented by a phase. Applied names
# land in RULES_APPLIED (space-separated) for reporting.
apply_rules_files() {
    RULES_APPLIED=""
    local src="${WORKTREE_DIR}/${RULES_STAGING_DIR}"
    local dst="${WORKTREE_DIR}/${RULES_SOURCE_DIR}"
    [ -d "$src" ] || return 0
    local f name
    local -a applied=()
    for f in "$src"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        if ! [[ "$name" =~ ^[A-Za-z0-9._-]+\.md$ ]]; then
            log "rules: ignoring staged file '${name}' (name outside the allow-list pattern)"
            continue
        fi
        if [ ! -f "${dst}/${name}" ]; then
            log "rules: ignoring staged file '${name}' (no counterpart in ${RULES_SOURCE_DIR}/)"
            continue
        fi
        if ! cmp -s "$f" "${dst}/${name}"; then
            cp "$f" "${dst}/${name}"
            applied+=("$name")
        fi
    done
    [ "${#applied[@]}" -eq 0 ] && return 0
    local paths=("${applied[@]/#/${RULES_SOURCE_DIR}/}")
    if git -C "$WORKTREE_DIR" add -- "${paths[@]}" 2>/dev/null \
        && git -C "$WORKTREE_DIR" commit -m "chore(agent): apply staged rules updates — ${applied[*]}" -- "${paths[@]}" 2>/dev/null; then
        RULES_APPLIED="${applied[*]}"
        log "Applied rules update(s) from staging: ${RULES_APPLIED}"
    else
        log "WARN: rules staging commit failed for: ${applied[*]}"
    fi
    return 0
}
