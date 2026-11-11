"""Submitting a task for review, and the receipts its reviews leave."""

import json

import pytest
from conftest import WALLET, command, request

from keyfleet_graph.host import Host

OTHER_WALLET = "0x" + "c3" * 20
EVIDENCE = {"title": "Source", "source_uri": "https://example.com/source"}


def _call(host, op, body, cmd):
    return host.handle(json.dumps(request(op, body, cmd)).encode("utf-8"))


def _ok(host, op, body, cmd):
    reply = _call(host, op, body, cmd)
    assert reply["ok"], reply
    return reply["result"]


def _review(task_version, decision="accept", **extra):
    return {
        "task": "task#1",
        "task_version": task_version,
        "decision": decision,
        "rationale": "Checked the result against the deliverable.",
        "conflicts_of_interest": "none",
        **extra,
    }


# Key 17 on WALLET submits; Key 18 on another wallet reviews.
SUBMITTER = {"token_id": 17}
REVIEWER = {"token_id": 18, "wallet": OTHER_WALLET}


@pytest.fixture
def host(db):
    host = Host("fleet_a", str(db), [])
    _ok(host, "create", {"project": "general", "type": "task", "data": {"title": "Draft"}}, command("t"))
    _ok(host, "create", {"project": "general", "type": "evidence", "data": EVIDENCE}, command("e1"))
    _ok(host, "create", {"project": "general", "type": "evidence", "data": EVIDENCE}, command("e2"))
    return host


def _submit(host, command_id, version, **body):
    payload = {"id": "task#1", "expected_version": version, "evidence": ["evidence#2", "evidence#3"], **body}
    return _ok(host, "submit", payload, command(command_id, **SUBMITTER))


def test_a_submission_marks_the_task_done_with_its_result_and_links_its_evidence_once(host):
    _submit(host, "s1", 1, result_ref="https://example.com/result", evidence=["evidence#2", "evidence#3", "evidence#2"])
    again = _submit(host, "s2", 2, result_ref="https://example.com/result-2")

    task = host.graph.get_object("task#1")
    assert again == {"id": "task#1", "version": 3}
    assert (task.data["progress"], task.data["result_ref"]) == ("done", "https://example.com/result-2")
    assert task.data["sys"]["submitted"] == {
        "key": {"chain_id": 8453, "contract": task.data["sys"]["created_by"]["key"]["contract"], "token_id": 17},
        "ownership_epoch": 3,
        "kind": "agent",
        "wallet": WALLET,
        "version": 3,
        "evidence": ["evidence#2", "evidence#3"],
    }
    assert task.version == 3
    produced = host.graph.relations(source="task#1", type="produces")
    assert sorted(rel.target for rel in produced) == ["evidence#2", "evidence#3"]


def test_a_key_submits_a_task_once_it_has_joined_it(host):
    refused = _call(host, "submit", {"id": "task#1", "expected_version": 1, "result_ref": "ipfs://cid"}, command("s", **REVIEWER))
    assert refused["error"]["code"] == "not_owner"

    _ok(host, "join", {"id": "task#1"}, command("j", **REVIEWER))
    _ok(host, "submit", {"id": "task#1", "expected_version": 2, "result_ref": "ipfs://cid"}, command("s2", **REVIEWER))

    assert host.graph.get_object("task#1").data["sys"]["submitted"]["key"]["token_id"] == REVIEWER["token_id"]


def test_a_review_records_its_decision_and_binds_itself_to_the_version_and_evidence_it_judged(host):
    _ok(host, "patch", {"id": "evidence#2", "expected_version": 1, "set": {"excerpt": "quote"}}, command("ex"))
    _submit(host, "s1", 1, result_ref="https://example.com/result")

    result = _ok(host, "review", _review(2, "dispute", conflicts_of_interest="I share in this fleet's treasury."), command("r", **REVIEWER))

    review = host.graph.get_object(result["id"])
    assert review.type == "review"
    assert {field: review.data[field] for field in ("decision", "rationale", "conflicts_of_interest")} == {
        "decision": "dispute",
        "rationale": "Checked the result against the deliverable.",
        "conflicts_of_interest": "I share in this fleet's treasury.",
    }
    receipt = review.data["sys"]["review"]
    assert (receipt["task"], receipt["task_version"]) == ("task#1", 2)
    assert (receipt["submitted_by"]["key"]["token_id"], receipt["submitted_by"]["wallet"]) == (17, WALLET)
    assert receipt["evidence"] == [{"id": "evidence#2", "version": 2}, {"id": "evidence#3", "version": 1}]
    assert review.data["sys"]["created_by"]["key"]["token_id"] == 18
    assert [(rel.source, rel.target) for rel in host.graph.relations(type="reviews")] == [(result["id"], "task#1")]


@pytest.mark.parametrize("reviewer", [SUBMITTER, {"token_id": 18}, {"token_id": 17, "wallet": OTHER_WALLET}])
def test_the_key_or_wallet_that_submitted_a_task_cannot_review_it(host, reviewer):
    _submit(host, "s1", 1)

    reply = _call(host, "review", _review(2), command("r", **reviewer))

    assert reply["error"]["code"] == "self_review"
    assert host.graph.relations(type="reviews") == []


def test_a_key_that_joined_a_task_cannot_review_it_and_another_key_can(host):
    _ok(host, "join", {"id": "task#1"}, command("j", **REVIEWER))
    _submit(host, "s1", 2)

    refused = _call(host, "review", _review(3), command("r", **REVIEWER))
    other = {"token_id": 19, "wallet": "0x" + "c3" * 20}

    assert refused["error"]["code"] == "self_review"
    assert _ok(host, "review", _review(3), command("r2", **other))["id"].startswith("review#")


def test_a_review_names_the_version_it_read_and_a_key_reviews_each_version_once(host):
    _submit(host, "s1", 1)

    assert _call(host, "review", _review(1), command("stale", **REVIEWER))["error"]["code"] == "conflict"
    _ok(host, "review", _review(2), command("r1", **REVIEWER))
    assert _call(host, "review", _review(2, "dispute"), command("r2", **REVIEWER))["error"]["code"] == "invalid"

    _submit(host, "s2", 2)
    _ok(host, "review", _review(3, "dispute"), command("r3", **REVIEWER))
    assert len(host.graph.relations(type="reviews")) == 2


def test_a_task_moved_back_to_doing_takes_no_review_until_it_is_submitted_again(host):
    _submit(host, "s1", 1)
    _ok(host, "patch", {"id": "task#1", "expected_version": 2, "set": {"progress": "doing"}}, command("reopen"))

    assert _call(host, "review", _review(3), command("r", **REVIEWER))["error"]["code"] == "invalid"


def test_a_review_stays_as_written(host):
    _submit(host, "s1", 1)
    review = _ok(host, "review", _review(2), command("r", **REVIEWER))["id"]
    [rel] = host.graph.relations(type="reviews")

    attempts = [
        ("patch", {"id": review, "expected_version": 1, "set": {"decision": "dispute"}}),
        ("archive", {"id": review, "expected_version": 1}),
        ("unlink", {"relation_id": rel.id}),
        ("link", {"source": review, "target": "task#1", "type": "references"}),
        ("link", {"source": review, "target": "task#1", "type": "reviews"}),
        ("create", {"project": "general", "type": "review", "data": {"decision": "accept", "rationale": "r", "conflicts_of_interest": "none"}}),
    ]
    for n, (op, body) in enumerate(attempts):
        reply = _call(host, op, body, command(f"a{n}", **REVIEWER))
        assert reply["error"]["code"] == "invalid", (op, reply)

    assert host.graph.get_object(review).version == 1


COMMIT = "https://keyfleet.ai/classic/1/code/classic_1/commits/" + "a" * 40


def test_a_review_says_whether_it_reproduced_the_work_from_the_commit_the_task_named(host):
    _ok(host, "patch", {"id": "task#1", "expected_version": 1, "set": {"commit_ref": COMMIT}}, command("pin"))
    _submit(host, "s1", 2, result_ref="https://example.com/result")

    result = _ok(host, "review", _review(3, reproduction="passed"), command("r", **REVIEWER))

    review = host.graph.get_object(result["id"])
    assert review.data["reproduction"] == "passed"
    assert review.data["sys"]["review"]["commit_ref"] == COMMIT


def test_a_review_that_could_not_reproduce_the_work_disputes_it(host):
    _submit(host, "s1", 1)

    reply = _call(host, "review", _review(2, "accept", reproduction="failed"), command("r1", **REVIEWER))
    assert reply["error"]["code"] == "invalid"

    result = _ok(host, "review", _review(2, "dispute", reproduction="failed"), command("r2", **REVIEWER))
    review = host.graph.get_object(result["id"])
    assert review.data["reproduction"] == "failed"
    assert "commit_ref" not in review.data["sys"]["review"]
