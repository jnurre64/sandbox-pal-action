"""Regression: dispatch-bot logger must have an effective handler.

Bug: discord-bot/bot.py originally called
    bot.run(BOT_TOKEN, log_handler=logging.StreamHandler(), log_level=logging.INFO)
which configures only discord.py's own loggers via `discord.utils.setup_logging`.
Application loggers (`logging.getLogger("dispatch-bot")`) had no handler attached,
so every `log.info(...)` from the notify handler and action handlers was dropped
silently. This made routing decisions invisible in journald.

Fix: call `logging.basicConfig` in `_setup_logging()` before `bot.run`.
"""

import logging

import pytest


@pytest.fixture
def isolated_logging():
    """Reset root logger handlers before/after the test so basicConfig actually runs.

    `logging.basicConfig` is a no-op if root already has handlers, so without this
    fixture pytest's own log capture handlers would mask the bug under test.
    """
    root = logging.getLogger()
    saved_handlers = root.handlers[:]
    saved_level = root.level
    root.handlers.clear()
    try:
        yield
    finally:
        root.handlers.clear()
        for h in saved_handlers:
            root.addHandler(h)
        root.setLevel(saved_level)


def test_setup_logging_attaches_effective_handler_to_dispatch_bot_logger(isolated_logging):
    import bot

    bot._setup_logging()

    log = logging.getLogger("dispatch-bot")
    assert log.hasHandlers(), (
        "dispatch-bot logger has no effective handler — INFO lines from notify "
        "handler and action handlers will be silently dropped"
    )
    assert log.getEffectiveLevel() <= logging.INFO, (
        "dispatch-bot effective log level is above INFO — routing decision lines "
        "will be filtered out"
    )
