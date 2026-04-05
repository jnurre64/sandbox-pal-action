# Auto-Detect Plan Completeness for Triage Routing

## Summary

Enhance the triage phase to auto-detect when an issue already contains a complete implementation plan and suggest (or automatically apply) the `agent:implement` flow instead of full triage.

## Problem

Currently, the user must choose upfront which label to apply:
- `agent` — full triage: explore codebase, ask questions, write plan, wait for approval
- `agent:implement` — skip triage: validate existing plan, proceed to implementation

This works well when the user knows their issue contains a complete plan. But there are cases where the boundary is unclear:

1. **User forgets `agent:implement` exists** — adds `agent` to a fully-planned issue, wasting a triage cycle
2. **Issue has a partial plan** — detailed enough to skip some triage work, but maybe not enough for direct implementation
3. **New users** — don't know about the `agent:implement` option

## Proposed Enhancement

When the `agent` label is added and triage begins, the agent could detect plan completeness indicators in the issue body before doing full exploration:

### Detection Signals (strong → weak)

1. **Structured plan sections**: Issue body contains headers like "Implementation Plan", "Proposed Changes", "Files to Modify", "Test Strategy" — the same structure the triage prompt would produce
2. **Referenced spec files**: Issue body mentions committed spec files (e.g., `docs/superpowers/specs/...`)
3. **File-by-file breakdown**: Issue lists specific files with specific changes
4. **Code blocks with implementation details**: Actual code snippets showing what to write
5. **Phase/task numbering**: Numbered implementation phases or tasks with concrete steps

### Behavior Options

Three possible approaches, from most to least automated:

**(A) Auto-route (most aggressive):**
If the issue body scores high enough on plan completeness signals, automatically switch from triage to the `agent:implement` flow (validate → implement). Set `agent:validating` label instead of `agent:triage`.

- **Pro**: Zero friction for well-planned issues
- **Con**: Could misread a detailed bug report as a plan; false positives waste implementation cycles on incomplete plans
- **Risk**: Medium — validation pass catches most false positives, but still burns a Claude invocation

**(B) Suggest and ask (recommended):**
During triage, if the agent detects a complete plan, it outputs a modified response:
```json
{"action": "plan_detected", "summary": "This issue appears to contain a complete implementation plan. Recommend using agent:implement for direct implementation."}
```
The dispatch script posts a comment suggesting the user re-label with `agent:implement` and sets `agent:needs-info`.

- **Pro**: Human stays in the loop; no false positive risk
- **Con**: Adds a round-trip (agent suggests → human re-labels → agent validates)
- **Risk**: Low

**(C) Triage with shortcuts:**
The triage prompt is modified to recognize existing plans. Instead of writing a new plan, the agent validates the existing one and outputs `plan_ready` immediately — posting the user's plan (possibly lightly edited) as the agent plan comment.

- **Pro**: Stays within the existing `agent` flow; no new labels needed
- **Con**: Still runs full triage tools and exploration; plan_ready triggers the human approval step (which is redundant since the human wrote the plan)
- **Risk**: Low but less efficient than `agent:implement`

### Recommendation

**Option B (suggest and ask)** for the initial implementation. It's the safest and builds on the existing `agent:implement` infrastructure without modifying the triage flow. Can graduate to Option A later after observing detection accuracy in practice.

### Detection Implementation

Could be implemented as:
1. **Pre-triage check in the dispatch script**: Before running the triage prompt, do a lightweight text scan of the issue body for plan indicators. If detected, post a suggestion comment instead of running triage. No Claude invocation needed.
2. **In the triage prompt itself**: Add instructions to the triage prompt to recognize existing plans early and output a `plan_detected` action. Requires a Claude invocation but produces better detection.

Option 1 is cheaper (no API call) but brittle (regex matching). Option 2 is more accurate but costs a triage invocation.

A hybrid could work: lightweight regex pre-check in the script, and if it matches, run a short validation-only prompt instead of full triage.

## Scope

- Only affects the `agent` label flow — `agent:implement` continues to work as-is
- Detection should err on the side of false negatives (let triage run normally) rather than false positives (incorrectly skipping triage)
- Should be configurable: `AGENT_AUTO_DETECT_PLAN=true|false` (default: depends on chosen option)

## Prior Art

The `agent:implement` feature (merged 2026-04-05) established the validate → implement pipeline. This enhancement would make that pipeline discoverable automatically rather than requiring the user to know about it upfront.

Motivating case: Frightful-Games/Webber#96 — a fully brainstormed 6-phase implementation plan that would have been better served by `agent:implement` but was initially dispatched with `agent` before the feature existed.
