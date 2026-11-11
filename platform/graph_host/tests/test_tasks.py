"""Who works on a task: any Key joins it, however many have, the Keys that joined it and its creator change it, only its creator changes what it is and archives it, once the others have left, and anyone forks it."""

import json

import pytest
from conftest import command, request

from keyfleet_graph.host import Host

GOAL = {"title": "Serve one customer", "outcome": "A paying customer"}
CREATOR = {"token_id": 17}
OTHER = {"token_id": 18, "wallet": "0x" + "c3" * 20}
THIRD = {"token_id": 19, "wallet": "0x" + "d4" * 20}


def _call(host, op, body, cmd):
    return host.handle(json.dumps(request(op, body, cmd)).encode("utf-8"))


def _ok(host, op, body, cmd):
    reply = _call(host, op, body, cmd)
    assert reply["ok"], reply
    return reply["result"]


def _joined(host, object_id="task#2"):
    return [entry["key"]["token_id"] for entry in host.graph.get_object(object_id).data["sys"]["joined"]]


def _version(host, object_id="task#2"):
    return host.graph.get_object(object_id).version


@pytest.fixture
def host(db):
    """A goal, and a task by Key 17 that implements it."""
    host = Host("fleet_a", str(db), [])
    _ok(host, "create", {"project": "general", "type": "goal", "data": GOAL}, command("g"))
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Draft", "deliverable": "One page", "acceptance_criteria": ["Fits on one page"]}}, command("t"))
    _ok(host, "link", {"source": "task#2", "target": "goal#1", "type": "implements"}, command("l"))
    return host


def test_a_new_task_has_no_one_joined(host):
    assert _joined(host) == []


def test_any_number_of_keys_join_one_task_and_each_leaves_only_itself(host):
    for token_id in range(18, 218):
        assert _call(host, "join", {"id": "task#2"}, command(f"j{token_id}", token_id=token_id))["ok"]
    assert _ok(host, "join", {"id": "task#2"}, command("again", token_id=18)) == {"id": "task#2", "version": 201}

    _ok(host, "leave", {"id": "task#2"}, command("leave", token_id=18))

    joined = _joined(host)
    assert (len(joined), 18 in joined, joined[0]) == (199, False, 19)


def test_a_key_joins_tasks_without_limit(host):
    for number in range(40):
        made = _ok(host, "create", {"project": "general", "type": "task", "data": {"title": f"Task {number}"}}, command(f"t{number}"))
        _ok(host, "join", {"id": made["id"]}, command(f"j{number}", **OTHER))

    tasks = [obj for obj in host.graph.query("task") if 18 in _joined(host, obj.id)]
    assert len(tasks) == 40


@pytest.mark.parametrize("change", [{"set": {"progress": "blocked"}}, {"set": {"next_step": "Ask the customer"}}, {"unset": ["next_step"]}])
def test_a_key_that_has_not_joined_a_task_cannot_change_it(host, change):
    _ok(host, "join", {"id": "task#2"}, command("j", **THIRD))

    reply = _call(host, "patch", {"id": "task#2", "expected_version": 2, **change}, command("e", **OTHER))

    assert reply["error"]["code"] == "not_owner"
    assert reply["error"]["details"] == {"id": "task#2", "owner_key": 17, "joined_keys": [19]}
    assert _version(host) == 2


def test_every_key_that_joined_a_task_works_on_it(host):
    _ok(host, "join", {"id": "task#2"}, command("j1", **OTHER))
    _ok(host, "join", {"id": "task#2"}, command("j2", **THIRD))

    _ok(host, "patch", {"id": "task#2", "expected_version": 3, "set": {"progress": "doing"}}, command("e1", **OTHER))
    _ok(host, "patch", {"id": "task#2", "expected_version": 4, "set": {"next_step": "Ask the customer"}}, command("e2", **THIRD))

    task = host.graph.get_object("task#2")
    assert (task.data["progress"], task.data["next_step"]) == ("doing", "Ask the customer")


@pytest.mark.parametrize("change", [{"set": {"title": "Another task"}}, {"unset": ["deliverable"]}, {"set": {"acceptance_criteria": []}}])
def test_only_the_creator_changes_what_a_task_is(host, change):
    _ok(host, "join", {"id": "task#2"}, command("j", **OTHER))

    refused = _call(host, "patch", {"id": "task#2", "expected_version": 2, **change}, command("e", **OTHER))

    assert refused["error"]["code"] == "not_owner"
    assert refused["error"]["details"]["owner_key"] == 17
    assert _ok(host, "patch", {"id": "task#2", "expected_version": 2, **change}, command("e2"))["version"] == 3


def test_a_keys_join_from_an_earlier_ownership_does_not_let_its_new_owner_work_on_the_task(host):
    _ok(host, "join", {"id": "task#2"}, command("j", **OTHER))
    bought = command("e", **OTHER)
    bought["auth"]["ownership_epoch"] = 4
    bought["principal"] = bought["principal"].replace("@3/", "@4/")

    reply = _call(host, "patch", {"id": "task#2", "expected_version": 2, "set": {"progress": "doing"}}, bought)

    assert reply["error"]["code"] == "not_owner"


def test_the_creator_archives_a_task_at_any_time_and_every_key_that_joined_it_is_let_go(host):
    _ok(host, "join", {"id": "task#2"}, command("j1", **OTHER))
    _ok(host, "join", {"id": "task#2"}, command("j2", **THIRD))

    by_other = _call(host, "archive", {"id": "task#2", "expected_version": 3}, command("a1", **OTHER))
    _ok(host, "archive", {"id": "task#2", "expected_version": 3}, command("a2"))

    assert by_other["error"]["code"] == "not_owner"
    sys = host.graph.get_object("task#2").data["sys"]
    assert (sys["archived"], sys["joined"]) == (True, [])


def test_links_from_a_task_are_for_its_creator_and_the_keys_that_joined_it(host):
    _ok(host, "create", {"project": "general", "type": "goal", "data": {"title": "Another", "outcome": "More"}}, command("g2", **OTHER))
    [implements] = host.graph.relations(source="task#2", type="implements")

    linked = _call(host, "link", {"source": "task#2", "target": "goal#3", "type": "implements"}, command("l", **THIRD))
    unlinked = _call(host, "unlink", {"relation_id": implements.id}, command("u", **THIRD))
    assert (linked["error"]["code"], unlinked["error"]["code"]) == ("not_owner", "not_owner")

    _ok(host, "join", {"id": "task#2"}, command("j", **THIRD))
    _ok(host, "link", {"source": "task#2", "target": "goal#3", "type": "implements"}, command("l2", **THIRD))
    _ok(host, "unlink", {"relation_id": implements.id}, command("u2", **THIRD))

    assert [rel.target for rel in host.graph.relations(source="task#2", type="implements")] == ["goal#3"]


def test_a_fork_is_the_forking_keys_own_task_in_progress_beside_the_one_it_copied(host):
    _ok(host, "join", {"id": "task#2"}, command("j"))

    fork = _ok(host, "fork", {"id": "task#2"}, command("f", **OTHER))

    copy = host.graph.get_object(fork["id"])
    assert fork == {"id": copy.id, "version": 1}
    fields = ("title", "deliverable", "acceptance_criteria", "progress", "result_ref")
    assert {field: copy.data.get(field) for field in fields} == {
        "title": "Draft",
        "deliverable": "One page",
        "acceptance_criteria": ["Fits on one page"],
        "progress": "doing",
        "result_ref": None,
    }
    assert (copy.data["sys"]["created_by"]["key"]["token_id"], copy.data["sys"]["joined"]) == (18, [])
    assert [(rel.target, rel.type) for rel in host.graph.relations(source=copy.id)] == [
        ("task#2", "forks"),
        ("goal#1", "implements"),
    ]
    assert (_version(host), _joined(host)) == (2, [17])


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
    if body["id"] == "goal#1":
        _ok(host, "join", {"id": "goal#1"}, command("j", **OTHER))
        body = {**body, "expected_version": 2}

    reply = _call(host, op, body, command("x", **OTHER))

    assert reply["error"]["code"] == "not_owner"
    assert host.graph.get_object(body["id"]).version == body["expected_version"]


def test_a_restart_makes_each_tasks_holder_the_first_key_to_have_joined_it(db):
    host = Host("fleet_a", str(db), [])
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Held"}}, command("t1"))
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Given"}}, command("t2", **OTHER))
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Open"}}, command("t3"))
    # Tasks as an older pack wrote them: each names its holder by Key number.
    host.graph.patch_object("task#1", {"assignee_key": 18}, actor="system")
    host.graph.patch_object("task#2", {"assignee_key": 99}, actor="system")
    host.graph.patch_object("task#3", {"assignee_key": None}, actor="system")
    host.graph.store.close()

    again = Host("fleet_a", str(db), [])

    held, given, untaken = (again.graph.get_object(f"task#{number}").data for number in (1, 2, 3))
    assert all("assignee_key" not in task for task in (held, given, untaken))
    assert [(entry["key"]["token_id"], entry["wallet"], entry["ownership_epoch"]) for entry in held["sys"]["joined"]] == [
        (18, OTHER["wallet"], 3)
    ]
    assert (given["sys"]["joined"], untaken["sys"]["joined"]) == ([], [])
    _ok(again, "patch", {"id": "task#1", "expected_version": 3, "set": {"progress": "doing"}}, command("e", **OTHER))
    again.graph.store.close()

    # The step runs once: a later restart finds nothing left to rewrite.
    third = Host("fleet_a", str(db), [])
    assert third.graph.get_object("task#1").version == 4


def test_a_restart_rewrites_any_number_of_held_tasks(db):
    host = Host("fleet_a", str(db), [])
    for number in range(150):
        made = _ok(host, "create", {"project": "general", "type": "task", "data": {"title": f"Task {number}"}}, command(f"t{number}"))
        host.graph.patch_object(made["id"], {"assignee_key": 17}, actor="system")
    host.graph.store.close()

    again = Host("fleet_a", str(db), [])

    assert [len(task.data["sys"]["joined"]) for task in again.graph.query("task")] == [1] * 150
