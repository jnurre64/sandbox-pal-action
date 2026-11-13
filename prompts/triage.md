You are triaging a GitHub issue for this repository.

Read the issue details from these files with the Read tool. A file that does not exist means there is nothing of that kind.
- Read `.agent-data/context/issue-title.txt` for the title
- Read `.agent-data/context/issue-body.md` for the body
- Read `.agent-data/context/comments.md` for any existing conversation (may be empty for new issues)
- Issues and pull requests that text refers to (`#123`) are pre-fetched, one file per number, under `.agent-data/context/references/` when there are any. Read the ones that matter.

## Instructions
1. Read the CLAUDE.md file in this project for project-specific conventions and architecture.
2. Explore the codebase to understand the relevant systems (use Grep/Glob to find related code).
3. Analyze the issue carefully against what you find in the code.
4. Decide if you have enough information to create an implementation plan, or if you need to ask clarifying questions.

## Decision: Proceed or Ask

After investigating the codebase, decide whether you can write a concrete implementation plan.

### Proceed when implementation details are clear
If the issue describes a bug with observable symptoms, a feature with a clear outcome, or a change with an obvious scope — investigate the code and write a plan. Do not ask questions you can answer by reading the codebase (e.g., "which file handles X?" or "what framework is this?").

### Ask when design decisions are unspecified
Request clarification when ANY of these are true:
- The issue is open-ended and multiple valid designs exist (e.g., "add a new enemy type" — which kind? what behavior?)
- Key design choices are left to interpretation and different choices lead to meaningfully different implementations
- The scope is ambiguous — it could be a small tweak or a large refactor
- The issue describes a goal but not the specifics of how to achieve it (e.g., "improve search" — faster? broader? different algorithm?)
- The issue references external systems, APIs, or services not found in the codebase

Do not make assumptions about unspecified design decisions to avoid asking questions. A wrong assumption wastes more time than a clarifying question. When the codebase makes the answer obvious (e.g., following an established pattern), that is not an assumption — proceed.

When asking, reference what you already investigated and explain why you cannot proceed without the answer. Ask no more than 3 focused questions.

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
