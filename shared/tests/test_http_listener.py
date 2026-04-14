import json

import pytest
from aiohttp import ClientSession, web

from dispatch_bot.http_listener import start_http_server


@pytest.mark.asyncio
async def test_serves_on_given_port_and_invokes_handler(unused_tcp_port):
    received = {}

    async def handler(request: web.Request) -> web.Response:
        received["body"] = await request.json()
        return web.Response(text="OK")

    runner = await start_http_server(handler, port=unused_tcp_port)
    try:
        async with ClientSession() as session:
            async with session.post(
                f"http://127.0.0.1:{unused_tcp_port}/notify",
                data=json.dumps({"event_type": "ping"}),
                headers={"Content-Type": "application/json"},
            ) as resp:
                assert resp.status == 200
                assert (await resp.text()) == "OK"
        assert received["body"] == {"event_type": "ping"}
    finally:
        await runner.cleanup()


@pytest.mark.asyncio
async def test_binds_to_loopback_only(unused_tcp_port):
    async def handler(request: web.Request) -> web.Response:
        return web.Response(text="OK")

    runner = await start_http_server(handler, port=unused_tcp_port)
    try:
        # The runner should have at least one site, and it should be bound to 127.0.0.1
        sites = list(runner.sites)
        assert len(sites) == 1
        # aiohttp's TCPSite stores the host; we verify the factory defaulted correctly
        assert sites[0].name.startswith("http://127.0.0.1:")
    finally:
        await runner.cleanup()
