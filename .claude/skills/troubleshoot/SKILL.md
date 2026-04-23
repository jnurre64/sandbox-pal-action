---
name: troubleshoot
description: Diagnose agent dispatch failures for a specific issue, or run a system health check across the runner environment.
user-invocable: true
argument-hint: "[issue-number or owner/repo#number]"
---

# Troubleshoot: Diagnose Agent Failures and System Health

Two modes:

- `/troubleshoot <number>` or `/troubleshoot owner/repo#42` — investigate a specific issue
- `/troubleshoot` (no argument) — system health check across 6 areas

## Step 1: Detect Environment

Determine whether you are running on the self-hosted runner or a remote machine:

```bash
ls ~/.claude/agent-logs/ 2>/dev/null
```

- **Runner mode** (directory exists): full diagnostics from local files + `gh` CLI
- **Remote mode** (directory does not exist): `gh`-only diagnostics with limited visibility

Note which mode you are in. If remote mode, skip any step that requires local file access and note "not available in remote mode" in the report.

## Step 2: Determine Repo Context

Infer the repository from the argument or current directory:

- If the argument is `owner/repo#42`, use that owner/repo and issue number
- If the argument is just a number, infer the repo from the current directory's git remote:
  ```bash
  git remote get-url origin 2>/dev/null
  ```
- If no argument is provided, proceed to the System Health Check (Step 6)

## Step 3: Gather Issue Data

Collect data from all available sources. Adapt to the detected environment.

### 3a: GitHub data (both modes)

```bash
# Issue details, labels, and body
gh issue view <NUMBER> --repo OWNER/REPO --json title,body,state,labels,comments,createdAt,updatedAt

# Check for associated PR
gh pr list --repo OWNER/REPO --head "agent/issue-<NUMBER>" --json number,state,title,url

# Recent workflow runs triggered by issue events
gh run list --repo OWNER/REPO --limit 20 --json databaseId,status,conclusion,event,createdAt,name
```

### 3b: Local logs (runner mode only)

```bash
# Dispatch log entries for this issue
grep "#<NUMBER>" ~/.claude/agent-logs/sandbox-pal-dispatch.log | tail -80

# Claude stderr log (most recent for this issue)
ls -t ~/.claude/agent-logs/claude-stderr-*<NUMBER>* 2>/dev/null | head -3
# Read the most recent one if it exists
```

### 3c: Worktree state (runner mode only)

```bash
# Check if a worktree exists for this issue
ls -la ~/.claude/worktrees/*/\*-issue-<NUMBER> 2>/dev/null

# Check the branch
git log --oneline origin/agent/issue-<NUMBER> 2>/dev/null | head -10
```

## Step 4: Match Known Failure Patterns

Compare the gathered data against these known failure patterns. Multiple patterns may match — report all that apply.

| Pattern | Detection Signal | Category |
|---|---|---|
| **Timeout** | Exit code 124, "timed out" in log | Resource limit |
| **Circuit breaker** | "halted: too many comments" in log, `agent:failed` label | Loop detection |
| **PR creation failure** | "Failed to create PR" in log, branch exists but no PR | Permission/state |
| **Worktree conflict** | "already checked out" in stderr | Stale state |
| **Parse failure** | "Could not parse" in log | Prompt/output issue |
| **Permission denied** | "Permission denied" or HTTP 403 in stderr | Auth/PAT |
| **No commits** | "No commits made" in log | Scope/complexity |
| **Test gate failure** | "Test Failure (Pre-PR Gate)" in issue comments or log | Test issue |
| **Runner offline** | No workflow run found for the label event | Infrastructure |

If no known pattern matches, report the raw data and suggest manual investigation.

## Step 5: Produce Issue Diagnostic Report

Assemble findings into this structured format:

```
## Troubleshooting Report: #<NUMBER>

### Summary
One or two sentences: what happened and the likely root cause.

### Timeline
Numbered list of events in chronological order. Include:
- When the agent label was added (from issue events/comments)
- Label transitions (from issue labels and log entries)
- Key dispatch log events (triage, plan, implementation start/end)
- Exit conditions (timeout, error, success)
- PR creation (if applicable)
Include timestamps where available.

### Diagnosis
Which known failure pattern(s) matched and why. Reference specific
log lines or state that led to this conclusion.

If remote mode, note which data sources were unavailable and how
that limits confidence in the diagnosis.

### Suggested Fix
Actionable steps to resolve the issue. Be specific:
- If timeout: suggest scope reduction or AGENT_TIMEOUT increase with the exact config line
- If circuit breaker: explain what caused the loop and how to prevent it
- If permission: specify which PAT scope is likely missing
- If worktree conflict: give the exact cleanup commands
- If test failure: suggest checking AGENT_TEST_COMMAND
- If no pattern matched: suggest gathering more data or checking specific logs
```

**Stop here** — do not proceed to the system health check. The report is complete.

## Step 6: System Health Check (no argument mode)

Run all 6 area checks. Report pass/warn/fail for each area.

### 6a: Runner Environment

Check that required tools are installed and accessible:

```bash
# Claude Code CLI
claude --version 2>/dev/null

# GitHub CLI and auth
gh auth status 2>/dev/null

# Other required tools
git --version
jq --version 2>/dev/null
curl --version 2>/dev/null | head -1
```

- **Pass**: all tools present and `gh` authenticated
- **Warn**: optional tools missing
- **Fail**: `claude`, `gh`, `git`, or `jq` missing or `gh` not authenticated

### 6b: Config Validation

Check that config files exist and required variables are set:

```bash
# Check for config files in common locations
# Standalone mode:
ls .sandbox-pal-dispatch/config.env 2>/dev/null
ls .sandbox-pal-dispatch/config.defaults.env 2>/dev/null
# Infrastructure mode:
ls config.env 2>/dev/null
ls config.defaults.env 2>/dev/null
```

Source the config and check:
- `AGENT_BOT_USER` is set (required)
- `AGENT_TIMEOUT` is a positive integer if set
- `AGENT_MAX_TURNS` is a positive integer if set
- `AGENT_CIRCUIT_BREAKER_LIMIT` is a positive integer if set
- `AGENT_TEST_COMMAND`, if set, is a valid command (check with `which` or `command -v` on the first word)

- **Pass**: required vars set, optional vars well-formed
- **Warn**: optional vars missing or `AGENT_TEST_COMMAND` not set (no pre-PR test gate)
- **Fail**: `AGENT_BOT_USER` not set or config file missing

### 6c: Disk and Worktree Health

```bash
# Disk space
df -h ~ | tail -1

# List worktrees and check for stale ones
find ~/.claude/worktrees/ -maxdepth 2 -mindepth 2 -type d 2>/dev/null

# Count worktrees
ls ~/.claude/worktrees/*/ 2>/dev/null | wc -l
```

- **Pass**: disk >10% free, 0 worktrees or all recently active
- **Warn**: disk <10% free, or >5 worktrees present (possible stale worktrees)
- **Fail**: disk <2% free

### 6d: Bot Services

Check systemd services for notification bots:

```bash
# Discord bot
systemctl --user is-active pennyworth-discord.service 2>/dev/null

# Check if notification backend is configured
# (from config: AGENT_NOTIFY_BACKEND)
```

- **Pass**: configured notification services are running
- **Warn**: notification backend configured but service not running, or no notification backend configured
- **Fail**: service is in failed state

### 6e: Recent Failures

```bash
# Check for agent:failed entries in the last 48 hours
grep "agent:failed\|agent_failed\|\[failed\]" ~/.claude/agent-logs/sandbox-pal-dispatch.log 2>/dev/null | tail -20
```

Review recent dispatch log entries for failure patterns. Count failures in the last 48 hours.

- **Pass**: 0 failures in last 48 hours
- **Warn**: 1-2 failures in last 48 hours
- **Fail**: 3+ failures in last 48 hours (may indicate systemic issue)

If failures exist, briefly note the issue numbers and failure categories (timeout, circuit breaker, etc.) so the user can run `/troubleshoot <number>` on specific ones.

### 6f: File Permissions

```bash
# config.env should not be world-readable (contains no secrets in gitignored file, but good practice)
stat -c '%a' config.env 2>/dev/null || stat -c '%a' .sandbox-pal-dispatch/config.env 2>/dev/null

# Log directory writable
test -w ~/.claude/agent-logs/ && echo "writable" || echo "not writable"

# Worktree directory writable (or creatable)
test -w ~/.claude/worktrees/ 2>/dev/null && echo "writable" || echo "not writable or missing"
```

- **Pass**: config not world-readable (perms not `*4` or `*6` or `*7` in the others column), log and worktree dirs writable
- **Warn**: config is world-readable
- **Fail**: log or worktree directory not writable

### 6g: Produce Health Report

```
## System Health Report

| Area | Status | Details |
|------|--------|---------|
| Runner environment | PASS/WARN/FAIL | ... |
| Config validation | PASS/WARN/FAIL | ... |
| Disk / worktrees | PASS/WARN/FAIL | ... |
| Bot services | PASS/WARN/FAIL | ... |
| Recent failures | PASS/WARN/FAIL | ... |
| File permissions | PASS/WARN/FAIL | ... |

### Recommendations
(Only if any area is WARN or FAIL — list specific actions to take)
```
