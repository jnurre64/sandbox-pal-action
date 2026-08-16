# Preserve Work on Test-Gate Failure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Never lose finished implementation work when a pre-PR gate fails — push the branch before any gate can fail, and give test-gate failures a bounded self-heal loop.

**Architecture:** A new `preserve_branch()` helper (best-effort push) is called as soon as commits exist in `handle_post_implementation`, and again from every controlled-failure path that can add commits. The inline pre-PR test gate in `scripts/lib/common.sh` moves to a new `run_test_gate()` in `scripts/lib/review-gates.sh` that wraps it in a bounded Claude fix loop (`AGENT_TEST_GATE_MAX_RETRIES`, default 2) mirroring the existing review-retry machinery. No changes to `setup_worktree` are needed: it already checks out `origin/$BRANCH_NAME` when the remote branch exists, so a preserved branch turns re-dispatch into a resume instead of a restart.

**Tech Stack:** Bash (`set -euo pipefail`, shellcheck-clean), BATS-Core tests, `gh` CLI, `claude -p` headless sessions.

**Spec:** Issue [jnurre64/sandbox-pal-action#73](https://github.com/jnurre64/sandbox-pal-action/issues/73). Design approved interactively 2026-08-16 (option: "push + test-fix retry"); design summary is in the plan comment on the issue. No separate spec file.

## Global Constraints

- All shell scripts must pass `shellcheck` with zero warnings (`shellcheck scripts/*.sh scripts/lib/*.sh`).
- All scripts use `set -euo pipefail`; any command that may fail inside a gate must be wrapped in `set +e` / `set -e` or `|| true`.
- Tests are BATS-Core: run `./tests/bats/bin/bats tests/` (or a single file: `./tests/bats/bin/bats tests/test_review_gates.bats`).
- Bug-fix tests use the `REGRESSION issue-73:` prefix in the test name.
- Issue/PR content is passed to prompts via environment variables, never shell-interpolated.
- `run_test_gate()` must contain NO column-0 `}` before its real closing brace — its regression tests extract the body with `sed -n '/^run_test_gate()/,/^}/p'`.
- Commit messages follow the existing conventional style (`feat:`, `fix:`, `test:`, `docs:`) and reference `#73`.

## Context the executor must know (from investigation)

- The loss chain: test-gate failure in `handle_post_implementation` (`scripts/lib/common.sh:259-274`) sets `agent:failed` and returns 1 **without pushing**; `handle_implement` (`scripts/sandbox-pal-dispatch.sh:467`) then runs `cleanup_worktree`; on re-dispatch `setup_worktree` (`scripts/lib/worktree.sh:26`) runs `git branch -D "$BRANCH_NAME"` and recreates from `origin/main`. Work gone.
- Two more loss paths: Gate B parse failure (`scripts/lib/review-gates.sh:282-289` — its comment tells the user to "check the branch", which was never pushed) and the review-retry test failure (`scripts/lib/review-gates.sh:328-342`).
- `setup_worktree` already resumes from `origin/$BRANCH_NAME` when it exists (`scripts/lib/worktree.sh:32-33`) — pushing is sufficient to make re-dispatch resume.
- The FingerWizard failure that motivated #73 was a *config-broken* test command (referenced a not-yet-installed addon). No in-repo fix can cure that, which is why the fix loop breaks early when a fix session makes no commits.
- The success-path push at `scripts/lib/common.sh:294` stays strict (unguarded under `set -e`) — the final push must succeed for PR creation.

---

### Task 1: `preserve_branch()` helper in common.sh

**Files:**
- Modify: `scripts/lib/common.sh` (add function after `parse_claude_output`, before `handle_post_implementation`; also add `preserve_branch` to the `# Provides:` header comment on line 2-6)
- Test: `tests/test_common.bats`

**Interfaces:**
- Produces: `preserve_branch()` — no args; reads globals `WORKTREE_DIR`, `BRANCH_NAME`; best-effort `git push -u origin "$BRANCH_NAME"`; returns 0 on pushed, 1 on failure (after logging a WARN). Callers always invoke as `preserve_branch || true`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_common.bats` (a new section after the `parse_claude_output` tests):

```bash
# ═══════════════════════════════════════════════════════════════
# preserve_branch — issue #73
# ═══════════════════════════════════════════════════════════════

@test "REGRESSION issue-73: preserve_branch pushes the work branch" {
    _source_common
    git() { echo "git $*" >> "${TEST_TEMP_DIR}/git_calls"; return 0; }
    run preserve_branch
    assert_success
    run cat "${TEST_TEMP_DIR}/git_calls"
    assert_output --partial "push -u origin agent/issue-99"
}

@test "REGRESSION issue-73: preserve_branch push failure warns and returns 1" {
    _source_common
    git() { return 1; }
    run preserve_branch
    assert_failure
    assert_output --partial "WARN: could not push"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_common.bats --filter "preserve_branch"`
Expected: both FAIL (`preserve_branch: command not found`).

- [ ] **Step 3: Implement**

In `scripts/lib/common.sh`, after the `parse_claude_output` function and before the `handle_post_implementation` section comment, add:

```bash
# ─── Preserve implementation work on the remote ──────────────────
# Best-effort push of the work branch so a controlled failure never
# strands finished commits in a worktree that the next dispatch's
# setup_worktree will delete (issue #73). setup_worktree checks out
# origin/$BRANCH_NAME when it exists, so a preserved branch turns a
# re-dispatch into a resume instead of a restart.
preserve_branch() {
    if git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null; then
        log "Preserved work branch: pushed ${BRANCH_NAME} to origin"
        return 0
    fi
    log "WARN: could not push ${BRANCH_NAME} to origin — commits remain only in the local worktree"
    return 1
}
```

Also add `preserve_branch` to the `# Provides:` comment at the top of the file.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_common.bats --filter "preserve_branch"`
Expected: 2 tests PASS.

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck scripts/lib/common.sh`
Expected: no output.

```bash
git add scripts/lib/common.sh tests/test_common.bats
git commit -m "feat(#73): preserve_branch helper — best-effort push of the work branch"
```

---

### Task 2: Config vars for the test-gate fix loop

**Files:**
- Modify: `scripts/lib/defaults.sh` (after the `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` block at line 64, and in the model block after `AGENT_MODEL_POST_IMPL_RETRY` at line 90)
- Modify: `tests/helpers/test_helper.bash` (add exports next to the existing `AGENT_POST_IMPL_*` exports at lines 58-61 and model exports at lines 62-68)
- Modify: `config.defaults.env.example` (commented entries next to the post-impl-review block, lines 67-102)
- Test: `tests/test_defaults.bats`

**Interfaces:**
- Produces: `AGENT_TEST_GATE_MAX_RETRIES` (default `2`), `AGENT_PROMPT_TEST_FIX` (default empty), `AGENT_MODEL_TEST_FIX` (default empty). Task 4 consumes all three.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_defaults.bats`:

```bash
# ─── REGRESSION: issue-73 — test gate fix loop config ───────────

@test "REGRESSION issue-73: AGENT_TEST_GATE_MAX_RETRIES defaults to 2" {
    export AGENT_BOT_USER="test-bot"
    source "${LIB_DIR}/defaults.sh"
    assert_equal "$AGENT_TEST_GATE_MAX_RETRIES" "2"
}

@test "REGRESSION issue-73: AGENT_PROMPT_TEST_FIX and AGENT_MODEL_TEST_FIX default to empty" {
    export AGENT_BOT_USER="test-bot"
    source "${LIB_DIR}/defaults.sh"
    assert_equal "$AGENT_PROMPT_TEST_FIX" ""
    assert_equal "$AGENT_MODEL_TEST_FIX" ""
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_defaults.bats --filter "issue-73"`
Expected: FAIL (unbound/empty variables — `assert_equal` mismatch on `AGENT_TEST_GATE_MAX_RETRIES`).

- [ ] **Step 3: Implement**

In `scripts/lib/defaults.sh`, directly after the `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` line (64), add:

```bash
# Max Claude fix sessions when the pre-PR test gate fails
# (0 = fail immediately; the work branch is pushed either way — issue #73)
AGENT_TEST_GATE_MAX_RETRIES="${AGENT_TEST_GATE_MAX_RETRIES:-2}"
```

After the `AGENT_PROMPT_POST_IMPL_RETRY` line (69), add:

```bash
AGENT_PROMPT_TEST_FIX="${AGENT_PROMPT_TEST_FIX:-}"
```

After the `AGENT_MODEL_POST_IMPL_RETRY` line (90), add:

```bash
AGENT_MODEL_TEST_FIX="${AGENT_MODEL_TEST_FIX:-}"  # pre-PR test-gate fix sessions
```

In `tests/helpers/test_helper.bash`, after `export AGENT_POST_IMPL_REVIEW_MAX_RETRIES="1"` (line 58) add:

```bash
    export AGENT_TEST_GATE_MAX_RETRIES="2"
```

After `export AGENT_PROMPT_POST_IMPL_RETRY=""` (line 61) add:

```bash
    export AGENT_PROMPT_TEST_FIX=""
```

After `export AGENT_MODEL_POST_IMPL_RETRY=""` (line 68) add:

```bash
    export AGENT_MODEL_TEST_FIX=""
```

In `config.defaults.env.example`, after the `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` entry (line 75), add:

```bash
# Max Claude fix sessions when the pre-PR test gate fails (0 = no fix
# sessions; the work branch is pushed either way, so nothing is lost)
# AGENT_TEST_GATE_MAX_RETRIES="${AGENT_TEST_GATE_MAX_RETRIES:-2}"
```

After the `AGENT_PROMPT_POST_IMPL_RETRY` entry (line 80), add:

```bash
# AGENT_PROMPT_TEST_FIX="${AGENT_PROMPT_TEST_FIX:-/path/to/your/test-fix.md}"
```

After the `AGENT_MODEL_POST_IMPL_RETRY` entry (line 102), add:

```bash
# AGENT_MODEL_TEST_FIX="${AGENT_MODEL_TEST_FIX:-}"   # pre-PR test-gate fix sessions
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_defaults.bats && ./tests/bats/bin/bats tests/test_config_vars.bats`
Expected: all PASS (config-vars parser tests must still pass against the example file).

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck scripts/lib/defaults.sh`
Expected: no output.

```bash
git add scripts/lib/defaults.sh tests/helpers/test_helper.bash config.defaults.env.example tests/test_defaults.bats
git commit -m "feat(#73): AGENT_TEST_GATE_MAX_RETRIES + test-fix prompt/model config"
```

---

### Task 3: `prompts/test-fix.md`

**Files:**
- Create: `prompts/test-fix.md`
- Modify: `prompts/CLAUDE.md` (add a row to the prompt-to-phase table)
- Test: `tests/test_common.bats` (`load_prompt` fallback section, near the existing `post-impl-retry` fallback test around line 515)

**Interfaces:**
- Produces: built-in prompt loadable as `load_prompt "test-fix" "$AGENT_PROMPT_TEST_FIX"`. Consumed by Task 4. The prompt instructs: make NO commits if the failure is unfixable from inside the repo — Task 4's no-commit early break relies on that instruction.

- [ ] **Step 1: Write the failing test**

In `tests/test_common.bats`, next to the existing `load_prompt: post-impl-retry falls back to built-in prompt` test, add:

```bash
@test "load_prompt: test-fix falls back to built-in prompt" {
    _source_common
    run load_prompt "test-fix" ""
    assert_success
    assert_output --partial "pre-PR test gate failed"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/bats/bin/bats tests/test_common.bats --filter "test-fix"`
Expected: FAIL (`No prompt found for 'test-fix'`).

- [ ] **Step 3: Create the prompt**

Create `prompts/test-fix.md` with exactly this content:

```markdown
You are fixing a failing test suite so an already-completed implementation can ship.

An implementation for a GitHub issue was completed and committed on this branch, but the pre-PR test gate failed. Your job is to get the test suite green with the smallest change that preserves the implementation's intent.

## Issue Context
Read the issue details from environment variables:
- Run: echo "$AGENT_ISSUE_TITLE" for the title
- Run: echo "$AGENT_ISSUE_BODY" for the description

## Approved Plan
Read the plan that guided the implementation:
- Run: echo "$AGENT_PLAN_CONTENT"

## Test Failure
- Run: echo "$AGENT_TEST_OUTPUT" for the failing output (last 100 lines)
- Run: echo "$AGENT_TEST_EXIT_CODE" for the exit code
- The gate command is: $AGENT_TEST_COMMAND

## Instructions

### Step 1: Read Project Context
Read the CLAUDE.md file for project conventions and how to run tests.

### Step 2: Understand the Failure
- Run: git log --format="- %h %s" origin/main..HEAD -- to see what the implementation changed
- Reproduce the failure by running the gate command: $AGENT_TEST_COMMAND
- Diagnose the root cause before changing anything.

### Step 3: Fix
- Prefer the smallest fix: a missing import, an un-updated assertion, a fixture that needs the new behavior.
- Fix the code when the implementation is wrong; fix the test when the test encodes old behavior the issue asked to change.
- Do NOT delete, skip, or weaken tests just to get to green.
- Do NOT revert the implementation.

### Step 4: Verify and Commit
- Re-run the gate command until it exits 0: $AGENT_TEST_COMMAND
- Commit with the message format: `fix(tests): <what was fixed>`
- If the failure cannot be fixed from inside the repository (for example, the gate command references tools, addons, or files that do not exist in this checkout), make NO commits and explain why in your final output. The dispatch script detects a no-commit session and stops retrying.

## Important Rules
- Make only the changes needed to get the gate green.
- Every commit MUST use the `fix(tests):` prefix.
- Do NOT modify .github/workflows/ files.
- Do NOT commit files in .agent-data/ or files containing secrets.

## Final Output
Output a short plain-text summary of what you changed and why — or why the failure is not fixable from this repository.
```

In `prompts/CLAUDE.md`, add to the prompt-to-phase table after the `post-impl-retry.md` row:

```markdown
| `test-fix.md` | `implement` (test gate retry) | Read-write | Fix a failing pre-PR test gate without reverting the implementation |
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/bats/bin/bats tests/test_common.bats --filter "test-fix"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add prompts/test-fix.md prompts/CLAUDE.md tests/test_common.bats
git commit -m "feat(#73): built-in test-fix prompt for the gate fix loop"
```

---

### Task 4: `run_test_gate()` in review-gates.sh

**Files:**
- Modify: `scripts/lib/review-gates.sh` (add function after `run_adversarial_plan_review`, before the Gate B section; add `run_test_gate` to the `# Provides:` header on line 3)
- Test: `tests/test_review_gates.bats`

**Interfaces:**
- Consumes: `preserve_branch` (Task 1), `AGENT_TEST_GATE_MAX_RETRIES` / `AGENT_PROMPT_TEST_FIX` / `AGENT_MODEL_TEST_FIX` (Task 2), `prompts/test-fix.md` (Task 3), plus existing `log`, `load_prompt`, `run_claude`, `parse_claude_output`, `set_label`, `notify`, globals `WORKTREE_DIR`, `BRANCH_NAME`, `NUMBER`, `REPO`, `AGENT_TEST_COMMAND`, `AGENT_TEST_SETUP_COMMAND`.
- Produces: `run_test_gate <impl_tools> <issue_title>` — returns 0 when the gate passes or is disabled; returns 1 after the fix loop is exhausted (having pushed the branch, posted the failure comment, set `agent:failed`, and notified). Exports `AGENT_TEST_OUTPUT` and `AGENT_TEST_EXIT_CODE` for fix sessions. Task 5 consumes this signature.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_review_gates.bats`:

```bash
# ═══════════════════════════════════════════════════════════════
# run_test_gate — pre-PR test gate with bounded fix sessions (#73)
# ═══════════════════════════════════════════════════════════════

_setup_test_gate() {
    export WORKTREE_DIR="${TEST_TEMP_DIR}/wt"
    export BRANCH_NAME="agent/issue-99"
    mkdir -p "$WORKTREE_DIR"
    git -C "$WORKTREE_DIR" init -q
    git -C "$WORKTREE_DIR" config user.email "t@t" && git -C "$WORKTREE_DIR" config user.name "t"
    (cd "$WORKTREE_DIR" && echo base > base.txt && git add base.txt && git commit -qm "base")
    export AGENT_TEST_GATE_MAX_RETRIES="2"
    create_mock "gh" ""
    _source_review_gates
    notify() { :; }
    preserve_branch() { echo "preserve" >> "${TEST_TEMP_DIR}/preserve_calls"; return 0; }
}

@test "test gate: disabled when AGENT_TEST_COMMAND is empty" {
    _setup_test_gate
    export AGENT_TEST_COMMAND=""
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
}

@test "test gate: passing tests return 0 with no fix session" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="true"
    run_claude() { echo "session" >> "${TEST_TEMP_DIR}/claude_calls"; echo '{"result":"x"}'; }
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
    [ ! -f "${TEST_TEMP_DIR}/claude_calls" ]
}

@test "REGRESSION issue-73: fix session that heals the suite returns 0" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="test -f fixed.txt"
    run_claude() {
        echo "session" >> "${TEST_TEMP_DIR}/claude_calls"
        (cd "$WORKTREE_DIR" && echo ok > fixed.txt && git add fixed.txt && git commit -qm "fix(tests): create fixed.txt")
        echo '{"result":"fixed the suite"}'
    }
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
    [ "$(wc -l < "${TEST_TEMP_DIR}/claude_calls")" -eq 1 ]
}

@test "REGRESSION issue-73: no-commit fix session breaks the loop early" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="false"
    run_claude() { echo "session" >> "${TEST_TEMP_DIR}/claude_calls"; echo '{"result":"cannot fix: broken config"}'; }
    run run_test_gate "Read,Edit" "Test issue"
    assert_failure
    # cap is 2 but only ONE session ran — no commits means no point retrying
    [ "$(wc -l < "${TEST_TEMP_DIR}/claude_calls")" -eq 1 ]
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
}

@test "REGRESSION issue-73: cap reached after max fix sessions with commits" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="false"
    run_claude() {
        echo "session" >> "${TEST_TEMP_DIR}/claude_calls"
        (cd "$WORKTREE_DIR" && echo fix >> churn.txt && git add churn.txt && git commit -qm "fix(tests): attempt")
        echo '{"result":"tried a fix"}'
    }
    run run_test_gate "Read,Edit" "Test issue"
    assert_failure
    [ "$(wc -l < "${TEST_TEMP_DIR}/claude_calls")" -eq 2 ]
}

@test "REGRESSION issue-73: retries=0 fails immediately but still preserves the branch" {
    _setup_test_gate
    export AGENT_TEST_GATE_MAX_RETRIES="0"
    export AGENT_TEST_COMMAND="false"
    run_claude() { echo "session" >> "${TEST_TEMP_DIR}/claude_calls"; echo '{"result":"x"}'; }
    run run_test_gate "Read,Edit" "Test issue"
    assert_failure
    [ ! -f "${TEST_TEMP_DIR}/claude_calls" ]
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
}

@test "REGRESSION issue-73: failure comment names the preserved branch and sets agent:failed" {
    _setup_test_gate
    export AGENT_TEST_GATE_MAX_RETRIES="0"
    export AGENT_TEST_COMMAND="false"
    run run_test_gate "Read,Edit" "Test issue"
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent/issue-99"* ]]
    [[ "$calls" == *"agent:failed"* ]]
    [[ "$calls" == *"Test Failure (Pre-PR Gate)"* ]]
}

@test "REGRESSION issue-73: non-integer AGENT_TEST_GATE_MAX_RETRIES falls back to 2" {
    _setup_test_gate
    export AGENT_TEST_GATE_MAX_RETRIES="lots"
    export AGENT_TEST_COMMAND="true"
    run run_test_gate "Read,Edit" "Test issue"
    assert_success
    assert_output --partial "using 2"
}

@test "REGRESSION issue-73: test setup command runs before the test command" {
    local body setup_line test_line
    body=$(sed -n '/^run_test_gate()/,/^}/p' "${LIB_DIR}/review-gates.sh")
    setup_line=$(echo "$body" | grep -n 'AGENT_TEST_SETUP_COMMAND' | head -1 | cut -d: -f1)
    test_line=$(echo "$body" | grep -n 'eval "\$AGENT_TEST_COMMAND"' | head -1 | cut -d: -f1)
    [ -n "$setup_line" ] && [ -n "$test_line" ]
    [ "$setup_line" -lt "$test_line" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats --filter "test gate|issue-73"`
Expected: all FAIL (`run_test_gate: command not found` / empty sed extraction).

- [ ] **Step 3: Implement**

In `scripts/lib/review-gates.sh`, after `run_adversarial_plan_review` and before the Gate B section, add (and append `run_test_gate` to the `# Provides:` line 3):

```bash
# ─── Pre-PR test gate with bounded fix sessions ─────────────────
# Runs AGENT_TEST_COMMAND in the worktree. On failure, up to
# AGENT_TEST_GATE_MAX_RETRIES fresh Claude fix sessions are fed the
# failing output (AGENT_TEST_OUTPUT / AGENT_TEST_EXIT_CODE) and the
# tests are re-run after each. A fix session that produces no new
# commits ends the loop early: nothing changed, so re-running the same
# command would fail the same way (issue #73 — e.g. the test command
# itself is broken in repo config, which no in-repo fix can cure).
# On final failure the work branch is pushed (preserve_branch), the
# failure comment links it, agent:failed is set, and 1 is returned.
# Returns 0 when the gate passes or is disabled.
#
# NOTE: tests extract this function body with
# `sed -n '/^run_test_gate()/,/^}/p'` — keep any column-0 `}` out of
# the body before the function's real closing brace.
run_test_gate() {
    local impl_tools="$1"
    local issue_title="$2"

    if [ -z "$AGENT_TEST_COMMAND" ]; then
        return 0
    fi

    # Validate the cap like AGENT_POST_IMPL_REVIEW_MAX_RETRIES: a
    # non-integer would error the -ge comparison on every iteration.
    local max_retries="$AGENT_TEST_GATE_MAX_RETRIES"
    if ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
        log "WARN: AGENT_TEST_GATE_MAX_RETRIES='${max_retries}' is not a non-negative integer; using 2"
        max_retries=2
    fi

    local attempt=0 test_output test_exit stop_reason=""
    while true; do
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            log "Running test setup: $AGENT_TEST_SETUP_COMMAND"
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") 2>&1 || log "WARN: Test setup command exited with non-zero (continuing)"
        fi

        log "Running pre-PR test gate (attempt $((attempt + 1)))..."
        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e

        if [ "$test_exit" -eq 0 ]; then
            if [ "$attempt" -gt 0 ]; then
                log "Pre-PR test gate green after ${attempt} fix session(s)"
            fi
            return 0
        fi

        if [ "$attempt" -ge "$max_retries" ]; then
            stop_reason="fix-session cap (${max_retries}) reached"
            break
        fi

        attempt=$((attempt + 1))
        log "Pre-PR test gate failed (exit ${test_exit}); starting fix session ${attempt}/${max_retries}..."

        export AGENT_TEST_OUTPUT
        AGENT_TEST_OUTPUT=$(echo "$test_output" | tail -100)
        export AGENT_TEST_EXIT_CODE="$test_exit"

        local before_sha
        before_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")

        local prompt result
        prompt=$(load_prompt "test-fix" "${AGENT_PROMPT_TEST_FIX}")
        result=$(run_claude "$prompt" "$impl_tools" "$AGENT_MODEL_TEST_FIX")
        log "Test-fix session output: $(parse_claude_output "$result" | head -c 300)"

        local after_sha
        after_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || echo "")
        if [ "$after_sha" = "$before_sha" ]; then
            stop_reason="fix session ${attempt} made no commits (failure likely not fixable from inside the repo, e.g. a broken test command in config)"
            break
        fi
    done

    log "Pre-PR test gate FAILED: ${stop_reason}"
    preserve_branch || true
    gh issue comment "$NUMBER" --repo "$REPO" \
        --body "## Test Failure (Pre-PR Gate)

Tests failed after implementation (${stop_reason}). Setting \`agent:failed\`.

**Your work is safe:** the implementation commits are pushed to the \`${BRANCH_NAME}\` branch. Re-applying \`agent:plan-approved\` resumes from that branch instead of starting over.

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
    set_label "agent:failed"
    notify "tests_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR test gate failed after ${attempt} fix session(s)"
    return 1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats`
Expected: all PASS (new tests plus every pre-existing test in the file).

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck scripts/lib/review-gates.sh`
Expected: no output.

```bash
git add scripts/lib/review-gates.sh tests/test_review_gates.bats
git commit -m "feat(#73): run_test_gate — bounded fix sessions, branch preserved on failure"
```

---

### Task 5: Wire into handle_post_implementation

**Files:**
- Modify: `scripts/lib/common.sh:243-283` (`handle_post_implementation`: replace the inline gate with `preserve_branch` + `run_test_gate`)
- Modify: `tests/test_common.bats:170-181` (relocate the two `REGRESSION v1.0.3` gate tests to point at `run_test_gate` in review-gates.sh)
- Test: `tests/test_common.bats` (new functional tests in the `handle_post_implementation × review loop` section, which already provides `_setup_post_impl`)

**Interfaces:**
- Consumes: `preserve_branch()` (Task 1), `run_test_gate <impl_tools> <issue_title>` (Task 4).
- Produces: unchanged external behavior of `handle_post_implementation "$start_sha" "$issue_title" "$claude_output"` — except the branch is now pushed as soon as commits exist, and gate failures run the fix loop.

- [ ] **Step 1: Write the failing tests**

Append to the `handle_post_implementation × review loop` section of `tests/test_common.bats`:

```bash
@test "REGRESSION issue-73: work branch is preserved before the test gate runs" {
    _setup_post_impl
    preserve_branch() { echo "preserve" >> "${TEST_TEMP_DIR}/order"; return 0; }
    run_test_gate() { echo "gate" >> "${TEST_TEMP_DIR}/order"; return 0; }
    run_post_impl_review_loop() { _ledger_init; _ledger_merge_review '{"findings":[]}'; return 0; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_success
    run cat "${TEST_TEMP_DIR}/order"
    assert_line --index 0 "preserve"
    assert_line --index 1 "gate"
}

@test "REGRESSION issue-73: test gate failure halts before PR creation" {
    _setup_post_impl
    preserve_branch() { :; }
    run_test_gate() { return 1; }
    run handle_post_implementation "" "Test issue" "did the thing"
    assert_failure
    run get_mock_calls "gh"
    refute_output --partial "pr create"
}
```

Then update the two `REGRESSION v1.0.3` tests (lines 170-181) in place — the gate now lives in `run_test_gate` in review-gates.sh, so scope the greps to that function body:

```bash
@test "REGRESSION v1.0.3: test setup command present in the pre-PR test gate" {
    sed -n '/^run_test_gate()/,/^}/p' "${LIB_DIR}/review-gates.sh" | grep -q 'AGENT_TEST_SETUP_COMMAND'
}

@test "REGRESSION v1.0.3: test setup runs before test command in the gate source" {
    local body setup_line test_line
    body=$(sed -n '/^run_test_gate()/,/^}/p' "${LIB_DIR}/review-gates.sh")
    setup_line=$(echo "$body" | grep -n 'AGENT_TEST_SETUP_COMMAND' | head -1 | cut -d: -f1)
    test_line=$(echo "$body" | grep -n 'eval "\$AGENT_TEST_COMMAND"' | head -1 | cut -d: -f1)
    [ -n "$setup_line" ] && [ -n "$test_line" ]
    [ "$setup_line" -lt "$test_line" ]
}
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `./tests/bats/bin/bats tests/test_common.bats --filter "issue-73"`
Expected: the two new `issue-73` handle_post_implementation tests FAIL (preserve/gate never called — the inline gate is still in place). The relocated v1.0.3 tests already PASS (Task 4 created `run_test_gate`).

- [ ] **Step 3: Implement**

In `scripts/lib/common.sh`, `handle_post_implementation`: replace everything from `if [ "$commit_count" -gt 0 ]; then` (line 243) through the `notify "tests_passed" ...` line and the `local impl_tools review_rc=0` / `impl_tools=$(get_implementation_tools)` lines (through line 282) with:

```bash
    if [ "$commit_count" -gt 0 ]; then
        # Preserve finished work on the remote BEFORE any gate can fail.
        # A gate failure used to strand unpushed commits in a worktree
        # that the next dispatch's setup_worktree deletes (issue #73);
        # setup_worktree resumes from origin/$BRANCH_NAME when it exists.
        preserve_branch || true

        local impl_tools review_rc=0
        impl_tools=$(get_implementation_tools)

        # ── Pre-PR test gate (bounded fix sessions) ───────────────
        if ! run_test_gate "$impl_tools" "$issue_title"; then
            return 1
        fi

        notify "tests_passed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR tests passed ($commit_count commits)"

        # ── Post-implementation review loop (Gate B) ─────────────
        run_post_impl_review_loop "$impl_tools" || review_rc=$?
```

Everything after `run_post_impl_review_loop "$impl_tools" || review_rc=$?` (the `review_rc -eq 1` check, commit_count refresh, final push, PR creation, no-commits else-branch) stays exactly as it is.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_common.bats`
Expected: all PASS — including the pre-existing `post-impl:` functional tests and both relocated v1.0.3 tests.

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck scripts/lib/common.sh && ./tests/bats/bin/bats tests/test_set_e_guards.bats`
Expected: no shellcheck output; set-e guard tests PASS.

```bash
git add scripts/lib/common.sh tests/test_common.bats
git commit -m "feat(#73): push work branch before gates; gate runs via run_test_gate fix loop"
```

---

### Task 6: Preserve work in the two remaining loss paths

**Files:**
- Modify: `scripts/lib/review-gates.sh:282-289` (Gate B parse-failure case in `run_post_impl_review`)
- Modify: `scripts/lib/review-gates.sh:328-342` (test-failure path in `run_post_impl_retry_session`)
- Test: `tests/test_review_gates.bats`

**Interfaces:**
- Consumes: `preserve_branch()` (Task 1).
- Produces: no signature changes; both paths now push before setting `agent:failed` and name the branch in their comments.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_review_gates.bats` (after the `run_test_gate` section added in Task 4; `_setup_test_gate` provides the `preserve_branch` recorder):

```bash
@test "REGRESSION issue-73: Gate B parse failure preserves the branch and names it" {
    _setup_test_gate
    export AGENT_POST_IMPL_REVIEW="true"
    _ledger_init
    run_claude() { echo '{"result":"not valid json at all"}'; }
    run run_post_impl_review
    assert_failure
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
    local calls
    calls=$(get_mock_calls "gh")
    [[ "$calls" == *"agent/issue-99"* ]]
}

@test "REGRESSION issue-73: retry-session test failure preserves the branch" {
    _setup_test_gate
    export AGENT_TEST_COMMAND="false"
    _ledger_init
    run_claude() { echo '{"result":"{\"action\": \"addressed\", \"dispositions\": []}"}'; }
    run run_post_impl_retry_session "Read,Edit"
    assert_failure
    [ -f "${TEST_TEMP_DIR}/preserve_calls" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats --filter "issue-73"`
Expected: the two new tests FAIL (`preserve_calls` file never created).

- [ ] **Step 3: Implement**

In `run_post_impl_review`, replace the `*)` case body (lines 282-289) with:

```bash
        *)
            log "Post-implementation review: could not parse response"
            log "Raw output: $claude_output"
            preserve_branch || true
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "Agent post-implementation review could not parse its output. The implementation commits are pushed to the \`${BRANCH_NAME}\` branch — check it and create a PR manually if the implementation looks correct." 2>/dev/null || true
            return 1
            ;;
```

In `run_post_impl_retry_session`, replace the `if [ "$test_exit" -ne 0 ]; then` block body (lines 328-343) with:

```bash
        if [ "$test_exit" -ne 0 ]; then
            log "Review loop retry: tests failed after retry"
            preserve_branch || true
            set_label "agent:failed"
            gh issue comment "$NUMBER" --repo "$REPO" \
                --body "## Post-Implementation Review: Retry Failed

Tests failed after addressing review findings. The work (including retry commits) is pushed to the \`${BRANCH_NAME}\` branch.

<details><summary>Test output (last 100 lines)</summary>

\`\`\`
$(echo "$test_output" | tail -100)
\`\`\`
</details>" 2>/dev/null || true
            return 1
        fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tests/bats/bin/bats tests/test_review_gates.bats`
Expected: all PASS, including every pre-existing Gate A/Gate B/ledger/retry test.

- [ ] **Step 5: Shellcheck + commit**

Run: `shellcheck scripts/lib/review-gates.sh`
Expected: no output.

```bash
git add scripts/lib/review-gates.sh tests/test_review_gates.bats
git commit -m "fix(#73): preserve branch on Gate B parse failure and retry-session test failure"
```

---

### Task 7: Implement-prompt note about resumed branches

**Files:**
- Modify: `prompts/implement.md` (add a short section after "## Approved Plan", before "### Attached Data")

**Interfaces:**
- Consumes: nothing. Produces: guidance only (no dispatch-script coupling).

- [ ] **Step 1: Edit the prompt**

In `prompts/implement.md`, after the "This plan has been reviewed and approved by a human. Follow it closely." line, add:

```markdown
## Prior Work on This Branch
A previous attempt may have completed part (or all) of the implementation before a test gate or review gate failed — the branch is preserved across attempts.
- Run: git log --format="- %h %s" origin/main..HEAD
- If commits exist beyond the plan/spec documents, READ the diff (git diff origin/main..HEAD) before writing any code. Resume from where the previous attempt stopped — do not redo or revert finished work. Your first priority is whatever made the previous attempt fail (check the latest issue comments for the failure output).
```

- [ ] **Step 2: Verify no test regressions**

Run: `./tests/bats/bin/bats tests/test_common.bats --filter "load_prompt"`
Expected: PASS (prompt still loads).

- [ ] **Step 3: Commit**

```bash
git add prompts/implement.md
git commit -m "docs(#73): implement prompt — resume preserved branches instead of redoing work"
```

---

### Task 8: Documentation

**Files:**
- Modify: `docs/configuration.md` (AGENT_TEST_COMMAND section, lines 109-131)
- Modify: `docs/customization.md` ("Adding a Pre-PR Test Gate" section, lines 139-177)
- Modify: `docs/architecture.md` (implement flow diagram, lines 195-202)
- Modify: `docs/troubleshooting.md` ("Tests Fail in Pre-PR Gate" → "Recovery", lines 312-325)

**Interfaces:** documentation only.

- [ ] **Step 1: configuration.md**

In the `### AGENT_TEST_COMMAND` section, replace the sentence "If the tests fail, the PR is not created and the issue is labeled `agent:failed`." with:

```markdown
If the tests fail, up to `AGENT_TEST_GATE_MAX_RETRIES` automated fix sessions attempt to get the suite green; if it still fails, the work branch is pushed, the failure comment links it, and the issue is labeled `agent:failed`. Re-applying `agent:plan-approved` resumes from the preserved branch.
```

After that section, add a new section:

```markdown
### AGENT_TEST_GATE_MAX_RETRIES

Maximum automated fix sessions when the pre-PR test gate fails. Each session is a fresh Claude run given the failing test output; the gate re-runs after each. A session that makes no commits ends the loop early (the failure is judged unfixable from inside the repo — e.g. a broken `AGENT_TEST_COMMAND`). Whatever happens, the work branch is pushed before `agent:failed` is set, so implementation work is never lost.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TEST_GATE_MAX_RETRIES` | `2` | non-negative integer (`0` = no fix sessions) |
| `AGENT_PROMPT_TEST_FIX` | *(empty, built-in `prompts/test-fix.md`)* | path |
| `AGENT_MODEL_TEST_FIX` | *(empty, falls back to `AGENT_MODEL`)* | model name |
```

- [ ] **Step 2: customization.md**

In "Adding a Pre-PR Test Gate", replace the "How It Works" list with:

```markdown
1. The agent finishes implementation and commits its changes
2. The dispatch script pushes the work branch (so a later failure never loses the work), then runs `AGENT_TEST_COMMAND` in the worktree
3. If the command exits with code 0, the review loop runs and a PR is created
4. If the command exits non-zero, up to `AGENT_TEST_GATE_MAX_RETRIES` (default 2) automated fix sessions get the failing output and try to make the suite green; a session that makes no commits stops the loop early
5. If the gate still fails, the last 100 lines of output are posted as an issue comment (linking the pushed branch) and the issue is labeled `agent:failed`; re-applying `agent:plan-approved` resumes from the pushed branch
```

- [ ] **Step 3: architecture.md**

In the implement flow diagram, replace:

```
      if new commits:
        run pre-PR test gate (if configured) -> fail -> agent:failed
        push branch
```

with:

```
      if new commits:
        push branch (preserve work before any gate can fail)
        run pre-PR test gate (if configured)
          -> fail -> bounded fix sessions (AGENT_TEST_GATE_MAX_RETRIES)
          -> still failing -> agent:failed (branch stays pushed)
```

- [ ] **Step 4: troubleshooting.md**

In "Tests Fail in Pre-PR Gate" → "Recovery", replace the paragraph "The agent's commits are still in the worktree (but not pushed). You can:" and the numbered list with:

```markdown
The agent's commits are pushed to the work branch (`agent/issue-N`) before `agent:failed` is set — the failure comment links it. You can:

1. Fix the underlying problem (e.g. a broken `AGENT_TEST_COMMAND`) and re-apply `agent:plan-approved` — the dispatch resumes from the pushed branch instead of starting over
2. Check out the branch, fix the tests yourself, and create the PR manually:
   ```bash
   git fetch origin agent/issue-42
   git checkout agent/issue-42
   # inspect and fix
   git push origin agent/issue-42
   gh pr create --head agent/issue-42 ...
   ```
```

- [ ] **Step 5: Commit**

```bash
git add docs/configuration.md docs/customization.md docs/architecture.md docs/troubleshooting.md
git commit -m "docs(#73): document branch preservation and the test-gate fix loop"
```

---

### Task 9: Full verification

- [ ] **Step 1: Run the complete check suite**

Run: `shellcheck scripts/*.sh scripts/lib/*.sh && ./tests/bats/bin/bats tests/`
Expected: shellcheck silent; every BATS test PASSES (no skips beyond any pre-existing platform skips).

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feature/73-preserve-work-on-gate-failure
```

## Self-review notes (already applied)

- The v1.0.3 regression tests are *relocated*, not deleted — their protected behavior (setup runs before tests) moves with the gate into `run_test_gate` and is re-asserted by a sed-scoped grep, which is why `run_test_gate` must keep column-0 `}` out of its body.
- `preserve_branch` is defined in `common.sh` (not `worktree.sh`) because `review-gates.sh` calls it and test files source only `common.sh` + `review-gates.sh`.
- The success-path push (`common.sh:294`) intentionally stays strict; `preserve_branch` earlier makes it a near-no-op fast-forward in the normal case.
- `notify "tests_passed"` keeps its existing behavior of firing even when the gate is disabled — semantics unchanged.
