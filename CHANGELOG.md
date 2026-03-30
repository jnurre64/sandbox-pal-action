# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Data privacy section in security.md and README
- Issue and PR templates for community contributions
- Presentation materials for April 2026 demo

## [1.0.0] - 2026-03-30

### Added
- Discord bot with interactive buttons (approve, request changes, comment, retry)
- Discord slash commands (/approve, /reject, /comment, /status, /retry)
- Bot install script with systemd service management
- Notification system with pluggable backends (Discord webhook, Discord bot)
- Review completion notifications (review_pushed event)
- Label-based tool extensions (AGENT_LABEL_TOOLS_*)
- Shared memory file support (AGENT_MEMORY_FILE)
- Pre-PR test gate (AGENT_TEST_COMMAND)
- Debug data pre-fetching for gists and attachments
- Comprehensive documentation (10+ guides)
- 52 BATS tests with regression coverage
- ShellCheck CI on all shell scripts
- Setup skill (/setup) for interactive project configuration
- Update skill (/update) for standalone installation sync

### Security
- Two-phase dispatch: plan review before implementation
- Phase-specific tool allowlists (read-only triage, read-write implementation)
- Circuit breaker (configurable max bot comments per hour per issue)
- Actor filter prevents bot self-triggering
- Concurrency groups (one agent job per issue)
- Fine-grained PAT guidance with rotation procedures
- Environment variable injection (no shell interpolation of issue content)
- Secret-guarding instructions in agent prompts
