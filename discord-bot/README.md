# Agent Dispatch Discord Bot

Interactive Discord bot for managing agent work. Adds buttons, slash commands, and modals on top of the webhook notification layer.

## Prerequisites

- Python 3.10+
- `gh` CLI authenticated with repo access
- A Discord bot application ([create one](https://discord.com/developers/applications))

## Discord Bot Setup

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Create a new application
3. Go to Bot > Reset Token > copy the token
4. Under Privileged Gateway Intents: leave all **unchecked** (no privileged intents needed)
5. Go to OAuth2 > URL Generator:
   - Scopes: `bot`, `applications.commands`
   - Bot Permissions: `View Channels`, `Send Messages`
6. Copy the generated URL and open it to invite the bot to your server
7. Get your channel ID (right-click channel > Copy Channel ID; enable Developer Mode in Discord settings if needed)
8. Get your server (guild) ID (right-click server name > Copy Server ID)

## Configuration

Add to your `config.env`:

```bash
AGENT_DISCORD_BOT_TOKEN="your-bot-token"
AGENT_DISCORD_CHANNEL_ID="123456789"
AGENT_DISCORD_GUILD_ID="987654321"
AGENT_DISCORD_ALLOWED_USERS="your-discord-user-id"  # comma-separated
# AGENT_DISCORD_ALLOWED_ROLE="role-id"              # alternative: role-based
AGENT_DISPATCH_REPO="owner/repo"                     # required: GitHub repo for gh commands
AGENT_DISCORD_BOT_PORT="8675"                        # default
AGENT_NOTIFY_BACKEND="bot"                           # switches from webhook to bot
```

## Install

```bash
./install.sh
systemctl --user start agent-dispatch-bot
```

## Verify

```bash
systemctl --user status agent-dispatch-bot
journalctl --user -u agent-dispatch-bot -f
```

## Buttons

| Button | Action |
|---|---|
| View | Link to GitHub issue/PR |
| Approve | Adds `agent:plan-approved` label, triggers implementation |
| Request Changes | Opens modal, posts comment, triggers re-triage |
| Comment | Opens modal, posts comment |
| Retry | Resets labels, adds `agent` to re-trigger |

## Slash Commands

| Command | Description |
|---|---|
| `/approve <issue>` | Approve a plan |
| `/reject <issue> [reason]` | Reject with optional reason |
| `/comment <issue> <text>` | Post feedback |
| `/status <issue>` | Check current agent labels |
| `/retry <issue>` | Re-trigger agent |

## Privacy

This bot processes Discord button clicks and slash commands to manage GitHub issues. No user data is collected or stored beyond operational logs.
