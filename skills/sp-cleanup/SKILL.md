---
name: sp-cleanup
description: Interactively run the sandbox-pal POST-MERGE CLEANUP phase for a merged agent PR — tracking-doc updates, review-ledger follow-up issues, branch deletion. Fallback/recovery path for the headless post_merge dispatch.
argument-hint: "<pr-number> [owner/repo]"
user-invocable: true
---

# sp-cleanup — interactive post-merge cleanup

Runs the cleanup phase in THIS session using the same `prompts/cleanup.md` the headless dispatch uses.

## Steps

### 1. Resolve the sandbox-pal install
Same resolution as sp-implement: `$SANDBOX_PAL_HOME/prompts/`, `~/agent-infra/prompts/`, `~/repos/sandbox-pal-action/prompts/`.

### 2. Preconditions
- `gh pr view <PR> --repo <REPO> --json title,body,headRefName,mergedAt,author,closingIssuesReferences`
- The PR must be MERGED. Confirm with the user before proceeding if the PR author is not the repo's agent bot (cleanup normally covers agent PRs only).

### 3. Execute
- Delete the merged remote branch (best-effort): `git push origin --delete <branch>`
- On an up-to-date main checkout, follow `prompts/cleanup.md`, mapping `$AGENT_PR_TITLE`/`$AGENT_PR_BODY`/`$AGENT_MERGED_BRANCH`/`$AGENT_ISSUE_NUMBER` to the PR fields and `$AGENT_REVIEW_LEDGER` to `.agent-data/review-ledger.json` from main (if present).
- Create the follow-up issues from your structured output via `gh issue create` (confirm the list with the user first — this is the interactive path's advantage).
- Push the doc commits to main (or open a chore PR if main is protected).
- Strip any remaining `agent:*` labels from the linked issue.

### 4. Report
Summarize: docs updated, issues filed, branch deleted.
