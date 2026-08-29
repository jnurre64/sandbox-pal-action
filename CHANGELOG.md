# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Orchestrator mode (#95): `AGENT_EXECUTION_MODE=orchestrator` runs the same pipeline from an interactive Claude Code session instead of a GitHub Actions workflow — phases inherit the operator's whole environment (user CLAUDE.md, memory, skills, authenticated tools) with nothing to provision or sync. In this mode human-readable output moves to stderr and the **final line of stdout is a compact JSON result** (`{event, repo, issue, outcome, exit_code, pr_url, started, finished}`), which keeps the orchestrating session thin: run one command, parse one line, narrate. Four new skills — `/sp-work` (label-aware event selection, plan-review gate preserved), `/sp-status` (read-only liveness), `/sp-revise`, `/sp-post-merge` — encode the operator discipline (the session never implements anything itself) and the liveness verification rule. Default `actions` mode is byte-for-byte unchanged.
- Dispatch liveness (#94): three independent signals answer "is it still going?" for long dispatches, since background-task monitors can report a live run as killed. A per-issue lock (`AGENT_LOCK_DIR`, default `$AGENT_LOG_DIR/locks`) carries pid/host/event/start and a **current-phase heartbeat** updated at every phase and every review-loop pass; a new read-only `status` event reports the lock as live or stale (final stdout line is compact JSON — the machine contract orchestrator mode will parse) without mutating anything; and a `last-dispatch.json` outcome record is written before exit on every outcome including failure, carrying the last agent label set plus exit code and timing. A held lock refuses the dispatch naming the holder; a dead same-host lock is reclaimed by the next dispatch; the verification rule ("a killed notification is unverified until checked") is documented in troubleshooting and architecture.
- Permission denials are now surfaced instead of silently costing turns (#93): after every phase, the envelope's `permission_denials` array is extracted, logged (`WARN: <phase>: permission denial(s)…`), and accumulated in the dispatch-scoped `.agent-data/permission-denials.log` (cleared by `setup_worktree` so a reused worktree never reports a previous run's denials). Non-empty denials appear as a "Permission Denials" section in the PR body, the implementation fail-fast comment, and the test-gate failure comment — each entry is an allow-list gap to fix in config. New `AGENT_ADD_DIRS` passes `--add-dir` per directory, since path gating is separate from tool allow rules. The broad-allow/narrow-deny idiom is documented in `docs/customization.md`.
- Rules staging works around the `.claude/**` write guard (#92): a headless phase cannot write anything under `.claude/` — a built-in, path-based guard in Claude Code that no allow-list entry lifts, and the phase reports success having written nothing. New `lib/rules-staging.sh` copies `.claude/rules/*.md` into `.agent-data/rules/` before each write phase (implement, revise, post-merge cleanup); the phase edits the staged copies (default prompts updated to say so); the harness copies back whatever differs and commits it. A staged file is honoured only if `.claude/rules/` already holds a file of that name matching `^[A-Za-z0-9._-]+\.md$` — a phase cannot invent rules files. No-op for repos without `.claude/rules/`. Documented in `docs/customization.md` and `docs/troubleshooting.md`.
- Actor-filter breadcrumb (#75): the label caller templates (triage, implement, direct-implement; reference and standalone variants) now include an `actor-filter-notice` job that comments on the issue when a trigger label is applied by the bot account — previously the anti-self-trigger guard skipped the run with no feedback anywhere. The comment runs on `ubuntu-latest` with the default `GITHUB_TOKEN`, so it works even when the self-hosted runner is down and cannot re-trigger workflows.
- `repository_dispatch` documented as the official programmatic on-ramp (#75): event types `agent-triage`/`agent-implement`/`agent-reply` and the `client_payload.issue_number` payload are now covered in `docs/architecture.md` ("Programmatic Triggering"), `docs/troubleshooting.md` (Actor Filter check), and the setup skill.

### Changed
- Dispatch caller workflow renamed from "Claude Agent: Discord Dispatch" to "Agent Dispatch (programmatic)" (#75) — Discord is one caller of the `repository_dispatch` entry point, not its owner. Cosmetic `name:` change only; filenames and event types are unchanged, no migration needed for existing consumers.
- `discord-bot/install.sh` now accepts `--config <path>` for non-interactive use, matching `slack-bot/install.sh`. Previously the Discord installer always prompted via `read`, making scripted reinstalls fragile (callers had to feed an empty line via stdin to use the default). Both installers now share the same option-parsing block and reject unknown flags with exit 1.

### Fixed
- Phase output is now scrubbed for credentials at the point of capture (#91): `run_claude` pipes the envelope and rewrites the stderr log through the new `redact_secrets` filter before either reaches any log line, saved file, parse, or issue/PR comment. Covered: well-known token shapes (`github_pat_…`, `gh[pousr]_…`, `Authorization:` header values) and the literal values of credential-looking environment variables (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*API_KEY*`, `*CREDENTIAL*`), which phases inherit. Deny rules remain the first line of defence — but a denied command is echoed verbatim to explain the denial, which is exactly where a credential surfaces in a log or public comment. Guarantee and limits documented in `docs/security.md`.
- Phase failure is now classified from the whole envelope instead of `subtype` alone (#90). An API-error envelope carries `is_error: true` together with `subtype: "success"`, so the old fallback could report an exhausted quota as `Agent stopped: success`. `parse_claude_output` now checks `is_error` first and never interpolates a non-`error_*` subtype as a cause, and the new `classify_claude_result` marks API errors as fail-fast: the implementation handler stops before the test gate and review loop, and the review/retry sessions abort the loop with an accurate API-error comment instead of "could not parse its output". Turn/budget caps and timeouts remain recoverable, exactly what the fix-up phases exist for.
- Review ledger is now stamped with its issue number, and `_ledger_init` discards a ledger stamped with a different issue (or not stamped at all) instead of merging it (#89). The ledger is committed to the work branch, so a branch cut after a merge inherited the previous PR's findings — the inherited ledger only ever grew, and in a reference implementation of the same pipeline it eventually overflowed the environment variable carrying it into the review phase, killing the review before it reviewed anything. Same-issue retries keep their history exactly as before.
- `discord-bot/install.sh` and `slack-bot/install.sh` now `cd` into their own directory before running `pip install`, so the editable `-e ../shared` requirement resolves correctly when the script is invoked from any cwd. Without this, `bash slack-bot/install.sh` from the repo root failed with `../shared is not a valid editable requirement`.
- `discord-bot/bot.py` now configures the root logger via `logging.basicConfig(force=True)` in `_setup_logging()` before `bot.run`. Previously `bot.run(..., log_handler=StreamHandler(), log_level=INFO)` only configured discord.py's own loggers, leaving the `dispatch-bot` logger without a handler — every routing-decision INFO line and action handler log line was silently dropped, making it impossible to triage notification issues from `journalctl`.

### Changed
- Repository renamed from `jnurre64/claude-pal-action` to `jnurre64/sandbox-pal-action` (2026-04-23). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. The rebrand also drops "Claude" from user-visible identifiers: workflow filenames (`dispatch-*.yml` → `sandbox-pal-*.yml`), concurrency group names (`claude-agent-*` → `sandbox-pal-*`), the internal dispatch script and directory (`scripts/agent-dispatch.sh` → `scripts/sandbox-pal-dispatch.sh`, `.agent-dispatch/` → `.sandbox-pal-dispatch/`), systemd service names, and notification footers. Motivated by upcoming multi-model support. See `docs/superpowers/plans/2026-04-23-rename-to-sandbox-pal-action.md`.
- Repository renamed from `jnurre64/claude-agent-dispatch` to `jnurre64/claude-pal-action` (2026-04-18). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. See `docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md`.

## [1.2.0] - 2026-04-03

### Added
- Global error trap with diagnostic messages for infrastructure failures
- AI-assisted discoverability: doc routing in CLAUDE.md, subdirectory CLAUDE.md files, function export comments in lib/ modules
- Discord bot with interactive buttons (approve, request changes, comment, retry)
- Discord slash commands and modal feedback
- Bot install script with systemd service management
- Discord bot repository_dispatch integration for triggering workflows from Discord
- Multi-repo notification support in Discord bot
- Review completion notifications (review_pushed event)
- Layered config: split committed defaults from gitignored overrides
- Versioning policy documentation (docs/versioning.md)
- OSS hygiene: dependabot, CODEOWNERS, .editorconfig, FUNDING.yml, issue template config
- Issue and PR templates for community contributions
- Data privacy section in security.md and README
- Secret-guarding instructions in agent prompts

### Fixed
- Triage agent now asks clarifying questions when key details are missing instead of assuming
- Notify backend allows bot mode without requiring a webhook URL
- Error trap catches bash parameter expansion failures
- Setup checks for *.env gitignore rules blocking config.defaults.env
- Write tool added to triage tool allowlist in config example
- Test setup runs after worktree creation for all event types
- Bot install.sh handles broken venv gracefully

### Changed
- Setup skill recommends standalone mode over reference mode
- Bump actions/checkout from v4 to v6

## [1.1.2] - 2026-03-22

### Added
- Discord webhook notification system with pluggable backend architecture
- Notification calls at all dispatch milestones (plan posted, questions asked, tests passed/failed, PR created, agent failed)
- Notification level filtering (all, actionable, failures)

### Fixed
- Remove existing worktree before PR review checkout to prevent conflicts

## [1.1.1] - 2026-03-22

### Added
- Commit log included in PR body as fallback for sparse Claude output
- Design spec for Discord notification and interaction layer

## [1.1.0] - 2026-03-22

### Added
- Auto-respond to comments during plan review phase (re-triage with feedback)

## [1.0.6] - 2026-03-21

### Added
- BATS test suite with 52 tests and regression coverage
- Testing documentation in CONTRIBUTING.md and docs/testing.md
- Update script tests and static file discovery fix

## [1.0.5] - 2026-03-21

### Fixed
- Duplicate Summary heading in PR body

## [1.0.4] - 2026-03-21

### Fixed
- Compare against origin/main for retry detection instead of HEAD

## [1.0.3] - 2026-03-21

### Added
- AGENT_TEST_SETUP_COMMAND for pre-test environment initialization

## [1.0.2] - 2026-03-21

### Fixed
- Add Write tool to triage toolset for plan file output

## [1.0.1] - 2026-03-21

### Fixed
- Prompt path resolution for standalone mode

## [1.0.0] - 2026-03-21

### Added
- Label-driven dispatch system for running Claude Code agents on GitHub issues
- Two-phase dispatch: plan review before implementation
- Four dispatch modes: triage, implement, reply, review
- Label state machine with 10 agent labels
- Reusable GitHub Actions workflows (dispatch-triage, dispatch-implement, dispatch-reply, dispatch-review, cleanup)
- Git worktree isolation for concurrent issue handling
- Debug data pre-fetching for gists and attachments
- Label-based tool extensions (AGENT_LABEL_TOOLS_*)
- Shared memory file support (AGENT_MEMORY_FILE)
- Pre-PR test gate (AGENT_TEST_COMMAND)
- Configurable prompts, tool allowlists, and timeouts
- Setup skill (/setup) for interactive project configuration
- Update skill (/update) for standalone installation sync
- Comprehensive documentation (10+ guides)
- ShellCheck CI on all shell scripts

### Security
- Phase-specific tool allowlists (read-only triage, read-write implementation)
- Circuit breaker (configurable max bot comments per hour per issue)
- Actor filter prevents bot self-triggering
- Concurrency groups (one agent job per issue)
- Fine-grained PAT guidance with rotation procedures
- Environment variable injection (no shell interpolation of issue content)
