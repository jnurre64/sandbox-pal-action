from dispatch_bot.auth import is_authorized_check


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
        # Secure-by-default: empty config denies everyone
        assert not is_authorized_check(
            user_id="123", role_ids=[], allowed_users=set(), allowed_role=""
        )

    def test_user_id_or_role_either_works(self):
        assert is_authorized_check(
            user_id="123", role_ids=["999"], allowed_users={"123"}, allowed_role="888"
        )
