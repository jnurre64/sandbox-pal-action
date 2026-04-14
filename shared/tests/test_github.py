import subprocess
from unittest.mock import MagicMock, patch

from dispatch_bot.github import gh_command, gh_dispatch, ALL_AGENT_LABELS


class TestGhCommand:
    @patch("dispatch_bot.github.subprocess.run")
    def test_calls_gh_with_args(self, mock_run):
        mock_run.return_value = MagicMock(stdout="ok\n", returncode=0)
        gh_command(["issue", "edit", "42", "--repo", "org/repo", "--add-label", "agent"])
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


class TestAllAgentLabels:
    def test_contains_core_labels(self):
        assert "agent:failed" in ALL_AGENT_LABELS
        assert "agent:plan-review" in ALL_AGENT_LABELS
        assert "agent:plan-approved" in ALL_AGENT_LABELS

    def test_is_list_of_strings(self):
        assert isinstance(ALL_AGENT_LABELS, list)
        assert all(isinstance(lbl, str) for lbl in ALL_AGENT_LABELS)
