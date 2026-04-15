from bot import build_blocks, build_actions, EVENT_COLORS


class TestBuildBlocks:
    def test_plan_posted_title_includes_indicator_and_label(self):
        blocks = build_blocks("plan_posted", "Add caching", "https://github.com/r/1", "Plan here", 42, "org/repo")
        title_text = blocks[0]["text"]["text"]
        assert "[INFO]" in title_text
        assert "Plan Ready" in title_text

    def test_title_includes_issue_number_as_link(self):
        blocks = build_blocks("plan_posted", "My Issue", "https://example.com", "desc", 42, "org/repo")
        title_text = blocks[0]["text"]["text"]
        assert "#42" in title_text
        assert "<https://example.com|" in title_text

    def test_description_included_as_section(self):
        blocks = build_blocks("plan_posted", "T", "https://x.com", "Plan details here", 1, "r")
        texts = [b["text"]["text"] for b in blocks if b["type"] == "section"]
        assert any("Plan details here" in t for t in texts)

    def test_description_truncated_at_3000(self):
        long_desc = "x" * 4000
        blocks = build_blocks("plan_posted", "T", "https://x.com", long_desc, 1, "r")
        desc_block = [b for b in blocks if b["type"] == "section" and "x" * 100 in b["text"]["text"]][0]
        assert len(desc_block["text"]["text"]) <= 3000

    def test_empty_description_omits_section(self):
        blocks = build_blocks("tests_passed", "T", "https://x.com", "", 1, "r")
        section_blocks = [b for b in blocks if b["type"] == "section"]
        assert len(section_blocks) == 1  # only the title section

    def test_footer_includes_automation_disclosure(self):
        blocks = build_blocks("plan_posted", "T", "https://x.com", "d", 1, "org/repo")
        context = [b for b in blocks if b["type"] == "context"][0]
        assert "Automated by claude-agent-dispatch" in context["elements"][0]["text"]

    def test_footer_includes_repo_and_issue(self):
        blocks = build_blocks("plan_posted", "T", "https://x.com", "d", 42, "org/repo")
        context = [b for b in blocks if b["type"] == "context"][0]
        assert "org/repo #42" in context["elements"][0]["text"]

    def test_unknown_event_gets_info_indicator(self):
        blocks = build_blocks("unknown_event", "T", "https://x.com", "d", 1, "r")
        title_text = blocks[0]["text"]["text"]
        assert "[INFO]" in title_text

    def test_all_blocks_use_mrkdwn(self):
        blocks = build_blocks("plan_posted", "T", "https://x.com", "desc", 1, "r")
        for b in blocks:
            if b["type"] == "section":
                assert b["text"]["type"] == "mrkdwn"


class TestBuildActions:
    def test_plan_posted_has_approve_changes_comment(self):
        actions = build_actions("plan_posted", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        action_ids = [e.get("action_id") for e in elements]
        assert "approve" in action_ids
        assert "changes" in action_ids
        assert "comment" in action_ids

    def test_plan_posted_has_view_link(self):
        actions = build_actions("plan_posted", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        link_buttons = [e for e in elements if e.get("url")]
        assert len(link_buttons) >= 1
        assert link_buttons[0]["url"] == "https://example.com"

    def test_agent_failed_has_retry(self):
        actions = build_actions("agent_failed", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        action_ids = [e.get("action_id") for e in elements]
        assert "retry" in action_ids

    def test_agent_failed_no_approve(self):
        actions = build_actions("agent_failed", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        action_ids = [e.get("action_id") for e in elements]
        assert "approve" not in action_ids

    def test_tests_passed_view_only(self):
        actions = build_actions("tests_passed", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        action_buttons = [e for e in elements if not e.get("url")]
        assert len(action_buttons) == 0

    def test_values_encode_repo_and_issue(self):
        actions = build_actions("plan_posted", 99, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        values = [e.get("value") for e in elements if e.get("value")]
        assert all(v == "org/repo:99" for v in values)

    def test_approve_button_has_primary_style(self):
        actions = build_actions("plan_posted", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        approve = [e for e in elements if e.get("action_id") == "approve"][0]
        assert approve["style"] == "primary"

    def test_changes_button_has_danger_style(self):
        actions = build_actions("plan_posted", 42, "https://example.com", "org/repo")
        elements = actions[0]["elements"]
        changes = [e for e in elements if e.get("action_id") == "changes"][0]
        assert changes["style"] == "danger"

    def test_returns_list_with_actions_block(self):
        actions = build_actions("plan_posted", 42, "https://example.com", "org/repo")
        assert len(actions) == 1
        assert actions[0]["type"] == "actions"


class TestEventColors:
    def test_success_events_are_green(self):
        for event in ("pr_created", "tests_passed", "review_pushed"):
            assert EVENT_COLORS[event] == "#57F287"

    def test_failure_events_are_red(self):
        for event in ("tests_failed", "agent_failed"):
            assert EVENT_COLORS[event] == "#ED4245"

    def test_info_events_are_blue(self):
        for event in ("plan_posted", "questions_asked"):
            assert EVENT_COLORS[event] == "#3498DB"
