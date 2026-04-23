#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# CLEANUP — Scheduled cleanup for agent bot artifacts
# Cleans up stale branches, orphaned gists, old workflow runs,
# and rotates its own logs.
# ═══════════════════════════════════════════════════════════════

# ─── Arguments ──────────────────────────────────────────────────
REPO="${1:?Usage: poopsmith.sh <owner/repo> [--dry-run] [--no-dry-run] [--verbose]}"
shift

DRY_RUN=true  # Safe by default
VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --no-dry-run)  DRY_RUN=false ;;
        --verbose)     VERBOSE=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ─── Token Configuration ────────────────────────────────────────
# AGENT_PAT (fine-grained): branches, workflow runs, issues, PRs
# AGENT_GIST_PAT (classic, gist scope): gist list/delete operations
# GH_TOKEN is set to AGENT_PAT by the workflow. We swap to AGENT_GIST_PAT
# only for gist operations, then swap back.
REPO_TOKEN="${GH_TOKEN:-}"  # Save the repo-scoped token

use_gist_token() {
    if [ -n "${AGENT_GIST_PAT:-}" ]; then
        export GH_TOKEN="$AGENT_GIST_PAT"
    else
        log "WARN" "AGENT_GIST_PAT not set — gist operations will use default token (may fail with fine-grained PAT)"
    fi
}

use_repo_token() {
    if [ -n "$REPO_TOKEN" ]; then
        export GH_TOKEN="$REPO_TOKEN"
    fi
}

# ─── Configuration ──────────────────────────────────────────────
LOG_DIR="$HOME/.claude/agent-logs"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/poopsmith-${TIMESTAMP}.log"
AUDIT_LOG="$LOG_DIR/poopsmith-audit.jsonl"

# Age thresholds (days)
MERGED_BRANCH_AGE=7
CLOSED_BRANCH_AGE=30
GIST_ORPHAN_AGE=14
WORKFLOW_RUN_AGE=30
LOG_RETENTION=90
STDERR_LOG_RETENTION=30
MIN_RUNS_PER_WORKFLOW=5

# Protected branch patterns
PROTECTED_BRANCHES="main master develop staging"

# Counter files (to survive subshells from piped while-loops)
COUNTER_DIR=$(mktemp -d)
trap 'rm -rf "$COUNTER_DIR"' EXIT
echo 0 > "$COUNTER_DIR/branches_deleted"
echo 0 > "$COUNTER_DIR/branches_skipped"
echo 0 > "$COUNTER_DIR/gists_deleted"
echo 0 > "$COUNTER_DIR/runs_deleted"
echo 0 > "$COUNTER_DIR/logs_cleaned"

mkdir -p "$LOG_DIR"

# ─── Core Functions ─────────────────────────────────────────────

increment() {
    local file="$COUNTER_DIR/$1"
    local val
    val=$(cat "$file")
    echo $((val + 1)) > "$file"
}

counter() {
    cat "$COUNTER_DIR/$1"
}

log() {
    local level="$1"; shift
    local msg
    msg="[$(date -u '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

verbose() {
    if [ "$VERBOSE" = true ]; then
        log "DEBUG" "$@"
    fi
}

audit() {
    local json="$1"
    local dry_val="true"
    [ "$DRY_RUN" = false ] && dry_val="false"
    json=$(echo "$json" | jq -c --argjson dry "$dry_val" '. + {dry_run: $dry}')
    echo "$json" >> "$AUDIT_LOG"
    verbose "AUDIT: $json"
}

days_since() {
    local iso_date="$1"
    local then_epoch now_epoch
    then_epoch=$(date -d "$iso_date" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    echo $(( (now_epoch - then_epoch) / 86400 ))
}

is_protected_branch() {
    local branch="$1"
    local default_branch="$2"

    [ "$branch" = "$default_branch" ] && return 0

    for protected in $PROTECTED_BRANCHES; do
        [ "$branch" = "$protected" ] && return 0
    done

    [[ "$branch" == release/* ]] && return 0

    return 1
}

delete_branch() {
    local branch="$1"
    local reason="$2"
    local pr_number="$3"
    local date_field="$4"

    if [ "$DRY_RUN" = true ]; then
        log "INFO" "[DRY RUN] Would delete branch: $branch (PR #$pr_number, $reason)"
    else
        if gh api --method DELETE "repos/${REPO}/git/refs/heads/${branch}" 2>/dev/null; then
            log "INFO" "Deleted branch: $branch (PR #$pr_number, $reason)"
        else
            log "WARN" "Failed to delete branch: $branch (may already be deleted)"
            return 0
        fi
    fi

    audit "$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg target "$branch" \
        --arg reason "$reason" \
        --argjson pr "$pr_number" \
        --arg date "$date_field" \
        '{ts: $ts, action: "delete_branch", target: $target, reason: $reason, pr: $pr, date: $date}')"

    increment branches_deleted
}

# ─── Task 1: Stale Branch Cleanup ──────────────────────────────

cleanup_merged_branches() {
    log "INFO" "Checking merged PR branches..."

    local default_branch
    default_branch=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "main")
    verbose "Default branch: $default_branch"

    local merged_prs
    merged_prs=$(gh pr list --repo "$REPO" --state merged --json number,headRefName,mergedAt --limit 200 2>/dev/null || echo "[]")

    local count
    count=$(echo "$merged_prs" | jq 'length')
    verbose "Found $count merged PRs to check"

    echo "$merged_prs" | jq -c '.[]' | while IFS= read -r pr; do
        local branch pr_number merged_at age
        branch=$(echo "$pr" | jq -r '.headRefName')
        pr_number=$(echo "$pr" | jq -r '.number')
        merged_at=$(echo "$pr" | jq -r '.mergedAt')
        age=$(days_since "$merged_at")

        if is_protected_branch "$branch" "$default_branch"; then
            verbose "Skipping protected branch: $branch"
            increment branches_skipped
            continue
        fi

        if [ "$age" -ge "$MERGED_BRANCH_AGE" ]; then
            delete_branch "$branch" "merged_pr" "$pr_number" "$merged_at"
        else
            verbose "Skipping branch $branch — merged $age days ago (threshold: $MERGED_BRANCH_AGE)"
        fi
    done
}

cleanup_closed_branches() {
    log "INFO" "Checking closed (not merged) PR branches..."

    local default_branch
    default_branch=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo "main")

    local closed_prs
    closed_prs=$(gh pr list --repo "$REPO" --state closed --json number,headRefName,mergedAt,closedAt --limit 200 2>/dev/null || echo "[]")

    # Filter to only those that were NOT merged
    closed_prs=$(echo "$closed_prs" | jq '[.[] | select(.mergedAt == null)]')

    local count
    count=$(echo "$closed_prs" | jq 'length')
    verbose "Found $count closed-not-merged PRs to check"

    echo "$closed_prs" | jq -c '.[]' | while IFS= read -r pr; do
        local branch pr_number closed_at age
        branch=$(echo "$pr" | jq -r '.headRefName')
        pr_number=$(echo "$pr" | jq -r '.number')
        closed_at=$(echo "$pr" | jq -r '.closedAt')
        age=$(days_since "$closed_at")

        if is_protected_branch "$branch" "$default_branch"; then
            verbose "Skipping protected branch: $branch"
            increment branches_skipped
            continue
        fi

        # Check if branch has any open PRs
        local open_prs_for_branch
        open_prs_for_branch=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo "0")
        if [ "$open_prs_for_branch" -gt 0 ]; then
            log "WARN" "Skipping branch: $branch — has open PR(s)"
            increment branches_skipped
            continue
        fi

        if [ "$age" -ge "$CLOSED_BRANCH_AGE" ]; then
            delete_branch "$branch" "closed_pr_not_merged" "$pr_number" "$closed_at"
        else
            verbose "Skipping branch $branch — closed $age days ago (threshold: $CLOSED_BRANCH_AGE)"
        fi
    done
}

# ─── Task 2: Gist Cleanup ──────────────────────────────────────

cleanup_tracked_gists() {
    log "INFO" "Checking tracked gists..."

    # Look for gist tracker in various repo clone locations
    local tracker_paths=(
        "$HOME/repos/$(basename "$REPO")/.git/gist-tracker.json"
        "$HOME/repos/STRONGBAD/$(basename "$REPO")/.git/gist-tracker.json"
        "$HOME/repos/STRONGMAD/$(basename "$REPO")/.git/gist-tracker.json"
        "$HOME/repos/STRONGSAD/$(basename "$REPO")/.git/gist-tracker.json"
    )

    local tracker_file=""
    for path in "${tracker_paths[@]}"; do
        if [ -f "$path" ]; then
            tracker_file="$path"
            break
        fi
    done

    if [ -z "$tracker_file" ]; then
        verbose "No gist-tracker.json found — skipping tracked gist cleanup"
        return 0
    fi

    log "INFO" "Found gist tracker: $tracker_file"

    local entries
    entries=$(jq -c '.[]' "$tracker_file" 2>/dev/null || echo "")

    if [ -z "$entries" ]; then
        verbose "Gist tracker is empty"
        return 0
    fi

    # Process tracked gists — build list of IDs to remove, then update tracker once
    local ids_to_remove=()

    while IFS= read -r entry; do
        local gist_id number entry_type state
        gist_id=$(echo "$entry" | jq -r '.gist_id')
        number=$(echo "$entry" | jq -r '.number')
        entry_type=$(echo "$entry" | jq -r '.type // "issue"')

        state=$(gh issue view "$number" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

        if [ "$state" = "CLOSED" ] || [ "$state" = "MERGED" ]; then
            if [ "$DRY_RUN" = true ]; then
                log "INFO" "[DRY RUN] Would delete tracked gist: $gist_id (${entry_type} #${number} is ${state})"
            else
                use_gist_token
                if gh gist delete "$gist_id" 2>/dev/null; then
                    log "INFO" "Deleted tracked gist: $gist_id (${entry_type} #${number} is ${state})"
                    ids_to_remove+=("$gist_id")
                else
                    log "WARN" "Failed to delete gist $gist_id — check AGENT_GIST_PAT"
                fi
                use_repo_token
            fi

            audit "$(jq -nc \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg target "$gist_id" \
                --arg reason "linked_${entry_type}_closed" \
                --argjson number "$number" \
                '{ts: $ts, action: "delete_gist", target: $target, reason: $reason, issue: $number}')"

            increment gists_deleted
        else
            verbose "Keeping gist $gist_id — ${entry_type} #${number} is $state"
        fi
    done <<< "$entries"

    # Update tracker file to remove deleted entries
    if [ "${#ids_to_remove[@]}" -gt 0 ] && [ "$DRY_RUN" = false ]; then
        local updated
        updated=$(cat "$tracker_file")
        for id in "${ids_to_remove[@]}"; do
            updated=$(echo "$updated" | jq --arg id "$id" 'del(.[] | select(.gist_id == $id))')
        done
        echo "$updated" > "$tracker_file"
    fi
}

cleanup_orphan_gists() {
    log "INFO" "Checking for orphan gists..."

    local gists
    use_gist_token
    gists=$(gh gist list --limit 200 --json id,description,createdAt,updatedAt 2>/dev/null || echo "[]")
    use_repo_token

    local count
    count=$(echo "$gists" | jq 'length')
    verbose "Found $count gists to check"

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    echo "$gists" | jq -c '.[]' | while IFS= read -r gist; do
        local gist_id created_at age description
        gist_id=$(echo "$gist" | jq -r '.id')
        created_at=$(echo "$gist" | jq -r '.createdAt')
        description=$(echo "$gist" | jq -r '.description // ""')
        age=$(days_since "$created_at")

        if [ "$age" -lt "$GIST_ORPHAN_AGE" ]; then
            verbose "Keeping gist $gist_id — only $age days old (threshold: $GIST_ORPHAN_AGE)"
            continue
        fi

        # Search for references in open issues/PRs
        local references
        references=$(gh search issues --repo "$REPO" --state open "$gist_id" --json number --jq 'length' 2>/dev/null || echo "0")

        if [ "$references" -gt 0 ]; then
            verbose "Keeping gist $gist_id — referenced by $references open issue(s)/PR(s)"
            continue
        fi

        if [ "$DRY_RUN" = true ]; then
            log "INFO" "[DRY RUN] Would delete orphan gist: $gist_id (age: ${age}d, desc: ${description:0:60})"
        else
            use_gist_token
            if gh gist delete "$gist_id" 2>/dev/null; then
                log "INFO" "Deleted orphan gist: $gist_id (age: ${age}d)"
            else
                log "WARN" "Failed to delete orphan gist $gist_id — check AGENT_GIST_PAT"
            fi
            use_repo_token
        fi

        audit "$(jq -nc \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg target "$gist_id" \
            --arg desc "${description:0:100}" \
            --argjson age "$age" \
            '{ts: $ts, action: "delete_gist", target: $target, reason: "orphan_no_references", age_days: $age, description: $desc}')"

        increment gists_deleted
    done
}

# ─── Task 3: Old Workflow Run Cleanup ──────────────────────────

cleanup_old_workflow_runs() {
    log "INFO" "Checking old workflow runs..."

    # Get all workflow IDs
    local workflows
    workflows=$(gh api "repos/${REPO}/actions/workflows" --jq '.workflows[].id' 2>/dev/null || echo "")

    if [ -z "$workflows" ]; then
        verbose "No workflows found"
        return 0
    fi

    for workflow_id in $workflows; do
        # Get completed runs sorted newest-first, as a JSON array
        local run_array
        run_array=$(gh api "repos/${REPO}/actions/workflows/${workflow_id}/runs?per_page=200&status=completed" \
            --jq '[.workflow_runs | sort_by(.created_at) | reverse | .[] | {id: .id, created_at: .created_at}]' 2>/dev/null || echo "[]")

        local total
        total=$(echo "$run_array" | jq 'length')
        verbose "Workflow $workflow_id: $total completed runs"

        # Skip the first MIN_RUNS_PER_WORKFLOW (keep them), process the rest
        echo "$run_array" | jq -c ".[$MIN_RUNS_PER_WORKFLOW:][]" 2>/dev/null | while IFS= read -r run; do
            local run_id created_at age
            run_id=$(echo "$run" | jq -r '.id')
            created_at=$(echo "$run" | jq -r '.created_at')
            age=$(days_since "$created_at")

            if [ "$age" -lt "$WORKFLOW_RUN_AGE" ]; then
                continue
            fi

            if [ "$DRY_RUN" = true ]; then
                log "INFO" "[DRY RUN] Would delete workflow run: $run_id (age: ${age}d)"
            else
                if gh run delete "$run_id" --repo "$REPO" 2>/dev/null; then
                    log "INFO" "Deleted workflow run: $run_id (age: ${age}d)"
                else
                    log "WARN" "Failed to delete workflow run: $run_id"
                fi
            fi

            audit "$(jq -nc \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --arg target "$run_id" \
                --arg created "$created_at" \
                '{ts: $ts, action: "delete_run", target: $target, reason: "older_than_30d", created: $created}')"

            increment runs_deleted
        done
    done
}

# ─── Task 4: Log Self-Maintenance ──────────────────────────────

cleanup_old_logs() {
    log "INFO" "Cleaning old log files..."

    # POOPSMITH logs older than 90 days
    while IFS= read -r file; do
        if [ "$DRY_RUN" = true ]; then
            log "INFO" "[DRY RUN] Would delete old log: $(basename "$file")"
        else
            rm -f "$file"
            log "INFO" "Deleted old log: $(basename "$file")"
        fi
        increment logs_cleaned
    done < <(find "$LOG_DIR" -name "poopsmith-*.log" -type f -mtime +"$LOG_RETENTION" 2>/dev/null)

    # Claude stderr logs older than 30 days
    while IFS= read -r file; do
        if [ "$DRY_RUN" = true ]; then
            log "INFO" "[DRY RUN] Would delete old stderr log: $(basename "$file")"
        else
            rm -f "$file"
            log "INFO" "Deleted old stderr log: $(basename "$file")"
        fi
        increment logs_cleaned
    done < <(find "$LOG_DIR" -name "claude-stderr-*.log" -type f -mtime +"$STDERR_LOG_RETENTION" 2>/dev/null)

    # Rotate sandbox-pal-dispatch.log if > 10MB
    local dispatch_log="$LOG_DIR/sandbox-pal-dispatch.log"
    if [ -f "$dispatch_log" ]; then
        local size_bytes
        size_bytes=$(stat -c%s "$dispatch_log" 2>/dev/null || echo 0)
        local size_mb=$((size_bytes / 1048576))

        if [ "$size_mb" -ge 10 ]; then
            if [ "$DRY_RUN" = true ]; then
                log "INFO" "[DRY RUN] Would rotate sandbox-pal-dispatch.log (${size_mb}MB)"
            else
                cp "$dispatch_log" "${dispatch_log}.1"
                truncate -s 0 "$dispatch_log"
                log "INFO" "Rotated sandbox-pal-dispatch.log (${size_mb}MB -> ${dispatch_log}.1)"
            fi
            increment logs_cleaned
        fi
    fi

    # Note: poopsmith-audit.jsonl is NEVER auto-deleted (retained indefinitely)
}

# ─── Summary ────────────────────────────────────────────────────

print_summary() {
    local mode="LIVE"
    [ "$DRY_RUN" = true ] && mode="DRY RUN"

    local summary
    summary=$(cat <<EOF
## POOPSMITH Cleanup Report — $(date -u +%Y-%m-%d) [$mode]

### Branches
- Deleted: $(counter branches_deleted)
- Skipped: $(counter branches_skipped) (protected or have open PRs)

### Gists
- Deleted: $(counter gists_deleted)

### Workflow Runs
- Deleted: $(counter runs_deleted)

### Log Maintenance
- Cleaned: $(counter logs_cleaned) log file(s)
EOF
)

    echo ""
    echo "$summary"
    echo "$summary" >> "$LOG_FILE"

    # Write to GitHub Actions step summary if available
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$summary" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# ─── Main ───────────────────────────────────────────────────────

main() {
    log "INFO" "POOPSMITH starting — repo: $REPO (dry_run=$DRY_RUN, verbose=$VERBOSE)"

    cleanup_merged_branches
    cleanup_closed_branches
    cleanup_tracked_gists
    cleanup_orphan_gists
    cleanup_old_workflow_runs
    cleanup_old_logs

    print_summary

    log "INFO" "POOPSMITH complete."
}

main
