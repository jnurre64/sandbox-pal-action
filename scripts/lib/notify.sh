#!/bin/bash
# ─── Notification layer (optional) ─────────────────────────────────
# Sends notifications at dispatch milestones to configured platforms.
# Currently supports Discord webhooks. Slack and Telegram planned.
# Silently no-ops if no platform is configured.

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

# ─── Event metadata ────────────────────────────────────────────────
_notify_event_color() {
    case "$1" in
        pr_created|tests_passed)     echo "5763719"  ;;  # green
        tests_failed|agent_failed)   echo "15548997" ;;  # red
        plan_posted|questions_asked) echo "3447003"  ;;  # blue
        review_feedback)             echo "16776960" ;;  # yellow
        *)                           echo "9807270"  ;;  # grey
    esac
}

_notify_event_label() {
    case "$1" in
        plan_posted)        echo "Plan Ready"             ;;
        questions_asked)    echo "Questions"              ;;
        implement_started)  echo "Implementation Started" ;;
        tests_passed)       echo "Tests Passed"           ;;
        tests_failed)       echo "Tests Failed"           ;;
        pr_created)         echo "PR Created"             ;;
        review_feedback)    echo "Review Feedback"        ;;
        agent_failed)       echo "Agent Failed"           ;;
        *)                  echo "Agent Update"           ;;
    esac
}

_notify_event_indicator() {
    case "$1" in
        pr_created|tests_passed)     echo "[OK]"     ;;
        tests_failed|agent_failed)   echo "[FAIL]"   ;;
        plan_posted|questions_asked) echo "[INFO]"   ;;
        review_feedback)             echo "[ACTION]" ;;
        implement_started)           echo "[INFO]"   ;;
        *)                           echo "[INFO]"   ;;
    esac
}

# ─── Build Discord embed JSON ──────────────────────────────────────
# Usage: _notify_build_discord_embed <event_type> <title> <url> <description>
_notify_build_discord_embed() {
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
    jq -cn \
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

# ─── Send to Discord webhook ──────────────────────────────────────
# Usage: _notify_send_discord <json_payload>
_notify_send_discord() {
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

# ─── Send to bot local HTTP API ──────────────────────────────────
# Usage: _notify_send_bot <event_type> <title> <url> <description>
# Returns 0 on success, 1 on failure (caller should fallback)
_notify_send_bot() {
    local event_type="$1"
    local title="$2"
    local url="$3"
    local description="$4"
    local port="${AGENT_DISCORD_BOT_PORT:-8675}"

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

# ─── Main notification function ────────────────────────────────────
# Usage: notify <event_type> <title> <url> [description]
notify() {
    local event_type="${1:-}"
    local title="${2:-}"
    local url="${3:-}"
    local description="${4:-}"

    # No-op if no platform is configured.
    # Webhook URL is required even in bot mode (used as fallback).
    if [ -z "${AGENT_NOTIFY_DISCORD_WEBHOOK:-}" ]; then
        return 0
    fi

    # Check notification level filter
    _notify_should_send "$event_type" || return 0

    # ── Route based on backend ──
    local backend="${AGENT_NOTIFY_BACKEND:-webhook}"

    if [ "$backend" = "bot" ]; then
        # Try bot first, fall back to webhook on failure
        if ! _notify_send_bot "$event_type" "$title" "$url" "$description"; then
            local discord_json
            discord_json=$(_notify_build_discord_embed "$event_type" "$title" "$url" "$description")
            _notify_send_discord "$discord_json"
        fi
    else
        # Webhook mode (Phase 1 default)
        local discord_json
        discord_json=$(_notify_build_discord_embed "$event_type" "$title" "$url" "$description")
        _notify_send_discord "$discord_json"
    fi
}
