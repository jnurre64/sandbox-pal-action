# Agent Dispatch Discord Bot

Interactive Discord bot for managing agent work. Adds buttons, slash commands, and modals on top of the webhook notification layer.

## Prerequisites

- Python 3.10+ with `python3-venv` package (on Debian/Ubuntu: `sudo apt install python3.12-venv` or equivalent for your Python version)
- `gh` CLI authenticated with repo access
- A Discord server you have admin access to
- A Discord channel for notifications (can be private)

## Step-by-Step Setup

### 1. Create the Discord Application

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **"New Application"** (top right)
3. Name it (e.g., "Agent Dispatch") and click **Create**

### 2. Configure Installation Settings

Before making the bot private, you need to clear the default install settings:

1. In the left sidebar, click **"Installation"**
2. Set the **Install Link** dropdown to **"None"**

This must be done before step 3, otherwise Discord will show an error: "Private application cannot have a default authorization link."

### 3. Make the Bot Private and Get the Token

1. In the left sidebar, click **"Bot"**
2. Turn off **Public Bot** (only you should be able to invite it)
3. Under **Privileged Gateway Intents**, leave all three **unchecked** (Presence, Server Members, Message Content) -- the bot only uses buttons and slash commands
4. Click **"Reset Token"** and confirm
5. **Copy the token immediately** -- you won't be able to see it again

### 4. Generate the Invite URL

1. In the left sidebar, click **"OAuth2"**
2. Scroll to **"OAuth2 URL Generator"**
3. Under **Scopes**, check:
   - `bot`
   - `applications.commands`
4. A **Bot Permissions** section appears. Check:
   - `View Channels`
   - `Send Messages`
5. Copy the **Generated URL** at the bottom

### 5. Invite the Bot to Your Server

1. Paste the generated URL into your browser
2. Select your Discord server
3. Click **Authorize** and complete any captcha

The bot will appear in your server's member list (offline until started).

### 6. Set Up a Private Channel (Optional)

If you want notifications in a private channel:

1. Create or select a private channel
2. Click the gear icon (Edit Channel) or right-click > **Edit Channel**
3. Go to **Permissions**
4. Click **Add members or roles**
5. Search for your bot's name and add it
6. Ensure it has **View Channel** and **Send Messages** permissions

### 7. Create a Webhook for Fallback

The bot requires a webhook URL as a fallback for when the bot is down:

1. Right-click your notification channel > **Edit Channel**
2. Go to **Integrations** > **Webhooks**
3. Click **New Webhook**
4. Copy the webhook URL

### 8. Get Your Discord IDs

Enable **Developer Mode** if not already on: User Settings > App Settings > Advanced > Developer Mode (toggle on).

Then copy these three IDs:

| ID | How to get it |
|---|---|
| **Server (Guild) ID** | Right-click server name > Copy Server ID |
| **Channel ID** | Right-click notification channel > Copy Channel ID |
| **Your User ID** | Right-click your name in the member list > Copy User ID |

Make sure all three IDs are different values.

### 9. Configure

The bot needs its own config file with Discord-specific settings. Create it:

```bash
mkdir -p ~/agent-infra
nano ~/agent-infra/config.env
```

Add:

```bash
AGENT_DISCORD_BOT_TOKEN="your-bot-token"
AGENT_DISCORD_CHANNEL_ID="your-channel-id"
AGENT_DISCORD_GUILD_ID="your-server-id"
AGENT_DISCORD_ALLOWED_USERS="your-user-id"   # comma-separated for multiple users
AGENT_DISPATCH_REPO="owner/repo"              # GitHub repo for slash commands
AGENT_NOTIFY_BACKEND="bot"
```

Then add the webhook and backend setting to your **project's** `config.env` (e.g., `.sandbox-pal-dispatch/config.env`):

```bash
AGENT_NOTIFY_DISCORD_WEBHOOK="your-webhook-url"
AGENT_NOTIFY_BACKEND="bot"
```

The webhook URL is required even in bot mode -- it serves as a fallback if the bot is unreachable.

### 10. Install and Start

```bash
cd discord-bot
./install.sh
```

When prompted for the config path, enter the path to your bot config (e.g., `/home/youruser/agent-infra/config.env`).

Then start the bot:

```bash
systemctl --user start sandbox-pal-dispatch-bot
```

### 11. Verify

Check the service status:

```bash
systemctl --user status sandbox-pal-dispatch-bot
```

You should see `active (running)`. The bot should show as **online** (green dot) in Discord.

Send a test notification:

```bash
curl -X POST http://127.0.0.1:8675/notify \
  -H "Content-Type: application/json" \
  -d '{"event_type":"plan_posted","title":"Test notification","url":"https://github.com","description":"Testing the bot","issue_number":0,"repo":"test/repo"}'
```

You should see a notification with buttons in your Discord channel.

## Troubleshooting

### `python3-venv` not installed

```
The virtual environment was not created successfully because ensurepip is not available.
```

Install the venv package for your Python version:

```bash
sudo apt install python3.12-venv  # adjust version as needed
```

If a previous install attempt left a broken `.venv` directory, remove it first:

```bash
rm -rf discord-bot/.venv
```

Then re-run `./install.sh`.

### "Privileged message content intent is missing" warning

This warning in the logs is expected and harmless. The bot uses buttons and slash commands only -- it does not read message content.

### Bot is online but no notifications appear

- Check that `AGENT_NOTIFY_BACKEND="bot"` is set in your project's `config.env`
- Check that `AGENT_NOTIFY_DISCORD_WEBHOOK` is also set (required even in bot mode)
- Verify the HTTP listener is running: `curl -s http://127.0.0.1:8675/notify` should return an error (not "connection refused")

### Buttons don't respond

- Verify your Discord User ID is in `AGENT_DISCORD_ALLOWED_USERS`
- Check the bot logs: `journalctl --user -u sandbox-pal-dispatch-bot -f`

## Managing the Bot

```bash
# Start
systemctl --user start sandbox-pal-dispatch-bot

# Stop
systemctl --user stop sandbox-pal-dispatch-bot

# Restart (after config changes)
systemctl --user restart sandbox-pal-dispatch-bot

# View logs
journalctl --user -u sandbox-pal-dispatch-bot -f

# Disable auto-start on login
systemctl --user disable sandbox-pal-dispatch-bot
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
