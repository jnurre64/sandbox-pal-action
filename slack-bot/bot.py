"""Slack bot for claude-agent-dispatch interactive notifications."""

import json
import logging
import os

from aiohttp import web

from dispatch_bot.events import (
    EVENT_INDICATORS,
    EVENT_LABELS,
    PLAN_EVENTS,
    RETRY_EVENTS,
)
from dispatch_bot.github import ALL_AGENT_LABELS, gh_command, gh_dispatch
from dispatch_bot.auth import is_authorized_check
from dispatch_bot.sanitize import sanitize_input
from dispatch_bot.http_listener import start_http_server

log = logging.getLogger("dispatch-bot")

# --- Configuration (from environment) ---
BOT_TOKEN = os.environ.get("AGENT_SLACK_BOT_TOKEN", "")
APP_TOKEN = os.environ.get("AGENT_SLACK_APP_TOKEN", "")
CHANNEL_ID = os.environ.get("AGENT_SLACK_CHANNEL_ID", "")
ALLOWED_USERS = set(os.environ.get("AGENT_SLACK_ALLOWED_USERS", "").split(",")) - {""}
ALLOWED_GROUP = os.environ.get("AGENT_SLACK_ALLOWED_GROUP", "")
BOT_PORT = int(os.environ.get("AGENT_SLACK_BOT_PORT", "8676"))
DEFAULT_REPO = os.environ.get("AGENT_DISPATCH_REPO", "")

# --- Event colors (hex strings for Slack attachment sidebar) ---
EVENT_COLORS: dict[str, str] = {
    "pr_created": "#57F287", "tests_passed": "#57F287", "review_pushed": "#57F287",
    "tests_failed": "#ED4245", "agent_failed": "#ED4245",
    "plan_posted": "#3498DB", "questions_asked": "#3498DB",
    "review_feedback": "#FFFF00",
}


def build_blocks(
    event_type: str, title: str, url: str, description: str, issue_number: int, repo: str,
) -> list[dict]:
    """Build Block Kit blocks for notification content."""
    indicator = EVENT_INDICATORS.get(event_type, "[INFO]")
    label = EVENT_LABELS.get(event_type, "Agent Update")

    blocks: list[dict] = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*{indicator} {label} -- <{url}|#{issue_number}: {title}>*",
            },
        },
    ]
    if description:
        blocks.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": description[:3000]},
        })
    blocks.append({
        "type": "context",
        "elements": [
            {"type": "mrkdwn", "text": f"Automated by claude-agent-dispatch | {repo} #{issue_number}"},
        ],
    })
    return blocks


def build_actions(event_type: str, issue_number: int, url: str, repo: str) -> list[dict]:
    """Build action button elements for a notification."""
    value = f"{repo}:{issue_number}"
    elements: list[dict] = [
        {
            "type": "button",
            "text": {"type": "plain_text", "text": "View"},
            "url": url,
            "action_id": "view_link",
        },
    ]
    if event_type in PLAN_EVENTS:
        elements.extend([
            {"type": "button", "text": {"type": "plain_text", "text": "Approve"}, "action_id": "approve", "value": value, "style": "primary"},
            {"type": "button", "text": {"type": "plain_text", "text": "Request Changes"}, "action_id": "changes", "value": value, "style": "danger"},
            {"type": "button", "text": {"type": "plain_text", "text": "Comment"}, "action_id": "comment", "value": value},
        ])
    elif event_type in RETRY_EVENTS:
        elements.append(
            {"type": "button", "text": {"type": "plain_text", "text": "Retry"}, "action_id": "retry", "value": value, "style": "primary"},
        )
    return [{"type": "actions", "elements": elements}]
