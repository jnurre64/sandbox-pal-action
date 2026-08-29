---
name: sp-work
description: Orchestrator mode — drive the agent pipeline for a GitHub issue from this interactive session. Picks the right dispatch event from the issue's agent labels, runs it, and narrates the result. Preserves the plan-review gate.
user-invocable: true
argument-hint: "<issue-number>"
---

# sp-work: Dispatch the Pipeline for an Issue

You are the **orchestrator tier**: you run one command, parse one JSON line, and narrate. The pipeline (harness + headless phases) does the work.

> Never implement, fix, or review anything yourself in this session — the pipeline owns that. Work you do here is neither seen by the adversarial review phase nor recorded in a phase envelope. Your job is dispatch, notify, report.

## Step 1: Locate the dispatch script and repo

- Script: `.sandbox-pal-dispatch/scripts/sandbox-pal-dispatch.sh` if it exists (standalone install), else `scripts/sandbox-pal-dispatch.sh`.
- Repo: `gh repo view --json nameWithOwner -q .nameWithOwner`.

## Step 2: Pick the event from the issue's agent labels

`gh issue view <n> --json labels,state -q '[.labels[].name, .state]'` — the issue must be OPEN.

| Label state | Action |
|---|---|
| none / `agent` / `agent:triage` | Run event `new_issue` (triage: posts a plan or questions) |
| `agent:needs-info` | If the human has answered on the issue, run `issue_reply`; otherwise report what's still awaited |
| `agent:plan-review` | **Stop — the plan gate.** Point the operator at the plan comment on the issue. Only if the operator explicitly approves: apply `agent:plan-approved` (`gh issue edit <n> --add-label agent:plan-approved --remove-label agent:plan-review`), then run `implement` |
| `agent:plan-approved` | Run event `implement` |
| `agent:in-progress` | A dispatch may be running — run `/sp-status <n>` first; only re-dispatch if it is stale |
| `agent:pr-open` | Nothing to dispatch — link the PR for human review |
| `agent:failed` | Read the failure comment and the last-dispatch record, explain the cause, and re-run the appropriate event only if the operator says so |

## Step 3: Run the dispatch

```bash
AGENT_EXECUTION_MODE=orchestrator <script> <event> <owner/repo> <issue>
```

This can run a long time (an implement dispatch includes the test gate and the adversarial review loop). While it runs, stderr is the human-readable narration; do not touch the worktree.

## Step 4: Parse the result

The **final line of stdout is a compact JSON object**: `{event, repo, issue, outcome, exit_code, pr_url, started, finished}`. Everything else is host output for humans. Act on `outcome`:

- `agent:plan-review` — plan posted; show the operator where to review it. The gate is theirs, not yours.
- `agent:needs-info` — questions posted; relay them.
- `agent:pr-open` — report `pr_url`, the review-loop summary from the PR body (including any "Review Unresolved" banner and Permission Denials section), and remind the operator the PR awaits their human review.
- `agent:failed` — quote the failure comment from the issue; if it lists permission denials, each one is an allow-list gap to fix in config.
- `lock-refused` — another dispatch owns this issue's lock; run `/sp-status <n>` and report who holds it.
- `error` — infrastructure error; the issue has an "Agent Infrastructure Error" comment with diagnostics.

## If the command appears to die: verify before you report

**A `killed` or `failed` task notification is unverified until you check it.** Background-task monitors have reported dispatches killed that were alive and went on to open PRs.

1. Run `/sp-status <n>` — `stale: false` means it is ALIVE; report the phase it is in and leave it alone.
2. Read the last-dispatch record the status output includes — every run writes its outcome before exiting, failures included.
3. Check the work branch: `git log origin/agent/issue-<n> --oneline | head` — commits are pushed before gates can fail.
4. Only report the dispatch as stopped once all of that agrees. Never describe the working tree as half-finished, and never advise discarding or salvaging work, on the strength of a notification alone.
