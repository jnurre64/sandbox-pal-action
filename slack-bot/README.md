# Agent Dispatch Slack Bot

Interactive Slack bot for managing agent work. Adds buttons, slash commands, and modals on top of the webhook notification layer.

## Prerequisites

- Python 3.10+ with `python3-venv` package
- `gh` CLI authenticated with repo access
- A Slack workspace you have admin access to

## Step-by-Step Setup

### 1. Create the Slack App

1. Go to [Slack API Apps](https://api.slack.com/apps)
2. Click **"Create New App"** > **"From scratch"**
3. Name it (e.g., "Agent Dispatch") and select your workspace

### 2. Enable Socket Mode

1. In the left sidebar, click **"Socket Mode"**
2. Toggle **Enable Socket Mode** to on
3. Create an **App-Level Token** with the `connections:write` scope
4. Name it (e.g., "socket-mode") and click **Generate**
5. **Copy the `xapp-` token immediately**

### 3. Configure Bot Token Scopes

1. In the left sidebar, click **"OAuth & Permissions"**
2. Under **Bot Token Scopes**, add:
   - `chat:write` -- send and update messages
   - `commands` -- slash commands
3. If using `AGENT_SLACK_ALLOWED_GROUP`, also add:
   - `usergroups:read` -- check user group membership

### 4. Create Slash Commands

1. In the left sidebar, click **"Slash Commands"**
2. Create each command:

| Command | Description |
|---|---|
| `/agent-approve` | Approve an agent plan |
| `/agent-reject` | Reject a plan with optional reason |
| `/agent-comment` | Post feedback on an issue |
| `/agent-status` | Check current agent labels |
| `/agent-retry` | Re-trigger the agent |

For each: click **"Create New Command"**, enter the command name and a short description. If Slack asks for a Request URL, enter `https://localhost` (Socket Mode ignores it, but the field may be required).

### 5. Enable Interactivity

1. In the left sidebar, click **"Interactivity & Shortcuts"**
2. Toggle **Interactivity** to on
3. If Slack shows a Request URL field, enter `https://localhost` -- with Socket Mode enabled, Slack typically skips this field entirely
4. Click **"Save Changes"**

### 6. Install to Workspace

1. In the left sidebar, click **"Install App"**
2. Click **"Install to Workspace"** and authorize
3. **Copy the `xoxb-` Bot User OAuth Token**

### 7. Invite the Bot to Your Channel

The bot must be a member of the notification channel before it can post messages.

In Slack, go to your notification channel and type:

```
/invite @Pennyworth
```

Or: click the channel name > **Integrations** > **Add apps** > search for your bot name.

### 8. Get Your Slack IDs

| ID | How to get it |
|---|---|
| **Channel ID** | Right-click channel name > View channel details > scroll to bottom |
| **Your User ID** | Click your profile picture > Profile > three dots menu > Copy member ID. This is **your** user ID, not the bot's -- it controls who is authorized to click action buttons (Approve, Retry, etc.) |

### 9. Configure

Add the Slack settings to your config file. If you already have a `config.env` (e.g., with Discord settings), **append** these lines -- do not overwrite the file.

Open the file directly on your machine:

```bash
mkdir -p ~/agent-infra
nano ~/agent-infra/config.env
```

Add:

```bash
# Slack Bot
AGENT_SLACK_BOT_TOKEN="xoxb-your-bot-token"
AGENT_SLACK_APP_TOKEN="xapp-your-app-token"
AGENT_SLACK_CHANNEL_ID="C0123456789"
AGENT_SLACK_ALLOWED_USERS="U0123456789"  # comma-separated for multiple
AGENT_DISPATCH_REPO="owner/repo"
```

> **Security note:** Paste tokens directly into the config file on your machine. Do not share tokens via chat, email, or other channels where they could be logged or cached.

### 10. Install and Start

```bash
cd slack-bot
./install.sh
```

When prompted, enter the path to your config (e.g., `/home/youruser/agent-infra/config.env`). For non-interactive installs, pass `--config`:

```bash
./install.sh --config ~/agent-infra/config.env
```

Then start:

```bash
systemctl --user start sandbox-pal-dispatch-slack
```

### 11. Verify

Check the service status:

```bash
systemctl --user status sandbox-pal-dispatch-slack
```

Send a test notification:

```bash
curl -X POST http://127.0.0.1:8676/notify \
  -H "Content-Type: application/json" \
  -d '{"event_type":"plan_posted","title":"Test notification","url":"https://github.com","description":"Testing the bot","issue_number":0,"repo":"test/repo"}'
```

You should see a notification with buttons in your Slack channel.

## Managing the Bot

```bash
# Start
systemctl --user start sandbox-pal-dispatch-slack

# Stop
systemctl --user stop sandbox-pal-dispatch-slack

# Restart (after config changes)
systemctl --user restart sandbox-pal-dispatch-slack

# View logs
journalctl --user -u sandbox-pal-dispatch-slack -f

# Disable auto-start
systemctl --user disable sandbox-pal-dispatch-slack
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
| `/agent-approve <issue>` | Approve a plan |
| `/agent-reject <issue> [reason]` | Reject with optional reason |
| `/agent-comment <issue> <text>` | Post feedback |
| `/agent-status <issue>` | Check current agent labels |
| `/agent-retry <issue>` | Re-trigger agent |

## Ports

The Slack bot listens on `127.0.0.1:8676` by default. If you're also running the Discord bot (port 8675), both can run simultaneously without conflict.

To change the Slack bot port, set `AGENT_SLACK_BOT_PORT` in your `config.env`:

```bash
AGENT_SLACK_BOT_PORT="8677"
```

## Troubleshooting

### Bot connects but no notifications appear

- Check that `AGENT_SLACK_CHANNEL_ID` is set correctly
- Verify the bot is invited to the channel -- type `/invite @YourBotName` in the channel
- Check the HTTP listener: `curl -s http://127.0.0.1:8676/notify` should not return "connection refused"

### Buttons don't respond

- Verify your Slack User ID is in `AGENT_SLACK_ALLOWED_USERS`
- Check the bot logs: `journalctl --user -u sandbox-pal-dispatch-slack -f`
- Ensure **Interactivity** is enabled in the Slack app settings

### Slash commands not found

- Verify the commands are created in the Slack app settings
- Ensure Socket Mode is enabled
- Try reinstalling the app to your workspace

## Privacy

This bot processes Slack button clicks, modal submissions, and slash commands to manage GitHub issues. No user data is collected or stored beyond operational logs.
