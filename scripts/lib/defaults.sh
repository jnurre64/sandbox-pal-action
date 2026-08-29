#!/bin/bash
# ─── Default configuration values ────────────────────────────────
# Provides: AGENT_BOT_USER, AGENT_MAX_TURNS, AGENT_TIMEOUT, AGENT_CIRCUIT_BREAKER_LIMIT,
#           AGENT_ALLOWED_TOOLS_*, AGENT_EXTRA_TOOLS, AGENT_DISALLOWED_TOOLS,
#           AGENT_PROMPT_*, AGENT_NOTIFY_*, AGENT_DISCORD_*, AGENT_LOG_DIR
# These are overridden by config.env (sourced before this file)
# or by environment variables set by the caller.

# Bot account username (REQUIRED — no default)
AGENT_BOT_USER="${AGENT_BOT_USER:?AGENT_BOT_USER must be set in config.env}"

# Max Claude conversation turns per invocation
AGENT_MAX_TURNS="${AGENT_MAX_TURNS:-200}"

# Timeout in seconds before killing a stuck claude -p process
AGENT_TIMEOUT="${AGENT_TIMEOUT:-3600}"

# Circuit breaker: max bot comments per hour per issue
AGENT_CIRCUIT_BREAKER_LIMIT="${AGENT_CIRCUIT_BREAKER_LIMIT:-8}"

# Shared Claude memory file (optional)
AGENT_MEMORY_FILE="${AGENT_MEMORY_FILE:-}"

# Shared Claude memory directory (optional): index + the files its
# pointers name; phases can Read them, read-only (#97)
AGENT_MEMORY_DIR="${AGENT_MEMORY_DIR:-}"

# Extra directories phases may access unprompted, space-separated
# (--add-dir; path gating is separate from tool allow rules)
AGENT_ADD_DIRS="${AGENT_ADD_DIRS:-}"

# Pre-test setup command (optional — runs before test command, e.g., npm install, godot --headless --import)
AGENT_TEST_SETUP_COMMAND="${AGENT_TEST_SETUP_COMMAND:-}"

# Pre-PR test command (optional — if unset, test gate is skipped)
AGENT_TEST_COMMAND="${AGENT_TEST_COMMAND:-}"

# Claude effort level for all agent runs
AGENT_EFFORT_LEVEL="${AGENT_EFFORT_LEVEL:-high}"

# Allow direct implementation via agent:implement label (skip triage)
AGENT_ALLOW_DIRECT_IMPLEMENT="${AGENT_ALLOW_DIRECT_IMPLEMENT:-true}"

# ─── Tool permissions ────────────────────────────────────────────
# Triage/reply: read-only + Write (needed to output plan file to .agent-data/)
AGENT_ALLOWED_TOOLS_TRIAGE="${AGENT_ALLOWED_TOOLS_TRIAGE:-Read,Write,Grep,Glob,Bash(echo:*),Bash(cat:*),Bash(ls:*),Bash(find:*)}"

# Implementation/review: read-write by default
AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT:-Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*),Bash(mkdir:*)}"

# Additional tools to append (e.g., project-specific build tools)
AGENT_EXTRA_TOOLS="${AGENT_EXTRA_TOOLS:-}"

# Tools to disallow (default: block MCP GitHub tools to avoid conflicts with gh CLI)
AGENT_DISALLOWED_TOOLS="${AGENT_DISALLOWED_TOOLS:-mcp__github__*}"

# ─── Prompt files (optional — uses built-in defaults if unset) ───
# Point to custom prompt files to override agent behavior per project.
# If unset, the dispatch script uses prompts/ from the repo root.
AGENT_PROMPT_TRIAGE="${AGENT_PROMPT_TRIAGE:-}"
AGENT_PROMPT_IMPLEMENT="${AGENT_PROMPT_IMPLEMENT:-}"
AGENT_PROMPT_REPLY="${AGENT_PROMPT_REPLY:-}"
AGENT_PROMPT_REVIEW="${AGENT_PROMPT_REVIEW:-}"
AGENT_PROMPT_VALIDATE="${AGENT_PROMPT_VALIDATE:-}"

# ─── Adversarial review gates ────────────────────────────────
# Pre-implementation plan review (fresh session checks plan vs issue)
AGENT_ADVERSARIAL_PLAN_REVIEW="${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}"
# Post-implementation diff review (fresh session checks diff vs issue/plan)
AGENT_POST_IMPL_REVIEW="${AGENT_POST_IMPL_REVIEW:-true}"
# Max fix sessions for the post-impl review loop (0 = single review pass; unresolved findings surface on the PR as agent:review-unresolved)
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-3}"
# Max Claude fix sessions when the pre-PR test gate fails
# (0 = fail immediately; the work branch is pushed either way — issue #73)
AGENT_TEST_GATE_MAX_RETRIES="${AGENT_TEST_GATE_MAX_RETRIES:-2}"

# Review gate prompt overrides (empty = use built-in defaults)
AGENT_PROMPT_ADVERSARIAL_PLAN="${AGENT_PROMPT_ADVERSARIAL_PLAN:-}"
AGENT_PROMPT_POST_IMPL_REVIEW="${AGENT_PROMPT_POST_IMPL_REVIEW:-}"
AGENT_PROMPT_POST_IMPL_RETRY="${AGENT_PROMPT_POST_IMPL_RETRY:-}"
AGENT_PROMPT_TEST_FIX="${AGENT_PROMPT_TEST_FIX:-}"

# ─── Post-merge cleanup phase ────────────────────────────────
# Runs a short headless session after an agent PR merges: tracking-doc
# updates, follow-up issues from the review ledger, branch deletion.
AGENT_CLEANUP_ENABLED="${AGENT_CLEANUP_ENABLED:-true}"
AGENT_PROMPT_CLEANUP="${AGENT_PROMPT_CLEANUP:-}"
AGENT_ALLOWED_TOOLS_CLEANUP="${AGENT_ALLOWED_TOOLS_CLEANUP:-Read,Edit,Write,Grep,Glob,Bash(git add:*),Bash(git commit:*),Bash(git rm:*),Bash(git status),Bash(git diff:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(grep:*),Bash(find:*)}"

# ─── Model configuration ────────────────────────────────────
# Claude model to use (empty = use CLI default, currently Opus 4.6)
AGENT_MODEL="${AGENT_MODEL:-}"

# Per-workflow model overrides (empty = fall back to AGENT_MODEL, then CLI default).
# Use these to pick a faster/cheaper model for read-only review phases while
# keeping a stronger model for implementation, or vice versa.
AGENT_MODEL_TRIAGE="${AGENT_MODEL_TRIAGE:-}"
AGENT_MODEL_IMPLEMENT="${AGENT_MODEL_IMPLEMENT:-}"
AGENT_MODEL_REVIEW="${AGENT_MODEL_REVIEW:-}"
AGENT_MODEL_ADVERSARIAL_PLAN="${AGENT_MODEL_ADVERSARIAL_PLAN:-}"
AGENT_MODEL_POST_IMPL_REVIEW="${AGENT_MODEL_POST_IMPL_REVIEW:-}"
AGENT_MODEL_POST_IMPL_RETRY="${AGENT_MODEL_POST_IMPL_RETRY:-}"
AGENT_MODEL_TEST_FIX="${AGENT_MODEL_TEST_FIX:-}"  # pre-PR test-gate fix sessions
AGENT_MODEL_CLEANUP="${AGENT_MODEL_CLEANUP:-}"  # post-merge cleanup phase

# ─── Label-to-tool mapping ────────────────────────────────────────
# Map issue labels to extra tools that get added when the label is present.
# Format: AGENT_LABEL_TOOLS_<sanitized_label>="tool1,tool2"
# Label names are sanitized: colons become underscores, hyphens become underscores.
# Example: for label "agent:image-gen", set:
#   AGENT_LABEL_TOOLS_agent_image_gen="Bash(curl *localhost:8188*),Bash(python3:*)"
# These tools are appended to the implementation toolset when the label is detected.

# ─── Notifications (optional — disabled by default) ─────────────────
# Discord webhook URL for dispatch milestone notifications
AGENT_NOTIFY_DISCORD_WEBHOOK="${AGENT_NOTIFY_DISCORD_WEBHOOK:-}"

# Optional: post notifications to a specific Discord thread
AGENT_NOTIFY_DISCORD_THREAD_ID="${AGENT_NOTIFY_DISCORD_THREAD_ID:-}"

# Notification level: "all", "actionable" (default), "failures"
AGENT_NOTIFY_LEVEL="${AGENT_NOTIFY_LEVEL:-actionable}"

# ─── Discord Bot (Phase 2 — interactive notifications) ────────────
AGENT_DISCORD_BOT_TOKEN="${AGENT_DISCORD_BOT_TOKEN:-}"
AGENT_DISCORD_CHANNEL_ID="${AGENT_DISCORD_CHANNEL_ID:-}"
AGENT_DISCORD_GUILD_ID="${AGENT_DISCORD_GUILD_ID:-}"
AGENT_DISCORD_ALLOWED_USERS="${AGENT_DISCORD_ALLOWED_USERS:-}"
AGENT_DISCORD_ALLOWED_ROLE="${AGENT_DISCORD_ALLOWED_ROLE:-}"
AGENT_DISCORD_BOT_PORT="${AGENT_DISCORD_BOT_PORT:-8675}"
# Notification backend(s). Comma-separated, e.g. "bot,slack". Empty = notifications disabled.
# Supported tokens: webhook, bot, slack. Each repo opts into backends explicitly.
AGENT_NOTIFY_BACKEND="${AGENT_NOTIFY_BACKEND:-}"
AGENT_DISPATCH_REPO="${AGENT_DISPATCH_REPO:-}"

# ─── Slack Bot (Phase 3 — interactive notifications) ─────────────────────────
AGENT_SLACK_BOT_TOKEN="${AGENT_SLACK_BOT_TOKEN:-}"
AGENT_SLACK_APP_TOKEN="${AGENT_SLACK_APP_TOKEN:-}"
AGENT_SLACK_CHANNEL_ID="${AGENT_SLACK_CHANNEL_ID:-}"
AGENT_SLACK_ALLOWED_USERS="${AGENT_SLACK_ALLOWED_USERS:-}"
AGENT_SLACK_ALLOWED_GROUP="${AGENT_SLACK_ALLOWED_GROUP:-}"
AGENT_SLACK_BOT_PORT="${AGENT_SLACK_BOT_PORT:-8676}"
AGENT_NOTIFY_SLACK_WEBHOOK="${AGENT_NOTIFY_SLACK_WEBHOOK:-}"

# ─── Per-repo channel routing (Phase 4) ──────────────────────────
# Format: owner/repo=channel-or-url,owner/repo=channel-or-url
# Empty value = explicit mute for that repo.
AGENT_DISCORD_CHANNEL_MAP="${AGENT_DISCORD_CHANNEL_MAP:-}"
AGENT_SLACK_CHANNEL_MAP="${AGENT_SLACK_CHANNEL_MAP:-}"
AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="${AGENT_NOTIFY_DISCORD_WEBHOOK_MAP:-}"
AGENT_NOTIFY_SLACK_WEBHOOK_MAP="${AGENT_NOTIFY_SLACK_WEBHOOK_MAP:-}"

# ─── Paths ───────────────────────────────────────────────────────
AGENT_LOG_DIR="${AGENT_LOG_DIR:-$HOME/.claude/agent-logs}"

# Dispatch locks and last-dispatch outcome records (liveness, #94)
AGENT_LOCK_DIR="${AGENT_LOCK_DIR:-$AGENT_LOG_DIR/locks}"

# ─── Structured output schemas (#96) ─────────────────────────────
# JSON Schema per machine-consumed phase, passed as --json-schema so
# the CLI returns a guaranteed-shape object. Set a var to "" to disable
# that phase's schema, or point it at your own file (absolute, or
# relative to the config directory). Note `-` not `:-`: an explicitly
# empty value disables; only an unset var gets the shipped default.
_SPA_SCHEMAS_DIR="${SCRIPT_DIR:-.}/../schemas"
AGENT_JSON_SCHEMA_TRIAGE="${AGENT_JSON_SCHEMA_TRIAGE-${_SPA_SCHEMAS_DIR}/triage.json}"
AGENT_JSON_SCHEMA_REPLY="${AGENT_JSON_SCHEMA_REPLY-${_SPA_SCHEMAS_DIR}/reply.json}"
AGENT_JSON_SCHEMA_VALIDATE="${AGENT_JSON_SCHEMA_VALIDATE-${_SPA_SCHEMAS_DIR}/validate.json}"
AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN="${AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN-${_SPA_SCHEMAS_DIR}/adversarial-plan.json}"
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="${AGENT_JSON_SCHEMA_POST_IMPL_REVIEW-${_SPA_SCHEMAS_DIR}/post-impl-review.json}"
AGENT_JSON_SCHEMA_POST_IMPL_RETRY="${AGENT_JSON_SCHEMA_POST_IMPL_RETRY-${_SPA_SCHEMAS_DIR}/post-impl-retry.json}"
AGENT_JSON_SCHEMA_CLEANUP="${AGENT_JSON_SCHEMA_CLEANUP-${_SPA_SCHEMAS_DIR}/cleanup.json}"

# ─── Execution mode ──────────────────────────────────────────────
# actions:      invoked by a GitHub Actions workflow (default)
# orchestrator: invoked by an interactive Claude Code session; logs go
#               to stderr and the final stdout line is the result JSON
AGENT_EXECUTION_MODE="${AGENT_EXECUTION_MODE:-actions}"
