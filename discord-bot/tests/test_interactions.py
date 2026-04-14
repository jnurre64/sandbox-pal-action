import subprocess
from unittest.mock import AsyncMock, MagicMock, patch, PropertyMock

import discord
import pytest

from bot import (
    handle_button_interaction,
    parse_custom_id,
    FeedbackModal,
    ALLOWED_USERS,
    ALLOWED_ROLE,
)
from dispatch_bot.github import gh_command, gh_dispatch


class TestParseCustomId:
    def test_parses_action_repo_issue(self):
        action, repo, issue = parse_custom_id("approve:org/repo:42")
        assert action == "approve"
        assert repo == "org/repo"
        assert issue == 42

    def test_parses_repo_with_hyphens(self):
        action, repo, issue = parse_custom_id("retry:Frightful-Games/recipe-manager-demo:7")
        assert action == "retry"
        assert repo == "Frightful-Games/recipe-manager-demo"
        assert issue == 7

    def test_returns_none_for_old_format(self):
        action, repo, issue = parse_custom_id("approve:42")
        assert action is None
        assert repo is None
        assert issue is None

    def test_returns_none_for_no_colon(self):
        action, repo, issue = parse_custom_id("approve")
        assert action is None
        assert repo is None
        assert issue is None

    def test_returns_none_for_non_numeric_issue(self):
        action, repo, issue = parse_custom_id("approve:org/repo:abc")
        assert action is None
        assert repo is None
        assert issue is None


class TestGhCommand:
    @patch("dispatch_bot.github.subprocess.run")
    def test_calls_gh_with_args(self, mock_run):
        mock_run.return_value = MagicMock(stdout="ok\n", returncode=0)
        result = gh_command(["issue", "edit", "42", "--repo", "org/repo", "--add-label", "agent"])
        mock_run.assert_called_once()
        args = mock_run.call_args[0][0]
        assert args[0] == "gh"
        assert "issue" in args
        assert "42" in args

    @patch("dispatch_bot.github.subprocess.run")
    def test_returns_success_tuple_with_stripped_stdout(self, mock_run):
        mock_run.return_value = MagicMock(stdout="  result  \n", returncode=0)
        ok, output = gh_command(["issue", "view", "1"])
        assert ok is True
        assert output == "result"

    @patch("dispatch_bot.github.subprocess.run")
    def test_handles_timeout(self, mock_run):
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="gh", timeout=30)
        ok, output = gh_command(["issue", "view", "1"])
        assert ok is False
        assert "timed out" in output.lower()

    @patch("dispatch_bot.github.subprocess.run")
    def test_handles_error(self, mock_run):
        mock_run.return_value = MagicMock(stdout="", stderr="not found", returncode=1)
        ok, output = gh_command(["issue", "view", "999"])
        assert ok is False
        assert output == "not found"


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
    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_adds_label(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("approve:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        calls = [str(c) for c in mock_gh.call_args_list]
        combined = " ".join(calls)
        assert "plan-approved" in combined

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_uses_repo_from_custom_id(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("approve:Frightful-Games/recipe-manager-demo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        gh_args = mock_gh.call_args[0][0]
        assert "Frightful-Games/recipe-manager-demo" in gh_args

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_sends_ephemeral_confirmation(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("approve:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        interaction.followup.send.assert_called_once()

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_failure_reports_error(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (False, "gh auth login required")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("approve:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        interaction.followup.send.assert_called_once()
        msg = interaction.followup.send.call_args[0][0]
        assert "Failed" in msg
        # Embed should NOT be updated on failure
        interaction.message.edit.assert_not_called()

    @pytest.mark.asyncio
    async def test_unauthorized_user_rejected(self):
        interaction = _mock_interaction("approve:org/repo:42", user_id="999")
        with patch("bot.ALLOWED_USERS", {"123"}), patch("bot.ALLOWED_ROLE", ""):
            await handle_button_interaction(interaction)
        interaction.response.send_message.assert_called_once()
        call_kwargs = interaction.response.send_message.call_args.kwargs
        assert call_kwargs.get("ephemeral") is True

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_retry_resets_labels(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("retry:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        mock_gh.assert_called_once()
        call_args = mock_gh.call_args[0][0]
        assert "--remove-label" in call_args
        assert "--add-label" in call_args
        assert "agent" in call_args

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_approve_fires_dispatch(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("approve:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        mock_dispatch.assert_called_once_with("org/repo", "agent-implement", 42)

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_retry_fires_dispatch(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        interaction = _mock_interaction("retry:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        mock_dispatch.assert_called_once_with("org/repo", "agent-triage", 42)

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_dispatch_failure_still_shows_success(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (False, "dispatch failed")
        interaction = _mock_interaction("approve:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        # Label succeeded, so Discord UI should still update
        interaction.message.edit.assert_called_once()
        # But warn the user about the dispatch failure
        followup_msg = interaction.followup.send.call_args[0][0]
        assert "trigger" in followup_msg.lower() or "dispatch" in followup_msg.lower()

    @pytest.mark.asyncio
    async def test_changes_shows_modal(self):
        interaction = _mock_interaction("changes:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        interaction.response.send_modal.assert_called_once()

    @pytest.mark.asyncio
    async def test_comment_shows_modal(self):
        interaction = _mock_interaction("comment:org/repo:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        interaction.response.send_modal.assert_called_once()

    @pytest.mark.asyncio
    async def test_ignores_invalid_custom_id(self):
        interaction = _mock_interaction("approve:42", user_id="123")
        with patch("bot.ALLOWED_USERS", {"123"}):
            await handle_button_interaction(interaction)
        # Should silently return without any response
        interaction.response.defer.assert_not_called()
        interaction.response.send_message.assert_not_called()
        interaction.response.send_modal.assert_not_called()


class TestGhDispatch:
    @patch("dispatch_bot.github.gh_command")
    def test_fires_repository_dispatch(self, mock_gh):
        mock_gh.return_value = (True, "")
        gh_dispatch("org/repo", "agent-implement", 42)
        mock_gh.assert_called_once()
        args = mock_gh.call_args[0][0]
        assert args[0] == "api"
        assert "repos/org/repo/dispatches" in args[1]

    @patch("dispatch_bot.github.gh_command")
    def test_passes_event_type_and_issue_number(self, mock_gh):
        mock_gh.return_value = (True, "")
        gh_dispatch("org/repo", "agent-triage", 7)
        args = mock_gh.call_args[0][0]
        assert "event_type=agent-triage" in " ".join(args)
        assert "client_payload[issue_number]=7" in " ".join(args)

    @patch("dispatch_bot.github.gh_command")
    def test_returns_gh_command_result(self, mock_gh):
        mock_gh.return_value = (False, "not found")
        ok, err = gh_dispatch("org/repo", "agent-implement", 1)
        assert ok is False
        assert err == "not found"


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

    @patch("bot.gh_dispatch")
    @patch("bot.gh_command")
    @pytest.mark.asyncio
    async def test_on_submit_fires_reply_dispatch(self, mock_gh, mock_dispatch):
        mock_gh.return_value = (True, "")
        mock_dispatch.return_value = (True, "")
        modal = FeedbackModal(action="comment", issue_number=42, repo="org/repo")
        interaction = AsyncMock(spec=discord.Interaction)
        interaction.response = AsyncMock()
        interaction.followup = AsyncMock()
        interaction.message = AsyncMock()
        interaction.message.embeds = [discord.Embed(title="Test")]
        interaction.user = MagicMock()
        interaction.user.display_name = "jonny"
        interaction.user.id = 123
        modal.feedback = MagicMock()
        modal.feedback.value = "This looks good but needs more tests"
        await modal.on_submit(interaction)
        mock_dispatch.assert_called_once_with("org/repo", "agent-reply", 42)
