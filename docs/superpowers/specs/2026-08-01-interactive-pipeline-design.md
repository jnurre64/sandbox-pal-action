# Interactive Pipeline: Plan-Session On-Ramp, Review Loop, Cleanup Phase, Fallback Skills

**Date:** 2026-08-01
**Status:** Approved design, pending implementation plan
**Repos touched:** sandbox-pal-action (primary), the user-global `work-issue` skill (`~/.claude/skills/work-issue/`)

## Problem

The current end-to-end issue workflow is a mix of automated and manual hand-offs:

1. `/work-issue N` runs an interactive brainstorm → spec → implementation plan, then emits a **paste-me handoff prompt**. The human must `/clear`, paste, and babysit each subsequent phase transition.
2. Implementation, adversarial review, review-fix, PR-feedback revision, and post-merge cleanup each want a **fresh context**, but chaining them is manual copy-paste.
3. sandbox-pal-action already automates most of this (label state machine, fresh `claude -p` per phase, post-impl review, revision phase, Discord approvals) — but its entry point is **autonomous** triage/planning, not an interactively authored plan.

The goal: after the human approves the plan at the end of the interactive session, the machine runs unattended — implement → adversarial review loop → PR — and the first human touchpoint is "PR ready for playtest."

## Design summary

**Prompts define phases → labels orchestrate → skills are the interactive fallback → subagents work inside phases where independence helps.**

- The canonical definition of each phase is its prompt file in `prompts/`. Both execution paths (headless dispatch, interactive fallback skill) read the same file, so they cannot drift.
- The GitHub label state machine + Actions runners remain the orchestrator. No Claude session supervises the pipeline; supervision is mechanical.
- The Workflow tool / agent teams are **not** used for orchestration (they live inside one session's lifetime; this pipeline is deliberately cross-session). Subagents are used *inside* phases (subagent-driven implementation, independent verifier subagents in review).
- `/loop` and `/goal` are not orchestration primitives (both are same-context). `/goal` may later serve as a phase-internal completion criterion (see Deferred).

## Pipeline

```
[INTERACTIVE — Fable]                                  [GATE 1 — in-session]
/work-issue N ──> brainstorm + spec + plan ──> human approves ──> skill posts plan
                  (unchanged from today)         in conversation    + applies
                                                                    agent:plan-approved
                                                                          │
[HEADLESS — fresh context per phase]                                      v
implement (Opus 5) ──> adversarial review loop (Fable, ≤3 cycles) ──> PR opens
  agent:in-progress        review ⇄ fix until clean                agent:pr-open
                                                                          │
                                                              [GATE 2 — human]
                                                        ping: "ready for playtest"
                                                                          │
        PR comments / changes requested ──> revision (Fable) ──┐          │
                                             agent:revision ───┘          v
                                                                   human merges
                                                                          │
                                                                          v
                                              cleanup phase (merge-triggered, headless)
```

### Gates

- **Gate 1 — plan approval, inside the interactive session.** The final step of `/work-issue`: the human approves the plan in conversation; the skill posts the plan as an issue comment and applies `agent:plan-approved` itself. No Discord ping between planning and implementation.
  - **Actor guard:** the existing guard is `github.actor != '<bot>'` — it filters only the bot account. The skill verifies its `gh` identity before applying the label; if it is running under the bot's identity (e.g., a bot-authenticated channel session), it stops and asks the human to apply the label (one click), which degrades gracefully to today's behavior.
- **Gate 2 — playtest + merge.** The pipeline's only ping. PR body carries the review ledger (see below). Merge is always manual ("working entirely" gate). PR feedback loops through `agent:revision` back to Gate 2.

### Models (config only)

| Phase | Model config | Value |
|---|---|---|
| Interactive brainstorm/plan | (interactive session) | Fable |
| Implement | `AGENT_MODEL_IMPLEMENT` | `claude-opus-5` |
| Adversarial review | `AGENT_MODEL_POST_IMPL_REVIEW` | `claude-fable-5` |
| Review-fix (retry) | `AGENT_MODEL_POST_IMPL_RETRY` | `claude-fable-5` |
| PR revision | `AGENT_MODEL_REVIEW` | `claude-fable-5` |
| Cleanup | new: `AGENT_MODEL_CLEANUP` | cheap (default = triage model) |

## Component 1 — work-issue v2 (interactive on-ramp)

Steps 1–7 of the existing skill (fetch issue, linked context, feature branch, investigate, brainstorm, write plan, commit/push) are unchanged. The tail changes:

- **Step 8 (replaces handoff prompt): arm the pipeline.**
  1. Post the plan as an issue comment in the format the implement phase already consumes (`AGENT_PLAN_CONTENT`).
  2. The "context the plan does not repeat" and "open questions / risks" sections of the old handoff template move **into** the plan/issue comment — the implement session is the consumer now, not a pasted prompt.
  3. Ask the human for final approval in conversation.
  4. On approval: verify `gh api user` is a non-bot identity, then apply `agent:plan-approved`.
  5. Confirm: "Pipeline armed — next ping will be the PR ready for playtest."
- The skill remains **user-global** (`~/.claude/skills/work-issue/`); project conventions come from each repo's CLAUDE.md. Portability = file sync.

### sandbox-pal-action change required

The implement phase must detect that a feature branch with a committed plan/spec **already exists** for the issue (branch name convention `feature/<N>-<slug>`, plan under `docs/superpowers/plans/`) and check it out instead of creating a fresh branch. Plan content still arrives via the issue comment; the branch carries the spec and any investigation artifacts.

## Component 2 — adversarial review loop (capped, ledger-driven)

Current behavior: one post-impl review pass (`AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1`) inside the implement job, before PR creation.

New behavior:

- **Loop until clean, hard cap 3 cycles.** Cycle = fresh Fable review session → if blocking findings, fresh Fable retry session fixes → next review pass. The loop driver is the dispatch script (bash), not a model.
- **Findings ledger.** A structured findings file committed to the branch each cycle. Each finding: id, description, severity, status ∈ {`open`, `fixed`, `rejected` (with the retry session's justification), `non-blocking`}. Each review pass receives the ledger and must (in order): verify `fixed` items, review the new delta, then hunt further — never rediscover from scratch. This is the convergence mechanism.
- **Only correctness / stated-requirement findings are blocking** and drive the loop. Style and nice-to-have observations are recorded as `non-blocking` and never trigger a retry cycle. (Anthropic's guidance: a reviewer asked to find gaps will report some even when work is sound — the prompt must scope what counts.)
- **Convergence:** PR opens; PR body includes the ledger summary — cycles run, findings fixed, `rejected` items surfaced for the human to arbitrate during playtest.
- **Cap-hit without convergence:** the PR **still opens**, labeled `agent:review-unresolved`, outstanding findings at the top of the PR body, and the Gate 2 ping says so explicitly. Rationale: an honest PR with evidence beats a dead pipeline; merge is manual either way.

## Component 3 — cleanup phase (merge-triggered)

New workflow on `pull_request` closed-with-merge for agent-labeled PRs. Short headless session, cheap model, low `--max-turns`:

- Confirm the issue closed (Closes #N).
- Update tracking docs when the project has them (e.g., `claude-work/Next_Tasks.md`, constants references) — discovered via the project's CLAUDE.md, not hardcoded.
- File follow-up issues for anything the ledger deferred (`rejected`/`non-blocking` items worth tracking).
- Delete the merged branch.

The existing *scheduled* `cleanup.sh` (stale branches, gists, old runs) is untouched.

## Component 4 — fallback skills (headless-gating insurance)

Motivation: headless `claude -p` currently works on subscription plans, but Anthropic has already once announced (then paused) splitting programmatic billing from subscriptions. The pipeline must survive headless being gated without a rewrite.

- sandbox-pal-action gains `skills/`: `sp-implement <issue>`, `sp-review <pr>`, `sp-revise <pr>`, `sp-cleanup <pr>`.
- Each skill is a **thin wrapper**: it resolves the same context the dispatch script builds (issue body, plan comment, ledger, attached data) via the shared `scripts/lib` helpers, then executes the **same prompt file** inline in the current interactive session, and performs the same label transitions.
- In fallback mode there is **no orchestrator**: labels remain the state ledger; the human (from any interactive session — terminal, or a Discord-bridged channel session) fires each phase with one command. The Discord channel session is a convenient keyboard, not a supervising process.
- Fresh-context discipline in fallback mode: each skill's header instructs running it in a fresh session (or the invoking session dispatches it into a subagent, which has a clean context window).
- Secondary use, independent of gating: manual recovery/debugging — re-run a single phase interactively to see why it failed.
- `/setup` offers to install the skills globally (`~/.claude/skills/`) or per-project.

## Failure handling

- Any phase crash → existing `agent:failed` label + Discord notification. No automatic retry storms.
- The fallback skills double as the recovery path.
- Existing circuit breaker, concurrency groups, and timeouts stay; new workflows adopt the same `concurrency` + `timeout-minutes` hygiene.
- Headless invocations keep `--output-format json`; the dispatch script logs `total_cost_usd` per phase for spend visibility.

## Portability (Pompom)

Two synced surfaces:

1. **sandbox-pal-action repo** — prompts, dispatch scripts, workflows, fallback skills, config. Any repo that adopts the action inherits the whole pipeline.
2. **`~/.claude/`** — `work-issue` skill, global fallback skills, settings.

Pompom either registers its own runner or simply drives the same GitHub-hosted state machine (labels don't care where they're applied from). The Discord bot continues unchanged as the notification/approval UI.

## Deferred (explicitly out of scope for v1)

- **Workflow-tool-powered review** (parallel review dimensions → adversarial verifier subagents → synthesis) as a drop-in upgrade to `post-impl-review.md`. The review prompt is written so this can be swapped in without touching the state machine.
- **`/goal` as phase-internal completion criterion** (e.g., implement phase: `/goal all tests pass`). Confirmed to work headless; adopt after observing v1 behavior.
- **Discord-channel supervisor session** (a live Claude session polling and spawning phases). Rejected: burns tokens on supervision, machine-local, duplicates the label machine. The Discord bot covers notifications/approvals.
- **Auto-merge.** Never; Gate 2 is permanent.

## Open questions (to resolve during implementation planning)

- Exact ledger file format/location on the branch (proposed: `.agent-data/review-ledger.json`) and how the PR body summarizes it.
- Whether `agent:review-unresolved` needs its own workflow hooks or is annotation-only.
- How the implement phase detects the pre-existing branch (branch-name convention vs. a marker in the plan comment).
