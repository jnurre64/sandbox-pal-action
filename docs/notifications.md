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
- All notifications include an "Automated by sandbox-pal-action" footer

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
   systemctl --user start sandbox-pal-dispatch-bot
   ```

### How It Works

When `AGENT_NOTIFY_BACKEND="bot"`, the dispatch `notify()` function POSTs to the bot's local HTTP API instead of the Discord webhook directly. The bot formats the notification with interactive buttons and sends it to your configured channel.

Button clicks and slash commands translate to `gh` CLI calls -- adding labels, posting comments, and triggering workflows. The full conversation loop works:

1. Agent posts plan -> Discord notification with Approve/Request Changes buttons
2. You click Request Changes -> modal appears -> you type feedback
3. Feedback posted as GitHub comment -> triggers sandbox-pal-reply -> agent re-triages
4. Updated plan notification -> you click Approve
5. Label added -> sandbox-pal-implement triggers -> agent implements -> PR notification

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
   systemctl --user start sandbox-pal-dispatch-slack
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

## Phase 4: Per-Repo Channel Routing

When managing multiple repositories, you often want notifications routed to different channels: one team's work to one channel, another team's to another, and some repos muted on a specific platform. Per-repo channel routing supports this without forcing every repo into every map.

### When to Use

- You manage multiple repos from one dispatch host and want team-specific channels
- You want a repo to notify on Discord but not Slack (or vice versa)
- You want a catch-all default channel but specific overrides for some repos

### Configuration

Four optional env vars, one per backend:

| Variable | Scope |
|---|---|
| `AGENT_DISCORD_CHANNEL_MAP` | Discord bot channel routing |
| `AGENT_SLACK_CHANNEL_MAP` | Slack bot channel routing |
| `AGENT_NOTIFY_DISCORD_WEBHOOK_MAP` | Discord webhook URL routing |
| `AGENT_NOTIFY_SLACK_WEBHOOK_MAP` | Slack webhook URL routing |

> **Required backend tokens.** Each map is only consulted when its backend is active. `AGENT_NOTIFY_BACKEND` must contain the matching token for notifications to reach that platform — configuring a map alone is not enough.
>
> | Desired delivery | Required `AGENT_NOTIFY_BACKEND` tokens |
> |---|---|
> | Discord bot only | `bot` |
> | Slack bot only | `slack` |
> | Discord + Slack bots | `bot,slack` |
> | Discord webhook only | `webhook` |
> | Discord webhook + Slack bot | `webhook,slack` |
>
> Symptom of a missing token: the relevant `*_CHANNEL_MAP` / `*_WEBHOOK_MAP` is set but no notifications appear on that platform, and no log line for that platform is emitted.

**Format:** single line, comma-separated entries, `=` separates key from value:

```bash
AGENT_DISCORD_CHANNEL_MAP="owner/repo-a=123456789,owner/repo-b=987654321,owner/muted-repo="
```

### Lookup Semantics

Each notification resolves the channel for its source repo through three distinct outcomes:

| Map state | Meaning | Behavior |
|---|---|---|
| Repo in map, value present | Explicit channel | Send to mapped channel (`match=direct`) |
| Repo in map, value empty | Explicit mute | Skip silently, no fallback (`match=muted`) |
| Repo **not** in map | No mapping | Use `AGENT_*_CHANNEL_ID` / `AGENT_NOTIFY_*_WEBHOOK` if set (`match=fallback`); skip if not (`match=dropped`) |

The distinction between "explicit mute" and "not in map" is what enables per-platform opt-out without forcing you to enumerate every repo in every map.

### Per-Platform Opt-Out

Each platform's map is independent. You can send a repo to Discord but silence it on Slack:

```bash
AGENT_DISCORD_CHANNEL_MAP="org/internal-tool=123"
AGENT_SLACK_CHANNEL_MAP="org/internal-tool="     # explicit mute on Slack
```

### Worked Example

Three repos (`dodge-the-creeps-demo`, `recipe-manager-demo`, `Webber`). Route all three to their own Discord channels, but only `Webber` to Slack:

```bash
# Discord — each repo to its own channel
AGENT_DISCORD_CHANNEL_MAP="Frightful-Games/dodge-the-creeps-demo=DISCORD_DODGE_ID,Frightful-Games/recipe-manager-demo=DISCORD_RECIPE_ID,Frightful-Games/Webber=DISCORD_WEBBER_ID"

# Slack — only Webber sends; the other two are explicitly muted
AGENT_SLACK_CHANNEL_MAP="Frightful-Games/dodge-the-creeps-demo=,Frightful-Games/recipe-manager-demo=,Frightful-Games/Webber=SLACK_WEBBER_ID"

# Both backends active — each routes independently
AGENT_NOTIFY_BACKEND="bot,slack"

# No defaults — unmapped repos are silently dropped (no catch-all channel)
# AGENT_DISCORD_CHANNEL_ID=""
# AGENT_SLACK_CHANNEL_ID=""
```

### Requirements

After enabling maps, at least one of (default channel, channel map) must be set for each bot you run. Bots now fail at startup with a clear error if both are empty.

### Logging

Every dispatch emits one INFO log line with:

- `repo` — source repository
- `platform` — `discord` or `slack`
- `match_type` — `direct`, `fallback`, `muted`, or `dropped`
- `event_type` — which milestone triggered the notification

Use `match=muted` to answer "why didn't I get this notification?" — a muted dispatch still appears in the log, distinguishing it from misconfiguration.

### Parsing Details

- Whitespace around entries, keys, and values is trimmed
- Split is on the **first** `=` only, so values may contain `=` (useful for URL-like webhook values)
- Malformed entries (no `=`, empty key) are silently skipped
- Match is **exact**: `owner/repo` does **not** match `owner/repo-fork`
