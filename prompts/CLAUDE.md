# Prompts

Default agent prompts for each dispatch phase. Each prompt is passed to `claude -p` via the `load_prompt` function in `scripts/lib/common.sh`.

## Prompt-to-Phase Mapping

| Prompt | Dispatch Phase | Tools | Purpose |
|--------|---------------|-------|---------|
| `triage.md` | `new_issue` | Read-only | Analyze issue, output questions or write plan to `.agent-data/plan.md` |
| `reply.md` | `issue_reply` | Read-only | Evaluate if clarifying questions are answered |
| `implement.md` | `implement` | Read-write | Execute approved plan using TDD |
| `review.md` | `pr_review` | Read-write | Address PR review feedback with targeted fixes |

## Output Format Convention

Triage and reply prompts MUST output a JSON object (no markdown, no code fences) with an `action` field. The dispatch script parses this to determine the next state transition. Implementation and review prompts output plain text summaries.

## Custom Prompts

Projects can override any prompt via `AGENT_PROMPT_*` settings in `config.env`. Relative paths resolve against the config directory. See `docs/customization.md`.
