from bot import sanitize_input, parse_custom_id, is_authorized_check


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


class TestParseCustomId:
    def test_approve(self):
        action, issue = parse_custom_id("approve:42")
        assert action == "approve"
        assert issue == 42

    def test_changes(self):
        action, issue = parse_custom_id("changes:7")
        assert action == "changes"
        assert issue == 7

    def test_comment(self):
        action, issue = parse_custom_id("comment:123")
        assert action == "comment"
        assert issue == 123

    def test_retry(self):
        action, issue = parse_custom_id("retry:1")
        assert action == "retry"
        assert issue == 1

    def test_invalid_no_colon(self):
        action, issue = parse_custom_id("invalid")
        assert action is None
        assert issue is None

    def test_invalid_non_numeric(self):
        action, issue = parse_custom_id("approve:abc")
        assert action is None
        assert issue is None


class TestIsAuthorizedCheck:
    def test_user_in_allowed_list(self):
        assert is_authorized_check(
            user_id="123", role_ids=[], allowed_users={"123", "456"}, allowed_role=""
        )

    def test_user_not_in_allowed_list(self):
        assert not is_authorized_check(
            user_id="789", role_ids=[], allowed_users={"123", "456"}, allowed_role=""
        )

    def test_user_has_allowed_role(self):
        assert is_authorized_check(
            user_id="789", role_ids=["100", "200"], allowed_users=set(), allowed_role="200"
        )

    def test_user_lacks_allowed_role(self):
        assert not is_authorized_check(
            user_id="789", role_ids=["100"], allowed_users=set(), allowed_role="200"
        )

    def test_no_restrictions_configured(self):
        # If no users or role configured, deny all (secure by default)
        assert not is_authorized_check(
            user_id="123", role_ids=[], allowed_users=set(), allowed_role=""
        )

    def test_user_id_or_role_either_works(self):
        assert is_authorized_check(
            user_id="123", role_ids=["999"], allowed_users={"123"}, allowed_role="888"
        )
