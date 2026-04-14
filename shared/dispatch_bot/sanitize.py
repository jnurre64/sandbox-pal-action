"""Input sanitization for bot-facing user text."""

import re


def sanitize_input(text: str) -> str:
    """Remove shell-dangerous characters from user input and cap length."""
    return re.sub(r"[`$\\]", "", text)[:2000]
