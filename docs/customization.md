# Customization Guide

This document covers how to tailor sandbox-pal-action for your specific project: custom prompts, extra tools, test gates, shared memory, and project conventions.

## Shared orchestration skills in standalone projects

Standalone `scripts/setup.sh` and `scripts/update.sh` install `sp-work`,
`sp-status`, `sp-revise`, and `sp-post-merge` under
`.sandbox-pal-dispatch/.claude/skills/`. These are regular files in the existing
asset inventory, with upstream checksums and customization review on updates.
The installers expose them through relative directory links in both the project's
`.claude/skills/` and `.agents/skills/`. Commit those links with the installed
assets; they remain valid when the consuming repository moves.

Existing client skill entries, including dangling links, are preserved and
reported. Symlinked client directories are preserved without writing through
them. Resolve a reported conflict manually if you want that client to use the
installed shared skill. Editing a skill through a managed link edits its installed
source; subsequent updates treat that edit as a local customization. Skills
deferred during an update receive no discovery links until installed.

The installers do not create or replace the consuming project's `AGENTS.md` or
`CLAUDE.md`. Keep project-specific build commands and conventions there. The four
shared skills contain the dispatch instructions and approval gates; the toolkit's
own repository development instructions are not suitable consumer defaults.
Use `$sp-work`, `$sp-status`, `$sp-revise`, or `$sp-post-merge` from Codex and the
corresponding slash commands from Claude Code. Client choice does not select a
worker engine; Claude remains the default worker.

Automatic discovery links apply only to the standard `.sandbox-pal-dispatch`
installation directory, which the shared skills use to locate the dispatcher.
Reference-mode and custom-location installations use the explicit command below.
Workflow templates remain reference assets during updates; review
and apply relevant changes to `.github/workflows/` while preserving local filters.

### Connect a reference or custom runtime

Run the following from the toolkit checkout or an updated runtime installation:

```bash
bash scripts/link-client-skills.sh /path/to/consumer /path/to/runtime
export AGENT_CONFIG=/absolute/path/to/project/config.env
```

The runtime must already contain its dispatch script and all four shared skills.
The command creates a relative `.sandbox-pal-dispatch` link in the consumer and
the same client discovery links used by standalone setup. It refuses an existing
installation pointing elsewhere and preserves custom client skills. It does not
copy credentials, modify project instructions, dispatch workers or create workflows.

For a runtime inside the consumer (for example `tools/worker-runtime`), commit the
runtime and links together; moving the whole repository preserves them. An external
reference runtime is local machine configuration: keep the `.sandbox-pal-dispatch`
link local and recreate it on another machine. For a Git checkout, a local entry
in `.git/info/exclude` can keep that runtime link out of commits. The client skill
links still require that local runtime link to resolve.

Update the runtime at its existing location with its existing update mechanism.
Both clients immediately see updated canonical skill files; rerun the linking
command to repair missing discovery links. `AGENT_CONFIG` must select the intended
project's configuration before interactive dispatch. Linking does not relocate
the runtime's state or change lock configuration. GitHub Actions reference callers
continue using their configured runner `dispatch_script` and `config_path`.

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

## Prompt Context Files

Before every phase the dispatch script writes the issue, plan, PR and review text into `.agent-data/context/` in the worktree. Custom prompts should tell the agent to read those files with the Read tool. The full list, per phase, is in [configuration.md](configuration.md#phase-context-files). The most used:

| File | Description |
|------|-------------|
| `.agent-data/context/issue-title.txt` | The GitHub issue title |
| `.agent-data/context/issue-body.md` | The full issue body (markdown) |
| `.agent-data/context/comments.md` | The last 20 comments on the issue, formatted as `[author] body` |
| `.agent-data/context/plan.md` | The full text of the approved plan comment (implement phase) |
| `.agent-data/context/test-command.txt` | The configured test command (absent when none is set) |
| `.agent-data/context/attached-data.md` | Index of downloaded data files and download errors (absent when nothing was attached) |
| `.agent-data/context/references/` | Issues and pull requests the issue text refers to, one file per number |

A file is absent when its value is empty, so say so in the prompt ("a file that does not exist means there is nothing of that kind").

### Example: Using Context Files in a Custom Prompt

```markdown
You are implementing changes for a GitHub issue.

Read the issue context with the Read tool:
- `.agent-data/context/issue-title.txt`
- `.agent-data/context/issue-body.md`
- `.agent-data/context/plan.md`

Follow these project-specific rules:
1. All commits must be signed.
2. Run `make lint` before committing.
3. Run the command in `.agent-data/context/test-command.txt` after all changes.
```

### Migrating a prompt that uses `echo "$AGENT_..."`

Earlier versions passed this text only as environment variables, and prompts read it with `echo "$AGENT_ISSUE_TITLE"`. That needed a shell command and an allow rule matching it exactly, and a phase that could not run the command did not know which issue it was working on. The variables are still exported for now and will be removed in a later release. Replace each `Run: echo "$AGENT_X"` line with a `Read` of the matching file.


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

Tools use Claude Code's permission rule syntax:
- `Bash(command:*)` — allows `command` with any arguments
- `Bash(command arg:*)` — allows `command arg` followed by anything
- `Read`, `Edit`, `Write`, `Grep`, `Glob` — Claude Code built-in tools

Extra tools are only added to the implementation and review phases. The triage phase remains read-only regardless of this setting.

---

## Adding a Pre-PR Test Gate

The `AGENT_TEST_COMMAND` setting adds a mandatory test step after implementation and before PR creation. If the tests fail, no PR is created and the issue is labeled `agent:failed`.

### How It Works

1. The agent finishes implementation and commits its changes
2. The dispatch script pushes the work branch (so a later failure never loses the work), then runs `AGENT_TEST_COMMAND` in the worktree
3. If the command exits with code 0, the review loop runs and a PR is created
4. If the command exits non-zero, up to `AGENT_TEST_GATE_MAX_RETRIES` (default 2) automated fix sessions get the failing output and try to make the suite green; a session that makes no commits stops the loop early
5. If the gate still fails, the last 100 lines of output are posted as an issue comment (linking the pushed branch) and the issue is labeled `agent:failed`; re-applying `agent:plan-approved` resumes from the pushed branch

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

## Tool Allow-Lists: Broad Allows, Narrow Denies

Deny rules beat allow rules, so the robust idiom is a **broad allow with narrow denies**: allow `Bash(git:*)` and put the hard limits — `git push`, `git merge`, `git add -A` — in `AGENT_DISALLOWED_TOOLS`. The alternative (enumerating every allowed verb) fails one denial at a time: every verb the allow list happens to miss (`checkout`, `rm`, `stash`, `rev-parse`) is a denied call that costs a turn, and denied calls compound — the phase does not know why it failed, retries a variant, and burns its turn cap on nothing.

**Under a sandbox profile this section mostly stops applying.** When a phase runs with `AGENT_SANDBOX="strict"`, every `Bash(...)` rule in its list is replaced by a single `Bash` rule: the sandbox limits what a command can touch, so the list no longer has to. Variables, redirects, `cd dir && cmd`, loops and heredocs all run. Rules for other tools (`Read`, `Edit`, `WebSearch`, MCP tools) are kept as written, a list with no `Bash` rule is not given shell access, and `AGENT_DISALLOWED_TOOLS` still applies, so `Bash(git push:*)` there is still refused. You can then delete the long prefix lists from `AGENT_EXTRA_TOOLS`, and any "how to phrase a command so it is allowed" guidance you wrote for agents. Set `AGENT_SANDBOX_SHORT_TOOLS="false"` to keep the lists as written. See [sandbox.md](sandbox.md).

Two tools make the gaps visible and fixable:

- **Denial surfacing**: after every phase, the dispatch script extracts the envelope's `permission_denials`, logs each one, and accumulates them in `.agent-data/permission-denials.log`. Non-empty denials appear in the PR body and in failure comments. **Treat every entry as an allow-list gap to fix in config, not as noise.** In a sandboxed phase a denial should be rare (a deny rule, a tool outside the list, a protected path) and is logged as unexpected.
- **`AGENT_ADD_DIRS`**: path gating is separate from tool rules. A command matching an allow rule is still denied when it touches a path outside the working directory — sibling repos, scratch areas, and package caches need `--add-dir` (see the configuration guide).

## Agent-Maintained Rules Files (`.claude/rules/`)

A headless phase **cannot write anything under `.claude/`** — a built-in, path-based guard in Claude Code, not something an allow-list entry can lift. `Edit` and `Bash` writes both fail, and the phase typically reports success having written nothing (see the troubleshooting guide). Only `--permission-mode bypassPermissions` lifts the guard, and it drops every deny rule with it — not a trade worth making.

If you want agents to maintain agent-facing rules files, the dispatch script works around the guard by **staging**:

1. Before each write phase (implement, revise, post-merge cleanup), every `*.md` file in `.claude/rules/` is copied into `.agent-data/rules/` — an ordinary, unguarded path.
2. The phase edits the staged copies with a plain `Edit` (the default prompts tell it so).
3. Afterwards, the harness copies back whatever differs and commits it. The phase authors the words; the harness does the writing.

The apply step is deliberately restrictive: a staged file is honoured **only if `.claude/rules/` already holds a file of that name**, and the name must match `^[A-Za-z0-9._-]+\.md$`. A phase cannot invent a new rules file or traverse out of the staging directory — new rules files are created by humans under version control first.

This is automatic: if your repo has no `.claude/rules/` directory, staging is a no-op.

## Shared Project Memory

### What It Is

`AGENT_MEMORY_FILE` points to a markdown file containing project knowledge that agents should have as context. When set, its contents are injected into every agent invocation via `--append-system-prompt`.

If your memory is a **directory** — an index whose lines point at sibling files, like `~/.claude/projects/<slug>/memory/` — use `AGENT_MEMORY_DIR` instead (or as well): the index is injected the same way, and the phase can additionally `Read` the file a pointer names. Injecting only the index gives the agent a list of things it knows it cannot access, which invites reasoning about facts it cannot read. Memory stays read-only in both forms. See the configuration guide.

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

### Retain worker settings when switching engines

The interactive client does not select worker settings. Use the same dispatcher
and project config from Claude Code, Codex, and label workflows. The opt-in
[engine profiles](configuration.md#retain-both-engines-settings) keep each engine's
model, effort and invocation timeout, plus Claude's applicable limits. Configure
both once, then switch `AGENT_ENGINE` or a phase routing override. Existing prompts,
schemas, tools, memory, review and test gates keep their shared configuration paths.

## Saving worker configurations

Use [named dispatch profiles](configuration.md#named-dispatch-profiles) to save
legacy routes and switch all phases together. Run `scripts/agent-profile.sh`
from the runtime with the same `AGENT_CONFIG` used by either client or Actions.
A profile can override engine-qualified models and effort while keeping tests,
prompts, gates and authentication shared. Setup/update distribute
`agent-profiles.example.json`; your active catalog and local selection remain
project-owned and are never automatically enabled or overwritten.
