# Handoff: Interactive Pipeline — sandbox-pal-action

**Branch:** `feature/interactive-pipeline` in `~/repos/sandbox-pal-action` — **local only, not pushed** (pushing happens in plan Task 12, with the jnurre64 token)
**Plan:** `docs/superpowers/plans/2026-08-01-interactive-pipeline.md`
**Spec:** `docs/superpowers/specs/2026-08-01-interactive-pipeline-design.md`
**No GitHub issue** — this work was designed interactively; the spec is the requirements document.

## Start the session by running:

```bash
cd ~/repos/sandbox-pal-action
git checkout feature/interactive-pipeline
git log --oneline -3   # expect: plan commit, spec commit, then main
```

## Then:

1. Read the plan in full: `docs/superpowers/plans/2026-08-01-interactive-pipeline.md`
2. Read the spec: `docs/superpowers/specs/2026-08-01-interactive-pipeline-design.md`
3. Invoke `superpowers:subagent-driven-development` (user's standing preference) OR `superpowers:executing-plans` to execute task-by-task
4. TDD discipline per the plan: every task is red → verify red → green → verify green → commit. Test runner: `./tests/bats/bin/bats tests/<file>.bats` (full: `./tests/bats/bin/bats tests/`)
5. Task 12 pushes the branch and opens the PR on `jnurre64/sandbox-pal-action` — GitHub ops on this repo need `GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token)`

## Context the plan does NOT repeat:

- **Run test suites in synchronous foreground Bash** (never backgrounded) — subagents have stalled waiting on backgrounded runs before. The BATS suite is fast (<1 min), so this is cheap.
- **Task 5 mock-file naming**: the plan's tests read `${TEST_TEMP_DIR}/mock_calls_gh` — verify the actual recording convention in `tests/helpers/test_helper.bash` (`create_mock`) first and adjust the two assertions if the helper writes elsewhere. The plan flags this inline.
- **Task 6 is the riskiest task** (reorders `handle_implement` in the 725-line dispatch script). `tests/test_set_e_guards.bats` greps the dispatch script for `set -e` guard patterns — if it goes red after the reorder, read its assertions and preserve the guards in the moved code rather than weakening the test.
- **Task 10 writes to `~/.claude/skills/work-issue/`** (user-global, not a git repo — no commit step). Source to copy from is `~/repos/Webber/.claude/skills/work-issue/SKILL.md`.
- **Task 11 opens a PR on Webber** (`Frightful-Games` — default gh token works there). Confirm with Jonny in-session before opening that PR; his convention disallows standalone docs-handoff PRs, and while this is a functional change, he may prefer folding it into the next Webber branch.
- **Task 12 deployment notes are for Jonny, not for you to execute** — post them as a PR comment. In particular: consuming-repo workflow files (Webber `.github/workflows/`) are always added by the human, never by an agent.

## Open questions / risks flagged during planning:

- The review-loop cap semantics changed for `AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0` (was: `agent:failed`; now: PR opens as `agent:review-unresolved`). This is intentional (spec: "an honest PR with evidence beats a dead pipeline") — don't "fix" it back.
- The ledger IS committed to the work branch (single file, `git add -f`) and lands in PR diffs by design; the cleanup phase removes it from main after merge. If a consuming repo's `.gitignore` fights this, `-f` wins — that's expected.
- The plan resolves the spec's three open questions as: ledger at `.agent-data/review-ledger.json`; `agent:review-unresolved` is annotation-only (no workflow hooks); branch detection via marker-in-plan-comment. If implementation reveals a problem with any of these, stop and surface it rather than improvising a fourth design.
