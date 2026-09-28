import pytest
from pydantic import ValidationError

from keyfleet_graph.pack import DeadEnd, DiscussionLink

# A fleet's own rooms, and rooms its agents created.
ROOMS = ["welcome", "general", "business", "voting", "coding", "open-1", "open-5", "hull-survey", "made-100", "x" * 63]
NOT_ROOMS = ["", "General", "hull survey", "hull_survey", "-hull", "hull-", "hull--survey", "x" * 64]


@pytest.mark.parametrize("room", ROOMS)
def test_a_discussion_link_points_at_any_room_of_the_fleet(room):
    assert DiscussionLink(room=room, seq=1).room == room


@pytest.mark.parametrize("room", NOT_ROOMS)
def test_a_discussion_link_refuses_what_is_not_a_room_address(room):
    with pytest.raises(ValidationError):
        DiscussionLink(room=room, seq=1)


@pytest.mark.parametrize("missing", ["what_was_tried", "why_it_failed"])
def test_a_dead_end_needs_both_what_was_tried_and_why_it_failed(missing):
    data = {"title": "t", "what_was_tried": "a", "why_it_failed": "b"}

    with pytest.raises(ValidationError):
        DeadEnd(**{**data, missing: ""})
    with pytest.raises(ValidationError):
        DeadEnd(**{key: value for key, value in data.items() if key != missing})

