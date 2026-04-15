from unittest.mock import AsyncMock, patch

import pytest

from bot import handle_approve, handle_retry, handle_changes, handle_comment, handle_feedback_submit, handle_view_link


def _make_body(action_id: str, value: str, user_id: str = "U123"):
    """Build a mock Slack action body for button clicks."""
    return {
        "user": {"id": user_id},
        "channel": {"id": "C456"},
        "actions": [{"action_id": action_id, "value": value}],
        "message": {
            "ts": "123.456",
            "text": "fallback",
            "attachments": [{
                "color": "#3498DB",
                "blocks": [
                    {"type": "section", "text": {"type": "mrkdwn", "text": "*title*"}},
                    {"type": "actions", "elements": [
                        {"type": "button", "text": {"type": "plain_text", "text": "View"}, "url": "https://example.com", "action_id": "view_link"},
                        {"type": "button", "text": {"type": "plain_text", "text": "Approve"}, "action_id": "approve", "value": value, "style": "primary"},
                    ]},
                    {"type": "context", "elements": [{"type": "mrkdwn", "text": "footer"}]},
                ],
            }],
        },
    }


class TestHandleApprove:
    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_approve_adds_label(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        ack.assert_called_once()
        args = mock_gh.call_args[0][0]
        assert "agent:plan-approved" in args
        assert "--remove-label" in args

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_approve_uses_repo_from_value(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "Frightful-Games/demo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        args = mock_gh.call_args[0][0]
        assert "Frightful-Games/demo" in args

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_approve_updates_message(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        client.chat_update.assert_called_once()
        call_kwargs = client.chat_update.call_args.kwargs
        assert call_kwargs["ts"] == "123.456"
        assert call_kwargs["channel"] == "C456"

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_approve_sends_ephemeral_confirmation(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        client.chat_postEphemeral.assert_called()
        call_kwargs = client.chat_postEphemeral.call_args.kwargs
        assert "Done" in call_kwargs["text"]

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(False, "gh auth login required"))
    @pytest.mark.asyncio
    async def test_approve_failure_reports_error(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        client.chat_postEphemeral.assert_called_once()
        assert "Failed" in client.chat_postEphemeral.call_args.kwargs["text"]
        client.chat_update.assert_not_called()

    @pytest.mark.asyncio
    async def test_unauthorized_user_rejected(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42", user_id="U999")
        with patch("bot.ALLOWED_USERS", {"U123"}), patch("bot.ALLOWED_GROUP", ""):
            await handle_approve(ack=ack, body=body, client=client)
        client.chat_postEphemeral.assert_called_once()
        assert "permission" in client.chat_postEphemeral.call_args.kwargs["text"].lower()

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_approve_fires_dispatch(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        mock_dispatch.assert_called_once_with("org/repo", "agent-implement", 42)

    @patch("bot.gh_dispatch", return_value=(False, "dispatch failed"))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_dispatch_failure_warns_in_ephemeral(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("approve", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_approve(ack=ack, body=body, client=client)
        client.chat_update.assert_called_once()
        text = client.chat_postEphemeral.call_args.kwargs["text"]
        assert "trigger" in text.lower() or "warning" in text.lower()


class TestHandleRetry:
    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_retry_resets_labels(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("retry", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_retry(ack=ack, body=body, client=client)
        args = mock_gh.call_args[0][0]
        assert "--remove-label" in args
        assert "--add-label" in args
        assert "agent" in args

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_retry_fires_triage_dispatch(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("retry", "org/repo:42")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_retry(ack=ack, body=body, client=client)
        mock_dispatch.assert_called_once_with("org/repo", "agent-triage", 42)

    @pytest.mark.asyncio
    async def test_retry_unauthorized_rejected(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("retry", "org/repo:42", user_id="U999")
        with patch("bot.ALLOWED_USERS", {"U123"}), patch("bot.ALLOWED_GROUP", ""):
            await handle_retry(ack=ack, body=body, client=client)
        client.chat_postEphemeral.assert_called_once()
        assert "permission" in client.chat_postEphemeral.call_args.kwargs["text"].lower()


class TestHandleChanges:
    @pytest.mark.asyncio
    async def test_opens_modal_with_trigger_id(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("changes", "org/repo:42")
        body["trigger_id"] = "T123"
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_changes(ack=ack, body=body, client=client)
        ack.assert_called_once()
        client.views_open.assert_called_once()
        call_kwargs = client.views_open.call_args.kwargs
        assert call_kwargs["trigger_id"] == "T123"

    @pytest.mark.asyncio
    async def test_modal_has_feedback_input(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("changes", "org/repo:42")
        body["trigger_id"] = "T123"
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_changes(ack=ack, body=body, client=client)
        view = client.views_open.call_args.kwargs["view"]
        assert view["type"] == "modal"
        assert view["callback_id"] == "feedback_modal"
        assert view["blocks"][0]["block_id"] == "feedback_block"

    @pytest.mark.asyncio
    async def test_modal_metadata_includes_repo_and_issue(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("changes", "org/repo:42")
        body["trigger_id"] = "T123"
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_changes(ack=ack, body=body, client=client)
        view = client.views_open.call_args.kwargs["view"]
        import json
        meta = json.loads(view["private_metadata"])
        assert meta["action"] == "changes"
        assert meta["repo"] == "org/repo"
        assert meta["issue_number"] == 42

    @pytest.mark.asyncio
    async def test_unauthorized_user_rejected(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("changes", "org/repo:42", user_id="U999")
        with patch("bot.ALLOWED_USERS", {"U123"}), patch("bot.ALLOWED_GROUP", ""):
            await handle_changes(ack=ack, body=body, client=client)
        client.views_open.assert_not_called()


class TestHandleComment:
    @pytest.mark.asyncio
    async def test_opens_modal_with_comment_action(self):
        ack, client = AsyncMock(), AsyncMock()
        body = _make_body("comment", "org/repo:42")
        body["trigger_id"] = "T123"
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_comment(ack=ack, body=body, client=client)
        view = client.views_open.call_args.kwargs["view"]
        import json
        meta = json.loads(view["private_metadata"])
        assert meta["action"] == "comment"


class TestHandleViewLink:
    @pytest.mark.asyncio
    async def test_acks_without_error(self):
        ack = AsyncMock()
        await handle_view_link(ack=ack)
        ack.assert_called_once()


class TestHandleFeedbackSubmit:
    def _make_view_body(self, action="changes", feedback_text="Please add more tests to the PR"):
        import json
        return {
            "user": {"id": "U123"},
        }, {
            "private_metadata": json.dumps({
                "action": action,
                "repo": "org/repo",
                "issue_number": 42,
                "channel": "C456",
                "ts": "123.456",
            }),
            "state": {
                "values": {
                    "feedback_block": {
                        "feedback_input": {"value": feedback_text},
                    },
                },
            },
        }

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_posts_comment_to_github(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body, view = self._make_view_body()
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_feedback_submit(ack=ack, body=body, client=client, view=view)
        mock_gh.assert_called_once()
        args = mock_gh.call_args[0][0]
        assert "issue" in args
        assert "comment" in args
        assert "org/repo" in args

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_posts_thread_reply(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body, view = self._make_view_body()
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_feedback_submit(ack=ack, body=body, client=client, view=view)
        client.chat_postMessage.assert_called_once()
        call_kwargs = client.chat_postMessage.call_args.kwargs
        assert call_kwargs["thread_ts"] == "123.456"
        assert call_kwargs["channel"] == "C456"

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_fires_reply_dispatch(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body, view = self._make_view_body()
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_feedback_submit(ack=ack, body=body, client=client, view=view)
        mock_dispatch.assert_called_once_with("org/repo", "agent-reply", 42)

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(False, "API error"))
    @pytest.mark.asyncio
    async def test_gh_failure_posts_ephemeral_error(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body, view = self._make_view_body()
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_feedback_submit(ack=ack, body=body, client=client, view=view)
        client.chat_postEphemeral.assert_called_once()
        assert "Failed" in client.chat_postEphemeral.call_args.kwargs["text"]
        client.chat_postMessage.assert_not_called()

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_changes_action_label(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body, view = self._make_view_body(action="changes")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_feedback_submit(ack=ack, body=body, client=client, view=view)
        text = client.chat_postMessage.call_args.kwargs["text"]
        assert "Changes requested" in text

    @patch("bot.gh_dispatch", return_value=(True, ""))
    @patch("bot.gh_command", return_value=(True, ""))
    @pytest.mark.asyncio
    async def test_comment_action_label(self, mock_gh, mock_dispatch):
        ack, client = AsyncMock(), AsyncMock()
        body, view = self._make_view_body(action="comment")
        with patch("bot.ALLOWED_USERS", {"U123"}):
            await handle_feedback_submit(ack=ack, body=body, client=client, view=view)
        text = client.chat_postMessage.call_args.kwargs["text"]
        assert "Comment posted" in text
