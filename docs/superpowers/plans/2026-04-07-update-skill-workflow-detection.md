# Update Skill: Workflow Template Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a step to the `/update` skill that detects new upstream workflow templates and offers to install them into the user's `.github/workflows/`.

**Architecture:** The update skill is a Claude Code skill defined entirely in `.claude/skills/update/SKILL.md`. The change is a new step inserted between the current Step 5 (Apply Updates) and Step 6 (Update Tracking). No shell scripts, no `.upstream` format changes.

**Tech Stack:** Markdown (SKILL.md instructions), YAML (workflow templates)

---

### Task 1: Add workflow template detection step to update SKILL.md

**Files:**
- Modify: `.claude/skills/update/SKILL.md:106` (insert new step after current Step 5, renumber Steps 6-7 to 7-8)

- [ ] **Step 1: Read the current SKILL.md to confirm structure**

Run:
```bash
grep -n "^## Step" .claude/skills/update/SKILL.md
```

Expected output (confirm step numbering before editing):
```
18:## Step 1: Locate the Installation
29:## Step 2: Fetch Latest Upstream
45:## Step 3: Categorize Files
63:## Step 4: Present Summary
89:## Step 5: Apply Updates
107:## Step 6: Update Tracking
115:## Step 7: Summary
```

- [ ] **Step 2: Insert the new Step 6 after the current Step 5 (Apply Updates)**

After line 106 (end of current Step 5), insert the following new section:

```markdown
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
```

- [ ] **Step 3: Renumber the existing Steps 6 and 7**

Change the current "Step 6: Update Tracking" heading to "Step 7: Update Tracking".

Change the current "Step 7: Summary" heading to "Step 8: Summary".

- [ ] **Step 4: Update the Summary step to mention workflow templates**

In the newly renumbered Step 8 (Summary), add a line after "How many files were updated, skipped, and merged":

```markdown
- How many new workflow templates were installed (if any)
```

Also update the suggested commit command to include workflow files:

```markdown
- Remind them to commit the changes: `git add .agent-dispatch/ .github/workflows/ && git commit -m "Update agent-dispatch from upstream"`
```

- [ ] **Step 5: Verify the complete SKILL.md reads correctly**

Read the full updated SKILL.md and verify:
- Steps are numbered 1-8 sequentially with no gaps
- Step 6 (new) flows logically between Step 5 (Apply Updates) and Step 7 (Update Tracking)
- No references to old step numbers remain in the document
- The `.upstream` file format section at the bottom is unchanged

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/update/SKILL.md
git commit -m "feat: detect new workflow templates during /update (#17)"
```

---

### Task 2: Update the issue documentation

**Files:**
- Modify: `docs/issues/update-skill-workflow-templates.md` (add implementation status)

- [ ] **Step 1: Add a resolution note to the issue doc**

At the top of `docs/issues/update-skill-workflow-templates.md`, add:

```markdown
> **Status:** Implemented — new Step 6 in `/update` skill detects and offers to install new workflow templates.
```

- [ ] **Step 2: Commit**

```bash
git add docs/issues/update-skill-workflow-templates.md
git commit -m "docs: mark workflow template detection as implemented (#17)"
```

---

### Task 3: Manual testing

- [ ] **Step 1: Verify detection logic by inspection**

On a standalone installation (e.g., Frightful-Games/Webber), confirm:
1. The upstream `templates/standalone/` directory contains 7 templates: `agent-triage.yml`, `agent-implement.yml`, `agent-reply.yml`, `agent-review.yml`, `agent-cleanup.yml`, `agent-dispatch.yml`, `agent-direct-implement.yml`
2. The target repo's `.github/workflows/` contains the installed workflows
3. Any missing workflow would be detected by the filename comparison logic described in Step 6

- [ ] **Step 2: Close the GitHub issue**

```bash
gh issue close 17 --comment "Implemented in [commit SHA]. The /update skill now detects new workflow templates and offers to install them."
```
