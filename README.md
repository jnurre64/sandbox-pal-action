<p align="center">
  <img src=".github/icon.png" width="150" alt="Claude Agent Dispatch">
</p>
<h1 align="center">claude-agent-dispatch</h1>

A reusable dispatch system for running [Claude Code](https://claude.com/claude-code) agents on GitHub issues — autonomously triaging, planning, implementing, and addressing PR review feedback, all orchestrated through GitHub Actions and a label-driven state machine.

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

### Safety

- **Circuit breaker** — halts after 8 bot comments/hour per issue (configurable)
- **Tool restrictions** — agents can only use explicitly allowed tools (no sudo, no network, no force push)
- **Actor filter** — bot's own actions don't re-trigger workflows
- **Concurrency groups** — one agent job at a time per issue/PR
- **Timeouts** — configurable per-job timeout prevents runaway sessions
- **Two-phase dispatch** — human reviews the plan before any code is written

> **Data privacy:** Issue content is sent to the Anthropic API for inference. Never put secrets, API keys, or PII in GitHub issues. See [docs/security.md](docs/security.md#data-privacy) for details.

## Quick Start

### Prerequisites

- A GitHub repository you want to add agent capabilities to
- A self-hosted GitHub Actions runner with:
  - [Claude Code CLI](https://claude.com/claude-code) installed
  - `ANTHROPIC_API_KEY` environment variable set
  - `gh` CLI authenticated, `git`, `jq`, `curl`
- A dedicated [bot GitHub account](docs/bot-account.md) with a fine-grained PAT

### Setup (2 options)

**Option A: Claude-assisted (recommended)**

```bash
git clone https://github.com/jnurre64/claude-agent-dispatch.git ~/agent-infra
cd ~/agent-infra
claude  # then type: /setup
```

The `/setup` skill walks you through everything interactively.

**Option B: Shell script**

```bash
git clone https://github.com/jnurre64/claude-agent-dispatch.git ~/agent-infra
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
| **Reference** | Thin workflow files in your repo call reusable workflows from this repo via `@v1` tags | Users who want automatic updates |
| **Standalone** | All scripts, prompts, and workflows copied into your repo under `.agent-dispatch/` | Users who want full control and no upstream dependency |

### Test It

After setup, create a test issue on your repo and add the `agent` label. Watch the agent triage it, write a plan, and wait for your approval.

## Configuration

All settings live in `config.env` (or `.agent-dispatch/config.env` for standalone mode). Key options:

| Setting | Default | Description |
|---------|---------|-------------|
| `AGENT_BOT_USER` | (required) | Bot account username |
| `AGENT_MAX_TURNS` | `200` | Max Claude conversation turns |
| `AGENT_TIMEOUT` | `3600` | Seconds before killing a stuck session |
| `AGENT_TEST_COMMAND` | (none) | Test command for pre-PR gate (e.g., `npm test`) |
| `AGENT_EXTRA_TOOLS` | (none) | Project-specific tools (e.g., `Bash(npm:*)`) |
| `AGENT_PROMPT_*` | built-in | Custom prompt file paths |

See [docs/configuration.md](docs/configuration.md) for the full reference.

## Customization

The system adapts to any project through:

- **CLAUDE.md** — your project's conventions file. The agent reads it for coding style, architecture, and guidelines.
- **Custom prompts** — override the default prompts to add project-specific instructions. See [docs/customization.md](docs/customization.md).
- **Tool allowlists** — control exactly what the agent can do via `AGENT_ALLOWED_TOOLS_*` and `AGENT_EXTRA_TOOLS`.
- **Test gate** — set `AGENT_TEST_COMMAND` to require passing tests before PR creation.

## Documentation

| Doc | Description |
|-----|-------------|
| [Getting Started](docs/getting-started.md) | Full walkthrough from zero to working agent |
| [Architecture](docs/architecture.md) | How the dispatch system works |
| [Configuration](docs/configuration.md) | All settings and options |
| [Customization](docs/customization.md) | Prompts, tools, and project-specific setup |
| [Operations](docs/operations.md) | Logs, monitoring, retrying failed issues |
| [Bot Account](docs/bot-account.md) | Creating and configuring the bot GitHub account |
| [Runners](docs/runners.md) | Self-hosted runner setup |
| [Security](docs/security.md) | Threat model, safety mechanisms, security checklist |
| [Testing](docs/testing.md) | BATS test suite — 52 tests, regression coverage, writing new tests |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and solutions |
| [Versioning](docs/versioning.md) | SemVer policy, release process, changelog conventions |

## How This Differs from claude-code-action

Anthropic's official [`claude-code-action`](https://github.com/anthropics/claude-code-action) is a GitHub Action for lightweight triggers — responding to `@claude` mentions or simple prompts on PRs. It's great for quick interactions.

**claude-agent-dispatch** is a full autonomous agent lifecycle system:
- Label-driven state machine with human checkpoints
- Two-phase plan/implement workflow (plan → review → approve → implement)
- Worktree isolation for concurrent issue handling
- Debug data pipeline (pre-fetches gists and attachments for Claude to analyze)
- Circuit breakers, tool restrictions, and safety mechanisms
- Configurable prompts, tools, and test gates per project
- Scheduled cleanup of stale branches, gists, and workflow runs

Use `claude-code-action` for quick PR interactions. Use this system for autonomous issue-to-PR workflows.

## Repository Structure

```
claude-agent-dispatch/
├── scripts/
│   ├── agent-dispatch.sh        # Main dispatch entry point
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
│   └── review.md                # Default PR review prompt
├── .github/workflows/
│   ├── dispatch-triage.yml      # Reusable workflow: issue triage
│   ├── dispatch-implement.yml   # Reusable workflow: plan implementation
│   ├── dispatch-reply.yml       # Reusable workflow: reply handling
│   ├── dispatch-review.yml      # Reusable workflow: PR review
│   ├── cleanup.yml              # Reusable workflow: scheduled cleanup
│   └── ci.yml                   # ShellCheck CI for this repo
├── .claude/skills/setup/        # /setup skill for Claude-assisted onboarding
├── config.env.example           # Configuration template
├── labels.txt                   # Label definitions for batch creation
├── CLAUDE.md                    # Claude Code instructions for this repo
└── docs/                        # Full documentation
```

## Disclaimer

Claude Agent Dispatch is an independent, community-built open-source project. It is not affiliated with, endorsed by, or sponsored by Anthropic, PBC. "Claude" and "Claude Code" are trademarks of Anthropic. This project uses Claude Code as its underlying agent and references these trademarks solely to describe that functionality.

## License

MIT
