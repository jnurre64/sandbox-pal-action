import json
import logging
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import bot as bot_module
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
def handler(mock_bot, monkeypatch):
    # Default CHANNEL_ID so tests that don't exercise routing get a channel.
    monkeypatch.setattr(bot_module, "CHANNEL_ID", 12345)
    monkeypatch.setattr(bot_module, "CHANNEL_MAP", {})
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
    async def test_returns_503_when_channel_not_found(self, monkeypatch, make_request):
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 12345)
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {})
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

    @pytest.mark.asyncio
    async def test_empty_url_returns_200_and_sends(self, handler, mock_channel, make_request):
        # A payload with url="" used to trigger Discord's 50035 rejection on the
        # link button and bubble up as a 500. The handler should now succeed and
        # the message should be sent without a View link.
        request = make_request({**VALID_PAYLOAD, "url": ""})
        response = await handler(request)
        assert response.status == 200
        mock_channel.send.assert_called_once()
        view = mock_channel.send.call_args.kwargs["view"]
        link_buttons = [c for c in view.children if getattr(c, "url", None)]
        assert link_buttons == []


class TestPerRepoChannelRouting:
    @pytest.mark.asyncio
    async def test_routes_to_mapped_channel_when_repo_matches(
        self, monkeypatch, mock_bot, mock_channel, make_request
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"org/repo": "999"})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 111)
        handler = create_notify_handler(mock_bot)
        await handler(make_request(VALID_PAYLOAD))
        mock_bot.get_channel.assert_called_with(999)

    @pytest.mark.asyncio
    async def test_falls_back_to_default_when_repo_not_in_map(
        self, monkeypatch, mock_bot, mock_channel, make_request
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"other/repo": "999"})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 111)
        handler = create_notify_handler(mock_bot)
        await handler(make_request(VALID_PAYLOAD))
        mock_bot.get_channel.assert_called_with(111)

    @pytest.mark.asyncio
    async def test_returns_200_when_repo_explicitly_muted(
        self, monkeypatch, mock_bot, mock_channel, make_request
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"org/repo": ""})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 111)
        handler = create_notify_handler(mock_bot)
        response = await handler(make_request(VALID_PAYLOAD))
        assert response.status == 200
        mock_channel.send.assert_not_called()

    @pytest.mark.asyncio
    async def test_returns_200_when_repo_unmapped_and_no_default(
        self, monkeypatch, mock_bot, mock_channel, make_request
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"other/repo": "999"})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 0)
        handler = create_notify_handler(mock_bot)
        response = await handler(make_request(VALID_PAYLOAD))
        assert response.status == 200
        mock_channel.send.assert_not_called()

    @pytest.mark.asyncio
    async def test_multiple_repos_route_to_different_channels(
        self, monkeypatch, mock_bot, mock_channel, make_request
    ):
        monkeypatch.setattr(
            bot_module,
            "CHANNEL_MAP",
            {"org/repo-a": "111", "org/repo-b": "222"},
        )
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 0)
        handler = create_notify_handler(mock_bot)
        await handler(make_request({**VALID_PAYLOAD, "repo": "org/repo-a"}))
        await handler(make_request({**VALID_PAYLOAD, "repo": "org/repo-b"}))
        calls = [c.args[0] for c in mock_bot.get_channel.call_args_list]
        assert 111 in calls
        assert 222 in calls

    @pytest.mark.asyncio
    async def test_info_log_emitted_with_match_direct(
        self, monkeypatch, mock_bot, mock_channel, make_request, caplog
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"org/repo": "999"})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 111)
        handler = create_notify_handler(mock_bot)
        with caplog.at_level(logging.INFO, logger="dispatch-bot"):
            await handler(make_request(VALID_PAYLOAD))
        assert any("match=direct" in r.message for r in caplog.records)
        assert any("repo=org/repo" in r.message for r in caplog.records)

    @pytest.mark.asyncio
    async def test_info_log_emitted_with_match_fallback(
        self, monkeypatch, mock_bot, mock_channel, make_request, caplog
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"other/repo": "999"})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 111)
        handler = create_notify_handler(mock_bot)
        with caplog.at_level(logging.INFO, logger="dispatch-bot"):
            await handler(make_request(VALID_PAYLOAD))
        assert any("match=fallback" in r.message for r in caplog.records)

    @pytest.mark.asyncio
    async def test_info_log_emitted_with_match_muted(
        self, monkeypatch, mock_bot, mock_channel, make_request, caplog
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"org/repo": ""})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 111)
        handler = create_notify_handler(mock_bot)
        with caplog.at_level(logging.INFO, logger="dispatch-bot"):
            await handler(make_request(VALID_PAYLOAD))
        assert any("match=muted" in r.message for r in caplog.records)

    @pytest.mark.asyncio
    async def test_info_log_emitted_with_match_dropped(
        self, monkeypatch, mock_bot, mock_channel, make_request, caplog
    ):
        monkeypatch.setattr(bot_module, "CHANNEL_MAP", {"other/repo": "999"})
        monkeypatch.setattr(bot_module, "CHANNEL_ID", 0)
        handler = create_notify_handler(mock_bot)
        with caplog.at_level(logging.INFO, logger="dispatch-bot"):
            await handler(make_request(VALID_PAYLOAD))
        assert any("match=dropped" in r.message for r in caplog.records)
