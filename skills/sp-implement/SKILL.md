---
name: sp-implement
description: Interactively run the sandbox-pal IMPLEMENT phase for an issue with an approved plan. Fallback/recovery path for the headless dispatch — same prompt, same label transitions, human-triggered. Use when headless dispatch is unavailable or a failed implement run needs a manual re-run.
argument-hint: "<issue-number> [owner/repo]"
user-invocable: true
---

# sp-implement — interactive implement phase

Runs the implement phase of the sandbox-pal pipeline in THIS session, using the same prompt file the headless dispatch uses. For clean-context discipline, run this in a FRESH session (or dispatch it into a subagent).

## Steps

### 1. Resolve the sandbox-pal install
Prompt files live next to the dispatch scripts. Check in order:
- `$SANDBOX_PAL_HOME/prompts/` if the env var is set
- `~/agent-infra/prompts/` (runner-style install)
- A local checkout: `~/repos/sandbox-pal-action/prompts/`
Stop and ask the user if none exists.

### 2. Gather phase context
With `<issue-number>` (and repo from the argument, else the current directory's `origin`):
- `gh issue view <N> --repo <REPO> --json title,body,comments,labels`
- The issue must carry `agent:plan-approved` (or the user explicitly overrides).
- Extract the plan: the LAST comment containing `<!-- agent-plan -->`.
- Extract the branch marker `<!-- agent-branch: ... -->` from that comment. If present, check out that branch (fetch + pull). If absent, create/checkout `agent/issue-<N>` off latest main.
- Set the label: `gh issue edit <N> --repo <REPO> --remove-label agent:plan-approved --add-label agent:in-progress`

### 3. Execute the phase
Read `prompts/implement.md` from the install. Follow it as your instructions, with this mapping for its environment references: `$AGENT_ISSUE_TITLE`/`$AGENT_ISSUE_BODY`/`$AGENT_COMMENTS` = the issue fields you fetched; `$AGENT_PLAN_CONTENT` = the extracted plan; `$AGENT_ISSUE_NUMBER` = <N>; attached-data variables = any gists/attachments you download from the issue comments. Follow the project's TDD rules; commit per red-green cycle.

### 4. Finish
- Run the project's test command (see the repo's CI or `AGENT_TEST_COMMAND` in the runner config). All green before proceeding.
- Push the branch; open a PR titled after the issue with `Closes #<N>`, or report why not.
- Label: `gh issue edit <N> --repo <REPO> --remove-label agent:in-progress --add-label agent:pr-open`
- The adversarial review phase is separate — run `/sp-review <PR>` next (in a fresh session).
