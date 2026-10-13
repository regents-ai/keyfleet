import io
import json
import sqlite3
from importlib import metadata

import activegraph
from activegraph import Event
import pytest
from activegraph.store.sqlite import SQLiteEventStore
import hashlib

from conftest import CONTRACT, WALLET, HostProcess, command, fleet_command, request

from keyfleet_graph import protocol
from keyfleet_graph.__main__ import EXIT_FAILED, EXIT_LOCKED
from keyfleet_graph.host import CHANGES_PAGE_BYTES, Host

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
    return b'{"v":1,"req":"deep","op":"changes","body":{"after_seq":' + b"[" * depth + b"]" * depth + b',"limit":1}}'


def _logged(host, event_type):
    """Every event of one type in a host process's log, oldest first."""
    page = host.send(request("changes", {"after_seq": 0, "limit": 500}))["result"]
    return [event for event in page["events"] if event["type"] == event_type]


FORBIDDEN_FIELDS = ["sys", "scope", "paid", "approved", "admin", "treasury_balance"]

# A scope is the fleet or one of the twenty levels, written exactly so.
MALFORMED_SCOPES = ["level:0", "level:21", "level:01", "level:1 ", "Level:1", "level:", "level:-1", "fleet:1", "*", ""]

# Embeddings, overrides and isolates, which can reorder how text displays.
BIDI_CONTROLS = [chr(code) for code in [*range(0x202A, 0x202F), *range(0x2066, 0x206A)]]

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
        ("invalid", request("create", {"type": "goal", "scope": "fleet", "data": {**GOAL, "title": f"pay{bidi}moc.exe"}}, command("c")))
        for bidi in BIDI_CONTROLS
    ],
    *[
        ("invalid", request("create", {"type": "note", "scope": "fleet", "data": {"title": "t", "body": f"line\n{bidi}two"}}, command("c")))
        for bidi in BIDI_CONTROLS
    ],
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
    ("forbidden_scope", request("create", {"type": "goal", "scope": "level:1", "data": GOAL}, command("c"))),
    ("forbidden_scope", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", scopes=("level:1",)))),
    *[
        ("bad_request", request("create", {"type": "goal", "scope": scope, "data": GOAL}, command("c")))
        for scope in MALFORMED_SCOPES
    ],
    *[
        ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", scopes=("fleet", scope))))
        for scope in MALFORMED_SCOPES
    ],
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", scopes=["fleet"] * 22))),
    ("bad_request", request("changes", {"after_seq": 2**63, "limit": 10})),
    ("bad_request", request("changes", {"after_seq": 2**70, "limit": 10})),
    ("bad_request", request("patch", {"id": "goal#1", "expected_version": 2**63, "set": {}}, command("c"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c", token_id=2**64))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c\x00"))),
    ("bad_request", request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, _with_auth(command("c"), checked_at="yesterday"))),
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
    b'{"v":1,"req":"surrogate","op":"changes","body":{"after_seq":"\\ud800","limit":1}}',
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
    assert [(rel.id, rel.type, rel.source, rel.target, rel.data) for rel in seeded.graph.relations()] == [
        (created["relation_id"], "supports", "finding#3", "goal#1", {"note": "the first customer said yes"})
    ]

    unscoped = _call(seeded, request("unlink", {"relation_id": created["relation_id"]}, command("u0", scopes=())))
    assert unscoped["error"]["code"] == "forbidden_scope"
    assert _ok(seeded, "unlink", {"relation_id": created["relation_id"]}, "u1") == {"relation_id": created["relation_id"]}
    assert seeded.graph.relations() == []
    relinked = _ok(seeded, "link", link, "l3")
    assert (relinked["existing"], relinked["relation_id"] != created["relation_id"]) == (False, True)


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

    assert seeded.graph.get_object(note["id"]).data["body"] == body


@pytest.mark.parametrize("blank", ["", "   "])
def test_a_goal_never_holds_an_empty_open_question(seeded, blank):
    create = {"type": "goal", "scope": "fleet", "data": {**GOAL, "open_questions": ["Who pays?", blank]}}
    patch = {"id": "goal#1", "expected_version": 2, "set": {"open_questions": [blank]}}

    assert _call(seeded, request("create", create, command("q1")))["error"]["code"] == "invalid"
    assert _call(seeded, request("patch", patch, command("q2")))["error"]["code"] == "invalid"

    asked = _ok(seeded, "create", {**create, "data": {**GOAL, "open_questions": ["Who pays?"]}}, "q3")
    assert seeded.graph.get_object(asked["id"]).data["open_questions"] == ["Who pays?"]


def test_a_reopened_host_serves_the_same_graph_and_ledger(db):
    first = HostProcess(db)
    assert first.send(request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c1")))["ok"]
    assert first.send(request("create", {"type": "task", "scope": "fleet", "data": {"title": "T"}}, command("c2")))["ok"]
    link = request("link", {"source": "task#2", "target": "goal#1", "type": "implements"}, command("c3"))
    assert first.send(link)["ok"]
    patch = request("patch", {"id": "task#2", "expected_version": 1, "set": {"progress": "doing"}}, command("c4"))
    assert first.send(patch)["ok"]
    assert first.send(request("archive", {"id": "goal#1", "expected_version": 1}, command("c5")))["ok"]
    before = first.send(request("changes", {"after_seq": 0, "limit": 500}))["result"]["events"]
    assert first.close() == 0

    reopened = HostProcess(db)

    # Reopening only appends the runtime's own bookkeeping.
    after = reopened.send(request("changes", {"after_seq": 0, "limit": 500}))["result"]["events"]
    assert after[: len(before)] == before
    assert {event["type"] for event in after[len(before) :]} <= {"runtime.loaded", "runtime.idle", "pack.loaded"}
    archived = request("patch", {"id": "goal#1", "expected_version": 2, "set": {"title": "x"}}, command("c6"))
    assert reopened.send(archived)["error"]["details"] == {"errors": [{"path": "id", "message": "the object is archived"}]}
    renamed = request("patch", {"id": "task#2", "expected_version": 2, "set": {"title": "T2"}}, command("c7"))
    assert reopened.send(renamed)["result"] == {"id": "task#2", "version": 3}
    replay = reopened.send(patch)
    assert (replay["replayed"], replay["result"]) == (True, {"id": "task#2", "version": 2})
    assert reopened.send(link)["replayed"] is True
    assert reopened.close() == 0


def test_the_log_id_is_minted_with_the_file_and_kept_across_restarts(db, tmp_path):
    first = HostProcess(db)
    log_id = first.send(request("hello", {}))["result"]["run_id"]
    created = first.send(request("create", {"type": "goal", "scope": "fleet", "data": GOAL}, command("c1")))
    changes = first.send(request("changes", {"after_seq": 0, "limit": 500}))["result"]
    assert first.close() == 0

    assert log_id.startswith("log_") and len(log_id) == len("log_") + 32
    assert created["run_id"] == changes["run_id"] == log_id

    reopened = HostProcess(db)
    assert reopened.send(request("hello", {}))["result"]["run_id"] == log_id
    assert reopened.close() == 0

    # The same fleet on a new file is a new log, whatever it holds.
    fresh = HostProcess(tmp_path / "fresh.sqlite")
    assert fresh.send(request("hello", {}))["result"]["run_id"] not in (log_id, None)
    assert fresh.close() == 0


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
    patches = [event["payload"]["patch"] for event in _logged(host, "patch.applied")]
    assert [(patch["target"], patch["value"]) for patch in patches] == [("goal#1", {"status": "dropped"})]
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
    assert _logged(host, "object.created") == []
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
    assert [event["payload"]["object"]["id"] for event in _logged(host, "object.created")] == ["goal#1"]
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


def test_right_to_left_text_is_kept_as_written(db):
    host = Host("fleet_a", str(db))
    title = "خدمة العملاء \U0001F680"

    created = _ok(host, "create", {"type": "goal", "scope": "fleet", "data": {**GOAL, "title": title}}, "rtl")

    assert host.graph.get_object(created["id"]).data["title"] == title


def test_emoji_joined_with_a_zero_width_joiner_are_kept_as_written(db):
    host = Host("fleet_a", str(db))
    family = "Crew \U0001F469‍\U0001F469‍\U0001F467"
    mechanic = "\U0001F9D1‍\U0001F527 on shift"

    goal = _ok(host, "create", {"type": "goal", "scope": "fleet", "data": {**GOAL, "title": family}}, "zwj1")
    note = _ok(host, "create", {"type": "note", "scope": "fleet", "data": {"title": mechanic, "body": f"{family}\n{mechanic}"}}, "zwj2")

    assert host.graph.get_object(goal["id"]).data["title"] == family
    stored = host.graph.get_object(note["id"]).data
    assert (stored["title"], stored["body"]) == (mechanic, f"{family}\n{mechanic}")


def _copy(code="import marimo\n", **fields):
    digest = "sha256:" + hashlib.sha256(code.encode("utf-8")).hexdigest()
    data = {"title": "Sales", "notebook_id": "nb_1", "hub_updated_at": "2026-10-13T12:00:00Z", "digest": digest, "code": code}
    return {"type": "notebook_copy", "scope": "fleet", "data": {**data, **fields}}


def _refusal(host, op, body, cmd):
    reply = _call(host, request(op, body, cmd))
    assert not reply["ok"], reply
    return reply["error"]["code"]


def test_the_fleet_keeps_one_copy_of_each_notebook_and_asks_nobody_to_look(seeded):
    head = _call(seeded, request("hello", {}))["result"]["head_seq"]

    kept = _call(seeded, request("create", _copy(), fleet_command("f1")))["result"]
    again = _call(seeded, request("create", _copy(), fleet_command("f2")))
    newer = _copy("import marimo\napp = marimo.App()\n")["data"]
    changed = {"id": kept["id"], "expected_version": 1, "set": {"code": newer["code"], "digest": newer["digest"]}}
    patched = _call(seeded, request("patch", changed, fleet_command("f3")))

    stored = seeded.graph.get_object(kept["id"]).data
    assert stored["sys"]["created_by"] == {"kind": "fleet", "fleet": {"chain_id": 8453, "contract": CONTRACT}}
    assert (again["error"]["code"], again["error"]["details"]["object"]["id"]) == ("conflict", kept["id"])
    assert (patched["ok"], stored["code"]) == (True, newer["code"])
    written = seeded._events_after(head)
    assert {event["actor"] for event in written if event["type"].startswith("object.")} == {f"fleet:8453:{CONTRACT}"}
    assert [event for event in written if event["type"] == "keyfleet.attention"] == []


def test_the_fleet_writes_only_its_copies_and_only_in_the_fleet_scope(seeded):
    goal = {"type": "goal", "scope": "fleet", "data": GOAL}

    assert _refusal(seeded, "create", goal, fleet_command("f1")) == "forbidden_type"
    assert _refusal(seeded, "patch", {"id": "goal#1", "expected_version": 2, "set": {"title": "T"}}, fleet_command("f2")) == "forbidden_type"
    assert _refusal(seeded, "archive", {"id": "goal#1", "expected_version": 2}, fleet_command("f3")) == "forbidden_op"
    assert _refusal(seeded, "link", {"source": "task#2", "target": "goal#1", "type": "implements"}, fleet_command("f4")) == "forbidden_op"
    assert _refusal(seeded, "unlink", {"relation_id": "rel#1"}, fleet_command("f5")) == "forbidden_op"
    assert _refusal(seeded, "create", _copy(), fleet_command("f6", scopes=("fleet", "level:1"))) == "bad_request"
    assert _refusal(seeded, "create", _copy(), {**fleet_command("f7"), "principal": command("f7")["principal"]}) == "bad_request"


def test_a_member_never_writes_archives_or_links_the_fleets_copy(seeded):
    kept = _call(seeded, request("create", _copy(), fleet_command("f1")))["result"]["id"]

    assert _refusal(seeded, "create", _copy(notebook_id="nb_2"), command("m1")) == "forbidden_type"
    assert _refusal(seeded, "patch", {"id": kept, "expected_version": 1, "set": {"title": "Mine"}}, command("m2")) == "forbidden_type"
    assert _refusal(seeded, "archive", {"id": kept, "expected_version": 1}, command("m3")) == "forbidden_type"
    assert _refusal(seeded, "link", {"source": "goal#1", "target": kept, "type": "references"}, command("m4")) == "invalid"
    assert seeded.graph.get_object(kept).version == 1


@pytest.mark.parametrize(
    "data",
    [
        _copy("x" * 262_145)["data"],
        _copy("é" * 131_073)["data"],
        {**_copy()["data"], "digest": "sha256:" + "0" * 64},
        _copy("a = 1\r\n")["data"],
        _copy("a = '\u202e'\n")["data"],
        {**_copy()["data"], "notebook_id": "nb\n1"},
    ],
    ids=["too many bytes", "too many bytes in fewer characters", "a digest of other code", "a carriage return", "a direction override", "a control character in the notebook's id"],
)
def test_a_copy_holds_only_code_that_fits_and_matches_its_digest(seeded, data):
    assert _refusal(seeded, "create", {"type": "notebook_copy", "scope": "fleet", "data": data}, fleet_command("f1")) == "invalid"


def test_a_copy_keeps_its_code_exactly_and_stays_with_its_notebook(seeded, db):
    code = "\n\timport marimo\n\n"
    kept = _call(seeded, request("create", _copy(code), fleet_command("f1")))["result"]["id"]
    moved = {"id": kept, "expected_version": 1, "set": {"notebook_id": "nb_2"}}

    assert seeded.graph.get_object(kept).data["code"] == code
    assert _refusal(seeded, "patch", moved, fleet_command("f2")) == "forbidden_field"
    # A reopened host still knows which notebook each copy is of.
    assert Host("fleet_a", str(db))._copies == {"nb_1": kept}
