# Troubleshooting

This document covers common problems, their causes, and how to resolve them.

## Automated Diagnostics with `/troubleshoot`

The `/troubleshoot` Claude Code skill automates most of the diagnostic steps described in this document. If you have an active Claude session, use it before working through the manual steps below.

**Diagnose a specific issue:**

```
/troubleshoot 42
```

Reconstructs a timeline from dispatch logs, issue labels, comments, and workflow runs. Matches the observed state against known failure patterns (timeout, circuit breaker, permission denied, worktree conflict, and more) and produces a structured report with a suggested fix.

**Run a system health check:**

```
/troubleshoot
```

Checks 6 areas — runner environment, config validation, disk/worktree health, bot services, recent failures, and file permissions — and reports pass/warn/fail for each.

The skill detects whether it is running on the self-hosted runner (full local log access) or a remote machine (degrades gracefully to `gh`-based diagnostics only). The manual steps below remain useful when you don't have a Claude session open or need to investigate beyond what the skill covers.

---

## Agent Does Not Respond to Label

> Automatically detected by `/troubleshoot <number>` — pattern: **Runner offline** (no workflow run found for the label event).

**Symptom**: You add the `agent` label to an issue, but nothing happens. No comment, no label change.

### Check 1: Runner Status

The agent runs on a self-hosted runner. If the runner is offline, jobs will queue indefinitely.

```bash
# Check runner status via GitHub CLI
gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | "\(.name): \(.status)"'
```

In the GitHub UI: Settings > Actions > Runners. Verify at least one runner with the expected labels is "Idle" or "Active".

### Check 2: Actor Filter

Your calling workflow must filter out the bot account to prevent self-triggering:

```yaml
if: github.event.label.name == 'agent' && github.actor != 'my-bot'
```

If the bot account is the one adding the label, the workflow will not fire. The `agent` label must be added by a human account.

### Check 3: Workflow Trigger Configuration

Verify your calling workflow triggers on the correct event:

```yaml
on:
  issues:
    types: [labeled]
```

For plan approval:
```yaml
on:
  issues:
    types: [labeled]
# with a job-level filter:
    if: github.event.label.name == 'agent:plan-approved'
```

For reply handling:
```yaml
on:
  issue_comment:
    types: [created]
```

For PR review:
```yaml
on:
  pull_request_review:
    types: [submitted]
```

### Check 4: Workflow File Location

GitHub Actions workflows must be in `.github/workflows/` on the default branch (usually `main`). If you added the workflow on a feature branch, it will not trigger until merged.

### Check 5: Label Name Match

Labels are case-sensitive. Ensure the label you added matches exactly what the workflow checks for. The default trigger label is `agent` (lowercase, no prefix).

---

## Agent Posts "Halted" Comment

> Automatically detected by `/troubleshoot <number>` — pattern: **Circuit breaker**.

**Symptom**: The agent comments "Agent halted: too many comments in the last hour" and the issue is labeled `agent:failed`.

### Cause

The circuit breaker triggered. The bot account posted `AGENT_CIRCUIT_BREAKER_LIMIT` or more comments on this issue within the last hour.

### Common Triggers

- A reply loop: the agent asks a question, the reply handler fires, the agent asks another question, and so on
- Multiple rapid retries by a human (removing and re-adding the `agent` label repeatedly)
- A bug in a custom prompt that causes the agent to always ask questions instead of proceeding

### Resolution

1. Wait for the 1-hour window to pass
2. Check the dispatch log to understand what caused the loop:
   ```bash
   grep "#<issue-number>" ~/.claude/agent-logs/sandbox-pal-dispatch.log | tail -30
   ```
3. Fix the underlying cause (clarify the issue, fix the prompt, etc.)
4. Remove all `agent:*` labels, then re-add `agent`

---

## Agent Fails to Create PR

> Automatically detected by `/troubleshoot <number>` — pattern: **PR creation failure**.

**Symptom**: The dispatch log shows "Failed to create PR" and the issue is labeled `agent:failed`, but the branch exists with commits.

### Check 1: Branch Protection Rules

If your repository has branch protection rules that require specific checks or reviews, the PR creation might fail. The `gh pr create` command may return an error if the base branch has restrictions.

Verify that the bot's PAT has permission to create PRs against the protected branch.

### Check 2: PAT Permissions

The bot's fine-grained PAT needs these permissions:
- **Repository**: Read and Write (for pushing branches)
- **Issues**: Read and Write (for commenting and labeling)
- **Pull Requests**: Read and Write (for creating PRs)
- **Contents**: Read and Write (for pushing commits)

Check your PAT scopes:
```bash
gh auth status
```

### Check 3: Branch Already Exists

If a PR already exists for the branch `agent/issue-<N>`, creating a second PR will fail. Check for existing PRs:

```bash
gh pr list --repo OWNER/REPO --head "agent/issue-<N>"
```

If a stale PR exists, close it before retrying.

### Recovery

The branch with the agent's commits still exists. You can manually create the PR:

```bash
gh pr create --repo OWNER/REPO --head "agent/issue-42" \
  --title "Agent: Fix the widget" \
  --body "Manual PR for agent work on #42"
```

---

## Agent Makes Wrong Changes

> Not automatically detected — this is a correctness issue rather than a dispatch failure. Review the agent's plan and prompts manually.

**Symptom**: The agent creates a PR, but the changes are incorrect, miss the point, or violate project conventions.

### Check 1: CLAUDE.md Conventions

The agent reads `CLAUDE.md` at the start of every phase. If your project conventions are missing or incomplete, the agent will make assumptions. Review your `CLAUDE.md` and add:
- Architecture descriptions
- Coding standards
- File naming patterns
- Things the agent should never do

### Check 2: Prompts

If the default prompts do not match your workflow, consider customizing them. For example, if you do not want TDD, override the implement prompt to remove the TDD steps.

See [customization.md](customization.md) for details.

### Check 3: Test Command

If `AGENT_TEST_COMMAND` is not set, the agent has no way to verify its changes. Adding a test command catches many categories of incorrect changes before a PR is created.

### Check 4: Plan Review

The two-phase workflow (plan then implement) exists specifically to catch wrong directions early. Review the agent's plan carefully before adding the `agent:plan-approved` label. If the plan is wrong, comment with feedback instead of approving.

### Recovery

Request changes on the PR. The agent will automatically address review feedback when a review with "changes requested" is submitted. Be specific in your review comments about what is wrong and what the correct approach should be.

---

## Worktree Conflicts

> Automatically detected by `/troubleshoot <number>` — pattern: **Worktree conflict**.

**Symptom**: The dispatch log shows errors related to worktrees, such as "fatal: is already checked out" or the agent fails during `setup_worktree`.

### Cause

Stale worktrees from previous runs (e.g., the process was killed mid-run) can interfere with new runs.

### Resolution

Clean up stale worktrees manually:

```bash
# List worktrees
git -C ~/repos/default/my-repo worktree list

# Prune references to worktrees that no longer exist on disk
git -C ~/repos/default/my-repo worktree prune

# Force-remove a specific worktree
git -C ~/repos/default/my-repo worktree remove ~/.claude/worktrees/default/my-repo-issue-42 --force
```

To remove all agent worktrees at once:

```bash
rm -rf ~/.claude/worktrees/
# Then prune references in each repo
git -C ~/repos/default/my-repo worktree prune
```

After cleanup, retry the issue by removing all `agent:*` labels and re-adding `agent`.

---

## Claude Times Out

> Automatically detected by `/troubleshoot <number>` — pattern: **Timeout**.

**Symptom**: The dispatch log shows "Claude exited with code 124" (the timeout signal) or "Claude timed out or errored".

### Cause

The `claude -p` process did not finish within `AGENT_TIMEOUT` seconds (default: 3600 = 1 hour).

### Resolution

**Option 1: Increase the timeout**

```bash
# In config.env
AGENT_TIMEOUT=7200  # 2 hours
```

Also ensure the GitHub Actions job timeout is higher than the Claude timeout:
```yaml
timeout_minutes: 125  # Must exceed AGENT_TIMEOUT / 60
```

**Option 2: Reduce scope**

Break the issue into smaller, more focused tasks. Large issues with many files to change are more likely to time out.

**Option 3: Increase max turns**

If Claude is running out of conversation turns rather than wall-clock time:
```bash
AGENT_MAX_TURNS=400
```

---

## Tests Fail in Pre-PR Gate

> Automatically detected by `/troubleshoot <number>` — pattern: **Test gate failure**.

**Symptom**: The issue gets an `agent:failed` label and a comment with "Test Failure (Pre-PR Gate)" showing test output.

### Check 1: Test Command Validity

Verify the `AGENT_TEST_COMMAND` works when run manually in the repository:

```bash
cd /path/to/repo
eval "$AGENT_TEST_COMMAND"
```

### Check 2: Headless Mode Compatibility

The agent runs in a CI-like environment without a display server. If your tests require a GUI (e.g., browser tests, game engine tests), they must support headless mode.

Common headless flags:
- `--headless` for browser-based tools
- `xvfb-run` as a wrapper for X11-dependent tools
- `--no-window` or `--batch` for game engines

### Check 3: Test Environment

The tests run in the worktree directory, which may not have all dependencies installed. Ensure:
- `node_modules/` exists (or `npm install` is part of the test command)
- Virtual environments are activated (or the test command handles activation)
- Required system dependencies are installed on the runner

### Recovery

The agent's commits are still in the worktree (but not pushed). You can:

1. Fix the test issue and retry the whole process
2. Manually check out the branch, fix the tests, and create the PR yourself:
   ```bash
   cd ~/.claude/worktrees/default/my-repo-issue-42
   # inspect and fix
   git push -u origin agent/issue-42
   gh pr create --head agent/issue-42 ...
   ```

---

## "Permission Denied" Errors

> Automatically detected by `/troubleshoot <number>` — pattern: **Permission denied**.

**Symptom**: The dispatch log or stderr shows permission errors when running `gh` commands, pushing branches, or creating PRs.

### Check 1: PAT Scopes

The `AGENT_PAT` secret must be a fine-grained PAT with these minimum scopes:
- **Contents**: Read and Write
- **Issues**: Read and Write
- **Pull Requests**: Read and Write

For organization repositories, the PAT must also be authorized for the organization.

### Check 2: PAT in Environment

The reusable workflows pass the PAT as both `GH_TOKEN` and `GITHUB_TOKEN`. Verify these are set in your calling workflow:

```yaml
env:
  GH_TOKEN: ${{ secrets.AGENT_PAT }}
  GITHUB_TOKEN: ${{ secrets.AGENT_PAT }}
```

### Check 3: Runner File Permissions

The dispatch script creates directories and files in `~/.claude/` and `~/repos/`. Verify the runner user has write access:

```bash
ls -la ~/.claude/agent-logs/
ls -la ~/.claude/worktrees/
ls -la ~/repos/
```

### Check 4: Git Credentials

The dispatch script pushes branches using the bot account. Ensure `git` can authenticate:

```bash
git ls-remote https://github.com/OWNER/REPO.git
```

If this fails, check `~/.git-credentials` or the git credential helper configuration.

---

## Workflow Never Triggers

> Automatically detected by `/troubleshoot <number>` — pattern: **Runner offline** (no workflow run found for the label event).

**Symptom**: You add a label but the Actions tab shows no workflow run at all (not even a failed one).

### Check 1: Label Names Must Match Exactly

Labels are case-sensitive. The calling workflow checks for exact matches:
- `agent` (not `Agent` or `AGENT`)
- `agent:plan-approved` (not `agent: plan-approved` with a space)

Create the labels in your repository's Settings > Labels if they do not exist.

### Check 2: Workflow File on Default Branch

GitHub Actions only runs workflow files that exist on the repository's default branch. If you added the workflow file on a feature branch, merge it to `main` first.

### Check 3: Workflow Syntax

A syntax error in the workflow file silently prevents it from running. Validate your workflow:

```bash
# Install actionlint (optional but helpful)
actionlint .github/workflows/sandbox-pal-dispatch.yml
```

Or check the Actions tab in GitHub for any workflow configuration errors.

### Check 4: GitHub Actions Enabled

Verify that Actions is enabled for your repository: Settings > Actions > General > "Allow all actions and reusable workflows" (or your preferred policy).

For organization repositories, the organization must also allow Actions.

---

## Getting Debug Information

When reporting issues or investigating problems, gather these pieces of information:

### 1. Dispatch Log (Last 50 Lines for the Issue)

```bash
grep "#<issue-number>" ~/.claude/agent-logs/sandbox-pal-dispatch.log | tail -50
```

### 2. Claude Stderr Log

```bash
# Find the most recent stderr log for the issue
ls -lt ~/.claude/agent-logs/claude-stderr-*<issue-number>* | head -3

# Read it
cat "$(ls -t ~/.claude/agent-logs/claude-stderr-*<issue-number>* | head -1)"
```

### 3. Workflow Run Logs

In the GitHub UI: Actions tab > find the run > click the job > expand the step. Or via CLI:

```bash
# List recent workflow runs
gh run list --repo OWNER/REPO --limit 10

# View a specific run's logs
gh run view <run-id> --repo OWNER/REPO --log
```

### 4. Label State

Check what labels are currently on the issue:

```bash
gh issue view <number> --repo OWNER/REPO --json labels --jq '.labels[].name'
```

### 5. Worktree State

Check if a worktree still exists for the issue:

```bash
ls -la ~/.claude/worktrees/default/my-repo-issue-<number>/ 2>/dev/null
git -C ~/repos/default/my-repo worktree list
```

### 6. Branch State

Check if the agent's branch exists and what commits are on it:

```bash
git -C ~/repos/default/my-repo log --oneline origin/agent/issue-<number> 2>/dev/null | head -10
```
