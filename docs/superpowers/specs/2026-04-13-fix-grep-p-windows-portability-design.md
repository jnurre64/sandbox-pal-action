# Fix `grep -P` Windows/non-UTF-8 portability — Design

**Issue:** [#42](https://github.com/jnurre64/claude-agent-dispatch/issues/42)
**Status:** Design approved, ready for implementation plan
**Date:** 2026-04-13

## Problem

Five BATS tests in `tests/test_data_fetch.bats` fail on Windows Git Bash and on any Linux host whose locale is not UTF-8:

```
not ok 67 extract_debug_data: finds gist links in comments
not ok 68 extract_debug_data: checks extra_text for attachments
not ok 69 _download_linked_files: extracts and downloads gist URLs
not ok 70 _download_linked_files: handles multiple gist URLs
not ok 71 _download_linked_files: records errors for failed downloads
```

Each failure log shows: `grep: -P supports only unibyte and UTF-8 locales`. GNU grep refuses `-P` under `LANG=C` / `LC_ALL=C`, returns exit 2, and produces empty stdout. Downstream code sees empty `gist_urls` / `attachment_urls`, no files get downloaded, and the `[ -f gist-*.txt ]` assertions fail.

The prior fix in commit cbfc4a4 ("remove last `grep -P` usage and drop PCRE prereq") was inaccurate: it addressed `scripts/lib/config-vars.sh` only and **missed 9 other call sites** across `scripts/lib/data-fetch.sh` and `scripts/agent-dispatch.sh`. cbfc4a4 also removed the PCRE probe from `scripts/check-test-prereqs.sh`, so there is no longer any early warning that surfaces the miss. CI is green because GitHub Actions Ubuntu runners boot with `LANG=C.UTF-8`.

### All 9 remaining `grep -P` call sites

| File | Line | Pattern |
|---|---:|---|
| `scripts/lib/data-fetch.sh` | 25 | `grep -oP 'https://gist\.github\.com/[a-zA-Z0-9_-]+/[a-f0-9]+'` |
| `scripts/lib/data-fetch.sh` | 42 | `grep -oP 'https://github\.com/user-attachments/(?:assets\|files)/[a-zA-Z0-9_./-]+'` |
| `scripts/lib/data-fetch.sh` | 49 | two chained `grep -oP` with injected-URL regex and `[^\]]` class |
| `scripts/lib/data-fetch.sh` | 107 | `grep -qP 'gist\.github\.com\|user-attachments/'` |
| `scripts/agent-dispatch.sh` | 176, 316, 508 | `grep -oP '\{[^{}]*"action"[^{}]*\}'` (triage-JSON extraction) |
| `scripts/agent-dispatch.sh` | 569 | `grep -oP 'issue-\K\d+'` (branch → issue number; uses PCRE `\K`) |

The 4 `data-fetch.sh` sites are hit by the 5 failing BATS tests. The 4 `agent-dispatch.sh` sites have no direct BATS coverage today but would silently misbehave on any non-UTF-8 host — triage dispatches, issue routing, and PR-review flows all depend on them.

## Goals

1. Make the 5 failing BATS tests pass on Windows Git Bash under the default (empty) `LANG` and on Linux under `LC_ALL=C`.
2. Remove every remaining `grep -P` from code we own.
3. Prevent the same class of regression from slipping in again via a statically-enforced BATS guard test.
4. Keep the decision from cbfc4a4 intact: PCRE is **not** a prerequisite on any platform.

## Non-goals

- Re-adding the PCRE probe to `scripts/check-test-prereqs.sh`. cbfc4a4 explicitly removed PCRE as a requirement; a soft probe would contradict that decision and the new guard test provides stronger protection.
- Rewriting `docs/superpowers/plans/*.md` — those are historical implementation plans that legitimately reference `grep -P` as it existed at the time. Rewriting them would falsify the record.
- Touching the `tests/bats/` submodule (upstream BATS code we don't own).
- Broader portability work (e.g., `sed -i` differences, `readlink`, `md5sum` vs `md5`). This spec is scoped to the `grep -P` issue only.

## Design

### Per-site rewrites

**`scripts/lib/data-fetch.sh`:**

| Line | Rewrite | Rationale |
|---|---|---|
| 25 | `grep -oE 'https://gist\.github\.com/[a-zA-Z0-9_-]+/[a-f0-9]+'` | Pattern is plain ERE already; swap flag. |
| 42 | `grep -oE 'https://github\.com/user-attachments/(assets\|files)/[a-zA-Z0-9_./-]+'` | Drop non-capturing `(?:...)` → capturing `(...)` — semantically identical for a match test. |
| 49 | Bash native `[[ =~ ]]` with `BASH_REMATCH` (see below) | Current pipeline chains two `grep -oP` with a `sed`-escaped interpolation of `$attach_url`. Bash-native removes the escape dance and 3 subprocess calls. |
| 107 | `grep -qE 'gist\.github\.com\|user-attachments/'` | Simple alternation; swap flag. |

Line 49 rewrite:

```bash
# Before:
md_name=$(echo "$text" | grep -oP '\[([^\]]+)\]\('"$(echo "$attach_url" | sed 's/[\/&]/\\&/g')"'\)' | grep -oP '^\[[^\]]+\]' | tr -d '[]' | head -1 || true)

# After:
local url_re="${attach_url//./\\.}"   # escape dots; line 42's charset has no other regex metachars
local md_name=""
if [[ "$text" =~ \[([^]]+)\]\($url_re\) ]]; then
    md_name="${BASH_REMATCH[1]}"
fi
```

Why bash-native here and not elsewhere:
- This is the only site that interpolates a runtime-unknown URL into a regex. The `sed`-escape-then-interpolate pattern is fragile and error-prone.
- Line 42's URL regex constrains the URL character set to `[a-zA-Z0-9_./-]`; the only regex metacharacter that can appear is `.`. A simple `${var//./\\.}` is sufficient.
- Verified on Git Bash (Windows): `[[ =~ ]]` + `BASH_REMATCH` returns `myfile.txt` as expected.

**`scripts/agent-dispatch.sh`:**

| Line | Rewrite | Rationale |
|---|---|---|
| 176, 316, 508 | `grep -oE '[{][^{}]*"action"[^{}]*[}]'` | Bracket-class `[{]` / `[}]` sidesteps portability edge cases around `{` as an ERE quantifier starter. Same semantics, no PCRE. |
| 569 | `sed -nE 's/.*issue-([0-9]+).*/\1/p'` | PCRE `\K` has no ERE equivalent. Capture-group `sed` mirrors the precedent set in cbfc4a4 for `config-vars.sh`. |

### Regression-guard test

Add a new test that statically asserts no owned shell file uses `grep -P`. Location: `tests/test_portability.bats` (new file — keeps portability concerns grouped and distinct from prereq detection).

```bash
#!/usr/bin/env bats
# Portability guards: fail on known non-portable constructs.

load 'helpers/test_helper'

@test "portability: no shell file uses grep -P (non-portable PCRE mode)" {
    local matches
    matches=$(grep -rnE 'grep[[:space:]]+-[a-zA-Z]*P' \
        "${REPO_ROOT}/scripts" \
        "${REPO_ROOT}/discord-bot" \
        "${REPO_ROOT}/tests"/*.bats 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo "Found non-portable 'grep -P' usage:"
        echo "$matches"
        echo ""
        echo "grep -P (PCRE) fails on non-UTF-8 locales (Windows Git Bash default)."
        echo "Rewrite with grep -E, sed -nE, or bash [[ =~ ]]."
        false
    fi
}
```

**Scope — owned shell surface:**
- `scripts/` (all `.sh` files)
- `discord-bot/*.sh` (owned, not in `scripts/`)
- `tests/*.bats` (our BATS test files themselves — a `grep -P` in a test would fail on the same locales)

**Explicitly excluded:**
- `tests/bats/` — upstream BATS submodule, not ours to modify
- `.worktrees/` — transient worktree copies of the repo
- `docs/` — historical implementation plans legitimately reference `grep -P` in code blocks describing past state

The pattern `grep[[:space:]]+-[a-zA-Z]*P` matches `grep -P`, `grep -oP`, `grep -qP`, `grep -oEP`, and any similar flag combination. The guard test itself uses `grep -rnE` (ERE-only), so it is self-consistent — it does not rely on the thing it is checking for.

### Files changed

- `scripts/lib/data-fetch.sh` — 4 sites rewritten
- `scripts/agent-dispatch.sh` — 4 sites rewritten
- `tests/test_portability.bats` — new guard test

No changes to `scripts/check-test-prereqs.sh`, `CLAUDE.md`, or `.claude/skills/test/SKILL.md` — cbfc4a4 already cleaned those up correctly.

## Verification plan

1. **Primary regression** — on Windows Git Bash, default `LANG` (no override):
   ```
   ./tests/bats/bin/bats tests/test_data_fetch.bats
   ```
   Expected: all 11 tests pass (previously 5 failing).

2. **Full suite, Windows default locale:**
   ```
   ./tests/bats/bin/bats tests/
   ```
   Expected: green, including new `test_portability.bats`.

3. **Linux under C locale:**
   ```
   LC_ALL=C ./tests/bats/bin/bats tests/test_data_fetch.bats
   ```
   Expected: green (proves locale-independence, not just Windows-specific).

4. **Linters clean:**
   ```
   shellcheck scripts/*.sh scripts/lib/*.sh discord-bot/*.sh
   ```
   Expected: zero warnings.

5. **Guard self-test** — temporarily reintroduce one `grep -P` line somewhere in `scripts/`, run `./tests/bats/bin/bats tests/test_portability.bats`, confirm failure output points at the offending file:line. Revert.

6. **CI sanity** — existing GitHub Actions matrix (Ubuntu, `LANG=C.UTF-8`) should remain green; no functional change for it.

## Risk assessment

- **`agent-dispatch.sh:176/316/508`** — the triage-JSON extraction path has no BATS coverage. The rewrite is a mechanical swap with no semantic change (ERE and PCRE behave identically for this pattern). Risk is low; manual smoke-test by dispatching a triage event would provide additional confidence but is not strictly required.
- **`agent-dispatch.sh:569`** — branch-name parsing feeds PR-review issue-number resolution. The `sed -nE` rewrite is the same construct cbfc4a4 shipped for `config-vars.sh`. Risk is low.
- **`data-fetch.sh:49`** — the most significant behavioural change (bash regex replaces a grep+sed+tr pipeline). Covered by the 5 now-passing BATS tests. The simplified `${var//./\\.}` escape is sufficient because line 42's URL regex already constrains the character set.

## Open questions

None at time of writing. All three clarifying questions from the brainstorming session were resolved:
- Line 49: bash-native approach (agreed).
- Guard scope: `scripts/` + `discord-bot/*.sh` + `tests/*.bats` (expanded from initial lean of `scripts/` only after scope analysis).
- PCRE probe: not re-added; regression test is the mechanism, and it hard-fails.
