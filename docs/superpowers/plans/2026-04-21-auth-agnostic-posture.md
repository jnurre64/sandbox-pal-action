# Auth-Agnostic Posture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the project's documentation so the project documents only the authentication prerequisite (Claude Code must be authenticated on the runner), deferring method choice and Terms-of-Service analysis to Anthropic's own docs. No env var names, no Path A / Path B, no decision matrix, no paraphrased ToS language.

**Architecture:** A trimmed `docs/authentication.md` becomes a ~25-line pointer page. Every downstream doc that currently prescribes a specific auth method (README, getting-started, runners, security, faq, setup skill, setup shell script) is rewritten to defer to `authentication.md` or to Anthropic's docs directly. `docs/claude-code-subscription-automation-guide.md` is deleted. The prior 2026-04-17 spec and plan get supersession notes. No code or test changes — verified on 2026-04-21 that no shell script, workflow, Python bot, or config file outside `scripts/setup.sh` references any auth env var.

**Tech Stack:** Markdown documentation; one shell script edit (ShellCheck must pass). No tests to add.

**Reference spec:** `docs/superpowers/specs/2026-04-21-auth-agnostic-posture-design.md`

---

## Prep: Confirm working state

**Files:**
- No edits

- [ ] **Step 1: Check git state**

Run: `git status && git log --oneline -5`

Expected: on a branch that already has the spec commit (`docs(spec): add auth-agnostic posture design spec`). If `git status` shows uncommitted changes unrelated to this plan, resolve them (commit, stash, or discard) before starting — the commit sequence in this plan assumes a clean working tree between tasks.

- [ ] **Step 2: Confirm spec is accessible**

Run: `test -f docs/superpowers/specs/2026-04-21-auth-agnostic-posture-design.md && echo OK`

Expected: `OK`. If missing, stop and ask the operator — the spec must be present for the implementation to make sense.

---

## Task 1: Rewrite `docs/authentication.md`

**Files:**
- Modify: `docs/authentication.md` (full rewrite, from 131 lines to ~25 lines of body)

This is the foundation. Every subsequent task links here, so rewrite it first and rewrite it completely.

- [ ] **Step 1: Read the current file**

Use the Read tool on `docs/authentication.md` to confirm its current shape (131-line Path A / Path B prescription).

- [ ] **Step 2: Replace the entire file**

Use the Write tool on `docs/authentication.md` with exactly this content:

```markdown
# Authentication

Claude Agent Dispatch runs `claude -p` (the headless mode of the native Claude Code CLI) on a self-hosted GitHub Actions runner. The dispatch scripts do not reference any credential environment variable — Claude Code's own authentication resolves whatever the operator has configured on the runner.

## Requirement

Claude Code must be authenticated on the runner before the first dispatch run. See Anthropic's [Claude Code authentication docs](https://code.claude.com/docs/en/authentication) for the supported methods and setup instructions.

After configuring authentication, verify with `claude /status` on the runner. If you configured a method that uses environment variables set in the runner's `.env` file, restart the runner service so workflow jobs pick up the variables.

## Terms of Service

Which of Anthropic's terms apply to your use of this project — and which authentication methods are appropriate — depend on how you are using the project, not on the project itself. Review the relevant Anthropic pages directly:

- [Claude Code Legal and Compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Anthropic Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms) (for subscription-backed accounts)
- [Anthropic Commercial Terms](https://www.anthropic.com/legal/commercial-terms) (for API-key and commercial accounts)
- [Anthropic Acceptable Use Policy](https://www.anthropic.com/legal/aup)

## Runner hygiene

Regardless of authentication method:

- If your chosen method uses environment variables in the runner's `.env` file, that file must be `chmod 600` — readable only by the runner user.
- Never commit credentials to any repository.
- Use `claude /status` on the runner to confirm the runner is authenticated with the account you intend.

## Disclaimer

This page describes an installation prerequisite. It is not legal advice. Review Anthropic's current Terms of Service, Usage Policies, and Claude Code documentation for the authoritative statement on authentication methods and their permitted uses.
```

- [ ] **Step 3: Verify the file no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token|Path A|Path B' docs/authentication.md`

Expected: `0`. If any hit appears, the rewrite left residual prescription — re-read the file and fix before committing.

- [ ] **Step 4: Commit**

```bash
git add docs/authentication.md
git commit -m "$(cat <<'EOF'
docs(authentication): rewrite as minimal prerequisite page

Removes Path A / Path B prescription, the decision matrix, the
Never-OK-patterns list, and the paraphrased ToS language. The page
now documents only that Claude Code must be authenticated on the
runner and points users to Anthropic's own authentication and
legal docs for method selection and Terms-of-Service analysis.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Update `README.md`

**Files:**
- Modify: `README.md` (L17 feature bullet; L64 prerequisites bullet)

- [ ] **Step 1: Read the current file to confirm line numbers**

Use the Read tool on `README.md` with offset 15 and limit 10 to see the feature bullet, then offset 60 and limit 10 to see the prerequisites block.

- [ ] **Step 2: Rewrite the feature bullet on ~L17**

Use the Edit tool:

**old_string:**
```
- **No third-party platform layers** — runs on the official Claude Code CLI and GitHub Actions, with no additional SaaS dependencies on top. Authentication uses either your Pro/Max subscription (individual use) or an Anthropic API key (required for team/commercial use) — see [authentication.md](docs/authentication.md).
```

**new_string:**
```
- **No third-party platform layers** — runs on the official Claude Code CLI and GitHub Actions, with no additional SaaS dependencies on top. Authenticate Claude Code on the runner however fits your use — the dispatch scripts do not prescribe a method; see [authentication.md](docs/authentication.md).
```

- [ ] **Step 3: Rewrite the prerequisites bullet on ~L64**

Use the Edit tool:

**old_string:**
```
  - Claude Code authentication configured — either `ANTHROPIC_API_KEY` (Console API key) or `CLAUDE_CODE_OAUTH_TOKEN` (OAuth token from `claude setup-token`); see [authentication.md](docs/authentication.md) for which applies to your use
```

**new_string:**
```
  - Claude Code CLI authenticated on the runner — see [authentication.md](docs/authentication.md)
```

- [ ] **Step 4: Verify README no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' README.md`

Expected: `0`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): defer auth method to authentication.md

Removes explicit naming of env vars and credential types from the
feature bullet and prerequisites. The README now states only that
Claude Code must be authenticated on the runner and points to
authentication.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rewrite `docs/getting-started.md` Step 4

**Files:**
- Modify: `docs/getting-started.md` (Step 4 body, approximately L85-115)

- [ ] **Step 1: Read the current Step 4 block**

Use the Read tool on `docs/getting-started.md` with offset 80 and limit 40 to see the full Step 4 block.

- [ ] **Step 2: Replace the auth-configuration block**

Use the Edit tool. This replaces the "Configure Claude Code authentication..." block (everything from that sentence through the closing triple-backtick of the `claude --version` code block) and leaves the `## Step 4: Install Claude Code on the Runner` heading and the preceding npm install block untouched.

**old_string:**

````markdown
Configure Claude Code authentication on the runner. Choose one of two paths — see [authentication.md](authentication.md) for the decision matrix and Terms of Service boundaries. In brief: use `ANTHROPIC_API_KEY` for team, shared-runner, or commercial deployments; use `CLAUDE_CODE_OAUTH_TOKEN` only for individual solo-developer use on your own repo.

Add exactly one of these to the runner's `.env` file (in the runner installation directory — not `~/.bashrc`; systemd services do not source shell profiles):

```bash
# Option A: Console API key
echo 'ANTHROPIC_API_KEY=sk-ant-api...' >> .env

# Option B: Subscription OAuth token
# Generate on a machine where you've logged in: `claude setup-token`
echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...' >> .env

chmod 600 .env
```

> **Warning.** Never set both. `ANTHROPIC_API_KEY` silently overrides `CLAUDE_CODE_OAUTH_TOKEN` in Claude Code's resolution order. Verify the active path with `claude /status` after restarting the runner service.

If you run the runner as a systemd service (the usual case), restart it so the new `.env` values are picked up:

```bash
sudo systemctl restart actions.runner.<org>-<repo>.<runner-name>.service
```

Verify the CLI works:
```bash
claude --version
```
````

**new_string:**

````markdown
Authenticate the Claude Code CLI on the runner. The dispatch scripts do not prescribe a method — see Anthropic's [Claude Code authentication docs](https://code.claude.com/docs/en/authentication) for the supported options, or [authentication.md](authentication.md) for the project's summary and the Terms-of-Service pointers.

After authenticating, verify with `claude /status` on the runner. If your method uses environment variables set in the runner's `.env` file, restart the runner service so workflow jobs pick them up:

```bash
sudo systemctl restart actions.runner.<org>-<repo>.<runner-name>.service
```

Verify the CLI is installed:

```bash
claude --version
```
````

> **Note to the implementer:** The outer four-backtick fences in this plan are only to render nested three-backtick code blocks. When calling the Edit tool, pass the inner content (starting from the first real line of old/new_string and preserving the inner triple-backticks exactly) — do not include the outer four-backtick lines as part of the string.

- [ ] **Step 3: Verify getting-started.md no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' docs/getting-started.md`

Expected: `0`.

- [ ] **Step 4: Commit**

```bash
git add docs/getting-started.md
git commit -m "$(cat <<'EOF'
docs(getting-started): defer auth method to authentication.md

Replaces the two-option env-var block in Step 4 with a short
prerequisite-oriented block. The step now points users to
Anthropic's Claude Code authentication docs and keeps the runner
service restart guidance as conditional on the chosen method.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update `docs/runners.md` Claude Code authentication subsection

**Files:**
- Modify: `docs/runners.md` (subsection starting at `### Claude Code authentication`, approximately L118-148)

- [ ] **Step 1: Read the current subsection**

Use the Read tool on `docs/runners.md` with offset 115 and limit 40 to see the full subsection.

- [ ] **Step 2: Replace the subsection body**

Use the Edit tool. This replaces everything from the `### Claude Code authentication` heading through the last "Security notes" bullet. The preceding `## Credentials and API Keys` heading and the following `### GitHub bot PAT` heading stay untouched.

**old_string:**

````markdown
### Claude Code authentication

The Claude Code CLI needs one of two environment variables set: `ANTHROPIC_API_KEY` (Console API key) or `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAuth token). The dispatch scripts do not specify which — Claude Code's own authentication precedence picks up whichever is set.

See [authentication.md](authentication.md) for the decision matrix and Terms of Service boundaries. In brief: API key is required for team, shared-runner, or commercial use; OAuth token is acceptable only for individual solo-developer use on your own repo.

Add exactly one of these to the runner's `.env` file (in the runner installation directory):

```bash
# Option A: Console API key — required for team/commercial/shared-runner use
echo 'ANTHROPIC_API_KEY=sk-ant-api...' >> .env

# Option B: Subscription OAuth token — individual solo-developer use only
# Generate on a machine where you've logged in: `claude setup-token`
echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...' >> .env

chmod 600 .env
```

> **Warning — silent override footgun.** Never set both variables simultaneously. `ANTHROPIC_API_KEY` takes precedence over `CLAUDE_CODE_OAUTH_TOKEN` in Claude Code's resolution order, so if both are present, the API key is used silently and charges route to the Console account. After configuring the runner, verify the active path with `claude /status`.

The runner reads `.env` on startup and injects these variables into every workflow job. **Do not** add credentials to `~/.bashrc` — systemd services do not source shell profiles.

**Security notes:**
- The `.env` file must be `chmod 600` (readable only by the runner user)
- Every workflow job on this runner can access whichever credential is set
- If you want per-workflow injection instead, store the credential as a [GitHub Actions secret](https://docs.github.com/en/actions/security-for-github-actions/security-guides/using-secrets-in-github-actions) and reference it in the `env:` block of your workflow files
- Rotate Console API keys every 90 days, or immediately if you suspect exposure; revoke the old key only after verifying the new one works
- Regenerate OAuth tokens before the ~1-year expiry, and remember they require an active subscription
````

**new_string:**

````markdown
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
````

- [ ] **Step 3: Verify runners.md no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' docs/runners.md`

Expected: `0`.

- [ ] **Step 4: Commit**

```bash
git add docs/runners.md
git commit -m "$(cat <<'EOF'
docs(runners): defer auth method to authentication.md

Replaces the side-by-side env-var subsection with a short section
that points to authentication.md and Anthropic's docs, while
keeping the method-agnostic runner-hygiene guidance (.env perms,
GitHub Actions secrets alternative).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Shrink `docs/security.md` authentication section and checklist

**Files:**
- Modify: `docs/security.md` (Anthropic Authentication Model section at ~L122-139; Security Checklist auth lines at ~L154-156)

- [ ] **Step 1: Read the current state of both sections**

Use the Read tool on `docs/security.md` with offset 120 and limit 45.

- [ ] **Step 2: Replace the "Anthropic Authentication Model" section**

Use the Edit tool. This replaces everything from the `## Anthropic Authentication Model` heading through the closing italic disclaimer line, and stops before the `## Security Checklist` heading.

**old_string:**

````markdown
## Anthropic Authentication Model

Claude Code supports two authentication paths for the runner: `ANTHROPIC_API_KEY` (Console API key) and `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAuth token from `claude setup-token`). See [authentication.md](authentication.md) for the full decision matrix, Terms of Service boundaries, and path-specific configuration.

The dispatch scripts are agnostic to which path is configured — the `claude -p` invocation in `scripts/lib/common.sh` does not specify an env var, and Claude Code's own authentication precedence handles the rest.

**Summary of path selection:**

- Team deployments, shared-access runners, commercial/customer-facing use, and any Agent SDK integration: `ANTHROPIC_API_KEY` is required.
- Individual solo-developer use on your own repo and runner: either path works. Subscription OAuth comes with additional guardrails documented in [authentication.md](authentication.md).

**Operator responsibilities:**

- Confirm exactly one of `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is set on the runner. Never both — `ANTHROPIC_API_KEY` silently overrides `CLAUDE_CODE_OAUTH_TOKEN` and routes billing to the Console account.
- Verify the active authentication method with `claude /status` on the runner.
- Confirm the Anthropic account or workspace that owns the credential is appropriate for your intended use (personal vs. organization; Consumer vs. Commercial Terms).

*This section describes how the system is designed to align with Anthropic's documented authentication paths. It is not legal advice — review Anthropic's current Terms of Service, Usage Policies, and Claude Code documentation to confirm fit for your specific use.*
````

**new_string:**

````markdown
## Anthropic Authentication Model

Claude Code must be authenticated on the runner for the dispatch scripts to function. The scripts themselves are agnostic to the authentication method — the `claude -p` invocation in `scripts/lib/common.sh` does not reference any credential environment variable, and Claude Code's own authentication precedence handles the rest.

See [authentication.md](authentication.md) for the project's authentication notes and links to Anthropic's authoritative documentation (authentication methods, legal and compliance, Terms of Service, Acceptable Use Policy).

*This section describes an installation prerequisite. It is not legal advice — review Anthropic's current terms to confirm fit for your specific use.*
````

- [ ] **Step 3: Collapse the three checklist lines into one**

Use the Edit tool with these exact strings:

**old_string:**
```
- [ ] No secrets appear in workflow logs (check recent runs)
- [ ] Authentication configured on the runner matches the intended use path per [authentication.md](authentication.md) — API key for team/commercial/shared-runner use; OAuth token only for individual solo-developer use
- [ ] Exactly one of `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` is set on the runner (never both — `ANTHROPIC_API_KEY` silently overrides `CLAUDE_CODE_OAUTH_TOKEN` and routes billing to the Console account)
- [ ] `claude /status` on the runner confirms the active auth method matches expectations
```

**new_string:**
```
- [ ] No secrets appear in workflow logs (check recent runs)
- [ ] Claude Code is authenticated on the runner (`claude /status` confirms the expected account) and the authenticated account is appropriate for your intended use — see [authentication.md](authentication.md)
```

- [ ] **Step 4: Verify security.md no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' docs/security.md`

Expected: `0`.

- [ ] **Step 5: Commit**

```bash
git add docs/security.md
git commit -m "$(cat <<'EOF'
docs(security): shrink auth section, collapse checklist to one line

The Anthropic Authentication Model section now points to
authentication.md and drops the path-selection summary. The
three auth-specific checklist lines collapse to a single
verification line.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Rewrite `docs/faq.md` auth-related answers

**Files:**
- Modify: `docs/faq.md` (three answers: ToS Q at ~L29-31, Pro/Max Q at ~L33-37, costs Q at ~L49-53)

- [ ] **Step 1: Read the current file**

Use the Read tool on `docs/faq.md` with limit 65 to see all three Qs.

- [ ] **Step 2: Rewrite the "Is this setup aligned with Anthropic's Terms of Service?" answer**

Use the Edit tool:

**old_string:**
```
The system supports two Anthropic-documented authentication paths and is agnostic to which you configure. For team deployments, shared-access runners, commercial use, or any Agent SDK integration, `ANTHROPIC_API_KEY` (a Console API key) is required. For an individual solo developer using this on their own repo with their own self-hosted runner, `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`, backed by a Pro/Max/Team/Enterprise subscription) is also supported per Anthropic's Claude Code authentication documentation. See [authentication.md](authentication.md) for the full decision matrix, ToS boundaries, and configuration steps. Review Anthropic's current Terms of Service, Usage Policies, and Claude Code documentation for the authoritative statement.
```

**new_string:**
```
Whether the project's use aligns with Anthropic's Terms of Service depends on how you are using the project — your authentication choice, whether the runner serves one person or many, whether use is individual or commercial, and whether usage stays within Anthropic's "ordinary individual usage" boundaries for subscription plans. The project does not take a position on any of these: the dispatch scripts simply invoke the `claude` CLI and rely on Anthropic's authentication precedence.

Review Anthropic's authoritative pages for the applicable rules: [Claude Code Legal and Compliance](https://code.claude.com/docs/en/legal-and-compliance), [Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms), [Commercial Terms](https://www.anthropic.com/legal/commercial-terms), and the [Acceptable Use Policy](https://www.anthropic.com/legal/aup). See [authentication.md](authentication.md) for the project's notes on the installation prerequisite.
```

- [ ] **Step 3: Rewrite the "Can I use my Pro/Max subscription instead of an API key?" answer**

Use the Edit tool:

**old_string:**
```
Yes — for individual solo-developer use on your own repo and your own self-hosted runner. Generate a token with `claude setup-token` and set it as `CLAUDE_CODE_OAUTH_TOKEN` on the runner. Do not set `ANTHROPIC_API_KEY` in the same environment — it silently overrides the OAuth token and routes billing to your Console account.

The OAuth path is **not** appropriate for team deployments, shared-access runners, 24/7 operation, or any scenario where multiple humans trigger workflows through a single token (this would violate Consumer Terms' account-sharing prohibition). See [authentication.md](authentication.md) for the full guardrails.
```

**new_string:**
```
Claude Code supports multiple authentication methods, including subscription-backed ones. Whether any specific method is appropriate for *your* use of this project is covered by Anthropic's terms, not by the project. See [authentication.md](authentication.md) and Anthropic's [Claude Code authentication docs](https://code.claude.com/docs/en/authentication).
```

- [ ] **Step 4: Rewrite the "What about costs?" answer**

Use the Edit tool:

**old_string:**
```
Billing depends on the authentication path you configured (see [authentication.md](authentication.md)). With `ANTHROPIC_API_KEY`, usage is billed per token against the Anthropic Console account that owns the key. With `CLAUDE_CODE_OAUTH_TOKEN`, usage counts against your Pro/Max/Team/Enterprise subscription's "ordinary individual usage" quota — no separate per-token charges, but sustained heavy automation may push you toward the subscription's limits or into API-key territory.

Cost controls built into the system regardless of auth path: the circuit breaker limits the agent to 8 bot comments per hour per issue, preventing runaway loops; timeouts kill stuck processes; and you control which issues get the `agent` label — it's opt-in per issue, not automatic.
```

**new_string:**
```
Costs depend on the authentication method you configured on the runner. API-key authentication is billed per token against the owning Anthropic Console account; subscription-based authentication counts against the plan's quota. The project itself adds no billing layer — whatever Claude Code charges to the account tied to the runner's credentials is whatever a corresponding interactive Claude Code session would charge.

Cost controls built into the system regardless of authentication method: the circuit breaker limits the agent to 8 bot comments per hour per issue, preventing runaway loops; timeouts kill stuck processes; and you control which issues get the `agent` label — it's opt-in per issue, not automatic.
```

- [ ] **Step 5: Verify faq.md no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' docs/faq.md`

Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add docs/faq.md
git commit -m "$(cat <<'EOF'
docs(faq): defer auth ToS and cost questions to Anthropic's docs

The ToS, Pro/Max, and costs answers no longer name env vars or
prescribe a path. They point users to Anthropic's authoritative
pages and to the project's authentication.md for the prerequisite
summary.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Rewrite `.claude/skills/setup/SKILL.md` Step 9d

**Files:**
- Modify: `.claude/skills/setup/SKILL.md` (Step 9d body, approximately L229-272)

- [ ] **Step 1: Read the current Step 9d block**

Use the Read tool on `.claude/skills/setup/SKILL.md` with offset 225 and limit 60 to see the whole step including the surrounding Node/Claude path note.

- [ ] **Step 2: Replace the Step 9d body**

Use the Edit tool. This replaces everything from the `### Step 9d: Configure credentials` heading through the "Verification (both branches)" paragraph, and stops exactly before the `**Node/Claude path** — If using nvm` paragraph (which is preserved unchanged).

**old_string:**

````markdown
### Step 9d: Configure credentials

Claude Code authentication uses one of two environment variables, set in the runner's `.env` file (not `~/.bashrc` — systemd services do not source shell profiles). Before proceeding, ask the user which auth path applies to their situation:

1. **Team, shared-runner, commercial, or Agent SDK use** → `ANTHROPIC_API_KEY` (Console API key, required)
2. **Individual solo-developer use on your own repo** → either `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`
3. **Not sure / want to read first** → point the user to [docs/authentication.md](../../../docs/authentication.md)

Get their choice, then apply one of the two branches below. **Never configure both** — `ANTHROPIC_API_KEY` silently overrides `CLAUDE_CODE_OAUTH_TOKEN` in Claude Code's precedence order.

**Branch A: Console API key**

```bash
echo 'ANTHROPIC_API_KEY=sk-ant-api...' >> .env
chmod 600 .env
```

Tell the user to paste their actual key. Remind them:
- The `.env` file must be `chmod 600` (only the runner user can read it)
- Every workflow job on this runner can access the key
- Rotate the key every 90 days

**Branch B: Subscription OAuth token**

Before reaching this step, the user needs to generate a token on a machine where they've logged into Claude Code. Tell them to run (on that machine, not necessarily the runner):

```bash
claude setup-token
```

This prints a token beginning `sk-ant-oat01-...`. Have them copy it, then on the runner:

```bash
echo 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...' >> .env
chmod 600 .env
```

Remind them:
- The `.env` file must be `chmod 600` (only the runner user can read it)
- The token is backed by their Pro/Max/Team/Enterprise subscription and expires after ~1 year
- Regenerate before expiry; if their subscription lapses, dispatch runs will fail with auth errors
- This path is for **individual solo-developer use only** — see [authentication.md](../../../docs/authentication.md) for the full ToS guardrails

**Verification (both branches):** After the runner service is restarted in Step 9f, have the user run `claude /status` on the runner (as the runner user, with `.env` sourced). It should report the auth method they configured.
````

**new_string:**

````markdown
### Step 9d: Configure credentials

The Claude Code CLI needs to be authenticated on the runner. The dispatch scripts do not prescribe a method — point the user to Anthropic's [Claude Code authentication docs](https://code.claude.com/docs/en/authentication) for the available options, or [authentication.md](../../../docs/authentication.md) for the project's summary and Terms-of-Service pointers.

If the user chose a method that uses environment variables, the runner's `.env` file (in the runner installation directory, not `~/.bashrc` — systemd services do not source shell profiles) is the right place to set them. Any `.env` holding credentials must be `chmod 600`.

**Verification:** After the runner service is restarted in Step 9f, have the user run `claude /status` on the runner (as the runner user). It should report that the runner is authenticated with the expected account.
````

> **Note to the implementer:** This Edit does **not** touch the `**Node/Claude path** — If using nvm…` paragraph that follows. That block stays as-is. Do not include it in either the old_string or the new_string.

- [ ] **Step 3: Verify SKILL.md no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' .claude/skills/setup/SKILL.md`

Expected: `0`.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/setup/SKILL.md
git commit -m "$(cat <<'EOF'
docs(setup-skill): drop auth-path branching in Step 9d

Step 9d no longer asks the user to choose between API key and
OAuth token branches. It points to Anthropic's Claude Code
authentication docs and the project's authentication.md, then
proceeds to claude /status verification after the existing
Step 9f runner service restart.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Update `scripts/setup.sh` and gate on ShellCheck

**Files:**
- Modify: `scripts/setup.sh` (post-setup instruction block, approximately L337-345)

- [ ] **Step 1: Read the current block**

Use the Read tool on `scripts/setup.sh` with offset 335 and limit 15.

- [ ] **Step 2: Replace the prescriptive instructions with a pointer**

Use the Edit tool:

**old_string:**
```
echo "  4. Add ANTHROPIC_API_KEY to the runner's .env file (systemd does not"
echo "     source ~/.bashrc — the .env file is required):"
echo ""
echo -e "     ${CYAN}echo 'ANTHROPIC_API_KEY=sk-ant-...' >> .env${NC}"
echo -e "     ${CYAN}chmod 600 .env${NC}"
echo ""
echo "     For individual solo-developer use, CLAUDE_CODE_OAUTH_TOKEN is also"
echo "     supported instead of ANTHROPIC_API_KEY — see docs/authentication.md"
echo "     for guidance, Terms of Service boundaries, and setup steps."
echo ""
```

**new_string:**
```
echo "  4. Authenticate the Claude Code CLI on the runner (as the runner user)."
echo "     The dispatch scripts do not prescribe a method — see Anthropic's"
echo "     Claude Code authentication docs and the project's authentication.md"
echo "     for setup options and Terms-of-Service pointers:"
echo ""
echo -e "     ${CYAN}https://code.claude.com/docs/en/authentication${NC}"
echo -e "     ${CYAN}docs/authentication.md${NC}"
echo ""
echo "     After configuring, verify with: claude /status"
echo ""
```

- [ ] **Step 3: Verify setup.sh no longer contains forbidden auth strings**

Run: `grep -c -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|setup-token' scripts/setup.sh`

Expected: `0`.

- [ ] **Step 4: Run ShellCheck on the modified file**

Run: `shellcheck scripts/setup.sh`

Expected: no warnings or errors introduced by this change. If ShellCheck reports a pre-existing warning that is not on the edited lines, do not fix it as part of this task — note it for the operator but do not expand scope.

- [ ] **Step 5: Run full project ShellCheck per CLAUDE.md convention**

Run: `shellcheck scripts/*.sh scripts/lib/*.sh`

Expected: zero warnings across all project shell scripts (CLAUDE.md requires this). If pre-existing warnings appear on files this task did not touch, stop and ask the operator before proceeding — the project invariant is broken in a way this task did not cause.

- [ ] **Step 6: Commit**

```bash
git add scripts/setup.sh
git commit -m "$(cat <<'EOF'
docs(setup-sh): replace auth prescription with docs pointer

The post-setup instructions no longer name ANTHROPIC_API_KEY or
CLAUDE_CODE_OAUTH_TOKEN. They now point users at Anthropic's
Claude Code authentication page and the project's authentication.md
for method selection, and tell them to verify with claude /status.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Delete `docs/claude-code-subscription-automation-guide.md`

**Files:**
- Delete: `docs/claude-code-subscription-automation-guide.md`

- [ ] **Step 1: Confirm the file exists and has no inbound links**

Run: `test -f docs/claude-code-subscription-automation-guide.md && echo EXISTS`

Expected: `EXISTS`.

Then: `grep -rn 'claude-code-subscription-automation-guide' . --include='*.md' --include='*.yml' --include='*.sh' 2>/dev/null | grep -v 'docs/superpowers/' | grep -v 'docs/issues/' | grep -v '\.git/' | grep -v 'claude-code-subscription-automation-guide.md:'`

Expected: no output (no project doc outside the superseded spec/plan area currently links to this file). If any inbound link appears, stop and ask the operator — the deletion would create a broken link.

- [ ] **Step 2: Delete the file**

Run: `git rm docs/claude-code-subscription-automation-guide.md`

- [ ] **Step 3: Verify deletion**

Run: `test ! -f docs/claude-code-subscription-automation-guide.md && echo GONE`

Expected: `GONE`.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
docs: delete claude-code-subscription-automation-guide

The subscription+automation guide was a 121-line opinion piece
ranking Docker sandbox options and paraphrasing Anthropic policy.
Under the auth-agnostic posture it has no home in the project —
its content belongs in Anthropic's own docs and community
resources, which stay current as policy evolves.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Add supersession notes to the 2026-04-17 spec and plan

**Files:**
- Modify: `docs/superpowers/specs/2026-04-17-authentication-docs-design.md`
- Modify: `docs/superpowers/plans/2026-04-17-authentication-docs-realignment.md`

- [ ] **Step 1: Add supersession note to the 2026-04-17 spec**

Use the Edit tool:

**old_string:**
```
# Authentication Documentation Realignment

**Status:** Draft
```

**new_string:**
```
# Authentication Documentation Realignment

> **Status — 2026-04-21:** Superseded by [`2026-04-21-auth-agnostic-posture-design.md`](2026-04-21-auth-agnostic-posture-design.md), which moves the project from informational-neutral path-documentation to full auth-agnosticism. This spec is preserved as a historical record.

**Status:** Draft
```

- [ ] **Step 2: Add supersession note to the 2026-04-17 plan**

Use the Edit tool:

**old_string:**
```
# Authentication Documentation Realignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
```

**new_string:**
```
# Authentication Documentation Realignment Implementation Plan

> **Status — 2026-04-21:** This plan was executed and its work has since been superseded by the [auth-agnostic posture spec](../specs/2026-04-21-auth-agnostic-posture-design.md). Preserved as a historical record.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
```

- [ ] **Step 3: Commit both in one commit**

```bash
git add docs/superpowers/specs/2026-04-17-authentication-docs-design.md docs/superpowers/plans/2026-04-17-authentication-docs-realignment.md
git commit -m "$(cat <<'EOF'
docs(superpowers): mark 2026-04-17 auth spec and plan as superseded

Adds supersession banners pointing to the 2026-04-21 auth-agnostic
posture spec. Historical bodies preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Final verification

**Files:**
- No file edits

- [ ] **Step 1: Final forbidden-string sweep across the whole repo**

Run this exact command from the repo root:

```bash
grep -rn -E 'ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|sk-ant-api|sk-ant-oat|claude setup-token' . \
  --include='*.md' --include='*.sh' --include='*.yml' --include='*.yaml' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.json' \
  --include='*.bats' --include='*.env*' 2>/dev/null \
  | grep -v '/tests/bats/' \
  | grep -v '/docs/superpowers/' \
  | grep -v '/docs/issues/' \
  | grep -v '\.git/'
```

Expected: no output. `docs/superpowers/` is excluded because the 2026-04-17 spec and plan (historical records) retain their original language; `docs/issues/` is excluded for the same reason. If any line outside those paths contains a forbidden string, go back to the task that owns that file and fix it.

- [ ] **Step 2: Verify all internal links still resolve**

For each file modified or created by this plan, open it and trace every relative `[text](path)` link to the file it points to. A quick smoke test:

```bash
for f in README.md docs/authentication.md docs/getting-started.md docs/runners.md docs/security.md docs/faq.md .claude/skills/setup/SKILL.md; do
  echo "=== $f ==="
  grep -oE '\[[^]]+\]\([^)]+\)' "$f" | grep -v 'http' | sort -u
done
```

Review the output manually. Each local link (e.g., `authentication.md`, `docs/authentication.md`, `../../../docs/authentication.md`) must point to a file that exists in the repo. The ones that matter most:

- `docs/authentication.md` resolves from `README.md` (written as `docs/authentication.md`)
- `authentication.md` resolves from each doc inside `docs/` (no path prefix — they're siblings)
- `../../../docs/authentication.md` resolves from `.claude/skills/setup/SKILL.md`

- [ ] **Step 3: End-to-end read-through**

Read the following files in this order and confirm consistent messaging:

1. `README.md` — feature bullet and prerequisite both defer to `authentication.md` without naming env vars
2. `docs/authentication.md` — ~25-line prerequisite page with no env var names, no Path A/B, no decision matrix
3. `docs/getting-started.md` — Step 4 points users to Anthropic's docs and authentication.md; no env var names
4. `docs/runners.md` — "Claude Code authentication" subsection is short and method-agnostic
5. `docs/security.md` — Anthropic Authentication Model section is short and points to authentication.md; checklist has one auth line
6. `docs/faq.md` — ToS, Pro/Max, and costs answers all defer to Anthropic and authentication.md
7. `.claude/skills/setup/SKILL.md` — Step 9d points to authentication.md without branching

Expected: consistent language across all files ("Claude Code must be authenticated on the runner"; "the dispatch scripts do not prescribe a method"). No surviving occurrences of "Path A" / "Path B", decision-matrix framing, silent-override warnings, or env var names as prescription.

- [ ] **Step 4: Confirm ShellCheck still passes project-wide**

Run: `shellcheck scripts/*.sh scripts/lib/*.sh`

Expected: zero warnings (CLAUDE.md requires this).

- [ ] **Step 5: Confirm BATS tests still pass**

Run: `./tests/bats/bin/bats tests/`

Expected: all tests pass. No tests were added or modified in this plan, so any failure indicates an unrelated regression — flag it to the operator.

- [ ] **Step 6: Review the commit sequence**

Run: `git log --oneline main..HEAD`

Expected: a clean sequence of focused commits. The exact order depends on task execution sequence, but each task in this plan should map to one commit (Task 10 combines two file edits into one commit for clean history):

```
<hash> docs(superpowers): mark 2026-04-17 auth spec and plan as superseded
<hash> docs: delete claude-code-subscription-automation-guide
<hash> docs(setup-sh): replace auth prescription with docs pointer
<hash> docs(setup-skill): drop auth-path branching in Step 9d
<hash> docs(faq): defer auth ToS and cost questions to Anthropic's docs
<hash> docs(security): shrink auth section, collapse checklist to one line
<hash> docs(runners): defer auth method to authentication.md
<hash> docs(getting-started): defer auth method to authentication.md
<hash> docs(readme): defer auth method to authentication.md
<hash> docs(authentication): rewrite as minimal prerequisite page
<hash> docs(spec): add auth-agnostic posture design spec
```

The `docs(spec):` commit is from the brainstorming phase and is already present on the branch. All other commits are produced by this plan.

---

## Out of scope (noted for later)

- **Ephemeral-runner guidance.** Users with reprovisioned runners may want a short doc on how to re-authenticate Claude Code after a rebuild. Out of scope here; Anthropic's docs already cover it.
- **Token-expiry monitoring.** Detecting when a user's auth is about to expire in agent logs could be future work, but is not part of this plan.
- **Worktree-based implementation.** If the operator wants to run this plan in an isolated worktree, they should create one from the current branch (which already contains the spec commit) before starting. This plan does not assume worktree isolation.
- **PR branching strategy.** The current branch (`chore/disclaimer-placement`) already contains an unrelated `docs: move affiliation disclaimer to top of README` commit. If the operator wants these changes in their own PR separate from the disclaimer move, they should extract via cherry-pick or rebase before opening the PR. This plan does not prescribe branch restructuring.
