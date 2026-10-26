"""Who a task belongs to: a Key takes an untaken task, only its holder changes it, gives it away or drops it, only its creator archives it, and anyone forks it."""

import json

import pytest
from conftest import command, request

from keyfleet_graph.host import Host

GOAL = {"title": "Serve one customer", "outcome": "A paying customer"}
HOLDER = {"token_id": 17}
OTHER = {"token_id": 18, "wallet": "0x" + "c3" * 20}


def _call(host, op, body, cmd):
    return host.handle(json.dumps(request(op, body, cmd)).encode("utf-8"))


def _ok(host, op, body, cmd):
    reply = _call(host, op, body, cmd)
    assert reply["ok"], reply
    return reply["result"]


def _assign(host, command_id, key, assignee):
    task = host.graph.get_object("task#2")
    return _call(host, "patch", {"id": "task#2", "expected_version": task.version, "set": {"assignee_key": assignee}}, command(command_id, **key))


def _holder(host, object_id="task#2"):
    return host.graph.get_object(object_id).data.get("assignee_key")


@pytest.fixture
def host(db):
    """A goal, and an untaken task that implements it."""
    host = Host("fleet_a", str(db), [])
    _ok(host, "create", {"project": "general", "type": "goal", "data": GOAL}, command("g"))
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Draft", "deliverable": "One page", "acceptance_criteria": ["Fits on one page"]}}, command("t"))
    _ok(host, "link", {"source": "task#2", "target": "goal#1", "type": "implements"}, command("l"))
    return host


def test_an_untaken_task_is_taken_only_by_the_acting_key(host):
    refused = _assign(host, "give", OTHER, 17)

    assert refused["error"]["code"] == "forbidden_field"
    assert _holder(host) is None
    assert _assign(host, "take", OTHER, 18)["ok"]
    assert _holder(host) == 18


def test_the_holder_gives_a_task_to_another_key_and_that_key_drops_it(host):
    assert _assign(host, "take", HOLDER, 17)["ok"]
    assert _assign(host, "give", HOLDER, 18)["ok"]
    assert _holder(host) == 18

    taken_back = _assign(host, "back", HOLDER, 17)
    assert taken_back["error"]["details"] == {"fields": ["assignee_key"], "assignee_key": 18}

    assert _assign(host, "drop", OTHER, None)["ok"]
    assert _holder(host) is None


@pytest.mark.parametrize("assignee", [18, None])
def test_a_key_cannot_take_or_drop_a_task_another_key_holds(host, assignee):
    _assign(host, "take", HOLDER, 17)

    reply = _assign(host, "x", OTHER, assignee)

    assert reply["error"]["code"] == "forbidden_field"
    assert "fork it instead" in reply["error"]["message"]
    assert _holder(host) == 17


@pytest.mark.parametrize(
    "change",
    [
        {"set": {"progress": "blocked"}},
        {"set": {"next_step": "Ask the customer"}},
        {"set": {"title": "Another task"}},
        {"unset": ["deliverable"]},
    ],
)
def test_a_key_cannot_change_a_task_another_key_holds(host, change):
    _assign(host, "take", HOLDER, 17)

    reply = _call(host, "patch", {"id": "task#2", "expected_version": 2, **change}, command("e", **OTHER))

    assert reply["error"]["code"] == "not_owner"
    assert reply["error"]["details"] == {"id": "task#2", "owner_key": 17}
    assert host.graph.get_object("task#2").version == 2


def test_the_holder_changes_the_task_they_hold(host):
    _assign(host, "take", OTHER, 18)

    _ok(host, "patch", {"id": "task#2", "expected_version": 2, "set": {"progress": "blocked", "next_step": "Ask the customer"}}, command("e", **OTHER))

    task = host.graph.get_object("task#2")
    assert (task.data["progress"], task.data["next_step"]) == ("blocked", "Ask the customer")


def test_an_untaken_task_is_changed_only_by_the_key_that_created_it(host):
    reply = _call(host, "patch", {"id": "task#2", "expected_version": 1, "set": {"progress": "doing", "assignee_key": 18}}, command("e", **OTHER))

    assert reply["error"]["code"] == "not_owner"
    assert _ok(host, "patch", {"id": "task#2", "expected_version": 1, "set": {"next_step": "Start"}}, command("e2"))["version"] == 2


@pytest.mark.parametrize("holder", [HOLDER, OTHER])
def test_a_held_task_is_not_archived_by_another_key(host, holder):
    _assign(host, "take", holder, holder["token_id"])
    archiver = OTHER if holder is HOLDER else HOLDER

    reply = _call(host, "archive", {"id": "task#2", "expected_version": 2}, command("a", **archiver))

    assert reply["error"]["code"] == "not_owner"
    assert not host.graph.get_object("task#2").data["sys"]["archived"]


def test_the_holder_drops_a_task_and_its_creator_archives_it(host):
    _assign(host, "take", OTHER, 18)
    refused = _call(host, "archive", {"id": "task#2", "expected_version": 2}, command("a", **OTHER))
    assert refused["error"]["code"] == "not_owner"

    assert _assign(host, "drop", OTHER, None)["ok"]
    _ok(host, "archive", {"id": "task#2", "expected_version": 3}, command("a2"))

    assert host.graph.get_object("task#2").data["sys"]["archived"]


def test_links_from_a_task_are_its_holders_to_make_and_remove(host):
    _ok(host, "create", {"project": "general", "type": "goal", "data": {"title": "Another", "outcome": "More"}}, command("g2", **OTHER))
    [implements] = host.graph.relations(source="task#2", type="implements")

    linked = _call(host, "link", {"source": "task#2", "target": "goal#3", "type": "implements"}, command("l", **OTHER))
    unlinked = _call(host, "unlink", {"relation_id": implements.id}, command("u", **OTHER))

    assert (linked["error"]["code"], unlinked["error"]["code"]) == ("not_owner", "not_owner")
    assert [rel.target for rel in host.graph.relations(source="task#2", type="implements")] == ["goal#1"]
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Theirs"}}, command("t2", **OTHER))
    _ok(host, "link", {"source": "task#4", "target": "task#2", "type": "depends_on"}, command("l2", **OTHER))


def test_a_fork_is_the_forking_keys_task_in_progress_beside_the_one_it_copied(host):
    _assign(host, "take", HOLDER, 17)

    fork = _ok(host, "fork", {"id": "task#2"}, command("f", **OTHER))

    copy = host.graph.get_object(fork["id"])
    assert fork == {"id": copy.id, "version": 1}
    fields = ("title", "deliverable", "acceptance_criteria", "assignee_key", "progress", "result_ref")
    assert {field: copy.data.get(field) for field in fields} == {
        "title": "Draft",
        "deliverable": "One page",
        "acceptance_criteria": ["Fits on one page"],
        "assignee_key": 18,
        "progress": "doing",
        "result_ref": None,
    }
    assert copy.data["sys"]["created_by"]["key"]["token_id"] == 18
    assert [(rel.target, rel.type) for rel in host.graph.relations(source=copy.id)] == [
        ("task#2", "forks"),
        ("goal#1", "implements"),
    ]
    original = host.graph.get_object("task#2")
    assert (original.version, original.data["assignee_key"]) == (2, 17)


def test_a_fork_stays_linked_to_the_task_it_copied(host):
    fork = _ok(host, "fork", {"id": "task#2"}, command("f", **OTHER))
    [rel] = host.graph.relations(source=fork["id"], type="forks")

    unlinked = _call(host, "unlink", {"relation_id": rel.id}, command("u"))
    linked = _call(host, "link", {"source": "task#2", "target": fork["id"], "type": "forks"}, command("l2"))

    assert (unlinked["error"]["code"], linked["error"]["code"]) == ("invalid", "invalid")
    assert len(host.graph.relations(type="forks")) == 1


@pytest.mark.parametrize(("setup", "target"), [(None, "goal#1"), ("archive", "task#2"), (None, "task#404")])
def test_only_a_live_task_is_forked(host, setup, target):
    if setup:
        _ok(host, "archive", {"id": target, "expected_version": 1}, command("a"))
    objects = len(host.graph.all_objects())

    reply = _call(host, "fork", {"id": target}, command("f", **OTHER))

    assert reply["error"]["code"] in {"invalid", "not_found"}
    assert len(host.graph.all_objects()) == objects


@pytest.mark.parametrize(("op", "body"), [
    ("patch", {"id": "goal#1", "expected_version": 1, "set": {"status": "dropped"}}),
    ("archive", {"id": "goal#1", "expected_version": 1}),
    ("patch", {"id": "note#3", "expected_version": 1, "set": {"body": "Overwritten"}}),
    ("archive", {"id": "note#3", "expected_version": 1}),
])
def test_another_keys_goal_or_note_is_left_as_its_creator_wrote_it(host, op, body):
    _ok(host, "create", {"project": "general", "type": "note", "data": {"title": "Mine", "body": "Kept"}}, command("n"))

    reply = _call(host, op, body, command("x", **OTHER))

    assert reply["error"]["code"] == "not_owner"
    assert host.graph.get_object(body["id"]).version == 1
