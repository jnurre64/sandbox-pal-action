# Update Skill: Handle New Workflow Templates

> **Status:** Implemented — new Step 6 in `/update` skill detects and offers to install new workflow templates.

## Summary

The `/update` skill should detect new standalone workflow templates from upstream and offer to install them, rather than requiring manual creation after each update.

## Problem

When a new feature adds a new GitHub Actions workflow and a corresponding standalone template (e.g., `sandbox-pal-direct-implement.yml`), the update skill successfully syncs all scripts, prompts, and labels — but the user has to manually create the calling workflow in `.github/workflows/`.

**What happened during the `agent:implement` rollout to Webber:**

1. Ran `/update` on Webber's standalone installation
2. Update correctly synced 11 files, added 2 new files (`prompts/validate.md`, `prompts/CLAUDE.md`)
3. Update did **not** detect that a new standalone template (`standalone/sandbox-pal-direct-implement.yml`) existed in upstream
4. Had to manually create `.github/workflows/sandbox-pal-direct-implement.yml` by copying the pattern from the existing `sandbox-pal-implement.yml` and adjusting the label trigger, event type, and job name

This is error-prone — the user has to know which templates are new, understand the bot username substitution, and match project-specific env vars (e.g., Discord webhook secrets) that differ between repos.

## Current Architecture

- Standalone workflow templates live in `.claude/skills/setup/templates/standalone/` in the upstream repo
- During **initial setup** (`/setup` or `setup.sh`), these templates are processed (bot username substituted) and placed in the consuming repo's `.github/workflows/`
- During **updates** (`/update`), only files under `.sandbox-pal-dispatch/` (scripts, prompts, labels.txt) are tracked and synced — workflow files in `.github/workflows/` are not part of the update scope
- The `.upstream` tracking file only has checksums for `.sandbox-pal-dispatch/` contents

## Proposed Enhancement

During the update flow, after categorizing `.sandbox-pal-dispatch/` files:

1. **Scan upstream templates**: List all files in `.claude/skills/setup/templates/standalone/`
2. **Compare against installed workflows**: Check which templates have corresponding workflow files in the consuming repo's `.github/workflows/`
3. **Detect new templates**: Any template that doesn't have a matching workflow is "new"
4. **Offer to install**: For each new template, show its contents and ask the user if they want to add it
5. **Apply bot username substitution**: Replace `{{BOT_USER}}` with the configured `AGENT_BOT_USER` from `config.env`
6. **Handle project-specific env vars**: This is the tricky part — new workflows may need secrets/env vars that existing workflows already pass (like `AGENT_NOTIFY_DISCORD_WEBHOOK`). The skill should:
   - Read an existing workflow to detect project-specific env vars
   - Apply those same env vars to the new workflow template
   - Ask the user to verify before writing

### Matching Logic

Template names follow a predictable pattern:
- Template: `standalone/sandbox-pal-<name>.yml`
- Installed: `.github/workflows/sandbox-pal-<name>.yml`

So the match is straightforward — strip the `standalone/` prefix and check if the file exists.

## Scope

- Only affects standalone mode (reference mode gets new workflows via version tags)
- Does not retroactively install workflows — only detects new ones during an update run
- Should also detect **removed** templates (upstream deleted a workflow) and inform the user

## Alternatives Considered

- **Track workflows in `.upstream`**: Would allow full checksum-based update logic for workflows, but breaks the current clean separation where `.sandbox-pal-dispatch/` is the only managed directory
- **Require re-running `/setup`**: Works but heavy-handed — setup asks many questions that are already answered
- **Documentation only**: Just document "check for new templates after update" — unreliable, easy to forget

## Evidence

Encountered during the first real-world use of the update skill to deploy the `agent:implement` feature to Frightful-Games/Webber on 2026-04-05.
