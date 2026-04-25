<p align="center">
  <img src=".github/icon.png" width="200" alt="Sandbox Pal Action">
</p>

<h1 align="center">Sandbox Pal Action</h1>

<p align="center">
  <a href="https://github.com/jnurre64/sandbox-pal-action/actions/workflows/ci.yml"><img src="https://github.com/jnurre64/sandbox-pal-action/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/jnurre64/sandbox-pal-action/releases/latest"><img src="https://img.shields.io/github/v/release/jnurre64/sandbox-pal-action" alt="Latest Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
</p>

A reusable dispatch system for running AI coding agents on GitHub issues — triaging, planning, implementing, and addressing PR review feedback, all orchestrated through GitHub Actions and a label-driven state machine.

> **Independent, community-built project.** Not affiliated with, endorsed by, or sponsored by Anthropic, PBC. "Claude" and "Claude Code" are trademarks of Anthropic; this project uses Claude Code as its underlying agent and references these trademarks solely to describe that functionality.

## Features

- **No third-party platform layers** — runs on the official Claude Code CLI and GitHub Actions, with no additional SaaS dependencies on top. Authenticate Claude Code on the runner however fits your use — the dispatch scripts do not prescribe a method; see [authentication.md](docs/authentication.md).
- **Low complexity, fast setup** — a small dependency chain (shell scripts, GitHub Actions, Claude Code CLI). Configure and deploy in about 5 minutes with the `/setup` skill.
- **Two-phase human approval** — the agent writes a plan and waits for your approval before writing any code. You stay in control of what gets built.
- **Async by default** — label an issue before bed, wake up to a plan awaiting approval. Brainstorm a new issue while the agent works on an existing one.
- **Fresh context every session** — no long-running conversations that drift. Each agent run loads just what it needs from the issue, codebase, and project context.
- **Deeply configurable** — override prompts per phase, tune tool allowlists, set test gates, add project-specific tools. Designed as a starting point you shape to your workflow.

This system supplements interactive Claude Code sessions — it doesn't replace them. Use interactive mode to brainstorm, investigate, and draft issues. Hand off well-defined work to an agent by labeling the issue, then continue your next interactive session while the agent works in the background. When the agent opens a PR, reference its changes in your interactive sessions to build on its work.

## How It Works

When you label a GitHub issue with `agent`, the system:

1. **Triages** the issue — reads your project's CLAUDE.md, explores the codebase, asks clarifying questions if needed
2. **Plans** — writes a detailed implementation plan and posts it as an issue comment for human review
3. **Implements** (after plan approval) — follows TDD to make changes, commits per cycle
4. **Creates a PR** — runs tests, pushes the branch, opens a PR with a summary
5. **Addresses review feedback** — when a reviewer requests changes, the agent reads the feedback and pushes fixes
6. **Cleans up** — stale branches, orphaned gists, old workflow runs (on a schedule)

### Label State Machine

```
agent ──> agent:triage ──> agent:plan-review ──> agent:plan-approved ──> agent:in-progress ──> agent:pr-open
               │                  │                                              │
               v                  v                                              v
         agent:needs-info   agent:needs-info                              agent:failed
          (asks questions)   (feedback on plan)
```

On PR review with changes requested: `agent:pr-open` → `agent:revision` → `agent:pr-open`

With `agent:implement` (skip triage): `agent:implement` → `agent:validating` → `agent:in-progress` → `agent:pr-open`

### Safety

Built-in protections at every layer: circuit breaker (8 bot comments/hour), phase-specific tool restrictions, actor filters to prevent self-triggering, concurrency groups, configurable timeouts, and two-phase dispatch ensuring human review before any code is written. See [docs/security.md](docs/security.md) for the full threat model.

> **Data privacy:** Issue content is sent to the Anthropic API for inference. Never put secrets, API keys, or PII in GitHub issues. See [docs/security.md](docs/security.md#data-privacy) for details.

## Quick Start

### Prerequisites

- A GitHub repository you want to add agent capabilities to
- A self-hosted GitHub Actions runner with:
  - [Claude Code CLI](https://claude.com/claude-code) installed
  - Claude Code CLI authenticated on the runner — see [authentication.md](docs/authentication.md)
  - `gh` CLI authenticated, `git`, `jq`, `curl`
- A dedicated [bot GitHub account](docs/bot-account.md) with a fine-grained PAT

### Setup (2 options)

**Option A: Claude-assisted (recommended)**

```bash
git clone https://github.com/jnurre64/sandbox-pal-action.git ~/agent-infra
cd ~/agent-infra
claude  # then type: /setup
```

The `/setup` skill walks you through everything interactively.

**Option B: Shell script**

```bash
git clone https://github.com/jnurre64/sandbox-pal-action.git ~/agent-infra
cd ~/agent-infra
./scripts/setup.sh
```

Both options will:
1. Ask for your repo, bot account, and preferences
2. Generate a `config.env` with your settings
3. Create the agent labels on your repo
4. Generate workflow files for your repo
5. Guide you through setting GitHub Actions secrets

### Setup Modes

| Mode | How it works | Best for |
|------|-------------|----------|
| **Standalone** (recommended) | All scripts, prompts, and workflows copied into your repo under `.sandbox-pal-dispatch/` | Most users — full control, per-repo isolation |
| **Reference** | Thin workflow files in your repo call reusable workflows from this repo via `@v1` tags | Advanced users who want automatic updates |

### Test It

After setup, create a test issue on your repo and add the `agent` label. Watch the agent triage it, write a plan, and wait for your approval.

## Configuration

All settings live in `config.env` (or `.sandbox-pal-dispatch/config.env` for standalone mode). Key options:

| Setting | Default | Description |
|---------|---------|-------------|
| `AGENT_BOT_USER` | (required) | Bot account username |
| `AGENT_MAX_TURNS` | `200` | Max Claude conversation turns |
| `AGENT_TIMEOUT` | `3600` | Seconds before killing a stuck session |
| `AGENT_TEST_COMMAND` | (none) | Test command for pre-PR gate (e.g., `npm test`) |
| `AGENT_EXTRA_TOOLS` | (none) | Project-specific tools (e.g., `Bash(npm:*)`) |
| `AGENT_PROMPT_*` | built-in | Custom prompt file paths |

The system adapts to any project through your CLAUDE.md (coding conventions), custom prompts per phase, tool allowlists, and test gates. See [docs/configuration.md](docs/configuration.md) for the full reference and [docs/customization.md](docs/customization.md) for prompt and tool customization.

## Documentation

| Doc | Description |
|-----|-------------|
| [Getting Started](docs/getting-started.md) | Full walkthrough from zero to working agent |
| [Authentication](docs/authentication.md) | Runner authentication prerequisite and pointers to Anthropic's docs |
| [Architecture](docs/architecture.md) | How the dispatch system works |
| [Design Philosophy](docs/design-philosophy.md) | Design principles, target use cases, and workflow guidance |
| [FAQ](docs/faq.md) | Common questions about safety, privacy, costs, and usage |
| [Configuration](docs/configuration.md) | All settings and options |
| [Customization](docs/customization.md) | Prompts, tools, and project-specific setup |
| [Operations](docs/operations.md) | Logs, monitoring, retrying failed issues |
| [Bot Account](docs/bot-account.md) | Creating and configuring the bot GitHub account |
| [Runners](docs/runners.md) | Self-hosted runner setup |
| [Security](docs/security.md) | Threat model, safety mechanisms, security checklist |
| [Testing](docs/testing.md) | BATS test suite — 52 tests, regression coverage, writing new tests |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and solutions — use `/troubleshoot` for automated diagnostics |
| [Versioning](docs/versioning.md) | SemVer policy, release process, changelog conventions |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for conventions, testing, and how to submit changes. Bug reports and feature requests are welcome via [GitHub Issues](https://github.com/jnurre64/sandbox-pal-action/issues).

## Repository Structure

```
sandbox-pal-action/
├── scripts/
│   ├── sandbox-pal-dispatch.sh        # Main dispatch entry point
│   ├── cleanup.sh               # Scheduled cleanup (branches, gists, logs)
│   ├── setup.sh                 # Interactive setup wizard
│   ├── check-prereqs.sh         # Prerequisite validation
│   ├── create-labels.sh         # Batch label creation
│   └── lib/
│       ├── common.sh            # Logging, labels, circuit breaker, claude runner
│       ├── worktree.sh          # Git worktree management
│       ├── data-fetch.sh        # Gist and attachment pre-fetching
│       └── defaults.sh          # Default configuration values
├── prompts/
│   ├── triage.md                # Default triage + plan prompt
│   ├── implement.md             # Default TDD implementation prompt
│   ├── reply.md                 # Default reply handling prompt
│   ├── review.md                # Default PR review prompt
│   └── validate.md              # Default plan validation prompt
├── .github/workflows/
│   ├── sandbox-pal-triage.yml      # Reusable workflow: issue triage
│   ├── sandbox-pal-direct-implement.yml  # Reusable workflow: direct implement (skip triage)
│   ├── sandbox-pal-implement.yml   # Reusable workflow: plan implementation
│   ├── sandbox-pal-reply.yml       # Reusable workflow: reply handling
│   ├── sandbox-pal-review.yml      # Reusable workflow: PR review
│   ├── sandbox-pal-cleanup.yml     # Reusable workflow: scheduled cleanup
│   └── ci.yml                   # ShellCheck CI for this repo
├── .claude/skills/setup/        # /setup skill for Claude-assisted onboarding
├── config.env.example           # Configuration template
├── labels.txt                   # Label definitions for batch creation
├── CLAUDE.md                    # Claude Code instructions for this repo
└── docs/                        # Full documentation
```

## License

MIT
