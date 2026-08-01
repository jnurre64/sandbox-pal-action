---
name: sp-review
description: Interactively run one sandbox-pal ADVERSARIAL REVIEW pass (plus optional fix pass) on an agent PR before merge. Fallback/recovery path for the headless review loop — same prompts, same ledger. Use when headless dispatch is unavailable or a review cycle needs a manual re-run.
argument-hint: "<pr-number> [owner/repo]"
user-invocable: true
---

# sp-review — interactive adversarial review pass

Runs ONE review pass of the sandbox-pal review loop in THIS session using the same `prompts/post-impl-review.md` the headless loop uses. Review requires independence: run this in a FRESH session that did NOT implement the changes, or dispatch the review into a subagent.

## Steps

### 1. Resolve the sandbox-pal install
Same resolution as sp-implement: `$SANDBOX_PAL_HOME/prompts/`, `~/agent-infra/prompts/`, `~/repos/sandbox-pal-action/prompts/`.

### 2. Gather phase context
- `gh pr view <PR> --repo <REPO> --json title,body,headRefName,number`
- Check out the PR branch; fetch first.
- Locate the linked issue (branch name `agent/issue-N` or `feature/N-…`, or `Closes #N` in the PR body) and fetch its title/body/comments and the `<!-- agent-plan -->` comment.
- Read the ledger at `.agent-data/review-ledger.json` on the branch (`{"cycles":0,"findings":[]}` if absent).

### 3. Execute the review pass
Read `prompts/post-impl-review.md` and follow it, mapping: `$AGENT_ISSUE_TITLE`/`$AGENT_ISSUE_BODY`/`$AGENT_COMMENTS` = issue fields; `$AGENT_PLAN_CONTENT` = plan comment; `$AGENT_REVIEW_LEDGER` = ledger contents. Produce the JSON verdict the prompt specifies.

### 4. Update the ledger and act on the verdict
- Merge your verdict into the ledger exactly as the loop does: bump `cycles`; mark `verified_fixed` ids fixed; append new findings as `F<next>` with status `open`; re-open `reopened` ids — `reopened` covers BOTH a demonstrably-wrong rejection AND a claimed-fixed finding the review found not genuinely fixed (per `prompts/post-impl-review.md`); a not-genuinely-fixed finding must never be re-reported as a new finding instead. Commit only the ledger file: `git add -f .agent-data/review-ledger.json && git commit -m "chore(agent): review ledger — interactive review pass"` and push.
- **No open blocking findings** → report "review clean" with the ledger summary; the PR is ready for the human gate.
- **Open blocking findings** → tell the user to run `/sp-revise <PR>` in a fresh session (that skill runs the fix pass against the ledger), or fix here only if the user explicitly waives fresh-context discipline.
