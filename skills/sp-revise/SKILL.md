---
name: sp-revise
description: Interactively run the sandbox-pal FIX phase — address open blocking review-ledger findings on an agent PR (the post-impl-retry prompt), or address human PR review feedback (the review prompt). Fallback/recovery path for headless dispatch.
argument-hint: "<pr-number> [owner/repo]"
user-invocable: true
---

# sp-revise — interactive fix phase

Addresses findings on an agent PR in THIS session using the same prompt files the headless dispatch uses. Run in a FRESH session.

## Steps

### 1. Resolve the sandbox-pal install
Same resolution as sp-implement: `$SANDBOX_PAL_HOME/prompts/`, `~/agent-infra/prompts/`, `~/repos/sandbox-pal-action/prompts/`.

### 2. Pick the mode
- If `.agent-data/review-ledger.json` on the PR branch has findings with `severity: "blocking"`, `status: "open"` → **ledger mode** (`prompts/post-impl-retry.md`).
- Else if the PR has human review feedback (changes requested / review comments) → **feedback mode** (`prompts/review.md`); set the linked issue's label to `agent:revision` first.

### 3. Gather context and execute
Check out the PR branch. Fetch the linked issue + plan comment as in sp-review.
- Ledger mode: follow `prompts/post-impl-retry.md` with `$AGENT_REVIEW_LEDGER` = ledger contents and `$AGENT_REVIEW_CONCERNS` = the open blocking findings as `- F<id>: <description>` bullets. Apply the dispositions you produce to the ledger file (set status/justification per finding), commit the ledger, run the project's tests, push.
- Feedback mode: follow `prompts/review.md` with `$AGENT_REVIEWS`/`$AGENT_REVIEW_COMMENTS`/`$AGENT_PR_COMMENTS` = the PR's reviews and comments; run tests; push; then restore the issue label to `agent:pr-open`.

### 4. Finish
- Ledger mode: tell the user to run `/sp-review <PR>` again in a fresh session to verify (the loop's re-review), unless every finding was rejected-with-justification — those go to the human gate.
- Report what changed, test evidence, and the ledger state.
