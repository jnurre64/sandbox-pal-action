---
name: sp-status
description: Orchestrator mode — read-only status of the agent pipeline for an issue. Reports whether a dispatch is in flight or dead, its current phase, and the last dispatch outcome. Mutates nothing.
user-invocable: true
argument-hint: "<issue-number>"
---

# sp-status: Is It Still Going?

**Read-only by contract.** This command mutates nothing: it does not clean up a dead lock (the next dispatch reclaims it), and it never overwrites the last-dispatch record of the run it reports on. Never "fix" anything from here.

## Run

- Script: `.sandbox-pal-dispatch/scripts/sandbox-pal-dispatch.sh` if it exists, else `scripts/sandbox-pal-dispatch.sh`.
- Repo: `gh repo view --json nameWithOwner -q .nameWithOwner`.

```bash
AGENT_EXECUTION_MODE=orchestrator <script> status <owner/repo> <issue>
```

## Parse the final stdout line (compact JSON)

`{event: "status", repo, issue, lock, last_dispatch}`

- `lock: null` — no dispatch in flight.
- `lock.stale: false` — **a dispatch is ALIVE.** Report its `phase`, how long since `updated`, and when it `started`. Do not dispatch anything else at this issue.
- `lock.stale: true` — the run died (pid is gone). The next `/sp-work` reclaims the lock. Report the phase it died in.
- `lock.stale: "unknown"` — the lock belongs to another host; you cannot check its pid from here. Say so.
- `last_dispatch` — the previous run's own outcome record: `outcome` (the last agent label it set), `exit_code`, `pr_url`, timings. If a caller lost track of a run, this is the truth.

Then render the issue's current agent label (`gh issue view <issue> --json labels`) so the operator sees pipeline state and process state side by side.
