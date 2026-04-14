# Fix `grep -P` Windows/non-UTF-8 portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all remaining `grep -P` usage from owned shell scripts so BATS tests pass on Windows Git Bash and non-UTF-8 Linux locales, and add a regression-guard test to prevent reintroduction.

**Architecture:** Mechanical rewrite of 9 `grep -P` call sites across 2 files — 8 translate to `grep -oE` / `grep -qE` / `sed -nE`, 1 (the interpolated-URL site in `data-fetch.sh:49`) becomes bash-native `[[ =~ ]]` with `BASH_REMATCH`. A new BATS test statically asserts no owned shell file uses `grep -P`, locking the fix in.

**Tech Stack:** Bash 4.x (Git Bash on Windows, bash on Linux), GNU grep (ERE mode only), GNU sed, BATS-Core for tests, ShellCheck for static analysis.

**Spec:** `docs/superpowers/specs/2026-04-13-fix-grep-p-windows-portability-design.md`
**Issue:** [#42](https://github.com/jnurre64/claude-agent-dispatch/issues/42)

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `scripts/lib/data-fetch.sh` | Modify | Pre-fetch debug data from issue/PR comments — 4 grep -P sites rewritten |
| `scripts/agent-dispatch.sh` | Modify | Main dispatch entry point — 4 grep -P sites rewritten |
| `tests/test_portability.bats` | **Create** | New: statically assert no owned shell file uses `grep -P` |

No new modules, no refactor. The bash-native rewrite at `data-fetch.sh:49` stays inside `_download_linked_files` where it already lives.

---

## Task 1: Baseline — observe the current RED state

**Files:** none (observation only)

- [ ] **Step 1: Observe the current failures on default locale**

Run: `LC_ALL=C ./tests/bats/bin/bats tests/test_data_fetch.bats 2>&1 | head -60`

Expected (simulating Windows Git Bash default): 5 tests fail with `grep: -P supports only unibyte and UTF-8 locales`. Specifically:
- `extract_debug_data: finds gist links in comments`
- `extract_debug_data: checks extra_text for attachments`
- `_download_linked_files: extracts and downloads gist URLs`
- `_download_linked_files: handles multiple gist URLs`
- `_download_linked_files: records errors for failed downloads`

(On a machine with `LANG=C.UTF-8`, this step is purely informational — the suite is green there. The point is to have the same mental picture as the bug reporter.)

- [ ] **Step 2: Confirm the 9 grep -P sites are present**

Run: `grep -rnE 'grep[[:space:]]+-[a-zA-Z]*P' scripts/`

Expected output contains exactly these 9 lines:
```
scripts/agent-dispatch.sh:176:    triage_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
scripts/agent-dispatch.sh:316:    triage_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
scripts/agent-dispatch.sh:508:    validate_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
scripts/agent-dispatch.sh:569:    issue_num=$(echo "$branch" | grep -oP 'issue-\K\d+' || echo "$pr_number")
scripts/lib/data-fetch.sh:25:    gist_urls=$(echo "$text" | grep -oP 'https://gist\.github\.com/[a-zA-Z0-9_-]+/[a-f0-9]+' | sort -u)
scripts/lib/data-fetch.sh:42:    attachment_urls=$(echo "$text" | grep -oP 'https://github\.com/user-attachments/(?:assets|files)/[a-zA-Z0-9_./-]+' | sort -u)
scripts/lib/data-fetch.sh:49:            md_name=$(echo "$text" | grep -oP '\[([^\]]+)\]\('"$(echo "$attach_url" | sed 's/[\/&]/\\&/g')"'\)' | grep -oP '^\[[^\]]+\]' | tr -d '[]' | head -1 || true)
scripts/lib/data-fetch.sh:107:        echo "$extra_text" | grep -qP 'gist\.github\.com|user-attachments/' && has_links=true
```

---

## Task 2: Rewrite the 4 sites in `scripts/lib/data-fetch.sh`

**Files:**
- Modify: `scripts/lib/data-fetch.sh:25`
- Modify: `scripts/lib/data-fetch.sh:42`
- Modify: `scripts/lib/data-fetch.sh:49` (bash-native rewrite, several lines)
- Modify: `scripts/lib/data-fetch.sh:107`
- Test (pre-existing): `tests/test_data_fetch.bats` — 5 tests currently RED

- [ ] **Step 1: Confirm the 5 data-fetch tests are currently RED under C locale**

Run: `LC_ALL=C ./tests/bats/bin/bats tests/test_data_fetch.bats 2>&1 | grep -E 'not ok|grep: -P'`

Expected: 5 `not ok` lines and several `grep: -P supports only unibyte and UTF-8 locales` lines.

- [ ] **Step 2: Rewrite line 25 — gist URL extraction**

Edit `scripts/lib/data-fetch.sh`, change:
```bash
    gist_urls=$(echo "$text" | grep -oP 'https://gist\.github\.com/[a-zA-Z0-9_-]+/[a-f0-9]+' | sort -u)
```
to:
```bash
    gist_urls=$(echo "$text" | grep -oE 'https://gist\.github\.com/[a-zA-Z0-9_-]+/[a-f0-9]+' | sort -u)
```

(Only flag change: `-oP` → `-oE`. Pattern is plain ERE — no non-capturing groups, no `\K`, no `\d`.)

- [ ] **Step 3: Rewrite line 42 — attachment URL extraction**

Edit `scripts/lib/data-fetch.sh`, change:
```bash
    attachment_urls=$(echo "$text" | grep -oP 'https://github\.com/user-attachments/(?:assets|files)/[a-zA-Z0-9_./-]+' | sort -u)
```
to:
```bash
    attachment_urls=$(echo "$text" | grep -oE 'https://github\.com/user-attachments/(assets|files)/[a-zA-Z0-9_./-]+' | sort -u)
```

(Flag `-oP` → `-oE`, non-capturing `(?:assets|files)` → capturing `(assets|files)`. For a match test — we don't read back-references — the capturing group has identical observable behaviour.)

- [ ] **Step 4: Rewrite line 49 — bash-native replacement of the nested grep+sed pipeline**

Current code block (lines ~47-50) in `_download_linked_files`:
```bash
        if [[ "$attach_filename" != *.* ]]; then
            local md_name
            md_name=$(echo "$text" | grep -oP '\[([^\]]+)\]\('"$(echo "$attach_url" | sed 's/[\/&]/\\&/g')"'\)' | grep -oP '^\[[^\]]+\]' | tr -d '[]' | head -1 || true)
            [ -n "$md_name" ] && attach_filename="$md_name"
        fi
```

Replace with:
```bash
        if [[ "$attach_filename" != *.* ]]; then
            # Try to find the markdown link label for this URL: [label](attach_url)
            # Escape dots in URL for use in bash regex (line 42's charset permits only . as a regex metachar).
            local url_re="${attach_url//./\\.}"
            local md_name=""
            if [[ "$text" =~ \[([^]]+)\]\($url_re\) ]]; then
                md_name="${BASH_REMATCH[1]}"
            fi
            [ -n "$md_name" ] && attach_filename="$md_name"
        fi
```

Why bash-native only here: this is the one site that interpolates a runtime-unknown URL into a regex. The original `sed`-escape-then-interpolate is fragile; `BASH_REMATCH` eliminates 3 subprocess calls and a command-substitution inside a command-substitution. Line 42's URL regex constrains characters to `[a-zA-Z0-9_./-]`, so escaping `.` is sufficient.

- [ ] **Step 5: Rewrite line 107 — has_links probe**

Edit `scripts/lib/data-fetch.sh`, change:
```bash
        echo "$extra_text" | grep -qP 'gist\.github\.com|user-attachments/' && has_links=true
```
to:
```bash
        echo "$extra_text" | grep -qE 'gist\.github\.com|user-attachments/' && has_links=true
```

(Flag change only.)

- [ ] **Step 6: Run test_data_fetch.bats under C locale — expect GREEN**

Run: `LC_ALL=C ./tests/bats/bin/bats tests/test_data_fetch.bats`

Expected: `11 tests, 0 failures`. All 5 previously-RED tests now pass; no `grep: -P` error messages in diagnostic output.

- [ ] **Step 7: ShellCheck data-fetch.sh**

Run: `shellcheck scripts/lib/data-fetch.sh`

Expected: no output (zero warnings).

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/data-fetch.sh
git commit -m "$(cat <<'EOF'
fix(data-fetch): replace grep -P with portable alternatives (#42)

Four grep -P sites in _download_linked_files and extract_debug_data
fail on non-UTF-8 locales (Windows Git Bash default, Linux under C
locale). GNU grep rejects -P with "supports only unibyte and UTF-8
locales", exits 2 with empty stdout, and downstream URL extraction
silently produces no results.

- Lines 25, 42, 107: grep -oP / -qP -> grep -oE / -qE (patterns are
  plain ERE; drop non-capturing (?:...) at line 42)
- Line 49: replace chained grep+sed+tr pipeline with bash [[ =~ ]]
  and BASH_REMATCH, escaping dots in the interpolated URL

Verification: LC_ALL=C tests/bats/bin/bats tests/test_data_fetch.bats
now passes all 11 tests (5 were RED).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rewrite the 4 sites in `scripts/agent-dispatch.sh`

**Files:**
- Modify: `scripts/agent-dispatch.sh:176`
- Modify: `scripts/agent-dispatch.sh:316`
- Modify: `scripts/agent-dispatch.sh:508`
- Modify: `scripts/agent-dispatch.sh:569`

No direct BATS coverage for these sites today (non-goal to add — these are inside large handler functions that would need heavy mocking). The regression-guard test in Task 4 enforces that they stay portable.

- [ ] **Step 1: Rewrite line 176 — triage JSON extraction**

Edit `scripts/agent-dispatch.sh`, change:
```bash
    triage_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
```
to:
```bash
    triage_json=$(echo "$claude_output" | grep -oE '[{][^{}]*"action"[^{}]*[}]' | tail -1)
```

(Using `[{]` / `[}]` bracket-classes avoids any ERE parsers that interpret bare `{` as a malformed quantifier. The semantics are identical to the PCRE version.)

- [ ] **Step 2: Rewrite line 316 — identical pattern, reply handler**

Edit `scripts/agent-dispatch.sh`, change:
```bash
    triage_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
```
to:
```bash
    triage_json=$(echo "$claude_output" | grep -oE '[{][^{}]*"action"[^{}]*[}]' | tail -1)
```

- [ ] **Step 3: Rewrite line 508 — identical pattern, validate handler**

Edit `scripts/agent-dispatch.sh`, change:
```bash
    validate_json=$(echo "$claude_output" | grep -oP '\{[^{}]*"action"[^{}]*\}' | tail -1)
```
to:
```bash
    validate_json=$(echo "$claude_output" | grep -oE '[{][^{}]*"action"[^{}]*[}]' | tail -1)
```

- [ ] **Step 4: Rewrite line 569 — issue-number extraction from branch name**

Edit `scripts/agent-dispatch.sh`, change:
```bash
    issue_num=$(echo "$branch" | grep -oP 'issue-\K\d+' || echo "$pr_number")
```
to:
```bash
    issue_num=$(echo "$branch" | sed -nE 's/.*issue-([0-9]+).*/\1/p')
    if [ -z "$issue_num" ]; then
        issue_num="$pr_number"
    fi
```

Why the `if` form (and not `[ -z ] && ...`): the original `grep -oP '\K' || echo fallback` relies on grep exiting non-zero on no-match. `sed` exits 0 even when no line is captured, so we cannot reuse the `||` pattern. The `[ -z ] && ...` shorthand would abort the script under `set -euo pipefail` when `$issue_num` is already populated (the `[` test returns 1, short-circuiting the `&&`, propagating exit 1 to the enclosing shell). Use an explicit `if` to make the branch behaviour unambiguous.

- [ ] **Step 5: ShellCheck agent-dispatch.sh**

Run: `shellcheck scripts/agent-dispatch.sh`

Expected: no output.

- [ ] **Step 6: Confirm no `grep -P` remains anywhere in `scripts/`**

Run: `grep -rnE 'grep[[:space:]]+-[a-zA-Z]*P' scripts/ || echo "CLEAN"`

Expected: `CLEAN`.

- [ ] **Step 7: Smoke-test the full BATS suite under C locale**

Run: `LC_ALL=C ./tests/bats/bin/bats tests/`

Expected: all tests green. (No regressions from the `agent-dispatch.sh` changes — the existing tests don't cover those handler paths, but they do source `common.sh` and various libs that are unaffected.)

- [ ] **Step 8: Commit**

```bash
git add scripts/agent-dispatch.sh
git commit -m "$(cat <<'EOF'
fix(dispatch): replace grep -P with portable alternatives (#42)

Four grep -P sites in agent-dispatch.sh (three identical triage-JSON
extractors and one PCRE-\K issue-number parser) fail silently on
non-UTF-8 locales. No BATS coverage today, but triage dispatches,
issue routing, and PR-review flows all depend on these paths.

- Lines 176, 316, 508: grep -oP '\{...\}' -> grep -oE '[{]...[}]'
  (bracket-class braces sidestep ERE quantifier ambiguity)
- Line 569: grep -oP 'issue-\K\d+' -> sed -nE capture + explicit
  fallback, mirroring cbfc4a4's config-vars.sh precedent

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add the regression-guard BATS test

**Files:**
- Create: `tests/test_portability.bats`

- [ ] **Step 1: Create the guard test**

Create `tests/test_portability.bats` with these contents:

```bash
#!/usr/bin/env bats
# Portability guards: fail on known non-portable constructs.
# Uses only POSIX / ERE tools so the guards themselves run everywhere.

load 'helpers/test_helper'

@test "portability: no owned shell file uses grep -P (non-portable PCRE mode)" {
    local repo_root
    repo_root="$(cd "${SCRIPTS_DIR}/.." && pwd)"

    # Scope: owned shell surface only.
    #   - scripts/  (all .sh)
    #   - discord-bot/*.sh
    #   - tests/*.bats  (our BATS files themselves)
    # Excluded:
    #   - tests/bats/      upstream BATS submodule
    #   - .worktrees/      transient worktree copies
    #   - docs/            historical plans legitimately reference grep -P
    local matches
    matches=$(grep -rnE 'grep[[:space:]]+-[a-zA-Z]*P' \
        "${repo_root}/scripts" \
        "${repo_root}/discord-bot" \
        "${repo_root}/tests"/*.bats 2>/dev/null || true)

    if [ -n "$matches" ]; then
        echo "Found non-portable 'grep -P' usage:" >&2
        echo "$matches" >&2
        echo "" >&2
        echo "grep -P (PCRE) fails on non-UTF-8 locales (Windows Git Bash default)." >&2
        echo "Rewrite with grep -E, sed -nE, or bash [[ =~ ]]." >&2
        false
    fi
}
```

- [ ] **Step 2: Run the guard test — expect GREEN**

Run: `./tests/bats/bin/bats tests/test_portability.bats`

Expected:
```
 ✓ portability: no owned shell file uses grep -P (non-portable PCRE mode)

1 test, 0 failures
```

- [ ] **Step 3: Negative test — confirm the guard correctly catches a regression**

Temporarily reintroduce a `grep -P` to verify the guard fails as designed.

Run:
```bash
# Append a bogus grep -P to data-fetch.sh
printf '\n# REGRESSION_PROBE: grep -P "test" /dev/null\n' >> scripts/lib/data-fetch.sh
./tests/bats/bin/bats tests/test_portability.bats
```

Expected: the test FAILS with diagnostic output showing `scripts/lib/data-fetch.sh:<line>: # REGRESSION_PROBE: grep -P "test" /dev/null` and the guidance message `Rewrite with grep -E, sed -nE, or bash [[ =~ ]]`.

- [ ] **Step 4: Revert the probe**

Run:
```bash
git checkout scripts/lib/data-fetch.sh
./tests/bats/bin/bats tests/test_portability.bats
```

Expected: the guard test passes again (1 test, 0 failures). Confirm no stray changes with `git status` — should show only `tests/test_portability.bats` as untracked.

- [ ] **Step 5: ShellCheck the new test file** (BATS is close enough to bash that shellcheck catches real issues)

Run: `shellcheck -s bash tests/test_portability.bats || true`

Expected: the only permissible warnings are BATS-specific false positives (e.g., `SC2154` about the `SCRIPTS_DIR` variable sourced from the helper). If any real issue appears, fix it before committing.

- [ ] **Step 6: Commit**

```bash
git add tests/test_portability.bats
git commit -m "$(cat <<'EOF'
test: add portability guard against grep -P reintroduction (#42)

cbfc4a4 missed 9 grep -P sites because nothing prevented them. This
BATS test hard-fails if any owned shell file (scripts/, discord-bot/,
tests/*.bats) uses grep -P. The guard itself uses only grep -E (no
PCRE), so it runs everywhere the code it checks runs.

Scope excludes tests/bats/ (upstream submodule), .worktrees/
(transient), and docs/ (archival plans that legitimately reference
grep -P in historical context).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full BATS suite, C locale**

Run: `LC_ALL=C ./tests/bats/bin/bats tests/`

Expected: all tests pass, including the new `test_portability.bats`. No `grep: -P` errors anywhere in diagnostic output.

- [ ] **Step 2: Full BATS suite, default locale** (should have always been green on this machine)

Run: `./tests/bats/bin/bats tests/`

Expected: same — all green.

- [ ] **Step 3: ShellCheck every touched file**

Run: `shellcheck scripts/*.sh scripts/lib/*.sh`

Expected: no output.

- [ ] **Step 4: Final grep-P search across the entire repo (owned surface)**

Run: `grep -rnE 'grep[[:space:]]+-[a-zA-Z]*P' scripts/ discord-bot/ tests/*.bats 2>/dev/null || echo "CLEAN"`

Expected: `CLEAN`.

- [ ] **Step 5: Confirm git log shows the three expected commits**

Run: `git log --oneline -5`

Expected top three entries (most recent first):
1. `test: add portability guard against grep -P reintroduction (#42)`
2. `fix(dispatch): replace grep -P with portable alternatives (#42)`
3. `fix(data-fetch): replace grep -P with portable alternatives (#42)`

- [ ] **Step 6: Ready for PR**

The branch is ready. Use the `finishing-a-development-branch` skill to decide PR vs merge strategy.

---

## Acceptance criteria (maps 1:1 to spec goals)

- [x] The 5 failing BATS tests in `tests/test_data_fetch.bats` pass on Windows Git Bash default locale and on Linux under `LC_ALL=C` — verified in Task 2 Step 6 and Task 5 Step 1.
- [x] Zero `grep -P` remain in owned shell (`scripts/`, `discord-bot/`, `tests/*.bats`) — verified in Task 3 Step 6 and Task 5 Step 4.
- [x] A hard-failing BATS test prevents the same class of regression — implemented in Task 4, negative-tested in Task 4 Step 3.
- [x] PCRE is **not** re-added as a prerequisite — no changes to `scripts/check-test-prereqs.sh`, `CLAUDE.md`, or `.claude/skills/test/SKILL.md`.
