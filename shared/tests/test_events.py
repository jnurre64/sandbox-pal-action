from dispatch_bot.events import (
    EVENT_LABELS,
    EVENT_INDICATORS,
    PLAN_EVENTS,
    RETRY_EVENTS,
)


class TestEventCatalog:
    def test_plan_events_have_labels(self):
        for event in PLAN_EVENTS:
            assert event in EVENT_LABELS, f"{event} missing from EVENT_LABELS"

    def test_retry_events_have_labels(self):
        for event in RETRY_EVENTS:
            assert event in EVENT_LABELS, f"{event} missing from EVENT_LABELS"

    def test_plan_events_have_indicators(self):
        for event in PLAN_EVENTS:
            assert event in EVENT_INDICATORS, f"{event} missing from EVENT_INDICATORS"

    def test_retry_events_have_indicators(self):
        for event in RETRY_EVENTS:
            assert event in EVENT_INDICATORS, f"{event} missing from EVENT_INDICATORS"

    def test_plan_and_retry_events_disjoint(self):
        assert PLAN_EVENTS.isdisjoint(RETRY_EVENTS), \
            "an event should not be both a plan event and a retry event"

    def test_plan_posted_is_plan_event(self):
        assert "plan_posted" in PLAN_EVENTS

    def test_agent_failed_is_retry_event(self):
        assert "agent_failed" in RETRY_EVENTS

    def test_labels_are_strings(self):
        for event, label in EVENT_LABELS.items():
            assert isinstance(label, str) and label, f"{event} has empty/non-str label"

    def test_indicators_are_strings(self):
        for event, indicator in EVENT_INDICATORS.items():
            assert isinstance(indicator, str) and indicator, \
                f"{event} has empty/non-str indicator"
