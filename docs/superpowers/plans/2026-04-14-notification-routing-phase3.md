# Notification Routing Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Slack bot into the dispatch notification system with multi-backend routing, so `AGENT_NOTIFY_BACKEND="bot,slack"` sends notifications to both Discord and Slack simultaneously.

**Architecture:** The `notify()` function in `scripts/lib/notify.sh` is updated to parse comma-separated backend values and loop over each. A shared `_notify_send_to_bot_api()` helper eliminates duplication between Discord and Slack bot senders. Each backend has independent fallback — one backend failing doesn't block others. Fully backward compatible.

**Tech Stack:** Bash, jq, curl, BATS-Core (tests)

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `scripts/lib/notify.sh` | Modify | Add Slack functions, refactor bot sender, multi-backend routing |
| `scripts/lib/defaults.sh` | Modify | Add Slack config defaults |
| `config.env.example` | Modify | Document Slack secrets |
| `config.defaults.env.example` | Modify | Document Slack backend option |
| `tests/test_notify.bats` | Modify | Add Slack and multi-backend tests |
| `docs/notifications.md` | Modify | Add Slack section |

---

### Task 1: Refactor Bot Sender and Add Slack Bot Sender

**Files:**
- Modify: `scripts/lib/notify.sh:135-165` (refactor `_notify_send_bot`, add `_notify_send_to_bot_api`, `_notify_send_slack_bot`)

- [ ] **Step 1: Run existing BATS tests to establish baseline**

Run: `./tests/bats/bin/bats tests/test_notify.bats`
Expected: All tests PASS (baseline)

- [ ] **Step 2: Refactor `_notify_send_bot` into shared helper**

Replace lines 135-165 of `scripts/lib/notify.sh` (the `_notify_send_bot` function) with:

```bash
# ─── Send to bot local HTTP API (shared) ──────────────────────────
# Usage: _notify_send_to_bot_api <port> <event_type> <title> <url> <description>
# Returns 0 on success, 1 on failure (caller should fallback)
_notify_send_to_bot_api() {
    local port="$1"
    local event_type="$2"
    local title="$3"
    local url="$4"
    local description="$5"

    local json
    json=$(jq -cn \
        --arg event_type "$event_type" \
        --arg title "$title" \
        --arg url "$url" \
        --arg description "$description" \
        --arg issue_number "${NUMBER:-0}" \
        --arg repo "${REPO:-}" \
        '{
            event_type: $event_type,
            title: $title,
            url: $url,
            description: $description,
            issue_number: ($issue_number | tonumber),
            repo: $repo
        }')

    curl -sf -o /dev/null -X POST "http://127.0.0.1:${port}/notify" \
        -H "Content-Type: application/json" \
        -d "$json" 2>/dev/null
}

# ─── Send to Discord bot ──────────────────────────────────────────
# Usage: _notify_send_bot <event_type> <title> <url> <description>
_notify_send_bot() {
    _notify_send_to_bot_api "${AGENT_DISCORD_BOT_PORT:-8675}" "$@"
}

# ─── Send to Slack bot ────────────────────────────────────────────
# Usage: _notify_send_slack_bot <event_type> <title> <url> <description>
_notify_send_slack_bot() {
    _notify_send_to_bot_api "${AGENT_SLACK_BOT_PORT:-8676}" "$@"
}
```

- [ ] **Step 3: Run existing BATS tests to verify no regression**

Run: `./tests/bats/bin/bats tests/test_notify.bats`
Expected: All tests PASS (same as baseline — `_notify_send_bot` behavior is unchanged)

- [ ] **Step 4: Run shellcheck**

Run: `shellcheck scripts/lib/notify.sh`
Expected: No warnings

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/notify.sh
git commit -m "refactor(notify): extract shared bot API sender, add Slack bot sender"
```

---

### Task 2: Add Slack Webhook Functions

**Files:**
- Modify: `scripts/lib/notify.sh` (add `_notify_build_slack_message`, `_notify_send_slack_webhook` after the Slack bot sender)

- [ ] **Step 1: Add Slack webhook functions**

Insert after `_notify_send_slack_bot` in `scripts/lib/notify.sh`:

```bash

# ─── Build Slack webhook message ──────────────────────────────────
# Usage: _notify_build_slack_message <event_type> <title> <url> <description>
# Builds a simple mrkdwn message for Slack incoming webhooks (fallback mode).
_notify_build_slack_message() {
    local event_type="$1"
    local title="$2"
    local url="$3"
    local description="$4"

    local indicator label
    indicator=$(_notify_event_indicator "$event_type")
    label=$(_notify_event_label "$event_type")

    local text="${indicator} *${label}* -- <${url}|#${NUMBER:-0}: ${title}>"
    if [ -n "$description" ]; then
        description="${description:0:2000}"
        text="${text}\n${description}"
    fi

    jq -cn --arg text "$text" '{text: $text}'
}

# ─── Send to Slack webhook ────────────────────────────────────────
# Usage: _notify_send_slack_webhook <json_payload>
_notify_send_slack_webhook() {
    local json="$1"
    local webhook_url="${AGENT_NOTIFY_SLACK_WEBHOOK}"

    curl -s -o /dev/null -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$json" 2>/dev/null || true
}
```

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck scripts/lib/notify.sh`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/notify.sh
git commit -m "feat(notify): add Slack webhook message builder and sender"
```

---

### Task 3: Update notify() for Multi-Backend Routing

**Files:**
- Modify: `scripts/lib/notify.sh:167-201` (replace the `notify` function)

- [ ] **Step 1: Replace the `notify` function**

Replace the entire `notify()` function (from the comment `# ─── Main notification function` through end of file) with:

```bash
# ─── Main notification function ────────────────────────────────────
# Usage: notify <event_type> <title> <url> [description]
# Routes to one or more backends via AGENT_NOTIFY_BACKEND (comma-separated).
# Supported backends: webhook (Discord webhook), bot (Discord bot), slack (Slack bot)
notify() {
    local event_type="${1:-}"
    local title="${2:-}"
    local url="${3:-}"
    local description="${4:-}"

    # Check notification level filter
    _notify_should_send "$event_type" || return 0

    # Parse comma-separated backends
    local backend_list="${AGENT_NOTIFY_BACKEND:-webhook}"
    local backends
    IFS=',' read -ra backends <<< "$backend_list"

    local backend
    for backend in "${backends[@]}"; do
        # Trim whitespace
        backend="${backend#"${backend%%[![:space:]]*}"}"
        backend="${backend%"${backend##*[![:space:]]}"}"

        case "$backend" in
            webhook)
                if [ -n "${AGENT_NOTIFY_DISCORD_WEBHOOK:-}" ]; then
                    local discord_json
                    discord_json=$(_notify_build_discord_embed "$event_type" "$title" "$url" "$description")
                    _notify_send_discord "$discord_json"
                fi
                ;;
            bot)
                if ! _notify_send_bot "$event_type" "$title" "$url" "$description"; then
                    if [ -n "${AGENT_NOTIFY_DISCORD_WEBHOOK:-}" ]; then
                        local discord_json
                        discord_json=$(_notify_build_discord_embed "$event_type" "$title" "$url" "$description")
                        _notify_send_discord "$discord_json"
                    fi
                fi
                ;;
            slack)
                if ! _notify_send_slack_bot "$event_type" "$title" "$url" "$description"; then
                    if [ -n "${AGENT_NOTIFY_SLACK_WEBHOOK:-}" ]; then
                        local slack_json
                        slack_json=$(_notify_build_slack_message "$event_type" "$title" "$url" "$description")
                        _notify_send_slack_webhook "$slack_json"
                    fi
                fi
                ;;
        esac
    done
}
```

Also update the file header comment (line 5) from:
```
# Currently supports Discord webhooks and Discord bot. Slack and Telegram planned.
```
to:
```
# Supports Discord webhooks, Discord bot, and Slack bot. Backends are comma-separated.
```

- [ ] **Step 2: Run existing BATS tests**

Run: `./tests/bats/bin/bats tests/test_notify.bats`
Expected: Most tests PASS. Two tests may need attention:
- `"notify: silently no-ops when AGENT_NOTIFY_DISCORD_WEBHOOK is empty"` — this test expects no curl calls when webhook is empty and backend defaults to "webhook". With the new code, the webhook case checks `AGENT_NOTIFY_DISCORD_WEBHOOK` before sending, so it should still no-op correctly.
- `"notify: silently no-ops when AGENT_NOTIFY_DISCORD_WEBHOOK is unset"` — same logic.

If any tests fail, investigate and fix. The new code should be fully backward compatible.

- [ ] **Step 3: Run shellcheck**

Run: `shellcheck scripts/lib/notify.sh`
Expected: No warnings

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/notify.sh
git commit -m "feat(notify): add multi-backend routing with Slack support"
```

---

### Task 4: Add BATS Tests for Slack and Multi-Backend

**Files:**
- Modify: `tests/test_notify.bats` (append new test sections)

- [ ] **Step 1: Add Slack and multi-backend tests**

Append to the end of `tests/test_notify.bats`:

```bash

# ===================================================================
# Phase 3: Slack bot backend routing
# ===================================================================

@test "notify: routes to Slack bot HTTP API when AGENT_NOTIFY_BACKEND=slack" {
    export AGENT_NOTIFY_BACKEND="slack"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "127.0.0.1:8676/notify"
}

@test "notify: Slack bot sends JSON with event_type and issue_number" {
    export AGENT_NOTIFY_BACKEND="slack"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "event_type"
    echo "$calls" | grep -q "issue_number"
}

@test "notify: Slack backend falls back to Slack webhook when bot curl fails" {
    export AGENT_NOTIFY_SLACK_WEBHOOK="https://hooks.slack.com/services/T00/B00/xxx"
    export AGENT_NOTIFY_BACKEND="slack"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    _source_notify

    local mock_bin="${TEST_TEMP_DIR}/bin"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_curl"
if echo "$@" | grep -q "127.0.0.1"; then
    exit 1
fi
exit 0
MOCK
    chmod +x "${mock_bin}/curl"
    export PATH="${mock_bin}:${PATH}"

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    local call_count
    call_count=$(echo "$calls" | wc -l)
    [ "$call_count" -eq 2 ]
    echo "$calls" | tail -1 | grep -q "hooks.slack.com"
}

@test "notify: Slack webhook message includes indicator and title" {
    _source_notify
    export NUMBER=42

    run _notify_build_slack_message "plan_posted" "Add caching" "https://github.com/org/repo/issues/42" "Plan here"
    assert_success

    local text
    text=$(echo "$output" | jq -r '.text')
    [[ "$text" == *"[INFO]"* ]]
    [[ "$text" == *"Plan Ready"* ]]
    [[ "$text" == *"Add caching"* ]]
}

# ===================================================================
# Phase 3: Multi-backend (comma-separated)
# ===================================================================

@test "notify: comma-separated 'bot,slack' sends to both backends" {
    export AGENT_NOTIFY_BACKEND="bot,slack"
    export AGENT_DISCORD_BOT_PORT="8675"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "127.0.0.1:8675"
    echo "$calls" | grep -q "127.0.0.1:8676"
}

@test "notify: one backend failure does not block another" {
    export AGENT_NOTIFY_BACKEND="bot,slack"
    export AGENT_DISCORD_BOT_PORT="8675"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    _source_notify

    # Mock curl: Discord bot fails, Slack bot succeeds
    local mock_bin="${TEST_TEMP_DIR}/bin"
    mkdir -p "$mock_bin"
    cat > "${mock_bin}/curl" << 'MOCK'
#!/bin/bash
echo "$@" >> "${TEST_TEMP_DIR}/mock_calls_curl"
if echo "$@" | grep -q "8675"; then
    exit 1
fi
exit 0
MOCK
    chmod +x "${mock_bin}/curl"
    export PATH="${mock_bin}:${PATH}"

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    # Discord bot tried and failed (port 8675), Slack bot tried and succeeded (port 8676)
    echo "$calls" | grep -q "8675"
    echo "$calls" | grep -q "8676"
}

@test "notify: 'webhook,slack' sends Discord webhook and Slack bot" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_BACKEND="webhook,slack"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "discord.com/api/webhooks"
    echo "$calls" | grep -q "127.0.0.1:8676"
}

@test "notify: spaces in comma-separated backends are trimmed" {
    export AGENT_NOTIFY_BACKEND="bot , slack"
    export AGENT_DISCORD_BOT_PORT="8675"
    export AGENT_SLACK_BOT_PORT="8676"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "127.0.0.1:8675"
    echo "$calls" | grep -q "127.0.0.1:8676"
}

# ===================================================================
# Phase 3: Slack configuration defaults
# ===================================================================

@test "defaults: AGENT_SLACK_BOT_PORT defaults to 8676" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_SLACK_BOT_PORT

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_SLACK_BOT_PORT" "8676"
}

@test "defaults: AGENT_NOTIFY_SLACK_WEBHOOK defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_NOTIFY_SLACK_WEBHOOK

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_SLACK_WEBHOOK" ""
}
```

- [ ] **Step 2: Run ALL BATS tests**

Run: `./tests/bats/bin/bats tests/test_notify.bats`
Expected: All tests PASS (old + new). The two new defaults tests will FAIL until Task 5 is done.

Note: If the defaults tests fail, that's expected — they depend on Task 5 (defaults.sh changes). Skip them for now and re-run after Task 5.

- [ ] **Step 3: Commit**

```bash
git add tests/test_notify.bats
git commit -m "test(notify): add Slack and multi-backend routing tests"
```

---

### Task 5: Update Config Defaults, Examples, and Documentation

**Files:**
- Modify: `scripts/lib/defaults.sh:103-111`
- Modify: `config.env.example`
- Modify: `config.defaults.env.example`
- Modify: `docs/notifications.md`

- [ ] **Step 1: Add Slack defaults to defaults.sh**

After the existing Discord Bot section (line 111), insert:

```bash

# ─── Slack Bot (Phase 3 — interactive notifications) ─────────────
AGENT_SLACK_BOT_TOKEN="${AGENT_SLACK_BOT_TOKEN:-}"
AGENT_SLACK_APP_TOKEN="${AGENT_SLACK_APP_TOKEN:-}"
AGENT_SLACK_CHANNEL_ID="${AGENT_SLACK_CHANNEL_ID:-}"
AGENT_SLACK_ALLOWED_USERS="${AGENT_SLACK_ALLOWED_USERS:-}"
AGENT_SLACK_ALLOWED_GROUP="${AGENT_SLACK_ALLOWED_GROUP:-}"
AGENT_SLACK_BOT_PORT="${AGENT_SLACK_BOT_PORT:-8676}"
AGENT_NOTIFY_SLACK_WEBHOOK="${AGENT_NOTIFY_SLACK_WEBHOOK:-}"
```

- [ ] **Step 2: Update config.defaults.env.example**

Replace the `AGENT_NOTIFY_BACKEND` comment (line 92-93) with:

```bash
# Backend: "webhook" (default), "bot" (Discord bot), "slack" (Slack bot)
# Comma-separated for multiple: "bot,slack" sends to both
# AGENT_NOTIFY_BACKEND="webhook"
```

- [ ] **Step 3: Add Slack section to config.env.example**

After the Discord Bot section (after line 38), insert:

```bash

# ── Slack Bot (interactive notifications) ────────────────────────
# Requires a Slack app with Socket Mode. See slack-bot/README.md for setup.

# Slack bot token (from Slack App > OAuth & Permissions > Bot User OAuth Token)
# AGENT_SLACK_BOT_TOKEN=""

# Slack app-level token for Socket Mode (from Slack App > Basic Info > App-Level Tokens)
# AGENT_SLACK_APP_TOKEN=""

# Slack channel ID for notifications
# AGENT_SLACK_CHANNEL_ID=""

# Comma-separated Slack user IDs allowed to click action buttons
# AGENT_SLACK_ALLOWED_USERS=""

# Local HTTP port for dispatch -> Slack bot communication (default: 8676)
# AGENT_SLACK_BOT_PORT="8676"

# Slack webhook URL (fallback when Slack bot is unreachable)
# AGENT_NOTIFY_SLACK_WEBHOOK=""
```

- [ ] **Step 4: Add Slack section to docs/notifications.md**

Append before the final `## Security` section (or at the end of the file):

```markdown

## Phase 3: Slack Bot

The Slack bot provides the same interactive experience as the Discord bot but in Slack — buttons, slash commands, and modals for managing agent work.

### Setup

1. Create a Slack app with Socket Mode — see `slack-bot/README.md` for detailed steps
2. Add the Slack configuration to your `config.env`:

   ```bash
   AGENT_SLACK_BOT_TOKEN="xoxb-your-bot-token"
   AGENT_SLACK_APP_TOKEN="xapp-your-app-token"
   AGENT_SLACK_CHANNEL_ID="C0123456789"
   AGENT_SLACK_ALLOWED_USERS="U0123456789"
   AGENT_NOTIFY_BACKEND="slack"
   ```

3. Install and start the bot:

   ```bash
   cd slack-bot && ./install.sh
   systemctl --user start agent-dispatch-slack
   ```

### Dual-Channel Mode

To send notifications to both Discord and Slack simultaneously, use a comma-separated backend list:

```bash
AGENT_NOTIFY_BACKEND="bot,slack"
```

Each backend operates independently — if one bot is down, the other still receives notifications. Per-backend fallback is preserved:

- Discord bot unreachable → falls back to Discord webhook (if configured)
- Slack bot unreachable → falls back to Slack webhook (if configured)

### Available Backends

| Backend | Description | Fallback |
|---|---|---|
| `webhook` | Discord webhook (Phase 1, no interactivity) | None |
| `bot` | Discord bot (interactive buttons and slash commands) | Discord webhook |
| `slack` | Slack bot (interactive buttons and slash commands) | Slack webhook |

### Examples

```bash
# Discord webhook only (Phase 1 default)
AGENT_NOTIFY_BACKEND="webhook"

# Discord bot only
AGENT_NOTIFY_BACKEND="bot"

# Slack bot only
AGENT_NOTIFY_BACKEND="slack"

# Both bots (dual-channel)
AGENT_NOTIFY_BACKEND="bot,slack"

# Discord webhook + Slack bot
AGENT_NOTIFY_BACKEND="webhook,slack"
```
```

- [ ] **Step 5: Run ALL BATS tests (including new defaults tests)**

Run: `./tests/bats/bin/bats tests/test_notify.bats`
Expected: All tests PASS

- [ ] **Step 6: Run shellcheck on all modified scripts**

Run: `shellcheck scripts/lib/notify.sh scripts/lib/defaults.sh`
Expected: No warnings

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/defaults.sh config.env.example config.defaults.env.example docs/notifications.md
git commit -m "feat(notify): add Slack config defaults, examples, and documentation"
```

---

## Design Notes

**Backward compatibility:** All existing configurations work unchanged. `AGENT_NOTIFY_BACKEND="webhook"` and `AGENT_NOTIFY_BACKEND="bot"` behave identically to before. The only new behaviors are triggered by new values (`slack`, comma-separated lists).

**DRY refactor:** `_notify_send_to_bot_api()` eliminates the duplicate JSON-building and curl logic between Discord and Slack bot senders. Both `_notify_send_bot` and `_notify_send_slack_bot` are thin wrappers that pass the appropriate port.

**Independent fallback:** Each backend in the comma-separated list is processed independently. A Discord bot failure triggers Discord webhook fallback but does not affect Slack delivery. A Slack bot failure triggers Slack webhook fallback but does not affect Discord delivery.

**Whitespace trimming:** `AGENT_NOTIFY_BACKEND="bot , slack"` works correctly — POSIX-compatible whitespace trimming via parameter expansion (no `xargs` dependency).
