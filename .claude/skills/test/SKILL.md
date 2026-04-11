---
name: test
description: Use when running tests, verifying code changes, or before commits/PRs in this repository. Checks prerequisites, runs ShellCheck and BATS, categorizes results.
user-invocable: true
---

# Test: Run ShellCheck and BATS with Prerequisite Detection

Run the project test suite with prerequisite checking and platform-aware result interpretation.

## Step 1: Check Prerequisites

Run the prerequisite detection script:

```bash
bash ${CLAUDE_SKILL_DIR}/../../../scripts/check-test-prereqs.sh
```

If any tools are missing:
- Show the user what's missing and the install commands from the script output
- Ask if they want you to run the install commands or if they'll do it manually
- Do NOT proceed to Steps 2-3 until prerequisites pass

## Step 2: Run ShellCheck

Run ShellCheck on all shell scripts:

```bash
shellcheck scripts/*.sh scripts/lib/*.sh
```

**Windows CRLF fallback:** If you see SC1017 errors ("Expected a function name but found end of line"), the files have CRLF line endings. Fix by running:

```bash
git add --renormalize . && git checkout -- .
```

Then re-run shellcheck.

## Step 3: Run BATS Tests

Run the full test suite:

```bash
./tests/bats/bin/bats tests/
```

## Step 4: Interpret Results

If Step 1 passed (all prerequisites met), all tests should pass. Any failure is a real regression — investigate it.

If tests fail with errors about `jq`, `shellcheck`, `grep -P`, or `bats`, re-run Step 1 — a prerequisite is missing.

## Step 5: Report Summary

Report results in this format:

```
ShellCheck: PASS (N files checked)
BATS: X/Y tests passed. Z skipped. N known platform limitations. M real failures.
```

If there are real failures, list each one with the test name and error output.
