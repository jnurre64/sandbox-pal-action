import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from bot import create_notify_handler


@pytest.fixture
def mock_channel():
    channel = AsyncMock()
    channel.send = AsyncMock()
    return channel


@pytest.fixture
def mock_bot(mock_channel):
    bot = MagicMock()
    bot.get_channel = MagicMock(return_value=mock_channel)
    return bot


@pytest.fixture
def handler(mock_bot):
    return create_notify_handler(mock_bot)


@pytest.fixture
def make_request():
    def _make(data: dict):
        request = AsyncMock()
        request.json = AsyncMock(return_value=data)
        return request
    return _make


VALID_PAYLOAD = {
    "event_type": "plan_posted",
    "title": "Add caching",
    "url": "https://github.com/org/repo/issues/42",
    "description": "Plan summary here",
    "issue_number": 42,
    "repo": "org/repo",
}


class TestNotifyHandler:
    @pytest.mark.asyncio
    async def test_sends_embed_to_channel(self, handler, mock_channel, make_request):
        request = make_request(VALID_PAYLOAD)
        response = await handler(request)
        assert response.status == 200
        mock_channel.send.assert_called_once()

    @pytest.mark.asyncio
    async def test_embed_has_correct_title(self, handler, mock_channel, make_request):
        request = make_request(VALID_PAYLOAD)
        await handler(request)
        call_kwargs = mock_channel.send.call_args
        embed = call_kwargs.kwargs["embed"]
        assert "#42" in embed.title
        assert "Add caching" in embed.title

    @pytest.mark.asyncio
    async def test_sends_buttons(self, handler, mock_channel, make_request):
        request = make_request(VALID_PAYLOAD)
        await handler(request)
        call_kwargs = mock_channel.send.call_args
        view = call_kwargs.kwargs["view"]
        assert len(view.children) > 1  # View link + action buttons

    @pytest.mark.asyncio
    async def test_buttons_contain_repo_in_custom_id(self, handler, mock_channel, make_request):
        request = make_request(VALID_PAYLOAD)
        await handler(request)
        call_kwargs = mock_channel.send.call_args
        view = call_kwargs.kwargs["view"]
        action_buttons = [b for b in view.children if hasattr(b, "custom_id") and b.custom_id]
        assert len(action_buttons) > 0
        for button in action_buttons:
            assert "org/repo" in button.custom_id

    @pytest.mark.asyncio
    async def test_returns_503_when_channel_not_found(self, make_request):
        bot = MagicMock()
        bot.get_channel = MagicMock(return_value=None)
        handler = create_notify_handler(bot)
        request = make_request(VALID_PAYLOAD)
        response = await handler(request)
        assert response.status == 503

    @pytest.mark.asyncio
    async def test_handles_missing_optional_fields(self, handler, mock_channel, make_request):
        minimal = {"event_type": "tests_passed", "title": "T", "url": "https://x.com", "issue_number": 1, "repo": "r"}
        request = make_request(minimal)
        response = await handler(request)
        assert response.status == 200
