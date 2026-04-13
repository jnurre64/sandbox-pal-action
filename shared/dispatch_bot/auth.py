"""Authorization checks for bot actions."""


def is_authorized_check(
    user_id: str,
    role_ids: list[str],
    allowed_users: set[str],
    allowed_role: str,
) -> bool:
    """Check if a user is authorized to perform bot actions.

    Secure by default: if neither `allowed_users` nor `allowed_role` is
    configured, all users are denied.
    """
    if not allowed_users and not allowed_role:
        return False
    if user_id in allowed_users:
        return True
    if allowed_role and allowed_role in role_ids:
        return True
    return False
