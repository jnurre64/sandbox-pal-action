# Design Philosophy

Claude Agent Dispatch is an issue-to-PR orchestrator built on GitHub Actions and the Claude Code CLI. These are the design principles behind it and the use cases it's optimized for.

## What This Prioritizes

### Minimal Dependencies

The system runs on two things you likely already have: a GitHub repository and a Claude Code CLI installation. There are no third-party platform subscriptions or external SaaS services to configure on top — authentication uses your existing Anthropic credentials, either a Pro/Max subscription (for individual use) or a Console API key (required for team/commercial use). See [authentication.md](authentication.md) for which applies. The dependency chain is deliberately small — shell scripts, GitHub Actions, and the Claude Code CLI.

### Human Oversight at Key Decision Points

No code is written until a human approves the plan. The agent triages the issue, writes a detailed implementation plan, and posts it as an issue comment. A human reviews the plan, provides feedback or requests changes, and only then approves implementation. After implementation, the PR goes through standard code review with branch protection. This two-phase approval gate — plan review, then PR review — keeps humans in the decision loop without requiring them to babysit every step.

### Simplicity Over Abstraction

The system is a focused pipeline: issue in, pull request out. It uses GitHub's native primitives — labels, issue comments, pull requests, Actions workflows — rather than introducing its own orchestration layer, dashboard, or control plane. The state machine is visible directly in GitHub's UI: anyone on the team can see where every issue is in the pipeline without opening a separate tool.

### Configurability as a Starting Point

The default configuration works out of the box, but every layer is designed to be overridden. Prompts, tool allowlists, test gates, notification backends — all configurable per project. In standalone mode, you own all the files and can modify the dispatch logic itself. This is a starting point you shape to your workflow, not a locked-down platform.

### Async-First Workflow

The system is designed for asynchronous work. Label an issue, walk away, come back to a plan awaiting approval. The agent works your backlog while you focus on other things. Each run starts with fresh context — no long-running conversations that accumulate drift.

## Who This Is For

### Solo developers and small teams with more issues than hours

If your backlog grows faster than you can work through it, the agent handles the mechanical implementation while you focus on design, review, and priorities.

### Teams that need their code to stay on their infrastructure

The agent runs on your self-hosted runner. Code never leaves your machine — only LLM API calls cross the network boundary. There is no external service that clones, stores, or processes your repository.

### Projects that value review discipline over speed

The two-phase approval gate deliberately slows things down. If you want an agent that autonomously merges code without human review, this isn't designed for that. If you want an agent that prepares work for human judgment, it is.

## Working With Interactive Sessions

Claude Agent Dispatch is not a replacement for interactive Claude Code sessions — it's a complement. The two modes feed each other:

- **Brainstorm interactively** — use Claude Code to scope and outline an issue, explore the codebase, or work through a complex design decision. Then write a clear issue and hand it off to the agent.
- **Agent works your backlog** — well-defined issues (features, bug fixes, tests, documentation) are the agent's sweet spot. It works them asynchronously with pre-configured tool boundaries.
- **Swap back when needed** — for complex troubleshooting or architectural work that requires back-and-forth judgment, open an interactive session with the full issue and PR history as context.

A focused pipeline: issue in, pull request out. Use it alongside whatever else is in your workflow.
