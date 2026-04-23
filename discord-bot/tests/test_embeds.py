import discord

from bot import build_embed, build_buttons, EVENT_COLORS


class TestBuildEmbed:
    def test_plan_posted_has_blue_color(self):
        embed = build_embed("plan_posted", "Add caching", "https://github.com/r/1", "Plan here", 42, "org/repo")
        assert embed.color.value == 0x3498DB

    def test_tests_failed_has_red_color(self):
        embed = build_embed("tests_failed", "Fix bug", "https://github.com/r/1", "Failed", 5, "org/repo")
        assert embed.color.value == 0xED4245

    def test_pr_created_has_green_color(self):
        embed = build_embed("pr_created", "Feature X", "https://github.com/r/1", "3 commits", 10, "org/repo")
        assert embed.color.value == 0x57F287

    def test_title_includes_indicator_and_issue_number(self):
        embed = build_embed("plan_posted", "My Issue", "https://example.com", "desc", 42, "org/repo")
        assert "#42" in embed.title
        assert "Plan Ready" in embed.title

    def test_footer_includes_automation_disclosure(self):
        embed = build_embed("plan_posted", "Title", "https://example.com", "desc", 1, "org/repo")
        assert "Automated by sandbox-pal-action" in embed.footer.text

    def test_footer_includes_repo_and_issue(self):
        embed = build_embed("plan_posted", "Title", "https://example.com", "desc", 42, "org/repo")
        assert "org/repo #42" in embed.footer.text

    def test_description_truncated_at_4000(self):
        long_desc = "x" * 5000
        embed = build_embed("plan_posted", "Title", "https://example.com", long_desc, 1, "r")
        assert len(embed.description) <= 4000

    def test_url_set(self):
        embed = build_embed("plan_posted", "Title", "https://example.com/42", "d", 42, "r")
        assert embed.url == "https://example.com/42"

    def test_unknown_event_gets_grey_color(self):
        embed = build_embed("unknown_event", "Title", "https://example.com", "d", 1, "r")
        assert embed.color.value == 0x95A5A6


class TestBuildButtons:
    def test_plan_posted_has_approve_changes_comment(self):
        view = build_buttons("plan_posted", 42, "https://example.com", "org/repo")
        labels = [child.label for child in view.children]
        assert "Approve" in labels
        assert "Request Changes" in labels
        assert "Comment" in labels

    def test_plan_posted_has_view_link(self):
        view = build_buttons("plan_posted", 42, "https://example.com", "org/repo")
        link_buttons = [c for c in view.children if c.url]
        assert len(link_buttons) >= 1
        assert link_buttons[0].url == "https://example.com"

    def test_agent_failed_has_retry(self):
        view = build_buttons("agent_failed", 42, "https://example.com", "org/repo")
        labels = [child.label for child in view.children]
        assert "Retry" in labels

    def test_agent_failed_no_approve(self):
        view = build_buttons("agent_failed", 42, "https://example.com", "org/repo")
        labels = [child.label for child in view.children]
        assert "Approve" not in labels

    def test_tests_passed_view_only(self):
        view = build_buttons("tests_passed", 42, "https://example.com", "org/repo")
        action_buttons = [c for c in view.children if not c.url]
        assert len(action_buttons) == 0

    def test_custom_ids_encode_repo_and_issue(self):
        view = build_buttons("plan_posted", 99, "https://example.com", "org/repo")
        custom_ids = [c.custom_id for c in view.children if c.custom_id]
        assert "approve:org/repo:99" in custom_ids
        assert "changes:org/repo:99" in custom_ids
        assert "comment:org/repo:99" in custom_ids

    def test_review_feedback_has_view_only(self):
        view = build_buttons("review_feedback", 42, "https://example.com", "org/repo")
        action_buttons = [c for c in view.children if not c.url]
        assert len(action_buttons) == 0

    def test_pr_created_has_view_link(self):
        view = build_buttons("pr_created", 42, "https://example.com/pull/5", "org/repo")
        link_buttons = [c for c in view.children if c.url]
        assert any(b.url == "https://example.com/pull/5" for b in link_buttons)
