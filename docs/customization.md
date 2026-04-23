# Customization Guide

This document covers how to tailor sandbox-pal-action for your specific project: custom prompts, extra tools, test gates, shared memory, and project conventions.

## Customizing Prompts

### When to Customize

The default prompts in `prompts/` are designed to be generic and work across project types. You should customize prompts when:

- Your project has specific workflow requirements (e.g., mandatory linting, specific commit message formats)
- You want the agent to follow domain-specific conventions not covered by CLAUDE.md alone
- You need to change the output format (e.g., different plan structure, different JSON schema)
- You want to add or remove steps from the implementation workflow (e.g., skip TDD for a documentation-only repo)

### How to Create Custom Prompt Files

1. Copy the default prompt as a starting point:
   ```bash
   cp prompts/implement.md ~/my-project/agent-prompts/implement.md
   ```

2. Edit the copy to match your needs.

3. Point your `config.env` to the custom prompt:
   ```bash
   AGENT_PROMPT_IMPLEMENT="/home/user/my-project/agent-prompts/implement.md"
   ```

The dispatch script checks for custom prompts first, then falls back to the built-in defaults:

```
custom path (AGENT_PROMPT_*) --> built-in prompts/ directory --> error
```

You only need to override the prompts you want to change. Unset variables use the defaults.

### Available Prompt Overrides

| Config Variable | Phase | Default File |
|----------------|-------|-------------|
| `AGENT_PROMPT_TRIAGE` | New issue analysis and planning | `prompts/triage.md` |
| `AGENT_PROMPT_IMPLEMENT` | Code implementation from approved plan | `prompts/implement.md` |
| `AGENT_PROMPT_REPLY` | Evaluating human replies to agent questions | `prompts/reply.md` |
| `AGENT_PROMPT_REVIEW` | Addressing PR review feedback | `prompts/review.md` |
| `AGENT_PROMPT_VALIDATE` | Pre-written plan validation | `prompts/validate.md` |

---

## Prompt Environment Variables

Your custom prompts can reference these environment variables. The dispatch script exports them before invoking `claude -p`. Prompts should instruct Claude to read them via `echo "$VARIABLE_NAME"`.

### Available in All Phases

| Variable | Description |
|----------|-------------|
| `$AGENT_ISSUE_TITLE` | The GitHub issue title |
| `$AGENT_ISSUE_BODY` | The full issue body (markdown) |
| `$AGENT_COMMENTS` | The last 20 comments on the issue, formatted as `[author] body` |
| `$AGENT_TEST_COMMAND` | The configured test command (may be empty) |

### Implement Phase Only

| Variable | Description |
|----------|-------------|
| `$AGENT_ISSUE_NUMBER` | The issue number |
| `$AGENT_PLAN_CONTENT` | The full text of the approved plan comment |
| `$AGENT_DATA_COMMENT_FILE` | Path to a file containing the latest data/debug comment, or empty |
| `$AGENT_GIST_FILES` | Space-separated paths to downloaded gist/attachment files, or empty |
| `$AGENT_DATA_ERRORS` | Path to a file listing any download failures, or empty |

### Review Phase Only

| Variable | Description |
|----------|-------------|
| `$AGENT_PR_TITLE` | The PR title |
| `$AGENT_PR_BODY` | The PR body/description |
| `$AGENT_REVIEWS` | Review submissions, formatted as `[author] (state): body` |
| `$AGENT_REVIEW_COMMENTS` | Inline code comments, formatted as `[author] on file:line: body` |
| `$AGENT_PR_COMMENTS` | PR conversation comments, formatted as `[author]: body` |
| `$AGENT_COMMIT_HISTORY` | Output of `git log --oneline origin/main..HEAD` on the PR branch |
| `$AGENT_DATA_COMMENT_FILE` | Path to a file containing the latest data/debug comment, or empty |
| `$AGENT_GIST_FILES` | Space-separated paths to downloaded gist/attachment files, or empty |
| `$AGENT_DATA_ERRORS` | Path to a file listing any download failures, or empty |

### Example: Using Variables in a Custom Prompt

```markdown
You are implementing changes for a GitHub issue.

Read the issue context:
- Run: echo "$AGENT_ISSUE_TITLE"
- Run: echo "$AGENT_ISSUE_BODY"
- Run: echo "$AGENT_PLAN_CONTENT"

Follow these project-specific rules:
1. All commits must be signed.
2. Run `make lint` before committing.
3. Run `$AGENT_TEST_COMMAND` after all changes.
```

---

## Adding Project-Specific Tools

Use `AGENT_EXTRA_TOOLS` to give the agent access to project-specific commands during implementation and review. These tools are appended to `AGENT_ALLOWED_TOOLS_IMPLEMENT`.

### Examples

```bash
# Node.js: allow npm and npx
AGENT_EXTRA_TOOLS="Bash(npm:*),Bash(npx:*)"

# Python: allow pytest and python
AGENT_EXTRA_TOOLS="Bash(pytest:*),Bash(python:*),Bash(pip:*)"

# Rust: allow cargo
AGENT_EXTRA_TOOLS="Bash(cargo:*)"

# Go: allow go tool
AGENT_EXTRA_TOOLS="Bash(go:*)"

# Multiple tools combined
AGENT_EXTRA_TOOLS="Bash(npm:*),Bash(npx:*),Bash(node:*),Bash(eslint:*)"
```

### Tool Format

Tools use Claude Code's `--allowedTools` syntax:
- `Bash(command:*)` — allows `command` with any arguments
- `Bash(command arg:*)` — allows `command arg` followed by anything
- `Read`, `Edit`, `Write`, `Grep`, `Glob` — Claude Code built-in tools

Extra tools are only added to the implementation and review phases. The triage phase remains read-only regardless of this setting.

---

## Adding a Pre-PR Test Gate

The `AGENT_TEST_COMMAND` setting adds a mandatory test step after implementation and before PR creation. If the tests fail, no PR is created and the issue is labeled `agent:failed`.

### How It Works

1. The agent finishes implementation and commits its changes
2. The dispatch script runs `AGENT_TEST_COMMAND` in the worktree
3. If the command exits with code 0, the branch is pushed and a PR is created
4. If the command exits with a non-zero code, the last 100 lines of output are posted as an issue comment and the issue is labeled `agent:failed`

### Examples by Framework

```bash
# Node.js (Jest, Mocha, Vitest, etc.)
AGENT_TEST_COMMAND="npm test"

# Python (pytest)
AGENT_TEST_COMMAND="pytest -x --tb=short"

# Rust
AGENT_TEST_COMMAND="cargo test"

# Go
AGENT_TEST_COMMAND="go test ./..."

# Java (Maven)
AGENT_TEST_COMMAND="mvn test -q"

# Multiple commands chained
AGENT_TEST_COMMAND="npm run lint && npm test"
```

### Notes

- The command runs in the worktree directory, which is a checkout of the agent's branch
- Ensure the test command works in headless mode (no GUI, no interactive prompts)
- The same `$AGENT_TEST_COMMAND` variable is available in prompts, so the agent can also run tests during its TDD cycles
- If `AGENT_TEST_COMMAND` is not set, the test gate is skipped entirely

---

## Shared Project Memory

### What It Is

`AGENT_MEMORY_FILE` points to a markdown file containing project knowledge that agents should have as context. When set, its contents are injected into every agent invocation via `--append-system-prompt`.

This gives the agent access to patterns, conventions, and hard-won lessons that were discovered during interactive development but are not written in CLAUDE.md.

### Two Approaches

#### Approach 1: Committed Memory File (Recommended)

A curated markdown file checked into the repository. Syncs across all machines via git — human developers on any OS and automated agents all read the same knowledge.

**Best for**: Teams or setups where multiple people/machines work on the same project. Eliminates knowledge isolation between interactive sessions on different machines and automated agent runs.

1. **Create the memory file** in your repository (e.g., `claude-work/shared-memory.md`):
   ```markdown
   # Project Memory

   ## Testing Patterns
   - Use `scene_runner()` for integration tests that need the scene tree
   - RefCounted classes can be tested without scene tree setup
   ...
   ```

2. **Set the config variable** (workspace-relative path):
   ```bash
   AGENT_MEMORY_FILE="claude-work/shared-memory.md"
   ```

3. **Add a CLAUDE.md instruction** telling interactive Claude to suggest updates:
   ```markdown
   ### Shared Memory Maintenance
   When you discover a noteworthy pattern or hard-won lesson during an interactive
   session, suggest adding it to `claude-work/shared-memory.md`.
   ```

4. **Curate manually** — review Claude's suggestions, approve and commit what's useful. Never let agents write to this file autonomously.

5. **Initialize from existing memory** — if you already have machine-local auto-memory, compare it with the committed file in your first interactive session and merge relevant entries. Ask Claude: "Compare my local memory with `claude-work/shared-memory.md` and suggest what should be added."

#### Approach 2: Machine-Local Memory

Points to Claude Code's auto-generated memory file on the runner machine. Only contains knowledge from interactive sessions on that specific machine.

**Best for**: Single-machine setups where the same person does interactive development and runs agents.

1. **Locate your project's memory file.** Claude Code stores per-project memory at:
   ```
   ~/.claude/projects/<path-encoded-project>/memory/MEMORY.md
   ```
   The path encoding replaces `/` with `-` and prefixes with `-`. For example, a project at `/home/user/repos/my-app` would have memory at:
   ```
   ~/.claude/projects/-home-user-repos-my-app/memory/MEMORY.md
   ```

2. **Set the config variable** (absolute path):
   ```bash
   AGENT_MEMORY_FILE="$HOME/.claude/projects/-home-user-repos-my-app/memory/MEMORY.md"
   ```

3. **Build up memory** by using Claude Code interactively on your project. As you work, Claude accumulates knowledge about patterns, edge cases, and conventions.

### Important Notes

- The agent reads the memory file but **never writes to it**. Only interactive Claude Code sessions (human-supervised) should manage memory content. This prevents context pollution and hallucinated learnings propagation.
- If the file does not exist or the variable is empty, the memory feature is silently skipped.
- Memory is wrapped with a header explaining that the agent should use it for context but not attempt to update it.
- Workspace-relative paths resolve against the agent's worktree directory at runtime.

---

## Customizing CLAUDE.md

The agent reads `CLAUDE.md` in the root of your repository at the start of every phase (triage, implement, review). This is the primary way to communicate project conventions to the agent.

### What to Include

- **Project overview**: What the project does, what language/framework it uses
- **Architecture**: Key files, directory structure, how systems interact
- **Coding standards**: Naming conventions, type annotations, formatting rules
- **Testing**: How to run tests, what framework is used, where test files live
- **Build/run instructions**: How to build, how to run locally
- **Things to avoid**: Files not to modify, patterns to avoid, known pitfalls

### Example CLAUDE.md

```markdown
# CLAUDE.md

## Project Overview
This is a Python REST API built with FastAPI.

## Architecture
- `src/api/` — Route handlers
- `src/models/` — Pydantic models
- `src/services/` — Business logic
- `tests/` — pytest tests

## Development
- Python 3.12+, managed with uv
- Run tests: `pytest -x`
- Run server: `uvicorn src.main:app --reload`

## Conventions
- Type hints on all functions
- Docstrings on public functions (Google style)
- Tests mirror src/ structure: `src/services/foo.py` -> `tests/services/test_foo.py`

## Rules
- Never modify `alembic/versions/` — migrations are manual
- Never modify `.github/workflows/`
- All API endpoints must have tests
```

The agent treats CLAUDE.md as its primary source of project truth. The more specific and clear your CLAUDE.md is, the better the agent's output will be.

---

## Advanced: Modifying the Dispatch Script

In standalone mode (where you have copied the scripts into your own infrastructure), you can modify the dispatch script itself.

### Common Modifications

**Adding a post-PR hook** — run a command after PR creation:
Edit `handle_post_implementation()` in `scripts/lib/common.sh` to add steps after the PR is created.

**Changing the branch naming convention** — the default is `agent/issue-<N>`:
Edit the `BRANCH_NAME` assignment in `scripts/sandbox-pal-dispatch.sh`.

**Adding a pre-triage check** — skip certain issues automatically:
Add logic at the top of `handle_new_issue()` in `scripts/sandbox-pal-dispatch.sh`.

**Changing the PR template** — customize the PR body:
Edit the `gh pr create` call in `handle_post_implementation()` in `scripts/lib/common.sh`.

### Caution

Modifying the dispatch script means you are responsible for keeping your fork in sync with upstream changes. Consider whether a custom prompt or config change can achieve the same goal before modifying the script itself.

If you are using reference mode (calling reusable workflows from the upstream repository), you cannot modify the dispatch script. Use config options and custom prompts instead.
