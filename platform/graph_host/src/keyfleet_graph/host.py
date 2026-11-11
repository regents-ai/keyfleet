"""One fleet's graph: the run, the pack, the command ledger and the ops.

Every accepted write commits as one SQLite transaction holding its domain
events, the `keyfleet.attention` events its reactions ask for, its
`keyfleet.command` ledger event and the runtime's settling events, so a
command is either wholly durable or absent. The in-memory
projection is outside that transaction, so any exception raised once a
transaction has begun is left to end the process: the supervisor restarts
it and `Runtime.load` rebuilds memory from what is durable.

Refusals are decided before the transaction begins, write nothing and are
not remembered; each is a pure function of the request and the current state.

Each command carries the fleet's projects as the site read them at the
write's turn. A write goes only into an active project, and an object of a
project the command does not list, one the site deleted, is not found.
"""

import hashlib
import json
import secrets
from contextlib import contextmanager
from importlib import metadata
from typing import Annotated, Any, Callable, Iterator, Optional

from activegraph import Event, Graph, Runtime
from activegraph.store.sqlite import SQLiteEventStore
from pydantic import BaseModel, ConfigDict, Field, RootModel, ValidationError
from pydantic_core import from_json

from keyfleet_graph import protocol
from keyfleet_graph.pack import (
    GENERAL,
    MAX_STARTING,
    MEMBER_MODELS,
    PACK,
    PACK_NAME,
    PACK_VERSION,
    RECORD_MODELS,
    RELATION_ENDPOINTS,
    RelationData,
)
from keyfleet_graph.protocol import MAX_EVIDENCE, Command
from keyfleet_graph.reactions import ATTENTION_EVENT, DependsOnLinks, Reactions

LEDGER_EVENT = "keyfleet.command"
# The host's own name on the events only it writes: the ledger and attention.
GATEWAY_ACTOR = "keyfleet:gateway"
# The name on the writes that keep a workspace's starting goals as the site
# lists them.
STARTING_ACTOR = "keyfleet:starting_goals"
# The name on the writes that put a workspace's items made before projects
# into `general`. The release after the one that adds projects removes them.
PROJECTS_ACTOR = "keyfleet:projects"
# The name on the writes that turn each task's one holder into the first Key
# to have joined it. The release after the one that adds task joins removes them.
JOINS_ACTOR = "keyfleet:joins"
# The fields of a task only the Key that created it changes: what the task is.
CREATOR_FIELDS = frozenset({"title", "deliverable", "acceptance_criteria"})
# A `changes` page stops at this many bytes of encoded events, or after the
# first event when that one alone is larger.
CHANGES_PAGE_BYTES = 512 * 1024

# The settling quantum only drains lifecycle bookkeeping: the pack carries no
# behaviors, so any work left after it is a fault. It holds the most one
# command can write: a submission's change and its `MAX_EVIDENCE` links,
# `MAX_ATTENTION` attention events and its ledger event. A test fails if
# either bound grows past what fits.
_QUANTUM_EVENTS = 96
_QUANTUM_SECONDS = 1.0


class Refusal(Exception):
    def __init__(self, code: str, message: str, details: Optional[dict[str, Any]] = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


def upstream_version() -> str:
    dist = metadata.distribution("activegraph")
    commit = json.loads(dist.read_text("direct_url.json"))["vcs_info"]["commit_id"]
    return f"{dist.version}+{commit[:7]}"


def body_hash(body: dict[str, Any]) -> str:
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class StartingGoal(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    title: str
    outcome: str


class StartingGoals(RootModel[Annotated[list[StartingGoal], Field(max_length=MAX_STARTING)]]):
    pass


class Host:
    def __init__(self, fleet: str, db_path: str, starting_goals: list[StartingGoal]):
        # The upstream store's run, fixed per fleet. What names this log to
        # readers is `log_id`, minted with the file.
        self._run = f"kf_{fleet}"
        self.runtime = _open_runtime(db_path, self._run)
        self.graph = self.runtime.graph
        self._conn = self.graph.store._conn
        # WAL with NORMAL may lose the last commits on power loss; a confirmed
        # command must survive it.
        self._conn.execute("PRAGMA synchronous=FULL")
        self._upstream = upstream_version()
        with self._transaction():
            self.log_id = self._log_id()
            self.runtime.load_pack(PACK)
            self._into_general()
            self._into_joined()
            self._keep_starting_goals(starting_goals)
            self._settle()
        self._ledger = {
            (event.payload["principal"], event.payload["command_id"]): event.payload
            for event in self.graph.events
            if event.type == LEDGER_EVENT
        }
        self.depends_on = DependsOnLinks(self.graph)

    # ---------- request handling ----------

    def handle(self, frame: bytes | protocol.TooLarge) -> dict[str, Any]:
        req = None
        try:
            message = _decode(frame)
            req = _request_id(message)
            request = _parse(message)
            if request.op in protocol.READ_OPS:
                body = _parse_body(protocol.READ_OPS[request.op], request.body)
                return {"v": 1, "req": req, "ok": True, "result": self._read(request.op, body)}
            return self._write(request)
        except Refusal as refusal:
            error = {"code": refusal.code, "message": refusal.message, "details": refusal.details}
            return {"v": 1, "req": req, "ok": False, "error": error}

    def _read(self, op: str, body: BaseModel) -> dict[str, Any]:
        if op == "hello":
            return {
                "run_id": self.log_id,
                "pack": f"{PACK_NAME}@{PACK_VERSION}",
                "activegraph": self._upstream,
                "head_seq": self._head_seq(),
            }
        events = self._events_after(body.after_seq, body.limit + 1)
        page = _byte_page(events[: body.limit])
        return {
            "run_id": self.log_id,
            "events": page,
            "next_seq": page[-1]["seq"] if page else body.after_seq,
            "has_more": len(events) > len(page),
            "head_seq": self._head_seq(),
        }

    def _write(self, request: protocol.Request) -> dict[str, Any]:
        command = request.command
        if command is None:
            raise Refusal("bad_request", f"{request.op} needs a command")
        body = _parse_body(protocol.WRITE_OPS[request.op], request.body)
        digest = body_hash(request.body)
        key = (command.principal, command.id)
        prior = self._ledger.get(key)
        if prior is not None:
            if prior["body_hash"] != digest or prior["op"] != request.op:
                raise Refusal(
                    "duplicate_mismatch",
                    "this command id was already used with a different body",
                    {"command_id": command.id},
                )
            return self._accepted(request.req, prior["result"], replayed=True, events=[])

        apply = _PLANNERS[request.op](self, command, body)
        head = self._head_seq()
        reactions = Reactions(self.graph, self.depends_on, self.log_id)
        with self._transaction():
            result = apply(reactions)
            for attention in reactions.attention:
                self._emit(ATTENTION_EVENT, attention)
            payload = {
                "principal": command.principal,
                "command_id": command.id,
                "body_hash": digest,
                "op": request.op,
                "result": result,
                "events": [event["id"] for event in self._events_after(head)],
                "auth": command.auth.model_dump(mode="json"),
            }
            self._emit(LEDGER_EVENT, payload)
            self._settle()
        self._ledger[key] = payload
        return self._accepted(request.req, result, replayed=False, events=self._events_after(head))

    def _accepted(self, req: str, result: Any, *, replayed: bool, events: list) -> dict[str, Any]:
        return {
            "v": 1,
            "req": req,
            "ok": True,
            "run_id": self.log_id,
            "replayed": replayed,
            "result": result,
            "events": events,
            "head_seq": self._head_seq(),
        }

    # ---------- planners: every check, then the closure that writes ----------

    def _plan_create(self, command: Command, body: protocol.CreateBody) -> Callable[[Reactions], dict]:
        _check_active(command, body.project)
        member = MEMBER_MODELS.get(body.type)
        if member is None:
            raise _invalid("type", f"unknown object type {body.type!r}")
        _check_fields(member, body.data.keys(), body.data)
        record = _validate(RECORD_MODELS[body.type], {**body.data, "sys": _sys(command, body.project)})

        def apply(reactions: Reactions) -> dict:
            obj = self.graph.add_object(body.type, record, actor=command.principal)
            return {"id": obj.id, "version": obj.version}

        return apply

    def _plan_patch(self, command: Command, body: protocol.PatchBody) -> Callable[[Reactions], dict]:
        obj = self._editable(command, body.id)
        _check_active(command, _project(obj))
        _check_version(obj, body.expected_version)
        _check_not_starting(obj)
        fields = set(body.set) | set(body.unset)
        _check_fields(MEMBER_MODELS[obj.type], fields, body.set)
        _check_owner(obj, command, fields)
        merged = {**obj.data, **body.set}
        for field in body.unset:
            merged.pop(field, None)
        record = _validate(RECORD_MODELS[obj.type], merged)
        # A member's patch changes sys only to note a Key that worked on a
        # task; a record from an older pack may validate with sys fields it
        # never stored.
        updates = {
            field: value for field, value in record.items() if field != "sys" and obj.data.get(field) != value
        }
        if not updates:
            raise _invalid("set", "the patch changes nothing")
        worked = _worked(obj, command) if obj.type == "task" else None
        if worked is not None:
            sys = {**obj.data["sys"], "worked": worked}
            updates["sys"] = _validate(RECORD_MODELS["task"], {**record, "sys": sys})["sys"]

        def apply(reactions: Reactions) -> dict:
            self.graph.patch_object(
                obj.id, updates, actor=command.principal, rationale=body.reason, evidence=body.evidence
            )
            return {"id": obj.id, "version": self.graph.get_object(obj.id).version}

        return apply

    def _plan_archive(self, command: Command, body: protocol.ArchiveBody) -> Callable[[Reactions], dict]:
        obj = self._editable(command, body.id)
        _check_active(command, _project(obj))
        _check_version(obj, body.expected_version)
        _check_not_starting(obj)
        _check_archiver(obj, command)
        # Archiving a task lets go every Key that joined it, as each leaving would.
        archived = {**obj.data["sys"], "archived": True, **({"joined": []} if obj.type == "task" else {})}

        def apply(reactions: Reactions) -> dict:
            self.graph.patch_object(obj.id, {"sys": archived}, actor=command.principal, rationale=body.reason)
            current = self.graph.get_object(obj.id)
            reactions.archived(current, self._last_event_id())
            return {"id": obj.id, "version": current.version}

        return apply

    def _plan_link(self, command: Command, body: protocol.LinkBody) -> Callable[[Reactions], dict]:
        source = self._live(command, body.source, "source")
        target = self._live(command, body.target, "target")
        _check_active(command, _project(source))
        endpoints = RELATION_ENDPOINTS.get(body.type)
        if endpoints is None:
            raise _invalid("type", f"unknown relation type {body.type!r}")
        sources, targets = endpoints
        if source.type not in sources or target.type not in targets:
            raise _invalid("type", f"{body.type} cannot link a {source.type} to a {target.type}")
        if body.type == "depends_on" and source.id == target.id:
            raise _invalid("target", "an object cannot depend on itself")
        _check_owner(source, command)
        data = _validate(RelationData, {"note": body.note}, exclude_none=True)

        def apply(reactions: Reactions) -> dict:
            existing = self.graph.relations(source=source.id, target=target.id, type=body.type)
            if existing:
                return {"relation_id": existing[0].id, "existing": True}
            rel = self.graph.add_relation(source.id, target.id, body.type, data, actor=command.principal)
            self.depends_on.made(rel)
            reactions.linked(rel, source, self._last_event_id())
            return {"relation_id": rel.id, "existing": False}

        return apply

    def _plan_unlink(self, command: Command, body: protocol.UnlinkBody) -> Callable[[Reactions], dict]:
        rel = self.graph.get_relation(body.relation_id)
        if rel is None:
            raise Refusal("not_found", "no such relation", {"id": body.relation_id})
        if rel.type == "reviews":
            raise _invalid("relation_id", "a review stays linked to the task it judged")
        if rel.type == "forks":
            raise _invalid("relation_id", "a fork stays linked to the task it was copied from")
        source = self._object(command, rel.source, "relation_id")
        _check_active(command, _project(source))
        _check_owner(source, command)
        target = self.graph.get_object(rel.target)

        def apply(reactions: Reactions) -> dict:
            self.graph.remove_relation(rel.id, actor=command.principal)
            self.depends_on.removed(rel)
            reactions.unlinked(rel, target, self._last_event_id())
            return {"relation_id": rel.id}

        return apply

    def _plan_join(self, command: Command, body: protocol.JoinBody) -> Callable[[Reactions], dict]:
        """Adds the acting Key and wallet to a goal or task, however many have joined it."""
        obj = self._joinable(command, body.id)
        member = _member(command)
        recorded = obj.data["sys"]["joined"]
        joined = _unlapsed(recorded, member)
        if any(_same_member(entry, member) for entry in joined):
            if joined == recorded:
                return lambda _reactions: {"id": obj.id, "version": obj.version}
            return self._rejoined(command, obj, joined)
        return self._rejoined(command, obj, [*joined, member])

    def _plan_leave(self, command: Command, body: protocol.LeaveBody) -> Callable[[Reactions], dict]:
        obj = self._joinable(command, body.id)
        member = _member(command)
        recorded = obj.data["sys"]["joined"]
        joined = [entry for entry in _unlapsed(recorded, member) if not _same_member(entry, member)]
        if joined == recorded:
            return lambda _reactions: {"id": obj.id, "version": obj.version}
        return self._rejoined(command, obj, joined)

    def _rejoined(self, command: Command, obj, joined: list) -> Callable[[Reactions], dict]:
        record = {**obj.data, "sys": {**obj.data["sys"], "joined": joined}}
        sys = _validate(RECORD_MODELS[obj.type], record)["sys"]

        def apply(_reactions: Reactions) -> dict:
            self.graph.patch_object(obj.id, {"sys": sys}, actor=command.principal)
            return {"id": obj.id, "version": self.graph.get_object(obj.id).version}

        return apply

    def _plan_submit(self, command: Command, body: protocol.SubmitBody) -> Callable[[Reactions], dict]:
        """Marks a task done for review, with its result and the evidence it rests on, in one write.

        The Key that created the task or one that joined it submits it. Each evidence item is linked as something the task `produces`. A
        submission is only a claim: whether the work is accepted is for its
        reviews to say.
        """
        task = self._task(command, body.id, "id")
        _check_active(command, _project(task))
        _check_version(task, body.expected_version)
        _check_owner(task, command)
        evidence = list(dict.fromkeys(body.evidence))
        if body.result_ref is None and not evidence:
            raise _invalid("evidence", "a submission names its result, its evidence or both")
        produced = []
        for index, item_id in enumerate(evidence):
            item = self._live(command, item_id, f"evidence.{index}")
            if item.type not in RELATION_ENDPOINTS["produces"][1]:
                raise _invalid(f"evidence.{index}", f"a task cannot produce a {item.type}")
            produced.append(item)
        submitted = {**_member(command), "version": task.version + 1, "evidence": evidence}
        merged = {
            **task.data,
            "progress": "done",
            "result_ref": body.result_ref,
            "sys": {**task.data["sys"], "submitted": submitted, "worked": _worked(task, command) or _worked_keys(task)},
        }
        record = _validate(RECORD_MODELS["task"], merged)
        updates = {field: value for field, value in record.items() if task.data.get(field) != value}
        was_done = task.data["progress"] == "done"

        def apply(reactions: Reactions) -> dict:
            self.graph.patch_object(
                task.id, updates, actor=command.principal, rationale=body.reason, evidence=evidence
            )
            current = self.graph.get_object(task.id)
            reactions.submitted(current, was_done, self._last_event_id())
            for item in produced:
                if not self.graph.relations(source=task.id, target=item.id, type="produces"):
                    self.graph.add_relation(task.id, item.id, "produces", {}, actor=command.principal)
            return {"id": task.id, "version": current.version}

        return apply

    def _plan_review(self, command: Command, body: protocol.ReviewBody) -> Callable[[Reactions], dict]:
        """Records one member's decision on the task version they read.

        A review binds itself to that version, to who submitted it, to each
        piece of its evidence as it then stood and to the commit the task then
        named; it may say whether the reviewer reproduced the work from it. The Key or wallet that submitted
        the task cannot review it, nor can a Key that joined, changed or submitted it, even after leaving it; a Key reviews each
        version once. Whether
        two different Keys belong to different people is not something the
        graph knows, so a review never claims it.
        """
        task = self._task(command, body.task, "task")
        _check_active(command, _project(task))
        submitted = task.data["sys"].get("submitted")
        if task.data["progress"] != "done" or submitted is None:
            raise _invalid("task", "the task has not been submitted for review")
        _check_version(task, body.task_version)
        reviewer = _member(command)
        submitted_by = {field: submitted[field] for field in ("key", "ownership_epoch", "kind", "wallet")}
        if reviewer["key"] == submitted_by["key"] or reviewer["wallet"] == submitted_by["wallet"]:
            raise Refusal(
                "self_review",
                "the Key or wallet that submitted a task cannot review it",
                {"submitted_by": submitted_by},
            )
        if _has_joined(task, command) or any(entry["key"] == reviewer["key"] for entry in _worked_keys(task)):
            raise Refusal(
                "self_review",
                "a Key that joined, changed or submitted a task worked on it, so it cannot review it",
                {"submitted_by": submitted_by},
            )
        for rel in self.graph.relations(target=task.id, type="reviews"):
            prior = self.graph.get_object(rel.source).data["sys"]
            if prior["review"]["task_version"] == task.version and prior["created_by"]["key"] == reviewer["key"]:
                raise _invalid("task_version", "this Key has already reviewed this version of the task")
        receipt = {
            "task": task.id,
            "task_version": task.version,
            "submitted_by": submitted_by,
            "evidence": [
                {"id": item_id, "version": self._object(command, item_id, "evidence").version}
                for item_id in submitted["evidence"]
            ],
            "commit_ref": task.data.get("commit_ref"),
        }
        member = {
            "decision": body.decision,
            "rationale": body.rationale,
            "conflicts_of_interest": body.conflicts_of_interest,
            "reproduction": body.reproduction,
        }
        # A review belongs to the project of the task it judged.
        sys = {**_sys(command, _project(task)), "review": receipt}
        record = _validate(RECORD_MODELS["review"], {**member, "sys": sys})

        def apply(reactions: Reactions) -> dict:
            review = self.graph.add_object("review", record, actor=command.principal)
            self.graph.add_relation(review.id, task.id, "reviews", {}, actor=command.principal)
            return {"id": review.id, "version": review.version}

        return apply

    def _plan_fork(self, command: Command, body: protocol.ForkBody) -> Callable[[Reactions], dict]:
        """Copies a task as the acting Key's own, in progress.

        The fork stays in the task's project and keeps its title, deliverable, acceptance criteria and discussion, implements
        the same goals and services, and links to the task with `forks`. The
        task forked is left as it was, and so is who joined it: forking makes
        a member's own copy, where joining works on the task itself.
        """
        task = self._task(command, body.id, "id")
        _check_active(command, _project(task))
        copied = {field: task.data[field] for field in ("title", "deliverable", "acceptance_criteria", "discussion") if task.data.get(field)}
        member = {**copied, "progress": "doing"}
        record = _validate(RECORD_MODELS["task"], {**member, "sys": _sys(command, _project(task))})
        implements = [
            target.id
            for rel in self.graph.relations(source=task.id, type="implements")
            if _project(target := self.graph.get_object(rel.target)) in command.projects
            and not target.data["sys"]["archived"]
        ]

        def apply(reactions: Reactions) -> dict:
            fork = self.graph.add_object("task", record, actor=command.principal)
            self.graph.add_relation(fork.id, task.id, "forks", {}, actor=command.principal)
            for target in implements:
                self.graph.add_relation(fork.id, target, "implements", {}, actor=command.principal)
            return {"id": fork.id, "version": fork.version}

        return apply

    # ---------- projects ----------

    def _into_general(self) -> None:
        """Puts every item made before projects into `general`, once.

        Each such item is rewritten whole by one replace: its `sys` names
        `general` in place of its scope, and a goal or task loses the public
        summary the pack no longer has. The release after the one that adds
        projects removes this step.
        """
        for obj in self.graph.objects():
            if "project" in obj.data["sys"]:
                continue
            sys = {field: value for field, value in obj.data["sys"].items() if field != "scope"}
            data = {field: value for field, value in obj.data.items() if field != "public_summary"}
            record = _validate(RECORD_MODELS[obj.type], {**data, "sys": {**sys, "project": GENERAL}})
            patch = self.graph.propose_patch(obj.id, "replace", record, proposed_by=PROJECTS_ACTOR)
            self.graph.apply_patch(patch.id, approved_by=PROJECTS_ACTOR)

    def _into_joined(self) -> None:
        """Makes each task's one holder the first Key to have joined it, once.

        A task made before task joins names its holder by Key number alone.
        Each such task is rewritten whole by one replace: the number goes, and
        `sys.joined` lists the holder as the Key and wallet of the last command
        that Key wrote in this fleet, or no one when it never wrote one. All of
        it commits in the startup transaction, or none of it. The release after the one that adds task joins removes this step.
        """
        authors = {
            event.payload["auth"]["key"]["token_id"]: event.payload["auth"]
            for event in self.graph.events
            if event.type == LEDGER_EVENT
        }
        for obj in self.graph.query("task"):
            if "assignee_key" not in obj.data:
                continue
            data = {field: value for field, value in obj.data.items() if field != "assignee_key"}
            auth = authors.get(obj.data["assignee_key"])
            joined = [] if auth is None else [_auth_member(auth)]
            record = _validate(RECORD_MODELS["task"], {**data, "sys": {**data["sys"], "joined": joined}})
            patch = self.graph.propose_patch(obj.id, "replace", record, proposed_by=JOINS_ACTOR)
            self.graph.apply_patch(patch.id, approved_by=JOINS_ACTOR)
            # Each rewrite settles before the next, so any number of tasks
            # fits the settling quantum.
            self._settle()

    # ---------- starting goals ----------

    def _keep_starting_goals(self, goals: list[StartingGoal]) -> None:
        """Makes the workspace's starting goals the ones listed, by their number.

        A missing one is added and one whose words changed is rewritten; the
        last is added first, so the first is the newest. One past the end of
        the list is archived. Who joined each is left as it is.
        """
        held = {
            obj.data["sys"]["starting"]: obj
            for obj in self.graph.query("goal")
            if obj.data["sys"].get("starting") is not None
        }
        for number, goal in reversed(list(enumerate(goals, start=1))):
            obj = held.get(number)
            if obj is None:
                sys = {"project": GENERAL, "created_by": None, "starting": number, "archived": False}
                record = _validate(RECORD_MODELS["goal"], {**goal.model_dump(), "sys": sys})
                self.graph.add_object("goal", record, actor=STARTING_ACTOR)
                continue
            updates = {field: value for field, value in goal.model_dump().items() if obj.data[field] != value}
            if obj.data["sys"]["archived"]:
                updates["sys"] = {**obj.data["sys"], "archived": False}
            if updates:
                _validate(RECORD_MODELS["goal"], {**obj.data, **updates})
                self.graph.patch_object(obj.id, updates, actor=STARTING_ACTOR)
        for number, obj in held.items():
            if number > len(goals) and not obj.data["sys"]["archived"]:
                sys = {**obj.data["sys"], "archived": True}
                self.graph.patch_object(obj.id, {"sys": sys}, actor=STARTING_ACTOR)

    # ---------- state helpers ----------

    def _joinable(self, command: Command, object_id: str):
        obj = self._live(command, object_id, "id")
        if obj.type not in ("goal", "task"):
            raise _invalid("id", f"only a goal or a task can be joined, not a {obj.type}")
        _check_active(command, _project(obj))
        return obj

    # An object of a project the command does not list belongs to a deleted
    # project, and is not found.
    def _object(self, command: Command, object_id: str, path: str):
        obj = self.graph.get_object(object_id)
        if obj is None or _project(obj) not in command.projects:
            raise Refusal("not_found", f"no such object ({path})", {"id": object_id})
        return obj

    def _live(self, command: Command, object_id: str, path: str):
        obj = self._object(command, object_id, path)
        if obj.data["sys"]["archived"]:
            raise _invalid(path, "the object is archived")
        return obj

    def _task(self, command: Command, object_id: str, path: str):
        obj = self._live(command, object_id, path)
        if obj.type != "task":
            raise _invalid(path, "the object is not a task")
        return obj

    # Reviews are written once and stay as written.
    def _editable(self, command: Command, object_id: str):
        obj = self._live(command, object_id, "id")
        if obj.type == "review":
            raise _invalid("id", "a review cannot be changed")
        return obj

    def _log_id(self) -> str:
        """The id minted when this file first held the log; a new file is a new log.

        Readers compare it with the one they last saw: places in two different
        logs are not comparable, so a changed id means reading again from 0.
        """
        self._conn.execute("CREATE TABLE IF NOT EXISTS keyfleet_log (id TEXT NOT NULL)")
        row = self._conn.execute("SELECT id FROM keyfleet_log").fetchone()
        if row is not None:
            return row[0]
        log_id = f"log_{secrets.token_hex(16)}"
        self._conn.execute("INSERT INTO keyfleet_log (id) VALUES (?)", (log_id,))
        return log_id

    def _last_event_id(self) -> str:
        """The id of the event just written, as this connection sees it inside its transaction."""
        row = self._conn.execute(
            "SELECT id FROM events WHERE run_id = ? ORDER BY seq DESC LIMIT 1", (self._run,)
        ).fetchone()
        return row[0]

    def _emit(self, event_type: str, payload: dict[str, Any]) -> None:
        self.graph.emit(
            Event(
                id=self.graph.ids.event(),
                type=event_type,
                payload=payload,
                actor=GATEWAY_ACTOR,
                timestamp=self.graph.clock.now(),
            )
        )

    def _head_seq(self) -> int:
        row = self._conn.execute(
            "SELECT COALESCE(MAX(seq), 0) FROM events WHERE run_id = ?", (self._run,)
        ).fetchone()
        return int(row[0])

    def _events_after(self, seq: int, limit: int = -1) -> list[dict[str, Any]]:
        rows = self._conn.execute(
            "SELECT seq, id, type, actor, timestamp, payload FROM events"
            " WHERE run_id = ? AND seq > ? ORDER BY seq LIMIT ?",
            (self._run, seq, limit),
        )
        return [
            {
                "seq": row["seq"],
                "id": row["id"],
                "type": row["type"],
                "actor": row["actor"],
                "timestamp": row["timestamp"],
                "payload": json.loads(row["payload"]),
            }
            for row in rows
        ]

    @contextmanager
    def _transaction(self) -> Iterator[None]:
        # Relies on the pinned store's autocommit connection (isolation_level
        # None): an explicit BEGIN then holds every append until COMMIT. The
        # private-seam test fails if a new upstream changes either detail.
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self._conn.execute("ROLLBACK")
            raise
        self._conn.execute("COMMIT")

    def _settle(self) -> None:
        quantum = self.runtime.run_quantum(max_queue_events=_QUANTUM_EVENTS, max_seconds=_QUANTUM_SECONDS)
        if not quantum.idle:
            raise RuntimeError("the runtime did not settle inside one quantum")


_PLANNERS = {
    "create": Host._plan_create,
    "patch": Host._plan_patch,
    "archive": Host._plan_archive,
    "link": Host._plan_link,
    "unlink": Host._plan_unlink,
    "join": Host._plan_join,
    "leave": Host._plan_leave,
    "submit": Host._plan_submit,
    "review": Host._plan_review,
    "fork": Host._plan_fork,
}


def _open_runtime(db_path: str, run_id: str) -> Runtime:
    probe = SQLiteEventStore(db_path, run_id)
    fresh = probe.get_run() is None
    probe.close()
    if fresh:
        return Runtime(Graph(run_id=run_id), persist_to=db_path, behaviors=[], tools=[])
    return Runtime.load(db_path, run_id, behaviors=[], tools=[])


def _decode(frame: bytes | protocol.TooLarge) -> Any:
    """Parse the frame once, with the JSON parser's nesting limit and no NaN or infinity literals."""
    if isinstance(frame, protocol.TooLarge):
        raise Refusal("bad_request", "the request is larger than 1 MiB")
    try:
        return from_json(frame, allow_inf_nan=False)
    except ValueError as error:
        raise Refusal("bad_request", "the request is not JSON", {"errors": [{"path": "", "message": str(error)}]}) from None


def _request_id(message: Any) -> Optional[str]:
    """The id to answer under, even when the rest of the envelope is refused."""
    req = message.get("req") if isinstance(message, dict) else None
    if isinstance(req, str) and 0 < len(req) <= 128:
        return req
    return None


def _parse(message: Any) -> protocol.Request:
    try:
        request = protocol.Request.model_validate(message)
    except ValidationError as error:
        raise Refusal("bad_request", "malformed envelope", {"errors": _errors(error)}) from None
    if request.op in protocol.READ_OPS:
        if request.command is not None:
            raise Refusal("bad_request", f"{request.op} takes no command")
    elif request.op not in protocol.WRITE_OPS:
        raise Refusal("bad_request", f"unknown op {request.op!r}")
    return request


def _parse_body(model: type[BaseModel], body: dict[str, Any]) -> BaseModel:
    try:
        return model.model_validate(body)
    except ValidationError as error:
        raise Refusal("bad_request", "malformed body", {"errors": _errors(error)}) from None


def _validate(model: type[BaseModel], data: dict[str, Any], *, exclude_none: bool = False) -> dict:
    try:
        return model.model_validate(data).model_dump(mode="json", exclude_none=exclude_none)
    except ValidationError as error:
        raise Refusal("invalid", "the data does not fit the schema", {"errors": _errors(error)}) from None


def _errors(error: ValidationError) -> list[dict[str, str]]:
    return [
        {"path": ".".join(str(part) for part in item["loc"]), "message": item["msg"]}
        for item in error.errors()
    ]


def _invalid(path: str, message: str) -> Refusal:
    return Refusal("invalid", message, {"errors": [{"path": path, "message": message}]})


def _check_version(obj, expected_version: int) -> None:
    if obj.version != expected_version:
        raise Refusal(
            "conflict",
            "the object changed since that version",
            {"current_version": obj.version, "object": _object_view(obj)},
        )


def _check_not_starting(obj) -> None:
    if obj.data["sys"].get("starting") is not None:
        raise _invalid("id", "a starting goal stays as it is: join it, or link work to it")



def _check_fields(member: type[BaseModel], fields, values: dict[str, Any]) -> None:
    unknown = sorted(field for field in fields if field not in member.model_fields)
    if unknown:
        raise Refusal(
            "forbidden_field",
            "this kind of item has no such fields",
            {"fields": unknown, "allowed": sorted(member.model_fields)},
        )
    if "result_ref" in fields or values.get("progress") == "done":
        raise Refusal(
            "forbidden_field",
            "a task is marked done, with its result, only by submitting it",
            {"fields": sorted({"result_ref", "progress"} & set(fields))},
        )


def _creator(obj) -> Optional[int]:
    created_by = obj.data["sys"]["created_by"]
    return None if created_by is None else created_by["key"]["token_id"]


# The Keys that joined an object, each once, in the order they first joined.
def _joined_keys(obj) -> list[int]:
    return list(dict.fromkeys(entry["key"]["token_id"] for entry in obj.data["sys"].get("joined", [])))


# Whether the acting Key, at its current ownership, joined the object.
def _has_joined(obj, command: Command) -> bool:
    member = _member(command)
    return any(
        entry["key"] == member["key"] and entry["ownership_epoch"] == member["ownership_epoch"]
        for entry in obj.data["sys"].get("joined", [])
    )


# The Keys other than a task's creator that changed or submitted it.
def _worked_keys(obj) -> list[dict[str, Any]]:
    return obj.data["sys"].get("worked", [])


# The task's workers with the acting Key added, or None when it is the
# creator or already one of them.
def _worked(obj, command: Command) -> Optional[list[dict[str, Any]]]:
    worked = _worked_keys(obj)
    member = _member(command)
    if _creator(obj) == member["key"]["token_id"] or any(entry["key"] == member["key"] for entry in worked):
        return None
    return [*worked, member]


# An item belongs to the Key that created it, and a task also to every Key
# that joined it. Only they change it or link from it, and only the creator
# changes what a task is (`CREATOR_FIELDS`); anyone else joins the task first,
# forks it, or links their own item to it.
def _check_owner(obj, command: Command, fields=frozenset()) -> None:
    key = command.auth.key.token_id
    creator = _creator(obj)
    if creator == key:
        return
    if obj.type != "task":
        raise Refusal(
            "not_owner",
            "only the Key that created this changes it or links from it: fork it, or link your own item to it",
            {"id": obj.id, "owner_key": creator},
        )
    if not _has_joined(obj, command):
        raise Refusal(
            "not_owner",
            "only the Key that created this task, or one that joined it, changes it or links from it: join it first",
            {"id": obj.id, "owner_key": creator, "joined_keys": _joined_keys(obj)},
        )
    named = sorted(CREATOR_FIELDS & set(fields))
    if named:
        raise Refusal(
            "not_owner",
            "only the Key that created this task changes its title, deliverable or acceptance criteria",
            {"id": obj.id, "owner_key": creator, "fields": named},
        )


# Archiving takes an item away from everyone, so only the Key that created it
# archives it, at any time.
def _check_archiver(obj, command: Command) -> None:
    key = command.auth.key.token_id
    creator = _creator(obj)
    if creator != key:
        raise Refusal(
            "not_owner",
            "only the Key that created this archives it",
            {"id": obj.id, "owner_key": creator},
        )


def _project(obj) -> str:
    return obj.data["sys"]["project"]


def _check_active(command: Command, project: str) -> None:
    """New work goes only into an active project; a refusal names the active ones."""
    state = command.projects.get(project)
    if state == "active":
        return
    active = sorted(name for name, held in command.projects.items() if held == "active")
    if active:
        where = f"New work goes into an active project: {', '.join(active)}."
    else:
        where = "No project is active; a Key starts one or takes one over."
    details = {"project": project, "active": active}
    if state is None:
        raise Refusal("project_unknown", f"This fleet has no project named {project}. {where}", details)
    raise Refusal("project_archived", f"{project} is archived. {where}", details)


def _sys(command: Command, project: str) -> dict[str, Any]:
    return {"project": project, "created_by": _member(command), "archived": False}


def _member(command: Command) -> dict[str, Any]:
    return _auth_member(command.auth.model_dump(mode="json"))


# A member as the audited auth of one command names it.
def _auth_member(auth: dict[str, Any]) -> dict[str, Any]:
    return {
        "key": auth["key"],
        "ownership_epoch": auth["ownership_epoch"],
        "kind": auth["kind"],
        "wallet": auth["operator_wallet"],
    }


# One Key and wallet join a goal once.
def _same_member(entry: dict[str, Any], member: dict[str, Any]) -> bool:
    return entry["key"] == member["key"] and entry["wallet"] == member["wallet"]


# A Key's joins from an earlier ownership lapse when its owner now joins or
# leaves: the agents who joined then no longer act as the Key.
def _unlapsed(joined: list[dict[str, Any]], member: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        entry
        for entry in joined
        if entry["key"] != member["key"] or entry["ownership_epoch"] == member["ownership_epoch"]
    ]


def _byte_page(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    page, size = [], 0
    for event in events:
        size += len(json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        if page and size > CHANGES_PAGE_BYTES:
            break
        page.append(event)
    return page


def _object_view(obj) -> dict[str, Any]:
    data = {field: value for field, value in obj.data.items() if field != "sys"}
    return {"id": obj.id, "type": obj.type, "data": data, "sys": obj.data["sys"], "version": obj.version}
