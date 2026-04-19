# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly:

1. **Do not** open a public issue for security vulnerabilities
2. Open a [private security advisory](https://github.com/jnurre64/claude-pal-action/security/advisories/new) on this repository
3. Or contact the maintainer directly

## Security Considerations

This project handles sensitive infrastructure:

- **GitHub Personal Access Tokens (PATs)** — stored as GitHub Secrets, never committed to code
- **Bot account credentials** — used for automated git operations and GitHub API calls
- **Claude API keys** — passed via environment variables

### Best Practices for Users

- Use **fine-grained PATs** with minimum required permissions
- Use a **dedicated bot account** (not your personal account) for agent operations
- Enable **branch protection** on your main branch (require PR + approval)
- Review the agent's PRs before merging — the agent is a tool, not a trusted committer
- Regularly rotate PATs (see `docs/pat-rotation.md` when available)
- Restrict runner access — the self-hosted runner has push access to your repos

## Supported Versions

Only the latest version is supported with security updates.
