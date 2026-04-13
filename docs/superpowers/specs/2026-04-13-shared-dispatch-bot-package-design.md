# Shared `dispatch_bot` Package — Design

**Issue:** #40 (Phase 1 of #19)
**Status:** Design approved, ready for implementation plan
**Date:** 2026-04-13

## Summary

Extract shared bot logic from `discord-bot/bot.py` into a new `shared/dispatch_bot/` Python package. Refactor the Discord bot to import from it. This is Phase 1 of the Slack integration (#19), isolated so the refactor ships on its own, behind a green test suite, before any Slack code is added.

## Motivation

The Slack bot (Phase 2 of #19) will reuse the Discord bot's logic for `gh` CLI calls, authorization, input sanitization, the local HTTP listener, and event metadata. Duplicating that logic would violate DRY and force every future change to be made in two places.

Landing the extraction first means the refactor is reviewed and merged on its own merits, rather than buried in a larger Slack-feature diff.

## Architecture

```
shared/
├── pyproject.toml                  # declares dispatch_bot package
├── dispatch_bot/
│   ├── __init__.py
│   ├── github.py                   # gh CLI wrappers
│   ├── auth.py                     # user/role authorization
│   ├── sanitize.py                 # shell-safe input stripping
│   ├── http_listener.py            # aiohttp POST /notify server factory
│   └── events.py                   # event catalog (labels, indicators, sets)
└── tests/
    ├── test_github.py
    ├── test_auth.py
    ├── test_sanitize.py
    ├── test_http_listener.py
    └── test_events.py

discord-bot/
├── bot.py                          # imports from dispatch_bot.*
├── requirements.txt                # adds: -e ../shared
└── tests/                          # import statements updated, assertions unchanged
```

## Module Breakdown

### `shared/dispatch_bot/github.py`

Pure `gh` CLI wrappers. No Discord or Slack dependencies.

- `gh_command(args: list[str]) -> tuple[bool, str]`
- `gh_dispatch(repo: str, event_type: str, issue_number: int) -> tuple[bool, str]`
- `ALL_AGENT_LABELS: list[str]` — the full agent label set used by retry flows (promoted from `_ALL_AGENT_LABELS`)

### `shared/dispatch_bot/auth.py`

- `is_authorized_check(user_id, role_ids, allowed_users, allowed_role) -> bool`

Names preserved from the existing function to minimize diff. Slack (Phase 2) will call with its user-group IDs mapped into the `role_ids` argument — a rename to `group_ids`/`allowed_group` can happen in Phase 2 if the asymmetry becomes awkward. YAGNI for now.

### `shared/dispatch_bot/sanitize.py`

- `sanitize_input(text: str) -> str` — strips `` ` $ \ ``, caps length at 2000

Identical behavior to the current function.

### `shared/dispatch_bot/events.py`

Platform-agnostic event metadata:

- `EVENT_LABELS: dict[str, str]`
- `EVENT_INDICATORS: dict[str, str]` (the `[OK]` / `[FAIL]` / `[INFO]` / `[ACTION]` text tags — reusable across platforms)
- `PLAN_EVENTS: set[str]` (promoted from `_PLAN_EVENTS`)
- `RETRY_EVENTS: set[str]` (promoted from `_RETRY_EVENTS`)

**Not in this file:** `EVENT_COLORS` stays in `discord-bot/bot.py`. Discord embed colors are hex integers (`0x57F287`) — Slack uses a different color model (named colors in Block Kit attachments, or attachment-level `color` hex strings). Keeping them platform-local avoids premature abstraction. A severity layer can be added in Phase 2 if duplication becomes painful.

### `shared/dispatch_bot/http_listener.py`

Factors the aiohttp boilerplate out of the Discord bot. Each bot provides its own request handler (which knows how to format and send to its platform):

```python
async def start_http_server(
    handler: Callable[[web.Request], Awaitable[web.Response]],
    port: int,
    host: str = "127.0.0.1",
) -> web.AppRunner:
    ...
```

The Discord bot's `create_notify_handler(bot)` closure returns a `handler` that is passed into this factory. The aiohttp `AppRunner` lifecycle (setup, `TCPSite`, cleanup) lives in the shared module.

## What Stays in `discord-bot/bot.py`

All Discord-specific concerns:

- `EVENT_COLORS` — Discord embed color format
- `parse_custom_id` — Discord component `custom_id` parsing (format is bot-internal)
- `build_embed`, `build_buttons` — return `discord.Embed` / `discord.ui.View`
- `FeedbackModal` — Discord UI modal
- `handle_button_interaction` — uses `discord.Interaction` objects
- `create_notify_handler(bot)` — closure over the Discord bot instance; calls `channel.send(...)`. It delegates HTTP-server plumbing to `dispatch_bot.http_listener.start_http_server`.
- `DispatchBot` class

## Dependency Mechanism

Editable install: `pip install -e ../shared` (declared as a line in `discord-bot/requirements.txt`).

Rationale:

- Standard approach for local multi-package Python development
- Changes to `shared/` reflect immediately without reinstall
- Clean import semantics (`from dispatch_bot.auth import is_authorized_check`) vs. `sys.path` hacks
- PEP 420 namespace packages evaluated and rejected — experimental in editable mode, known issues when `__init__.py` is present

`shared/pyproject.toml`:

```toml
[project]
name = "dispatch_bot"
version = "0.1.0"
requires-python = ">=3.10"

[tool.setuptools.packages.find]
where = ["."]
include = ["dispatch_bot*"]
```

## Testing

### Existing `discord-bot/tests/` (updated in place)

- `test_utils.py` — update imports: `from dispatch_bot.sanitize import sanitize_input`, `from dispatch_bot.auth import is_authorized_check`. `parse_custom_id` still imports from `bot`.
- `test_embeds.py` — `build_embed` / `build_buttons` / `EVENT_COLORS` still import from `bot`. `EVENT_LABELS` / `EVENT_INDICATORS` imports may shift to `dispatch_bot.events`.
- `test_interactions.py` — `gh_command`, `gh_dispatch` imports shift to `dispatch_bot.github`; patching targets update from `bot.subprocess.run` / `bot.gh_command` to `dispatch_bot.github.subprocess.run` / `dispatch_bot.github.gh_command` (and wherever `handle_button_interaction` references them). Assertions unchanged.
- `test_http.py` — `create_notify_handler` imports from `bot`. Assertions unchanged.

### New `shared/tests/`

- `test_github.py` — mocks `subprocess.run`; covers success, nonzero exit, timeout. Mirrors existing coverage for `gh_command` and `gh_dispatch`.
- `test_auth.py` — mirrors existing `TestIsAuthorizedCheck` cases (user-in-list, role match, neither configured, combined).
- `test_sanitize.py` — mirrors existing `TestSanitizeInput` cases.
- `test_events.py` — sanity checks: every `PLAN_EVENTS` / `RETRY_EVENTS` entry has a matching `EVENT_LABELS` and `EVENT_INDICATORS` entry; no overlap between `PLAN_EVENTS` and `RETRY_EVENTS`.
- `test_http_listener.py` — starts a real aiohttp app on an ephemeral port via `start_http_server`, POSTs to it with a fake payload, asserts the provided handler is invoked and its response is returned. Uses `aiohttp`'s test client where possible.

### Existing BATS suite

- `./tests/bats/bin/bats tests/` — unchanged, still passing. Bash side is untouched in this phase.

### Static checks

- `shellcheck scripts/*.sh scripts/lib/*.sh` — unchanged, still passing.

## Install & Deployment

- `discord-bot/install.sh` — no code change needed. `pip install -r requirements.txt` will honor the `-e ../shared` line because pip runs the install from within `discord-bot/` (the `SCRIPT_DIR`). Manually verify by running the script in a clean venv during the acceptance smoke test.
- `agent-dispatch-bot.service` — no change. `WorkingDirectory` is `discord-bot/`; editable install places `.egg-link` in the venv's site-packages, so `from dispatch_bot...` resolves regardless of CWD.
- CI — `.github/workflows/ci.yml` currently runs ShellCheck and BATS only; Python tests are not in CI today. This refactor does not add Python tests to CI (out of scope). Python tests are run locally by contributors; any future CI job that runs them will need to `pip install -e shared/` before invoking pytest in `discord-bot/`.

## Acceptance Criteria

- [ ] `shared/pyproject.toml` exists; `pip install -e shared/` from repo root succeeds
- [ ] Five shared modules exist, each with a single, focused responsibility
- [ ] `discord-bot/bot.py` imports from `dispatch_bot.*`; no duplicated logic remains
- [ ] All pre-existing Discord bot tests pass; only import statements changed
- [ ] `shared/tests/` pytest suite covers all five shared modules and passes
- [ ] `discord-bot/requirements.txt` contains `-e ../shared`
- [ ] Running `discord-bot/install.sh` in a clean venv produces a working installation
- [ ] systemd service starts cleanly; Discord bot's runtime behavior is identical to pre-refactor
- [ ] `shellcheck scripts/*.sh scripts/lib/*.sh` passes with zero warnings
- [ ] BATS suite (`./tests/bats/bin/bats tests/`) passes

## Out of Scope

Deferred to Phase 2 / Phase 3 of #19:

- Any Slack code (no `slack-bot/` directory, no `slack-bolt` dependency)
- Any changes to `scripts/lib/notify.sh` routing — Bash side untouched
- Any new configuration variables
- Any severity abstraction in `events.py` (YAGNI until Slack needs it)
- Any auth function renames (`role_ids` → `group_ids`)
- Documentation changes beyond updating `discord-bot/README.md` if install steps change (they should not)

## Design Principles

- **SRP**: one responsibility per shared module
- **DRY**: shared logic extracted once, zero duplication between bots
- **KISS**: plain functions and imports, no abstract base classes, no plugin registries
- **Behavioral parity**: Discord bot functions identically before and after this refactor
- **YAGNI**: no speculative abstractions for Phase 2; severity layer and name changes deferred until a second consumer exists

## Security Notes

No new attack surface is introduced by this refactor. Existing properties preserved:

- Subprocess calls use list args (no `shell=True`) — immune to shell injection
- `repo` parsed from button `custom_id` is trusted because only authorized users can press buttons; authorization check precedes the `gh` call
- `sanitize_input` strips `` ` $ \ `` and caps at 2000 chars — unchanged
- Local HTTP listener continues to bind only to `127.0.0.1`
- No new network surface, no new config variables, no new secrets
