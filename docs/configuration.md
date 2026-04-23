# Configuration Reference

This document covers every configuration option in sandbox-pal-action, how values are loaded, and example configurations for different project types.

## Config Loading Order

Configuration values are resolved in this order, with earlier sources taking priority:

1. **Environment variables** set by the caller (e.g., in a workflow step or shell session)
2. **`config.env`** sourced by the dispatch script at startup
3. **`scripts/lib/defaults.sh`** fills in anything not already set (using `${VAR:-default}` syntax)

The dispatch script looks for `config.env` at the path specified by `AGENT_CONFIG`, which defaults to `~/agent-infra/config.env`. You can override this by setting `AGENT_CONFIG` in your environment before calling the dispatch script.

```bash
# The dispatch script does this internally:
AGENT_CONFIG="${AGENT_CONFIG:-$HOME/agent-infra/config.env}"
source "$AGENT_CONFIG"       # your project values
source lib/defaults.sh       # fills in gaps with defaults
```

To configure your project, copy `config.env.example` to your config path and edit it:

```bash
cp config.env.example ~/agent-infra/config.env
```

---

## Required Settings

### AGENT_BOT_USER

The GitHub username of the bot account that will comment on issues, push branches, and create PRs.

```bash
AGENT_BOT_USER="my-bot-account"
```

This has no default. The dispatch script will exit with an error if it is not set. It is used to:
- Filter the circuit breaker (count only this user's comments)
- Identify bot-authored comments when extracting debug data
- Prevent the agent's own label changes from re-triggering workflows (via the actor filter in your calling workflow)

---

## Optional Settings

### AGENT_MAX_TURNS

Maximum number of Claude conversation turns per invocation. A higher value allows more complex tasks but increases cost and runtime.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MAX_TURNS` | `200` | integer |

```bash
AGENT_MAX_TURNS=200
```

### AGENT_TIMEOUT

Timeout in seconds before the dispatch script kills a stuck `claude -p` process. If Claude does not finish within this window, the process is terminated and the issue is marked as failed.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TIMEOUT` | `3600` | integer (seconds) |

```bash
AGENT_TIMEOUT=3600   # 1 hour
```

### AGENT_CIRCUIT_BREAKER_LIMIT

Maximum number of bot comments allowed per hour on a single issue. If the limit is exceeded, the agent halts with `agent:failed` and posts a warning. This prevents infinite loops.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_CIRCUIT_BREAKER_LIMIT` | `8` | integer |

```bash
AGENT_CIRCUIT_BREAKER_LIMIT=8
```

### AGENT_MEMORY_FILE

Path to a shared Claude memory file. If set and the file exists, its contents are appended to the system prompt for every `claude -p` invocation via `--append-system-prompt`. This lets the agent benefit from context accumulated during interactive Claude Code sessions.

Supports two path modes:
- **Absolute path**: Resolves directly (e.g., `$HOME/.claude/projects/.../memory/MEMORY.md`)
- **Workspace-relative path**: Resolves against the worktree directory (e.g., `claude-work/shared-memory.md`)

Workspace-relative paths enable **committed memory files** — a curated knowledge file checked into the repository that syncs across machines via git. See the [Customization Guide](customization.md#shared-project-memory) for setup details.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MEMORY_FILE` | *(empty)* | file path (absolute or workspace-relative) |

```bash
# Option 1: Machine-local memory (from interactive sessions on this machine)
AGENT_MEMORY_FILE="$HOME/.claude/projects/-home-user-repos-myproject/memory/MEMORY.md"

# Option 2: Committed memory file (shared across machines via git) — recommended
AGENT_MEMORY_FILE="claude-work/shared-memory.md"
```

The agent reads this file but never writes to it. Only interactive sessions should manage memory content.

### AGENT_TEST_COMMAND

A shell command to run as a pre-PR test gate. If set, the dispatch script runs this command after implementation and before creating the PR. If the tests fail, the PR is not created and the issue is labeled `agent:failed`.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TEST_COMMAND` | *(empty, gate skipped)* | shell command |

```bash
# Node.js
AGENT_TEST_COMMAND="npm test"

# Python
AGENT_TEST_COMMAND="pytest"

# Rust
AGENT_TEST_COMMAND="cargo test"

# Go
AGENT_TEST_COMMAND="go test ./..."
```

The test command is also referenced in the implement and review prompts as `$AGENT_TEST_COMMAND`, so the agent can run tests during its TDD cycles.

### AGENT_EFFORT_LEVEL

The Claude Code effort level for all agent runs. Controls how much extended thinking Claude uses.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_EFFORT_LEVEL` | `high` | string (`low`, `medium`, `high`) |

```bash
AGENT_EFFORT_LEVEL="high"
```

This is exported as `CLAUDE_CODE_EFFORT_LEVEL` for the `claude` CLI.

### AGENT_ALLOW_DIRECT_IMPLEMENT

Controls whether the `agent:implement` label is accepted as an entry point. When enabled, humans can skip triage by adding `agent:implement` to an issue that already contains a complete plan. When disabled, the label is rejected and the issue is marked as failed.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_ALLOW_DIRECT_IMPLEMENT` | `true` | boolean string (`true` or `false`) |

```bash
# Enable (default) — allow agent:implement label
AGENT_ALLOW_DIRECT_IMPLEMENT="true"

# Disable — reject agent:implement label, require standard triage flow
AGENT_ALLOW_DIRECT_IMPLEMENT="false"
```

When disabled, any issue labeled with `agent:implement` will receive a comment explaining that direct implementation is not enabled and the label will be changed to `agent:failed`.

---

## Tool Permissions

Tool permissions control which Claude Code tools the agent can use during each phase. They are passed to `claude -p` via `--allowedTools` and `--disallowedTools`.

### AGENT_ALLOWED_TOOLS_TRIAGE

Tools available during triage and reply phases. These are read-only by default — the agent can explore the codebase but not modify files.

| Key | Default |
|-----|---------|
| `AGENT_ALLOWED_TOOLS_TRIAGE` | `Read,Grep,Glob,Bash(echo:*),Bash(cat:*),Bash(ls:*),Bash(find:*)` |

### AGENT_ALLOWED_TOOLS_IMPLEMENT

Tools available during implementation and review phases. These include write access for editing files and making git commits.

| Key | Default |
|-----|---------|
| `AGENT_ALLOWED_TOOLS_IMPLEMENT` | `Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*),Bash(mkdir:*)` |

Notable exclusions from the defaults:
- `git push` — handled by the dispatch script, not by Claude
- `sudo`, `rm -rf` — dangerous system operations
- `curl`, `wget` — network access (mitigates prompt injection from issue content)

### AGENT_EXTRA_TOOLS

Additional tools appended to the implementation toolset. Use this for project-specific build tools, test runners, or other commands the agent needs.

| Key | Default |
|-----|---------|
| `AGENT_EXTRA_TOOLS` | *(empty)* |

```bash
# Node.js project
AGENT_EXTRA_TOOLS="Bash(npm:*),Bash(npx:*)"

# Rust project
AGENT_EXTRA_TOOLS="Bash(cargo:*)"

# Python project
AGENT_EXTRA_TOOLS="Bash(pytest:*),Bash(pip:*)"
```

Extra tools are appended only to the implementation/review toolset, not to the triage toolset.

### AGENT_DISALLOWED_TOOLS

Tools to explicitly block. By default, MCP GitHub tools are blocked to avoid conflicts with the `gh` CLI that the dispatch script uses directly.

| Key | Default |
|-----|---------|
| `AGENT_DISALLOWED_TOOLS` | `mcp__github__*` |

```bash
AGENT_DISALLOWED_TOOLS="mcp__github__*"
```

---

## Custom Prompts

You can override the default prompts for each agent phase by pointing to your own prompt files. If unset, the dispatch script uses the built-in prompts from the `prompts/` directory.

| Key | Phase | Default prompt file |
|-----|-------|-------------------|
| `AGENT_PROMPT_TRIAGE` | Triage (new issue analysis) | `prompts/triage.md` |
| `AGENT_PROMPT_IMPLEMENT` | Implementation (code changes) | `prompts/implement.md` |
| `AGENT_PROMPT_REPLY` | Reply (follow-up to questions) | `prompts/reply.md` |
| `AGENT_PROMPT_REVIEW` | Review (PR feedback) | `prompts/review.md` |
| `AGENT_PROMPT_VALIDATE` | Validation (pre-written plan check) | `prompts/validate.md` |

```bash
AGENT_PROMPT_TRIAGE="/home/user/my-project/agent-prompts/triage.md"
AGENT_PROMPT_IMPLEMENT="/home/user/my-project/agent-prompts/implement.md"
```

See [customization.md](customization.md) for guidance on writing custom prompts.

---

## Path Settings

### AGENT_LOG_DIR

Directory where log files are written.

| Key | Default |
|-----|---------|
| `AGENT_LOG_DIR` | `$HOME/.claude/agent-logs` |

Two types of logs are written here:
- `sandbox-pal-dispatch.log` — main dispatch log (appended across all runs)
- `claude-stderr-<repo>-<issue>-<timestamp>.log` — stderr from each `claude -p` invocation

---

## Reusable Workflow Inputs

The reusable workflows (`sandbox-pal-triage.yml`, `sandbox-pal-implement.yml`, `sandbox-pal-reply.yml`, `sandbox-pal-review.yml`, `sandbox-pal-direct-implement.yml`) accept these inputs when called from your project's workflow:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `bot_user` | Yes | — | Bot account username (for self-trigger prevention in your calling workflow) |
| `dispatch_script` | No | `~/agent-infra/scripts/sandbox-pal-dispatch.sh` | Path to the dispatch script on the runner |
| `config_path` | No | `~/agent-infra/config.env` | Path to `config.env` on the runner |
| `timeout_minutes` | No | `125` | GitHub Actions job timeout in minutes |
| `runner_labels` | No | `["self-hosted", "agent"]` | JSON array of runner labels for job placement |

All workflows also require the `agent_pat` secret — a fine-grained PAT for the bot account with repository read/write, issues, and pull requests permissions.

Example calling workflow:

```yaml
on:
  issues:
    types: [labeled]

jobs:
  triage:
    if: github.event.label.name == 'agent' && github.actor != 'my-bot'
    uses: your-org/sandbox-pal-action/.github/workflows/sandbox-pal-triage.yml@main
    with:
      bot_user: "my-bot"
      runner_labels: '["self-hosted", "agent"]'
    secrets:
      agent_pat: ${{ secrets.AGENT_PAT }}
```

---

## Environment Variables Set by the Dispatch Script

The dispatch script exports these environment variables before invoking `claude -p`. Your prompts (both default and custom) can reference them:

### Issue Context (triage, reply, implement phases)

| Variable | Content |
|----------|---------|
| `$AGENT_ISSUE_TITLE` | Issue title |
| `$AGENT_ISSUE_BODY` | Issue body (full markdown) |
| `$AGENT_COMMENTS` | Last 20 issue comments, formatted as `[author] body` |
| `$AGENT_ISSUE_NUMBER` | Issue number (implement phase only) |
| `$AGENT_PLAN_CONTENT` | The approved plan comment body (implement phase), or the issue body (direct implement) |

### Debug Data (implement and review phases)

| Variable | Content |
|----------|---------|
| `$AGENT_DATA_COMMENT_FILE` | Path to the latest data comment saved as a file, or empty |
| `$AGENT_GIST_FILES` | Space-separated paths to downloaded gist/attachment files, or empty |
| `$AGENT_DATA_ERRORS` | Path to a file listing download failures, or empty |

### PR Context (review phase only)

| Variable | Content |
|----------|---------|
| `$AGENT_PR_TITLE` | PR title |
| `$AGENT_PR_BODY` | PR body/description |
| `$AGENT_REVIEWS` | Review submissions, formatted as `[author] (state): body` |
| `$AGENT_REVIEW_COMMENTS` | Inline code comments, formatted as `[author] on file:line: body` |
| `$AGENT_PR_COMMENTS` | PR conversation comments, formatted as `[author]: body` |
| `$AGENT_ISSUE_TITLE` | Linked issue title (if extractable from branch name) |
| `$AGENT_ISSUE_BODY` | Linked issue body |
| `$AGENT_COMMIT_HISTORY` | `git log --oneline origin/main..HEAD` on the PR branch |

### Test Command

| Variable | Content |
|----------|---------|
| `$AGENT_TEST_COMMAND` | The test command from config (available in prompts for TDD cycles) |

---

## Example Configurations

### Node.js Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_TEST_COMMAND="npm test"
AGENT_EXTRA_TOOLS="Bash(npm:*),Bash(npx:*),Bash(node:*)"
```

### Python Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=200
AGENT_TIMEOUT=3600
AGENT_TEST_COMMAND="pytest -x --tb=short"
AGENT_EXTRA_TOOLS="Bash(pytest:*),Bash(python:*),Bash(pip:*)"
```

### Rust Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=300
AGENT_TIMEOUT=5400
AGENT_TEST_COMMAND="cargo test"
AGENT_EXTRA_TOOLS="Bash(cargo:*),Bash(rustc:*)"
```

### Godot / GDScript Project

```bash
AGENT_BOT_USER="my-ci-bot"
AGENT_MAX_TURNS=600
AGENT_TIMEOUT=7200
AGENT_TEST_COMMAND="godot --headless --path . -s addons/gdUnit4/bin/GdUnitCmdTool.gd --add res://tests/unit --ignoreHeadlessMode"
AGENT_EXTRA_TOOLS="Bash(godot:*),Bash(Godot:*)"
AGENT_MEMORY_FILE="$HOME/.claude/projects/-home-user-repos-mygame/memory/MEMORY.md"
```
