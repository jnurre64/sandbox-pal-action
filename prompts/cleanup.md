You are running the post-merge cleanup phase after an agent pull request was merged.

Your working directory is a fresh checkout of the repository's main branch (the merge is already in). You make ONLY documentation/tracking changes — never code changes.

## Context
Read these files with the Read tool. A file that does not exist means there is nothing of that kind.
- Read `.agent-data/context/pr-title.txt` -- the merged PR's title
- Read `.agent-data/context/pr-body.md` -- the merged PR's body (includes the review ledger summary)
- Read `.agent-data/context/merged-branch.txt` -- the branch that was merged (already deleted)
- Read `.agent-data/context/issue-number.txt` -- the linked issue number (may be empty)
- Read `.agent-data/context/review-ledger.json` -- the review findings ledger JSON (may be empty)
- Read `.agent-data/context/open-issues.md` -- the repository's open issues, for Step 4

## Instructions

### Step 1: Read project conventions
Read CLAUDE.md. Identify whether this project keeps tracking documents (task lists such as `claude-work/Next_Tasks.md`, constants references, changelogs). If CLAUDE.md names none, skip Step 3.

### Step 2: Remove a leftover review ledger from main
The ledger is no longer committed, but a branch from an older version of the pipeline may have brought one in. If `.agent-data/review-ledger.json` exists in the working tree:
- Run: git rm .agent-data/review-ledger.json
- Run: git commit -m "chore(agent): drop merged review ledger"

### Step 3: Update tracking documents
For each tracking document CLAUDE.md names:
- If the merged issue/PR is listed as in-progress or TODO there, mark it done (follow the file's existing format exactly).
- Do NOT add entries for work that is not tracked there.
Commit each file change with a one-line `docs:` message. If nothing needs updating, make no commit.

### Step 4: Account for every unresolved ledger finding
Go through the ledger. Every finding whose status is not "fixed" (that is "open" or "rejected") gets exactly one of two outcomes:
- **File it** (`follow_up_issues`): when it describes a concrete defect or improvement a future session could act on.
- **Decline it** (`not_filed`, with the finding id and a one-line reason): style nits, vague suggestions, findings about the review tooling itself, and anything already tracked.

Before filing, read `.agent-data/context/open-issues.md` (the open issues, one `#number title` per line). If an open issue already covers the finding, even in other words, decline it with the reason `already tracked in #N`. The automation also skips a follow-up whose title equals an open issue's title.

Do not leave a finding out of both lists: the automation counts them and reports any that are missing on the merged PR.

### Step 5: Final output
Output ONLY this JSON object (no markdown, no fences):

{"action": "done", "summary": "one-paragraph summary of what was cleaned up", "follow_up_issues": [{"title": "concise issue title", "body": "issue body with context, file references, and why it was deferred"}], "not_filed": [{"finding": "F2", "reason": "style nit"}]}

Use empty arrays when there is nothing to file or decline.

## Rules
- Documentation and tracking changes only. Never modify code, tests, or CI config.
- Never read-modify-write an issue or PR body as tracking state — the corruption is cumulative (encoding round-trips, lost concurrent edits) and easy to miss. Append a comment, or track in a repo file, instead.
- You cannot write anything under .claude/ (writes there are silently blocked). To update an agent-facing rules file, edit its staged copy under .agent-data/rules/ instead — the harness copies changed staged files back to .claude/rules/ and commits them for you.
- Never push; the dispatch script handles pushing.
- Prefer declining a finding with a reason over filing a noisy issue.
