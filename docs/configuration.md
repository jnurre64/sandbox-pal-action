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

### AGENT_MODEL

The Claude model for agent sessions, plus per-workflow overrides. Everything empty (the default) runs the CLI default model — currently Opus — for every step.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MODEL` | *(empty, CLI default)* | model name |
| `AGENT_MODEL_TRIAGE` / `_IMPLEMENT` / `_REVIEW` / `_ADVERSARIAL_PLAN` / `_POST_IMPL_REVIEW` / `_POST_IMPL_RETRY` / `_TEST_FIX` / `_CLEANUP` | *(empty, falls back to `AGENT_MODEL`)* | model name |

**Model-tier guidance.** The all-defaults configuration is the recommended baseline — Opus-tier models handle planning, implementation, and adversarial review well. Pinning a frontier-tier model (e.g. `claude-fable-5`, roughly 2× Opus pricing) across several pipeline steps multiplies cost per issue with little quality gain when a human or a stronger orchestrator session already gates plans and merges: in one deployment, three frontier sessions per issue consumed the bulk of the model budget while duplicating the orchestrator's own plan review. This mirrors Anthropic's multi-agent guidance — put the strongest model where judgment density is highest (orchestration, plan gating, synthesis) and run volume work on the default tier.

If you escalate a single slot, `AGENT_MODEL_ADVERSARIAL_PLAN` is the highest-leverage pin: the plan review is read-mostly (cheap in tokens) and catches flaws before the expensive implement/review cycle, similar to the API's advisor-tool pattern (a cheaper executor consulting a stronger model for plan-level judgment). Cheap/fast models (`haiku`) fit `AGENT_MODEL_CLEANUP` and other bookkeeping steps.

```bash
# Recommended baseline — CLI default everywhere
# (all AGENT_MODEL_* unset)

# Escalate only the plan review, keep everything else on the default
AGENT_MODEL_ADVERSARIAL_PLAN="claude-fable-5"

# Bookkeeping on a cheap model
AGENT_MODEL_CLEANUP="haiku"
```

### AGENT_CIRCUIT_BREAKER_LIMIT

Maximum number of bot comments allowed per hour on a single issue. If the limit is exceeded, the agent halts with `agent:failed` and posts a warning. This prevents infinite loops.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_CIRCUIT_BREAKER_LIMIT` | `8` | integer |

```bash
AGENT_CIRCUIT_BREAKER_LIMIT=8
```

### Per-Phase Invocation Flags

Four independent controls on how each phase invokes the CLI. **Every one is optional and defaults to current behaviour.** Phase suffixes match the model-override vars: `TRIAGE`, `REPLY`, `IMPLEMENT`, `VALIDATE`, `REVIEW` (PR revision), `CLEANUP`, `ADVERSARIAL_PLAN`, `TEST_FIX`, `POST_IMPL_REVIEW`, `POST_IMPL_RETRY`.

| Key | Default | Effect |
|-----|---------|--------|
| `AGENT_BUDGET_USD_<PHASE>` | *(empty — limitless)* | `--max-budget-usd` for that phase |
| `AGENT_BUDGET_USD` | *(empty — limitless)* | fallback budget for phases without their own |
| `AGENT_EFFORT_<PHASE>` | *(empty)* | `--effort` for that phase (low/medium/high/xhigh) |
| `AGENT_PERMISSION_MODE_<PHASE>` | *(empty)* | `--permission-mode` for that phase |
| `AGENT_MCP_CONFIG` | *(empty)* | path → `--mcp-config <path> --strict-mcp-config`: phases get exactly these MCP servers |
| `AGENT_STRICT_MCP` | *(empty)* | `true` → `--strict-mcp-config` alone: phases get **no** MCP servers |
| `AGENT_SESSION_PERSISTENCE` | `false` | `true` keeps resumable phase sessions (default passes `--no-session-persistence`) |

Notes:
- **Budget is deliberately limitless by default** — turns (`AGENT_MAX_TURNS`) and the timeout still bound every phase; a dollar cap is the operator's choice. Turns and dollars are not interchangeable bounds: a phase can be cheap and long or short and expensive. If you set caps, size generously for write phases — a revision that runs out mid-way (work committed, reply unfinished) is worse than one that never started.
- Without `AGENT_MCP_CONFIG`/`AGENT_STRICT_MCP`, a phase run on a machine with user-level MCP servers silently inherits them. This matters most in orchestrator mode, where inheritance is otherwise the point: *inherit identity, memory and skills; gate the tool surface explicitly.*
- A workable effort/permission spread from a reference implementation: `dontAsk` for read-only phases (triage, reviews, cleanup), `acceptEdits` for writers (implement, test-fix, retry, revision); effort `high` for triage/review, `xhigh` for implement/retry/revision.

### AGENT_JSON_SCHEMA_* (structured phase output)

Each machine-consumed phase passes a JSON Schema to `claude -p --json-schema`, so the CLI returns a guaranteed-shape object in the envelope's `structured_output` field instead of the dispatch script parsing free text. Handlers prefer the validated object and fall back to text extraction, so older CLIs and custom prompts keep working.

| Key | Default | Phase |
|-----|---------|-------|
| `AGENT_JSON_SCHEMA_TRIAGE` | `schemas/triage.json` | triage |
| `AGENT_JSON_SCHEMA_REPLY` | `schemas/reply.json` | issue reply |
| `AGENT_JSON_SCHEMA_VALIDATE` | `schemas/validate.json` | direct-implement validation |
| `AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN` | `schemas/adversarial-plan.json` | Gate A plan review |
| `AGENT_JSON_SCHEMA_POST_IMPL_REVIEW` | `schemas/post-impl-review.json` | Gate B review |
| `AGENT_JSON_SCHEMA_POST_IMPL_RETRY` | `schemas/post-impl-retry.json` | Gate B retry |
| `AGENT_JSON_SCHEMA_CLEANUP` | `schemas/cleanup.json` | post-merge cleanup |

Set a variable to `""` (explicitly empty) to disable that phase's schema, or point it at your own file — absolute, or relative to the config directory. Phases with no machine-consumed result (`implement`, `pr_review` revision) take no schema. If you override a phase's prompt with a different output contract, override or disable its schema to match — a configured schema whose shape the prompt never produces is reported as a schema/prompt mismatch, distinct from an agent failure.

### AGENT_EXECUTION_MODE

How the dispatch script is being invoked. `actions` (the default) is the GitHub Actions workflow path and changes nothing. `orchestrator` is for invocation by an interactive Claude Code session (see the Orchestrator Mode section of the architecture guide): human-readable log output moves to stderr, and the final line of stdout becomes a compact JSON result object for the calling session to parse. Usually set per-invocation by the `sp-*` skills (`AGENT_EXECUTION_MODE=orchestrator scripts/sandbox-pal-dispatch.sh …`) rather than in config.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_EXECUTION_MODE` | `actions` | `actions` \| `orchestrator` |

### AGENT_LOCK_DIR

Directory for per-issue dispatch locks and last-dispatch outcome records (see the Dispatch Liveness section of the architecture guide). The lock enforces one dispatch per issue and carries a phase heartbeat; the last-dispatch record preserves each run's outcome even when the caller lost track of it.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_LOCK_DIR` | `$AGENT_LOG_DIR/locks` | directory path |

### AGENT_ADD_DIRS

Space-separated list of extra directories phases may access without prompting, passed to `claude -p` as `--add-dir` flags. Path gating is separate from tool allow rules: a command matching an allow rule is still denied when it touches a path outside the working directory, so sibling repos, scratch areas, and package caches need to be listed here even when the account can already read them.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_ADD_DIRS` | *(empty)* | space-separated directory paths |

```bash
AGENT_ADD_DIRS="$HOME/repos/shared-assets $HOME/.cache/packages"
```

### AGENT_MEMORY_DIR

Path to a shared memory **directory** — an index plus the files its pointers name (the `~/.claude/projects/<slug>/memory/` layout). `AGENT_MEMORY_FILE` alone injects only the index, which for this layout is a table of contents for a book the agent cannot open: 25 one-line pointers to files the phase has no way to read.

When set:
- The index (`MEMORY.md` in the directory, or `AGENT_MEMORY_FILE` if also set) is injected via `--append-system-prompt` exactly as before.
- The directory is passed as `--add-dir`, so the phase can `Read` the file a pointer names — path gating would otherwise deny out-of-tree reads.
- The injected preamble names the directory and keeps memory **read-only**: only interactive sessions manage memory.

Supports absolute or workspace-relative paths. `AGENT_MEMORY_FILE` alone behaves exactly as before.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MEMORY_DIR` | *(empty)* | directory path (absolute or workspace-relative) |

```bash
AGENT_MEMORY_DIR="$HOME/.claude/projects/-home-user-repos-myproject/memory"
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

A shell command to run as a pre-PR test gate. If set, the dispatch script runs this command after implementation and before creating the PR. If the tests fail, up to `AGENT_TEST_GATE_MAX_RETRIES` automated fix sessions attempt to get the suite green; if it still fails, the work branch is pushed, the failure comment links it, and the issue is labeled `agent:failed`. Re-applying `agent:plan-approved` resumes from the preserved branch.

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

### AGENT_TEST_GATE_MAX_RETRIES

Maximum automated fix sessions when the pre-PR test gate fails. Each session is a fresh Claude run given the failing test output; the gate re-runs after each. A session that makes no commits ends the loop early (the failure is judged unfixable from inside the repo — e.g. a broken `AGENT_TEST_COMMAND`). Whatever happens, the work branch is pushed before `agent:failed` is set, so implementation work is never lost.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_TEST_GATE_MAX_RETRIES` | `2` | non-negative integer (`0` = no fix sessions) |
| `AGENT_PROMPT_TEST_FIX` | *(empty, built-in `prompts/test-fix.md`)* | path |
| `AGENT_MODEL_TEST_FIX` | *(empty, falls back to `AGENT_MODEL`)* | model name |

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

## Review Gates

Two independent, fresh-session review gates check the agent's work before it reaches a human: a pre-implementation plan review, and a capped post-implementation review loop.

### AGENT_ADVERSARIAL_PLAN_REVIEW

Before implementation starts, a fresh session checks the approved plan against the issue for gaps or misunderstandings.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_ADVERSARIAL_PLAN_REVIEW` | `true` | boolean string (`true` or `false`) |

```bash
AGENT_ADVERSARIAL_PLAN_REVIEW="false"   # disable pre-implementation plan review
```

### AGENT_POST_IMPL_REVIEW

After implementation, a fresh session checks the diff against the issue/plan. Set to `false` to skip straight to PR creation with no review loop at all.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_POST_IMPL_REVIEW` | `true` | boolean string (`true` or `false`) |

```bash
AGENT_POST_IMPL_REVIEW="false"   # disable post-implementation review entirely
```

If you override the review prompt via `AGENT_PROMPT_POST_IMPL_REVIEW` with a prompt that predates the ledger, a legacy `{"action":"concerns","concerns":["..."]}` response is still accepted: each string in `concerns` is mapped to a blocking finding when `.findings` is absent or empty.

### AGENT_POST_IMPL_REVIEW_MAX_RETRIES

Sets the cap on the ledger-driven review loop that gates PR creation: **review → fix → re-review**, repeated until the review comes back clean or the cap is hit. Each pass merges its findings into a ledger committed to the work branch at `.agent-data/review-ledger.json`, so the finding history and dispositions survive across retries and are visible in the branch's commit log.

- `0` = a single review pass with no fix loop — any open finding goes straight to an `agent:review-unresolved` PR.
- `N` (default `3`) = up to `N` fresh fix sessions, each followed by a fresh re-review pass, before giving up.

If the loop reaches the cap with findings still open, it does **not** block the PR: the PR opens anyway, labeled `agent:review-unresolved` **in addition to** `agent:pr-open`, with the outstanding findings summarized at the top of the PR body so a human reviewer sees them first.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` | `3` | integer (`0` = single pass, no retries) |

```bash
AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3   # default: up to 3 fix/re-review cycles
AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0   # single pass only, escalate any finding to a human
```

---

## Post-Merge Cleanup

When an agent-authored PR merges, an optional cleanup phase runs: tracking-doc updates and follow-up issues (sourced from the review ledger's structured output) are committed, and the merged branch is deleted.

### AGENT_CLEANUP_ENABLED

Enables the post-merge cleanup phase. When disabled, the doc-cleanup session is skipped for merged agent PRs.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_CLEANUP_ENABLED` | `true` | boolean string (`true` or `false`) |

```bash
AGENT_CLEANUP_ENABLED="false"   # disable post-merge cleanup
```

This flag gates only the doc-cleanup Claude session. The `agent:done` label
transition on linked issues runs for every merged agent PR regardless of
this setting — label bookkeeping is not cleanup.

### AGENT_PROMPT_CLEANUP

Custom prompt file for the cleanup session. If unset, the dispatch script uses the built-in `prompts/cleanup.md`.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_PROMPT_CLEANUP` | *(empty, uses `prompts/cleanup.md`)* | file path |

```bash
AGENT_PROMPT_CLEANUP="/home/user/my-project/agent-prompts/cleanup.md"
```

### AGENT_MODEL_CLEANUP

Per-workflow model override for the cleanup session. Empty falls back to `AGENT_MODEL`, then the CLI default. Cleanup is bookkeeping (doc edits, issue filing), not implementation work, so a cheap/fast model is usually a good fit.

| Key | Default | Type |
|-----|---------|------|
| `AGENT_MODEL_CLEANUP` | *(empty)* | string (model name) |

```bash
AGENT_MODEL_CLEANUP="haiku"
```

### AGENT_ALLOWED_TOOLS_CLEANUP

Tools available during the cleanup session. Read-write by default (for doc edits and branch/label bookkeeping), same shape as `AGENT_ALLOWED_TOOLS_IMPLEMENT` but without a network-adjacent test-runner allowance.

| Key | Default |
|-----|---------|
| `AGENT_ALLOWED_TOOLS_CLEANUP` | `Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git rm:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*)` |

### Caller workflow

`sandbox-pal-post-merge.yml` is triggered by `pull_request.closed`, guarded to only fire for merged PRs authored by your bot:

```yaml
name: "Claude Agent: Post-Merge Cleanup"

on:
  pull_request:
    types: [closed]

jobs:
  post-merge-cleanup:
    if: >-
      github.event.pull_request.merged == true &&
      github.event.pull_request.user.login == 'my-bot'
    uses: your-org/sandbox-pal-action/.github/workflows/sandbox-pal-post-merge.yml@v1
    with:
      bot_user: "my-bot"
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      agent_pat: ${{ secrets.AGENT_PAT }}
```

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

The reusable workflows (`sandbox-pal-triage.yml`, `sandbox-pal-implement.yml`, `sandbox-pal-reply.yml`, `sandbox-pal-review.yml`, `sandbox-pal-direct-implement.yml`, `sandbox-pal-post-merge.yml`) accept these inputs when called from your project's workflow:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `bot_user` | Yes | — | Bot account username (for self-trigger prevention in your calling workflow) |
| `dispatch_script` | No | `~/agent-infra/scripts/sandbox-pal-dispatch.sh` | Path to the dispatch script on the runner |
| `config_path` | No | `~/agent-infra/config.env` | Path to `config.env` on the runner |
| `timeout_minutes` | No | `125`¹ | GitHub Actions job timeout in minutes |
| `runner_labels` | No | `["self-hosted", "agent"]` | JSON array of runner labels for job placement |

¹ `sandbox-pal-post-merge.yml` is the exception: its `timeout_minutes` default is `30`, not `125` — cleanup is bookkeeping (doc commits, follow-up issue filing), not implementation work, so it doesn't need the longer default. `sandbox-pal-post-merge.yml` also accepts one extra input not needed by the other workflows:

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `pr_number` | No | `''` (falls back to `github.event.pull_request.number`) | PR number override, for triggering the workflow via `repository_dispatch` instead of the standard `pull_request.closed` event |

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
