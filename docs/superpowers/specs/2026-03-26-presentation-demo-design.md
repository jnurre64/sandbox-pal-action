# Presentation & Demo Design Spec

**Title:** Claude Agent Dispatch: An Open-Source Agent Orchestrator Built on GitHub Actions

**Date:** April 2, 2026 (Wednesday)

**Format:** 30-minute virtual presentation with screenshare, live demo, and Q&A

**Audience:** Engineers familiar with GitHub Actions, CI/CD, and Claude Code/AI coding agents

**Goal:** Introduce autonomous agent orchestration with human-in-the-loop guardrails, demonstrate the full issue-to-PR lifecycle live, show cross-project flexibility, and invite open-source adoption.

---

## Presentation Tool

**Slidev** — Markdown-based, browser-presented slide deck. No Google Slides dependency. Supports Mermaid diagrams and code syntax highlighting natively.

---

## Slide Deck (~12 slides)

### 1. Title
- "Claude Agent Dispatch: An Open-Source Agent Orchestrator Built on GitHub Actions"
- Presenter name
- Repo URL: `github.com/jnurre64/claude-agent-dispatch`
- Disclaimer: *"This is an independent open-source project, not affiliated with or endorsed by Anthropic."*

### 2. The Problem
Three scenario bullets (one sentence each, presenter expands verbally):
- **The babysitting problem** — Manually shepherding Claude through each issue: paste context, wait, review, approve, wait, check...
- **The overnight backlog** — Three bugs come in overnight; you wake up to three issues, not three PRs.
- **The scale problem** — Claude Code is great for one task. What about a backlog of twenty?

### 3. What If?
Single vision statement: "A system that triages, plans, gets approval, implements, and handles review feedback — autonomously, on any project."

### 4. Label State Machine (progressive diagram)
Build step by step:
```
agent → agent:triage → agent:plan-review → agent:plan-approved → agent:in-progress → agent:pr-open
```
With branches: `agent:needs-info`, `agent:failed`, `agent:revision`

### 5. Architecture
Second layer showing the event flow:
```
GitHub Event → Caller Workflow → Reusable Workflow → Dispatch Script → Claude Code CLI
                                                            ↑
                                                     Discord Bot (approve/feedback)
                                                     via repository_dispatch
```

### 6. Safety & Guardrails
Bullet points:
- Circuit breaker — halts after 8 bot comments/hour per issue
- Tool restrictions — phase-specific (read-only for triage, read-write for implementation)
- Actor filter — bot's own actions don't re-trigger workflows
- Two-phase approval — human reviews plan before any code is written
- Concurrency groups — one agent job per issue at a time
- Timeouts — configurable per-job

### 7. How Is This Different?
Three-column comparison table (Copilot Coding Agent / OpenClaw / Claude Agent Dispatch):

| | Copilot Coding Agent | OpenClaw | Claude Agent Dispatch |
|---|---|---|---|
| **Type** | GitHub's built-in agent | General-purpose AI assistant | Issue-to-PR orchestrator |
| **Open source** | No | Yes | Yes |
| **Self-hosted** | No (SaaS only) | Yes | Yes |
| **Auth model** | GitHub subscription + premium requests | Any LLM API key + hosting | Claude Code CLI (Pro/Max subscription) |
| **Human approval gate** | No | N/A for coding | First-class (two-phase) |
| **Customization** | GitHub's pipeline or nothing | 13k+ skills, 24+ channels | Custom prompts, tools, test gates |
| **Data sovereignty** | Code on GitHub's infra | Your infra | Your infra |
| **Complexity** | Low (built-in) | High (full assistant platform) | Low (shell scripts + GitHub Actions) |

Speaker notes cover Devin, Open SWE, SWE-agent as Q&A ammunition.

### 8. Demo Transition
"Let's see it in action."

### 9. (Demo happens — no slides)

### 10. Cross-Project Transition
"Same system, different project."

### 11. (Godot cameo — no slides)

### 12. Getting Started
Three steps:
```bash
git clone https://github.com/jnurre64/claude-agent-dispatch.git ~/agent-infra
cd ~/agent-infra
claude  # then type: /setup
```
Reference mode vs standalone mode — one sentence each.

### 13. Open Source + Close
- Repo URL + QR code if possible
- What's coming next (Slack integration, channel-based architecture)
- How to contribute
- Thank you + Q&A

---

## Demo Repos

### Primary: .NET Recipe Manager

**Stack:** .NET 9 (Razor Pages or minimal API + simple frontend)

**MVP features (pre-built):**
- Recipe model: name, description, ingredients, instructions
- CRUD pages: list, add, view, edit, delete
- Simple clean UI — functional, not fancy
- SQLite or in-memory database for simplicity

**Agent-dispatch config:** Standalone mode with Discord bot connected.

### Secondary: Godot dodge_the_creeps

**Source:** Fork of `godotengine/godot-demo-projects` (MIT licensed), using `2d/dodge_the_creeps`

**Pre-staged feature:** One completed PR with a visually obvious addition (power-up, particle effects, or difficulty scaling)

**Agent-dispatch config:** Standalone mode with Discord bot connected.

### Setup Speed Run Repo

Clone of the .NET recipe app to a separate repo with all agent-dispatch files stripped out. Used only for the `/setup` speed run at the end.

---

## Pre-Staged Issues (.NET Recipe App)

| Issue | Feature | Lifecycle State | Purpose in Demo |
|---|---|---|---|
| #1 | Add dark mode toggle | Fresh (no labels) | Live kick-off: label `agent`, show triage start + Discord notification |
| #2 | Add recipe rating | `agent:plan-review` with completed plan | Pre-staged plan: approve via Discord live |
| #3 | Add favorites | `agent:plan-review` with feedback | Pre-staged feedback: Request Changes via Discord, show revised plan |
| #4 | Add search/filter | `agent:pr-open` with merged PR | Pre-staged result: walk through code, show feature in app |

---

## Demo Flow (~12-15 min)

### Main demo (recipe app)

| Step | Action | What audience sees | Time |
|---|---|---|---|
| 1 | Browse the recipe app | Working web app with basic CRUD | 30s |
| 2 | Open "Add dark mode toggle" issue | Clean issue with description | 15s |
| 3 | Add `agent` label | Label appears | 10s |
| 4 | Show GitHub Actions | Workflow starts running | 15s |
| 5 | Switch to Discord | Notification arrives with buttons | 15s |
| 6 | Cooking show pivot | "While that's working, let me show you the next stage" | 5s |
| 7 | Open "Add recipe rating" issue | Pre-staged plan comment | 45s |
| 8 | Click Approve in Discord | Confirmation, workflow triggers in Actions tab | 30s |
| 9 | Open "Add favorites" issue | Another pre-staged plan | 15s |
| 10 | Click Request Changes in Discord | Modal, type feedback, posted as comment | 30s |
| 11 | Show revised plan | Pre-staged revision incorporating feedback | 30s |
| 12 | Open "Add search/filter" PR | PR with code diff, commits, tests | 60s |
| 13 | Show search/filter in the app | Live feature working in browser | 30s |
| 14 | Check back on dark mode triage | Plan may have been posted while demoing | 30s |

### Godot cameo (~60-90s)

| Step | Action | What audience sees |
|---|---|---|
| 15 | Open Godot repo, show completed PR | PR diff with GDScript changes |
| 16 | Run game before and after | Visual difference — new feature visible |
| 17 | "Zero code changes to the dispatch system" | Flexibility message lands |

### Setup speed run (~60-90s)

| Step | Action | What audience sees |
|---|---|---|
| 18 | `cd` into clean clone repo, open Claude, type `/setup` | Setup skill starts |
| 19 | Answer 2-3 prompts | Interactive setup flow |
| 20 | Cut short — "about 5 minutes total" | Audience sees easy onboarding |

---

## Positioning Against Alternatives

### On the comparison slide (3-column table)

**GitHub Copilot Coding Agent:**
- SaaS-only, no self-hosting, no model choice, no customizable workflows
- No human approval gate before implementation
- Premium request quotas ($0.04/extra after 300/month)
- Your code processed on GitHub's infrastructure

**OpenClaw:**
- General-purpose AI assistant platform (messaging, calendar, email, voice) — not purpose-built for issue-to-PR
- Complex setup for a simple workflow — freight train when you need a bicycle
- Forced rename from "Clawdbot" due to Anthropic trademark issues
- 250k+ stars, 24+ messaging channels, 13k+ skills — massive scope

**Claude Agent Dispatch:**
- Purpose-built for issue-to-PR orchestration
- Human approval gate is first-class (two-phase plan/implement)
- Uses existing Claude Pro/Max subscription — no additional API costs
- Self-hosted, your code stays on your infrastructure
- Simple: shell scripts + GitHub Actions + label state machine

### Q&A ammunition (speaker notes only)

**Devin:** Closed-source SaaS, $20-500/month, zero control over internals, code goes to Cognition's servers.

**Open SWE (LangChain):** Closest open-source competitor. Label-triggered, plans and opens PRs. But tightly coupled to LangGraph ecosystem, no built-in human approval gate.

**SWE-agent:** Research tool for benchmarks, not a production workflow. One-shot solver, no orchestration lifecycle.

---

## Speaker Notes Document

A separate Markdown file with:
- 2-3 expanded talking points per slide
- The three scenario narratives for slide 2 (babysitting, overnight, scale) with full storytelling versions the presenter can draw from
- Alternative comparison deep-dives for Q&A
- Transition phrases between slides and demo segments
- Fallback pivot lines for demo failures

---

## Dry Runs & Rehearsal Plan

### Dry Run 1: Technical Verification (Saturday)
- Verify all pre-staged issues in correct states with right labels
- Run through full demo flow end-to-end, hitting every step
- Time each segment with a stopwatch
- Verify .NET app, Discord bot, GitHub Actions all work
- Verify Godot game runs before/after
- Verify setup speed run repo is clean and `/setup` works
- **Goal:** Find and fix technical issues. Mechanics only.

### Dry Run 2: Full Rehearsal (Sunday)
- Present entire talk out loud, slides + demo, timer visible
- Practice transitions: slides → demo → Discord → back to slides
- Practice cooking show pivot line
- Practice fallback line for demo failures
- Note which segments run long/short, adjust
- **Goal:** Hit 25-minute mark (leaving 5 for Q&A). Identify what to cut.

### Dry Run 3: Final Check (Wednesday, 1 hour before)
- Restart Discord bot, verify connection
- Verify no other agent jobs running on self-hosted runner
- Open all browser tabs in presentation order
- Test one `gh api repos/.../dispatches` call
- Test screenshare on actual meeting platform
- **Goal:** Everything warm and ready.

### Fallback Materials (prepared Sunday)
- Screenshots of each demo stage as hidden backup slides at end of deck
- Optional: 3-minute screen recording of full demo flow from Dry Run 2

---

## Prep Timeline

| When | What |
|---|---|
| **Thursday 3/26** | Finalize and commit design spec. Start .NET recipe app MVP. |
| **Friday 3/27** | Finish .NET app. Fork dodge_the_creeps. Configure agent-dispatch on both repos. |
| **Saturday 3/28** | Run agent on all demo issues to generate authentic plans/PRs. Pre-stage lifecycle states. Build Slidev deck and speaker notes. **Dry Run 1.** |
| **Sunday 3/29** | Prepare setup speed run repo. Build fallback screenshots. Polish slides. **Dry Run 2.** |
| **Monday-Tuesday 3/30-31** | Buffer for fixes, re-staging issues, slide tweaks. |
| **Wednesday 4/1 morning** | **Dry Run 3** (1 hour before). Present. |

---

## Legal / Trademark

- **Anthropic/Claude:** Non-affiliation disclaimer on README (done) and title slide. Nominative fair use — accurately describes what the project uses.
- **Godot:** MIT licensed demo projects. Keep LICENSE file in fork. Permitted community content use.
- **.NET/Microsoft:** Standard factual reference. No issues.
- **GitHub:** Standard tech presentation practice.
- **Discord:** Bot not named with "Discord." Showing own bot in demo is fine.
