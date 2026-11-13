# Security

## Threat Model

An autonomous agent that reads GitHub issues, writes code, and creates PRs introduces several categories of risk. This document describes the threats, the mitigations built into the system, and a checklist for periodic review.

### Prompt Injection via Issues

Anyone who can create an issue or comment in your repository can influence the agent's behavior. A malicious actor could craft issue text or comment content that attempts to:

- Instruct the agent to modify sensitive files (workflows, CI config, credentials)
- Exfiltrate secrets by embedding them in commit messages or comments
- Introduce backdoors in generated code
- Trigger excessive API calls or resource consumption

**Mitigations**: Tool allowlists narrow what the agent is asked to do, and a phase is launched without the dispatcher's credentials (see [Phase Environment](#phase-environment)), so a steered phase has no token to push or post with. The allowlist on its own is not a security boundary: Claude Code documents Bash permission rules as a convenience, not a sandbox. CLAUDE.md rules instruct the agent to never modify sensitive files. Branch protection ensures a human reviews all changes before merging. Issue content is passed via environment variables, not shell-interpolated.

**Plan-comment branch marker**: An interactively-authored plan comment can carry a `<!-- agent-branch: ... -->` marker (`extract_plan_branch` in `scripts/lib/common.sh`) naming the pre-pushed branch the implement phase should build on. Plan comments are not author-filtered, so this marker is validated defense-in-depth: charset-restricted (`[A-Za-z0-9._/-]`), must be namespaced (contain at least one `/`, ruling out `main`/`master` and any other un-namespaced branch), must not equal `main` or `master` exactly, and no `/`-separated segment may start with `-` (which could otherwise be interpreted as an option by a downstream `git`/`gh` invocation). Residual risk: a malicious commenter can still redirect the implement phase to any *existing, non-protected, already-namespaced* branch in the repo (e.g. another open feature branch) — branch protection and PR review remain the backstop for what actually lands on `main`.

### Runaway Loops

Without safeguards, the bot's own actions (comments, label changes) could re-trigger workflows, creating an infinite loop that burns through API quota and runner time.

**Mitigations**: Actor filters (`github.actor != 'your-bot'`) on every workflow prevent the bot from triggering its own workflows. The circuit breaker halts the agent if it posts too many comments per hour on a single issue. Timeouts kill stuck processes. Concurrency groups prevent parallel runs on the same issue.

### Credential Exposure

The bot's PAT has write access to the repository. If exposed, an attacker could push arbitrary code, modify branches, or access private repository data.

**Mitigations**: The PAT is stored as a GitHub Actions secret and injected via environment variable at runtime. It is never written to workflow files, committed to the repository, or logged. Fine-grained PATs scope access to specific repositories and permissions. The token is removed from the environment of every phase before the worker starts (see [Phase Environment](#phase-environment)); only the dispatch script, which does all GitHub reads and writes, holds it. Tool restrictions are not what keeps the token from a phase: allowed commands such as `cat` and `find`, or an interpreter added through `AGENT_EXTRA_TOOLS`, are enough to read an environment.

### Malicious Debug Data

Users can attach gists, file uploads, and inline data to issues and PR comments. This data is pre-fetched and presented to Claude as local files. Malicious content could attempt prompt injection through data payloads.

**Mitigations**: All user-submitted data is framed as "untrusted" in the agent prompt. The phase holds no dispatcher credential to exfiltrate (see [Phase Environment](#phase-environment)). `curl` and `wget` are not in the allowlist, which removes the obvious route to the network, but an allowlist is not a network boundary; blocking egress needs a sandbox or host-level controls.

## Built-in Safety Mechanisms

### Actor Filter

Every caller workflow must include a condition like:

```yaml
if: github.event.label.name == 'agent' && github.actor != 'your-bot'
```

This prevents the bot's own label changes and comments from re-triggering workflows. The filter must check against the bot username on every event type:
- `github.actor != 'your-bot'` for label events
- `github.event.comment.user.login != 'your-bot'` for issue comment events
- `github.event.review.user.login != 'your-bot'` for PR review events

### Circuit Breaker

The dispatch script counts bot comments on the current issue within the last hour. If the count exceeds `AGENT_CIRCUIT_BREAKER_LIMIT` (default: 8), the agent halts immediately, sets `agent:failed`, and posts a warning comment.

This catches loops that bypass actor filters (e.g., if a second workflow or external integration re-triggers the agent).

### Tool Allowlists

Claude Code's permission allow rules restrict which tools the agent can use. The dispatch script writes them into the settings file each phase is launched with. The system uses phase-specific allowlists:

**Triage/Reply (read-only)**:
```
Read, Grep, Glob, Bash(echo:*), Bash(cat:*), Bash(ls:*), Bash(find:*)
```

**Implementation/Review (read-write)**:
```
Read, Edit, Write, Grep, Glob, Bash(git add:*), Bash(git commit:*),
Bash(git status), Bash(git diff:*), Bash(git log:*), Bash(ls:*),
Bash(cat:*), Bash(grep:*), Bash(find:*), Bash(mkdir:*)
```

Notable exclusions from all phases:
- `git push` -- handled by the dispatch script after validation
- `sudo` -- no privilege escalation
- `curl`, `wget` -- no network access
- `rm -rf` -- no destructive filesystem operations

Additionally, a deny rule blocks `mcp__github__*` by default to prevent the agent from using MCP GitHub tools that could conflict with the script's own `gh` CLI operations.

### Timeouts

Two layers of timeout protection:

1. **Process timeout**: `AGENT_TIMEOUT` (default: 3600s) kills a stuck `claude -p` process via the `timeout` command
2. **Workflow timeout**: `timeout-minutes` on the GitHub Actions job (default: 125 minutes) kills the entire job if the process timeout fails

### Concurrency Groups

Each reusable workflow uses a concurrency group keyed by workflow type and issue or PR number:

```yaml
concurrency:
  group: sandbox-pal-triage-${{ github.event.issue.number }}
  cancel-in-progress: false
```

Groups are workflow-specific (e.g., `sandbox-pal-triage-96`, `sandbox-pal-implement-96`) so that label changes during a run don't cause other workflows to compete in the same group. `cancel-in-progress: false` means concurrent jobs for the same workflow and issue are queued, not cancelled.

### Issue Text Is Data, Never Code

Issue titles, bodies, comments, review text and referenced issues are written to files under `.agent-data/context/` in the worktree, which the agent reads with the Read tool. They are never interpolated into shell commands or prompt strings, which prevents shell injection from crafted issue content. (The same values are still exported as `AGENT_*` environment variables for older custom prompts.)

This does not stop the text from trying to steer the agent: it is untrusted input the model reads. What a steered phase can reach is limited by the phase environment and settings below, not by how the text is delivered.

### Pipeline-Owned Settings

Each Claude phase is launched with a settings file the dispatch script generates for that run, holding the phase's permission rules, and with `--setting-sources`. With `AGENT_SETTING_SOURCES="project"` a phase does not read the operator's user settings, so hooks, plugins and allow rules that one person added on their machine are not silently part of every unattended run. The default still reads them, to leave existing installs unchanged. Note that `claude -p` loads a project's own hooks and `.mcp.json` without a trust dialog: what a phase loads from the repository is whatever is committed there.

### Pre-PR Test Gate

If `AGENT_TEST_COMMAND` is configured, the dispatch script runs the test suite after implementation and before creating a PR. If tests fail, the agent sets `agent:failed` and posts the test output -- no PR is created with broken code.

### Alignment with Industry Standards

The safety mechanisms above align with emerging industry frameworks for autonomous AI agents, including the [OWASP Top 10 for Agentic Applications](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/) (principle of least agency — only grant agents the minimum autonomy required for safe, bounded tasks) and the [NVIDIA AI Red Team's recommended controls](https://developer.nvidia.com/blog/securing-ai-agents-best-practices-from-nvidias-ai-red-team/) for autonomous agents (network egress restrictions, file write restrictions, approval architecture).

### Phase Environment

The dispatch script does every GitHub read and write and sends every notification itself, before and after a phase. No default prompt calls `gh`. A phase therefore needs none of the dispatcher's credentials, and both worker engines are launched with these variables removed:

```
GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN, GITHUB_ENTERPRISE_TOKEN,
AGENT_GIST_PAT,
AGENT_NOTIFY_DISCORD_WEBHOOK, AGENT_NOTIFY_DISCORD_WEBHOOK_MAP,
AGENT_NOTIFY_SLACK_WEBHOOK, AGENT_NOTIFY_SLACK_WEBHOOK_MAP,
AGENT_DISCORD_BOT_TOKEN, AGENT_SLACK_BOT_TOKEN, AGENT_SLACK_APP_TOKEN,
ACTIONS_RUNTIME_TOKEN, ACTIONS_ID_TOKEN_REQUEST_TOKEN
```

They are removed inside the engine's own subshell as the last step before the worker starts, so the dispatcher still has them when the phase returns. The model provider's own credential (an API key or a saved login) stays, because the worker cannot run without it.

- `AGENT_PHASE_SCRUB_ENV` — space-separated names of further variables to remove, for a project whose environment carries other secrets (a deploy key, a registry password).
- `AGENT_PHASE_KEEP_ENV` — space-separated names to leave in place, for a project whose custom prompts really do need one. Keeping `GH_TOKEN` gives every phase a token that can push and write issues; prefer moving that work into the dispatcher.

Startup logs which of these variables were set and withheld, and which were kept, by name only.

**Limits.** This removes credentials from the environment, not from the machine. A phase runs as the same OS user as the dispatcher, so a token on disk (a `gh` login, a git credential helper, a config file holding a secret) is still readable by it. The `strict` sandbox profile closes it for the credential stores it hides: see [Sandbox Profile](#sandbox-profile) and [sandbox.md](sandbox.md). Claude Code's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` is not set by the dispatcher: as of CLI 2.1.322 it requires bubblewrap on Linux and forces the default permission mode, which would change how every phase runs, and it leaves `GH_TOKEN`/`GITHUB_TOKEN` in place. The `strict` profile does not set it either: the whole phase is already inside the sandbox.

### Sandbox Profile

With `AGENT_SANDBOX="strict"` a Claude phase runs under Anthropic's sandbox runtime (`srt`, which uses bubblewrap on Linux). The whole process is inside: shell commands, the model's own file tools, hooks and MCP servers. It is off by default; [sandbox.md](sandbox.md) has the setup and the full lists.

What it enforces, checked by a canary test against the real runtime:

- **Writes** go only to the worktree, the clone's `.git` (which a worktree needs), the temp directory and the Claude config directory. The clone's `.git/hooks` and `.git/config` are write-denied, and so are the Claude settings, skills, plugins, commands, agents and hooks, because those decide what a later unsandboxed session runs.
- **Credential stores are absent**: SSH and GPG keys, the `gh` login, cloud CLI credentials, `.netrc`, package-registry tokens, `.env` files in the worktree, the install's `config.env`, and whatever `AGENT_SANDBOX_DENY_READ` names.
- **The network** reaches the model provider, GitHub, and the hosts in `AGENT_SANDBOX_ALLOWED_DOMAINS`. Everything else is refused, including services on the host's own loopback and LAN addresses.
- **It fails closed.** A profile that is asked for and cannot start is a configuration error and no phase runs.

What it does not do. State these limits plainly when describing the setup to others:

- **An allowed host is a way out.** A steered phase can send what it can read to any host on the allowlist, GitHub included, for example by pushing to a repository of the attacker's with a token the attacker supplied in the issue text. The allowlist narrows where data can go; it does not make a leak impossible. What limits the damage is how little a phase can read: no dispatcher token, hidden credential stores, and a phase token that is read-only.
- **The model provider's login is readable.** The worker cannot run without it. A phase can read the Claude login and send it to an allowed host.
- **Other files in the home directory are readable** unless you list them. The profile hides known credential stores, not everything. Put directories of tokens in `AGENT_SANDBOX_DENY_READ`.
- **`AGENT_SANDBOX_UNIX_SOCKETS=true` removes the socket filter**, so any Unix socket the process can see is reachable (a Docker socket, an SSH agent). Use it only where a display server is needed.
- **The runtime is a beta research preview** and is not a substitute for a VM or container when the code being run is hostile by assumption.
- **Phases still run as the dispatcher's OS user.** A dedicated user for phases is a separate, stronger boundary and is not provided here.
- **Codex phases are not wrapped.** Asking for `strict` on a Codex phase is refused; use that engine's own sandbox setting.

### The Phase's GitHub Token

No phase receives the dispatcher's token. Under `strict` a phase cannot read a stored `gh` login either, so without anything else it cannot look at another issue or pull request. `AGENT_PHASE_GH_TOKEN_FILE` names a file holding a token that is exported to each phase as `GH_TOKEN`.

Make it a fine-grained token with read-only access (Contents, Issues, Pull requests, Actions) to the repositories the pipeline works on. The dispatcher keeps doing every write. The dispatcher cannot check a token's permissions: a write-capable token in this file gives every phase write access. The value is read at launch, never placed in configuration, hidden from the sandboxed phase as a file, and redacted from phase output.

### Phase Output Redaction

Everything a phase session outputs — the JSON envelope on stdout and the CLI's stderr log — is scrubbed by `redact_secrets` at the point of capture in `run_claude`, before it reaches any log line, saved file, parse, or issue/PR comment. Two match classes are covered:

1. **Well-known token shapes**: `github_pat_…`, `gh[pousr]_…` (classic PATs, OAuth, server/user/refresh tokens), and the value following an `Authorization: token|bearer|basic` header.
2. **The literal value of every credential-looking environment variable** in the dispatch process — names matching `TOKEN`, `SECRET`, `PASSWORD`, `API_KEY`/`APIKEY`, or `CREDENTIAL`. The dispatcher's own credentials are no longer passed to a phase (see [Phase Environment](#phase-environment)), but one kept with `AGENT_PHASE_KEEP_ENV`, an engine credential, or a secret read from disk can still surface, so the exact values are replaced wherever they appear.

**Why it exists**: deny rules are the first line of defence, but a *denied* command is echoed verbatim to explain the denial — which is precisely where a credential surfaces. In a reference implementation of this pipeline, a phase typed a bot PAT into a denied `curl` and the harness echoed the denied command, token included, into the log and the transcript. The deny rule worked; the reporting path leaked.

**Limits** (redaction is the second line of defence, not a guarantee):
- Environment-variable matching is by name convention — a secret in an unconventionally named variable (e.g. `MY_VALUE`) is not caught by class 2, only by class 1 if its shape is recognizable.
- Values shorter than 8 characters are deliberately not replaced (scrubbing a 2-character password everywhere it appears would mangle ordinary text).
- A secret transformed by the phase (base64-encoded, split across lines) will not match either class.
- Secrets that exist only inside the phase's sandbox (fetched at runtime, never in the dispatch environment) are unknown to the filter.

The first line of defence is that a phase is not given the dispatcher's credentials at all. Deny rules, which this project configures by default, then narrow what a phase attempts; they are not a boundary on their own.

### Data Privacy

Issue content (titles, bodies, comments, attached gists/files) is sent to the Anthropic API for inference. This is the same trust boundary as using Claude Code interactively on your codebase.

**Best practices:**
- Never put secrets, API keys, passwords, or credentials in GitHub issues -- this is a GitHub best practice regardless of whether agents are involved
- Avoid including personally identifiable information (PII) in issue descriptions
- If your organization has data residency requirements (GDPR, etc.), verify that Anthropic's data processing locations are acceptable
- Review Anthropic's privacy policy for data retention terms

## Anthropic Authentication Model

Claude Code must be authenticated on the runner for the dispatch scripts to function. The scripts themselves are agnostic to the authentication method — the `claude -p` invocation in `scripts/lib/common.sh` does not reference any credential environment variable, and Claude Code's own authentication precedence handles the rest.

See [authentication.md](authentication.md) for the project's authentication notes and links to Anthropic's authoritative documentation (authentication methods, legal and compliance, Terms of Service, Acceptable Use Policy).

*This section describes an installation prerequisite. It is not legal advice — review Anthropic's current terms to confirm fit for your specific use.*

## Security Checklist

Review this checklist periodically and after any changes to the agent system.

### Authentication and Secrets

- [ ] Bot PAT is fine-grained and scoped to your specific org/repos only
- [ ] PAT has minimal permissions: Contents (read/write), Issues (read/write), Pull Requests (read/write), Metadata (read)
- [ ] PAT is not expired (check expiry date in bot account settings)
- [ ] PAT is stored as a GitHub Actions repository or organization secret (never in workflow files or code)
- [ ] `GITHUB_TOKEN` on the runner machine (if set in shell profile) is not committed to any repository
- [ ] `~/.git-credentials` on the runner is not committed to any repository
- [ ] No secrets appear in workflow logs (check recent runs)
- [ ] Claude Code is authenticated on the runner (`claude /status` confirms the expected account) and the authenticated account is appropriate for your intended use — see [authentication.md](authentication.md)

### Branch Protection

- [ ] Main branch requires pull request before merging
- [ ] Main branch requires at least 1 approval from a human reviewer
- [ ] Bot account cannot approve its own PRs (enforced by GitHub -- PR authors cannot approve)
- [ ] Force pushes to main are disabled

### Agent Safety

- [ ] Actor filter (`github.actor != 'your-bot'`) is present on every caller workflow
- [ ] Comment/review user login filter is present on reply and review caller workflows
- [ ] Circuit breaker limit is set appropriately (default: 8 comments/hour)
- [ ] Allow rules (`AGENT_ALLOWED_TOOLS_*`) restrict agent capabilities in both triage and implementation modes
- [ ] Deny rules (`AGENT_DISALLOWED_TOOLS`) block MCP GitHub tools (or other tools that could bypass restrictions)
- [ ] `git push` is handled only by the dispatch script, never by Claude directly
- [ ] `CLAUDE.md` instructs the agent to never modify `.github/workflows/`, CI/CD, or security files
- [ ] Phases run under `AGENT_SANDBOX="strict"`, or you have decided they need not, and directories holding tokens are in `AGENT_SANDBOX_DENY_READ`
- [ ] `AGENT_PHASE_GH_TOKEN_FILE`, if set, holds a read-only token
- [ ] Issue content is passed as files under `.agent-data/context/` (not shell-interpolated in prompts)

### Workflow Safety

- [ ] Workflow `timeout-minutes` is set on every job (recommended: 60-125 minutes)
- [ ] `AGENT_TIMEOUT` is set appropriately for the `claude -p` process (default: 3600s)
- [ ] `AGENT_MAX_TURNS` prevents runaway agent sessions (default: 200)
- [ ] Concurrency groups prevent parallel runs on the same issue/PR
- [ ] Workflows only run on self-hosted runners with the correct labels (e.g., `[self-hosted, agent]`)

### Runner Security

- [ ] Runners are registered at the org level (not on public repos where anyone can trigger workflows)
- [ ] Runners run under a non-root user
- [ ] `sudo` is not available to the agent (blocked by tool allowlist and optionally by system config)
- [ ] Runner services are configured to start on boot
- [ ] Per-runner repo isolation prevents git lock races between concurrent agents

### CLAUDE.md Rules

- [ ] Agent is instructed to never modify `.github/workflows/` files
- [ ] Agent is instructed to never modify CI/CD configuration files
- [ ] Agent is instructed to never modify security-sensitive files
- [ ] Agent is instructed to never commit secrets, credentials, or `.env` files

## Best Practices

### Use Minimum Permissions

Scope the bot's PAT to the narrowest set of permissions needed. A fine-grained PAT scoped to a single organization and specific repositories is strongly preferred over a classic PAT with broad access.

Required permissions for the bot PAT:
- **Contents**: Read and write (clone, push branches)
- **Issues**: Read and write (comment, manage labels)
- **Pull Requests**: Read and write (create PRs, respond to reviews)
- **Metadata**: Read (required by GitHub for all fine-grained PATs)

### Use a Dedicated Bot Account

Run the agent under a separate GitHub account, not your personal account. This provides:
- Clear audit trail of what the agent did vs what you did
- Actor filters can reliably distinguish bot actions from human actions
- The bot account can have different permissions than your account
- If the bot account is compromised, your personal account is unaffected

### Enable Branch Protection

At minimum:
- Require pull requests before merging to main
- Require at least 1 approval
- Do not allow the bot to bypass branch protection

The agent creates PRs but cannot merge them. A human must review and approve every change.

### Review Agent PRs Before Merging

The agent is a tool, not a trusted committer. Treat agent PRs with the same scrutiny as PRs from a junior developer:
- Read the diff carefully
- Verify the implementation matches the approved plan
- Check for unintended side effects
- Run the test suite locally if CI is not configured
- Look for subtle issues that automated tests might miss (security, performance, edge cases)

### Rotate the Bot PAT Periodically

Set an expiry date on the PAT and rotate it before expiry. Update the GitHub Actions secret with the new token. A good cadence is every 90 days.

### Monitor Agent Activity

Regularly review:
- Agent log files on the runner (`~/.claude/agent-logs/sandbox-pal-dispatch.log`)
- GitHub Actions workflow run history
- Issues and PRs created by the bot account
- Circuit breaker activations (search for `agent:failed` labels)

## What the System Does NOT Protect Against

The agent is a tool, not a trusted committer. These limitations are by design:

- **Subtle bugs in generated code**: The agent may write code that passes tests but has logical errors, performance issues, or security vulnerabilities. Human review is essential.
- **Social engineering of the reviewer**: If the plan looks good and the code looks plausible, a reviewer might approve without thorough examination. The agent does not replace careful code review.
- **Compromise of the runner machine**: If the self-hosted runner is compromised, all bets are off. The attacker has access to the PAT, the codebase, and the ability to push code. Secure the runner machine itself.
- **Compromise of the bot account**: If the bot's GitHub credentials are leaked, the attacker can push branches and create PRs. Branch protection limits the blast radius (they cannot merge to main without approval), but they can still access private repository content.
- **Abuse by authorized collaborators**: Anyone who can add the `agent` label can trigger the agent. If your repository has collaborators you don't fully trust, consider restricting who can manage labels.
- **Resource exhaustion**: A determined attacker who can create issues could trigger many agent runs, consuming runner time and API quota. The circuit breaker limits per-issue activity but does not limit across-issue volume.
