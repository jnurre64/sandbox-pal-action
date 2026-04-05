# Getting Started

A complete walkthrough for setting up claude-agent-dispatch from scratch. By the end of this guide you will have an autonomous Claude Code agent that triages GitHub issues, writes implementation plans, and creates pull requests -- all triggered by adding a label.

---

## Prerequisites

Before you begin, make sure you have the following:

| Requirement | Why |
|-------------|-----|
| A GitHub repository you want the agent to work on | The "target repo" |
| A machine to run a self-hosted GitHub Actions runner | Linux recommended (Ubuntu 22.04+); can be a home server, VM, or cloud instance |
| An Anthropic API key with access to Claude | Powers the `claude` CLI |
| GitHub CLI (`gh`) installed on the runner | Used for label management, issue/PR operations |
| `git`, `jq`, and `curl` installed on the runner | Core dependencies of the dispatch scripts |

You should be comfortable creating GitHub accounts, generating personal access tokens, and editing shell configuration files.

---

## Step 1: Create a Bot GitHub Account

The agent needs its own GitHub account so that its actions (comments, pushes, PRs) are clearly separated from human activity. This also enables the **actor filter** -- workflows ignore events triggered by the bot, preventing infinite loops.

Create a dedicated GitHub account for the bot (e.g., `my-project-bot`). See [bot-account.md](bot-account.md) for a detailed walkthrough covering account creation, profile setup, PAT creation with exact scopes, and security best practices.

If you already have a bot account with an appropriate PAT, skip ahead to Step 3.

---

## Step 2: Create a Fine-Grained PAT

Log in as the bot account and create a fine-grained personal access token:

1. Go to **Settings > Developer settings > Personal access tokens > Fine-grained tokens**
2. Click **Generate new token**
3. Set the resource owner to the organization or user that owns your target repo
4. Under **Repository access**, select the target repo (or "All repositories" if the bot will work across multiple repos)
5. Grant these permissions:

| Permission | Access | Required? |
|------------|--------|-----------|
| **Contents** | Read and write | Yes -- read code, push branches |
| **Issues** | Read and write | Yes -- comment, manage labels |
| **Pull requests** | Read and write | Yes -- create and update PRs |
| **Metadata** | Read-only | Yes -- automatically included |
| **Workflows** | Read and write | Only if the bot needs to trigger `workflow_dispatch` events |

6. Set an expiration (max 1 year for fine-grained PATs) and click **Generate token**
7. Copy the token immediately -- you will not see it again

For full details on PAT scopes, rotation, and the optional classic PAT for gist cleanup, see [bot-account.md](bot-account.md).

---

## Step 3: Set Up a Self-Hosted GitHub Actions Runner

The agent runs on a self-hosted runner because it needs the `claude` CLI installed locally (it is not available in GitHub-hosted runners).

### Install the runner

1. In your target repo, go to **Settings > Actions > Runners > New self-hosted runner**
2. Follow GitHub's instructions for your OS (Linux is recommended)
3. Configure the runner with the `self-hosted` label (this is the default)
4. Start the runner as a service so it persists across reboots:
   ```bash
   sudo ./svc.sh install
   sudo ./svc.sh start
   ```

### Verify the runner

After installation, the runner should appear as "Idle" in **Settings > Actions > Runners**.

---

## Step 4: Install Claude Code on the Runner

Install the Claude CLI on the runner machine:

```bash
# Install Claude Code (see https://docs.anthropic.com/en/docs/claude-code for latest instructions)
npm install -g @anthropic-ai/claude-code
```

Set the Anthropic API key so the runner's service user can access it. The recommended approach is to add it to the runner service user's environment:

```bash
# Add to the runner user's shell profile (~/.bashrc or ~/.profile)
export ANTHROPIC_API_KEY="sk-ant-..."
```

If you run the runner as a systemd service, you may need to add the environment variable to the service override:

```bash
sudo systemctl edit actions.runner.<org>-<repo>.<runner-name>.service
```

Add:
```ini
[Service]
Environment="ANTHROPIC_API_KEY=sk-ant-..."
```

Then reload and restart:
```bash
sudo systemctl daemon-reload
sudo systemctl restart actions.runner.<org>-<repo>.<runner-name>.service
```

Verify the CLI works:
```bash
claude --version
```

---

## Step 5: Set Up the Bot's Git and GitHub CLI Credentials on the Runner

The dispatch scripts use `gh` and `git` on the runner as the bot account. Configure both:

```bash
# Authenticate gh as the bot account using the PAT you created in Step 2
echo "ghp_YOUR_BOT_PAT" | gh auth login --with-token --hostname github.com

# Verify
gh auth status
# Should show: Logged in to github.com as my-project-bot

# Configure git credentials so pushes authenticate as the bot
git config --global credential.helper store
echo "https://my-project-bot:ghp_YOUR_BOT_PAT@github.com" >> ~/.git-credentials

# Set git identity for commits
git config --global user.name "my-project-bot"
git config --global user.email "my-project-bot@users.noreply.github.com"
```

Replace `my-project-bot` and `ghp_YOUR_BOT_PAT` with your actual bot username and PAT.

---

## Step 6: Choose a Setup Mode

claude-agent-dispatch supports two modes. Choose based on your needs:

### Reference mode (recommended)

Thin caller workflow files live in your target repo and call back to the upstream `claude-agent-dispatch` reusable workflows. Scripts run from a clone of this repo on the runner.

**Pros:**
- Minimal files added to your repo (just 5 small workflow YAMLs)
- Automatic updates when the upstream repo releases new versions
- Clean separation between your code and agent infrastructure

**Cons:**
- Requires cloning this repo on every runner
- Depends on an external repository being available
- Updates could introduce breaking changes (pin to a version tag to mitigate)

### Standalone mode

All scripts, prompts, and workflow files are copied directly into your target repo under `.agent-dispatch/`. No external dependency.

**Pros:**
- Full control over every file -- customize freely
- No external dependency at runtime
- Everything is versioned alongside your project

**Cons:**
- More files in your repo
- No automatic updates -- you must manually sync improvements
- Prompt and script drift if the upstream evolves

---

## Step 7: Run Setup

You can run setup in two ways: interactively with the Claude Code `/setup` skill, or with the `setup.sh` shell script.

### Option A: `/setup` skill (if you have Claude Code locally)

Open Claude Code in the `claude-agent-dispatch` directory and run:

```
/setup your-org/your-repo
```

This walks you through every step interactively with explanations and validation.

### Option B: `setup.sh` script

```bash
cd ~/agent-infra   # or wherever you cloned claude-agent-dispatch
./scripts/setup.sh
```

The wizard will prompt you for:
- Setup mode (reference or standalone)
- Target repository (`owner/repo`)
- Bot account username
- Default branch (usually `main`)
- Test command (optional, e.g., `npm test`, `pytest`)
- Extra tools (optional, e.g., `Bash(npm:*)`)

It then:
1. Generates `config.env` with your settings
2. Creates the required labels on your target repo via `gh`
3. Generates workflow files for your chosen mode
4. Guides you through setting the `AGENT_PAT` secret

### Reference mode post-setup

If you chose reference mode, you also need to clone this repo on the runner:

```bash
git clone https://github.com/jnurre64/claude-agent-dispatch.git ~/agent-infra
cp config.env ~/agent-infra/config.env
```

---

## Step 8: Add Secrets to the Target Repo

Your target repo needs at least one GitHub Actions secret:

### AGENT_PAT (required)

The bot account's fine-grained PAT. Used by all agent workflows.

```bash
gh secret set AGENT_PAT --repo your-org/your-repo
# Paste the PAT when prompted
```

Or set it through the GitHub web UI: **Settings > Secrets and variables > Actions > New repository secret**.

### AGENT_GIST_PAT (optional)

A classic PAT with the `gist` scope, used by the cleanup workflow to list and delete orphaned gists created during agent runs. Fine-grained PATs do not support gist permissions, so a classic token is needed for this.

```bash
gh secret set AGENT_GIST_PAT --repo your-org/your-repo
```

If you skip this, the cleanup workflow will simply skip gist cleanup.

---

## Step 9: Add the Bot as a Collaborator

The bot account needs write access to the target repo so it can push branches, manage labels, and create PRs.

```bash
gh api repos/your-org/your-repo/collaborators/my-project-bot \
  -X PUT -f permission=write
```

Or through the web UI: **Settings > Collaborators > Add people**, search for the bot username, and grant **Write** access.

Accept the invitation by logging in as the bot account (check email or visit `https://github.com/notifications`).

---

## Step 10: Commit and Push Workflow Files

If setup generated workflow files locally, commit and push them to your target repo:

```bash
cd /path/to/your-repo
git add .github/workflows/agent-*.yml
git commit -m "Add claude-agent-dispatch workflow files"
git push
```

For standalone mode, also commit the `.agent-dispatch/` directory:

```bash
git add .agent-dispatch/
git add .github/workflows/agent-*.yml
git commit -m "Add claude-agent-dispatch (standalone mode)"
git push
```

---

## Step 11: Test with a Dry-Run Issue

Create a simple test issue to verify everything works end to end:

1. Go to your target repo on GitHub
2. Create a new issue:
   - **Title**: `Test: verify agent dispatch is working`
   - **Body**: `This is a test issue. The agent should triage this and post a plan. No code changes are needed -- just verify the pipeline works.`
3. Add the **`agent`** label to the issue

### What to expect

Once you add the `agent` label, this sequence happens:

1. **Triage workflow fires** -- check the Actions tab to see it start
2. The agent reads the issue, explores the codebase, and decides what to do
3. Within a few minutes, the agent posts a **plan comment** on the issue
4. The label changes from `agent` to `agent:triage` and then to `agent:plan-review`
5. You can now review the plan

If something goes wrong, the label changes to `agent:failed`. Check the workflow run logs in the Actions tab for details.

To continue past the test:
- Add the `agent:plan-approved` label to trigger implementation
- The agent will implement, run tests (if configured), push a branch, and create a PR
- The label progresses through `agent:in-progress` to `agent:pr-open`

---

## The Label Flow

The agent uses a label state machine to track progress. Only one `agent:*` label is active at a time.

```
Human adds "agent" label
  |
  v
agent:triage            Agent is analyzing the issue
  |
  +---> agent:needs-info    Agent asked questions, waiting for human reply
  |       |
  |       +---> (human replies) ---> agent:ready ---> agent:plan-review
  |
  +---> agent:plan-review   Agent posted a plan, awaiting approval
          |
          +---> (human adds agent:plan-approved)
                  |
                  v
                agent:in-progress   Agent is implementing
                  |
                  v
                agent:pr-open       PR created, awaiting review
                  |
                  +---> (reviewer requests changes) ---> agent:revision ---> agent:pr-open
                  |
                  +---> (approved & merged) ---> labels removed
```

At any point, if the agent encounters an unrecoverable error, the label is set to `agent:failed`.

### Alternative: Direct Implementation

If your issue already contains a complete implementation plan (detailed steps, file paths, expected changes), you can skip triage entirely by adding the `agent:implement` label instead of `agent`.

When you use `agent:implement`:

1. The agent validates the plan in the issue body against the current codebase
2. If the plan is valid, the agent proceeds directly to implementation (no separate approval step)
3. If validation finds issues (missing files, outdated references, ambiguous steps), the agent posts its findings as a comment and sets `agent:needs-info` for you to address

This is useful when you have already written a detailed plan -- for example, from an interactive Claude Code session -- and want the agent to execute it without an extra triage round-trip.

### Retrying a failed issue

1. Check the workflow run logs in the Actions tab
2. Fix the underlying problem (unclear requirements, missing context, runner issue)
3. Remove all `agent:*` labels from the issue
4. Re-add the `agent` label from a human account (not the bot)

The `agent` label must be added by a non-bot account to pass the actor filter.

---

## Configuration Reference

After setup, your `config.env` controls agent behavior. See `config.env.example` for all options:

| Setting | Default | Description |
|---------|---------|-------------|
| `AGENT_BOT_USER` | *(required)* | Bot account username |
| `AGENT_MAX_TURNS` | 200 | Max Claude conversation turns per invocation |
| `AGENT_TIMEOUT` | 3600 | Seconds before killing a stuck process |
| `AGENT_CIRCUIT_BREAKER_LIMIT` | 8 | Max bot comments per hour per issue |
| `AGENT_TEST_COMMAND` | *(unset)* | Pre-PR test gate command |
| `AGENT_EXTRA_TOOLS` | *(unset)* | Project-specific tools to allow |
| `AGENT_PROMPT_*` | *(built-in)* | Paths to custom prompt files |

---

## Troubleshooting

**Workflow does not trigger when I add the label**
- Verify the workflow files are on the default branch (usually `main`)
- Check that the runner is online: **Settings > Actions > Runners**
- Make sure the label was added by a human account, not the bot

**Agent posts "circuit breaker tripped"**
- The bot hit the comment rate limit (default: 8/hour/issue)
- Wait an hour, then remove `agent:failed` and re-add `agent`

**Agent fails with authentication errors**
- Verify the `AGENT_PAT` secret is set and not expired
- Verify `gh auth status` on the runner shows the bot account
- Check that the bot has write access to the repo

**Agent creates a PR but tests fail**
- If `AGENT_TEST_COMMAND` is set, the agent runs tests before creating the PR
- If tests fail, the label is set to `agent:failed` instead of `agent:pr-open`
- Review the workflow logs for test output

---

## Next Steps

- Read [bot-account.md](bot-account.md) for detailed bot account and PAT management
- Customize prompts in `prompts/` (or via `AGENT_PROMPT_*` in config.env) to match your project's conventions
- Create a `CLAUDE.md` in your target repo with project context -- the agent reads it during triage
- Set up branch protection rules on your default branch to require PR approval before merging
