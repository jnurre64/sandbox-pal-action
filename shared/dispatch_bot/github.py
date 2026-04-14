"""gh CLI wrappers for bot-initiated GitHub actions."""

import logging
import subprocess

log = logging.getLogger("dispatch-bot")


ALL_AGENT_LABELS: list[str] = [
    "agent:failed",
    "agent:triage",
    "agent:needs-info",
    "agent:ready",
    "agent:in-progress",
    "agent:pr-open",
    "agent:plan-review",
    "agent:plan-approved",
    "agent:revision",
]


def gh_command(args: list[str]) -> tuple[bool, str]:
    """Execute a gh CLI command and return (success, output)."""
    try:
        result = subprocess.run(
            ["gh"] + args, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            log.warning("gh %s failed: %s", " ".join(args[:3]), result.stderr.strip())
            return False, result.stderr.strip()
        return True, result.stdout.strip()
    except subprocess.TimeoutExpired:
        log.error("gh command timed out: %s", " ".join(args[:3]))
        return False, "Error: command timed out"


def gh_dispatch(repo: str, event_type: str, issue_number: int) -> tuple[bool, str]:
    """Fire a repository_dispatch event to trigger a workflow."""
    return gh_command([
        "api", f"repos/{repo}/dispatches",
        "-f", f"event_type={event_type}",
        "-f", f"client_payload[issue_number]={issue_number}",
    ])
