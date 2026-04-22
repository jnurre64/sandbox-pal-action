# Frequently Asked Questions

## Safety & Trust

### What if the AI writes plausible-looking but subtly wrong code?

The system has three checkpoints before any code reaches your main branch. First, the agent writes a plan — not code — and a human reviews the approach. If the plan is wrong, you reject it before a line is written. Second, the agent must pass your project's test suite before a PR is even created. Third, the PR goes through normal code review with branch protection — a human must approve the merge.

Treat agent PRs the way you'd treat any pull request from a new contributor: review every line.

### What about prompt injection from malicious issues?

The system defends at the tool level, not the prompt level. During triage, the agent is read-only — even if a malicious issue says "delete all files," the tools to do that don't exist in the agent's environment. During implementation, the agent can write files and git commit, but cannot push (the dispatch script handles that after validation), cannot access the network, and cannot sudo. Issue content is passed via environment variables, not shell interpolation, so shell injection doesn't work either.

### Who is accountable when the agent introduces a bug?

The system creates a clear chain of accountability documented in GitHub. The human who approves the plan authorized the approach. The human who merges the PR authorized the code. Both are timestamped with usernames in the issue and PR history. This is often better documentation than human-only workflows produce — every decision point is captured.

### What about data privacy?

Issue content — title, body, comments, and attached data — is sent to the Anthropic API for inference. This is the same trust boundary as using Claude Code interactively on your codebase. The mitigation is a best practice that applies regardless of tooling: don't put secrets, PII, or sensitive credentials in GitHub issues. See [security.md](security.md#data-privacy) for details and review [Anthropic's privacy policy](https://www.anthropic.com/privacy) for data handling specifics.

### Does this meet SOC2/HIPAA/PCI-DSS compliance requirements?

The audit trail exists natively in GitHub — every plan, approval, comment, commit, and PR review is timestamped and attributed. Many organizations already have GitHub covered under their compliance frameworks. The system enforces separation of duties (bot writes code, human approves) and creates an immutable change log in git history.

For formal compliance, evaluate Anthropic as a subprocessor under your organization's requirements, ensure log retention meets your standards, and document the agent in your change management process. This is a risk assessment exercise specific to your organization.

### Is this setup aligned with Anthropic's Terms of Service?

Whether the project's use aligns with Anthropic's Terms of Service depends on how you are using the project — your authentication choice, whether the runner serves one person or many, whether use is individual or commercial, and whether usage stays within Anthropic's "ordinary individual usage" boundaries for subscription plans. The project does not take a position on any of these: the dispatch scripts simply invoke the `claude` CLI and rely on Anthropic's authentication precedence.

Review Anthropic's authoritative pages for the applicable rules: [Claude Code Legal and Compliance](https://code.claude.com/docs/en/legal-and-compliance), [Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms), [Commercial Terms](https://www.anthropic.com/legal/commercial-terms), and the [Acceptable Use Policy](https://www.anthropic.com/legal/aup). See [authentication.md](authentication.md) for the project's notes on the installation prerequisite.

### Can I use my Pro/Max subscription instead of an API key?

Claude Code supports multiple authentication methods, including subscription-backed ones. Whether any specific method is appropriate for *your* use of this project is covered by Anthropic's terms, not by the project. See [authentication.md](authentication.md) and Anthropic's [Claude Code authentication docs](https://code.claude.com/docs/en/authentication).

## Usage

### Can it handle complex tasks?

The system handles well-scoped issues effectively — features, bug fixes, tests, documentation. For complex or architectural work, consider brainstorming the approach interactively with Claude Code first, then breaking it into well-defined issues for the agent. You can also swap to an interactive session at any point for hands-on troubleshooting. The two modes complement each other — interactive sessions for exploration and judgment calls, autonomous dispatch for execution.

### Won't this create more review work than it saves?

The plan review step catches bad approaches early — a couple minutes to read a plan vs. a lengthy review of code built on a flawed approach. The system works async: the agent processes your backlog overnight, and you review in the morning. The comparison isn't "agent PR vs. I write it myself" — it's "agent PR ready for review at 9am vs. issue still sitting in the backlog."

### What about costs?

Costs depend on the authentication method you configured on the runner. API-key authentication is billed per token against the owning Anthropic Console account; subscription-based authentication counts against the plan's quota. The project itself adds no billing layer — whatever Claude Code charges to the account tied to the runner's credentials is whatever a corresponding interactive Claude Code session would charge.

Cost controls built into the system regardless of authentication method: the circuit breaker limits the agent to 8 bot comments per hour per issue, preventing runaway loops; timeouts kill stuck processes; and you control which issues get the `agent` label — it's opt-in per issue, not automatic.

### Will this replace developers?

This is augmentation, not replacement. You define the problem (write the issue), validate the approach (review the plan), and verify the result (review the PR). The agent handles the mechanical implementation. Developers who learn to work effectively with agents will be more productive, not less valuable.
