# Operations Guide

This document covers day-to-day operations: monitoring, retrying failed issues, understanding label transitions, circuit breaker recovery, worktree management, and updates.

## Monitoring

### Log Files

All logs are written to the directory specified by `AGENT_LOG_DIR` (default: `~/.claude/agent-logs/`).

| File | Content |
|------|---------|
| `agent-dispatch.log` | Main dispatch log. Appended by every run. Contains timestamped entries with event type, issue number, and status messages. |
| `claude-stderr-<repo>-<issue>-<timestamp>.log` | Stderr output from each `claude -p` invocation. Empty on success. Contains error details on failure. |

### Watching Logs in Real Time

To follow the dispatch log as the agent works:

```bash
tail -f ~/.claude/agent-logs/agent-dispatch.log
```

To check the most recent stderr log for a failed run:

```bash
ls -lt ~/.claude/agent-logs/claude-stderr-* | head -5
cat "$(ls -t ~/.claude/agent-logs/claude-stderr-* | head -1)"
```

### Reading Log Entries

Each log line follows the format:

```
[2025-01-15 14:32:01] [new_issue] #42: Triaging issue (plan-only mode)...
[2025-01-15 14:33:15] [new_issue] #42: Plan posted. Awaiting human approval.
[2025-01-15 15:10:22] [implement] #42: Starting implementation of approved plan...
[2025-01-15 15:12:45] [implement] #42: Pushing 3 commit(s)...
[2025-01-15 15:12:50] [implement] #42: PR created: https://github.com/org/repo/pull/43
```

The bracketed fields are `[timestamp]`, `[event_type]`, and `#issue_number`.

---

## Label Flow

Labels track the agent's progress on each issue. Only one `agent:*` label is active at a time. The dispatch script removes all agent labels before setting a new one.

### Label State Machine

```
Human adds "agent" label
  |
  v
agent:triage  ............  agent is analyzing the issue
  |
  +--> agent:needs-info ...  agent asked questions, waiting for human reply
  |      |
  |      +--> (human replies) --> re-triages --> agent:plan-review
  |
  +--> agent:plan-review ..  agent posted a plan, waiting for human approval
         |
         +--> (human adds agent:plan-approved)
                |
                v
              agent:in-progress ...  agent is implementing
                |
                v
              agent:pr-open .......  PR created, awaiting code review
                |
                +--> (reviewer requests changes) --> agent:revision --> agent:pr-open
                |
                +--> (reviewer approves) --> human merges, labels removed

At any point on failure:
  agent:failed
```

### Label Definitions

| Label | Meaning | Who sets it |
|-------|---------|-------------|
| `agent` | Request for the agent to work on this issue | Human |
| `agent:triage` | Agent is actively analyzing the issue | Dispatch script |
| `agent:needs-info` | Agent asked clarifying questions | Dispatch script |
| `agent:ready` | Questions answered, ready to proceed | Dispatch script |
| `agent:plan-review` | Agent posted an implementation plan | Dispatch script |
| `agent:plan-approved` | Plan approved, implementation can begin | Human |
| `agent:in-progress` | Agent is actively implementing code | Dispatch script |
| `agent:pr-open` | PR created, awaiting human review | Dispatch script |
| `agent:revision` | Agent is addressing review feedback on the PR | Dispatch script |
| `agent:failed` | Something went wrong; needs human attention | Dispatch script |

### Expected Transitions

**Happy path (no questions):**
`agent` -> `agent:triage` -> `agent:plan-review` -> `agent:plan-approved` -> `agent:in-progress` -> `agent:pr-open` -> merged

**With questions:**
`agent` -> `agent:triage` -> `agent:needs-info` -> (human replies) -> `agent:ready` -> `agent:plan-review` -> `agent:plan-approved` -> `agent:in-progress` -> `agent:pr-open`

**With PR review feedback:**
`agent:pr-open` -> (review with changes requested) -> `agent:revision` -> `agent:pr-open`

---

## Retrying Failed Issues

When an issue gets the `agent:failed` label:

1. **Check the dispatch log** for what went wrong:
   ```bash
   grep "#42" ~/.claude/agent-logs/agent-dispatch.log | tail -20
   ```

2. **Check stderr** for Claude-specific errors:
   ```bash
   ls -lt ~/.claude/agent-logs/claude-stderr-*42* | head -3
   cat "$(ls -t ~/.claude/agent-logs/claude-stderr-*42* | head -1)"
   ```

3. **Fix the underlying issue** (unclear requirements, missing context, etc.)

4. **Remove all agent labels** from the issue:
   - In the GitHub UI, remove every label starting with `agent`
   - Or use the CLI: `gh issue edit 42 --repo org/repo --remove-label agent:failed`

5. **Re-add the `agent` label** from your primary (non-bot) account:
   ```bash
   gh issue edit 42 --repo org/repo --add-label agent
   ```

The `agent` label must be added by a non-bot account to pass the actor filter in your calling workflow. If the bot adds the label, the workflow will not trigger.

---

## Circuit Breaker

### What Triggers It

The circuit breaker counts comments made by the bot account (`AGENT_BOT_USER`) on a specific issue within the last hour. If the count reaches or exceeds `AGENT_CIRCUIT_BREAKER_LIMIT` (default: 8), the agent halts immediately.

This protects against infinite loops — for example, if the agent keeps asking questions that trigger reply handlers that ask more questions.

### What Happens

When the circuit breaker triggers:
1. The issue is labeled `agent:failed`
2. A comment is posted: "Agent halted: too many comments in the last hour."
3. The dispatch script exits

### How to Recover

1. Wait for the hour window to pass (the circuit breaker counts comments in a rolling 1-hour window)
2. Investigate why the agent was looping (check the dispatch log)
3. Follow the retry procedure: remove all agent labels, re-add `agent`

If the underlying cause is not fixed, the agent will trip the breaker again.

---

## Worktree Management

### Where Worktrees Live

The dispatch script uses git worktrees for isolation. Each issue/PR gets its own worktree:

```
~/.claude/worktrees/<runner-name>/
  <repo-name>-issue-<N>/     # Created for triage + implementation
  <repo-name>-pr-<N>/        # Created for PR review feedback
```

The base repository clone lives at:

```
~/repos/<runner-name>/<repo-name>/
```

The `<runner-name>` segment comes from the `RUNNER_NAME` environment variable set by GitHub Actions, which provides per-runner isolation when multiple runners share a machine.

### Automatic Cleanup

- **Triage phase**: Worktree is cleaned up if the agent asks questions or fails. It is intentionally kept alive if a plan is posted, so the implementation phase can reuse it.
- **Implementation phase**: Worktree is cleaned up after the PR is created (or on failure).
- **PR review phase**: Worktree is cleaned up after pushing review fixes.

### Manual Cleanup

If worktrees are left behind (e.g., from a killed process), clean them up manually:

```bash
# List all worktrees for a repo
git -C ~/repos/default/my-repo worktree list

# Remove a specific stale worktree
git -C ~/repos/default/my-repo worktree remove ~/.claude/worktrees/default/my-repo-issue-42 --force

# Prune all stale worktree references
git -C ~/repos/default/my-repo worktree prune
```

To remove all worktrees at once:

```bash
rm -rf ~/.claude/worktrees/
git -C ~/repos/default/my-repo worktree prune
```

---

## Updating the Dispatch Scripts

### Reference Mode

If your project calls the reusable workflows from this repository, you are already in reference mode. The dispatch scripts live in the `claude-agent-dispatch` repository and your project references them via `workflow_call`.

To update, pull the latest changes on the runner machine:

```bash
cd ~/agent-infra
git pull origin main
```

Or, if you cloned the repository to a different path, pull there. The `dispatch_script` workflow input controls which path is used.

### Version Pinning

You can pin to a specific tag or commit in your calling workflow to avoid unexpected changes:

```yaml
uses: your-org/claude-agent-dispatch/.github/workflows/dispatch-triage.yml@v1.0.0
```

Or pin to a commit SHA:

```yaml
uses: your-org/claude-agent-dispatch/.github/workflows/dispatch-triage.yml@abc1234
```

This ensures the dispatch scripts and prompts do not change until you explicitly update the reference.

### Standalone Mode

If you copied the dispatch scripts into your own repository, you manage updates manually. When upstream changes are released, compare the differences and apply them to your copy:

```bash
# In your copy of the scripts
diff -r scripts/ /path/to/claude-agent-dispatch/scripts/
diff -r prompts/ /path/to/claude-agent-dispatch/prompts/
```

---

## Concurrency

Each reusable workflow uses a concurrency group keyed by workflow type and issue or PR number:

```yaml
concurrency:
  group: claude-agent-triage-${{ github.event.issue.number }}
  cancel-in-progress: false
```

Groups are workflow-specific (e.g., `claude-agent-triage-96`, `claude-agent-implement-96`) so that label changes during a run don't cause other workflows to compete in the same group. This means:
- Only one job per workflow type runs per issue/PR at a time
- Additional triggers for the same workflow and issue are **queued**, not cancelled
- Different issues can run in parallel on different runners
- Different workflow types for the same issue don't interfere with each other

If a job seems stuck, check the GitHub Actions UI for queued runs. You can cancel queued runs manually if needed.
