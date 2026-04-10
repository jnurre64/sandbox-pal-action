# Design: Adversarial Review Gates — Plan Review + Post-Implementation Review

**Date:** 2026-04-10
**Issue:** #26 — Add adversarial review gates: plan review + post-implementation review
**Scope:** Core dispatch system (`scripts/`, `prompts/`, config, tests)

## Problem

Research on autonomous agent quality (SWE-bench overfitting studies) shows 21-33% of agent-generated patches pass tests but are wrong. The strongest mitigation is session separation for review — a fresh AI session evaluating the plan/diff catches problems that in-context self-review misses, because the reviewing session doesn't share the reasoning context that produced the output.

Issue #103/PR #104 demonstrated this: the agent's `nearest_on_web` strategy ignored the spider's position, causing 2.5x suboptimal paths. The test codified the wrong behavior because it tested a simplified topology where the fix trivially works.

## Approach

Add two review gates as a new `scripts/lib/review-gates.sh` module, following the existing `lib/` module pattern. Each gate is a fresh Claude session with read-only tools that reviews work product (plan or diff) against the original issue. Gates are called inline from the existing `handle_implement()` and `handle_post_implementation()` flows.

No new dispatch events, label types, or notification events. Existing labels (`agent:needs-info`, `agent:failed`) and notifications cover all end states.

## Design

### New Module: `scripts/lib/review-gates.sh`

Two primary functions and one retry handler.

#### `run_adversarial_plan_review()`

Checks the approved plan against the original issue before implementation begins.

**Inputs** (via environment, following existing convention):
- `AGENT_ISSUE_TITLE`, `AGENT_ISSUE_BODY`, `AGENT_COMMENTS` — original issue context
- `AGENT_PLAN_CONTENT` — the approved plan
- `AGENT_DATA_COMMENT_FILE`, `AGENT_GIST_FILES`, `AGENT_DATA_ERRORS` — extracted debug data

**Behavior:**
1. Check `AGENT_ADVERSARIAL_PLAN_REVIEW` config — if `false`, return 0 (skip)
2. Load prompt via `load_prompt "adversarial-plan" "$AGENT_PROMPT_ADVERSARIAL_PLAN"`
3. Call `run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE"` (read-only tools)
4. Parse JSON output for `action` field:
   - `"approved"` — plan aligns with issue. Log, return 0.
   - `"corrected"` — minor inconsistencies found and fixed. Extract `corrections` array and `revised_plan`. Post issue comment noting what was caught/changed (with `<!-- agent-adversarial-review -->` HTML marker). Update `AGENT_PLAN_CONTENT` with the revised plan. Return 0.
   - `"needs_clarification"` — ambiguity that requires human input. Extract `questions` array. Post issue comment with questions. Call `set_label "agent:needs-info"`. Return 1 (halts implementation).
   - Parse failure — log error, set `agent:failed`, return 1.

**Key constraint:** `"corrected"` is only for minor inconsistencies the reviewer can resolve confidently (e.g., plan says "nearest to bug" but issue says "minimize total travel"). Major deviations or ambiguities must use `"needs_clarification"`. The prompt enforces this distinction.

#### `run_post_impl_review()`

Checks the implementation diff against the original issue and plan after tests pass.

**Inputs** (via environment):
- Same issue/plan context as Gate A
- Git diff available in the worktree (`git diff origin/main..HEAD`)

**Behavior:**
1. Check `AGENT_POST_IMPL_REVIEW` config — if `false`, return 0 (skip)
2. Load prompt via `load_prompt "post-impl-review" "$AGENT_PROMPT_POST_IMPL_REVIEW"`
3. Call `run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE"` (read-only tools)
4. Parse JSON output:
   - `"approved"` — diff looks good. Log, return 0.
   - `"concerns"` — extract `concerns` array. Set `POST_IMPL_REVIEW_CONCERNS` env var. Return 1 (triggers retry).
   - Parse failure — log error, set `agent:failed`, return 1.

#### `handle_post_impl_review_retry()`

Called when `run_post_impl_review()` returns 1 and retries are enabled.

**Behavior:**
1. Check `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` — if `0`, post concerns as issue comment, set `agent:failed`, return 1
2. Capture pre-retry SHA: `retry_start_sha=$(git rev-parse HEAD)`
3. Load prompt via `load_prompt "post-impl-retry" "$AGENT_PROMPT_POST_IMPL_RETRY"`
   - Prompt receives: original plan, the concerns array, instruction to make targeted fixes
   - Uses implementation tools (can modify code and commit)
   - Instructed to commit with `fix(review): address post-impl review concerns` prefix
4. Call `run_claude "$prompt" "$impl_tools"` (implementation tools)
5. Capture post-retry SHA: `retry_end_sha=$(git rev-parse HEAD)`
6. Re-run tests if `AGENT_TEST_COMMAND` is configured — if tests fail, set `agent:failed`, return 1
7. Re-run `run_post_impl_review()` — if still concerns, set `agent:failed`, post comment with all concerns, return 1
8. If approved: set `REVIEW_RETRY_CONCERNS` (original concerns) and `REVIEW_RETRY_COMMITS` (`retry_start_sha..retry_end_sha`), return 0

### Integration Points

#### Gate A in `handle_implement()`

Inserted after plan loading and environment export, before the implementation Claude session:

```
handle_implement():
  1. Setup worktree, fetch issue, load plan          (existing)
  2. Extract debug data, export environment           (existing)
  3. run_adversarial_plan_review()                    (NEW)
     - returns 1 → cleanup_worktree, return
     - returns 0, plan corrected → AGENT_PLAN_CONTENT already updated
  4. Load prompt & tools, run implementation session  (existing)
  5. handle_post_implementation()                     (existing)
```

Runs on both the normal path (`agent:plan-approved`) and the direct-implement path (`agent:implement`, after `validate.md` passes).

#### Gate B in `handle_post_implementation()`

Inserted after tests pass, before pushing and creating the PR:

```
handle_post_implementation():
  1. Count commits                                    (existing)
  2. Run test gate                                    (existing)
  3. run_post_impl_review()                           (NEW)
     - returns 0 → proceed to push/PR
     - returns 1 → handle_post_impl_review_retry()
       - returns 0 → proceed to push/PR (with annotation)
       - returns 1 → agent:failed, return
  4. Push, create PR                                  (existing)
```

#### PR Body Annotation

When Gate B triggered a successful retry, `handle_post_implementation()` checks for `REVIEW_RETRY_CONCERNS` and appends to the PR body:

```markdown
## Post-Implementation Review

The adversarial post-implementation review identified concerns that were
addressed before this PR was created:

**Concerns raised:**
- [concern 1]
- [concern 2]

**Commits addressing concerns:** abc1234..def5678
```

### Prompt Files

#### `prompts/adversarial-plan.md`

Fresh-session plan reviewer. Review criteria:
1. **Root cause alignment** — Does the plan address the actual problem, or a simplified version?
2. **Test strategy** — Will proposed tests catch the bug on the reported scenario, not just a trivial case?
3. **Edge cases** — What scenarios could still be broken after this fix?
4. **Side effects** — Could proposed changes break existing functionality?
5. **Data usage** — If the issue includes reproduction data, does the plan reference it?

Output format — strict JSON, no markdown fences:
- `{"action": "approved"}`
- `{"action": "corrected", "corrections": ["..."], "revised_plan": "..."}`
- `{"action": "needs_clarification", "questions": ["..."]}`

#### `prompts/post-impl-review.md`

Fresh-session diff reviewer. Instructed to run `git diff origin/main..HEAD` and `git log` to examine changes. Review criteria:
1. **Issue-diff alignment** — Does the diff address every requirement? Anything missing?
2. **Test quality** — Do tests verify behavior or implementation details? Would tests fail if the bug were reintroduced?
3. **Overfitting detection** — Are tests using the reported scenario, or a simplified version?
4. **Scope** — Any unrelated changes or scope creep?
5. **Architectural compliance** — Does the change follow existing patterns?

Output format:
- `{"action": "approved"}`
- `{"action": "concerns", "concerns": ["..."]}`

#### `prompts/post-impl-retry.md`

Write-access session that addresses Gate B concerns. Receives the concerns array and is instructed to make targeted fixes with `fix(review):` commit message prefix. Same implementation tools as the main implementation session.

### Configuration

New entries in `scripts/lib/defaults.sh`:

```bash
# Review gates
AGENT_ADVERSARIAL_PLAN_REVIEW="${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW="${AGENT_POST_IMPL_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-1}"

# Review gate prompt overrides (empty = use built-in defaults)
AGENT_PROMPT_ADVERSARIAL_PLAN="${AGENT_PROMPT_ADVERSARIAL_PLAN:-}"
AGENT_PROMPT_POST_IMPL_REVIEW="${AGENT_PROMPT_POST_IMPL_REVIEW:-}"
AGENT_PROMPT_POST_IMPL_RETRY="${AGENT_PROMPT_POST_IMPL_RETRY:-}"

# Model (empty = use CLI default)
AGENT_MODEL="${AGENT_MODEL:-}"
```

Behavior matrix for Gate B:

| `AGENT_POST_IMPL_REVIEW` | `MAX_RETRIES` | Behavior |
|---|---|---|
| `false` | (ignored) | Gate B skipped entirely |
| `true` | `0` | Review runs, concerns go straight to human (agent:failed) |
| `true` | `1` (default) | Review runs, agent gets one retry, then escalates |

#### `run_claude` model support

If `AGENT_MODEL` is non-empty, pass `--model "$AGENT_MODEL"` to the Claude CLI invocation. Otherwise omit the flag (CLI default behavior).

### Files Changed

**New files:**
| File | Purpose |
|---|---|
| `scripts/lib/review-gates.sh` | Gate A + Gate B + retry logic |
| `prompts/adversarial-plan.md` | Gate A prompt |
| `prompts/post-impl-review.md` | Gate B prompt |
| `prompts/post-impl-retry.md` | Gate B retry prompt |
| `tests/test_review_gates.bats` | All gate tests |

**Modified files:**
| File | Change |
|---|---|
| `scripts/agent-dispatch.sh` | Source `review-gates.sh`; call `run_adversarial_plan_review()` in `handle_implement()` |
| `scripts/lib/common.sh` | Call `run_post_impl_review()` + retry in `handle_post_implementation()`; add `--model` to `run_claude()`; add PR body annotation |
| `scripts/lib/defaults.sh` | Add defaults for new config values |
| `config.defaults.env.example` | Document new settings |

### Test Plan

New file `tests/test_review_gates.bats`:

**Gate A tests:**
- `approved` response → returns 0, no comment posted
- `corrected` response → returns 0, `AGENT_PLAN_CONTENT` updated, comment posted with `<!-- agent-adversarial-review -->` marker
- `needs_clarification` response → returns 1, comment posted, `agent:needs-info` set
- Malformed JSON → returns 1, `agent:failed` set
- Disabled (`AGENT_ADVERSARIAL_PLAN_REVIEW=false`) → returns 0 immediately, `run_claude` never called

**Gate B tests:**
- `approved` response → returns 0
- `concerns` response → returns 1, `POST_IMPL_REVIEW_CONCERNS` set
- Malformed JSON → returns 1, `agent:failed` set
- Disabled (`AGENT_POST_IMPL_REVIEW=false`) → returns 0 immediately

**Retry tests:**
- Retry succeeds → returns 0, `REVIEW_RETRY_CONCERNS` and `REVIEW_RETRY_COMMITS` set
- Retry fails (second review still has concerns) → returns 1, `agent:failed` set
- Tests fail after retry → returns 1, `agent:failed` set
- Retries disabled (`MAX_RETRIES=0`) → concerns posted immediately, no retry session

**Config tests** (in `tests/test_defaults.bats`):
- All new defaults have correct values

**Integration tests:**
- Corrected plan flows into implementation session
- Gate B retry → PR body contains review annotation
- Both gates disabled → existing flow unchanged (regression guard)

### Follow-Up Issue

File a separate enhancement issue for per-workflow model configuration: `AGENT_MODEL_TRIAGE`, `AGENT_MODEL_IMPLEMENT`, `AGENT_MODEL_REVIEW`, etc., overriding the global `AGENT_MODEL` when set.
