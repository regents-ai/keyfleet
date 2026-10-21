"""Who holds a task: a Key takes an untaken task, only its holder gives it away or drops it, and anyone forks it."""

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
    _ok(host, "create", {"type": "goal", "data": GOAL}, command("g"))
    _ok(host, "create", {"type": "task", "data": {"title": "Draft", "deliverable": "One page", "acceptance_criteria": ["Fits on one page"]}}, command("t"))
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


def test_a_key_still_edits_a_task_another_key_holds(host):
    _assign(host, "take", HOLDER, 17)

    _ok(host, "patch", {"id": "task#2", "expected_version": 2, "set": {"next_step": "Ask the customer"}}, command("e", **OTHER))

    assert (_holder(host), host.graph.get_object("task#2").data["next_step"]) == (17, "Ask the customer")


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
