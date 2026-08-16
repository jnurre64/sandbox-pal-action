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
