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

The Discord bot adds interactive buttons and slash commands on top of webhook notifications. Instead of just receiving notifications, you can approve plans, request changes, post feedback, and retry failed agents directly from Discord.

### Setup

1. Create a Discord bot application and invite it to your server -- see `discord-bot/README.md` for detailed steps
2. Add the bot configuration to your `config.env`:

   ```bash
   AGENT_DISCORD_BOT_TOKEN="your-bot-token"
   AGENT_DISCORD_CHANNEL_ID="123456789"
   AGENT_DISCORD_GUILD_ID="987654321"
   AGENT_DISCORD_ALLOWED_USERS="your-discord-user-id"
   AGENT_NOTIFY_BACKEND="bot"
   ```

3. Install and start the bot:

   ```bash
   cd discord-bot && ./install.sh
   systemctl --user start agent-dispatch-bot
   ```

### How It Works

When `AGENT_NOTIFY_BACKEND="bot"`, the dispatch `notify()` function POSTs to the bot's local HTTP API instead of the Discord webhook directly. The bot formats the notification with interactive buttons and sends it to your configured channel.

Button clicks and slash commands translate to `gh` CLI calls -- adding labels, posting comments, and triggering workflows. The full conversation loop works:

1. Agent posts plan -> Discord notification with Approve/Request Changes buttons
2. You click Request Changes -> modal appears -> you type feedback
3. Feedback posted as GitHub comment -> triggers dispatch-reply -> agent re-triages
4. Updated plan notification -> you click Approve
5. Label added -> dispatch-implement triggers -> agent implements -> PR notification

### Fallback

If the bot is unreachable (crashed, restarting), notifications automatically fall back to the Phase 1 webhook. Agent work is never blocked by notification delivery.

### Security

Only users listed in `AGENT_DISCORD_ALLOWED_USERS` or with the role in `AGENT_DISCORD_ALLOWED_ROLE` can click action buttons and use slash commands. View/link buttons work for anyone. Unauthorized clicks get a private rejection message.

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
