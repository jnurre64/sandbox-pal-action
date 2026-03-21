#!/bin/bash
# ─── Default configuration values ────────────────────────────────
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

# Pre-test setup command (optional — runs before test command, e.g., npm install, godot --headless --import)
AGENT_TEST_SETUP_COMMAND="${AGENT_TEST_SETUP_COMMAND:-}"

# Pre-PR test command (optional — if unset, test gate is skipped)
AGENT_TEST_COMMAND="${AGENT_TEST_COMMAND:-}"

# Claude effort level for all agent runs
AGENT_EFFORT_LEVEL="${AGENT_EFFORT_LEVEL:-high}"

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

# ─── Label-to-tool mapping ────────────────────────────────────────
# Map issue labels to extra tools that get added when the label is present.
# Format: AGENT_LABEL_TOOLS_<sanitized_label>="tool1,tool2"
# Label names are sanitized: colons become underscores, hyphens become underscores.
# Example: for label "agent:image-gen", set:
#   AGENT_LABEL_TOOLS_agent_image_gen="Bash(curl *localhost:8188*),Bash(python3:*)"
# These tools are appended to the implementation toolset when the label is detected.

# ─── Paths ───────────────────────────────────────────────────────
AGENT_LOG_DIR="${AGENT_LOG_DIR:-$HOME/.claude/agent-logs}"
