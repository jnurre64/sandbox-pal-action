# Architecture

## Overview

Claude Agent Dispatch is a label-driven system for running Claude Code agents on GitHub issues via GitHub Actions. When a human adds the `agent` label to an issue, the system triages the issue, writes a plan, waits for human approval, implements the plan, creates a PR, and addresses review feedback -- all automatically.

The system runs on self-hosted GitHub Actions runners where Claude Code CLI is installed. A dispatch shell script (`sandbox-pal-dispatch.sh`) handles event routing, label management, worktree isolation, data pre-fetching, and safety mechanisms. Claude Code runs in headless mode (`claude -p`) with tool restrictions tailored to each phase.

### Accounts

| Account | Role |
|---------|------|
| Human account(s) | Label issues, review plans, review PRs, merge |
| `your-bot` | Bot account that implements code, comments, pushes branches, creates PRs |

The bot authenticates via a fine-grained PAT stored as a GitHub Actions secret (`AGENT_PAT`).

## Label State Machine

Labels track the agent's progress on each issue. Only one `agent:*` label should be active at a time. The dispatch script enforces this by removing all agent labels before setting the new one.

```
Human adds "agent" label
  |
  v
agent:triage  ................ agent is analyzing the issue
  |
  +--> agent:needs-info ...... agent asked questions, waiting for human
  |      |
  |      +--> (human replies) --> agent:ready --> agent:triage (re-plan)
  |
  +--> agent:plan-review ..... agent posted plan, waiting for human approval
         |
         +--> agent:needs-info  (human has feedback on plan)
         |
         +--> (human adds agent:plan-approved)
                |
                v
              agent:in-progress  agent is implementing the approved plan
                |
                v
              agent:pr-open .... PR created, awaiting review
                |
                +--> (CHANGES_REQUESTED) --> agent:revision --> agent:pr-open
                |
                +--> (APPROVED) --> merged
                        |
                        v
              agent:done ....... PR merged — terminal state

At any point on failure: --> agent:failed
```

PR creation itself is gated by a capped adversarial review loop (review -> fix
-> re-review) rather than a single pass -- see "Post-Implementation Review
Loop" below. A PR that opens with findings still outstanding when the retry
cap is hit carries `agent:review-unresolved` in addition to `agent:pr-open`.

### Direct Implement Path

If an issue already contains a complete implementation plan, a human can add the `agent:implement` label to skip triage entirely. The agent validates the plan against the codebase, then proceeds directly to implementation in a single session (no human checkpoint between validation and implementation).

```
Human adds "agent:implement" label
  |
  v
agent:validating ............. agent is verifying the plan against the codebase
  |
  +--> agent:needs-info ...... plan has issues, waiting for human to fix
  |      |
  |      +--> (human replies) --> re-validates plan
  |
  +--> agent:in-progress ..... plan valid, implementing (same as standard flow)
         |
         v
       agent:pr-open ......... PR created, awaiting review (same as standard flow)
```

This path requires `AGENT_ALLOW_DIRECT_IMPLEMENT=true` (the default). Set to `false` to disable the `agent:implement` label entirely.

All agent labels:

| Label | Meaning |
|-------|---------|
| `agent` | Human trigger: start working on this issue |
| `agent:triage` | Agent is analyzing the issue |
| `agent:needs-info` | Agent asked questions, waiting for human reply |
| `agent:ready` | Questions answered, ready to plan/implement |
| `agent:plan-review` | Plan posted, awaiting human approval |
| `agent:plan-approved` | Human approved the plan (triggers implementation) |
| `agent:in-progress` | Agent is implementing code |
| `agent:pr-open` | PR created, awaiting review |
| `agent:review-unresolved` | Annotation label (applied alongside `agent:pr-open`): the review loop hit its retry cap with findings still outstanding |
| `agent:done` | Terminal: the agent's PR merged; linked issue closed and cleaned |
| `agent:revision` | Agent is addressing review feedback |
| `agent:implement` | Human trigger: skip triage, validate and implement a pre-written plan |
| `agent:validating` | Agent is validating a pre-written plan against the codebase |
| `agent:failed` | Something went wrong; check logs |

## Event Triggers

The system uses six reusable GitHub Actions workflows (`sandbox-pal-*.yml`) that your repository calls via `workflow_call`. Each responds to a different GitHub event.

| Event | Trigger | Reusable Workflow | Filter (in your caller workflow) |
|-------|---------|-------------------|----------------------------------|
| `issues.labeled` | `agent` label added | `sandbox-pal-triage.yml` | Label is `agent`, actor != `your-bot` |
| `issues.labeled` | `agent:plan-approved` label added | `sandbox-pal-implement.yml` | Label is `agent:plan-approved`, actor != `your-bot` |
| `issue_comment.created` | Human replies on issue | `sandbox-pal-reply.yml` | Issue has `agent:needs-info` label, commenter != `your-bot` |
| `issues.labeled` | `agent:implement` label added | `sandbox-pal-direct-implement.yml` | Label is `agent:implement`, actor != `your-bot` |
| `pull_request_review.submitted` | Review with changes requested | `sandbox-pal-review.yml` | State is `changes_requested`, reviewer != `your-bot` |
| `pull_request.closed` | merged agent PR | `sandbox-pal-post-merge.yml` | PR merged, PR author == `your-bot` |
| `repository_dispatch` | `agent-triage` / `agent-implement` / `agent-reply` event type | `sandbox-pal-triage.yml` / `sandbox-pal-implement.yml` / `sandbox-pal-reply.yml` | Event type match only -- no actor filter (see below) |

The actor/commenter/reviewer filters are critical -- without them, the bot's own actions would re-trigger workflows in an infinite loop.

### Programmatic Triggering (`repository_dispatch`)

The label filters above mean a trigger label applied *by the bot account itself* is ignored by design. Any automation that authenticates as the bot -- an orchestrator session, a chat bot, a script using the bot PAT -- must therefore not use labels to start work; its label events are filtered (repos set up with current templates leave a breadcrumb comment on the issue explaining the skip; older setups skip silently). The supported programmatic on-ramp is `repository_dispatch`.

The dispatch caller workflow ("Agent Dispatch (programmatic)", installed by `/setup` as `caller-dispatch.yml` in reference mode or `sandbox-pal-dispatch.yml` in standalone mode) listens for three event types:

| Event type | Phase | Human-path equivalent |
|------------|-------|-----------------------|
| `agent-triage` | Triage a new issue | Adding the `agent` label |
| `agent-implement` | Implement an approved plan | Adding the `agent:plan-approved` label |
| `agent-reply` | Process a reply on a waiting issue | Commenting on an `agent:needs-info` / `agent:plan-review` issue |

The payload carries one field, `client_payload.issue_number`:

```bash
gh api repos/OWNER/REPO/dispatches \
  -f event_type=agent-implement \
  -F 'client_payload[issue_number]=42'
```

Notes:

- Do **not** also apply the trigger label when firing `repository_dispatch`. The dispatch script manages state labels itself; a bot-applied trigger label only produces a skipped run and the breadcrumb comment.
- The Discord bot is one caller of this entry point, not its owner -- anything holding the bot PAT can use it.
- Direct implement (`agent:implement`) and post-merge cleanup have no dispatch event types today; those flows are label/PR-event only. The reusable workflows accept `issue_number`/`pr_number` input overrides if a consuming repo wants to wire up additional event types (see [configuration.md](configuration.md)).

## Two-Phase Dispatch

The agent operates in two separate `claude -p` invocations with a human checkpoint between them:

### Phase 1: Plan (triage)

Triggered by the `agent` label. The agent:
1. Reads the issue title, body, and existing comments
2. Explores the codebase (read-only tools only)
3. Decides whether to ask clarifying questions or write a plan
4. If questions needed: posts a comment, sets `agent:needs-info`
5. If plan ready: writes the plan to `.agent-data/plan.md`, the script posts it as an issue comment with a `<!-- agent-plan -->` marker, sets `agent:plan-review`

The human reviews the plan and either provides feedback (sets `agent:needs-info`) or adds the `agent:plan-approved` label.

### Phase 2: Implement

Triggered by the `agent:plan-approved` label. The agent:
1. Reads the approved plan from the issue comments (finds the `<!-- agent-plan -->` marker, or an interactive `<!-- agent-branch: ... -->` marker naming a pre-pushed branch — see "Interactive Plan Branch Marker" below)
2. Implements the plan with read-write tools (edit, write, git add, git commit)
3. The dispatch script checks for new commits, optionally runs a pre-PR test gate, pushes the branch, and creates a PR with `Closes #N` linking
4. Sets `agent:pr-open`

This two-phase design ensures a human reviews the plan before any code is written. For urgent issues, the human can approve the plan immediately after it is posted.

#### Interactive Plan Branch Marker

The standard (autonomous) flow reuses the plan-phase worktree for implementation, so uncommitted state from that worktree carries forward. An interactive plan branch (`<!-- agent-branch: ... -->`) is different: `handle_implement` always creates a **fresh** worktree on the branch head for it (see `extract_plan_branch` handling in `scripts/sandbox-pal-dispatch.sh`), rather than reusing any prior worktree for that branch. This means uncommitted or unpushed work left behind by a failed prior interactive-branch run is **not** retained — a retry starts clean from whatever was last pushed to the branch.

## Post-Implementation Review Loop

Before a PR is created, `handle_post_implementation()` runs a capped, ledger-driven review loop instead of a single adversarial pass:

1. A fresh review session checks the diff against the issue/plan and reports findings.
2. Findings are merged into a ledger at `.agent-data/review-ledger.json` (committed to the work branch after every pass, so the history survives across retries). The ledger is stamped with the issue number it belongs to: because it rides the branch, a branch cut after a merge inherits the previous PR's ledger, so on init a ledger stamped with a different issue — or not stamped at all — is discarded as a stale leftover, not merged as history (#89).
3. If no blocking findings remain open, the loop exits clean and the PR opens as `agent:pr-open`.
4. Otherwise, if the retry count is under the cap (`AGENT_POST_IMPL_REVIEW_MAX_RETRIES`, default 3), a fix session addresses the open findings, dispositions them in the ledger, and the loop re-reviews.
5. If the cap is reached with findings still open, the loop stops and the PR opens anyway -- labeled `agent:review-unresolved` **in addition to** `agent:pr-open` -- with the outstanding findings summarized at the top of the PR body.

`AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0` means a single review pass with no fix loop: any open finding immediately produces an `agent:review-unresolved` PR. This replaces the earlier single-retry Gate B design.

## Dispatch Flow by Event Type

### Triage (new_issue)

```
issues.labeled "agent"
  --> set_label("agent:triage")
  --> check_circuit_breaker
  --> ensure_repo (clone if needed)
  --> setup_worktree (agent/issue-N branch)
  --> fetch issue title, body, comments via gh CLI
  --> pass issue content via environment variables
  --> run claude -p with triage prompt (read-only tools)
  --> parse response:
      ask_questions -> post comment, set agent:needs-info
      plan_ready    -> post plan comment, set agent:plan-review
      other         -> set agent:failed
```

### Reply (issue_reply)

```
issue_comment.created on agent:needs-info issue
  --> verify agent:needs-info label still present
  --> check_circuit_breaker
  --> ensure_repo, setup_worktree
  --> fetch full conversation (title, body, all comments)
  --> run claude -p with reply prompt (read-only tools)
  --> parse response:
      ask_questions -> post follow-up, keep agent:needs-info
      implement     -> set agent:ready, re-enter triage to generate plan
```

### Implement (implement)

```
issues.labeled "agent:plan-approved"
  --> set_label("agent:in-progress")
  --> check_circuit_breaker
  --> ensure_repo
  --> reuse existing worktree from plan phase (or create fresh)
  --> find plan comment (<!-- agent-plan --> marker)
  --> extract debug data (gists, attachments) from comments
  --> run claude -p with implement prompt (read-write tools)
  --> handle_post_implementation:
      if new commits:
        push branch (preserve work before any gate can fail)
        run pre-PR test gate (if configured)
          -> fail -> bounded fix sessions (AGENT_TEST_GATE_MAX_RETRIES)
          -> still failing -> agent:failed (branch stays pushed)
        create PR with Closes #N
        set agent:pr-open
      if no commits:
        set agent:failed, post comment
```

### Direct Implement (direct_implement)

```
issues.labeled "agent:implement"
  --> check AGENT_ALLOW_DIRECT_IMPLEMENT (fail if disabled)
  --> set_label("agent:validating")
  --> check_circuit_breaker
  --> ensure_repo, setup_worktree
  --> fetch issue title, body, comments via gh CLI
  --> extract debug data (gists, attachments) from comments and body
  --> run claude -p with validate prompt (read-only tools)
  --> parse response:
      valid         -> set AGENT_PLAN_CONTENT, call handle_implement (same session)
      issues_found  -> post comment with <!-- agent-direct-implement --> marker,
                       set agent:needs-info
      other         -> set agent:failed
```

### PR Review (pr_review)

```
pull_request_review.submitted (changes_requested)
  --> check_circuit_breaker, ensure_repo
  --> fetch PR details (title, body, reviews, inline comments, conversation)
  --> fetch original issue context
  --> set agent:revision on linked issue
  --> create worktree from PR branch
  --> extract debug data from PR comments
  --> run claude -p with review prompt (read-write tools)
  --> if new commits: push, set agent:pr-open
  --> if no commits: post comment explaining inability, keep agent:revision
```

### Post-Merge Cleanup (post_merge)

```
pull_request.closed
  --> verify PR is merged and authored by AGENT_BOT_USER (skip otherwise)
  --> resolve all linked issues (closingIssuesReferences, else branch name)
  --> replace each linked issue's agent:* state labels with agent:done
  --> check AGENT_CLEANUP_ENABLED (if disabled, stop here — only the
      doc-cleanup session below is skipped; labels are already done)
  --> check_circuit_breaker, ensure_repo
  --> delete the merged remote branch (best-effort)
  --> fresh worktree off latest main (chore/agent-cleanup-pr-<N> branch)
  --> run claude -p with cleanup prompt (read-write tools),
      given PR title/body, merged branch name, first linked issue, and the
      review ledger from the merged branch
  --> file follow-up issues from the session's structured output
  --> if doc commits were made: push directly to main,
      falling back to a chore PR if the direct push is rejected
```

This is distinct from the scheduled `cleanup` event below: `post_merge` runs once per merged agent PR and does tracking-doc/follow-up-issue work, while scheduled `cleanup` is a periodic housekeeping sweep across the whole repo.

### Cleanup (cleanup)

```
schedule (cron) or manual dispatch
  --> run cleanup.sh
  --> prune stale agent branches
  --> clean up old gists, workflow runs, log files
```

## Dispatch Liveness

A caller that starts a long dispatch has to answer "is it still going?" — and background-task monitors are not reliable: a run reported `killed` can be alive and go on to open a PR. Three independent signals answer it (`scripts/lib/liveness.sh`, #94):

1. **The lock** (`$AGENT_LOCK_DIR/<repo>-<number>.lock`) carries pid, host, event, start time, and **current phase**, heartbeat-updated as the pipeline advances — including once per review-loop pass, which is where a long dispatch actually spends its time. One dispatch per issue: a held lock is refused with the holder named; a same-host lock whose pid is dead is reclaimed by the next dispatch; a lock from another host is never reclaimed.
2. **The `status` event** (`sandbox-pal-dispatch.sh status <repo> <number>`) is read-only. It reports the lock as live (`stale: false`, with phase and timestamps) or dead (`stale: true`), plus the last-dispatch record. It deliberately mutates nothing: it does not clean up a dead lock, and it never writes the last-dispatch record of the run being asked about. Its final line of stdout is a compact JSON object; everything before it is for humans.
3. **The last-dispatch record** (`$AGENT_LOCK_DIR/<repo>-<number>-last-dispatch.json`) is written before the process exits on **every** outcome including failure — a failure is exactly when the caller is least likely to still hold the pipe. The outcome is the last agent label the dispatch set (e.g. `agent:pr-open`, `agent:failed`), plus the exit code and start/finish times.

**The rule for callers**: a `killed` or `failed` notification about a dispatch is **unverified until checked**. Run `status` first (usually the whole answer), then read the last-dispatch record, then check whether the work branch gained commits. Never describe the work as lost, or advise discarding a branch, on the strength of a notification alone.

## Key Components

### Dispatch Script (`scripts/sandbox-pal-dispatch.sh`)

The main entry point. Takes three arguments: `<event_type> <repo> <number>`. Sources configuration from `config.env`, loads library modules, and dispatches to the appropriate handler function.

### Library Modules (`scripts/lib/`)

| Module | Purpose |
|--------|---------|
| `common.sh` | Logging, label state machine, circuit breaker, prompt loading, Claude runner, output parsing, post-implementation handling |
| `worktree.sh` | Git worktree creation, cleanup, and repo cloning |
| `data-fetch.sh` | Pre-fetches debug data (gists, GitHub file attachments) from issue/PR comments |
| `defaults.sh` | Default configuration values (overridden by `config.env`) |

### Prompts (`prompts/`)

Default prompts for each dispatch mode. Each prompt instructs Claude on what to do, how to format its response, and what tools are available. Custom prompts can be specified in `config.env` to override defaults.

| Prompt | Mode | Purpose |
|--------|------|---------|
| `triage.md` | `new_issue` | Analyze issue, decide questions vs plan |
| `reply.md` | `issue_reply` | Evaluate if questions are answered |
| `implement.md` | `implement` | Implement approved plan with TDD |
| `review.md` | `pr_review` | Address PR review feedback |
| `validate.md` | `direct_implement` | Validate pre-written plan against codebase |

### Worktrees

Each issue gets its own git worktree at `~/.claude/worktrees/<RUNNER_NAME>/<repo>-issue-<N>/`. This provides complete filesystem isolation between concurrent agent runs. Worktrees branch from `origin/main` (or an existing remote branch if one exists for the issue).

The plan phase leaves the worktree in place so the implement phase can reuse it without re-cloning.

### Configuration (`config.env`)

Project-specific settings loaded before defaults. See `config.env.example` for all available options including bot username, timeouts, tool permissions, test commands, and custom prompt paths.

## Data Pipeline

When issues or PRs contain debug data -- gist links, file attachments, or inline data blocks -- the dispatch script pre-fetches this data before invoking Claude.

```
Issue/PR comment
  |
  +--> scan for gist URLs (https://gist.github.com/...)
  |      --> gh gist view --raw --> .agent-data/gist-{id}.txt
  |
  +--> scan for attachment URLs (https://github.com/user-attachments/...)
  |      --> curl download --> .agent-data/{filename}
  |
  +--> find latest data comment body
         --> .agent-data/latest-data-comment.md

File paths passed to Claude via environment variables:
  AGENT_DATA_COMMENT_FILE, AGENT_GIST_FILES, AGENT_DATA_ERRORS
```

Claude reads these local files with the `Read` tool during its analysis. The `.agent-data/` directory is cleaned up when the worktree is removed. If downloads fail, errors are recorded and Claude is instructed to report what it could not access.

Data from comments and gists is framed as "untrusted user-submitted data" in the prompt. Tool restrictions prevent the agent from making network requests, limiting prompt injection risk from malicious content.

## Safety Mechanisms

| Mechanism | Description |
|-----------|-------------|
| **Actor filter** | `github.actor != 'your-bot'` in workflow conditions prevents the bot's own actions from re-triggering workflows |
| **Circuit breaker** | Max bot comments per hour per issue (default: 8). Exceeding the limit sets `agent:failed` and halts |
| **Tool allowlists** | `--allowedTools` restricts what Claude can do. Triage gets read-only tools. Implementation gets read-write but no push, no sudo, no network |
| **Tool denylists** | `--disallowedTools` blocks specific tools (default: `mcp__github__*` to avoid conflicts with gh CLI) |
| **Timeout** | Configurable timeout on `claude -p` (default: 3600s). Workflow-level `timeout-minutes` as a backstop |
| **Concurrency groups** | One job at a time per issue/PR number. Jobs queue (not cancel) to prevent race conditions |
| **CLAUDE.md rules** | The repository's `CLAUDE.md` instructs the agent to never modify workflows, CI/CD, or security files |
| **Env var injection** | Issue content is passed via environment variables, never shell-interpolated into prompts |
| **Branch protection** | (Recommended) Require PR approval before merging to main. The bot cannot approve its own PRs |
| **Pre-PR test gate** | (Optional) Configured via `AGENT_TEST_COMMAND`. Tests must pass before a PR is created |

## Comparison with claude-code-action

[anthropics/claude-code-action](https://github.com/anthropics/claude-code-action) is Anthropic's official GitHub Action for running Claude Code on PRs and issues. Claude Agent Dispatch takes a different approach:

| Feature | claude-code-action | Claude Agent Dispatch |
|---------|-------------------|----------------------|
| **Execution model** | Runs Claude in a GitHub Actions container per event | Runs Claude on persistent self-hosted runners with state |
| **State persistence** | Stateless -- fresh clone each run | Worktrees persist between phases; repo clone reused across runs |
| **Plan/implement separation** | Single invocation | Two-phase: plan then implement with human approval gate |
| **Label state machine** | No structured label tracking | Full state machine with 13 labels tracking agent progress |
| **Tool restrictions** | Configurable | Phase-specific: read-only for triage, read-write for implementation |
| **Circuit breaker** | No | Configurable comments-per-hour limit |
| **Debug data pipeline** | No | Pre-fetches gists and attachments before invoking Claude |
| **Concurrency** | Default GitHub Actions concurrency | Per-issue/PR concurrency groups with queuing (not cancellation) |
| **Customization** | Action inputs | Full config file, custom prompts, extra tools, shared memory |
| **Setup complexity** | Drop-in GitHub Action | Requires self-hosted runners with Claude Code CLI installed |

Claude Agent Dispatch is designed for projects that need more control over the agent lifecycle, want a human checkpoint between planning and implementation, or need persistent runner state (worktrees, caches, project-specific tooling).
