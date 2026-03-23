import subprocess
from unittest.mock import AsyncMock, MagicMock, patch, PropertyMock

import discord
import pytest

from bot import (
    gh_command,
    handle_button_interaction,
    FeedbackModal,
    ALLOWED_USERS,
    ALLOWED_ROLE,
)


class TestGhCommand:
    @patch("bot.subprocess.run")
    def test_calls_gh_with_args(self, mock_run):
        mock_run.return_value = MagicMock(stdout="ok\n", returncode=0)
        result = gh_command(["issue", "edit", "42", "--repo", "org/repo", "--add-label", "agent"])
        mock_run.assert_called_once()
        args = mock_run.call_args[0][0]
        assert args[0] == "gh"
        assert "issue" in args
        assert "42" in args

    @patch("bot.subprocess.run")
    def test_returns_stdout_stripped(self, mock_run):
        mock_run.return_value = MagicMock(stdout="  result  \n", returncode=0)
        assert gh_command(["issue", "view", "1"]) == "result"

    @patch("bot.subprocess.run")
    def test_handles_timeout(self, mock_run):
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="gh", timeout=30)
        result = gh_command(["issue", "view", "1"])
        assert "timed out" in result.lower()

    @patch("bot.subprocess.run")
    def test_handles_error(self, mock_run):
        mock_run.return_value = MagicMock(stdout="", stderr="not found", returncode=1)
        result = gh_command(["issue", "view", "999"])
        assert isinstance(result, str)


def _mock_interaction(custom_id: str, user_id: str = "123", role_ids=None, display_name: str = "jonny"):
    """Build a mock Discord interaction for button clicks."""
    interaction = AsyncMock(spec=discord.Interaction)
    interaction.data = {"custom_id": custom_id}
    interaction.user = MagicMock()
    interaction.user.id = int(user_id)
    interaction.user.display_name = display_name
    interaction.user.roles = [MagicMock(id=int(r)) for r in (role_ids or [])]
    interaction.response = AsyncMock()
    interaction.followup = AsyncMock()
    interaction.message = AsyncMock()
    interaction.message.embeds = [discord.Embed(title="Test")]
    interaction.message.components = []
    return interaction


class TestHandleButtonInteraction:
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_adds_label(self, mock_gh):
        mock_gh.return_value = ""
        interaction = _mock_interaction("approve:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}), patch("bot.REPO", "org/repo"):
            await handle_button_interaction(interaction)
        calls = [str(c) for c in mock_gh.call_args_list]
        combined = " ".join(calls)
        assert "plan-approved" in combined

    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_sends_ephemeral_confirmation(self, mock_gh):
        mock_gh.return_value = ""
        interaction = _mock_interaction("approve:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}), patch("bot.REPO", "org/repo"):
            await handle_button_interaction(interaction)
        interaction.followup.send.assert_called_once()

    @pytest.mark.asyncio
    async def test_unauthorized_user_rejected(self):
        interaction = _mock_interaction("approve:42", user_id="999")
        with patch("bot.ALLOWED_USERS", {"123"}), patch("bot.ALLOWED_ROLE", ""):
            await handle_button_interaction(interaction)
        interaction.response.send_message.assert_called_once()
        call_kwargs = interaction.response.send_message.call_args.kwargs
        assert call_kwargs.get("ephemeral") is True

    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_retry_resets_labels(self, mock_gh):
        mock_gh.return_value = ""
        interaction = _mock_interaction("retry:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}), patch("bot.REPO", "org/repo"):
            await handle_button_interaction(interaction)
        mock_gh.assert_called_once()
        call_args = mock_gh.call_args[0][0]
        assert "--remove-label" in call_args
        assert "--add-label" in call_args
        assert "agent" in call_args

    @pytest.mark.asyncio
    async def test_changes_shows_modal(self):
        interaction = _mock_interaction("changes:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        interaction.response.send_modal.assert_called_once()

    @pytest.mark.asyncio
    async def test_comment_shows_modal(self):
        interaction = _mock_interaction("comment:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        interaction.response.send_modal.assert_called_once()


class TestFeedbackModal:
    def test_modal_title_for_changes(self):
        modal = FeedbackModal(action="changes", issue_number=42, repo="org/repo")
        assert "Request Changes" in modal.title

    def test_modal_title_for_comment(self):
        modal = FeedbackModal(action="comment", issue_number=42, repo="org/repo")
        assert "Comment" in modal.title

    def test_modal_has_text_input(self):
        modal = FeedbackModal(action="comment", issue_number=42, repo="org/repo")
        assert len(modal.children) > 0
