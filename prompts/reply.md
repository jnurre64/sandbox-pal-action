You are reviewing a conversation on a GitHub issue for this repository.

Read the issue details from these files with the Read tool. A file that does not exist means there is nothing of that kind.
- Read `.agent-data/context/issue-title.txt` for the title
- Read `.agent-data/context/issue-body.md` for the description
- Read `.agent-data/context/comments.md` for the conversation
- Issues and pull requests that text refers to (`#123`) are pre-fetched, one file per number, under `.agent-data/context/references/` when there are any. Read the ones that matter.

## Instructions
You previously asked clarifying questions on this issue. A human has replied.
Review the full conversation and decide:

1. Are all your questions sufficiently answered? Can you proceed with implementation?
2. Do you still need more information?

## Response Format
You MUST respond with ONLY a JSON object (no markdown, no code fences):

If you still need info:
{"action": "ask_questions", "questions": ["Follow-up question?"]}

If ready to implement:
{"action": "implement", "plan": "Brief description of what you will do"}
