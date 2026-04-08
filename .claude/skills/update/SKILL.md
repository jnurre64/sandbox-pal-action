---
name: update
description: Update a standalone agent-dispatch installation from the upstream repository. Shows what changed, handles merges intelligently.
user-invocable: true
argument-hint: "[path-to-.agent-dispatch]"
---

# Update: Sync Standalone Installation with Upstream

Update a standalone agent-dispatch installation by comparing against the latest upstream version and helping the user selectively apply changes.

**This skill is for standalone mode only.** Reference mode users get updates automatically via `@v1` tags and `git pull`.

## Prerequisites

The standalone installation must have a `.agent-dispatch/.upstream` file (created by the setup process). This file tracks which upstream version was last synced and checksums of each file at that time.

## Step 1: Locate the Installation

If the user provided a path argument, use that. Otherwise, look for `.agent-dispatch/` in the current working directory or ask the user where it is.

Read `.agent-dispatch/.upstream` to get:
- `repo` — the upstream repo URL
- `version` — the commit SHA or tag last synced from
- `checksums` — SHA256 of each file at last sync time

If `.upstream` doesn't exist, tell the user this installation predates the update mechanism and offer to create the tracking file based on the current state (treating all current files as the baseline).

## Step 2: Fetch Latest Upstream

Clone or fetch the upstream repo to a temporary location:

```bash
UPSTREAM_DIR=$(mktemp -d)
git clone --depth=1 https://github.com/jnurre64/claude-agent-dispatch.git "$UPSTREAM_DIR"
```

Read the latest commit SHA:
```bash
LATEST_SHA=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)
```

Compare against the stored version. If they match, tell the user they're already up to date.

## Step 3: Categorize Files

For each file in the upstream installation (scripts, lib, prompts, labels.txt):

1. **Compute current checksum** of the user's local file
2. **Compare against stored checksum** from `.upstream` to detect local modifications
3. **Compare against upstream file** to detect upstream changes

Classify each file into one of these categories:

| Category | Local modified? | Upstream changed? | Action |
|----------|:-:|:-:|--------|
| **Up to date** | No | No | Skip |
| **Auto-update** | No | Yes | Safe to overwrite — user hasn't modified |
| **Needs review** | Yes | Yes | Both sides changed — show diff, user decides |
| **Local only** | Yes | No | User modified, upstream hasn't — skip |
| **New upstream** | (doesn't exist) | Yes | New file from upstream — offer to add |

## Step 4: Present Summary

Show the user a table of all files and their categories. Example:

```
Update Summary (v1.0.0 → v1.2.0):

  Auto-update (safe to overwrite):
    scripts/agent-dispatch.sh
    scripts/lib/common.sh

  Needs review (both sides changed):
    prompts/implement.md

  New from upstream:
    scripts/lib/new-module.sh

  Up to date:
    scripts/lib/worktree.sh
    prompts/triage.md

  Local only (your changes, upstream unchanged):
    prompts/review.md
    config.env
```

## Step 5: Apply Updates

### Auto-update files
Ask the user: "Apply all auto-updates? These files haven't been modified locally." If yes, copy each file from the upstream temp directory to the installation.

### Needs-review files
For each file that both sides modified:
1. Show the upstream diff (what changed in the upstream version since last sync)
2. Show the user's local diff (what they changed from the original)
3. **Use your judgment as Claude** to analyze both changes:
   - If they're in different parts of the file: suggest applying both (no conflict)
   - If they touch the same area: explain the conflict and ask the user what to do
   - Options: accept upstream, keep local, or merge (you write the merged version)
4. Apply the user's choice

### New files
For each new upstream file, show its contents and ask if the user wants to add it.

## Step 6: Detect New Workflow Templates

After applying updates to `.agent-dispatch/`, check whether upstream has added any new workflow templates that the user's repo doesn't have yet.

### Scan for new templates

1. List all `.yml` files in the upstream clone's `.claude/skills/setup/templates/standalone/` directory.
2. For each template file (e.g., `agent-direct-implement.yml`), check if `.github/workflows/<same-filename>` exists in the user's repo.
3. Collect any templates that don't have a matching installed workflow — these are new.

### If no new templates found

Report: "No new workflow templates detected." and proceed to the next step.

### If new templates found

For each new template:

1. **Describe it:** Read the template's `name:` field and `on:` trigger to give the user a one-line summary. Example:
   ```
   New workflow template available:
     agent-direct-implement.yml — "Claude Agent: Direct Implement" (triggers on issues labeled)
   ```

2. **Confirm bot username:** Read `AGENT_BOT_USER` from `.agent-dispatch/config.defaults.env`. Ask the user to confirm: "I'll substitute `<bot-username>` for the bot user in the workflow — does that look right?"

3. **Show the generated workflow:** Read the template, replace all `{{BOT_USER}}` occurrences with the confirmed bot username, and show the result to the user.

4. **Ask to install:** "Install this workflow to `.github/workflows/agent-direct-implement.yml`?"
   - If yes: write the file (create `.github/workflows/` if it doesn't exist).
   - If no: skip it.

5. Repeat for each new template.

### Bot username confirmation

Only ask for bot username confirmation once (on the first new template). Reuse the confirmed value for all subsequent templates in the same update run.

## Step 7: Update Tracking

After applying changes, update `.agent-dispatch/.upstream`:
- Set `version` to the latest upstream commit SHA
- Recompute checksums for all files (both updated and unchanged)

Write the updated `.upstream` file.

## Step 8: Summary

Tell the user:
- How many files were updated, skipped, and merged
- How many new workflow templates were installed (if any)
- If any manual review items remain
- Remind them to commit the changes: `git add .agent-dispatch/ .github/workflows/ && git commit -m "Update agent-dispatch from upstream"`

## File Format: .agent-dispatch/.upstream

```yaml
# Upstream tracking for standalone agent-dispatch installation
# Do not edit manually — managed by /update skill and setup.sh
repo: https://github.com/jnurre64/claude-agent-dispatch.git
version: abc123def456  # commit SHA of last sync
synced_at: "2026-03-21T01:00:00Z"
checksums:
  scripts/agent-dispatch.sh: "sha256:abc..."
  scripts/lib/common.sh: "sha256:def..."
  scripts/lib/worktree.sh: "sha256:ghi..."
  scripts/lib/data-fetch.sh: "sha256:jkl..."
  scripts/lib/defaults.sh: "sha256:mno..."
  scripts/cleanup.sh: "sha256:pqr..."
  scripts/check-prereqs.sh: "sha256:stu..."
  scripts/create-labels.sh: "sha256:vwx..."
  prompts/triage.md: "sha256:..."
  prompts/implement.md: "sha256:..."
  prompts/reply.md: "sha256:..."
  prompts/review.md: "sha256:..."
  labels.txt: "sha256:..."
```
