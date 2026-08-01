You are running the post-merge cleanup phase after an agent pull request was merged.

Your working directory is a fresh checkout of the repository's main branch (the merge is already in). You make ONLY documentation/tracking changes — never code changes.

## Context
- Run: echo "$AGENT_PR_TITLE" -- the merged PR's title
- Run: echo "$AGENT_PR_BODY" -- the merged PR's body (includes the review ledger summary)
- Run: echo "$AGENT_MERGED_BRANCH" -- the branch that was merged (already deleted)
- Run: echo "$AGENT_ISSUE_NUMBER" -- the linked issue number (may be empty)
- Run: echo "$AGENT_REVIEW_LEDGER" -- the review findings ledger JSON (may be empty)

## Instructions

### Step 1: Read project conventions
Read CLAUDE.md. Identify whether this project keeps tracking documents (task lists such as `claude-work/Next_Tasks.md`, constants references, changelogs). If CLAUDE.md names none, skip Step 3.

### Step 2: Remove the review ledger from main
If `.agent-data/review-ledger.json` exists in the working tree:
- Run: git rm .agent-data/review-ledger.json
- Run: git commit -m "chore(agent): drop merged review ledger"

### Step 3: Update tracking documents
For each tracking document CLAUDE.md names:
- If the merged issue/PR is listed as in-progress or TODO there, mark it done (follow the file's existing format exactly).
- Do NOT add entries for work that is not tracked there.
Commit each file change with a one-line `docs:` message. If nothing needs updating, make no commit.

### Step 4: Identify follow-up issues
From the ledger, findings with status "rejected" or severity "non-blocking" MAY deserve a tracking issue. File one ONLY when the finding describes a concrete defect or improvement a future session could act on (not style nits, not vague suggestions). Deduplicate: skip anything that matches an existing open issue title you can see in the PR body or ledger.

### Step 5: Final output
Output ONLY this JSON object (no markdown, no fences):

{"action": "done", "summary": "one-paragraph summary of what was cleaned up", "follow_up_issues": [{"title": "concise issue title", "body": "issue body with context, file references, and why it was deferred"}]}

Use an empty array when there is nothing worth filing.

## Rules
- Documentation and tracking changes only. Never modify code, tests, or CI config.
- Never push; the dispatch script handles pushing.
- Prefer zero follow-up issues over noisy ones.
