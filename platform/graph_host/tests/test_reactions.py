"""The two reactions: which writes ask for attention, what they ask, and their bounds."""

import json

import pytest
from conftest import CONTRACT, WALLET, HostProcess, command, request

from keyfleet_graph import host as host_module
from keyfleet_graph.host import Host
from keyfleet_graph.reactions import MAX_ATTENTION, MAX_WORK, DependsOnLinks

GATEWAY = "keyfleet:gateway"
MEMBER = f"member:8453:{CONTRACT}:17@3/agent:{WALLET}"
SYS = {
    "scope": "fleet",
    "created_by": {
        "key": {"chain_id": 8453, "contract": CONTRACT, "token_id": 17},
        "ownership_epoch": 3,
        "kind": "agent",
        "wallet": WALLET,
    },
    "archived": False,
}


class Fleet:
    """One host driven through its protocol, as the writer drives it."""

    def __init__(self, host):
        self.host = host
        self.n = 0

    def send(self, op, body):
        self.n += 1
        reply = self.host.handle(json.dumps(request(op, body, command(f"c{self.n}"))).encode("utf-8"))
        assert reply["ok"], reply
        return reply

    def create(self, type_, **data):
        return self.send("create", {"type": type_, "scope": "fleet", "data": {"title": type_, **data}})["result"]["id"]

    def patch(self, object_id, **fields):
        obj = self.host.graph.get_object(object_id)
        return self.send("patch", {"id": object_id, "expected_version": obj.version, "set": fields})

    def submit(self, object_id, result_ref="https://example.com/result", evidence=()):
        obj = self.host.graph.get_object(object_id)
        body = {"id": object_id, "expected_version": obj.version, "result_ref": result_ref, "evidence": list(evidence)}
        return self.send("submit", body)

    def archive(self, object_id):
        obj = self.host.graph.get_object(object_id)
        return self.send("archive", {"id": object_id, "expected_version": obj.version})

    def link(self, source, target, type_="depends_on"):
        return self.send("link", {"source": source, "target": target, "type": type_})

    def unlink(self, relation_id):
        return self.send("unlink", {"relation_id": relation_id})


def attention(reply):
    return [event for event in reply["events"] if event["type"] == "keyfleet.attention"]


def asked(reply):
    """What a write's reply asked for, as (kind, object) pairs."""
    return [(event["payload"]["kind"], event["payload"]["object_id"]) for event in attention(reply)]


def change(reply):
    """The event of the member's own change in a write's reply."""
    [event] = [e for e in reply["events"] if e["type"] in ("object.created", "patch.applied", "relation.created", "relation.removed")]
    return event


@pytest.fixture
def fleet(db):
    return Fleet(Host("fleet_a", str(db), []))


EVIDENCE = {"source_uri": "https://example.com/source"}


# ---------- task_unblocked ----------


def test_a_task_submitted_asks_for_its_review_and_unblocks_each_task_waiting_only_on_it(fleet):
    blocker = fleet.create("task")
    first, second = fleet.create("task"), fleet.create("task", progress="blocked")
    fleet.link(first, blocker)
    fleet.link(second, blocker)

    done = fleet.submit(blocker)

    cause, log = change(done)["id"], done["run_id"]
    assert [event["payload"] for event in attention(done)] == [
        {
            "kind": kind,
            "object_id": task,
            "cause": {"event_id": cause},
            "dedupe_key": f"{log}:{kind}:{task}:{cause}",
        }
        for kind, task in (("needs_review", blocker), ("task_unblocked", first), ("task_unblocked", second))
    ]
    assert {event["actor"] for event in attention(done)} == {GATEWAY}


def test_attention_comes_after_the_change_it_answers_and_the_ledger_names_it(fleet):
    blocker, waiting = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, blocker)

    done = fleet.submit(blocker)

    types = [event["type"] for event in done["events"]]
    assert types[:4] == ["patch.applied", "keyfleet.attention", "keyfleet.attention", "keyfleet.command"]
    [ledger] = [event for event in done["events"] if event["type"] == "keyfleet.command"]
    assert ledger["payload"]["events"] == [event["id"] for event in done["events"][:3]]


def test_a_task_still_waiting_on_another_target_is_not_unblocked_until_that_one_finishes(fleet):
    one, two, waiting = fleet.create("task"), fleet.create("task"), fleet.create("task")
    fleet.link(waiting, one)
    fleet.link(waiting, two)

    assert asked(fleet.submit(one)) == [("needs_review", one)]
    assert asked(fleet.submit(two)) == [("needs_review", two), ("task_unblocked", waiting)]


@pytest.mark.parametrize("other", ["service", "goal"])
def test_a_target_with_no_finished_state_keeps_its_dependents_waiting(fleet, other):
    data = {"service": {"customer": "c", "problem": "p", "deliverable": "d"}, "goal": {"outcome": "o"}}.get(other, {})
    blocker, standing = fleet.create("task"), fleet.create(other, **data)
    waiting = fleet.create("task")
    fleet.link(waiting, blocker)
    fleet.link(waiting, standing)

    assert asked(fleet.submit(blocker)) == [("needs_review", blocker)]


def test_archiving_an_unfinished_target_unblocks_and_archiving_a_done_one_does_not(fleet):
    open_target, done_target = fleet.create("goal", outcome="o"), fleet.create("task")
    fleet.submit(done_target)
    waiting, also = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, open_target)
    fleet.link(also, done_target)
    fleet.link(also, fleet.create("task"))

    assert asked(fleet.archive(open_target)) == [("task_unblocked", waiting)]
    assert asked(fleet.archive(done_target)) == []


def test_archiving_a_task_already_done_asks_nothing_more(fleet):
    blocker, waiting = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, blocker)

    assert asked(fleet.submit(blocker)) == [("needs_review", blocker), ("task_unblocked", waiting)]
    assert asked(fleet.archive(blocker)) == []


def test_unlinking_an_unfinished_target_unblocks_its_source_and_other_unlinks_do_not(fleet):
    open_target, done_target = fleet.create("task"), fleet.create("task")
    fleet.submit(done_target)
    waiting = fleet.create("task")
    blocking = fleet.link(waiting, open_target)["result"]["relation_id"]
    finished = fleet.link(waiting, done_target)["result"]["relation_id"]
    other = fleet.create("task")
    reference = fleet.link(other, open_target, "references")["result"]["relation_id"]

    assert asked(fleet.unlink(reference)) == []
    unlinked = fleet.unlink(blocking)
    assert asked(unlinked) == [("task_unblocked", waiting)]
    assert attention(unlinked)[0]["payload"]["cause"] == {"event_id": change(unlinked)["id"]}
    assert asked(fleet.unlink(finished)) == []


def test_unlinking_the_last_of_several_open_targets_is_what_unblocks(fleet):
    one, two, waiting = fleet.create("task"), fleet.create("task"), fleet.create("task")
    first = fleet.link(waiting, one)["result"]["relation_id"]
    second = fleet.link(waiting, two)["result"]["relation_id"]

    assert asked(fleet.unlink(first)) == []
    assert asked(fleet.unlink(second)) == [("task_unblocked", waiting)]


def test_only_depends_on_links_hold_a_task_back(fleet):
    blocker, waiting = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, blocker)
    # Open objects the task produces, references and is supported by, and an
    # open task that references the blocker, none of which it waits on.
    fleet.link(waiting, fleet.create("note", body="b"), "produces")
    fleet.link(waiting, fleet.create("goal", outcome="o"), "references")
    fleet.link(waiting, fleet.create("goal", outcome="o"), "implements")
    fleet.link(fleet.create("finding", statement="s"), waiting, "supports")
    fleet.link(fleet.create("task"), blocker, "references")

    assert asked(fleet.submit(blocker)) == [("needs_review", blocker), ("task_unblocked", waiting)]


SOURCES = {
    "done task": ("task", {}),
    "archived task": ("task", {}),
    "goal": ("goal", {"outcome": "o"}),
    "service": ("service", {"customer": "c", "problem": "p", "deliverable": "d"}),
}


@pytest.mark.parametrize("source_kind", SOURCES)
def test_only_a_task_still_waiting_is_announced(fleet, source_kind):
    type_, data = SOURCES[source_kind]
    blocker, source = fleet.create("task"), fleet.create(type_, **data)
    fleet.link(source, blocker)
    if source_kind == "done task":
        fleet.submit(source)
    if source_kind == "archived task":
        fleet.archive(source)

    assert asked(fleet.submit(blocker)) == [("needs_review", blocker)]


def test_a_task_reopened_and_submitted_again_unblocks_again_under_the_new_cause(fleet):
    blocker, waiting = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, blocker)

    first = fleet.submit(blocker)
    assert asked(fleet.patch(blocker, progress="doing")) == []
    again = fleet.submit(blocker)

    assert asked(first) == asked(again) == [("needs_review", blocker), ("task_unblocked", waiting)]
    assert attention(first)[1]["payload"]["dedupe_key"] != attention(again)[1]["payload"]["dedupe_key"]


# ---------- needs_review ----------


@pytest.mark.parametrize(("relation", "target_type"), [("supports", "finding"), ("contradicts", "goal"), ("supports", "task")])
def test_evidence_newly_linked_for_or_against_an_object_asks_for_its_review(fleet, relation, target_type):
    data = {"finding": {"statement": "s"}, "goal": {"outcome": "o"}}.get(target_type, {})
    evidence, target = fleet.create("evidence", **EVIDENCE), fleet.create(target_type, **data)

    linked = fleet.link(evidence, target, relation)

    assert [event["payload"] for event in attention(linked)] == [
        {
            "kind": "needs_review",
            "object_id": target,
            "cause": {"event_id": change(linked)["id"]},
            "dedupe_key": f"{linked['run_id']}:needs_review:{target}:{change(linked)['id']}",
        }
    ]
    # Linking the same way again changes nothing and asks nothing.
    assert asked(fleet.link(evidence, target, relation)) == []


@pytest.mark.parametrize("output", ["evidence", "finding", "note", "dead_end"])
def test_a_task_producing_something_asks_for_a_review_of_what_it_produced(fleet, output):
    data = {
        "evidence": EVIDENCE,
        "finding": {"statement": "s"},
        "note": {"body": "b"},
        "dead_end": {"what_was_tried": "t", "why_it_failed": "w"},
    }.get(output, {})
    task, produced = fleet.create("task"), fleet.create(output, **data)

    assert asked(fleet.link(task, produced, "produces")) == [("needs_review", produced)]


def test_each_submission_asks_for_a_review_and_only_the_first_unblocks(fleet):
    task, waiting = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, task)

    assert asked(fleet.submit(task, "https://example.com/v1")) == [("needs_review", task), ("task_unblocked", waiting)]
    assert asked(fleet.submit(task, "https://example.com/v2")) == [("needs_review", task)]
    assert asked(fleet.patch(task, next_step="Send it.")) == []


def test_reviewing_a_submission_asks_for_nothing(fleet):
    task = fleet.create("task")
    fleet.submit(task)
    body = {"task": task, "task_version": 2, "decision": "accept", "rationale": "r", "conflicts_of_interest": "none"}

    reply = fleet.host.handle(json.dumps(request("review", body, command("rv", token_id=18, wallet="0x" + "c3" * 20))).encode())

    assert reply["ok"], reply
    assert attention(reply) == []


# ---------- writes that ask for nothing ----------


def test_writes_outside_the_listed_changes_ask_for_nothing(fleet):
    finding, goal = fleet.create("finding", statement="s"), fleet.create("goal", outcome="o")
    task, service = fleet.create("task"), fleet.create("service", customer="c", problem="p", deliverable="d")
    evidence = fleet.create("evidence", **EVIDENCE)
    waiting = fleet.create("task")
    fleet.link(waiting, task)

    quiet = [
        fleet.create("note", body="b"),
        fleet.link(finding, goal, "supports"),
        fleet.link(finding, goal, "contradicts"),
        fleet.link(task, goal, "implements"),
        fleet.link(service, goal, "implements"),
        fleet.link(evidence, goal, "references"),
        fleet.link(goal, task, "depends_on"),
        fleet.patch(goal, status="achieved"),
        fleet.patch(task, progress="doing"),
        fleet.patch(task, progress="blocked", title="Renamed", deliverable="A brief"),
        fleet.patch(evidence, excerpt="quote"),
        fleet.archive(finding),
        fleet.archive(waiting),
    ]
    replies = [reply for reply in quiet if isinstance(reply, dict)]

    assert all(attention(reply) == [] for reply in replies)
    assert not any(event.type == "keyfleet.attention" for event in fleet.host.graph.events)


# ---------- dedupe across replay and restart ----------


def test_the_same_command_again_is_answered_from_the_ledger_and_asks_nothing_more(fleet):
    blocker, waiting = fleet.create("task"), fleet.create("task")
    fleet.link(waiting, blocker)
    done = request("submit", {"id": blocker, "expected_version": 1, "result_ref": "ipfs://cid"}, command("done"))

    first = fleet.host.handle(json.dumps(done).encode())
    again = fleet.host.handle(json.dumps(done).encode())

    assert asked(first) == [("needs_review", blocker), ("task_unblocked", waiting)]
    assert (again["replayed"], again["events"]) == (True, [])
    assert sum(event.type == "keyfleet.attention" for event in fleet.host.graph.events) == 2


CRASH_AFTER_COMMIT = """
import os
from keyfleet_graph import protocol
_write = protocol.write_frame
def write_frame(stream, message):
    if message.get("ok") and message.get("replayed") is False and message["result"].get("version") == 2:
        os._exit(9)
    _write(stream, message)
protocol.write_frame = write_frame
"""


def test_a_retry_after_a_crash_between_commit_and_reply_asks_nothing_twice(db):
    create = [
        request("create", {"type": "task", "scope": "fleet", "data": {"title": title}}, command(title))
        for title in ("blocker", "waiting")
    ]
    link = request("link", {"source": "task#2", "target": "task#1", "type": "depends_on"}, command("l"))
    done = request("submit", {"id": "task#1", "expected_version": 1, "result_ref": "ipfs://cid"}, command("d"))

    crashing = HostProcess(db, patch=CRASH_AFTER_COMMIT)
    for message in (*create, link):
        assert crashing.send(message)["ok"]
    assert crashing.send(done) is None
    assert crashing.wait() == 9

    host = HostProcess(db)
    retried = host.send(done)
    assert (retried["replayed"], retried["events"]) == (True, [])
    page = host.send(request("changes", {"after_seq": 0, "limit": 500}))["result"]["events"]
    assert [event["payload"]["object_id"] for event in page if event["type"] == "keyfleet.attention"] == ["task#1", "task#2"]
    assert host.close() == 0


def test_a_reopened_host_asks_nothing_again_and_its_next_cause_is_new(db):
    first = Fleet(Host("fleet_a", str(db), []))
    blocker, waiting = first.create("task"), first.create("task")
    first.link(waiting, blocker)
    done = first.submit(blocker)
    first.host.graph.store.close()

    reopened = Fleet(Host("fleet_a", str(db), []))
    reopened.n = first.n

    # Opening the log runs nothing again, so it gains no attention.
    assert [event.id for event in reopened.host.graph.events if event.type == "keyfleet.attention"] == [
        event["id"] for event in attention(done)
    ]
    # The same change made again is a new cause, with its own keys.
    reopened.patch(blocker, progress="doing")
    again = reopened.submit(blocker)
    keys = [event.payload["dedupe_key"] for event in reopened.host.graph.events if event.type == "keyfleet.attention"]
    assert asked(again) == [("needs_review", blocker), ("task_unblocked", waiting)]
    assert len(set(keys)) == len(keys) == 4


def test_the_same_change_in_two_fleets_asks_under_two_keys(tmp_path):
    fleets = [Fleet(Host(name, str(tmp_path / f"{name}.sqlite"), [])) for name in ("fleet_a", "fleet_b")]
    replies = []
    for fleet in fleets:
        blocker, waiting = fleet.create("task"), fleet.create("task")
        fleet.link(waiting, blocker)
        replies.append(fleet.submit(blocker))

    [_, a], [_, b] = (attention(reply) for reply in replies)
    # Both logs number their events alike, so only the log id tells them apart.
    assert (a["payload"]["object_id"], a["payload"]["cause"]) == (b["payload"]["object_id"], b["payload"]["cause"])
    assert a["payload"]["dedupe_key"] != b["payload"]["dedupe_key"]
    assert a["payload"]["dedupe_key"].startswith(replies[0]["run_id"] + ":")


# ---------- bounds ----------


def _seed(host, dependents, extra_targets=0):
    """A blocker task and `dependents` tasks waiting on it, each also waiting on
    `extra_targets` tasks that are already done; written straight to the graph."""
    with host._transaction():
        add = host.graph.add_object
        blocker = add("task", {"title": "blocker", "sys": SYS}, actor=MEMBER).id
        finished = [add("task", {"title": "d", "progress": "done", "sys": SYS}, actor=MEMBER).id for _ in range(extra_targets)]
        waiting = []
        for n in range(dependents):
            task = add("task", {"title": f"w{n}", "sys": SYS}, actor=MEMBER).id
            for target in (blocker, *finished):
                host.graph.add_relation(task, target, "depends_on", {}, actor=MEMBER)
            waiting.append(task)
    # Let the runtime see the seeded events, as it would have one command at a
    # time, and gather the links as the host does when it opens a fleet.
    while not host.runtime.run_quantum(max_queue_events=1_000, max_seconds=10.0).idle:
        pass
    host.depends_on = DependsOnLinks(host.graph)
    return blocker, waiting


def test_a_fan_out_past_the_attention_bound_asks_that_many_in_link_order_and_commits(fleet):
    blocker, waiting = _seed(fleet.host, MAX_ATTENTION * 4)

    done = fleet.submit(blocker)

    assert asked(done) == [("needs_review", blocker)] + [("task_unblocked", task) for task in waiting[: MAX_ATTENTION - 1]]
    assert fleet.host.graph.get_object(blocker).data["progress"] == "done"
    assert done["result"]["version"] == 2
    assert fleet.create("note", body="the fleet keeps writing")


def test_the_work_bound_cuts_a_check_short_and_never_announces_a_task_it_did_not_finish_checking(fleet):
    # Each dependent costs one read to reach and one per target. Sized so the
    # first 28 fit the bound exactly and the 29th would need just one more.
    per_dependent = 1 + 68
    assert (MAX_WORK + 1) % per_dependent == 0
    fits = MAX_WORK // per_dependent
    blocker, waiting = _seed(fleet.host, fits + 5, extra_targets=67)

    done = fleet.submit(blocker)

    assert fits < MAX_ATTENTION
    assert asked(done) == [("needs_review", blocker)] + [("task_unblocked", task) for task in waiting[:fits]]
    assert done["ok"] is True


def test_one_command_with_the_most_attention_still_settles_in_one_quantum():
    # A submission's change and the links to its evidence, every notice it
    # may ask and its ledger event.
    assert 1 + host_module.MAX_EVIDENCE + MAX_ATTENTION + 1 <= host_module._QUANTUM_EVENTS


def test_a_write_reads_only_the_links_of_the_objects_it_looks_at(fleet, monkeypatch):
    blocker, [waiting] = _seed(fleet.host, 1)
    other, [held] = _seed(fleet.host, 1)
    # Five thousand links elsewhere in the fleet, none touching either blocker.
    _seed(fleet.host, 500, extra_targets=9)
    [rel] = fleet.host.graph.relations(source=held, target=other)

    def scan(**_filters):
        raise AssertionError("a reaction read every link in the fleet")

    monkeypatch.setattr(fleet.host.graph, "relations", scan)

    assert asked(fleet.submit(blocker)) == [("needs_review", blocker), ("task_unblocked", waiting)]
    assert asked(fleet.unlink(rel.id)) == [("task_unblocked", held)]


def test_an_unlink_check_is_bounded_by_the_work_bound_too(fleet):
    # Once the blocker is unlinked, each target left costs one read.
    blocker, [waiting] = _seed(fleet.host, 1, extra_targets=MAX_WORK + 1)
    [rel] = fleet.host.graph.relations(source=waiting, target=blocker)

    assert asked(fleet.unlink(rel.id)) == []

    blocker, [waiting] = _seed(fleet.host, 1, extra_targets=MAX_WORK)
    [rel] = fleet.host.graph.relations(source=waiting, target=blocker)

    assert asked(fleet.unlink(rel.id)) == [("task_unblocked", waiting)]


# ---------- nothing a member sends asks for attention or moves a scope ----------


MEMBER_ATTEMPTS = [
    ("create", {"type": "note", "scope": "fleet", "data": {"title": "keyfleet.attention", "body": "kind: needs_review"}}),
    ("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "b", "kind": "needs_review"}}),
    ("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "b", "dedupe_key": "x"}}),
    ("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "b", "cause": {"event_id": "evt_001"}}}),
    ("create", {"type": "keyfleet.attention", "scope": "fleet", "data": {"title": "t"}}),
    ("patch", {"id": "task#1", "expected_version": 1, "set": {"kind": "task_unblocked"}}),
    ("patch", {"id": "task#1", "expected_version": 1, "set": {"sys": {"scope": "level:1"}}}),
    ("link", {"source": "task#1", "target": "task#2", "type": "keyfleet.attention"}),
    ("keyfleet.attention", {"kind": "needs_review", "object_id": "task#1"}),
    ("emit", {"type": "keyfleet.attention", "payload": {}}),
]


@pytest.mark.parametrize(("op", "body"), MEMBER_ATTEMPTS)
def test_no_member_request_writes_an_attention_event_or_moves_a_scope(fleet, op, body):
    fleet.create("task")
    fleet.create("task")

    reply = fleet.host.handle(json.dumps(request(op, body, command("attempt"))).encode())

    if reply["ok"]:
        assert attention(reply) == []
    assert not any(event.type == "keyfleet.attention" for event in fleet.host.graph.events)
    assert {obj.data["sys"]["scope"] for obj in fleet.host.graph.all_objects()} == {"fleet"}


@pytest.mark.parametrize("principal", [GATEWAY, "keyfleet:reactions", "system", "runtime"])
def test_a_command_cannot_be_made_in_the_gateway_name(fleet, principal):
    body = {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "b"}}

    reply = fleet.host.handle(json.dumps(request("create", body, {**command("x"), "principal": principal})).encode())

    assert reply["error"]["code"] == "bad_request"
