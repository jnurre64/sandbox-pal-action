# Adversarial review prompts need stronger JSON-only reinforcement

> **Status:** Draft — file as issue on `jnurre64/claude-agent-dispatch`. Complementary to the parser fix in `fix/review-gates-json-preamble-parse`.

## Summary

`prompts/adversarial-plan.md` and `prompts/post-impl-review.md` both end with a `## Rules` section containing:

> Output ONLY a JSON object. No markdown, no code fences, no extra text.

Fresh Claude sessions running Gate A and Gate B **do not reliably follow this directive** when they have findings they want to explain. The model's natural instinct is to narrate its verification work before delivering a verdict — especially when the plan passes, because there's no obvious "problem" to report and the JSON feels like an afterthought.

## Observed output shapes

Two different Webber #59 Gate A runs, both against the same plan, both ultimately approving:

**Run 1 (first attempt):**
```
I've now verified all key claims in the plan against the actual codebase. Let me summarize my findings:

**Verified claims:**
- main.gd:start_round() lines 302-303: ... — confirmed
- line_drawer.gd:exit_build_mode() lines 3732-3742: ... — confirmed
- [8 more verified claims]

**No issues found.** The plan correctly identifies the root cause ...

{"action": "approved"}
```

**Run 2 (after parser fix merged):**
```
All assumptions verified. The plan is correct.

{"action": "approved"}
```

Both cases wrap the JSON in preamble. The parser now extracts the JSON regardless (see `fix/review-gates-json-preamble-parse`), but the parser fallback is best-effort — a belt/suspenders prompt change would make the JSON-only format more reliable upstream and reduce parser load.

## Why the current prompt fails

The rules section is **after** a long set of instructions (Step 1–5) that asks the model to read the issue, read the plan, evaluate against 5 criteria, and decide. By the time the model reaches the end, it has a lot of context it wants to demonstrate it used, and a single sentence in a `## Rules` section isn't strong enough to override "show your work" instincts.

Specifically:

1. The instructions ask for explicit criteria-by-criteria reasoning (Steps 4.1–4.5). Models that follow this faithfully end up with pages of analysis.
2. Step 5 decides the action but doesn't explicitly say "and nothing else."
3. The rules section says "no extra text" but doesn't show an example of the *entire* response (which would include nothing but the JSON).

## Proposed changes

### 1. Move the JSON-only rule to the top of the prompt

```markdown
You are an independent reviewer ...

## Output Format — CRITICAL

Your ENTIRE response must be exactly one JSON object and nothing else.
Do not include:
- A preamble ("I've verified all claims...")
- A summary of your findings
- Markdown code fences
- Trailing commentary

If you want to explain your reasoning, put it in the JSON as a "reasoning" field.
(The dispatcher ignores unknown fields — it will not affect the outcome.)

Example of a complete, valid response:

    {"action": "approved"}

Example of an INVALID response (the narrative prefix will fail parsing in some runners):

    I verified the plan and found no issues.

    {"action": "approved"}

## Issue Context
...
```

### 2. Add a "reasoning" field to the schema

Give the model a legitimate place to express its analysis without breaking the parser:

```json
{
  "action": "approved",
  "reasoning": "Verified main.gd:302, line_drawer.gd:3732, _perform_build_action logic. All claims match the codebase."
}
```

The dispatcher's jq lookup for `.action` still works; the `reasoning` field is available for debugging / logs but doesn't need parsing.

### 3. Apply the same changes to `post-impl-review.md` and `post-impl-retry.md`

All three prompts share the output-format problem.

## Out of scope

- Changing the parser. The parser fix in `fix/review-gates-json-preamble-parse` handles noisy output robustly; prompt changes are additive defense in depth, not a replacement.
- Structured outputs via the Anthropic API. The dispatch script uses `claude -p` which doesn't expose structured output mode. If it ever does, that would eliminate the prompt-following problem entirely.

## Evidence

- Parser fix PR: `fix/review-gates-json-preamble-parse` (merged)
- Observed runs: Webber #59 runs `24280140216` and `24280942202`
- Both narrative shapes captured in the regression tests in `tests/test_review_gates.bats` (`REGRESSION Gate A: approved JSON with narrative preamble (Webber #59)`)
