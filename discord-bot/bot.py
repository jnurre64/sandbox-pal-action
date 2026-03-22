"""Discord bot for claude-agent-dispatch interactive notifications."""

import logging
import os
import re

import discord
from aiohttp import web

log = logging.getLogger("dispatch-bot")

# --- Configuration (from environment) ---
BOT_TOKEN = os.environ.get("AGENT_DISCORD_BOT_TOKEN", "")
CHANNEL_ID = int(os.environ.get("AGENT_DISCORD_CHANNEL_ID", "0"))
GUILD_ID = int(os.environ.get("AGENT_DISCORD_GUILD_ID", "0"))
ALLOWED_USERS = set(os.environ.get("AGENT_DISCORD_ALLOWED_USERS", "").split(",")) - {""}
ALLOWED_ROLE = os.environ.get("AGENT_DISCORD_ALLOWED_ROLE", "")
BOT_PORT = int(os.environ.get("AGENT_DISCORD_BOT_PORT", "8675"))
REPO = os.environ.get("AGENT_DISPATCH_REPO", "")


def sanitize_input(text: str) -> str:
    """Remove shell-dangerous characters from user input."""
    return re.sub(r"[`$\\]", "", text)[:2000]


def parse_custom_id(custom_id: str) -> tuple[str | None, int | None]:
    """Parse 'action:issue_number' from a button custom_id."""
    if ":" not in custom_id:
        return None, None
    action, num_str = custom_id.split(":", 1)
    try:
        return action, int(num_str)
    except ValueError:
        return None, None


def is_authorized_check(
    user_id: str, role_ids: list[str], allowed_users: set[str], allowed_role: str
) -> bool:
    """Check if a user is authorized to perform bot actions."""
    if not allowed_users and not allowed_role:
        return False
    if user_id in allowed_users:
        return True
    if allowed_role and allowed_role in role_ids:
        return True
    return False


# --- Event metadata ---
EVENT_COLORS = {
    "pr_created": 0x57F287, "tests_passed": 0x57F287,
    "tests_failed": 0xED4245, "agent_failed": 0xED4245,
    "plan_posted": 0x3498DB, "questions_asked": 0x3498DB,
    "review_feedback": 0xFFFF00,
}

EVENT_LABELS = {
    "plan_posted": "Plan Ready", "questions_asked": "Questions",
    "implement_started": "Implementation Started",
    "tests_passed": "Tests Passed", "tests_failed": "Tests Failed",
    "pr_created": "PR Created", "review_feedback": "Review Feedback",
    "agent_failed": "Agent Failed",
}

EVENT_INDICATORS = {
    "pr_created": "[OK]", "tests_passed": "[OK]",
    "tests_failed": "[FAIL]", "agent_failed": "[FAIL]",
    "plan_posted": "[INFO]", "questions_asked": "[INFO]",
    "review_feedback": "[ACTION]", "implement_started": "[INFO]",
}

# Events that get action buttons (not just a View link)
_PLAN_EVENTS = {"plan_posted"}
_RETRY_EVENTS = {"agent_failed"}


def build_embed(
    event_type: str, title: str, url: str, description: str, issue_number: int, repo: str
) -> discord.Embed:
    """Build a Discord embed for a dispatch notification."""
    indicator = EVENT_INDICATORS.get(event_type, "[INFO]")
    label = EVENT_LABELS.get(event_type, "Agent Update")
    color = EVENT_COLORS.get(event_type, 0x95A5A6)

    embed = discord.Embed(
        title=f"{indicator} {label} -- #{issue_number}: {title}",
        url=url,
        description=description[:4000],
        color=color,
    )
    embed.set_footer(text=f"Automated by claude-agent-dispatch | {repo} #{issue_number}")
    return embed


def build_buttons(event_type: str, issue_number: int, url: str) -> discord.ui.View:
    """Build interactive buttons for a notification message."""
    view = discord.ui.View(timeout=None)
    view.add_item(discord.ui.Button(label="View", url=url, style=discord.ButtonStyle.link))

    if event_type in _PLAN_EVENTS:
        view.add_item(discord.ui.Button(
            label="Approve", custom_id=f"approve:{issue_number}", style=discord.ButtonStyle.success
        ))
        view.add_item(discord.ui.Button(
            label="Request Changes", custom_id=f"changes:{issue_number}", style=discord.ButtonStyle.danger
        ))
        view.add_item(discord.ui.Button(
            label="Comment", custom_id=f"comment:{issue_number}", style=discord.ButtonStyle.secondary
        ))
    elif event_type in _RETRY_EVENTS:
        view.add_item(discord.ui.Button(
            label="Retry", custom_id=f"retry:{issue_number}", style=discord.ButtonStyle.primary
        ))

    return view


def create_notify_handler(channel):
    """Create an aiohttp handler that sends notifications to the given Discord channel."""
    async def handle_notify(request: web.Request) -> web.Response:
        if channel is None:
            return web.Response(status=503, text="Channel not found")

        data = await request.json()
        event_type = data["event_type"]
        title = data["title"]
        url = data["url"]
        description = data.get("description", "")
        issue_number = data.get("issue_number", 0)
        repo = data.get("repo", "")

        embed = build_embed(event_type, title, url, description, issue_number, repo)
        view = build_buttons(event_type, issue_number, url)
        await channel.send(embed=embed, view=view)
        return web.Response(text="OK")

    return handle_notify
