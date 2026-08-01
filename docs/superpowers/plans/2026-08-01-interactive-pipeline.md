# Interactive Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn sandbox-pal-action into the orchestrator for an interactively-planned issue pipeline: an interactive plan session arms the machine, which then runs implement → capped adversarial-review loop → PR → (human playtest/merge) → post-merge cleanup, with interactive fallback skills for every headless phase.

**Architecture:** The label state machine and fresh `claude -p` per phase stay unchanged. Four additions: (1) a ledger-driven review loop (cap = `AGENT_POST_IMPL_REVIEW_MAX_RETRIES`, new default 3) replacing the single-retry Gate B; (2) an `<!-- agent-branch: ... -->` marker in the plan comment so `handle_implement` builds on an interactively-created feature branch; (3) a `post_merge` event + cleanup phase; (4) thin `skills/` wrappers that run the same prompt files interactively. The user-global `work-issue` skill v2 arms the pipeline instead of emitting a paste-me handoff.

**Tech Stack:** Bash + jq (dispatch), BATS (`./tests/bats/bin/bats tests/`), GitHub Actions reusable workflows, Claude Code skills (markdown).

**Spec:** `docs/superpowers/specs/2026-08-01-interactive-pipeline-design.md` — read it first.

## Global Constraints

- Branch: `feature/interactive-pipeline` in `~/repos/sandbox-pal-action` (already exists, holds the spec commit).
- GitHub ops on this repo need `GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token)` (jnurre64 repo).
- Run tests with `./tests/bats/bin/bats tests/<file>.bats` from the repo root. Full suite: `./tests/bats/bin/bats tests/`.
- Existing test conventions: `load 'helpers/test_helper'`, mock `run_claude` by redefining the function after sourcing, `create_mock "gh" ""` for gh, `TEST_TEMP_DIR`, `assert_success`/`assert_failure`/`assert_equal` (bats-assert).
- Every new config var gets: a default in `scripts/lib/defaults.sh`, a commented entry in `config.defaults.env.example`, and a mention in `docs/configuration.md`.
- Commit messages: conventional prefixes (`feat:`, `fix:`, `docs:`, `test:`), one red-green cycle per commit. End with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Bash style: `set -euo pipefail` is active in the dispatch script — guard non-zero-tolerant commands with `|| true` / `set +e` blocks exactly as the surrounding code does.
- The ledger file path is always `${WORKTREE_DIR}/.agent-data/review-ledger.json`; it IS committed to the work branch (single file, forced add).

## File Structure

| File | Change |
|---|---|
| `scripts/lib/review-gates.sh` | + ledger helpers, rework `run_post_impl_review`, new `run_post_impl_retry_session` + `run_post_impl_review_loop`; delete `handle_post_impl_review_retry` |
| `scripts/lib/common.sh` | `handle_post_implementation` uses the loop + cap-hit path; new `extract_plan_branch`; `agent:review-unresolved` in `ALL_AGENT_LABELS` |
| `scripts/lib/defaults.sh` | retries default 3; new `AGENT_CLEANUP_ENABLED`, `AGENT_MODEL_CLEANUP`, `AGENT_PROMPT_CLEANUP`, `AGENT_ALLOWED_TOOLS_CLEANUP` |
| `scripts/lib/notify.sh` | new events `review_unresolved`, `cleanup_done` |
| `scripts/sandbox-pal-dispatch.sh` | `handle_implement` reorder + marker; new `post_merge` event + `handle_post_merge` |
| `prompts/post-impl-review.md`, `prompts/post-impl-retry.md` | ledger contract |
| `prompts/cleanup.md` | new |
| `.github/workflows/sandbox-pal-post-merge.yml` | new reusable workflow |
| `.claude/skills/setup/templates/caller-post-merge.yml`, `.claude/skills/setup/templates/standalone/sandbox-pal-post-merge.yml` | new caller templates (setup.sh's `*.yml` glob picks them up automatically — no setup.sh change needed) |
| `labels.txt` | + `agent:review-unresolved` |
| `skills/sp-implement/SKILL.md`, `skills/sp-review/SKILL.md`, `skills/sp-revise/SKILL.md`, `skills/sp-cleanup/SKILL.md` | new fallback skills |
| `config.defaults.env.example`, `docs/architecture.md`, `docs/configuration.md`, `docs/getting-started.md`, `CONTRIBUTING.md`, `README.md` | docs sync |
| `tests/test_review_gates.bats`, `tests/test_common.bats`, `tests/test_dispatch_post_merge.bats` (new) | tests |
| `~/.claude/skills/work-issue/SKILL.md` | new user-global work-issue v2 |
| Webber repo `.claude/skills/work-issue/` | deleted (small separate PR) |

---

### Task 1: Ledger helpers in review-gates.sh

**Files:**
- Modify: `scripts/lib/review-gates.sh` (append after `_extract_review_json`, before Gate A)
- Test: `tests/test_review_gates.bats` (append)

**Interfaces:**
- Consumes: `WORKTREE_DIR` (test sets it to `TEST_TEMP_DIR`), `jq`, `git`.
- Produces (used by Tasks 2–5, 7):
  - `_ledger_init` — sets global `LEDGER_FILE`, creates `{"cycles":0,"findings":[]}` if absent
  - `_ledger_merge_review <review_json>` — bumps `cycles`, marks `verified_fixed` ids fixed, re-opens `reopened` ids, appends new findings with sequential ids `F1..Fn`
  - `_ledger_apply_dispositions <dispositions_json>` — sets status/justification on open findings
  - `_ledger_blocking_open_count` — prints count of `severity=="blocking" && status=="open"`
  - `_ledger_pr_summary` — markdown of the whole ledger
  - `_ledger_outstanding_summary` — markdown of blocking+open findings only
  - `_ledger_commit <msg>` — force-adds and commits only the ledger file in `WORKTREE_DIR` (best-effort)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_review_gates.bats`:

```bash
# ═══════════════════════════════════════════════════════════════
# Review ledger helpers
# ═══════════════════════════════════════════════════════════════

_setup_ledger() {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
}

@test "ledger: init creates empty ledger file" {
    _setup_ledger
    [ -f "${TEST_TEMP_DIR}/.agent-data/review-ledger.json" ]
    run jq -r '.cycles' "$LEDGER_FILE"
    assert_output "0"
}

@test "ledger: init preserves an existing ledger" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    mkdir -p "${TEST_TEMP_DIR}/.agent-data"
    echo '{"cycles":2,"findings":[{"id":"F1","severity":"blocking","description":"x","status":"open","justification":""}]}' \
        > "${TEST_TEMP_DIR}/.agent-data/review-ledger.json"
    _ledger_init
    run jq -r '.cycles' "$LEDGER_FILE"
    assert_output "2"
}

@test "ledger: merge_review appends findings with sequential ids and bumps cycles" {
    _setup_ledger
    _ledger_merge_review '{"action":"concerns","findings":[{"severity":"blocking","description":"missing test"},{"severity":"non-blocking","description":"style nit"}]}'
    run jq -r '.cycles' "$LEDGER_FILE"
    assert_output "1"
    run jq -r '.findings[0].id' "$LEDGER_FILE"
    assert_output "F1"
    run jq -r '.findings[1].id' "$LEDGER_FILE"
    assert_output "F2"
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "open"
}

@test "ledger: merge_review marks verified_fixed and continues id sequence" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"}]}'
    _ledger_merge_review '{"verified_fixed":["F1"],"findings":[{"severity":"blocking","description":"b"}]}'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "fixed"
    run jq -r '.findings[1].id' "$LEDGER_FILE"
    assert_output "F2"
}

@test "ledger: merge_review reopens rejected findings listed in reopened" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"}]}'
    _ledger_apply_dispositions '[{"id":"F1","status":"rejected","note":"not a bug"}]'
    _ledger_merge_review '{"reopened":["F1"],"findings":[]}'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "open"
}

@test "ledger: apply_dispositions sets status and justification on open findings only" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"},{"severity":"blocking","description":"b"}]}'
    _ledger_apply_dispositions '[{"id":"F1","status":"fixed","note":"done"},{"id":"F2","status":"rejected","note":"by design"}]'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "fixed"
    run jq -r '.findings[1].justification' "$LEDGER_FILE"
    assert_output "by design"
    # A second disposition on an already-fixed finding is ignored
    _ledger_apply_dispositions '[{"id":"F1","status":"rejected","note":"flip"}]'
    run jq -r '.findings[0].status' "$LEDGER_FILE"
    assert_output "fixed"
}

@test "ledger: blocking_open_count counts only open blocking findings" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"},{"severity":"non-blocking","description":"b"},{"severity":"blocking","description":"c"}]}'
    _ledger_apply_dispositions '[{"id":"F1","status":"fixed","note":""}]'
    run _ledger_blocking_open_count
    assert_output "1"
}

@test "ledger: pr_summary renders cycles and findings" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"missing test"}]}'
    run _ledger_pr_summary
    assert_output --partial "Review cycles:"
    assert_output --partial "F1"
    assert_output --partial "missing test"
}

@test "ledger: outstanding_summary lists only open blocking findings" {
    _setup_ledger
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"real gap"},{"severity":"non-blocking","description":"nit"}]}'
    run _ledger_outstanding_summary
    assert_output --partial "real gap"
    refute_output --partial "nit"
}

@test "ledger: commit adds only the ledger file to git" {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    _source_review_gates
    _ledger_init
    echo "unrelated" > "${WORKTREE_DIR}/other.txt"
    _ledger_commit "review pass 1"
    run git -C "$WORKTREE_DIR" log --format='%s' -1
    assert_output --partial "review pass 1"
    run git -C "$WORKTREE_DIR" status --porcelain
    assert_output --partial "other.txt"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats -f "ledger"`
Expected: all new tests FAIL (`_ledger_init: command not found` or similar).

- [ ] **Step 3: Implement the helpers**

Append to `scripts/lib/review-gates.sh` after `_extract_review_json` (before the Gate A section):

```bash
# ─── Review ledger ──────────────────────────────────────────────
# A structured findings file that rides the work branch across review
# cycles. Path: ${WORKTREE_DIR}/.agent-data/review-ledger.json
# Schema: {"cycles": N, "findings": [{"id","severity","description","status","justification"}]}
#   severity: "blocking" | "non-blocking"
#   status:   "open" | "fixed" | "rejected"
LEDGER_FILE=""

_ledger_init() {
    LEDGER_FILE="${WORKTREE_DIR}/.agent-data/review-ledger.json"
    mkdir -p "$(dirname "$LEDGER_FILE")"
    if [ ! -f "$LEDGER_FILE" ] || ! jq -e '.findings' "$LEDGER_FILE" >/dev/null 2>&1; then
        echo '{"cycles": 0, "findings": []}' > "$LEDGER_FILE"
    fi
}

# Merge one review pass's parsed JSON output into the ledger.
# $1 = {"action":..., "verified_fixed":["F1"], "reopened":["F2"], "findings":[{"severity","description"}]}
_ledger_merge_review() {
    local review_json="$1"
    local tmp="${LEDGER_FILE}.tmp"
    jq --argjson r "$review_json" '
        .cycles += 1
        | .findings |= map(
            .id as $id
            | if ((($r.verified_fixed // []) | index($id)) != null) and .status == "open"
              then .status = "fixed"
              elif ((($r.reopened // []) | index($id)) != null)
              then .status = "open"
              else . end)
        | (.findings | length) as $base
        | .findings += ((($r.findings // []) | to_entries) | map(
            {id: ("F" + (($base + .key + 1) | tostring)),
             severity: (if .value.severity == "blocking" then "blocking" else "non-blocking" end),
             description: (.value.description // ""),
             status: "open",
             justification: ""}))
    ' "$LEDGER_FILE" > "$tmp" && mv "$tmp" "$LEDGER_FILE"
}

# Apply a retry session's dispositions to open findings.
# $1 = [{"id":"F1","status":"fixed"|"rejected","note":"..."}]
_ledger_apply_dispositions() {
    local dispositions_json="$1"
    local tmp="${LEDGER_FILE}.tmp"
    jq --argjson d "$dispositions_json" '
        .findings |= map(
            .id as $id
            | ((($d // []) | map(select(.id == $id))) | first) as $m
            | if $m != null and .status == "open"
                   and ($m.status == "fixed" or $m.status == "rejected")
              then . + {status: $m.status, justification: ($m.note // "")}
              else . end)
    ' "$LEDGER_FILE" > "$tmp" && mv "$tmp" "$LEDGER_FILE"
}

_ledger_blocking_open_count() {
    jq -r '[.findings[] | select(.severity == "blocking" and .status == "open")] | length' "$LEDGER_FILE"
}

_ledger_pr_summary() {
    jq -r '
        "**Review cycles:** \(.cycles)\n\n" +
        (if (.findings | length) == 0
         then "_No findings recorded._"
         else ([.findings[] |
            "- **\(.id)** [\(.severity) / \(.status)]: \(.description)"
            + (if (.justification // "") != "" then "\n  - justification: \(.justification)" else "" end)]
            | join("\n"))
         end)
    ' "$LEDGER_FILE"
}

_ledger_outstanding_summary() {
    jq -r '[.findings[] | select(.severity == "blocking" and .status == "open")
            | "- **\(.id)**: \(.description)"] | join("\n")' "$LEDGER_FILE"
}

# Commit ONLY the ledger file (it may sit under a gitignored .agent-data/).
_ledger_commit() {
    local msg="$1"
    git -C "$WORKTREE_DIR" add -f "$LEDGER_FILE" 2>/dev/null || true
    git -C "$WORKTREE_DIR" commit -m "chore(agent): review ledger — ${msg}" -- "$LEDGER_FILE" 2>/dev/null || true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats`
Expected: all pass (new ledger tests + all pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/review-gates.sh tests/test_review_gates.bats
git commit -m "feat: review ledger helpers (init/merge/dispositions/summaries/commit)"
```

---

### Task 2: Rework `run_post_impl_review` for the ledger contract

**Files:**
- Modify: `scripts/lib/review-gates.sh:146-188` (`run_post_impl_review`)
- Modify: `prompts/post-impl-review.md` (input + output sections)
- Test: `tests/test_review_gates.bats` (rewrite the existing Gate B review tests)

**Interfaces:**
- Consumes: `LEDGER_FILE` (Task 1; caller must have run `_ledger_init`), `load_prompt`, `run_claude`, `parse_claude_output`, `_extract_review_json`.
- Produces: `run_post_impl_review` — exports `AGENT_REVIEW_LEDGER` (ledger contents) before the session; on parseable output sets global `POST_IMPL_REVIEW_JSON` (compact JSON with `action` ∈ {`approved`,`concerns`}) and returns 0; on unparseable output keeps today's side effects (`agent:failed` + issue comment) and returns 1. The legacy `POST_IMPL_REVIEW_CONCERNS` global and the "concerns → return 1" behavior are REMOVED.

- [ ] **Step 1: Rewrite the Gate B review tests**

In `tests/test_review_gates.bats`, find the existing `run_post_impl_review` tests (search `Gate B`). Replace the "approved returns 0" / "concerns returns 1" style tests with:

```bash
@test "Gate B review: skipped when AGENT_POST_IMPL_REVIEW=false" {
    export AGENT_POST_IMPL_REVIEW="false"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    run run_post_impl_review
    assert_success
}

@test "Gate B review: approved output sets POST_IMPL_REVIEW_JSON and returns 0" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"findings\": []}"}'; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.action')" = "approved" ]
}

@test "Gate B review: concerns output sets POST_IMPL_REVIEW_JSON and returns 0" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"concerns\", \"findings\": [{\"severity\": \"blocking\", \"description\": \"weak test\"}]}"}'; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.findings[0].severity')" = "blocking" ]
}

@test "Gate B review: exports current ledger to the session env" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"seed"}]}'
    run_claude() { echo "{\"result\":\"{\\\"action\\\": \\\"approved\\\", \\\"echo_ledger\\\": $(echo "$AGENT_REVIEW_LEDGER" | jq -c '.cycles')}\"}"; }
    run_post_impl_review
    [ "$(printf '%s' "$POST_IMPL_REVIEW_JSON" | jq -r '.echo_ledger')" = "1" ]
}

@test "Gate B review: unparseable output sets agent:failed and returns 1" {
    export AGENT_POST_IMPL_REVIEW="true"
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    create_mock "gh" ""
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"I could not decide"}'; }
    run run_post_impl_review
    assert_failure
}
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats -f "Gate B review"`
Expected: FAIL — current implementation returns 1 on concerns and never sets `POST_IMPL_REVIEW_JSON`.

- [ ] **Step 3: Replace `run_post_impl_review`**

Replace the whole function (currently `scripts/lib/review-gates.sh:144-188`, including the `POST_IMPL_REVIEW_CONCERNS=""` line above it) with:

```bash
# ─── Gate B: Post-Implementation Review (one pass) ──────────────
# Runs a fresh Claude session reviewing the diff against issue/plan/ledger.
# Sets POST_IMPL_REVIEW_JSON (action=approved|concerns) and returns 0 on
# any parseable output; returns 1 only on parse failure (labels + comments).
POST_IMPL_REVIEW_JSON=""

run_post_impl_review() {
    if [ "${AGENT_POST_IMPL_REVIEW}" != "true" ]; then
        log "Post-implementation review: skipped (disabled)"
        POST_IMPL_REVIEW_JSON='{"action":"approved","findings":[]}'
        return 0
    fi

    log "Running post-implementation review..."
    export AGENT_REVIEW_LEDGER
    AGENT_REVIEW_LEDGER=$(cat "$LEDGER_FILE" 2>/dev/null || echo '{"cycles":0,"findings":[]}')

    local prompt
    prompt=$(load_prompt "post-impl-review" "${AGENT_PROMPT_POST_IMPL_REVIEW}")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_TRIAGE" "$AGENT_MODEL_POST_IMPL_REVIEW")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Post-impl review result: ${claude_output:0:500}"

    local json_block action
    json_block=$(_extract_review_json "$claude_output")
    set +e
    action=$(printf '%s' "$json_block" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e

    case "$action" in
        approved|concerns)
            POST_IMPL_REVIEW_JSON=$(printf '%s' "$json_block" | jq -c '.' 2>/dev/null)
            log "Post-implementation review: $action"
            return 0
            ;;
        *)
            log "Post-implementation review: could not parse response"
            log "Raw output: $claude_output"
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent post-implementation review could not parse its output. Please check the branch and create a PR manually if the implementation looks correct." 2>/dev/null || true
            return 1
            ;;
    esac
}
```

- [ ] **Step 4: Update `prompts/post-impl-review.md`**

Three edits:

1. After the "## Approved Plan" block, insert:

```markdown
## Review Ledger
Findings from previous review cycles (empty on the first pass):
- Run: echo "$AGENT_REVIEW_LEDGER"

The ledger is your working state. For each finding already in it:
- If its status is "fixed" claimed by a retry session, VERIFY the fix in the diff. List genuinely fixed ids in `verified_fixed`.
- If its status is "rejected", accept the justification unless it is demonstrably wrong (contradicted by the code or the issue). Only then list the id in `reopened` — rejections are otherwise left for the human to arbitrate.
- Do NOT re-report a finding that is already in the ledger; report only NEW findings.

Review priority: verify claimed fixes first, then review the newest commits (the delta), then look wider.
```

2. Replace the "### Step 4: Decide" section with:

```markdown
### Step 4: Decide

Classify every NEW finding by severity:
- **blocking** — affects correctness or a stated requirement of the issue/plan (wrong behavior, missing requirement, test that cannot catch the bug, overfitted test).
- **non-blocking** — style, naming, minor structure, nice-to-have. A reviewer asked to find gaps will usually find some; that is what non-blocking is for. Non-blocking findings NEVER trigger another fix cycle.

**If there are no new blocking findings and no open blocking findings remain:**
Output: {"action": "approved", "verified_fixed": ["F1"], "reopened": [], "findings": [{"severity": "non-blocking", "description": "..."}]}

**If blocking findings exist (new or still open):**
Output: {"action": "concerns", "verified_fixed": [], "reopened": [], "findings": [{"severity": "blocking", "description": "Specific concern with file/line references"}]}

All four keys are always present; use empty arrays when not applicable.
```

3. In the `## Rules` list, replace the line `- Be specific in concerns — reference exact files, line numbers, test names.` with `- Be specific in findings — reference exact files, line numbers, test names.` and add: `- Only "blocking" findings drive another fix cycle. When in doubt between severities, choose non-blocking.`

- [ ] **Step 5: Run tests**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats`
Expected: PASS. (If other existing tests referenced `POST_IMPL_REVIEW_CONCERNS`, update them in this step — grep first: `grep -rn "POST_IMPL_REVIEW_CONCERNS" tests/ scripts/`. After this task only `handle_post_impl_review_retry` still references it; that function is deleted in Task 4.)

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/review-gates.sh prompts/post-impl-review.md tests/test_review_gates.bats
git commit -m "feat: ledger contract for post-impl review pass"
```

---

### Task 3: Retry session with dispositions

**Files:**
- Modify: `scripts/lib/review-gates.sh` (new function after `run_post_impl_review`)
- Modify: `prompts/post-impl-retry.md`
- Test: `tests/test_review_gates.bats`

**Interfaces:**
- Consumes: `LEDGER_FILE`, `load_prompt`, `run_claude`, `AGENT_TEST_COMMAND`/`AGENT_TEST_SETUP_COMMAND`.
- Produces: `run_post_impl_retry_session <impl_tools>` — exports `AGENT_REVIEW_LEDGER` + legacy `AGENT_REVIEW_CONCERNS` (open blocking findings as bullets, for custom prompt overrides), runs the retry session, re-runs the test gate; sets global `RETRY_DISPOSITIONS_JSON` (`[]` when unparseable) and returns 0; returns 1 only when the test gate fails (posts comment + `agent:failed`, as today).

- [ ] **Step 1: Write failing tests**

Append to `tests/test_review_gates.bats`:

```bash
# ═══════════════════════════════════════════════════════════════
# run_post_impl_retry_session
# ═══════════════════════════════════════════════════════════════

@test "retry session: parses dispositions and returns 0" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"a"}]}'
    run_claude() { echo '{"result":"{\"action\": \"addressed\", \"dispositions\": [{\"id\": \"F1\", \"status\": \"fixed\", \"note\": \"added test\"}]}"}'; }
    run_post_impl_retry_session "Read,Edit"
    [ "$(printf '%s' "$RETRY_DISPOSITIONS_JSON" | jq -r '.[0].id')" = "F1" ]
}

@test "retry session: unparseable output yields empty dispositions but returns 0" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"I did some fixes"}'; }
    run_post_impl_retry_session "Read,Edit"
    assert_equal "$RETRY_DISPOSITIONS_JSON" "[]"
}

@test "retry session: failing test gate returns 1" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    export AGENT_TEST_COMMAND="false"
    create_mock "gh" ""
    _source_review_gates
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"addressed\", \"dispositions\": []}"}'; }
    run run_post_impl_retry_session "Read,Edit"
    assert_failure
}

@test "retry session: exports open blocking findings as AGENT_REVIEW_CONCERNS" {
    export WORKTREE_DIR="$TEST_TEMP_DIR"
    _source_review_gates
    _ledger_init
    _ledger_merge_review '{"findings":[{"severity":"blocking","description":"needs coverage"},{"severity":"non-blocking","description":"nit"}]}'
    run_claude() { echo "{\"result\":\"{\\\"action\\\": \\\"addressed\\\", \\\"dispositions\\\": []}\"}"; }
    run_post_impl_retry_session "Read,Edit"
    [[ "$AGENT_REVIEW_CONCERNS" == *"needs coverage"* ]]
    [[ "$AGENT_REVIEW_CONCERNS" != *"nit"* ]]
}
```

- [ ] **Step 2: Verify red**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats -f "retry session"`
Expected: FAIL (`run_post_impl_retry_session: command not found`).

- [ ] **Step 3: Implement**

Add to `scripts/lib/review-gates.sh` after `run_post_impl_review`:

```bash
# ─── Gate B retry session (one fix pass) ────────────────────────
RETRY_DISPOSITIONS_JSON="[]"

run_post_impl_retry_session() {
    local impl_tools="$1"
    log "Review loop: retry session addressing open blocking findings..."

    export AGENT_REVIEW_LEDGER
    AGENT_REVIEW_LEDGER=$(cat "$LEDGER_FILE")
    # Legacy env for custom prompt overrides that predate the ledger
    export AGENT_REVIEW_CONCERNS
    AGENT_REVIEW_CONCERNS=$(jq -r '[.findings[] | select(.severity == "blocking" and .status == "open")
        | "- \(.id): \(.description)"] | join("\n")' "$LEDGER_FILE")

    local prompt
    prompt=$(load_prompt "post-impl-retry" "${AGENT_PROMPT_POST_IMPL_RETRY}")

    local result
    result=$(run_claude "$prompt" "$impl_tools" "$AGENT_MODEL_POST_IMPL_RETRY")

    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Retry output: ${claude_output:0:500}"

    # Re-run tests if configured (a retry must never ship a red suite)
    if [ -n "$AGENT_TEST_COMMAND" ]; then
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Test setup command exited with non-zero (continuing)"
        fi
        log "Review loop retry: re-running tests..."
        local test_output test_exit
        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e
        if [ "$test_exit" -ne 0 ]; then
            log "Review loop retry: tests failed after retry"
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "## Post-Implementation Review: Retry Failed

Tests failed after addressing review findings.

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
            return 1
        fi
    fi

    local json_block action
    json_block=$(_extract_review_json "$claude_output")
    set +e
    action=$(printf '%s' "$json_block" | jq -r '.action // empty' 2>/dev/null || echo "")
    set -e
    if [ "$action" = "addressed" ]; then
        RETRY_DISPOSITIONS_JSON=$(printf '%s' "$json_block" | jq -c '.dispositions // []' 2>/dev/null || echo "[]")
    else
        RETRY_DISPOSITIONS_JSON="[]"
        log "Retry session output had no parseable dispositions; findings stay open for the next review pass"
    fi
    return 0
}
```

- [ ] **Step 4: Update `prompts/post-impl-retry.md`**

Replace its "## Review Concerns" section with:

```markdown
## Review Ledger
The full findings ledger from the review loop:
- Run: echo "$AGENT_REVIEW_LEDGER"

Open blocking findings (the ones you must address):
- Run: echo "$AGENT_REVIEW_CONCERNS"

For each open blocking finding, either FIX it (make the code/test change and commit) or REJECT it with a specific technical justification (only when the finding is factually wrong for this codebase — a rejection is arbitrated by a human before merge, so never reject to save effort). Non-blocking findings are optional; fix them only if trivial.
```

At the end of the prompt's instructions (where it currently describes final output), replace with:

```markdown
## Final Output

After committing your fixes, output ONLY this JSON object (no markdown, no fences):

{"action": "addressed", "dispositions": [{"id": "F1", "status": "fixed", "note": "what was changed"}, {"id": "F2", "status": "rejected", "note": "specific technical justification"}]}

Every open blocking finding id from the ledger MUST appear in `dispositions`.
```

- [ ] **Step 5: Verify green**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/review-gates.sh prompts/post-impl-retry.md tests/test_review_gates.bats
git commit -m "feat: retry session emits ledger dispositions"
```

---

### Task 4: The review loop (replaces single retry)

**Files:**
- Modify: `scripts/lib/review-gates.sh` — add `run_post_impl_review_loop`; DELETE `handle_post_impl_review_retry` (and its `REVIEW_RETRY_CONCERNS`/`REVIEW_RETRY_COMMITS` globals)
- Modify: `scripts/lib/defaults.sh:64` — `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` default `1` → `3`
- Test: `tests/test_review_gates.bats` — delete the old `handle_post_impl_review_retry` tests, add loop tests

**Interfaces:**
- Consumes: Tasks 1–3 functions.
- Produces: `run_post_impl_review_loop <impl_tools>` — return codes: `0` clean (no open blocking findings), `1` hard failure (parse failure or test-gate failure; labels/comments already posted), `2` cap-hit (retries exhausted, blocking findings still open). Ledger committed after every review pass and every disposition application. `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` = number of retry (fix) sessions; `0` now means "single review pass, unresolved concerns go to the PR as unresolved" (return 2), no longer `agent:failed`.

- [ ] **Step 1: Delete old retry tests, write loop tests**

Delete every `@test` in `tests/test_review_gates.bats` that calls `handle_post_impl_review_retry` (grep: `grep -n "handle_post_impl_review_retry" tests/test_review_gates.bats`). Append:

```bash
# ═══════════════════════════════════════════════════════════════
# run_post_impl_review_loop
# ═══════════════════════════════════════════════════════════════

_setup_loop_worktree() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    _source_review_gates
}

@test "review loop: clean first pass returns 0" {
    _setup_loop_worktree
    run_claude() { echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"reopened\": [], \"findings\": []}"}'; }
    run run_post_impl_review_loop "Read,Edit"
    assert_success
}

@test "review loop: converges on second pass after a fix" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3
    LOOP_CALL_FILE="${TEST_TEMP_DIR}/calls"
    echo 0 > "$LOOP_CALL_FILE"
    run_claude() {
        local n; n=$(cat "$LOOP_CALL_FILE"); echo $((n + 1)) > "$LOOP_CALL_FILE"
        case "$n" in
            0) echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"gap\"}]}"}' ;;
            1) echo '{"result":"{\"action\": \"addressed\", \"dispositions\": [{\"id\": \"F1\", \"status\": \"fixed\", \"note\": \"done\"}]}"}' ;;
            *) echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [\"F1\"], \"reopened\": [], \"findings\": []}"}' ;;
        esac
    }
    run run_post_impl_review_loop "Read,Edit"
    assert_success
    # 3 sessions: review, retry, review
    [ "$(cat "$LOOP_CALL_FILE")" = "3" ]
}

@test "review loop: rejection with justification exits loop at next clean review" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3
    LOOP_CALL_FILE="${TEST_TEMP_DIR}/calls"
    echo 0 > "$LOOP_CALL_FILE"
    run_claude() {
        local n; n=$(cat "$LOOP_CALL_FILE"); echo $((n + 1)) > "$LOOP_CALL_FILE"
        case "$n" in
            0) echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"gap\"}]}"}' ;;
            1) echo '{"result":"{\"action\": \"addressed\", \"dispositions\": [{\"id\": \"F1\", \"status\": \"rejected\", \"note\": \"by design\"}]}"}' ;;
            *) echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"reopened\": [], \"findings\": []}"}' ;;
        esac
    }
    run run_post_impl_review_loop "Read,Edit"
    assert_success
    run jq -r '.findings[0].status' "${WORKTREE_DIR}/.agent-data/review-ledger.json"
    assert_output "rejected"
}

@test "review loop: cap-hit returns 2 with findings still open" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1
    LOOP_CALL_FILE="${TEST_TEMP_DIR}/calls"
    echo 0 > "$LOOP_CALL_FILE"
    run_claude() {
        local n; n=$(cat "$LOOP_CALL_FILE"); echo $((n + 1)) > "$LOOP_CALL_FILE"
        case "$n" in
            1) echo '{"result":"{\"action\": \"addressed\", \"dispositions\": []}"}' ;;
            *) echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"still broken '"$RANDOM"'\"}]}"}' ;;
        esac
    }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 2 ]
}

@test "review loop: MAX_RETRIES=0 returns 2 on first concerns (no retry session)" {
    _setup_loop_worktree
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0
    run_claude() { echo '{"result":"{\"action\": \"concerns\", \"verified_fixed\": [], \"reopened\": [], \"findings\": [{\"severity\": \"blocking\", \"description\": \"gap\"}]}"}'; }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 2 ]
}

@test "review loop: parse failure returns 1" {
    _setup_loop_worktree
    create_mock "gh" ""
    run_claude() { echo '{"result":"garbage"}'; }
    run run_post_impl_review_loop "Read,Edit"
    [ "$status" -eq 1 ]
}

@test "review loop: ledger is committed on the branch" {
    _setup_loop_worktree
    run_claude() { echo '{"result":"{\"action\": \"approved\", \"verified_fixed\": [], \"reopened\": [], \"findings\": []}"}'; }
    run_post_impl_review_loop "Read,Edit"
    run git -C "$WORKTREE_DIR" log --format='%s' -1
    assert_output --partial "review ledger"
}

@test "defaults: AGENT_POST_IMPL_REVIEW_MAX_RETRIES defaults to 3" {
    unset AGENT_POST_IMPL_REVIEW_MAX_RETRIES
    source "${LIB_DIR}/defaults.sh"
    assert_equal "$AGENT_POST_IMPL_REVIEW_MAX_RETRIES" "3"
}
```

Note on the cap-hit test: the `$RANDOM` in the finding description makes each review pass report a distinct new finding, so `blocking_open_count` stays > 0.

- [ ] **Step 2: Verify red**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats -f "review loop"`
Expected: FAIL (`run_post_impl_review_loop: command not found`). Also run `-f "defaults"` — the default test fails (currently 1).

- [ ] **Step 3: Implement the loop; delete `handle_post_impl_review_retry`**

Delete `handle_post_impl_review_retry` and the `export REVIEW_RETRY_CONCERNS=""` / `export REVIEW_RETRY_COMMITS=""` lines from `scripts/lib/review-gates.sh`. Add:

```bash
# ─── Gate B: capped review loop ─────────────────────────────────
# review → (fix → review)* until no open blocking findings, capped at
# AGENT_POST_IMPL_REVIEW_MAX_RETRIES fix sessions.
# Returns: 0 = clean, 1 = hard failure (already labeled/commented),
#          2 = cap reached with blocking findings still open.
run_post_impl_review_loop() {
    local impl_tools="$1"

    if [ "${AGENT_POST_IMPL_REVIEW}" != "true" ]; then
        log "Post-implementation review loop: skipped (disabled)"
        return 0
    fi

    _ledger_init
    local retries=0
    while true; do
        if ! run_post_impl_review; then
            return 1
        fi
        _ledger_merge_review "$POST_IMPL_REVIEW_JSON"
        _ledger_commit "review pass $((retries + 1))"

        local open
        open=$(_ledger_blocking_open_count)
        if [ "$open" -eq 0 ]; then
            log "Review loop: clean after $((retries + 1)) review pass(es), ${retries} retry session(s)"
            return 0
        fi

        if [ "$retries" -ge "$AGENT_POST_IMPL_REVIEW_MAX_RETRIES" ]; then
            log "Review loop: cap reached (${AGENT_POST_IMPL_REVIEW_MAX_RETRIES} retries) with ${open} open blocking finding(s)"
            return 2
        fi

        retries=$((retries + 1))
        if ! run_post_impl_retry_session "$impl_tools"; then
            return 1
        fi
        _ledger_apply_dispositions "$RETRY_DISPOSITIONS_JSON"
        _ledger_commit "retry ${retries} dispositions"
    done
}
```

In `scripts/lib/defaults.sh`, change line 64:

```bash
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-3}"
```

and update its comment to: `# Max fix sessions for the post-impl review loop (0 = single review pass; unresolved findings surface on the PR as agent:review-unresolved)`.

Also update the top-of-file comment in `review-gates.sh` (line 3-4) to: `# Provides: run_adversarial_plan_review, run_post_impl_review, run_post_impl_retry_session, run_post_impl_review_loop, ledger helpers`.

- [ ] **Step 4: Verify green**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats && ./tests/bats/bin/bats tests/test_defaults.bats`
Expected: PASS. If `test_defaults.bats` pins the old retry default of 1, update that assertion to 3.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/review-gates.sh scripts/lib/defaults.sh tests/test_review_gates.bats tests/test_defaults.bats
git commit -m "feat: capped ledger-driven review loop replaces single Gate B retry"
```

---

### Task 5: Wire the loop + cap-hit path into `handle_post_implementation`

**Files:**
- Modify: `scripts/lib/common.sh:193-326` (`handle_post_implementation`), `ALL_AGENT_LABELS` (line 13-26)
- Modify: `scripts/lib/notify.sh` (event lists)
- Modify: `labels.txt`
- Test: `tests/test_common.bats`, `tests/test_notify.bats`

**Interfaces:**
- Consumes: `run_post_impl_review_loop` (Task 4), `_ledger_pr_summary` / `_ledger_outstanding_summary` (Task 1).
- Produces: on loop rc=2 the PR is STILL created; the linked issue gets `agent:pr-open` plus the extra label `agent:review-unresolved`, the PR itself gets `agent:review-unresolved`, notify event `review_unresolved` fires, and the PR body leads with the outstanding findings. On rc=0 the PR body carries the full ledger summary. The old `REVIEW_RETRY_CONCERNS` annotation block is gone.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_common.bats` (it already sources `common.sh`; also source `review-gates.sh` in these tests for the ledger helpers):

```bash
# ═══════════════════════════════════════════════════════════════
# handle_post_implementation × review loop
# ═══════════════════════════════════════════════════════════════

_setup_post_impl() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    export REPO_DIR="${TEST_TEMP_DIR}/repo"
    export BRANCH_NAME="agent/issue-99"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    (cd "$WORKTREE_DIR" && echo x > f.txt && git add f.txt && git commit -qm "impl commit")
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/review-gates.sh"
    source "${LIB_DIR}/notify.sh"
    export AGENT_TEST_COMMAND=""
    # git push / gh must not hit the network
    create_mock "gh" "https://github.com/test-org/test-repo/pull/123"
    git() { if [ "$1" = "-C" ] && [ "$3" = "push" ]; then return 0; fi; command git "$@"; }
}

@test "post-impl: clean loop creates PR with ledger summary in body" {
    _setup_post_impl
    run_post_impl_review_loop() { _ledger_init; _ledger_merge_review '{"findings":[]}'; return 0; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_success
    # gh mock records args; PR body must include the ledger summary header
    run cat "${TEST_TEMP_DIR}/mock_calls_gh"
    assert_output --partial "Review cycles:"
}

@test "post-impl: cap-hit still creates PR and applies agent:review-unresolved" {
    _setup_post_impl
    run_post_impl_review_loop() {
        _ledger_init
        _ledger_merge_review '{"findings":[{"severity":"blocking","description":"unresolved gap"}]}'
        return 2
    }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_success
    run cat "${TEST_TEMP_DIR}/mock_calls_gh"
    assert_output --partial "agent:review-unresolved"
    assert_output --partial "unresolved gap"
}

@test "post-impl: loop hard failure halts PR creation" {
    _setup_post_impl
    run_post_impl_review_loop() { return 1; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_failure
}

@test "labels: agent:review-unresolved is a known agent label" {
    source "${LIB_DIR}/common.sh"
    [[ " ${ALL_AGENT_LABELS[*]} " == *" agent:review-unresolved "* ]]
}
```

Check how `create_mock` records calls (see `tests/helpers/test_helper.bash` — existing tests reference `mock_calls_<name>` files) and match the actual file naming; adjust the two `mock_calls_gh` reads if the helper uses a different path (e.g. `${TEST_TEMP_DIR}/mock_calls/gh`). Mirror whatever `tests/test_notify.bats` already does to inspect mock invocations.

Append to `tests/test_notify.bats`:

```bash
@test "notify level actionable includes review_unresolved" {
    export AGENT_NOTIFY_LEVEL="actionable"
    source "${LIB_DIR}/notify.sh"
    run _notify_should_send "review_unresolved"
    assert_success
}

@test "notify level actionable excludes cleanup_done" {
    export AGENT_NOTIFY_LEVEL="actionable"
    source "${LIB_DIR}/notify.sh"
    run _notify_should_send "cleanup_done"
    assert_failure
}
```

- [ ] **Step 2: Verify red**

Run: `./tests/bats/bin/bats tests/test_common.bats -f "post-impl" && ./tests/bats/bin/bats tests/test_notify.bats -f "review_unresolved"`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `scripts/lib/common.sh`:

1. Add `agent:review-unresolved` to `ALL_AGENT_LABELS` (after `agent:validating`).

2. In `handle_post_implementation`, replace the Gate B block (lines 244-256, from `# ── Post-implementation review (Gate B) ──` through the commit-count update) with:

```bash
        # ── Post-implementation review loop (Gate B) ─────────────
        local impl_tools review_rc=0
        impl_tools=$(get_implementation_tools)
        run_post_impl_review_loop "$impl_tools" || review_rc=$?
        if [ "$review_rc" -eq 1 ]; then
            log "Post-implementation review loop halted PR creation."
            return 1
        fi
        # Retry sessions and ledger commits may have added commits
        if [ -n "$start_sha" ]; then
            commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
        fi
```

3. Replace the `review_annotation` block (lines 265-279) and the `pr_body` assignment (lines 281-293) with:

```bash
        # Ledger summary for the PR body
        local ledger_summary="" unresolved_header=""
        if [ -f "${WORKTREE_DIR}/.agent-data/review-ledger.json" ]; then
            LEDGER_FILE="${WORKTREE_DIR}/.agent-data/review-ledger.json"
            ledger_summary="
### Adversarial Review Ledger

$(_ledger_pr_summary)
"
            if [ "$review_rc" -eq 2 ]; then
                unresolved_header="## ⚠ Review Unresolved

The adversarial review loop hit its retry cap with blocking findings still open. Do not merge before arbitrating these:

$(_ledger_outstanding_summary)

---
"
            fi
        fi

        local pr_body="${unresolved_header}## Automated PR for #${NUMBER}

This PR was created by the Claude Code agent.

${claude_output:0:2000}
${ledger_summary}
### Commits
${commit_log}

---
Please review carefully. The agent will address review feedback automatically.

Closes #${NUMBER}"
```

4. In the PR-created success branch (after `set_label "agent:pr-open"`), add:

```bash
            if [ "$review_rc" -eq 2 ]; then
                gh issue edit "$NUMBER" --repo "$REPO" --add-label "agent:review-unresolved" 2>/dev/null || true
                gh pr edit "$pr_url" --repo "$REPO" --add-label "agent:review-unresolved" 2>/dev/null || true
                notify "review_unresolved" "$issue_title" "$pr_url" "Review loop hit its cap — blocking findings need human arbitration"
            fi
```

Note: `set_label` strips all agent labels and sets exactly one, so the extra `--add-label` MUST come after `set_label "agent:pr-open"`.

In `scripts/lib/notify.sh`:
- `_notify_should_send` actionable case: add `review_unresolved` to the allowed list (`plan_posted|questions_asked|pr_created|review_feedback|review_pushed|agent_failed|review_unresolved`).
- `_notify_event_color`: add `review_unresolved) echo "16776960" ;;` (yellow) and `cleanup_done) echo "5763719" ;;` (green).
- `_notify_event_label`: add `review_unresolved) echo "Review Unresolved" ;;` and `cleanup_done) echo "Cleanup Complete" ;;`.
- `_notify_event_indicator`: add `review_unresolved) echo "[ACTION]" ;;` and `cleanup_done) echo "[OK]" ;;`.

In `labels.txt` append:

```
agent:review-unresolved|B60205|Review loop hit its cap; blocking findings need human arbitration before merge
```

- [ ] **Step 4: Verify green**

Run: `./tests/bats/bin/bats tests/`
Expected: full suite PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/common.sh scripts/lib/notify.sh labels.txt tests/test_common.bats tests/test_notify.bats
git commit -m "feat: cap-hit PRs open as agent:review-unresolved with ledger summary"
```

---

### Task 6: Interactive plan-branch marker

**Files:**
- Modify: `scripts/lib/common.sh` (new `extract_plan_branch`, near `load_prompt`)
- Modify: `scripts/sandbox-pal-dispatch.sh:348-450` (`handle_implement` reorder)
- Test: `tests/test_common.bats`

**Interfaces:**
- Consumes: plan comment content (`plan_content`).
- Produces: `extract_plan_branch <plan_content>` — prints the branch from the FIRST `<!-- agent-branch: NAME -->` marker; prints nothing when absent or when NAME contains characters outside `[A-Za-z0-9._/-]` (defense against comment-injected git arguments). `handle_implement` honors the marker: overrides `BRANCH_NAME`, never reuses the plan-phase worktree, and computes `start_sha` from the branch head (not `origin/main`) so pre-existing plan/spec commits don't defeat the no-commits guard. The work-issue v2 skill (Task 10) writes this marker.

- [ ] **Step 1: Write failing tests**

Append to `tests/test_common.bats`:

```bash
# ═══════════════════════════════════════════════════════════════
# extract_plan_branch
# ═══════════════════════════════════════════════════════════════

@test "extract_plan_branch: finds marker branch" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-plan -->
<!-- agent-branch: feature/400-async-rest-settle -->
# Plan body"
    assert_output "feature/400-async-rest-settle"
}

@test "extract_plan_branch: empty when no marker" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-plan -->
# Plan body"
    assert_output ""
}

@test "extract_plan_branch: rejects unsafe characters" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: feature/400;rm -rf / -->"
    assert_output ""
}

@test "extract_plan_branch: uses first marker only" {
    source "${LIB_DIR}/common.sh"
    run extract_plan_branch "<!-- agent-branch: feature/1-a -->
<!-- agent-branch: feature/2-b -->"
    assert_output "feature/1-a"
}
```

- [ ] **Step 2: Verify red**

Run: `./tests/bats/bin/bats tests/test_common.bats -f "extract_plan_branch"`
Expected: FAIL (command not found).

- [ ] **Step 3: Implement `extract_plan_branch`**

Add to `scripts/lib/common.sh` after `load_prompt`:

```bash
# ─── Interactive plan branch marker ─────────────────────────────
# An interactively-authored plan comment may carry
#   <!-- agent-branch: feature/123-some-slug -->
# naming the pre-pushed feature branch the implementation must build on.
# Prints the branch name, or nothing when absent/unsafe.
extract_plan_branch() {
    local plan="$1"
    local branch
    branch=$(printf '%s' "$plan" \
        | grep -oE '<!-- agent-branch: [^ >]+ -->' | head -1 \
        | sed -E 's/<!-- agent-branch: ([^ >]+) -->/\1/')
    if [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        printf '%s' "$branch"
    fi
}
```

- [ ] **Step 4: Verify green**

Run: `./tests/bats/bin/bats tests/test_common.bats -f "extract_plan_branch"`
Expected: PASS.

- [ ] **Step 5: Reorder `handle_implement`**

In `scripts/sandbox-pal-dispatch.sh`, restructure `handle_implement` so issue/plan fetch precedes worktree setup. Replace the section from `# Reuse existing worktree from plan phase, or create fresh one` (line 355) down to and including the `comments=` assignment (line 400) with:

```bash
    # Fetch issue details FIRST — an interactive plan comment can override
    # the branch before any worktree exists.
    local issue_json
    issue_json=$(gh issue view "$NUMBER" --repo "$REPO" --json title,body,comments)
    local issue_title issue_body
    issue_title=$(echo "$issue_json" | jq -r '.title')
    notify "implement_started" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation starting"
    issue_body=$(echo "$issue_json" | jq -r '.body')

    # Find the approved plan — use pre-loaded content (from direct implement) or extract from comments
    local plan_content
    if [ -n "${AGENT_PLAN_CONTENT:-}" ]; then
        plan_content="$AGENT_PLAN_CONTENT"
        log "Using pre-loaded plan content (direct implement)"
    else
        plan_content=$(echo "$issue_json" | jq -r '
            [.comments[] | select(.body | test("<!-- agent-plan -->"))] | last | .body // ""
        ' 2>/dev/null)

        if [ -z "$plan_content" ]; then
            log "Could not find plan comment on issue. Marking as failed."
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent could not find the approved plan comment. Expected a comment with \`<!-- agent-plan -->\` marker. Please re-run the plan phase by labeling with \`agent\`." 2>/dev/null || true
            return
        fi
    fi

    # Interactive plan branch marker (work-issue v2 on-ramp)
    local plan_branch interactive_plan=""
    plan_branch=$(extract_plan_branch "$plan_content")
    if [ -n "$plan_branch" ]; then
        log "Interactive plan branch detected: $plan_branch"
        # shellcheck disable=SC2034
        BRANCH_NAME="$plan_branch"
        interactive_plan=1
    fi

    # Worktree: reuse the plan-phase worktree only for the autonomous flow;
    # an interactive branch always gets a fresh worktree on that branch.
    if [ -z "$interactive_plan" ] && [ -d "$WORKTREE_DIR" ]; then
        log "Reusing existing worktree at $WORKTREE_DIR"
        git -C "$WORKTREE_DIR" fetch origin main 2>/dev/null || true
        git -C "$WORKTREE_DIR" merge origin/main --no-edit 2>/dev/null || true
        run_worktree_setup
    else
        if [ -d "$WORKTREE_DIR" ]; then
            git -C "$REPO_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
        fi
        log "Creating worktree for branch $BRANCH_NAME"
        setup_worktree
    fi

    # Baseline for the commit count: for interactive branches the plan/spec
    # commits already exist on the branch, so measure from the branch head.
    local start_sha
    if [ -n "$interactive_plan" ]; then
        start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")
    else
        start_sha=$(git -C "$WORKTREE_DIR" rev-parse origin/main 2>/dev/null || echo "")
    fi

    local comments
    comments=$(echo "$issue_json" | jq -r '.comments[] | "[\(.author.login)] \(.body)"' | tail -20)
```

Then DELETE the now-duplicated later occurrences inside `handle_implement` of: the original `start_sha` block, the original issue fetch block, and the original plan-content extraction block (the `cleanup_worktree`-on-missing-plan variant disappears with it — the early return above happens before any worktree exists, so no cleanup is needed). Verify with `bash -n scripts/sandbox-pal-dispatch.sh` and by reading the final function top-to-bottom: order must be fetch → plan → marker → worktree → start_sha → comments → extract_debug_data → exports → Gate A → implement session → `handle_post_implementation "$start_sha" ...` → `cleanup_worktree`.

- [ ] **Step 6: Syntax check + full suite**

Run: `bash -n scripts/sandbox-pal-dispatch.sh && ./tests/bats/bin/bats tests/`
Expected: clean syntax, all tests PASS (`tests/test_set_e_guards.bats` greps dispatch-script patterns — if it fails, read its assertions and keep the guards it checks intact in the moved code).

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/common.sh scripts/sandbox-pal-dispatch.sh tests/test_common.bats
git commit -m "feat: honor <!-- agent-branch --> marker from interactive plans"
```

---

### Task 7: `post_merge` event + cleanup phase

**Files:**
- Create: `.github/workflows/sandbox-pal-post-merge.yml`
- Create: `.claude/skills/setup/templates/caller-post-merge.yml`
- Create: `.claude/skills/setup/templates/standalone/sandbox-pal-post-merge.yml`
- Create: `prompts/cleanup.md`
- Modify: `scripts/sandbox-pal-dispatch.sh` (new handler + case arm)
- Modify: `scripts/lib/defaults.sh`
- Test: `tests/test_dispatch_post_merge.bats` (new), `tests/test_defaults.bats`

**Interfaces:**
- Consumes: `run_claude`, `load_prompt`, `parse_claude_output`, `_extract_review_json`, `setup_worktree`, `notify`.
- Produces: dispatch event `post_merge <repo> <pr_number>`; `handle_post_merge` — no-ops unless `AGENT_CLEANUP_ENABLED=true`, PR is merged, and PR author == `AGENT_BOT_USER`; deletes the merged branch; runs the cleanup session on a fresh worktree branched from `origin/main`; creates follow-up issues from the session's JSON; pushes doc commits to `main` (PR fallback); strips agent labels from the linked issue; fires `cleanup_done`.

- [ ] **Step 1: Write failing tests**

Create `tests/test_dispatch_post_merge.bats`:

```bash
#!/usr/bin/env bats
# Tests for handle_post_merge in scripts/sandbox-pal-dispatch.sh

load 'helpers/test_helper'

# handle_post_merge lives in the dispatch script; extract it by sourcing the
# libs and defining the function body via a sourced test double is fragile —
# instead these tests exercise the pure helpers and the config gate through
# a stub harness that sources the dispatch script's function definitions.
_source_dispatch_functions() {
    export SCRIPT_DIR="${SCRIPTS_DIR}"
    source "${LIB_DIR}/common.sh"
    source "${LIB_DIR}/worktree.sh"
    source "${LIB_DIR}/notify.sh"
    source "${LIB_DIR}/review-gates.sh"
    # shellcheck disable=SC1090
    source <(sed -n '/^handle_post_merge()/,/^}/p' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh")
}

@test "post_merge: disabled config gate returns 0 without calling gh" {
    export AGENT_CLEANUP_ENABLED="false"
    _source_dispatch_functions
    run handle_post_merge
    assert_success
    [ ! -f "${TEST_TEMP_DIR}/mock_calls_gh" ]
}

@test "post_merge: unmerged PR is skipped" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    gh() { echo '{"title":"t","body":"","headRefName":"agent/issue-9","mergedAt":null,"author":{"login":"test-bot"},"closingIssuesReferences":[]}'; }
    run handle_post_merge
    assert_success
}

@test "post_merge: non-bot-authored PR is skipped" {
    export AGENT_CLEANUP_ENABLED="true"
    _source_dispatch_functions
    gh() { echo '{"title":"t","body":"","headRefName":"feature/9-x","mergedAt":"2026-08-01T00:00:00Z","author":{"login":"some-human"},"closingIssuesReferences":[]}'; }
    run handle_post_merge
    assert_success
}

@test "defaults: cleanup config vars exist with safe defaults" {
    unset AGENT_CLEANUP_ENABLED AGENT_MODEL_CLEANUP AGENT_PROMPT_CLEANUP AGENT_ALLOWED_TOOLS_CLEANUP
    source "${LIB_DIR}/defaults.sh"
    assert_equal "$AGENT_CLEANUP_ENABLED" "true"
    [ -n "$AGENT_ALLOWED_TOOLS_CLEANUP" ]
}

@test "dispatch: post_merge is a recognized event type" {
    run grep -E '^\s+post_merge\)' "${SCRIPTS_DIR}/sandbox-pal-dispatch.sh"
    assert_success
}
```

(The `sed -n '/^handle_post_merge()/,/^}/p'` extraction requires `handle_post_merge` to end with a `}` at column 0 and to contain no other column-0 `}` — write the implementation accordingly, matching the existing handler style, which already satisfies this.)

- [ ] **Step 2: Verify red**

Run: `./tests/bats/bin/bats tests/test_dispatch_post_merge.bats`
Expected: FAIL (no `handle_post_merge`, missing defaults, missing case arm).

- [ ] **Step 3: Add defaults**

In `scripts/lib/defaults.sh`, after the review-gates block (line 69):

```bash
# ─── Post-merge cleanup phase ────────────────────────────────
# Runs a short headless session after an agent PR merges: tracking-doc
# updates, follow-up issues from the review ledger, branch deletion.
AGENT_CLEANUP_ENABLED="${AGENT_CLEANUP_ENABLED:-true}"
AGENT_PROMPT_CLEANUP="${AGENT_PROMPT_CLEANUP:-}"
AGENT_ALLOWED_TOOLS_CLEANUP="${AGENT_ALLOWED_TOOLS_CLEANUP:-Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git rm:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*)}"
```

And in the model block (after line 83): `AGENT_MODEL_CLEANUP="${AGENT_MODEL_CLEANUP:-}"  # post-merge cleanup phase`.

- [ ] **Step 4: Implement `handle_post_merge` + case arm**

In `scripts/sandbox-pal-dispatch.sh`, add after `handle_pr_review` (before the dispatch `case`):

```bash
# ═══════════════════════════════════════════════════════════════
# EVENT: Agent PR merged → post-merge cleanup phase
# ═══════════════════════════════════════════════════════════════
handle_post_merge() {
    if [ "${AGENT_CLEANUP_ENABLED}" != "true" ]; then
        log "Post-merge cleanup: disabled (AGENT_CLEANUP_ENABLED=${AGENT_CLEANUP_ENABLED})"
        return 0
    fi

    local pr_number="$NUMBER"
    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$REPO" --json title,body,headRefName,mergedAt,author,closingIssuesReferences)

    local merged_at pr_author branch pr_title
    merged_at=$(echo "$pr_json" | jq -r '.mergedAt // empty')
    if [ -z "$merged_at" ]; then
        log "PR #${pr_number} is not merged. Skipping cleanup."
        return 0
    fi
    pr_author=$(echo "$pr_json" | jq -r '.author.login // empty')
    if [ "$pr_author" != "$AGENT_BOT_USER" ]; then
        log "PR #${pr_number} was not authored by ${AGENT_BOT_USER}. Skipping cleanup."
        return 0
    fi
    branch=$(echo "$pr_json" | jq -r '.headRefName')
    pr_title=$(echo "$pr_json" | jq -r '.title')

    log "Post-merge cleanup for PR #${pr_number} (branch ${branch})..."
    check_circuit_breaker
    ensure_repo

    # Linked issue: closingIssuesReferences, else branch-name conventions
    local issue_num
    issue_num=$(echo "$pr_json" | jq -r '.closingIssuesReferences[0].number // empty')
    if [ -z "$issue_num" ]; then
        issue_num=$(echo "$branch" | sed -nE 's/.*issue-([0-9]+).*/\1/p')
    fi
    if [ -z "$issue_num" ]; then
        issue_num=$(echo "$branch" | sed -nE 's|^feature/([0-9]+)-.*|\1|p')
    fi

    # Delete the merged remote branch (best-effort)
    git -C "$REPO_DIR" push origin --delete "$branch" 2>/dev/null \
        || log "WARN: could not delete remote branch $branch (may be already gone)"

    # Fresh worktree on a chore branch off latest main
    # shellcheck disable=SC2034
    BRANCH_NAME="chore/agent-cleanup-pr-${pr_number}"
    WORKTREE_DIR="$WORKTREE_BASE/${REPO_NAME}-postmerge-${pr_number}"
    setup_worktree

    local start_sha
    start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

    export AGENT_PR_TITLE="$pr_title"
    export AGENT_PR_BODY
    AGENT_PR_BODY=$(echo "$pr_json" | jq -r '.body // ""')
    export AGENT_MERGED_BRANCH="$branch"
    export AGENT_ISSUE_NUMBER="${issue_num:-}"
    export AGENT_REVIEW_LEDGER=""
    if [ -f "${WORKTREE_DIR}/.agent-data/review-ledger.json" ]; then
        AGENT_REVIEW_LEDGER=$(cat "${WORKTREE_DIR}/.agent-data/review-ledger.json")
    fi

    local prompt
    prompt=$(load_prompt "cleanup" "$AGENT_PROMPT_CLEANUP")

    local result
    result=$(run_claude "$prompt" "$AGENT_ALLOWED_TOOLS_CLEANUP" "$AGENT_MODEL_CLEANUP")
    local claude_output
    claude_output=$(parse_claude_output "$result")
    log "Cleanup output: ${claude_output:0:500}"

    # Follow-up issues from the session's structured output
    local json_block fu_count i=0
    json_block=$(_extract_review_json "$claude_output")
    set +e
    fu_count=$(printf '%s' "$json_block" | jq -r '(.follow_up_issues // []) | length' 2>/dev/null)
    set -e
    [ -z "$fu_count" ] && fu_count=0
    while [ "$i" -lt "$fu_count" ]; do
        local fu_title fu_body
        fu_title=$(printf '%s' "$json_block" | jq -r ".follow_up_issues[$i].title")
        fu_body=$(printf '%s' "$json_block" | jq -r ".follow_up_issues[$i].body")
        gh issue create --repo "$REPO" --title "$fu_title" --body "${fu_body}

---
_Filed automatically by the post-merge cleanup of PR #${pr_number}._" 2>/dev/null \
            || log "WARN: follow-up issue creation failed: $fu_title"
        i=$((i + 1))
    done

    # Push doc commits directly to main; fall back to a chore PR on failure
    local commit_count
    commit_count=$(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..HEAD" 2>/dev/null || echo "0")
    if [ "$commit_count" -gt 0 ]; then
        if ! git -C "$WORKTREE_DIR" push origin "HEAD:main" 2>/dev/null; then
            log "Direct push to main failed; opening a chore PR instead"
            git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null || true
            gh pr create --repo "$REPO" --head "$BRANCH_NAME" \
                --title "chore: post-merge cleanup for PR #${pr_number}" \
                --body "Tracking-doc updates from the automated post-merge cleanup of PR #${pr_number}." 2>/dev/null || true
        fi
    fi

    # Strip agent labels from the closed issue
    if [ -n "$issue_num" ]; then
        (NUMBER="$issue_num"; remove_all_agent_labels) || true
    fi

    notify "cleanup_done" "$pr_title" "https://github.com/${REPO}/pull/${pr_number}" \
        "Post-merge cleanup complete (${commit_count} doc commit(s), ${fu_count} follow-up issue(s))"
    cleanup_worktree
}
```

Add the case arm before `*)`:

```bash
    post_merge)
        handle_post_merge
        ;;
```

- [ ] **Step 5: Create `prompts/cleanup.md`**

```markdown
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
```

- [ ] **Step 6: Create the reusable workflow `.github/workflows/sandbox-pal-post-merge.yml`**

```yaml
name: "Agent Dispatch: Post-Merge Cleanup"

on:
  workflow_call:
    inputs:
      bot_user:
        description: 'Bot account username (for self-trigger prevention)'
        required: true
        type: string
      pr_number:
        description: 'PR number override (for repository_dispatch triggers)'
        required: false
        type: string
        default: ''
      dispatch_script:
        description: 'Path to sandbox-pal-dispatch.sh on the runner'
        required: false
        type: string
        default: '~/agent-infra/scripts/sandbox-pal-dispatch.sh'
      config_path:
        description: 'Path to config.env on the runner'
        required: false
        type: string
        default: '~/agent-infra/config.env'
      timeout_minutes:
        description: 'Job timeout in minutes'
        required: false
        type: number
        default: 30
      runner_labels:
        description: 'JSON array of runner labels'
        required: false
        type: string
        default: '["self-hosted", "agent"]'
    secrets:
      agent_pat:
        description: 'Fine-grained PAT for the bot account'
        required: true

concurrency:
  group: sandbox-pal-post-merge-${{ inputs.pr_number || github.event.pull_request.number }}
  cancel-in-progress: false

jobs:
  post-merge-cleanup:
    runs-on: ${{ fromJSON(inputs.runner_labels) }}
    timeout-minutes: ${{ inputs.timeout_minutes }}
    permissions:
      contents: write
      issues: write
      pull-requests: write
    steps:
      - name: Run agent dispatch (post-merge)
        env:
          GH_TOKEN: ${{ secrets.agent_pat }}
          GITHUB_TOKEN: ${{ secrets.agent_pat }}
          AGENT_CONFIG: ${{ inputs.config_path }}
        run: |
          ${{ inputs.dispatch_script }} \
            post_merge \
            "${{ github.repository }}" \
            "${{ inputs.pr_number || github.event.pull_request.number }}"
```

- [ ] **Step 7: Create the caller templates**

`.claude/skills/setup/templates/caller-post-merge.yml`:

```yaml
name: "Claude Agent: Post-Merge Cleanup"

on:
  pull_request:
    types: [closed]

jobs:
  post-merge-cleanup:
    if: >-
      github.event.pull_request.merged == true &&
      github.event.pull_request.user.login == '{{BOT_USER}}'
    uses: jnurre64/sandbox-pal-action/.github/workflows/sandbox-pal-post-merge.yml@v1
    with:
      bot_user: "{{BOT_USER}}"
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      agent_pat: ${{ secrets.AGENT_PAT }}
```

`.claude/skills/setup/templates/standalone/sandbox-pal-post-merge.yml`:

```yaml
name: "Claude Agent: Post-Merge Cleanup"

on:
  pull_request:
    types: [closed]

concurrency:
  group: sandbox-pal-post-merge-${{ github.event.pull_request.number }}
  cancel-in-progress: false

jobs:
  post-merge-cleanup:
    if: >-
      github.event.pull_request.merged == true &&
      github.event.pull_request.user.login == '{{BOT_USER}}'
    runs-on: [self-hosted, agent]
    timeout-minutes: 30
    permissions:
      contents: write
      issues: write
      pull-requests: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Run agent dispatch
        env:
          GH_TOKEN: ${{ secrets.AGENT_PAT }}
          GITHUB_TOKEN: ${{ secrets.AGENT_PAT }}
          AGENT_CONFIG: ${{ github.workspace }}/.sandbox-pal-dispatch/config.env  # override file (gitignored, optional)
        run: |
          .sandbox-pal-dispatch/scripts/sandbox-pal-dispatch.sh \
            post_merge \
            "${{ github.repository }}" \
            "${{ github.event.pull_request.number }}"
```

Note the trigger condition uses `pull_request.user.login == bot` (agent PRs are always bot-created), NOT `github.actor != bot` — the merger is a human, and non-agent PRs must not trigger cleanup.

- [ ] **Step 8: Verify green**

Run: `bash -n scripts/sandbox-pal-dispatch.sh && ./tests/bats/bin/bats tests/test_dispatch_post_merge.bats && ./tests/bats/bin/bats tests/`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add scripts/sandbox-pal-dispatch.sh scripts/lib/defaults.sh prompts/cleanup.md \
        .github/workflows/sandbox-pal-post-merge.yml \
        .claude/skills/setup/templates/caller-post-merge.yml \
        .claude/skills/setup/templates/standalone/sandbox-pal-post-merge.yml \
        tests/test_dispatch_post_merge.bats
git commit -m "feat: post_merge event — merge-triggered cleanup phase"
```

---

### Task 8: Fallback skills

**Files:**
- Create: `skills/sp-implement/SKILL.md`, `skills/sp-review/SKILL.md`, `skills/sp-revise/SKILL.md`, `skills/sp-cleanup/SKILL.md`

**Interfaces:**
- Consumes: the same `prompts/*.md` files the dispatch uses; GitHub state via `gh`.
- Produces: interactive one-command phase runners. No bats tests (markdown); verification is the checklist in Step 2.

These are the headless-gating insurance and the manual-recovery path. Each skill is self-contained and follows the same 4-part shape: resolve the sandbox-pal install, gather the phase context, execute the phase prompt inline, perform the label transition.

- [ ] **Step 1: Write the four skills**

`skills/sp-implement/SKILL.md`:

```markdown
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
```

`skills/sp-review/SKILL.md`:

```markdown
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
- Merge your verdict into the ledger exactly as the loop does: bump `cycles`; mark `verified_fixed` ids fixed; append new findings as `F<next>` with status `open`; re-open `reopened` ids. Commit only the ledger file: `git add -f .agent-data/review-ledger.json && git commit -m "chore(agent): review ledger — interactive review pass"` and push.
- **No open blocking findings** → report "review clean" with the ledger summary; the PR is ready for the human gate.
- **Open blocking findings** → tell the user to run `/sp-revise <PR>` in a fresh session (that skill runs the fix pass against the ledger), or fix here only if the user explicitly waives fresh-context discipline.
```

`skills/sp-revise/SKILL.md`:

```markdown
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
```

`skills/sp-cleanup/SKILL.md`:

```markdown
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
```

- [ ] **Step 2: Verify**

- `ls skills/*/SKILL.md` shows the four files.
- Each frontmatter has `name`, `description`, `argument-hint`, `user-invocable: true`.
- Grep check that no skill embeds a copy of a phase prompt (they must READ `prompts/*.md`, not duplicate it): `grep -L "prompts/" skills/*/SKILL.md` → empty output.

- [ ] **Step 3: Commit**

```bash
git add skills/
git commit -m "feat: interactive fallback skills (sp-implement/sp-review/sp-revise/sp-cleanup)"
```

---

### Task 9: Config example + docs sync

**Files:**
- Modify: `config.defaults.env.example`, `docs/architecture.md`, `docs/configuration.md`, `docs/getting-started.md`, `CONTRIBUTING.md`, `README.md`

- [ ] **Step 1: `config.defaults.env.example`**

- Update the commented `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` line (line ~70) to show `:-3` and the new meaning (fix sessions in the review loop; 0 = single pass, unresolved → `agent:review-unresolved` PR).
- Add below the post-impl block:

```bash
# ─── Post-merge cleanup phase ─────────────────────────────────────
# Runs after an agent PR merges: tracking-doc updates, follow-up issues
# from the review ledger, merged-branch deletion.
# AGENT_CLEANUP_ENABLED="${AGENT_CLEANUP_ENABLED:-true}"
# AGENT_PROMPT_CLEANUP="${AGENT_PROMPT_CLEANUP:-/path/to/your/cleanup.md}"
# AGENT_MODEL_CLEANUP="${AGENT_MODEL_CLEANUP:-}"   # cheap model recommended
# AGENT_ALLOWED_TOOLS_CLEANUP="${AGENT_ALLOWED_TOOLS_CLEANUP:-}"  # see defaults.sh
```

- In the per-phase model comment block (lines ~85-89), add `# AGENT_MODEL_CLEANUP=...` alongside the others.

- [ ] **Step 2: `docs/architecture.md`**

- Trigger table (line ~96): add a row: `| pull_request.closed | merged agent PR | sandbox-pal-post-merge.yml | PR merged, PR author == your-bot |`
- Label list/state machine section: add `agent:review-unresolved` (cap-hit annotation label, applied IN ADDITION to `agent:pr-open`) and the `post_merge` event.
- Review-gates description: replace the single-retry Gate B description with the capped ledger loop (review → fix → re-review, cap `AGENT_POST_IMPL_REVIEW_MAX_RETRIES`, ledger at `.agent-data/review-ledger.json` committed to the branch).

- [ ] **Step 3: `docs/configuration.md`**

In the review-gates/config-reference section, document: new retry default 3 + new semantics, `AGENT_CLEANUP_ENABLED`, `AGENT_MODEL_CLEANUP`, `AGENT_PROMPT_CLEANUP`, `AGENT_ALLOWED_TOOLS_CLEANUP`, and the caller snippet for post-merge (copy the `caller-post-merge.yml` content from Task 7 as the example).

- [ ] **Step 4: `docs/getting-started.md`, `CONTRIBUTING.md`, `README.md`**

- getting-started line ~152: "just 5 small workflow YAMLs" → "just 6 small workflow YAMLs".
- CONTRIBUTING test-file table: add `tests/test_dispatch_post_merge.bats | Post-merge cleanup event: config gate, merged/author guards`.
- README: in "How It Works", renumber/extend: step 5 becomes the review loop ("An independent adversarial review loop (fresh session per pass, capped) gates PR creation; unresolved findings surface as `agent:review-unresolved`"), add a step for post-merge cleanup, and extend the label state machine diagram with `agent:pr-open ──merge──> post-merge cleanup` and the `agent:review-unresolved` annotation. Add an "Interactive on-ramp" paragraph: a plan authored interactively and posted with `<!-- agent-plan -->` + `<!-- agent-branch: ... -->` markers enters the machine at `agent:plan-approved`, and the implement phase builds on the pre-pushed branch. Mention the `skills/` fallback runners in Features.

- [ ] **Step 5: Verify + commit**

Run: `./tests/bats/bin/bats tests/test_portability.bats` (docs-adjacent greps live here; fix any assertions that pin the old workflow count).

```bash
git add config.defaults.env.example docs/architecture.md docs/configuration.md docs/getting-started.md CONTRIBUTING.md README.md
git commit -m "docs: interactive pipeline — review loop, post-merge cleanup, fallback skills"
```

---

### Task 10: work-issue v2 (user-global skill)

**Files:**
- Create: `~/.claude/skills/work-issue/SKILL.md` (copy of `~/repos/Webber/.claude/skills/work-issue/SKILL.md` with the edits below)

**Interfaces:**
- Consumes: the plan-comment contract from Task 6 (`<!-- agent-plan -->` + `<!-- agent-branch: ... -->`), the actor-guard fact (workflows filter only the BOT account).
- Produces: an armed pipeline instead of a paste-me handoff.

- [ ] **Step 1: Copy the current skill**

```bash
mkdir -p ~/.claude/skills/work-issue
cp ~/repos/Webber/.claude/skills/work-issue/SKILL.md ~/.claude/skills/work-issue/SKILL.md
```

- [ ] **Step 2: Apply the v2 edits**

1. Frontmatter `description`: replace with: `Fetch a GitHub issue, create a feature branch, investigate, brainstorm the approach with the user, write a comprehensive implementation plan, then ARM the sandbox-pal pipeline: post the plan to the issue and apply agent:plan-approved so the headless machine implements, adversarially reviews, and opens the PR. Use when the user wants to start work on a specific GitHub issue.`

2. Intro paragraph (line 10-12): replace the second paragraph ("**This skill ENDS at the handoff prompt.**...") with:

```markdown
**This skill ENDS at pipeline arming.** Implementation, the adversarial review loop, PR creation, and revision cycles run headlessly via the sandbox-pal-action label machine on the project's runners. The next human touchpoint after arming is the "PR ready for playtest" notification. The plan must be self-sufficient: the implement session starts cold, reading only the issue, the plan comment, and the branch.
```

3. Replace all of **Step 8 (Generate the Handoff Prompt)** with:

```markdown
### 8. Arm the Pipeline

The plan and spec are committed and pushed (step 7). Now hand the branch to the machine.

1. **Verify identity.** `gh api user --jq .login` must NOT be the repo's agent bot account (the dispatch workflows filter the bot's own label events — a bot-applied label triggers nothing). The bot username is `AGENT_BOT_USER` in the runner config (`~/agent-infra/config.env` when readable; for Frightful-Games repos it is `strongbad-bot`). If the current identity IS the bot: print the exact label command below for the user to run themselves, and stop after step 3.

2. **Post the plan comment.** One comment on the issue, containing in order:
   - `<!-- agent-plan -->` on its own line
   - `<!-- agent-branch: feature/<N>-<short-description> -->` on its own line (the exact branch pushed in step 7)
   - The full implementation plan content
   - A section `## Context the plan does not repeat` — 3-5 bullets of non-obvious investigation findings (exact file:line pointers)
   - A section `## Open questions / risks` — anything discussed but unresolved; the implement session should surface these rather than guess

3. **Final approval.** Show the user the comment URL and ask: "Arm the pipeline? (applies `agent:plan-approved` — implementation starts immediately on the runner)". Do not proceed without an explicit yes.

4. **Arm.** `gh issue edit <N> --repo <owner/repo> --add-label "agent:plan-approved"`

5. **Confirm:** "Pipeline armed — the machine will implement (Opus), run the adversarial review loop (Fable), and open a PR. Next ping: PR ready for playtest. Fallback if the runner is down: `/sp-implement <N>` in a fresh session."
```

4. Replace **Step 9** heading/body with:

```markdown
### 9. (Optional) Update Next_Tasks.md

If the project tracks tasks (e.g., `claude-work/Next_Tasks.md`) and this issue isn't listed, add a one-line entry referencing the branch and plan, commit and push it on the feature branch BEFORE arming (step 8), so the implement session sees it.
```

5. In **Notes**: replace the bullet `**The next session has zero memory of our conversation.** ...` with `**The implement session has zero memory of this conversation.** If something matters, it goes in the plan or the plan comment's context/risks sections.` Delete the Lessons Learned bullets? NO — keep the whole Lessons Learned section verbatim (it still applies to steps 1-7).

6. Step 6's closing line ("When writing-plans offers the execution choice... note the options in the handoff prompt below.") → replace with: `When writing-plans offers the execution choice (subagent-driven vs inline), decline both — execution belongs to the headless implement phase. The plan header's "For agentic workers" line already directs the executor.`

- [ ] **Step 3: Verify**

- `grep -c "agent-branch" ~/.claude/skills/work-issue/SKILL.md` ≥ 1
- `grep -c "handoff prompt" ~/.claude/skills/work-issue/SKILL.md` returns 0 matches in steps 8-9 (the phrase may legitimately survive in Lessons Learned history).
- Read the full file top to bottom once: steps 1-7 intact, 8-9 replaced, no dangling references to the handoff template.

(No git commit — `~/.claude` is not a repo. Note for Pompom portability: this file is part of the `~/.claude/skills/` sync set.)

---

### Task 11: Remove the Webber project-level copy (small separate PR)

**Files:**
- Delete: `~/repos/Webber/.claude/skills/work-issue/SKILL.md` (in the Webber repo)

The project-level skill would shadow the new global v2 in Webber sessions. Small functional PR (this is not a docs-handoff PR; the no-standalone-docs-PR rule doesn't apply, but flag it to the user before opening).

- [ ] **Step 1: Branch, delete, push, PR**

```bash
cd ~/repos/Webber
git checkout main && git pull origin main
git checkout -b chore/work-issue-v2-global
git rm -r .claude/skills/work-issue
git commit -m "chore: retire project work-issue skill (superseded by global v2 pipeline on-ramp)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin chore/work-issue-v2-global
gh pr create --title "chore: retire project work-issue skill (global v2 supersedes)" \
  --body "The work-issue skill moved to ~/.claude/skills/ as the sandbox-pal pipeline on-ramp (v2). The project copy would shadow it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 2: Tell the user** the PR exists and merges whenever convenient (Webber sessions keep working either way — v1 until merge, v2 after).

---

### Task 12: Final verification + push + deployment notes

- [ ] **Step 1: Full suite + lint**

```bash
cd ~/repos/sandbox-pal-action
bash -n scripts/sandbox-pal-dispatch.sh scripts/lib/*.sh
./tests/bats/bin/bats tests/
```

Expected: every suite passes. Read the full output — no skips you didn't expect.

- [ ] **Step 2: Push and open the PR**

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token) git push -u origin feature/interactive-pipeline
GH_TOKEN=$(cat ~/.config/gh-tokens/claude-pal-token) gh pr create --repo jnurre64/sandbox-pal-action \
  --title "Interactive pipeline: plan on-ramp, capped review loop, post-merge cleanup, fallback skills" \
  --body "Implements docs/superpowers/specs/2026-08-01-interactive-pipeline-design.md.

- Ledger-driven adversarial review loop (cap = AGENT_POST_IMPL_REVIEW_MAX_RETRIES, default 3); cap-hit PRs open as agent:review-unresolved
- <!-- agent-branch --> marker: interactively-planned issues implement on their pre-pushed feature branch
- post_merge event + cleanup phase (tracking docs, ledger follow-up issues, branch deletion)
- skills/: sp-implement, sp-review, sp-revise, sp-cleanup — interactive fallback runners sharing the same prompts

Test evidence: full BATS suite green (tests/test_review_gates.bats, tests/test_common.bats, tests/test_dispatch_post_merge.bats, tests/test_notify.bats, tests/test_defaults.bats + existing suites).

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 3: Deployment notes (post-merge, for the user — do not execute)**

Post as a PR comment so it isn't lost:
- Runner update: pull the new scripts to `~/agent-infra` (the repo's update procedure, `scripts/update.sh`).
- Consuming repos (Webber): add the new caller workflow (`agent-post-merge.yml` from the template) — note memory: agent workflows in Webber's `.github/workflows/` must be added by the human, agents never modify workflow files.
- Run `scripts/create-labels.sh <owner/repo>` to create `agent:review-unresolved` on each consuming repo.
- Set per-phase models in `~/agent-infra/config.env`: `AGENT_MODEL_IMPLEMENT=claude-opus-5`, `AGENT_MODEL_POST_IMPL_REVIEW=claude-fable-5`, `AGENT_MODEL_POST_IMPL_RETRY=claude-fable-5`, `AGENT_MODEL_REVIEW=claude-fable-5`, `AGENT_MODEL_CLEANUP=claude-haiku-4-5-20251001`.
- Optionally install the fallback skills globally: copy `skills/sp-*` to `~/.claude/skills/` (and to Pompom alongside `work-issue`).
