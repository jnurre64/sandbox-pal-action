"""Local aiohttp HTTP listener factory shared across dispatch bots.

The caller supplies a request handler (which knows how to format and send
notifications to its specific platform) and a port. This module owns the
aiohttp `AppRunner` / `TCPSite` plumbing.
"""

import logging
from typing import Awaitable, Callable

from aiohttp import web

log = logging.getLogger("dispatch-bot")


async def start_http_server(
    handler: Callable[[web.Request], Awaitable[web.Response]],
    port: int,
    host: str = "127.0.0.1",
) -> web.AppRunner:
    """Start a local HTTP server listening on POST /notify.

    Returns the AppRunner so the caller can `await runner.cleanup()` on shutdown.
    """
    app = web.Application()
    app.router.add_post("/notify", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    log.info("HTTP listener on %s:%d", host, port)
    return runner
