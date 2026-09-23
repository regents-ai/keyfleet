"""Scopes: every object a write touches must sit in a scope the command may write."""

import json

import pytest
from conftest import command, request

from keyfleet_graph.host import Host

GOAL = {"title": "Serve one customer", "outcome": "A paying customer"}
EVERYWHERE = ("fleet", "level:2", "level:3")


def _call(host, message):
    return host.handle(json.dumps(message).encode("utf-8"))


def _ok(host, op, body, command_id, scopes=EVERYWHERE):
    reply = _call(host, request(op, body, command(command_id, scopes=scopes)))
    assert reply["ok"], reply
    return reply["result"]


def _refused(host, op, body, scopes):
    head = _call(host, request("hello", {}))["result"]["head_seq"]
    reply = _call(host, request(op, body, command(f"x-{op}-{len(scopes)}", scopes=scopes)))
    assert _call(host, request("hello", {}))["result"]["head_seq"] == head
    return reply["error"]


@pytest.fixture
def scoped(db):
    """A task in the fleet scope, one in level 2 and one in level 3."""
    host = Host("fleet_a", str(db))
    for n, scope in enumerate(("fleet", "level:2", "level:3"), start=1):
        _ok(host, "create", {"type": "task", "scope": scope, "data": {"title": f"T{n}"}}, f"s{n}")
    return host


def _scope_of(host, object_id):
    return host.graph.get_object(object_id).data["sys"]["scope"]


def test_a_create_lands_in_the_scope_it_names_when_the_command_may_write_it(scoped):
    created = _ok(scoped, "create", {"type": "goal", "scope": "level:2", "data": GOAL}, "c1", scopes=("fleet", "level:2"))

    assert _scope_of(scoped, created["id"]) == "level:2"


@pytest.mark.parametrize("scope", ["level:1", "level:3", "level:20"])
def test_a_create_in_a_scope_the_command_may_not_write_is_refused(scoped, scope):
    error = _refused(scoped, "create", {"type": "goal", "scope": scope, "data": GOAL}, ("fleet", "level:2"))

    assert error == {
        "code": "forbidden_scope",
        "message": "the command may not write this scope",
        "details": {"scope": scope},
    }


@pytest.mark.parametrize(
    ("op", "body"),
    [
        ("patch", {"id": "task#2", "expected_version": 1, "set": {"progress": "doing"}}),
        ("archive", {"id": "task#2", "expected_version": 1}),
    ],
)
def test_changing_an_object_needs_its_scope(scoped, op, body):
    assert _refused(scoped, op, body, ("fleet", "level:3"))["details"] == {"scope": "level:2"}
    assert _refused(scoped, op, body, ())["details"] == {"scope": "level:2"}

    assert _ok(scoped, op, body, f"ok-{op}", scopes=("level:2",)) == {"id": "task#2", "version": 2}
    assert _scope_of(scoped, "task#2") == "level:2"


@pytest.mark.parametrize(("source", "target"), [("task#1", "task#2"), ("task#2", "task#1")])
def test_a_link_needs_the_scope_of_both_ends(scoped, source, target):
    link = {"source": source, "target": target, "type": "depends_on"}

    assert _refused(scoped, "link", link, ("fleet",))["details"] == {"scope": "level:2"}
    assert _refused(scoped, "link", link, ("level:2",))["details"] == {"scope": "fleet"}
    assert scoped.graph.relations() == []

    assert _ok(scoped, "link", link, "l1", scopes=("fleet", "level:2"))["existing"] is False


@pytest.mark.parametrize(("source", "target"), [("task#1", "task#3"), ("task#3", "task#1")])
def test_an_unlink_needs_the_scope_of_both_ends(scoped, source, target):
    rel = _ok(scoped, "link", {"source": source, "target": target, "type": "references"}, "l1")
    unlink = {"relation_id": rel["relation_id"]}

    assert _refused(scoped, "unlink", unlink, ("fleet",))["details"] == {"scope": "level:3"}
    assert _refused(scoped, "unlink", unlink, ("level:3",))["details"] == {"scope": "fleet"}
    assert len(scoped.graph.relations()) == 1

    assert _ok(scoped, "unlink", unlink, "u1", scopes=("fleet", "level:3")) == unlink
    assert scoped.graph.relations() == []


@pytest.mark.parametrize(
    "change",
    [
        {"set": {"sys": {"scope": "fleet", "archived": False}}},
        {"set": {"scope": "fleet"}},
        {"unset": ["sys"]},
        {"unset": ["scope"]},
    ],
)
def test_no_member_write_moves_an_object_to_another_scope(scoped, change):
    error = _refused(scoped, "patch", {"id": "task#2", "expected_version": 1, **change}, EVERYWHERE)

    assert error["code"] == "forbidden_field"
    assert _scope_of(scoped, "task#2") == "level:2"


def test_archiving_keeps_the_scope(scoped):
    _ok(scoped, "archive", {"id": "task#3", "expected_version": 1}, "a1")

    sys = scoped.graph.get_object("task#3").data["sys"]
    assert (sys["scope"], sys["archived"]) == ("level:3", True)


def test_a_reopened_host_keeps_each_object_in_its_scope(db):
    host = Host("fleet_a", str(db))
    _ok(host, "create", {"type": "task", "scope": "level:3", "data": {"title": "T"}}, "c1")
    host.graph.store.close()

    reopened = Host("fleet_a", str(db))

    assert _scope_of(reopened, "task#1") == "level:3"
    patch = {"id": "task#1", "expected_version": 1, "set": {"progress": "doing"}}
    assert _refused(reopened, "patch", patch, ("fleet", "level:2"))["details"] == {"scope": "level:3"}


def test_the_most_scopes_a_key_can_hold_is_accepted(db):
    # Key 1 of a sold-out Fibonacci fleet: the fleet and all twenty levels.
    every_scope = ["fleet", *(f"level:{level}" for level in range(1, 21))]
    host = Host("fleet_a", str(db))

    created = _ok(host, "create", {"type": "goal", "scope": "level:20", "data": GOAL}, "c-21", scopes=every_scope)

    assert _scope_of(host, created["id"]) == "level:20"
