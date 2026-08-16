# Per-Merge Agent Label Cleanup — Design

**Issue:** [#74](https://github.com/jnurre64/sandbox-pal-action/issues/74)
**Date:** 2026-08-16
**Status:** Approved (brainstormed interactively; decisions recorded below)

## Problem

When an agent PR merges, the linked issue auto-closes but keeps its `agent:*`
state label (observed: `agent:pr-open` lingering in FingerWizard). Anything
that reads the label state machine as ground truth then sees a closed issue
in an "open PR" state.

Investigation findings (2026-08-16):

1. The toolkit **already has** a per-merge path: `sandbox-pal-post-merge.yml`
   → `handle_post_merge` in `scripts/sandbox-pal-dispatch.sh`, which strips
   agent labels from the linked issue — but only as its **last** step.
2. That label strip is fragile: it runs after a heavyweight Claude
   doc-cleanup session, follow-up issue filing, and doc pushes. Under
   `set -euo pipefail`, any earlier failure aborts before labels are touched.
   `AGENT_CLEANUP_ENABLED=false` skips label cleanup entirely.
3. Only the **first** linked issue (`closingIssuesReferences[0]`) is cleaned.
4. The weekly `cleanup.sh` cron never touches labels at all — the issue's
   "up to a week" assumption was wrong; stale labels persist forever.
5. The observed FingerWizard incident had a simpler cause: that repo's
   wiring predates `sandbox-pal-post-merge.yml` and has no caller workflow.
   (Fixing FingerWizard is out of scope here — separate action on that repo.)

## Decisions (user-approved)

1. **Terminal label `agent:done`** — on merge, all `agent:*` state labels are
   replaced with `agent:done`, making merged-by-agent work greppable
   (`gh issue list -l agent:done`). The label is provisioned in
   `labels.txt`/`create-labels.sh`, and applied best-effort with
   `gh label create --force` first so repos provisioned before this change
   still get marked.
2. **Label transition runs first** — restructure `handle_post_merge`: resolve
   linked issues and apply `agent:done` immediately after the merged/bot-author
   guards, before the circuit breaker, worktree, and Claude session.
   `AGENT_CLEANUP_ENABLED` gates **only** the doc-cleanup session from then on.
   All `closingIssuesReferences` are processed, not just the first; the
   branch-name fallbacks (`issue-N`, `feature/N-...`) remain.
3. **Weekly safety net with precise terminal state** — new `cleanup.sh` task:
   closed issues still carrying `agent:*` state labels get them stripped;
   `agent:done` is added **only** when a merged closing PR qualifies as agent
   work (authored by `AGENT_BOT_USER` when that var is available; any merged
   closing PR when it is not — the issue carried agent labels, so a merged
   closing PR is almost certainly the agent's). This catches repos without
   the post-merge caller wired, missed webhooks, and manually closed issues.

## Non-decisions / scope limits

- No new workflow and no new consumer wiring — the existing post-merge event
  and weekly cron carry everything.
- No new config variable — `AGENT_CLEANUP_ENABLED` keeps its name; its docs
  are updated to say it gates only the doc-cleanup session.
- `agent:failed` and `agent:review-unresolved` on closed issues are swept
  like other state labels: on a closed issue, all agent state is stale.
- Reopened issues: `agent:done` is a member of `ALL_AGENT_LABELS`, so any
  later `set_label` transition (e.g. re-triage after reopening) removes it
  naturally.

## Components

| Piece | File | Change |
|-------|------|--------|
| Label definition | `labels.txt`, `scripts/create-labels.sh` | add `agent:done` (color `6F42C1`) |
| Label machine | `scripts/lib/common.sh` | `agent:done` in `ALL_AGENT_LABELS`; new `mark_issue_done()` helper |
| Per-merge transition | `scripts/sandbox-pal-dispatch.sh` `handle_post_merge` | restructure per Decision 2 |
| Weekly sweep | `scripts/cleanup.sh` | new `sweep_stale_agent_labels` task + counter + summary + optional `AGENT_CONFIG` sourcing for `AGENT_BOT_USER` |
| Docs | `docs/architecture.md`, `docs/operations.md`, `docs/getting-started.md`, `docs/configuration.md`, `docs/troubleshooting.md` | label tables, flow diagrams, `AGENT_CLEANUP_ENABLED` semantics, stale-label troubleshooting entry |
| Tests | `tests/test_common.bats`, `tests/test_dispatch_post_merge.bats`, `tests/test_cleanup.bats` (new) | see plan; includes `REGRESSION v1.2.0` tests for the lingering-label bug |

## Error handling

- All `gh` label operations stay best-effort (`2>/dev/null || true`) — label
  bookkeeping must never fail the dispatch or the cron.
- The sweep respects `cleanup.sh`'s existing `--dry-run` default, counters,
  and JSONL audit log.

## Testing

BATS throughout (existing harness patterns: function extraction via
`sed -n '/^fn()/,/^}/p'`, `gh` mocked as a shell function recording calls).
The sed-extraction constraint applies to `handle_post_merge` and the new
cleanup function: **no column-0 `}` inside function bodies**. Full suite +
`shellcheck` must pass (CLAUDE.md: zero warnings).
