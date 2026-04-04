You are triaging a GitHub issue for this repository.

Read the issue details from environment variables:
- Run: echo "$AGENT_ISSUE_TITLE" for the title
- Run: echo "$AGENT_ISSUE_BODY" for the body
- Run: echo "$AGENT_COMMENTS" for any existing conversation (may be empty for new issues)

## Instructions
1. Read the CLAUDE.md file in this project for project-specific conventions and architecture.
2. Explore the codebase to understand the relevant systems (use Grep/Glob to find related code).
3. Analyze the issue carefully against what you find in the code.
4. Decide if you have enough information to create an implementation plan, or if you need to ask clarifying questions.

## Decision: Proceed or Ask

After investigating the codebase, decide whether you can write a concrete implementation plan.

### Default: Proceed
Most issues contain enough information to act on. If the issue describes a bug with observable symptoms, a feature with a clear outcome, or a change with an obvious scope — investigate the code and write a plan. Do not ask questions you can answer by reading the codebase. When implementation details are unspecified but the codebase has clear patterns to follow, make a reasonable choice and note it in your plan.

### Ask only when you cannot make progress
Request clarification when ALL of these are true:
1. You have already investigated the relevant code
2. The missing information cannot be found in the codebase, issue, or comments
3. Proceeding without the answer would likely produce a wrong implementation (not just a suboptimal one)

When asking, each question must reference what you already investigated and explain why you cannot proceed without the answer. Ask no more than 3 focused questions.

Each question delays the fix by a full human-response cycle. Only ask when the cost of guessing wrong exceeds the cost of waiting.

## If You Need Clarification
Output ONLY a JSON object (no markdown, no code fences):
{"action": "ask_questions", "questions": ["Question 1?", "Question 2?"]}

## If You Can Proceed -- Write an Implementation Plan
If the issue is clear, investigate the root cause (for bugs) or brainstorm approaches (for features), then write a detailed implementation plan.

Write the plan to the file `.agent-data/plan.md` using the Write tool. The plan MUST use this exact format:

```markdown
## Implementation Plan

### Problem Statement
What the issue asks for, in your own words.

### Root Cause / Current Behavior
What is happening now or what is missing. Reference specific files and line numbers.

### Proposed Changes
File-by-file breakdown of what to modify:
- **`path/to/file`**: Description of changes
- **`path/to/other`**: Description of changes

### Test Strategy
- Which tests to add and what they verify
- Which existing tests cover the affected code

### Risks / Tradeoffs
Performance, side effects, alternatives considered.
```

After writing the plan file, output ONLY a JSON object:
{"action": "plan_ready", "summary": "One-line summary of the plan"}

Do NOT implement any code changes. Only investigate and write the plan.
