import io
import json
import sqlite3
from importlib import metadata

import activegraph
from activegraph import Event
import pytest
from activegraph.store.sqlite import SQLiteEventStore
from conftest import CONTRACT, WALLET, HostProcess, command, request

from keyfleet_graph import protocol
from keyfleet_graph.__main__ import EXIT_FAILED, EXIT_LOCKED
from keyfleet_graph.host import CHANGES_PAGE_BYTES, RELATION_PAGE, Host

PINNED_VERSION = "1.10.0"
PINNED_COMMIT = "8aedb1866cf5dce056af97529152ffd6f468a1ed"

GOAL = {"title": "Serve one customer", "outcome": "A paying customer"}


def _call(host, message):
    return host.handle(json.dumps(message).encode("utf-8"))


def _ok(host, op, body, command_id):
    reply = _call(host, request(op, body, command(command_id)))
    assert reply["ok"], reply
    return reply["result"]


@pytest.fixture
def seeded(db):
    """A host holding a goal at version 2, a task, a finding and an archived note."""
    host = Host("fleet_a", str(db))
    _ok(host, "create", {"type": "goal", "scope": "fleet", "data": GOAL}, "s1")
    _ok(host, "create", {"type": "task", "scope": "fleet", "data": {"title": "Draft"}}, "s2")
    _ok(host, "create", {"type": "finding", "scope": "fleet", "data": {"title": "F", "statement": "S"}}, "s3")
    _ok(host, "create", {"type": "note", "scope": "fleet", "data": {"title": "N", "body": "B"}}, "s4")
    _ok(host, "archive", {"id": "note#4", "expected_version": 1}, "s5")
    _ok(host, "patch", {"id": "goal#1", "expected_version": 1, "set": {"status": "achieved"}}, "s6")
    return host


def _with_auth(cmd, **auth):
    return {**cmd, "auth": {**cmd["auth"], **auth}}


def _deep(depth):
    return b'{"v":1,"req":"deep","op":"get","body":{"id":' + b"[" * depth + b"]" * depth + b"}}"


FORBIDDEN_FIELDS = ["sys", "paid", "approved", "admin", "treasury_balance"]

REFUSALS = [
    ("conflict", request("patch", {"id": "goal#1", "expected_version": 1, "set": {"title": "x"}}, command("c"))),
    ("conflict", request("archive", {"id": "goal#1", "expected_version": 1}, command("c"))),
    ("invalid", request("create", {"type": "goal", "scope": "fleet", "data": {"title": "t"}}, command("c"))),
    ("invalid", request("create", {"type": "goal", "scope": "fleet", "data": {**GOAL, "title": "x" * 201}}, command("c"))),
    ("invalid", request("create", {"type": "receipt", "scope": "fleet", "data": {"title": "t"}}, command("c"))),
    ("invalid", request("patch", {"id": "note#4", "expected_version": 2, "set": {"body": "b"}}, command("c"))),
    ("invalid", request("patch", {"id": "task#2", "expected_version": 1, "set": {"progress": "later"}}, command("c"))),
    ("invalid", request("link", {"source": "finding#3", "target": "goal#1", "type": "owns"}, command("c"))),
    ("invalid", request("link", {"source": "goal#1", "target": "finding#3", "type": "supports"}, command("c"))),
    ("invalid", request("link", {"source": "task#2", "target": "task#2", "type": "depends_on"}, command("c"))),
    ("invalid", request("link", {"source": "finding#3", "target": "note#4", "type": "references"}, command("c"))),
    ("invalid", request("patch", {"id": "task#2", "expected_version": 1}, command("c"))),
    ("invalid", request("patch", {"id": "task#2", "expected_version": 1, "set": {"title": "Draft"}}, command("c"))),
    ("invalid", request("patch", {"id": "task#2", "expected_version": 1, "unset": ["next_step"]}, command("c"))),
    ("invalid", request("create", {"type": "goal", "scope": "fleet", "data": {**GOAL, "title": "a\x00b"}}, command("c"))),
    ("invalid", request("create", {"type": "goal", "scope": "fleet", "data": {**GOAL, "title": "two\nlines"}}, command("c"))),
    ("invalid", request("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "bell\x07"}}, command("c"))),
    ("invalid", request("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "cr\rlf"}}, command("c"))),
    ("invalid", request("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": "c1\x85c1"}}, command("c"))),
    ("invalid", request("link", {"source": "finding#3", "target": "goal#1", "type": "supports", "note": "a\tb"}, command("c"))),
    *[
        ("forbidden_field", request("create", {"type": "goal", "scope": "fleet", "data": {**GOAL, field: True}}, command("c")))
        for field in FORBIDDEN_FIELDS
    ],
    *[
        ("forbidden_field", request("patch", {"id": "task#2", "expected_version": 1, "set": {field: True}}, command("c")))
        for field in FORBIDDEN_FIELDS
    ],
    ("forbidden_field", request("patch", {"id": "task#2", "expected_version": 1, "unset": ["sys"]}, command("c"))),
    ("forbidden_field", request("patch", {"id": "task#2", "expected_version": 1, "set": {"assignee_key": 99}}, command("c"))),
    ("forbidden_scope", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", scopes=()))),
    ("forbidden_scope", request("patch", {"id": "goal#1", "expected_version": 2, "set": {"title": "x"}}, command("c", scopes=()))),
    ("forbidden_scope", request("link", {"source": "finding#3", "target": "goal#1", "type": "supports"}, command("c", scopes=()))),
    ("not_found", request("get", {"id": "goal#404"})),
    ("not_found", request("patch", {"id": "goal#404", "expected_version": 1, "set": {}}, command("c"))),
    ("not_found", request("link", {"source": "finding#3", "target": "goal#404", "type": "supports"}, command("c"))),
    ("not_found", request("unlink", {"relation_id": "rel_404"}, command("c"))),
    ("duplicate_mismatch", request("create", {"type": "task", "scope": "fleet", "data": {"title": "Other"}}, command("s2"))),
    ("duplicate_mismatch", request("archive", {"id": "task#2", "expected_version": 1}, command("s2"))),
    ("bad_request", {"v": 2, "req": "r", "op": "hello", "body": {}}),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL})),
    ("bad_request", request("hello", {}, command("c"))),
    ("bad_request", request("changes", {"after_seq": 0, "limit": 501})),
    ("bad_request", request("patch", {"id": "goal#1", "set": {}}, command("c"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, {**command("c"), "principal": "system"})),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", wallet="0x" + WALLET[2:].upper()))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", contract="0x" + CONTRACT[2:].upper()))),
    ("bad_request", request("create", {"type": "goal", "scope": "level:1", "data": GOAL}, command("c"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", scopes=("level:1",)))),
    ("bad_request", request("changes", {"after_seq": 2**63, "limit": 10})),
    ("bad_request", request("changes", {"after_seq": 2**70, "limit": 10})),
    ("bad_request", request("patch", {"id": "goal#1", "expected_version": 2**63, "set": {}}, command("c"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", token_id=2**64))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c\x00"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, _with_auth(command("c"), checked_at="yesterday"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, _with_auth(command("c"), pairing_id="p" * 5000))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, _with_auth(command("c"), credential_ref="receipt"))),
]


@pytest.mark.parametrize(("code", "message"), REFUSALS)
def test_each_refusal_names_its_code_and_writes_nothing(seeded, code, message):
    head = _call(seeded, request("hello", {}))["result"]["head_seq"]

    reply = _call(seeded, message)

    assert reply["ok"] is False
    assert reply["error"]["code"] == code, reply
    assert _call(seeded, request("hello", {}))["result"]["head_seq"] == head


RUNTIME_OPS = [
    "emit",
    "load_pack",
    "fork",
    "promote",
    "compact",
    "truncate_after",
    "remove_object",
    "run_quantum",
    "propose_patch",
    "system_record",
    "import",
    "",
]


@pytest.mark.parametrize("op", RUNTIME_OPS)
def test_every_op_outside_the_allowlist_is_a_bad_request(seeded, op):
    for message in (request(op, {}), request(op, {}, command("c"))):
        reply = _call(seeded, message)

        assert reply["error"]["code"] == "bad_request"
        assert reply["error"]["message"] == f"unknown op {op!r}"


def test_a_frame_that_is_not_json_is_a_bad_request(seeded):
    reply = seeded.handle(b"\x00not json")

    assert (reply["req"], reply["ok"], reply["error"]["code"]) == (None, False, "bad_request")


HOSTILE_FRAMES = [
    _deep(10_000),
    json.dumps(request("changes", {"after_seq": 2**70, "limit": 10}, req="huge")).encode(),
    b'{"v":1,"req":"nan","op":"changes","body":{"after_seq":NaN,"limit":1}}',
    b'{"v":1,"req":"surrogate","op":"get","body":{"id":"\\ud800"}}',
]


@pytest.mark.parametrize("frame", HOSTILE_FRAMES)
def test_a_hostile_frame_is_refused_and_the_host_keeps_serving(db, frame):
    host = HostProcess(db)
    host.proc.stdin.write(len(frame).to_bytes(4, "big") + frame)
    host.proc.stdin.flush()

    reply = json.loads(protocol.read_frame(host.proc.stdout))

    assert (reply["ok"], reply["error"]["code"]) == (False, "bad_request")
    assert host.send(request("hello", {}))["ok"] is True
    assert host.close() == 0


def test_an_oversized_frame_is_refused_from_its_header_and_the_host_serves_the_next_frame(db):
    host = HostProcess(db)
    body = b"x" * (protocol.MAX_REQUEST_BYTES + 1)
    host.proc.stdin.write(len(body).to_bytes(4, "big") + body)
    host.proc.stdin.flush()

    reply = json.loads(protocol.read_frame(host.proc.stdout))

    assert (reply["req"], reply["ok"], reply["error"]["code"]) == (None, False, "bad_request")
    assert reply["error"]["message"] == "the request is larger than 1 MiB"
    assert host.send(request("hello", {}))["ok"] is True
    assert host.close() == 0


def test_an_oversized_frame_is_read_past_in_pieces_without_being_kept():
    class Reads(io.BytesIO):
        largest = 0

        def read(self, size=-1):
            Reads.largest = max(Reads.largest, size)
            return super().read(size)

    oversized = protocol.MAX_REQUEST_BYTES * 4
    stream = Reads(oversized.to_bytes(4, "big") + b"x" * oversized + (2).to_bytes(4, "big") + b"{}")

    assert isinstance(protocol.read_frame(stream), protocol.TooLarge)
    assert protocol.read_frame(stream) == b"{}"
    assert Reads.largest <= 1 << 16


def test_a_refused_envelope_is_answered_under_its_request_id_and_an_unreadable_frame_under_none(seeded):
    refused = _call(seeded, {**request("hello", {}, req="r-bad"), "v": 2})
    unreadable = seeded.handle(_deep(300))

    assert (refused["req"], refused["error"]["code"]) == ("r-bad", "bad_request")
    assert (unreadable["req"], unreadable["error"]["code"]) == (None, "bad_request")


def test_a_link_is_idempotent_on_its_triple_and_an_unlink_removes_it(seeded):
    link = {"source": "finding#3", "target": "goal#1", "type": "supports", "note": "the first customer said yes"}

    created = _ok(seeded, "link", link, "l1")
    again = _ok(seeded, "link", {**link, "note": None}, "l2")

    assert created["existing"] is False
    assert again == {"relation_id": created["relation_id"], "existing": True}
    got = _call(seeded, request("get", {"id": "goal#1"}))["result"]
    assert got["relations"] == [
        {
            "id": created["relation_id"],
            "type": "supports",
            "source": "finding#3",
            "target": "goal#1",
            "data": {"note": "the first customer said yes"},
        }
    ]
    assert got["relations_has_more"] is False
    assert _call(seeded, request("get", {"id": "finding#3"}))["result"]["relations"] == got["relations"]

    unscoped = _call(seeded, request("unlink", {"relation_id": created["relation_id"]}, command("u0", scopes=())))
    assert unscoped["error"]["code"] == "forbidden_scope"
    assert _ok(seeded, "unlink", {"relation_id": created["relation_id"]}, "u1") == {"relation_id": created["relation_id"]}
    assert _call(seeded, request("get", {"id": "goal#1"}))["result"]["relations"] == []
    relinked = _ok(seeded, "link", link, "l3")
    assert (relinked["existing"], relinked["relation_id"] != created["relation_id"]) == (False, True)


def test_get_returns_the_first_page_of_relations_and_says_more_exist(db):
    host = Host("fleet_a", str(db))
    _ok(host, "create", {"type": "goal", "scope": "fleet", "data": GOAL}, "g")
    for n in range(RELATION_PAGE + 1):
        found = _ok(host, "create", {"type": "finding", "scope": "fleet", "data": {"title": f"F{n}", "statement": "S"}}, f"f{n}")
        _ok(host, "link", {"source": found["id"], "target": "goal#1", "type": "supports"}, f"l{n}")

    got = _call(host, request("get", {"id": "goal#1"}))["result"]

    assert (len(got["relations"]), got["relations_has_more"]) == (RELATION_PAGE, True)


def _all_changes(host, limit):
    events, after, pages = [], 0, 0
    while True:
        page = _call(host, request("changes", {"after_seq": after, "limit": limit}))["result"]
        events += page["events"]
        after, pages = page["next_seq"], pages + 1
        if not page["has_more"]:
            return events, page, pages


def test_changes_pages_through_every_event_exactly_once(seeded):
    events, last, pages = _all_changes(seeded, 4)

    assert [event["seq"] for event in events] == list(range(1, last["head_seq"] + 1))
    assert last["next_seq"] == last["head_seq"]
    assert pages == -(-last["head_seq"] // 4)
    beyond = _call(seeded, request("changes", {"after_seq": last["head_seq"], "limit": 4}))["result"]
    assert (beyond["events"], beyond["next_seq"], beyond["has_more"]) == ([], last["head_seq"], False)


def test_a_changes_page_stops_at_its_byte_budget_and_the_cursor_continues(db):
    host = Host("fleet_a", str(db))
    for n in range(60):
        _ok(host, "create", {"type": "note", "scope": "fleet", "data": {"title": f"N{n}", "body": "x" * 20_000}}, f"n{n}")

    first = _call(host, request("changes", {"after_seq": 0, "limit": 500}))["result"]
    events, last, _pages = _all_changes(host, 500)

    assert first["has_more"] is True
    assert len(json.dumps(first["events"]).encode()) <= CHANGES_PAGE_BYTES
    assert [event["seq"] for event in events] == list(range(1, last["head_seq"] + 1))


def test_multi_line_text_keeps_its_newlines_and_tabs(seeded):
    body = "first line\n\tindented"
    note = _ok(seeded, "create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": body}}, "m1")

    assert _call(seeded, request("get", {"id": note["id"]}))["result"]["object"]["data"]["body"] == body


def test_a_reopened_host_serves_the_same_graph_and_ledger(db):
    first = HostProcess(db)
    assert first.send(request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c1")))["ok"]
    assert first.send(request("create", {"type": "task", "scope": "fleet", "data": {"title": "T"}}, command("c2")))["ok"]
    link = request("link", {"source": "task#2", "target": "goal#1", "type": "implements"}, command("c3"))
    assert first.send(link)["ok"]
    patch = request("patch", {"id": "task#2", "expected_version": 1, "set": {"progress": "doing"}}, command("c4"))
    assert first.send(patch)["ok"]
    assert first.send(request("archive", {"id": "goal#1", "expected_version": 1}, command("c5")))["ok"]
    before = [first.send(request("get", {"id": object_id}))["result"] for object_id in ("goal#1", "task#2")]
    assert first.close() == 0

    reopened = HostProcess(db)

    assert [reopened.send(request("get", {"id": object_id}))["result"] for object_id in ("goal#1", "task#2")] == before
    replay = reopened.send(patch)
    assert (replay["replayed"], replay["result"]) == (True, {"id": "task#2", "version": 2})
    assert reopened.send(link)["replayed"] is True
    assert reopened.close() == 0


CRASH_AFTER_COMMIT = """
import os
from keyfleet_graph import protocol
_write = protocol.write_frame
def write_frame(stream, message):
    if message.get("ok") and message.get("replayed") is False:
        os._exit(9)
    _write(stream, message)
protocol.write_frame = write_frame
"""


def test_a_retry_after_a_crash_between_commit_and_reply_returns_the_original_result(db):
    create = request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c1"))
    patch = request("patch", {"id": "goal#1", "expected_version": 1, "set": {"status": "dropped"}}, command("c2"))
    other = request("patch", {"id": "goal#1", "expected_version": 1, "set": {"status": "achieved"}}, command("c2"))

    host = HostProcess(db)
    assert host.send(create)["result"] == {"id": "goal#1", "version": 1}
    assert host.close() == 0

    crashing = HostProcess(db, patch=CRASH_AFTER_COMMIT)
    assert crashing.send(patch) is None
    assert crashing.wait() == 9

    host = HostProcess(db)
    retried = host.send(patch)
    assert retried["replayed"] is True
    assert retried["result"] == {"id": "goal#1", "version": 2}
    assert host.send(other)["error"] == {
        "code": "duplicate_mismatch",
        "message": "this command id was already used with a different body",
        "details": {"command_id": "c2"},
    }
    got = host.send(request("get", {"id": "goal#1"}))["result"]["object"]
    assert (got["version"], got["data"]["status"]) == (2, "dropped")
    assert host.close() == 0


APPEND_FAILURE = """
import sqlite3
from activegraph.store.sqlite import SQLiteEventStore
_append = SQLiteEventStore.append
def append(self, event):
    if event.type == "object.created" and event.payload["object"]["data"]["title"] == "doomed":
        raise sqlite3.OperationalError("disk I/O error (simulated)")
    _append(self, event)
SQLiteEventStore.append = append
"""


# Ends the process after every append of a command, including its ledger
# event and the runtime's settling events, and before COMMIT.
KILL_BEFORE_COMMIT = """
import os
from keyfleet_graph.host import Host
_settle = Host._settle
def settle(self):
    _settle(self)
    if hasattr(self, "_ledger"):
        os._exit(9)
Host._settle = settle
"""


def test_a_kill_inside_the_commit_leaves_nothing_and_the_retry_applies_once(db):
    create = request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c1"))

    dying = HostProcess(db, patch=KILL_BEFORE_COMMIT)
    assert dying.send(create) is None
    assert dying.wait() == 9

    host = HostProcess(db)
    assert host.send(request("get", {"id": "goal#1"}))["error"]["code"] == "not_found"
    retried = host.send(create)
    assert (retried["replayed"], retried["result"]) == (False, {"id": "goal#1", "version": 1})
    assert host.send(create)["replayed"] is True
    assert host.close() == 0


def test_an_append_failure_ends_the_host_and_a_reload_holds_only_durable_state(db):
    kept = request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c1"))
    doomed = request("create", {"type": "task", "scope": "fleet", "data": {"title": "doomed"}}, command("c2"))

    failing = HostProcess(db, patch=APPEND_FAILURE)
    assert failing.send(kept)["result"] == {"id": "goal#1", "version": 1}
    assert failing.send(doomed) is None
    assert failing.wait() == EXIT_FAILED

    host = HostProcess(db)
    assert host.send(request("get", {"id": "goal#1"}))["ok"] is True
    assert host.send(request("get", {"id": "task#2"}))["error"]["code"] == "not_found"
    retried = host.send(doomed)
    assert (retried["replayed"], retried["result"]) == (False, {"id": "task#2", "version": 1})
    assert host.close() == 0


def test_a_second_host_on_the_same_run_exits_locked(db):
    first = HostProcess(db)
    assert first.send(request("hello", {}))["ok"] is True

    second = HostProcess(db)
    assert second.wait() == EXIT_LOCKED
    assert first.close() == 0


def test_the_private_seams_of_the_pinned_activegraph_hold(db):
    """The host's transaction relies on the store's connection being autocommit.

    Upstream constructs its own store in `Runtime.load`, so the host reaches
    `store._conn` and issues BEGIN on it. Any upstream change to the version,
    the store class or its isolation mode must fail here before it ships.
    """
    direct_url = json.loads(metadata.distribution("activegraph").read_text("direct_url.json"))
    assert activegraph.__version__ == PINNED_VERSION
    assert direct_url["vcs_info"]["commit_id"] == PINNED_COMMIT

    host = Host("fleet_a", str(db))
    store = host.graph.store
    assert type(store) is SQLiteEventStore
    assert store._conn.isolation_level is None
    assert store._conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert store._conn.execute("PRAGMA synchronous").fetchone()[0] == 2  # FULL

    outside = sqlite3.connect(db)
    durable = outside.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    store._conn.execute("BEGIN IMMEDIATE")
    store.append(Event(id="evt_probe", type="probe", payload={}, actor="probe", timestamp=host.graph.clock.now()))
    assert outside.execute("SELECT COUNT(*) FROM events").fetchone()[0] == durable
    store._conn.execute("ROLLBACK")
    assert store._conn.execute("SELECT COUNT(*) FROM events").fetchone()[0] == durable
