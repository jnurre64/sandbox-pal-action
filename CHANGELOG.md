# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
