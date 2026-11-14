# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `AGENT_DISPATCH_PAUSED`: a pause switch. With any value other than `false`, every dispatch except `status` exits at once with outcome `paused`, before the lock is taken, a label is changed or a worker starts.
- A mutex on the dispatch lock. Where `flock` is installed, the lock's check-and-write is serialized, so two dispatches fired at the same moment cannot both take it. Without `flock` the pid check alone applies, as before.
- The Claude OAuth refresh-lock race is retried inside the same phase. When several CLI processes on one machine refresh the stored login at once, one can fail at startup before a session exists. That failure now has its own error kind (`auth_refresh_contention`) and is retried up to `AGENT_CLAUDE_AUTH_REFRESH_RETRIES` times (default `2`, maximum `2`) after `AGENT_CLAUDE_AUTH_REFRESH_DELAY_SECONDS` (default `60`). Real authentication failures are not retried.
- `AGENT_WORKTREE_RECOVERED_DAYS` (default `30`): how long a worktree moved aside with unsaved work is kept. `0` keeps them for ever.

### Changed
- **A worktree with unsaved work is never force-removed.** Unsaved means changed or untracked files outside `.agent-data` (ignored files do not count), or commits that no remote branch contains: what an interrupted worker leaves behind. At the end of a dispatch such a worktree is left in place. When the next dispatch needs the path, the worktree is moved to `<worktree base>/.recovered/<name>-<time>` and its branch renamed to `recovered/<branch>-<time>`, and the dispatch starts clean. If the move fails the dispatch stops and removes nothing. A local branch with unpublished commits and no worktree is renamed the same way instead of being deleted. Clean, published worktrees are removed as before.
- **A PR revision runs the pre-PR test gate before its commits are pushed**, with the same bounded fix sessions as an implementation. Until now revision commits were pushed untested. A gate failure pushes the branch, comments on the linked issue and sets `agent:failed`. `AGENT_REVISION_TEST_GATE="false"` restores the old behaviour. The gate only runs when `AGENT_TEST_COMMAND` is set.
- **Failures that were warnings now stop the dispatch:**
  - A failing `AGENT_TEST_SETUP_COMMAND` fails worktree setup, and fails the test gate without running the suite or a fix session. A phase no longer runs in a worktree whose setup failed. To keep the old tolerance, end the command with `|| true`.
  - A review ledger commit that fails (for example a rejecting commit hook) stops the review loop: the branch is pushed, the issue gets a comment and `agent:failed`. No PR is created without its review record.
  - A staged rules edit that cannot be committed stops the dispatch the same way.

## [1.3.1] - 2026-11-13

### Added
- Phase context as files (#135, closes the second half of #118). Before every phase the dispatcher writes the issue title, body and comments, the plan, the PR and review text, the review ledger, the test-gate output and the configured test commands to `.agent-data/context/` in the worktree, and an index of attached data files. A phase reads them with the Read tool, so it knows what it is working on even when it cannot run a shell command. The directory is rebuilt for each phase, cleared by `setup_worktree`, and excluded from `git add`. The file list is in `docs/configuration.md`.
- Referenced issues and pull requests are pre-fetched (#135). An issue or pull request of the same repository named in the issue or review text (`#123` or its URL) is fetched by the dispatcher into `.agent-data/context/references/<number>.md`. `AGENT_CONTEXT_REFS_MAX` (default `10`) bounds how many; `0` turns it off.
- `AGENT_SETTING_SOURCES` (#135) passes `--setting-sources` to Claude phases. The default, `user,project,local`, is the CLI's own, so nothing changes on update. Set `project` to stop phases reading the operator's user settings (allow rules, hooks, plugins, user-level skills), which makes a phase behave the same on every machine. An empty value omits the flag.
- **The `strict` sandbox profile (#137).** `AGENT_SANDBOX="strict"`, or `AGENT_SANDBOX_<PHASE>`, runs a Claude phase under Anthropic's sandbox runtime (`srt`): the whole worker, including the model's own file tools, hooks and MCP servers. Only the worktree, the clone's `.git`, the temp directory and the Claude config directory are writable; the clone's `.git/hooks` and `.git/config` and the Claude settings, skills, plugins and hooks are write-denied; credential stores (`~/.ssh`, the `gh` login, cloud CLI credentials, `.env` files, the install's `config.env`) are absent; the network reaches the model provider, GitHub and the hosts in `AGENT_SANDBOX_ALLOWED_DOMAINS`. `AGENT_SANDBOX_DENY_READ`, `AGENT_SANDBOX_ALLOW_WRITE`, `AGENT_SANDBOX_UNIX_SOCKETS` (for a virtual display) and `AGENT_SANDBOX_SRT` adjust it. The default is `none`: an install that sets nothing is unchanged. A profile that is asked for and cannot start is a configuration error and no phase runs. `git add -A` works inside through a phase-only excludes file. `scripts/check-prereqs.sh` reports whether the sandbox is available. A canary test (`tests/test_sandbox_canary.bats`) checks the profile against the real runtime where it is installed. Setup, lists and limits are in the new `docs/sandbox.md` and in `docs/security.md`. The `gpu` profile from the issue is not part of this release, and Codex phases are not wrapped (asking for `strict` on one is refused).
- Short tool lists for sandboxed phases (#143). Under `strict`, every `Bash(...)` prefix rule in a phase's allowed tools is replaced by a single `Bash` rule, so ordinary shell (variables, redirects, `cd dir && cmd`, loops, heredocs) runs without a matching rule. Rules for other tools are kept, a list with no `Bash` rule is not given shell access, and `AGENT_DISALLOWED_TOOLS` still applies. Unsandboxed phases keep their lists exactly as configured. `AGENT_SANDBOX_SHORT_TOOLS="false"` turns it off. A permission denial in a sandboxed phase is logged as unexpected, not as an allow-list gap.
- `AGENT_PHASE_GH_TOKEN_FILE` (#137): a file holding a GitHub token that is exported to every phase as `GH_TOKEN`, so a phase can read issues and pull requests with `gh` although it has neither the dispatcher's token (#142) nor, under `strict`, a stored login. Intended for a read-only fine-grained token. The value is read at launch, hidden from a sandboxed phase as a file, and redacted from phase output.
- `AGENT_SETTINGS_FILE` (#135): a settings JSON of your own that every phase's generated settings file is built on. Checked at preflight.

### Changed
- **Claude phases get their permission rules from a generated settings file (#135).** The allowed tools for the phase and `AGENT_DISALLOWED_TOOLS` are written as `permissions.allow` and `permissions.deny` in a file passed with `--settings`, created for one phase run and removed afterwards. `--allowedTools` and `--disallowedTools` are no longer passed. The rules themselves are unchanged. A tool list may be separated by commas or spaces; a separator inside parentheses stays part of its rule.
- **The default prompts read context files, not environment variables (#135).** No shipped prompt says `echo "$AGENT_..."` any more, so the exact-match allow rules those commands needed can go. The `AGENT_*` context variables are still exported for custom prompts and are deprecated: move custom prompts to the files (`docs/customization.md` has the mapping). The test commands are read from `.agent-data/context/test-command.txt` and `test-setup-command.txt`.

## [1.3.0] - 2026-11-12

### Added
- Two headless controls for Claude phases (#136). `AGENT_PERMISSION_PROMPTS` (default `none`) passes `--permission-prompts none`, so a tool call that would prompt is denied at once and reported in `permission_denials`, where the model would otherwise spend turns retrying variants of it; the flag is passed only when the installed CLI's `--help` lists it, and an empty value omits it. `AGENT_BG_WAIT_CEILING_MS` (default `600000`, per-phase `AGENT_BG_WAIT_CEILING_MS_<PHASE>`) is exported to the phase as `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, bounding how long `claude -p` waits on its own background work so a stuck task returns a result before the outer `timeout` kills the CLI; the default equals the CLI's own ceiling as of 2.1.322, and an empty value leaves the CLI's own. Both are validated at preflight.
- Staged worker configuration (#116): dispatch/per-phase engine resolution, engine-specific model defaults, and reachable-phase preflight before worktree changes or worker execution. Claude remains the only enabled engine; Codex selections fail closed pending permission verification. Schemas and worker policy settings are frozen for the dispatch, and status remains independent of worker authentication.
- Dispatch hygiene (#99): `setup_worktree` now clears every dispatch-scoped scratch artefact (`plan.md`, `permission-denials.log`, the rules staging directory) so a reused worktree can never post a previous dispatch's plan verbatim, report its denials, or apply its staged rules edits. Config provenance is logged once at startup — config sources, execution mode, and every phase's model — for every event including `status`, at the only point where the printed values are guaranteed to be the values used. A standing BATS guard asserts no script read-modify-writes an issue or PR body (tracking state in a body corrupts cumulatively), and the cleanup prompt states the rule.
- Per-phase invocation flags (#98), every one optional and defaulting to current behaviour: `AGENT_BUDGET_USD_<PHASE>` / `AGENT_BUDGET_USD` pass `--max-budget-usd` (**limitless by default** — a dollar cap is the operator's choice; turns and timeout still bound every phase), `AGENT_EFFORT_<PHASE>` passes `--effort`, `AGENT_PERMISSION_MODE_<PHASE>` passes `--permission-mode`. `AGENT_MCP_CONFIG` (path) passes `--mcp-config` **with** `--strict-mcp-config` so phases get exactly the harness's MCP servers and none of the operator's; `AGENT_STRICT_MCP=true` strips MCP entirely. Headless phases now pass `--no-session-persistence` by default (`AGENT_SESSION_PERSISTENCE=true` opts out) so they stop accumulating resumable sessions.
- `AGENT_MEMORY_DIR` (#97): point at a shared memory directory (the `~/.claude/projects/<slug>/memory/` layout) and phases can `Read` the files the injected index points at — previously `AGENT_MEMORY_FILE` handed the agent a table of contents for a book it could not open. The index is still injected via `--append-system-prompt`; the directory is passed as `--add-dir` (out-of-tree reads are path-gated without it); the preamble names the directory and keeps memory read-only. `AGENT_MEMORY_FILE` alone behaves exactly as before, and names the index when both are set. Absolute or workspace-relative.
- Structured phase output via `--json-schema` (#96): the seven machine-consumed phases (triage, reply, validate, Gate A plan review, Gate B review, Gate B retry, post-merge cleanup) now pass a JSON Schema so the CLI returns a guaranteed-shape object in the envelope's `structured_output` field. Handlers prefer the validated object and fall back to the existing text extraction, so custom prompts and older CLIs behave exactly as before; a configured schema that yields no validated object is reported as a schema/prompt mismatch, distinct from an agent failure. Schemas live in `schemas/*.json`; `AGENT_JSON_SCHEMA_<PHASE>` overrides or disables per phase (`""` disables). Phases with no machine-consumed result (implement, revision) take no schema.
- Orchestrator mode (#95): `AGENT_EXECUTION_MODE=orchestrator` runs the same pipeline from an interactive Claude Code session instead of a GitHub Actions workflow — phases inherit the operator's whole environment (user CLAUDE.md, memory, skills, authenticated tools) with nothing to provision or sync. In this mode human-readable output moves to stderr and the **final line of stdout is a compact JSON result** (`{event, repo, issue, outcome, exit_code, pr_url, started, finished}`), which keeps the orchestrating session thin: run one command, parse one line, narrate. Four new skills — `/sp-work` (label-aware event selection, plan-review gate preserved), `/sp-status` (read-only liveness), `/sp-revise`, `/sp-post-merge` — encode the operator discipline (the session never implements anything itself) and the liveness verification rule. Default `actions` mode is byte-for-byte unchanged.
- Dispatch liveness (#94): three independent signals answer "is it still going?" for long dispatches, since background-task monitors can report a live run as killed. A per-issue lock (`AGENT_LOCK_DIR`, default `$AGENT_LOG_DIR/locks`) carries pid/host/event/start and a **current-phase heartbeat** updated at every phase and every review-loop pass; a new read-only `status` event reports the lock as live or stale (final stdout line is compact JSON — the machine contract orchestrator mode will parse) without mutating anything; and a `last-dispatch.json` outcome record is written before exit on every outcome including failure, carrying the last agent label set plus exit code and timing. A held lock refuses the dispatch naming the holder; a dead same-host lock is reclaimed by the next dispatch; the verification rule ("a killed notification is unverified until checked") is documented in troubleshooting and architecture.
- Permission denials are now surfaced instead of silently costing turns (#93): after every phase, the envelope's `permission_denials` array is extracted, logged (`WARN: <phase>: permission denial(s)…`), and accumulated in the dispatch-scoped `.agent-data/permission-denials.log` (cleared by `setup_worktree` so a reused worktree never reports a previous run's denials). Non-empty denials appear as a "Permission Denials" section in the PR body, the implementation fail-fast comment, and the test-gate failure comment — each entry is an allow-list gap to fix in config. New `AGENT_ADD_DIRS` passes `--add-dir` per directory, since path gating is separate from tool allow rules. The broad-allow/narrow-deny idiom is documented in `docs/customization.md`.
- Rules staging works around the `.claude/**` write guard (#92): a headless phase cannot write anything under `.claude/` — a built-in, path-based guard in Claude Code that no allow-list entry lifts, and the phase reports success having written nothing. New `lib/rules-staging.sh` copies `.claude/rules/*.md` into `.agent-data/rules/` before each write phase (implement, revise, post-merge cleanup); the phase edits the staged copies (default prompts updated to say so); the harness copies back whatever differs and commits it. A staged file is honoured only if `.claude/rules/` already holds a file of that name matching `^[A-Za-z0-9._-]+\.md$` — a phase cannot invent rules files. No-op for repos without `.claude/rules/`. Documented in `docs/customization.md` and `docs/troubleshooting.md`.
- Actor-filter breadcrumb (#75): the label caller templates (triage, implement, direct-implement; reference and standalone variants) now include an `actor-filter-notice` job that comments on the issue when a trigger label is applied by the bot account — previously the anti-self-trigger guard skipped the run with no feedback anywhere. The comment runs on `ubuntu-latest` with the default `GITHUB_TOKEN`, so it works even when the self-hosted runner is down and cannot re-trigger workflows.
- `repository_dispatch` documented as the official programmatic on-ramp (#75): event types `agent-triage`/`agent-implement`/`agent-reply` and the `client_payload.issue_number` payload are now covered in `docs/architecture.md` ("Programmatic Triggering"), `docs/troubleshooting.md` (Actor Filter check), and the setup skill.

### Changed
- **Phases no longer inherit the dispatcher's credentials (#142).** Both worker engines are now launched with `GH_TOKEN`, `GITHUB_TOKEN`, their enterprise variants, `AGENT_GIST_PAT`, the notification webhooks and maps, the Discord and Slack bot tokens and the Actions runtime tokens removed from the environment. The dispatcher does every GitHub read and write itself and keeps them; no default prompt calls `gh`. Previously a phase, and anything that steered it through issue text, a pasted log or a dependency, could read a token able to push and write issues, and the tool allow list was credited with preventing that when it does not. **If a custom prompt of yours calls `gh` or needs one of these variables inside a phase, it will now find it unset**: name it in the new `AGENT_PHASE_KEEP_ENV`, or move the step into the dispatcher. `AGENT_PHASE_SCRUB_ENV` removes further variables. Startup logs, by name only, which credentials were withheld and which were kept. `docs/security.md` is corrected: the allow list is not a security boundary, and a credential on disk is still readable by a phase running as the same OS user.
- Dispatch caller workflow renamed from "Claude Agent: Discord Dispatch" to "Agent Dispatch (programmatic)" (#75) — Discord is one caller of the `repository_dispatch` entry point, not its owner. Cosmetic `name:` change only; filenames and event types are unchanged, no migration needed for existing consumers.
- `discord-bot/install.sh` now accepts `--config <path>` for non-interactive use, matching `slack-bot/install.sh`. Previously the Discord installer always prompted via `read`, making scripted reinstalls fragile (callers had to feed an empty line via stdin to use the default). Both installers now share the same option-parsing block and reject unknown flags with exit 1.
- Repository renamed from `jnurre64/claude-pal-action` to `jnurre64/sandbox-pal-action` (2026-04-23). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. The rebrand also drops "Claude" from user-visible identifiers: workflow filenames (`dispatch-*.yml` → `sandbox-pal-*.yml`), concurrency group names (`claude-agent-*` → `sandbox-pal-*`), the internal dispatch script and directory (`scripts/agent-dispatch.sh` → `scripts/sandbox-pal-dispatch.sh`, `.agent-dispatch/` → `.sandbox-pal-dispatch/`), systemd service names, and notification footers. Motivated by upcoming multi-model support. See `docs/superpowers/plans/2026-04-23-rename-to-sandbox-pal-action.md`.
- Repository renamed from `jnurre64/claude-agent-dispatch` to `jnurre64/claude-pal-action` (2026-04-18). Old URL continues to redirect indefinitely. No version bump — rename is non-breaking. See `docs/superpowers/specs/2026-04-18-rename-to-claude-pal-action-design.md`.

### Fixed
- A review of a long-lived branch no longer dies as an "Agent Infrastructure Error" with exit code 141 (#129). The dispatcher runs under `set -o pipefail` and read the branch's commits with `git log … | head -N`; once the branch had more than N commits, `head` closed the pipe, `git log` died of SIGPIPE, and the ERR trap reported an infrastructure failure before any agent session started. Both commit-log sites (the review context, limit 30, and the PR-body fallback, limit 20) now go through `branch_commit_lines`, which limits with `git log -n`. The remaining `| head` uses in `scripts/` are replaced with forms that read their whole input, and a standing BATS guard keeps `| head` out of the scripts.
- A closed subscription usage window is no longer reported as an exhausted quota, and every failed phase now keeps its evidence (#127). The result adapter classified `usage limit` / `session limit` / per-model limit wording as kind `quota` ("API error: quota exhausted"), which reads as billing, and it discarded the envelope's `subtype`, `terminal_reason`, `api_error_status` and error text — so an operator whose two workers died inside the same two minutes was told to top up, with nothing left to prove otherwise. `normalize` now emits kind `usage_limit` ("API error: usage limit reached (the window resets on its own; re-dispatch after it does)") for the CLI's usage-window wording, checks a `429` / `rate limit` before the `quota` substring so the CLI's own rate-limit text is a recoverable rate limit, and keeps `quota` for `credit balance` / `billing` / `insufficient_quota`. Every failure carries `error.detail` — the envelope's subtype, terminal reason, API status, exit code and the first 300 characters of the error text, after redaction — and `parse_agent_output` appends it in brackets, so the dispatch log and the `agent:failed` comment name the actual stop. `usage_limit` stays fail-fast: retrying inside a closed window would only burn the fix-up phases against the same wall.
- Worker phases now consume a versioned neutral result through the Claude adapter (#116). Nonzero exits no longer concatenate envelopes, semantic failures cannot approve partial output, and configured schemas fail closed using the packaged Python `jsonschema` dependency. Missing telemetry remains unknown. Capped/timed-out implementation work requires tests and independent review before recovery can succeed. Claude flags and the public orchestrator outcome remain compatible; this does not enable Codex workers.
- Standalone setup and update now share an asset inventory that includes schemas, packaged skills, and workflow templates (#112). Updates preserve customized checksum baselines, reconcile missing assets at the same revision, and report caller template changes. `--yes` accepts safe updates without replacing customizations; EOF and interrupted copies can be retried without corrupting tracking or truncating the installed updater.
- Phase output is now scrubbed for credentials at the point of capture (#91): `run_claude` pipes the envelope and rewrites the stderr log through the new `redact_secrets` filter before either reaches any log line, saved file, parse, or issue/PR comment. Covered: well-known token shapes (`github_pat_…`, `gh[pousr]_…`, `Authorization:` header values) and the literal values of credential-looking environment variables (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*API_KEY*`, `*CREDENTIAL*`), which phases inherit. Deny rules remain the first line of defence — but a denied command is echoed verbatim to explain the denial, which is exactly where a credential surfaces in a log or public comment. Guarantee and limits documented in `docs/security.md`.
- Phase failure is now classified from the whole envelope instead of `subtype` alone (#90). An API-error envelope carries `is_error: true` together with `subtype: "success"`, so the old fallback could report an exhausted quota as `Agent stopped: success`. `parse_claude_output` now checks `is_error` first and never interpolates a non-`error_*` subtype as a cause, and the new `classify_claude_result` marks API errors as fail-fast: the implementation handler stops before the test gate and review loop, and the review/retry sessions abort the loop with an accurate API-error comment instead of "could not parse its output". Turn/budget caps and timeouts remain recoverable, exactly what the fix-up phases exist for.
- Review ledger is now stamped with its issue number, and `_ledger_init` discards a ledger stamped with a different issue (or not stamped at all) instead of merging it (#89). The ledger is committed to the work branch, so a branch cut after a merge inherited the previous PR's findings — the inherited ledger only ever grew, and in a reference implementation of the same pipeline it eventually overflowed the environment variable carrying it into the review phase, killing the review before it reviewed anything. Same-issue retries keep their history exactly as before.
- `discord-bot/install.sh` and `slack-bot/install.sh` now `cd` into their own directory before running `pip install`, so the editable `-e ../shared` requirement resolves correctly when the script is invoked from any cwd. Without this, `bash slack-bot/install.sh` from the repo root failed with `../shared is not a valid editable requirement`.
- `discord-bot/bot.py` now configures the root logger via `logging.basicConfig(force=True)` in `_setup_logging()` before `bot.run`. Previously `bot.run(..., log_handler=StreamHandler(), log_level=INFO)` only configured discord.py's own loggers, leaving the `dispatch-bot` logger without a handler — every routing-decision INFO line and action handler log line was silently dropped, making it impossible to triage notification issues from `journalctl`.
- A config file that overwrites an exported `AGENT_*` variable no longer does so silently (#132). A plain `VAR=value` in `config.defaults.env` or the overrides file replaces a value exported by the caller, so a per-dispatch override such as `AGENT_BUDGET_USD_IMPLEMENT=150 sandbox-pal-dispatch.sh …` ran with the file's value and nothing said so. The loader now records each exported `AGENT_*` variable a sourced file changed, and startup logs one `WARN` listing the names and the file responsible (never the values). Which value wins is unchanged: the file still does, and `VAR="${VAR:-default}"` remains the way to let the environment win. Two statements that the environment always takes precedence are corrected.

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
