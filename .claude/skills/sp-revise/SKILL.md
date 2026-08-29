---
name: sp-revise
description: Orchestrator mode — after a human leaves PR review feedback, dispatch the revision phase to address it, then return to the review hold.
user-invocable: true
argument-hint: "<pr-number>"
---

# sp-revise: Dispatch the Revision Phase for a PR

Run after a human has left review feedback on an agent PR. The pipeline fixes, re-tests, pushes, and replies on the PR.

> Never implement the review feedback yourself in this session — the pipeline owns that. Your job is dispatch, notify, report.

## Run

- Script: `.sandbox-pal-dispatch/scripts/sandbox-pal-dispatch.sh` if it exists, else `scripts/sandbox-pal-dispatch.sh`.
- Repo: `gh repo view --json nameWithOwner -q .nameWithOwner`.

```bash
AGENT_EXECUTION_MODE=orchestrator <script> pr_review <owner/repo> <pr-number>
```

## Parse the final stdout line (compact JSON)

- `agent:pr-open` — revision pushed; report how many commits and remind the operator to re-review the PR.
- Anything else / no new commits — the pipeline posts a comment on the PR explaining what it found; quote it and let the operator decide.

If the command appears to die, follow the verification rule in `/sp-work` — a killed notification is unverified until `/sp-status` and the branch agree.
