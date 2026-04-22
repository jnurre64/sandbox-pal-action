# Self-Hosted Runner Setup

## Why Self-Hosted Runners

Claude Agent Dispatch requires self-hosted GitHub Actions runners because:

- **Claude Code CLI**: The `claude` CLI must be installed on the runner. GitHub-hosted runners do not have it pre-installed, and installing it fresh on every run would add latency and complexity.
- **Persistent state**: The dispatch script maintains per-runner repository clones and git worktrees that persist across workflow runs. This avoids re-cloning the entire repository for every agent invocation and allows the plan phase to leave a worktree for the implement phase to reuse.
- **Project-specific tooling**: Your project may require build tools, test frameworks, or runtime environments that are impractical to install on every run.
- **Performance**: Self-hosted runners avoid the startup overhead of provisioning a fresh container for each job.

## Security Warning: Public Repositories

> **Self-hosted runners on public repositories are a security risk.** GitHub explicitly warns against this. Anyone who forks a public repo can open a PR that potentially executes code on your runner, gaining access to environment variables (including API keys), the filesystem, and network resources.

If your target repo is public:
- **Strongly consider making it private** before adding self-hosted runners
- If it must be public, require approval for all fork PR workflows (Settings > Actions > General > Fork pull request workflows)
- See [docs/security.md](security.md) for the full threat model and hardening checklist
- Claude Agent Dispatch triggers on `issues` and `issue_comment` events (not fork PRs), which limits exposure, but secrets on the runner are still at risk if any workflow runs fork PR code

For most users, **org-level runners + private repos** is the simplest and most secure pattern.

## Prerequisites

The runner machine needs the following installed:

| Tool | Purpose | Install |
|------|---------|---------|
| **Linux** (recommended) | Host OS | Ubuntu 22.04+ or similar |
| **Node.js** (18+) | Required by Claude Code | Via [nvm](https://github.com/nvm-sh/nvm) or system package |
| **Claude Code** | The AI agent CLI | `npm install -g @anthropic-ai/claude-code` |
| **gh** | GitHub CLI for API operations | [cli.github.com](https://cli.github.com/) |
| **git** | Version control | System package |
| **jq** | JSON processing in shell scripts | System package |
| **curl** | Downloading attachments | System package |

Verify the tools are available:

```bash
node --version       # v18+ required
claude --version     # Claude Code CLI
gh --version         # GitHub CLI
git --version
jq --version
```

## Installing a GitHub Actions Runner

Full instructions are in the [GitHub docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners).

### Runner registration scope

| Scope | Best for | Token source |
|-------|----------|-------------|
| **Repository** | Single-repo setups, personal accounts | Repo Settings > Actions > Runners > New self-hosted runner |
| **Organization** | Multi-repo setups, teams | Org Settings > Actions > Runners > New self-hosted runner |

GitHub does not support user-level runners for personal accounts. If your repo is under a personal account (not an org), you must use repo-level registration.

### Installation steps

Navigate to the runner setup page in GitHub to get the correct download URL and registration token for your context:
- **Org:** `https://github.com/organizations/<your-org>/settings/actions/runners/new`
- **Repo:** `https://github.com/<owner>/<repo>/settings/actions/runners/new`

The page shows the exact download URL, checksum, and token for your platform. Follow those instructions, then register with the appropriate labels:

```bash
# Create a directory for the runner
mkdir -p ~/actions-runner-<repo-name> && cd ~/actions-runner-<repo-name>

# Download and extract (use the URL from the GitHub UI — it has the current version)
# curl -o actions-runner-linux-x64.tar.gz -L <URL_FROM_GITHUB_UI>
# tar xzf actions-runner-linux-x64.tar.gz

# Configure the runner (token expires in 1 hour — generate it immediately before this)
./config.sh \
  --url https://github.com/<owner-or-org> \
  --token <TOKEN_FROM_GITHUB_UI> \
  --name <descriptive-runner-name> \
  --labels self-hosted,agent \
  --work _work

# Install and start as a systemd service
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start
```

## Installing Claude Code on the Runner

Install Claude Code globally so it is available to the runner process:

```bash
# If using nvm
nvm install 22
nvm use 22
npm install -g @anthropic-ai/claude-code

# Verify
claude --version
```

The dispatch script includes nvm sourcing as a fallback for systemd services (which do not source shell profiles):

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
```

Additionally, add the nvm/node path to the runner's `.env` file so systemd can find the `claude` binary:

```bash
# Add to <runner-dir>/.env (create if it doesn't exist)
echo "PATH=$HOME/.nvm/versions/node/$(node -v)/bin:$PATH" >> .env
```

## Credentials and API Keys

### Claude Code authentication

The Claude Code CLI must be authenticated on the runner. The dispatch scripts do not reference any credential environment variable — see [authentication.md](authentication.md) and Anthropic's [Claude Code authentication docs](https://code.claude.com/docs/en/authentication) for the available methods.

If you choose a method that uses environment variables, the runner's `.env` file (in the runner installation directory, not `~/.bashrc` — systemd services do not source shell profiles) is where the runner makes variables available to workflow jobs:

```bash
# The exact variable depends on the method you chose
chmod 600 .env
```

After configuring authentication (by whichever method), verify with `claude /status` on the runner before the first dispatch run.

**Security notes:**

- If `.env` holds any credential, it must be `chmod 600` (readable only by the runner user).
- Every workflow job on this runner can access credentials present in `.env`.
- If you want per-workflow injection instead, store the credential as a [GitHub Actions secret](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions) and reference it in the `env:` block of your workflow files.
- Refer to Anthropic's authentication docs for guidance on rotating or refreshing whichever credential type you chose.

### GitHub bot PAT

The bot's fine-grained PAT is injected via GitHub Actions secrets (`secrets.AGENT_PAT`) in the workflow files. It does not need to be stored on the runner's filesystem for normal operation.

If you need `gh` CLI access on the runner for manual operations:

```bash
# Authenticate gh CLI as the bot
echo "<PAT>" | gh auth login --with-token

# Secure the credential files
chmod 600 ~/.config/gh/hosts.yml
chmod 700 ~/.config/gh/
```

**PAT scope:** Use a fine-grained PAT with minimum permissions: Contents (read/write), Issues (read/write), Pull requests (read/write), Metadata (read). Set expiration to 90 days. See [docs/bot-account.md](bot-account.md) for full guidance.

### Git configuration for the bot

Configure git to use the bot identity for commits:

```bash
git config --global user.name "<bot-username>"
git config --global user.email "<bot-username>@users.noreply.github.com"
```

## Runner Labels

Labels control which runners pick up which workflow jobs. The reusable workflows accept a `runner_labels` input (default: `["self-hosted", "agent"]`).

Recommended label scheme:

| Label | Purpose | Used by |
|-------|---------|---------|
| `self-hosted` | Required by GitHub for all self-hosted runners | All workflows |
| `agent` | Marks runners that handle agent dispatch (triage, implement, reply, review) | `dispatch-triage.yml`, `dispatch-implement.yml`, `dispatch-reply.yml`, `dispatch-review.yml` |
| `cleanup` | Marks runners that handle periodic cleanup | `cleanup.yml` |
| `ci` | Marks runners that handle CI test suites | Your CI workflow |

A single runner can have multiple labels. For example, a flex runner with labels `agent`, `cleanup`, and `ci` can pick up any job type when other runners are busy.

Your caller workflows specify which labels to require:

```yaml
jobs:
  triage:
    uses: your-org/claude-pal-action/.github/workflows/dispatch-triage.yml@main
    with:
      bot_user: your-bot
      runner_labels: '["self-hosted", "agent"]'
    secrets:
      agent_pat: ${{ secrets.AGENT_PAT }}
```

### Changing Runner Labels

The easiest way is via the GitHub UI: **Settings -> Actions -> Runners** -> click the runner -> edit labels.

Alternatively, remove and reconfigure:

```bash
cd ~/actions-runner-<repo-name>
./config.sh remove
# Get a fresh registration token
./config.sh --url https://github.com/your-org --token NEW_TOKEN \
  --name agent-runner-1 --labels agent,cleanup --work _work
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start
```

## Per-Runner Isolation

When multiple runners handle agent workloads on the same machine, each runner needs its own repository clone and worktree directory to prevent git lock races.

The dispatch script uses the `RUNNER_NAME` environment variable (set automatically by GitHub Actions) to create isolated paths:

```
~/repos/
  <RUNNER_NAME>/
    your-repo/                     <-- this runner's clone (auto-created on first use)

~/.claude/worktrees/
  <RUNNER_NAME>/
    your-repo-issue-42/            <-- per-issue worktree
    your-repo-issue-43/            <-- no conflicts between concurrent issues
```

For example, with two runners named `AGENT-1` and `AGENT-2`:

```
~/repos/
  AGENT-1/your-repo/              <-- AGENT-1's clone
  AGENT-2/your-repo/              <-- AGENT-2's clone

~/.claude/worktrees/
  AGENT-1/your-repo-issue-42/     <-- AGENT-1 working on issue 42
  AGENT-2/your-repo-issue-43/     <-- AGENT-2 working on issue 43
```

The dispatch script creates these directories automatically. You do not need to pre-create them unless you want to pre-clone the repository for faster first runs:

```bash
mkdir -p ~/repos/AGENT-1
git clone https://github.com/your-org/your-repo.git ~/repos/AGENT-1/your-repo
```

## Multiple Runners on One Machine

For handling concurrent issues, register multiple runners on the same machine. Each runner is an independent process with its own directory:

```bash
# Runner 1: primary agent runner
mkdir -p ~/actions-runner-agent-1
cd ~/actions-runner-agent-1
# ... download, extract, configure with --name AGENT-1 --labels agent ...
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start

# Runner 2: overflow agent runner
mkdir -p ~/actions-runner-agent-2
cd ~/actions-runner-agent-2
# ... download, extract, configure with --name AGENT-2 --labels agent ...
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start

# Runner 3: dedicated to CI (no agent label)
mkdir -p ~/actions-runner-ci
cd ~/actions-runner-ci
# ... download, extract, configure with --name CI-1 --labels ci ...
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start
```

All runners share the same OS user, home directory, and installed tools (Claude Code, gh, git). Per-runner isolation via `RUNNER_NAME` prevents git conflicts.

**Resource considerations**: Agent work is primarily I/O-bound (API calls to Claude and GitHub). Multiple agent runners on the same machine rarely cause resource contention. CI test suites may be CPU-bound -- if your tests are heavy, consider dedicating a separate machine or runner for CI.

## Monitoring Runner Health

### From the GitHub UI

Navigate to your org or repo **Settings -> Actions -> Runners**. Each runner shows its status (Idle, Active, Offline).

### From the Command Line

Check systemd service status:

```bash
# Replace with your actual service name
# Service names follow the pattern: actions.runner.<org-or-repo>.<runner-name>.service
sudo systemctl status actions.runner.your-org.AGENT-1.service
```

View runner logs:

```bash
journalctl -u actions.runner.your-org.AGENT-1.service -f
```

Check agent dispatch logs:

```bash
tail -f ~/.claude/agent-logs/agent-dispatch.log
```

List recent Claude stderr logs (non-empty files indicate errors):

```bash
ls -lt ~/.claude/agent-logs/claude-stderr-*.log | head -10
```

### Quick Health Check Script

```bash
#!/bin/bash
# Check all runner services on this machine
for svc in $(systemctl list-units --type=service --state=running \
  | grep actions.runner | awk '{print $1}'); do
  status=$(systemctl is-active "$svc")
  echo "$svc: $status"
done

# Check disk space (worktrees accumulate)
echo ""
echo "Disk usage:"
du -sh ~/repos/ ~/.claude/worktrees/ ~/.claude/agent-logs/ 2>/dev/null
```

## Systemd Service Setup

The GitHub Actions runner includes built-in systemd support. After configuring a runner:

```bash
# Install the service (runs as the specified user)
sudo ./svc.sh install $(whoami)

# Start the service
sudo ./svc.sh start

# Check status
sudo ./svc.sh status

# Stop the service
sudo ./svc.sh stop

# Uninstall the service
sudo ./svc.sh uninstall
```

The service starts automatically on boot. The runner auto-updates itself when GitHub releases new runner versions.

For full details on runner service management, see the [GitHub documentation on configuring the self-hosted runner application as a service](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/configuring-the-self-hosted-runner-application-as-a-service).

### Notes

- **Same OS user**: All runners on a machine typically share a single OS user. This is fine for single-developer or small-team setups. For stronger isolation between runners, create separate OS users.
- **Shared filesystem**: Runners share the home directory. The dispatch script, Claude Code, `gh`, and `git` are installed once. Only the per-runner repo clones and worktrees are isolated.
- **Runner auto-updates**: GitHub pushes runner updates automatically. You do not need to manage runner versions.
- **Credential file permissions**: Ensure `chmod 600` on the runner `.env` file, `~/.config/gh/hosts.yml`, and `~/.git-credentials`. Ensure `chmod 700` on `~/.config/gh/`.
- **Removing a runner**: Stop the service, uninstall it, remove the runner from GitHub UI (or `./config.sh remove`), then delete the directory and its isolation directories under `~/repos/<RUNNER_NAME>` and `~/.claude/worktrees/<RUNNER_NAME>`.
