"""Platform-agnostic event catalog for dispatch notifications.

Each event type maps to a human-readable label and a text indicator tag
(e.g. `[OK]`, `[FAIL]`) that bots can use in message titles. Event subsets
(`PLAN_EVENTS`, `RETRY_EVENTS`) declare which events get interactive
buttons for which workflows.
"""

EVENT_LABELS: dict[str, str] = {
    "plan_posted": "Plan Ready",
    "questions_asked": "Questions",
    "implement_started": "Implementation Started",
    "tests_passed": "Tests Passed",
    "tests_failed": "Tests Failed",
    "pr_created": "PR Created",
    "review_feedback": "Review Feedback",
    "review_pushed": "Review Fixes Pushed",
    "agent_failed": "Agent Failed",
}

EVENT_INDICATORS: dict[str, str] = {
    "pr_created": "[OK]",
    "tests_passed": "[OK]",
    "review_pushed": "[OK]",
    "tests_failed": "[FAIL]",
    "agent_failed": "[FAIL]",
    "plan_posted": "[INFO]",
    "questions_asked": "[INFO]",
    "review_feedback": "[ACTION]",
    "implement_started": "[INFO]",
}

PLAN_EVENTS: set[str] = {"plan_posted"}
RETRY_EVENTS: set[str] = {"agent_failed"}
