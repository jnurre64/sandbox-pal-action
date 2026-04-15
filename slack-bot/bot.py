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


def parse_value(value: str) -> tuple[str | None, int | None]:
    """Parse 'owner/repo:issue_number' from a button value."""
    parts = value.rsplit(":", 1)
    if len(parts) != 2:
        return None, None
    try:
        return parts[0], int(parts[1])
    except ValueError:
        return None, None


async def is_authorized(user_id: str, client) -> bool:
    """Check if a Slack user is authorized to use bot actions.

    Uses shared auth for user-level checks. Group membership is checked
    via the Slack API if ALLOWED_GROUP is configured.
    """
    if is_authorized_check(user_id, [], ALLOWED_USERS, ""):
        return True
    if ALLOWED_GROUP:
        try:
            result = await client.usergroups_users_list(usergroup=ALLOWED_GROUP)
            return user_id in result.get("users", [])
        except Exception:
            log.warning("Failed to check user group membership for %s", user_id)
    return False


def build_updated_attachments(message: dict, action_text: str) -> list[dict]:
    """Build updated attachments after a button action is taken.

    Replaces interactive buttons with a view-only link and appends
    a context block showing who performed the action.
    """
    attachments = message.get("attachments", [])
    if not attachments:
        return []
    old = attachments[0]
    blocks = old.get("blocks", [])
    color = old.get("color", "#95A5A6")

    updated: list[dict] = []
    for block in blocks:
        if block["type"] == "actions":
            view_url = None
            for elem in block.get("elements", []):
                if elem.get("url"):
                    view_url = elem["url"]
                    break
            if view_url:
                updated.append({
                    "type": "actions",
                    "elements": [{
                        "type": "button",
                        "text": {"type": "plain_text", "text": "View"},
                        "url": view_url,
                        "action_id": "view_link",
                    }],
                })
        else:
            updated.append(block)
    updated.append({
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": action_text}],
    })
    return [{"color": color, "blocks": updated}]


async def handle_approve(ack, body, client) -> None:
    """Handle Approve button click: add plan-approved label, trigger implementation."""
    await ack()
    user_id = body["user"]["id"]
    channel = body["channel"]["id"]

    if not await is_authorized(user_id, client):
        await client.chat_postEphemeral(channel=channel, user=user_id, text="You don't have permission to perform this action.")
        return

    repo, issue_number = parse_value(body["actions"][0]["value"])
    if repo is None:
        return

    ok, err = gh_command([
        "issue", "edit", str(issue_number), "--repo", repo,
        "--remove-label", "agent:plan-review", "--add-label", "agent:plan-approved",
    ])
    if not ok:
        await client.chat_postEphemeral(channel=channel, user=user_id, text=f"Failed to update GitHub issue #{issue_number}: {err}")
        return

    dispatch_ok, dispatch_err = gh_dispatch(repo, "agent-implement", issue_number)

    action_text = f"Approved by <@{user_id}>"
    attachments = build_updated_attachments(body["message"], action_text)
    await client.chat_update(channel=channel, ts=body["message"]["ts"], attachments=attachments, text=body["message"].get("text", ""))

    status = f"Done: Approved by <@{user_id}>"
    if not dispatch_ok:
        status += f" (warning: workflow trigger failed -- {dispatch_err})"
    await client.chat_postEphemeral(channel=channel, user=user_id, text=status)
    log.info("ACTION: approve on %s#%d by %s", repo, issue_number, user_id)


async def handle_retry(ack, body, client) -> None:
    """Handle Retry button click: reset labels, re-trigger triage."""
    await ack()
    user_id = body["user"]["id"]
    channel = body["channel"]["id"]

    if not await is_authorized(user_id, client):
        await client.chat_postEphemeral(channel=channel, user=user_id, text="You don't have permission to perform this action.")
        return

    repo, issue_number = parse_value(body["actions"][0]["value"])
    if repo is None:
        return

    ok, err = gh_command([
        "issue", "edit", str(issue_number), "--repo", repo,
        "--remove-label", ",".join(ALL_AGENT_LABELS), "--add-label", "agent",
    ])
    if not ok:
        await client.chat_postEphemeral(channel=channel, user=user_id, text=f"Failed to update GitHub issue #{issue_number}: {err}")
        return

    dispatch_ok, dispatch_err = gh_dispatch(repo, "agent-triage", issue_number)

    action_text = f"Retried by <@{user_id}>"
    attachments = build_updated_attachments(body["message"], action_text)
    await client.chat_update(channel=channel, ts=body["message"]["ts"], attachments=attachments, text=body["message"].get("text", ""))

    status = f"Done: Retried by <@{user_id}>"
    if not dispatch_ok:
        status += f" (warning: workflow trigger failed -- {dispatch_err})"
    await client.chat_postEphemeral(channel=channel, user=user_id, text=status)
    log.info("ACTION: retry on %s#%d by %s", repo, issue_number, user_id)


async def _open_feedback_modal(
    client, trigger_id: str, action: str, repo: str,
    issue_number: int, channel: str, ts: str,
) -> None:
    """Open a Slack modal for free-text feedback."""
    title = f"Changes #{issue_number}" if action == "changes" else f"Comment #{issue_number}"
    placeholder = "Describe the changes you'd like..." if action == "changes" else "Enter your comment..."

    metadata = json.dumps({
        "action": action, "repo": repo, "issue_number": issue_number,
        "channel": channel, "ts": ts,
    })
    await client.views_open(
        trigger_id=trigger_id,
        view={
            "type": "modal",
            "callback_id": "feedback_modal",
            "private_metadata": metadata,
            "title": {"type": "plain_text", "text": title[:24]},
            "submit": {"type": "plain_text", "text": "Submit"},
            "blocks": [{
                "type": "input",
                "block_id": "feedback_block",
                "element": {
                    "type": "plain_text_input",
                    "action_id": "feedback_input",
                    "multiline": True,
                    "min_length": 10,
                    "max_length": 2000,
                    "placeholder": {"type": "plain_text", "text": placeholder},
                },
                "label": {"type": "plain_text", "text": "Feedback"},
            }],
        },
    )


async def handle_changes(ack, body, client) -> None:
    """Handle Request Changes button: open feedback modal."""
    await ack()
    user_id = body["user"]["id"]
    if not await is_authorized(user_id, client):
        await client.chat_postEphemeral(channel=body["channel"]["id"], user=user_id, text="You don't have permission to perform this action.")
        return

    repo, issue_number = parse_value(body["actions"][0]["value"])
    if repo is None:
        return

    await _open_feedback_modal(
        client, body["trigger_id"], "changes", repo, issue_number,
        body["channel"]["id"], body["message"]["ts"],
    )


async def handle_comment(ack, body, client) -> None:
    """Handle Comment button: open feedback modal."""
    await ack()
    user_id = body["user"]["id"]
    if not await is_authorized(user_id, client):
        await client.chat_postEphemeral(channel=body["channel"]["id"], user=user_id, text="You don't have permission to perform this action.")
        return

    repo, issue_number = parse_value(body["actions"][0]["value"])
    if repo is None:
        return

    await _open_feedback_modal(
        client, body["trigger_id"], "comment", repo, issue_number,
        body["channel"]["id"], body["message"]["ts"],
    )


async def handle_view_link(ack) -> None:
    """No-op handler for View link buttons (Slack requires ack)."""
    await ack()


async def handle_feedback_submit(ack, body, client, view) -> None:
    """Handle feedback modal submission: post comment to GitHub, reply in thread."""
    await ack()
    meta = json.loads(view["private_metadata"])
    action = meta["action"]
    repo = meta["repo"]
    issue_number = meta["issue_number"]
    channel = meta["channel"]
    ts = meta["ts"]
    user_id = body["user"]["id"]

    feedback = sanitize_input(
        view["state"]["values"]["feedback_block"]["feedback_input"]["value"]
    )

    ok, err = gh_command(["issue", "comment", str(issue_number), "--repo", repo, "--body", feedback])
    if not ok:
        await client.chat_postEphemeral(channel=channel, user=user_id, text=f"Failed to comment on #{issue_number}: {err}")
        return

    action_label = "Changes requested" if action == "changes" else "Comment posted"
    await client.chat_postMessage(
        channel=channel, thread_ts=ts,
        text=f"{action_label} by <@{user_id}>",
    )

    gh_dispatch(repo, "agent-reply", issue_number)
    log.info("MODAL: %s on %s#%d by %s", action, repo, issue_number, user_id)
