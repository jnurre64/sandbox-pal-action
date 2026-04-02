# Discord Bot

Interactive Discord bot for agent dispatch notifications and control. This is a standalone Python application that runs as a systemd service alongside the dispatch scripts.

## Architecture

`bot.py` runs two services: a Discord bot (discord.py) and a local HTTP API (aiohttp on port 8675). The dispatch scripts send notifications to the HTTP API, and the bot translates them into interactive Discord messages with buttons and slash commands.

## Key Flows

- **Dispatch -> Bot**: `scripts/lib/notify.sh` POSTs to `http://127.0.0.1:8675/notify`
- **Bot -> GitHub**: Button clicks and slash commands call `gh` CLI to add labels or post comments
- **Fallback**: If the bot is unreachable, `notify.sh` falls back to webhook mode

## Development

- Python 3.10+, dependencies in `requirements.txt`
- Tests in `tests/` (pytest)
- Authorization via `AGENT_DISCORD_ALLOWED_USERS` and `AGENT_DISCORD_ALLOWED_ROLE`
- Input sanitization removes shell-dangerous characters (caps at 2000 chars)
