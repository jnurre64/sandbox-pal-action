---
name: setup
description: Configure the Claude agent dispatch system for a new project. Use when setting up for the first time or reconfiguring.
user-invocable: true
argument-hint: "[owner/repo]"
---

# Setup: Configure Agent Dispatch for a Project

Walk the user through configuring the agent dispatch system for their GitHub repository.

## Prerequisites

Before starting, run the prerequisites check:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/check-prereqs.sh
```

If any required tools are missing, help the user install them before continuing. If `config.env` doesn't exist yet, that's expected — we'll create it in this flow.

## Step 1: Choose Setup Mode

Use the `AskUserQuestion` tool to ask the user which mode they prefer:

**Standalone mode** (recommended):
- All scripts, prompts, config, and workflows are copied directly into the user's repo under `.agent-dispatch/`
- No upstream dependency — the user owns every file and can modify freely
- No automatic updates — the user manages their own copy
- Best for: most users, full control, easy to customize, no external dependencies

**Reference mode**:
- Thin workflow files in the user's repo call back to this upstream repo via `uses: jnurre64/claude-agent-dispatch/...@v1`
- Scripts run from a clone of this repo on the runner (`~/agent-infra/`)
- Updates come automatically via version tags and `git pull`
- Best for: users who want automatic updates and minimal files in their repo

## Step 2: Gather Project Information

Use the `AskUserQuestion` tool to collect the following. If the user provided an `owner/repo` argument, use that instead of asking.

1. **Target repository** (owner/repo format) — the repo where the agent will work on issues
2. **Bot account username** — the GitHub account that will comment, push, and create PRs (recommend a dedicated bot account, not their personal account)
3. **Default branch** — usually `main`, but confirm
4. **Test command** (optional) — command to run before creating PRs (e.g., `npm test`, `pytest`, `cargo test`). If not set, the pre-PR test gate is skipped.
5. **Extra tools** (optional) — project-specific tools the agent needs (e.g., `Bash(npm:*)` for Node.js, `Bash(cargo:*)` for Rust, `Bash(Godot:*)` for Godot)
6. **Local clone path** (standalone mode only) — where the target repo is cloned on this machine

## Step 3: Generate Configuration

### Reference mode
Read the template at `config.defaults.env.example` (in the repo root). Fill in the user's answers and write to `config.env` in the repo root (reference mode uses a single file since it's not committed to a repo). Show the user the generated config and ask if they want to adjust anything.

### Standalone mode
Create the `.agent-dispatch/` directory in the user's target repo. Copy:
- `scripts/agent-dispatch.sh` and `scripts/cleanup.sh` → `.agent-dispatch/scripts/`
- `scripts/lib/*.sh` → `.agent-dispatch/scripts/lib/`
- `scripts/check-prereqs.sh` and `scripts/create-labels.sh` → `.agent-dispatch/scripts/`
- `prompts/*.md` → `.agent-dispatch/prompts/`
- `labels.txt` → `.agent-dispatch/`
- Generated `config.defaults.env` → `.agent-dispatch/config.defaults.env` (non-sensitive project config, committed)

**Important:** Configuration uses a layered approach:
- `config.defaults.env` — **committed** to the repo. Contains non-sensitive project config (bot username, timeouts, tool permissions, test commands). This file MUST NOT contain secrets, tokens, or credentials.
- `config.env` — **gitignored**, optional. Contains sensitive overrides (Discord tokens, webhook URLs, GitHub tokens). Values here override `config.defaults.env`.
- Environment variables — highest precedence, override both files.

Make all scripts executable after copying.

**Gitignore check:** Many `.gitignore` templates (e.g., VisualStudio, Node) include `*.env` which will block `config.defaults.env` from being committed. After copying files, check if the target repo's `.gitignore` excludes `*.env`. If so, add an exception:
```
!.agent-dispatch/config.defaults.env
```
Warn the user about this and make the change for them.

## Step 4: Review Default Prompts

Show the user the default prompts in `prompts/` (repo root). Explain what each one does:

- **`triage.md`** — How the agent investigates issues and writes plans
- **`implement.md`** — How the agent implements approved plans with TDD
- **`reply.md`** — How the agent evaluates human replies to its questions
- **`review.md`** — How the agent addresses PR review feedback

Ask the user:
- What test framework does their project use? The implement and review prompts reference `$AGENT_TEST_COMMAND` which they set in Step 2.
- Does their project have a CLAUDE.md? The prompts instruct the agent to read it. If not, recommend creating one with coding conventions and architecture overview.
- Do they want to customize any prompts now, or start with defaults and customize later?

For standalone mode: customizations are made directly in `.agent-dispatch/prompts/`.
For reference mode: customizations go in separate files pointed to by `AGENT_PROMPT_*` in `config.env`.

## Step 5: Create Labels

Run the label creation script against their target repo:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/create-labels.sh OWNER/REPO
```

Replace `OWNER/REPO` with the actual value from Step 2. Confirm the labels were created successfully.

## Step 6: Generate Workflows

### Reference mode
Read each template in this skill's `templates/` directory (the `caller-*.yml` files, NOT the `standalone/` subdirectory):
- `caller-triage.yml`, `caller-implement.yml`, `caller-reply.yml`, `caller-review.yml`, `caller-cleanup.yml`

### Standalone mode
Read each template in `templates/standalone/`:
- `agent-triage.yml`, `agent-implement.yml`, `agent-reply.yml`, `agent-review.yml`, `agent-cleanup.yml`

For each template:
1. Replace `{{BOT_USER}}` with the bot username from Step 2
2. Show the user the generated workflow
3. Write it to the user's target repo at `.github/workflows/`

Ask the user where their target repo is cloned locally so you can write the files there. For standalone mode, this was already collected in Step 2.

### Discord bot dispatch (optional)

If the user has set up the Discord bot (see `docs/notifications.md`), also deploy the dispatch template:

- **Reference mode:** `caller-dispatch.yml`
- **Standalone mode:** `agent-dispatch.yml` (from `templates/standalone/`)

This template enables the Discord bot's Approve, Retry, Comment, and Request Changes actions to trigger agent workflows. It is only needed if the Discord bot is in use.

## Step 7: Guide Secret Setup

The target repo needs these GitHub Actions secrets:
- **`AGENT_PAT`** — Fine-grained PAT for the bot account (required)
- **`AGENT_GIST_PAT`** — Classic PAT with `gist` scope for the cleanup workflow (optional)

Walk the user through setting them:

```bash
# Set the bot's PAT (this will prompt securely)
gh secret set AGENT_PAT --repo OWNER/REPO

# Optional: set gist PAT for cleanup
gh secret set AGENT_GIST_PAT --repo OWNER/REPO
```

If the user hasn't created a bot account or PAT yet, walk them through:
1. Create a new GitHub account for the bot
2. Create a fine-grained PAT with scopes: Contents (rw), Issues (rw), Pull requests (rw), Metadata (r)
3. Add the bot as a collaborator on their target repo

## Step 8: Validate

Summarize everything that was set up:
- Setup mode chosen (reference vs standalone)
- Config file location
- Labels created
- Workflow files generated and where they were written
- Secrets that need to be set (if not done in Step 7)
- For standalone: list of files copied to `.agent-dispatch/`

## Step 9: Next Steps

### Reference mode
1. **Commit and push** the workflow files to their target repo
2. **Set up a self-hosted runner** (if not already done)
3. **Ensure the runner has `claude` CLI installed** and the ANTHROPIC_API_KEY environment variable set
4. **Clone this repo** on the runner: `git clone https://github.com/jnurre64/claude-agent-dispatch.git ~/agent-infra`
5. **Copy config.env** to the runner at `~/agent-infra/config.env`
6. **Test with a dry run**: Create a test issue, add the `agent` label, and watch the agent triage it

### Standalone mode
1. **Review and customize** `.agent-dispatch/prompts/` for your project's conventions
2. **Review** `.agent-dispatch/config.env` — ensure settings are correct
3. **Commit and push** all files (`.agent-dispatch/` and `.github/workflows/`) to the target repo
4. **Set up a self-hosted runner** with `claude` CLI installed
5. **Test with a dry run**: Create a test issue, add the `agent` label, and watch the agent triage it

Note for standalone users: You own all the files now. Modify scripts, prompts, and workflows as needed for your project. There is no upstream dependency.
