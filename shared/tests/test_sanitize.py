from dispatch_bot.sanitize import sanitize_input


class TestSanitizeInput:
    def test_passes_normal_text(self):
        assert sanitize_input("Please fix the login bug") == "Please fix the login bug"

    def test_removes_backticks(self):
        assert "`" not in sanitize_input("use `rm -rf /`")

    def test_removes_dollar_signs(self):
        assert "$" not in sanitize_input("cost is $100 $(whoami)")

    def test_removes_backslashes(self):
        assert "\\" not in sanitize_input("path\\to\\file")

    def test_truncates_to_2000_chars(self):
        long_text = "x" * 3000
        result = sanitize_input(long_text)
        assert len(result) == 2000

    def test_preserves_markdown_formatting(self):
        text = "**bold** and *italic* and [link](url)"
        assert sanitize_input(text) == text

    def test_preserves_newlines(self):
        text = "line1\nline2\nline3"
        assert sanitize_input(text) == text

    def test_empty_string(self):
        assert sanitize_input("") == ""
