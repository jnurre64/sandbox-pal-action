# ERR trap double-reports on controlled handler failures

> **Status:** Draft — fixed by `fix/err-trap-guards-clean-failures`. File as issue on `jnurre64/claude-agent-dispatch` and link the PR if you want to track the finding.

## Summary

`agent-dispatch.sh`'s `_on_unexpected_error` trap is intended to catch genuine infrastructure crashes (missing commands, config failures, syntax errors) and post an "Agent Infrastructure Error" comment. It fires on `ERR` and `EXIT` via `set -e`.

The trap does not distinguish a controlled `return 1` from a handler function that already reported its own failure cleanly. Under `set -e`, the unguarded call to `handle_post_implementation` at line 439 of `handle_implement()` propagates any non-zero return up to the script top level, which triggers the ERR trap, which posts the infrastructure-error comment — even though the test-gate / Gate-B / no-commits handler already posted a specific failure comment seconds before.

## Observed case

Webber issue #59, run `24280942202`. Sequence:

1. Implementation made 1 commit (correct, matches the plan).
2. Pre-PR test gate ran 574 tests; 1 failed (`test_struggling_bug_follows_web_movement` — unrelated pre-existing physics flake).
3. `handle_post_implementation` (`scripts/lib/common.sh:221-237`) caught the test failure:
   - Logged `Pre-PR test gate FAILED (exit code $test_exit)`
   - Posted `## Test Failure (Pre-PR Gate)` comment with last 100 lines of output
   - Called `set_label "agent:failed"`
   - Emitted `tests_failed` notification
   - Returned `1`
4. `handle_implement` caller at `agent-dispatch.sh:439`:
   ```bash
   handle_post_implementation "$start_sha" "$issue_title" "$claude_output"
   cleanup_worktree
   ```
   Unguarded. `set -e` propagated the `1` return. `cleanup_worktree` **never ran** — worktree leaked.
5. ERR trap fired at line 439. `_on_unexpected_error` posted `## Agent Infrastructure Error` with exit code 1 and the generic `A command or config assertion failed` hint.
6. EXIT trap also fired (same early-return guard means it was effectively a no-op on the infra comment, but the duplicate set_label ran).

Issue #59 now has two failure comments for the same underlying cause, and the worktree at `~/.claude/worktrees/STRONGMAD/Webber-issue-59` is orphaned until manual cleanup.

## Root cause

`set -e` + trap + unguarded function call with intentional `return 1`. Standard bash gotcha. The three handler paths that rely on `return 1` as a controlled failure signal:

- Test gate failure (`common.sh:236`)
- Gate B halt after retry exhausted (`common.sh:248`)
- No commits made (`common.sh:311-320`, this path returns at the end of the function — which is also `1` due to the final `else` branch... actually let me re-check)

Actually the "no commits" branch at `common.sh:311` doesn't explicitly `return 1` — it just hits the end of the function. That exits with whatever the last command returned. Worth auditing.

## Fix

`agent-dispatch.sh:439`:

```bash
# Before
handle_post_implementation "$start_sha" "$issue_title" "$claude_output"
cleanup_worktree

# After
if ! handle_post_implementation "$start_sha" "$issue_title" "$claude_output"; then
    log "Post-implementation handler reported a controlled failure."
fi
cleanup_worktree
```

The `if !` wrapper is the idiomatic bash pattern for suppressing `set -e` on a specific call while still observing the return value. `cleanup_worktree` now always runs (no more leaks), and the ERR trap doesn't fire.

## Regression tests

Two source-level regression guards in `test_common.bats`:

- `REGRESSION: handle_post_implementation call in handle_implement is guarded` — greps the source for `if ! handle_post_implementation`
- `REGRESSION: cleanup_worktree runs after guarded handle_post_implementation` — uses awk to confirm the cleanup call sits after the guard block

Source-level because behavioral testing would require spawning subshells with the trap installed, mocking `handle_post_implementation`, and asserting no "Agent Infrastructure Error" comment was posted — considerably more complex for a one-line syntactic fix.

## Related audit items

While fixing this, I noticed two things worth a follow-up:

1. **`handle_direct_implement` also eventually calls `handle_post_implementation`** (via `handle_implement` on line 514). Same fix should work transitively because the guard is at the handle_implement call site. Verified by source inspection.

2. **`_on_unexpected_error` could distinguish controlled vs genuine failures.** One approach: set a `_HANDLED_FAILURE=1` variable in handler functions before returning 1, and have the trap early-return when it sees that variable. More complex but catches cases we miss at individual call sites. Probably not worth it for this one call site.

3. **`worktree leak on set -e exit`**. The current pattern leaves the worktree dir when the trap fires. Even with the guard in place, a genuine crash during handle_post_implementation still leaks. Consider calling cleanup_worktree from `_on_unexpected_error` with a best-effort guard.

## References

- PR: `fix/err-trap-guards-clean-failures`
- Observed: Webber #59 run `24280942202` on 2026-04-11
- Related: the review-gates JSON parser fix (`fix/review-gates-json-preamble-parse`) from the same session — same root issue of fresh-session agents interacting with dispatch-script expectations in ways the original authors didn't anticipate
