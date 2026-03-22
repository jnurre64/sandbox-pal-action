# Dispatch Notify Phase 1: Webhook Notification Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional Discord webhook notifications at dispatch milestones so users can monitor agent activity without watching GitHub.

**Architecture:** A new `scripts/lib/notify.sh` module provides a `notify()` function that formats Discord embeds and sends them via `curl`. It's sourced from `agent-dispatch.sh` and called at each milestone in `agent-dispatch.sh` and `common.sh`. The feature is entirely optional — disabled by default, activated by setting `AGENT_NOTIFY_DISCORD_WEBHOOK` in `config.env`.

**Tech Stack:** Bash, curl, jq (already dependencies), Discord Webhook API, BATS-Core for tests.

**Spec:** `docs/superpowers/specs/2026-03-22-dispatch-notify-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `scripts/lib/notify.sh` | Create | Core notification module: `notify()`, level filtering, embed formatting, Discord send |
| `scripts/lib/defaults.sh` | Modify (lines 58-60, append before Paths section) | Add default values for notification config vars |
| `config.env.example` | Modify (append new section) | Document notification config vars with examples |
| `scripts/agent-dispatch.sh` | Modify (add source line after line 59, add `notify()` calls at milestones) | Source `notify.sh` module and add milestone notifications |
| `tests/test_notify.bats` | Create | BATS tests for notify module |
| `tests/helpers/test_helper.bash` | Modify (append new defaults) | Add notification config defaults for test environment |
| `docs/notifications.md` | Create | Setup guide for Discord notifications |
| `docs/future-channels.md` | Create | Phase 3 roadmap documentation |

---

### Task 1: Create the notify module with level filtering

**Files:**
- Create: `scripts/lib/notify.sh`
- Test: `tests/test_notify.bats`

- [ ] **Step 1: Write the test file skeleton and first test — notify no-ops when unconfigured**

Create `tests/test_notify.bats`:

```bash
#!/usr/bin/env bats
# Tests for scripts/lib/notify.sh

load 'helpers/test_helper'

_source_notify() {
    source "${LIB_DIR}/notify.sh"
}

# ===================================================================
# No-op behavior when unconfigured
# ===================================================================

@test "notify: silently no-ops when AGENT_NOTIFY_DISCORD_WEBHOOK is empty" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK=""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success
    assert_output ""
}

@test "notify: silently no-ops when AGENT_NOTIFY_DISCORD_WEBHOOK is unset" {
    unset AGENT_NOTIFY_DISCORD_WEBHOOK
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success
    assert_output ""
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: FAIL — `notify.sh` does not exist

- [ ] **Step 3: Create `scripts/lib/notify.sh` with the notify function skeleton**

```bash
#!/bin/bash
# ─── Discord notification layer (optional) ─────────────────────────
# Sends Discord webhook notifications at dispatch milestones.
# Silently no-ops if AGENT_NOTIFY_DISCORD_WEBHOOK is not configured.

# ─── Notification level check ──────────────────────────────────────
# Returns 0 (true) if the event should be sent at the current level.
_notify_should_send() {
    local event_type="$1"
    local level="${AGENT_NOTIFY_LEVEL:-actionable}"

    case "$level" in
        all)
            return 0
            ;;
        actionable)
            case "$event_type" in
                plan_posted|questions_asked|pr_created|review_feedback|agent_failed)
                    return 0 ;;
                *)
                    return 1 ;;
            esac
            ;;
        failures)
            case "$event_type" in
                tests_failed|agent_failed)
                    return 0 ;;
                *)
                    return 1 ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
}

# ─── Main notification function ────────────────────────────────────
# Usage: notify <event_type> <title> <url> [description]
#
# Event types: plan_posted, questions_asked, implement_started,
#              tests_passed, tests_failed, pr_created,
#              review_feedback, agent_failed
notify() {
    local event_type="${1:-}"
    local title="${2:-}"
    local url="${3:-}"
    local description="${4:-}"

    # No-op if webhook not configured
    [ -z "${AGENT_NOTIFY_DISCORD_WEBHOOK:-}" ] && return 0

    # Check notification level filter
    _notify_should_send "$event_type" || return 0

    local json
    json=$(_notify_build_embed "$event_type" "$title" "$url" "$description")

    _notify_send "$json"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: PASS (both no-op tests)

- [ ] **Step 5: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/lib/notify.sh tests/test_notify.bats
git commit -m "feat(notify): add notify module skeleton with no-op behavior"
```

---

### Task 2: Add notification level filtering tests

**Files:**
- Modify: `tests/test_notify.bats`
- Modify: `scripts/lib/notify.sh`

- [ ] **Step 1: Write level filtering tests**

Append to `tests/test_notify.bats`:

```bash
# ===================================================================
# Notification level filtering
# ===================================================================

@test "notify level 'actionable': sends plan_posted" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/test/token"
    export AGENT_NOTIFY_LEVEL="actionable"
    _source_notify

    run _notify_should_send "plan_posted"
    assert_success
}

@test "notify level 'actionable': skips implement_started" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/test/token"
    export AGENT_NOTIFY_LEVEL="actionable"
    _source_notify

    run _notify_should_send "implement_started"
    assert_failure
}

@test "notify level 'actionable': skips tests_passed" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/test/token"
    export AGENT_NOTIFY_LEVEL="actionable"
    _source_notify

    run _notify_should_send "tests_passed"
    assert_failure
}

@test "notify level 'actionable': sends agent_failed" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/test/token"
    export AGENT_NOTIFY_LEVEL="actionable"
    _source_notify

    run _notify_should_send "agent_failed"
    assert_success
}

@test "notify level 'failures': sends tests_failed" {
    export AGENT_NOTIFY_LEVEL="failures"
    _source_notify

    run _notify_should_send "tests_failed"
    assert_success
}

@test "notify level 'failures': sends agent_failed" {
    export AGENT_NOTIFY_LEVEL="failures"
    _source_notify

    run _notify_should_send "agent_failed"
    assert_success
}

@test "notify level 'failures': skips plan_posted" {
    export AGENT_NOTIFY_LEVEL="failures"
    _source_notify

    run _notify_should_send "plan_posted"
    assert_failure
}

@test "notify level 'failures': skips pr_created" {
    export AGENT_NOTIFY_LEVEL="failures"
    _source_notify

    run _notify_should_send "pr_created"
    assert_failure
}

@test "notify level 'all': sends implement_started" {
    export AGENT_NOTIFY_LEVEL="all"
    _source_notify

    run _notify_should_send "implement_started"
    assert_success
}

@test "notify level 'all': sends tests_passed" {
    export AGENT_NOTIFY_LEVEL="all"
    _source_notify

    run _notify_should_send "tests_passed"
    assert_success
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: PASS (all 12 tests)

- [ ] **Step 3: Commit**

```bash
cd ~/claude-agent-dispatch
git add tests/test_notify.bats
git commit -m "test(notify): add notification level filtering tests"
```

---

### Task 3: Build the Discord embed formatter

**Files:**
- Modify: `scripts/lib/notify.sh`
- Modify: `tests/test_notify.bats`

- [ ] **Step 1: Write tests for embed JSON structure**

Append to `tests/test_notify.bats`:

```bash
# ===================================================================
# Embed formatting
# ===================================================================

@test "notify embed: plan_posted has blue color (3447003) and correct title" {
    _source_notify

    run _notify_build_embed "plan_posted" "Add sprite caching" "https://github.com/org/repo/issues/42" "Plan summary here"
    assert_success

    local color title
    color=$(echo "$output" | jq -r '.embeds[0].color')
    title=$(echo "$output" | jq -r '.embeds[0].title')
    assert_equal "$color" "3447003"
    assert_equal "$title" "[INFO] Plan Ready -- #99: Add sprite caching"
}

@test "notify embed: tests_failed has red color (15548997)" {
    _source_notify

    run _notify_build_embed "tests_failed" "Fix login bug" "https://github.com/org/repo/issues/5" "npm test exited 1"
    assert_success

    local color
    color=$(echo "$output" | jq -r '.embeds[0].color')
    assert_equal "$color" "15548997"
}

@test "notify embed: pr_created has green color (5763719)" {
    _source_notify

    run _notify_build_embed "pr_created" "Add feature X" "https://github.com/org/repo/pull/87" "3 commits"
    assert_success

    local color
    color=$(echo "$output" | jq -r '.embeds[0].color')
    assert_equal "$color" "5763719"
}

@test "notify embed: review_feedback has yellow color (16776960)" {
    _source_notify

    run _notify_build_embed "review_feedback" "PR #87" "https://github.com/org/repo/pull/87" "Changes requested"
    assert_success

    local color
    color=$(echo "$output" | jq -r '.embeds[0].color')
    assert_equal "$color" "16776960"
}

@test "notify embed: includes footer with automation disclosure" {
    _source_notify

    run _notify_build_embed "plan_posted" "Issue title" "https://example.com" "desc"
    assert_success

    local footer
    footer=$(echo "$output" | jq -r '.embeds[0].footer.text')
    assert_output --partial "Automated by claude-agent-dispatch"
}

@test "notify embed: includes issue URL in field" {
    _source_notify

    run _notify_build_embed "plan_posted" "Issue title" "https://github.com/org/repo/issues/42" "desc"
    assert_success

    # URL should appear somewhere in the embed
    echo "$output" | jq -e '.embeds[0]' | grep -q "https://github.com/org/repo/issues/42"
}

@test "notify embed: truncates description longer than 4000 chars" {
    _source_notify

    local long_desc
    long_desc=$(printf 'x%.0s' {1..5000})

    run _notify_build_embed "plan_posted" "Issue title" "https://example.com" "$long_desc"
    assert_success

    local desc_len
    desc_len=$(echo "$output" | jq -r '.embeds[0].description' | wc -c)
    [ "$desc_len" -le 4010 ]
}

@test "notify embed: uses webhook username 'Agent Dispatch'" {
    _source_notify

    run _notify_build_embed "plan_posted" "Issue title" "https://example.com" "desc"
    assert_success

    local username
    username=$(echo "$output" | jq -r '.username')
    assert_equal "$username" "Agent Dispatch"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: FAIL — `_notify_build_embed` not implemented

- [ ] **Step 3: Implement `_notify_build_embed` in `scripts/lib/notify.sh`**

Add before the `notify()` function:

```bash
# ─── Event metadata ────────────────────────────────────────────────
_notify_event_color() {
    case "$1" in
        pr_created|tests_passed)    echo "5763719"  ;;  # green
        tests_failed|agent_failed)  echo "15548997" ;;  # red
        plan_posted|questions_asked) echo "3447003" ;;  # blue
        review_feedback)            echo "16776960" ;;  # yellow
        *)                          echo "9807270"  ;;  # grey
    esac
}

_notify_event_label() {
    case "$1" in
        plan_posted)        echo "Plan Ready"           ;;
        questions_asked)    echo "Questions"             ;;
        implement_started)  echo "Implementation Started" ;;
        tests_passed)       echo "Tests Passed"          ;;
        tests_failed)       echo "Tests Failed"          ;;
        pr_created)         echo "PR Created"            ;;
        review_feedback)    echo "Review Feedback"       ;;
        agent_failed)       echo "Agent Failed"          ;;
        *)                  echo "Agent Update"          ;;
    esac
}

_notify_event_indicator() {
    case "$1" in
        pr_created|tests_passed)    echo "[OK]"  ;;
        tests_failed|agent_failed)  echo "[FAIL]" ;;
        plan_posted|questions_asked) echo "[INFO]" ;;
        review_feedback)            echo "[ACTION]" ;;
        implement_started)          echo "[INFO]" ;;
        *)                          echo "[INFO]" ;;
    esac
}

# ─── Build Discord embed JSON ──────────────────────────────────────
# Usage: _notify_build_embed <event_type> <title> <url> <description>
_notify_build_embed() {
    local event_type="$1"
    local title="$2"
    local url="$3"
    local description="$4"

    local color label indicator
    color=$(_notify_event_color "$event_type")
    label=$(_notify_event_label "$event_type")
    indicator=$(_notify_event_indicator "$event_type")

    # Truncate description to fit Discord embed limit (4096 chars, leave room for indicator)
    if [ "${#description}" -gt 4000 ]; then
        description="${description:0:3997}..."
    fi

    local embed_title="${indicator} ${label} -- #${NUMBER}: ${title}"

    # Build JSON with jq for proper escaping
    jq -n \
        --arg username "Agent Dispatch" \
        --arg title "$embed_title" \
        --arg url "$url" \
        --arg description "$description" \
        --argjson color "$color" \
        --arg footer "Automated by claude-agent-dispatch | ${REPO:-unknown} #${NUMBER:-0}" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                url: $url,
                description: $description,
                color: $color,
                footer: { text: $footer },
                timestamp: $timestamp
            }]
        }'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: PASS (all 20 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/lib/notify.sh tests/test_notify.bats
git commit -m "feat(notify): implement Discord embed formatter with color-coded events"
```

---

### Task 4: Implement the Discord webhook sender

**Files:**
- Modify: `scripts/lib/notify.sh`
- Modify: `tests/test_notify.bats`

- [ ] **Step 1: Write tests for the send function (mock curl)**

Append to `tests/test_notify.bats`:

```bash
# ===================================================================
# Sending via webhook
# ===================================================================

@test "notify send: calls curl with correct webhook URL" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "https://discord.com/api/webhooks/123/abc"
}

@test "notify send: includes Content-Type header" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "application/json"
}

@test "notify send: includes thread_id when configured" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_DISCORD_THREAD_ID="987654321"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "thread_id=987654321"
}

@test "notify send: does not include thread_id when not configured" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_DISCORD_THREAD_ID=""
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    # Should not have thread_id query param
    ! echo "$calls" | grep -q "thread_id"
}

@test "notify send: does not fail when curl fails" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" "error" 1
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success
}

@test "notify: skipped events do not call curl" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_LEVEL="failures"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: FAIL — `_notify_send` not implemented

- [ ] **Step 3: Implement `_notify_send` in `scripts/lib/notify.sh`**

Add after `_notify_build_embed`:

```bash
# ─── Send to Discord webhook ──────────────────────────────────────
# Usage: _notify_send <json_payload>
_notify_send() {
    local json="$1"
    local webhook_url="${AGENT_NOTIFY_DISCORD_WEBHOOK}"

    # Append thread_id query parameter if configured
    if [ -n "${AGENT_NOTIFY_DISCORD_THREAD_ID:-}" ]; then
        webhook_url="${webhook_url}?thread_id=${AGENT_NOTIFY_DISCORD_THREAD_ID}"
    fi

    curl -s -o /dev/null -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$json" 2>/dev/null || true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: PASS (all 26 tests)

- [ ] **Step 5: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/lib/notify.sh tests/test_notify.bats
git commit -m "feat(notify): implement Discord webhook sender with thread support"
```

---

### Task 5: Add config defaults and update config.env.example

**Files:**
- Modify: `scripts/lib/defaults.sh` (append before Paths section)
- Modify: `config.env.example` (append new section)
- Modify: `tests/helpers/test_helper.bash` (add new defaults)

- [ ] **Step 1: Write a test for defaults**

Append to `tests/test_notify.bats`:

```bash
# ===================================================================
# Configuration defaults
# ===================================================================

@test "defaults: AGENT_NOTIFY_LEVEL defaults to 'actionable'" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_NOTIFY_LEVEL

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_LEVEL" "actionable"
}

@test "defaults: AGENT_NOTIFY_DISCORD_WEBHOOK defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_NOTIFY_DISCORD_WEBHOOK

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_DISCORD_WEBHOOK" ""
}

@test "defaults: config.env overrides notification defaults" {
    cat > "${MOCK_CONFIG_DIR}/config.env" << 'EOF'
AGENT_BOT_USER="custom-bot"
AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
AGENT_NOTIFY_LEVEL="all"
EOF

    source "${MOCK_CONFIG_DIR}/config.env"
    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_DISCORD_WEBHOOK" "https://discord.com/api/webhooks/123/abc"
    assert_equal "$AGENT_NOTIFY_LEVEL" "all"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats`
Expected: FAIL — vars not defined in defaults.sh

- [ ] **Step 3: Add defaults to `scripts/lib/defaults.sh`**

Insert before the `# ─── Paths` section (before line 59):

```bash
# ─── Notifications (optional — disabled by default) ─────────────────
# Discord webhook URL for dispatch milestone notifications
AGENT_NOTIFY_DISCORD_WEBHOOK="${AGENT_NOTIFY_DISCORD_WEBHOOK:-}"

# Optional: post notifications to a specific Discord thread
AGENT_NOTIFY_DISCORD_THREAD_ID="${AGENT_NOTIFY_DISCORD_THREAD_ID:-}"

# Notification level: "all", "actionable" (default), "failures"
AGENT_NOTIFY_LEVEL="${AGENT_NOTIFY_LEVEL:-actionable}"
```

- [ ] **Step 4: Add defaults to `tests/helpers/test_helper.bash`**

Append after line 46 (`export AGENT_DISALLOWED_TOOLS="mcp__github__*"`):

```bash
    export AGENT_NOTIFY_DISCORD_WEBHOOK=""
    export AGENT_NOTIFY_DISCORD_THREAD_ID=""
    export AGENT_NOTIFY_LEVEL="actionable"
```

- [ ] **Step 5: Append notification section to `config.env.example`**

Append after the Custom Prompts section:

```bash
# ── Notifications (optional, disabled by default) ────────────────
# Discord webhook URL — set to enable agent milestone notifications
# Create one: Server Settings > Integrations > Webhooks > New Webhook
# AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/ID/TOKEN"

# Optional: post notifications to a specific Discord thread
# AGENT_NOTIFY_DISCORD_THREAD_ID=""

# Notification level: "all" (every milestone), "actionable" (default, events
# needing user response), "failures" (only failures)
# AGENT_NOTIFY_LEVEL="actionable"
```

- [ ] **Step 6: Run all tests to verify they pass**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/test_notify.bats tests/test_defaults.bats`
Expected: PASS (all tests including existing defaults tests)

- [ ] **Step 7: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/lib/defaults.sh config.env.example tests/test_notify.bats tests/helpers/test_helper.bash
git commit -m "feat(notify): add notification config defaults and config.env documentation"
```

---

### Task 6: Source notify.sh from agent-dispatch.sh

**Files:**
- Modify: `scripts/agent-dispatch.sh` (add source line in the library sourcing block)

- [ ] **Step 1: Verify existing tests still pass before modifying**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/`
Expected: PASS (all existing tests)

- [ ] **Step 2: Add source line to `scripts/agent-dispatch.sh`**

All library modules are sourced in `agent-dispatch.sh` (lines 53-59). Add the notify source after the last existing source line (line 59, `source "${SCRIPT_DIR}/lib/data-fetch.sh"`):

```bash
# shellcheck source=lib/notify.sh
source "${SCRIPT_DIR}/lib/notify.sh"
```

This follows the same pattern as the other `source` lines in that block. The `notify()` function will be available to all handlers in both `agent-dispatch.sh` and `common.sh` since they're sourced before the handlers run.

- [ ] **Step 3: Run all tests to verify nothing broke**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/`
Expected: PASS (all tests)

- [ ] **Step 4: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/agent-dispatch.sh
git commit -m "feat(notify): source notify.sh in dispatch entry point"
```

---

### Task 7: Add notify calls at each milestone in agent-dispatch.sh

**Files:**
- Modify: `scripts/agent-dispatch.sh` (6 insertion points)

This task adds `notify` calls at each milestone. All calls are fire-and-forget (the function handles level filtering and no-ops internally).

- [ ] **Step 1: Add notify call for "questions_asked" event**

In `handle_new_issue()`, after line 117 (`set_label "agent:needs-info"`), add:

```bash
        notify "questions_asked" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "$questions"
```

- [ ] **Step 2: Add notify call for "plan_posted" event**

In `handle_new_issue()`, after line 134 (`set_label "agent:plan-review"`), add:

```bash
            notify "plan_posted" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "${plan_content:0:1000}"
```

- [ ] **Step 3: Add notify call for "agent_failed" in handle_new_issue (plan file missing)**

After line 138 (`set_label "agent:failed"` in the plan_ready else branch), add:

```bash
            notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Plan file not found"
```

- [ ] **Step 4: Add notify call for "agent_failed" in handle_new_issue (parse failure)**

After line 147 (`set_label "agent:failed"` in the else branch), add:

```bash
        notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Could not parse triage response"
```

- [ ] **Step 5: Add notify call for "implement_started" event**

In `handle_implement()`, after line 237 (`set_label "agent:in-progress"`), add:

```bash
    notify "implement_started" "$(gh issue view "$NUMBER" --repo "$REPO" --json title --jq '.title' 2>/dev/null || echo "Issue #$NUMBER")" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation starting"
```

Actually, the issue title isn't fetched yet at line 237. It's fetched later at line 260. So instead, add the notify call after line 260 (`issue_title=$(echo "$issue_json" | jq -r '.title')`):

```bash
    notify "implement_started" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation starting"
```

- [ ] **Step 6: Add notify call for "review_feedback" event**

In `handle_pr_review()`, after line 322 (`log "Addressing PR review feedback..."`), add:

```bash
    notify "review_feedback" "PR #${pr_number}" "https://github.com/${REPO}/pull/${pr_number}" "Review feedback received"
```

Wait — `pr_number` is already set at line 321 but `pr_title` isn't fetched until line 331. Move the notify call to after `pr_title` is set (line 331):

```bash
    notify "review_feedback" "$pr_title" "https://github.com/${REPO}/pull/${pr_number}" "Review feedback received, addressing changes"
```

- [ ] **Step 7: Run shellcheck on modified files**

Run: `cd ~/claude-agent-dispatch && shellcheck scripts/agent-dispatch.sh scripts/lib/notify.sh`
Expected: No warnings

- [ ] **Step 8: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/agent-dispatch.sh
git commit -m "feat(notify): add notify calls at dispatch milestones in agent-dispatch.sh"
```

---

### Task 8: Add notify calls in common.sh (handle_post_implementation)

**Files:**
- Modify: `scripts/lib/common.sh` (5 insertion points in `handle_post_implementation`)

- [ ] **Step 1: Add notify call for "tests_passed" event**

In `handle_post_implementation()`, after the test gate succeeds (after the closing `fi` of the test failure block at line 224), before `log "Pushing $commit_count commit(s)..."` at line 226, add:

```bash
            notify "tests_passed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR tests passed ($commit_count commits)"
```

- [ ] **Step 2: Add notify call for "tests_failed" event**

In `handle_post_implementation()`, after line 221 (`set_label "agent:failed"` inside the test failure branch), add:

```bash
                notify "tests_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR test gate failed (exit code $test_exit)"
```

- [ ] **Step 3: Add notify call for "pr_created" event**

After line 246 (`log "PR created: $pr_url"`), add:

```bash
            notify "pr_created" "$issue_title" "$pr_url" "PR created with $commit_count commit(s)"
```

- [ ] **Step 4: Add notify call for "agent_failed" on PR creation failure**

After line 250 (`set_label "agent:failed"` in the PR creation failure branch), add:

```bash
            notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Implementation complete but PR creation failed"
```

- [ ] **Step 5: Add notify call for "agent_failed" on no commits**

After line 256 (`set_label "agent:failed"` in the no-commits branch), add:

```bash
        notify "agent_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "No commits made during implementation"
```

- [ ] **Step 6: Run shellcheck**

Run: `cd ~/claude-agent-dispatch && shellcheck scripts/lib/common.sh`
Expected: No warnings

- [ ] **Step 7: Run all tests**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/`
Expected: PASS (all tests)

- [ ] **Step 8: Commit**

```bash
cd ~/claude-agent-dispatch
git add scripts/lib/common.sh
git commit -m "feat(notify): add notify calls at post-implementation milestones"
```

---

### Task 9: Run full test suite and ShellCheck

**Files:** None (validation only)

- [ ] **Step 1: Run ShellCheck on all scripts**

Run: `cd ~/claude-agent-dispatch && shellcheck scripts/*.sh scripts/lib/*.sh`
Expected: No warnings

- [ ] **Step 2: Run the full BATS test suite**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/`
Expected: PASS (all tests, including new notify tests)

- [ ] **Step 3: Verify notify.sh has the shebang and set flags**

Read `scripts/lib/notify.sh` and confirm it starts with `#!/bin/bash` and does not have `set -euo pipefail` (since it's sourced, not executed directly — the parent script's flags apply).

---

### Task 10: Write documentation

**Files:**
- Create: `docs/notifications.md`
- Create: `docs/future-channels.md`

- [ ] **Step 1: Create `docs/notifications.md`**

```markdown
# Discord Notifications

Optional Discord notifications for agent dispatch milestones. When configured, the dispatch system sends rich embed messages to a Discord channel at key events.

## Quick Start

1. Create a Discord webhook: Server Settings > Integrations > Webhooks > New Webhook
2. Copy the webhook URL
3. Add to your `config.env`:

   ```bash
   AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN"
   ```

4. (Optional) Set the notification level:

   ```bash
   # "all" — every milestone
   # "actionable" — events needing user response (default)
   # "failures" — only failures
   AGENT_NOTIFY_LEVEL="actionable"
   ```

5. (Optional) Post to a specific thread:

   ```bash
   AGENT_NOTIFY_DISCORD_THREAD_ID="123456789"
   ```

## Events

| Event | Level | When |
|---|---|---|
| Plan Ready | `actionable` | Agent has triaged an issue and posted a plan |
| Questions | `actionable` | Agent needs clarification before planning |
| Implementation Started | `all` | Agent begins implementing an approved plan |
| Tests Passed | `all` | Pre-PR test gate passed |
| Tests Failed | `failures` | Pre-PR test gate failed |
| PR Created | `actionable` | Agent created a pull request |
| Review Feedback | `actionable` | Agent is addressing PR review comments |
| Agent Failed | `failures` | Agent encountered an error |

## Notification Levels

- **`all`** — Every event above is sent
- **`actionable`** (default) — Only events that may need your attention
- **`failures`** — Only `tests_failed` and `agent_failed`

## Security

- The webhook URL is stored in `config.env` which is not committed to git
- Notifications are sent via HTTPS to Discord's API
- No user data is collected or stored
- All notifications include an "Automated by claude-agent-dispatch" footer

## Phase 2: Interactive Bot

A future phase will add a Discord bot with interactive buttons (Approve, Request Changes, Comment) and slash commands, enabling two-way interaction from Discord. See the design spec for details.
```

- [ ] **Step 2: Create `docs/future-channels.md`**

```markdown
# Future: Channel-Based Architecture

This document tracks the planned evolution from webhook notifications and Discord bot interactions to a Claude Code Channel-based architecture.

## Current Status

**Not planned for implementation.** This is a roadmap item contingent on upstream changes from Anthropic.

## Trigger to Revisit

Any of these changes from Anthropic would make this viable:

- Claude Code Channels work with `claude -p` (headless mode)
- Channels support API key or subscription-based auth (not just claude.ai login)
- A stable (non-research-preview) release of Channels with a settled API contract

## What It Would Look Like

A custom webhook channel (MCP server) receives GitHub events and dispatch notifications. Claude in a persistent session acts as a coordinator — it receives events, reasons about them, and communicates via Discord and/or Telegram. Implementation still happens via `claude -p` dispatch.

## What It Would Enable

- Natural conversation with the agent from Discord/Telegram
- Proactive context surfacing across issues
- Multi-platform support from a single session

## Preparation

Phases 1 and 2 are designed to make this transition smooth:

- The `notify()` interface is generic (structured data, not Discord-specific)
- GitHub labels and comments remain the source of truth for dispatch state
- No Discord-only state is introduced

## References

- [Claude Code Channels documentation](https://code.claude.com/docs/en/channels)
- [Channels reference (building custom channels)](https://code.claude.com/docs/en/channels-reference)
- Design spec: `docs/superpowers/specs/2026-03-22-dispatch-notify-design.md`
```

- [ ] **Step 3: Commit**

```bash
cd ~/claude-agent-dispatch
git add docs/notifications.md docs/future-channels.md
git commit -m "docs: add notification setup guide and future channels roadmap"
```

---

### Task 11: Final integration verification

**Files:** None (validation only)

- [ ] **Step 1: Run full ShellCheck**

Run: `cd ~/claude-agent-dispatch && shellcheck scripts/*.sh scripts/lib/*.sh`
Expected: No warnings

- [ ] **Step 2: Run full BATS suite**

Run: `cd ~/claude-agent-dispatch && ./tests/bats/bin/bats tests/`
Expected: PASS (all tests)

- [ ] **Step 3: Dry-run verify — source the dispatch script to check for syntax errors**

Run: `cd ~/claude-agent-dispatch && bash -n scripts/agent-dispatch.sh && echo "Syntax OK"`
Expected: "Syntax OK"

- [ ] **Step 4: Verify all new files are committed**

Run: `cd ~/claude-agent-dispatch && git status`
Expected: Clean working tree

- [ ] **Step 5: Review the full diff since before this plan**

Run: `cd ~/claude-agent-dispatch && git log --oneline bd1b6c1..HEAD`
Expected: All commits covering the full Phase 1 implementation (starting SHA `bd1b6c1` is the last commit before this plan)
