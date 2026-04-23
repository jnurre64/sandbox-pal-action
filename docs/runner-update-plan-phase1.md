# Runner Update Plan: Phase 1 (Shared Package Extraction)

## 1. Overview

Phase 1 (PR #41) refactored the Discord bot to extract reusable logic into a
shared Python package at `shared/dispatch_bot/`. The bot's `bot.py` now imports
from this package (`from dispatch_bot.events import ...`, etc.) instead of
defining those functions inline. The bot's `requirements.txt` includes
`-e ../shared` so pip installs the shared package in editable (development)
mode.

**Key risk:** The bot's imports changed. If the shared package is not installed
in the bot's virtualenv, the bot will crash on startup with `ImportError`. The
update procedure below ensures the package is installed and verified before the
bot is restarted.

## 2. Prerequisites

Before starting, confirm the bot is currently running and note the commit you
are updating from (so you can roll back if needed).

```bash
# Confirm the bot service is active
systemctl --user status sandbox-pal-dispatch-bot

# Record the current commit hash
git -C ~/agent-infra rev-parse --short HEAD
```

Write down the short commit hash from the second command. You will need it for
rollback if anything goes wrong.

## 3. Update Steps

### Step 1 — Pull the latest code

```bash
cd ~/agent-infra && git pull origin main
```

Verify the pull completed without merge conflicts. If there are conflicts, do
**not** continue; resolve them first or see the Rollback section.

### Step 2 — Install the shared package in the bot's venv

```bash
cd ~/agent-infra/discord-bot
.venv/bin/pip install -e ../shared
```

This installs (or reinstalls) the `dispatch_bot` package from `shared/` in
editable mode. Editable mode means changes to the source files take effect
immediately without reinstalling.

### Step 3 — Verify imports work

```bash
cd ~/agent-infra/discord-bot
.venv/bin/python -c "from dispatch_bot import events, github, auth, sanitize, http_listener; print('All shared imports OK')"
```

Expected output: `All shared imports OK`

If you see an `ImportError` or `ModuleNotFoundError`, the package was not
installed correctly. Re-run Step 2 and check for errors in pip's output.

### Step 4 — Restart the bot service

```bash
systemctl --user restart sandbox-pal-dispatch-bot
```

### Step 5 — Verify the bot is running

```bash
systemctl --user status sandbox-pal-dispatch-bot
journalctl --user -u sandbox-pal-dispatch-bot --since "2 min ago" --no-pager
```

Check that:
- The service status shows **active (running)**.
- The journal logs show no `ImportError`, `ModuleNotFoundError`, or tracebacks.
- The bot logs its normal startup messages (Discord connection, HTTP listener
  ready on port 8675).

### Step 6 — Verify the HTTP listener is responding

```bash
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8675/notify \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"event_type":"test","title":"Runner update test","url":"","description":"Testing after Phase 1 update"}'
```

Expected: HTTP status `200` (or `204`). If the bot is working, it will log the
test event. A non-2xx response or connection refused means the HTTP listener did
not start; check the journal logs from Step 5 for errors.

## 4. Rollback

If the bot fails to start after updating, roll back to the previous commit.

```bash
# Find the commit you noted in the Prerequisites step, or list recent commits:
git -C ~/agent-infra log --oneline -5

# Check out the previous commit
git -C ~/agent-infra checkout <previous-sha>

# Reinstall the shared package at the old commit's state
cd ~/agent-infra/discord-bot && .venv/bin/pip install -e ../shared

# Restart the bot
systemctl --user restart sandbox-pal-dispatch-bot

# Confirm it recovered
systemctl --user status sandbox-pal-dispatch-bot
```

Replace `<previous-sha>` with the short hash you recorded before pulling.

## 5. Verification Checklist

- [ ] Bot service is **active (running)** (`systemctl --user status sandbox-pal-dispatch-bot`)
- [ ] No `ImportError` in journal logs (`journalctl --user -u sandbox-pal-dispatch-bot --since "5 min ago" --no-pager`)
- [ ] HTTP listener responds on port 8675 (curl test returns 2xx)
- [ ] Shared imports resolve correctly (`from dispatch_bot import ...` prints OK)

## 6. Next Steps

After verification, the demo repos (`recipe-manager-demo`, `dodge-the-creeps-demo`
under the Frightful-Games org) have been updated for the new dispatch
infrastructure. Test issues will be created in those repos. The Discord bot
should display notification embeds with action buttons when the agent processes
those issues, confirming end-to-end functionality.
