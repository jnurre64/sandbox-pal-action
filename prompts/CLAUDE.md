# Prompts

Default agent prompts for each dispatch phase. Each prompt is passed to `claude -p` via the `load_prompt` function in `scripts/lib/common.sh`.

## Prompt-to-Phase Mapping

| Prompt | Dispatch Phase | Tools | Purpose |
|--------|---------------|-------|---------|
| `triage.md` | `new_issue` | Read-only | Analyze issue, output questions or write plan to `.agent-data/plan.md` |
| `reply.md` | `issue_reply` | Read-only | Evaluate if clarifying questions are answered |
| `implement.md` | `implement` | Read-write | Execute approved plan using TDD |
| `review.md` | `pr_review` | Read-write | Address PR review feedback with targeted fixes |
| `validate.md` | `direct_implement` | Read-only | Validate pre-written plan against codebase |
| `adversarial-plan.md` | `implement` (pre-gate) | Read-only | Fresh-session adversarial review of plan vs issue |
| `post-impl-review.md` | `implement` (post-gate) | Read-only | Fresh-session review of diff vs issue/plan |
| `post-impl-retry.md` | `implement` (retry) | Read-write | Address post-impl review concerns |

## Output Format Convention

Triage and reply prompts MUST output a JSON object (no markdown, no code fences) with an `action` field. The dispatch script parses this to determine the next state transition. Implementation and review prompts output plain text summaries.

## Custom Prompts

Projects can override any prompt via `AGENT_PROMPT_*` settings in `config.env`. Relative paths resolve against the config directory. See `docs/customization.md`.
