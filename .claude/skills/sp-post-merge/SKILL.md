---
name: sp-post-merge
description: Orchestrator mode — after merging an agent PR, dispatch the post-merge cleanup: label transitions, tracking-doc updates, follow-up issues, branch cleanup.
user-invocable: true
argument-hint: "<pr-number>"
---

# sp-post-merge: Dispatch Post-Merge Cleanup

Run after you merge an agent PR. The pipeline transitions the linked issues to `agent:done`, does tracking-doc work, files follow-up issues from the session's structured output, and cleans up.

> Never do the cleanup yourself in this session — the pipeline owns it. Your job is dispatch, notify, report.

## Run

- Script: `.sandbox-pal-dispatch/scripts/sandbox-pal-dispatch.sh` if it exists, else `scripts/sandbox-pal-dispatch.sh`.
- Repo: `gh repo view --json nameWithOwner -q .nameWithOwner`.

```bash
AGENT_EXECUTION_MODE=orchestrator <script> post_merge <owner/repo> <pr-number>
```

## Parse the final stdout line (compact JSON)

- `success` / `agent:done` — report the linked issues marked done, doc commits made, and any follow-up issues filed (they are named in the notify line and on the PR).
- `error` — the PR or issue has the failure detail; quote it.

Then name the next issue worth working, if the operator asks: open issues labeled `agent:plan-approved` first, then `agent:plan-review`, then unlabeled candidates.
