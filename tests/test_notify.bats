#!/usr/bin/env bats
# Tests for scripts/lib/notify.sh

load 'helpers/test_helper'

_source_notify() {
    source "${LIB_DIR}/notify.sh"
}

# ===================================================================
# No-op behavior when unconfigured
# ===================================================================

@test "notify: does not send when AGENT_NOTIFY_DISCORD_WEBHOOK is empty (logs match=dropped)" {
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_DISCORD_WEBHOOK=""
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ]
    echo "$output" | grep -q "match=dropped"
}

@test "notify: does not send when AGENT_NOTIFY_DISCORD_WEBHOOK is unset (logs match=dropped)" {
    export AGENT_NOTIFY_BACKEND="webhook"
    unset AGENT_NOTIFY_DISCORD_WEBHOOK
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ]
    echo "$output" | grep -q "match=dropped"
}

# ─── REGRESSION issue-53: empty AGENT_NOTIFY_BACKEND is a clean no-op ──────
# Previously the default was "webhook"; with an empty default, notify() must
# early-return without emitting a bogus "unknown backend" warning.

@test "REGRESSION issue-53: empty AGENT_NOTIFY_BACKEND is a clean no-op (no warning, no curl)" {
    export AGENT_NOTIFY_BACKEND=""
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ]
    ! echo "$output" | grep -q "unknown notification backend"
    ! echo "$output" | grep -q "match="
}

@test "REGRESSION issue-53: unset AGENT_NOTIFY_BACKEND is a clean no-op (default changed to empty)" {
    unset AGENT_NOTIFY_BACKEND
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ]
    ! echo "$output" | grep -q "unknown notification backend"
}

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

@test "notify level 'actionable': sends review_pushed" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/test/token"
    export AGENT_NOTIFY_LEVEL="actionable"
    _source_notify

    run _notify_should_send "review_pushed"
    assert_success
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

# ===================================================================
# Embed formatting
# ===================================================================

@test "notify embed: plan_posted has blue color (3447003) and correct title" {
    _source_notify

    run _notify_build_discord_embed "plan_posted" "Add sprite caching" "https://github.com/org/repo/issues/42" "Plan summary here"
    assert_success

    local color title
    color=$(echo "$output" | jq -r '.embeds[0].color')
    title=$(echo "$output" | jq -r '.embeds[0].title')
    assert_equal "$color" "3447003"
    assert_equal "$title" "[INFO] Plan Ready -- #99: Add sprite caching"
}

@test "notify embed: tests_failed has red color (15548997)" {
    _source_notify

    run _notify_build_discord_embed "tests_failed" "Fix login bug" "https://github.com/org/repo/issues/5" "npm test exited 1"
    assert_success

    local color
    color=$(echo "$output" | jq -r '.embeds[0].color')
    assert_equal "$color" "15548997"
}

@test "notify embed: pr_created has green color (5763719)" {
    _source_notify

    run _notify_build_discord_embed "pr_created" "Add feature X" "https://github.com/org/repo/pull/87" "3 commits"
    assert_success

    local color
    color=$(echo "$output" | jq -r '.embeds[0].color')
    assert_equal "$color" "5763719"
}

@test "notify embed: review_feedback has yellow color (16776960)" {
    _source_notify

    run _notify_build_discord_embed "review_feedback" "PR #87" "https://github.com/org/repo/pull/87" "Changes requested"
    assert_success

    local color
    color=$(echo "$output" | jq -r '.embeds[0].color')
    assert_equal "$color" "16776960"
}

@test "notify embed: includes footer with automation disclosure" {
    _source_notify

    run _notify_build_discord_embed "plan_posted" "Issue title" "https://example.com" "desc"
    assert_success

    local footer
    footer=$(echo "$output" | jq -r '.embeds[0].footer.text')
    [[ "$footer" == *"Automated by sandbox-pal-action"* ]]
}

@test "notify embed: includes issue URL in field" {
    _source_notify

    run _notify_build_discord_embed "plan_posted" "Issue title" "https://github.com/org/repo/issues/42" "desc"
    assert_success

    echo "$output" | jq -e '.embeds[0]' | grep -q "https://github.com/org/repo/issues/42"
}

@test "notify embed: truncates description longer than 4000 chars" {
    _source_notify

    local long_desc
    long_desc=$(printf 'x%.0s' {1..5000})

    run _notify_build_discord_embed "plan_posted" "Issue title" "https://example.com" "$long_desc"
    assert_success

    local desc_len
    desc_len=$(echo "$output" | jq -r '.embeds[0].description' | wc -c)
    [ "$desc_len" -le 4010 ]
}

@test "notify embed: uses webhook username 'Pennyworth'" {
    _source_notify

    run _notify_build_discord_embed "plan_posted" "Issue title" "https://example.com" "desc"
    assert_success

    local username
    username=$(echo "$output" | jq -r '.username')
    assert_equal "$username" "Pennyworth"
}

# ===================================================================
# Sending via webhook
# ===================================================================

@test "notify send: calls curl with correct webhook URL" {
    export AGENT_NOTIFY_BACKEND="webhook"
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
    export AGENT_NOTIFY_BACKEND="webhook"
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
    export AGENT_NOTIFY_BACKEND="webhook"
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
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_DISCORD_THREAD_ID=""
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    ! echo "$calls" | grep -q "thread_id"
}

@test "notify send: does not fail when curl fails" {
    export AGENT_NOTIFY_BACKEND="webhook"
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

# ===================================================================
# Phase 2: Configuration defaults
# ===================================================================

@test "defaults: AGENT_DISCORD_BOT_TOKEN defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_DISCORD_BOT_TOKEN

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_DISCORD_BOT_TOKEN" ""
}

@test "defaults: AGENT_DISCORD_CHANNEL_ID defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_DISCORD_CHANNEL_ID

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_DISCORD_CHANNEL_ID" ""
}

@test "defaults: AGENT_DISCORD_BOT_PORT defaults to 8675" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_DISCORD_BOT_PORT

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_DISCORD_BOT_PORT" "8675"
}

@test "REGRESSION issue-53: AGENT_NOTIFY_BACKEND defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_NOTIFY_BACKEND

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_BACKEND" ""
}

# ===================================================================
# Phase 2: Bot backend routing
# ===================================================================

@test "notify: routes to bot HTTP API when AGENT_NOTIFY_BACKEND=bot" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_BACKEND="bot"
    export AGENT_DISCORD_BOT_PORT="8675"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "127.0.0.1:8675/notify"
}

@test "notify: bot backend sends JSON with issue_number and repo" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_BACKEND="bot"
    export AGENT_DISCORD_BOT_PORT="8675"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "issue_number"
    echo "$calls" | grep -q "event_type"
}

@test "notify: falls back to webhook when bot backend curl fails" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_BACKEND="bot"
    export AGENT_DISCORD_BOT_PORT="8675"
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
    echo "$calls" | tail -1 | grep -q "discord.com/api/webhooks"
}

@test "notify: webhook backend still works unchanged" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/123/abc"
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "discord.com/api/webhooks"
    ! echo "$calls" | grep -q "127.0.0.1"
}

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

# ===================================================================
# Phase 4: Per-repo channel routing — map resolver helper
# ===================================================================

@test "_notify_resolve_from_map: returns mapped value when repo matches" {
    _source_notify

    run _notify_resolve_from_map "org/repo" "org/repo=https://hook/a,other/repo=https://hook/b"
    assert_success
    assert_output "https://hook/a"
}

@test "_notify_resolve_from_map: returns empty string for explicit mute" {
    _source_notify

    run _notify_resolve_from_map "org/muted" "org/muted=,org/other=https://hook/a"
    assert_success
    assert_output ""
}

@test "_notify_resolve_from_map: returns non-zero when repo not in map" {
    _source_notify

    run _notify_resolve_from_map "missing/repo" "org/a=x,org/b=y"
    assert_failure
}

@test "_notify_resolve_from_map: returns non-zero when map is empty" {
    _source_notify

    run _notify_resolve_from_map "any/repo" ""
    assert_failure
}

@test "_notify_resolve_from_map: trims whitespace around entries" {
    _source_notify

    run _notify_resolve_from_map "org/repo" " org/repo = https://hook/a , other/repo = https://hook/b "
    assert_success
    assert_output "https://hook/a"
}

@test "_notify_resolve_from_map: splits on first '=' only (URL-like values)" {
    _source_notify

    run _notify_resolve_from_map "org/repo" "org/repo=https://hook?a=b&c=d"
    assert_success
    assert_output "https://hook?a=b&c=d"
}

@test "_notify_resolve_from_map: skips malformed entries" {
    _source_notify

    run _notify_resolve_from_map "org/repo" "bad_entry,=orphan,org/repo=good"
    assert_success
    assert_output "good"
}

# ===================================================================
# Phase 4: Per-repo webhook routing (Discord)
# ===================================================================

@test "notify webhook: uses mapped URL when repo matches map" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="test-org/test-repo=https://discord.com/api/webhooks/mapped/token"
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "webhooks/mapped/token"
    ! echo "$calls" | grep -q "webhooks/default/token"
}

@test "notify webhook: falls back to default URL when repo not in map" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="other-org/other-repo=https://discord.com/api/webhooks/mapped/token"
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "webhooks/default/token"
    ! echo "$calls" | grep -q "webhooks/mapped/token"
}

@test "notify webhook: skips silently when repo has empty value (mute)" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="test-org/test-repo="
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ] || ! echo "$calls" | grep -q "discord.com"
}

@test "notify webhook: skips silently when no map and no default" {
    unset AGENT_NOTIFY_DISCORD_WEBHOOK
    unset AGENT_NOTIFY_DISCORD_WEBHOOK_MAP
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    [ -z "$calls" ]
}

@test "notify webhook: appends thread_id to mapped URL" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="test-org/test-repo=https://discord.com/api/webhooks/mapped/token"
    export AGENT_NOTIFY_DISCORD_THREAD_ID="987654321"
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    local calls
    calls=$(get_mock_calls "curl")
    echo "$calls" | grep -q "webhooks/mapped/token?thread_id=987654321"
}

@test "notify webhook: emits logfmt INFO log with match=direct" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="test-org/test-repo=https://discord.com/api/webhooks/mapped/token"
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    echo "$output" | grep -q "match=direct"
    echo "$output" | grep -q "repo=test-org/test-repo"
}

@test "notify webhook: emits logfmt INFO log with match=fallback" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="other-org/other-repo=https://discord.com/api/webhooks/mapped/token"
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    echo "$output" | grep -q "match=fallback"
}

@test "notify webhook: emits logfmt INFO log with match=muted" {
    export AGENT_NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/default/token"
    export AGENT_NOTIFY_DISCORD_WEBHOOK_MAP="test-org/test-repo="
    export AGENT_NOTIFY_BACKEND="webhook"
    export AGENT_NOTIFY_LEVEL="all"
    create_mock "curl" ""
    _source_notify

    run notify "plan_posted" "Test Issue" "https://github.com/test/1" "Plan summary"
    assert_success

    echo "$output" | grep -q "match=muted"
}

# ===================================================================
# Phase 4: Per-repo webhook routing (Slack fallback)
# ===================================================================

@test "notify slack: bot-to-webhook fallback uses mapped Slack URL" {
    export AGENT_NOTIFY_SLACK_WEBHOOK="https://hooks.slack.com/services/default"
    export AGENT_NOTIFY_SLACK_WEBHOOK_MAP="test-org/test-repo=https://hooks.slack.com/services/mapped"
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
    echo "$calls" | grep -q "hooks.slack.com/services/mapped"
    ! echo "$calls" | grep -q "hooks.slack.com/services/default"
}

@test "notify slack: bot-to-webhook fallback mutes on empty value" {
    export AGENT_NOTIFY_SLACK_WEBHOOK="https://hooks.slack.com/services/default"
    export AGENT_NOTIFY_SLACK_WEBHOOK_MAP="test-org/test-repo="
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
    ! echo "$calls" | grep -q "hooks.slack.com"
}

@test "defaults: AGENT_DISCORD_CHANNEL_MAP defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_DISCORD_CHANNEL_MAP

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_DISCORD_CHANNEL_MAP" ""
}

@test "defaults: AGENT_SLACK_CHANNEL_MAP defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_SLACK_CHANNEL_MAP

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_SLACK_CHANNEL_MAP" ""
}

@test "defaults: AGENT_NOTIFY_DISCORD_WEBHOOK_MAP defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_NOTIFY_DISCORD_WEBHOOK_MAP

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_DISCORD_WEBHOOK_MAP" ""
}

@test "defaults: AGENT_NOTIFY_SLACK_WEBHOOK_MAP defaults to empty" {
    export AGENT_BOT_USER="test-bot"
    unset AGENT_NOTIFY_SLACK_WEBHOOK_MAP

    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_NOTIFY_SLACK_WEBHOOK_MAP" ""
}

@test "defaults: config.env overrides AGENT_DISCORD_CHANNEL_MAP" {
    cat > "${MOCK_CONFIG_DIR}/config.env" << 'EOF'
AGENT_BOT_USER="custom-bot"
AGENT_DISCORD_CHANNEL_MAP="org/a=111,org/b=222"
EOF

    source "${MOCK_CONFIG_DIR}/config.env"
    source "${LIB_DIR}/defaults.sh"

    assert_equal "$AGENT_DISCORD_CHANNEL_MAP" "org/a=111,org/b=222"
}

@test "notify slack: bot-to-webhook fallback falls back to default when repo not mapped" {
    export AGENT_NOTIFY_SLACK_WEBHOOK="https://hooks.slack.com/services/default"
    export AGENT_NOTIFY_SLACK_WEBHOOK_MAP="other/repo=https://hooks.slack.com/services/mapped"
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
    echo "$calls" | grep -q "hooks.slack.com/services/default"
}
