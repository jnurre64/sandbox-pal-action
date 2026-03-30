# Security

## Threat Model

An autonomous agent that reads GitHub issues, writes code, and creates PRs introduces several categories of risk. This document describes the threats, the mitigations built into the system, and a checklist for periodic review.

### Prompt Injection via Issues

Anyone who can create an issue or comment in your repository can influence the agent's behavior. A malicious actor could craft issue text or comment content that attempts to:

- Instruct the agent to modify sensitive files (workflows, CI config, credentials)
- Exfiltrate secrets by embedding them in commit messages or comments
- Introduce backdoors in generated code
- Trigger excessive API calls or resource consumption

**Mitigations**: Tool allowlists prevent the agent from accessing the network, pushing code, or running arbitrary commands. CLAUDE.md rules instruct the agent to never modify sensitive files. Branch protection ensures a human reviews all changes before merging. Issue content is passed via environment variables, not shell-interpolated.

### Runaway Loops

Without safeguards, the bot's own actions (comments, label changes) could re-trigger workflows, creating an infinite loop that burns through API quota and runner time.

**Mitigations**: Actor filters (`github.actor != 'your-bot'`) on every workflow prevent the bot from triggering its own workflows. The circuit breaker halts the agent if it posts too many comments per hour on a single issue. Timeouts kill stuck processes. Concurrency groups prevent parallel runs on the same issue.

### Credential Exposure

The bot's PAT has write access to the repository. If exposed, an attacker could push arbitrary code, modify branches, or access private repository data.

**Mitigations**: The PAT is stored as a GitHub Actions secret and injected via environment variable at runtime. It is never written to workflow files, committed to the repository, or logged. Fine-grained PATs scope access to specific repositories and permissions. The agent's tool restrictions prevent it from reading or exfiltrating environment variables.

### Malicious Debug Data

Users can attach gists, file uploads, and inline data to issues and PR comments. This data is pre-fetched and presented to Claude as local files. Malicious content could attempt prompt injection through data payloads.

**Mitigations**: All user-submitted data is framed as "untrusted" in the agent prompt. Tool restrictions prevent the agent from making network requests (`curl`, `wget` are not in the allowlist), so even if prompt injection succeeds in the data-reading phase, the agent cannot exfiltrate information over the network. The agent can only use the tools explicitly listed in `--allowedTools`.

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

Claude Code's `--allowedTools` flag restricts which tools the agent can use. The system uses phase-specific allowlists:

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

Additionally, `--disallowedTools` blocks `mcp__github__*` by default to prevent the agent from using MCP GitHub tools that could conflict with the script's own `gh` CLI operations.

### Timeouts

Two layers of timeout protection:

1. **Process timeout**: `AGENT_TIMEOUT` (default: 3600s) kills a stuck `claude -p` process via the `timeout` command
2. **Workflow timeout**: `timeout-minutes` on the GitHub Actions job (default: 125 minutes) kills the entire job if the process timeout fails

### Concurrency Groups

Each reusable workflow uses a concurrency group keyed by issue or PR number:

```yaml
concurrency:
  group: claude-agent-${{ github.event.issue.number }}
  cancel-in-progress: false
```

`cancel-in-progress: false` means concurrent jobs for the same issue are queued, not cancelled. This prevents race conditions where two agent runs modify the same branch simultaneously.

### Environment Variable Injection

Issue titles, bodies, and comments are passed to Claude via environment variables (`AGENT_ISSUE_TITLE`, `AGENT_ISSUE_BODY`, `AGENT_COMMENTS`, etc.), never interpolated into shell commands or prompt strings. This prevents shell injection from crafted issue content.

### Pre-PR Test Gate

If `AGENT_TEST_COMMAND` is configured, the dispatch script runs the test suite after implementation and before creating a PR. If tests fail, the agent sets `agent:failed` and posts the test output -- no PR is created with broken code.

### Data Privacy

Issue content (titles, bodies, comments, attached gists/files) is sent to the Anthropic API for inference. This is the same trust boundary as using Claude Code interactively on your codebase.

**Best practices:**
- Never put secrets, API keys, passwords, or credentials in GitHub issues -- this is a GitHub best practice regardless of whether agents are involved
- Avoid including personally identifiable information (PII) in issue descriptions
- If your organization has data residency requirements (GDPR, etc.), verify that Anthropic's data processing locations are acceptable
- Review Anthropic's privacy policy for data retention terms

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

### Branch Protection

- [ ] Main branch requires pull request before merging
- [ ] Main branch requires at least 1 approval from a human reviewer
- [ ] Bot account cannot approve its own PRs (enforced by GitHub -- PR authors cannot approve)
- [ ] Force pushes to main are disabled

### Agent Safety

- [ ] Actor filter (`github.actor != 'your-bot'`) is present on every caller workflow
- [ ] Comment/review user login filter is present on reply and review caller workflows
- [ ] Circuit breaker limit is set appropriately (default: 8 comments/hour)
- [ ] `--allowedTools` restricts agent capabilities in both triage and implementation modes
- [ ] `--disallowedTools` blocks MCP GitHub tools (or other tools that could bypass restrictions)
- [ ] `git push` is handled only by the dispatch script, never by Claude directly
- [ ] `CLAUDE.md` instructs the agent to never modify `.github/workflows/`, CI/CD, or security files
- [ ] Issue content is passed via environment variables (not shell-interpolated in prompts)

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
- Agent log files on the runner (`~/.claude/agent-logs/agent-dispatch.log`)
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
