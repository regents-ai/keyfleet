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
"""

import hashlib
import json
import secrets
from contextlib import contextmanager
from importlib import metadata
from typing import Any, Callable, Iterator, Optional

from activegraph import Event, Graph, Runtime
from activegraph.store.sqlite import SQLiteEventStore
from pydantic import BaseModel, ValidationError
from pydantic_core import from_json

from keyfleet_graph import protocol
from keyfleet_graph.pack import (
    MAX_JOINED,
    MEMBER_MODELS,
    PACK,
    PACK_NAME,
    PACK_VERSION,
    RECORD_MODELS,
    RELATION_ENDPOINTS,
    RelationData,
)
from keyfleet_graph.protocol import Command
from keyfleet_graph.reactions import ATTENTION_EVENT, DependsOnLinks, Reactions

LEDGER_EVENT = "keyfleet.command"
# The host's own name on the events only it writes: the ledger and attention.
GATEWAY_ACTOR = "keyfleet:gateway"
# A `changes` page stops at this many bytes of encoded events, or after the
# first event when that one alone is larger.
CHANGES_PAGE_BYTES = 512 * 1024

# The settling quantum only drains lifecycle bookkeeping: the pack carries no
# behaviors, so any work left after it is a fault. It holds the most one
# command can write: its change, `MAX_ATTENTION` attention events and its
# ledger event. A test fails if `MAX_ATTENTION` grows past what fits.
_QUANTUM_EVENTS = 64
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


class Host:
    def __init__(self, fleet: str, db_path: str):
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
        member = MEMBER_MODELS.get(body.type)
        if member is None:
            raise _invalid("type", f"unknown object type {body.type!r}")
        if body.scope not in command.writable_scopes:
            raise Refusal("forbidden_scope", "the command may not write this scope", {"scope": body.scope})
        _check_fields(member, body.data.keys(), body.data, command)
        record = _validate(RECORD_MODELS[body.type], {**body.data, "sys": _sys(command, body.scope)})

        def apply(reactions: Reactions) -> dict:
            obj = self.graph.add_object(body.type, record, actor=command.principal)
            reactions.created(obj, self._last_event_id())
            return {"id": obj.id, "version": obj.version}

        return apply

    def _plan_patch(self, command: Command, body: protocol.PatchBody) -> Callable[[Reactions], dict]:
        obj = self._live(body.id, "id")
        _check_version(obj, body.expected_version)
        _check_scope(command, obj)
        _check_fields(MEMBER_MODELS[obj.type], set(body.set) | set(body.unset), body.set, command)
        merged = {**obj.data, **body.set}
        for field in body.unset:
            merged.pop(field, None)
        record = _validate(RECORD_MODELS[obj.type], merged)
        # A member's patch never changes sys; a record from an older pack may
        # validate with sys fields it never stored.
        updates = {
            field: value for field, value in record.items() if field != "sys" and obj.data.get(field) != value
        }
        if not updates:
            raise _invalid("set", "the patch changes nothing")

        def apply(reactions: Reactions) -> dict:
            self.graph.patch_object(
                obj.id, updates, actor=command.principal, rationale=body.reason, evidence=body.evidence
            )
            current = self.graph.get_object(obj.id)
            reactions.patched(current, updates, self._last_event_id())
            return {"id": obj.id, "version": current.version}

        return apply

    def _plan_archive(self, command: Command, body: protocol.ArchiveBody) -> Callable[[Reactions], dict]:
        obj = self._live(body.id, "id")
        _check_version(obj, body.expected_version)
        _check_scope(command, obj)
        archived = {**obj.data["sys"], "archived": True}

        def apply(reactions: Reactions) -> dict:
            self.graph.patch_object(obj.id, {"sys": archived}, actor=command.principal, rationale=body.reason)
            current = self.graph.get_object(obj.id)
            reactions.archived(current, self._last_event_id())
            return {"id": obj.id, "version": current.version}

        return apply

    def _plan_link(self, command: Command, body: protocol.LinkBody) -> Callable[[Reactions], dict]:
        source = self._live(body.source, "source")
        target = self._live(body.target, "target")
        _check_scope(command, source, target)
        endpoints = RELATION_ENDPOINTS.get(body.type)
        if endpoints is None:
            raise _invalid("type", f"unknown relation type {body.type!r}")
        sources, targets = endpoints
        if source.type not in sources or target.type not in targets:
            raise _invalid("type", f"{body.type} cannot link a {source.type} to a {target.type}")
        if body.type == "depends_on" and source.id == target.id:
            raise _invalid("target", "an object cannot depend on itself")
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
        target = self.graph.get_object(rel.target)
        _check_scope(command, self.graph.get_object(rel.source), target)

        def apply(reactions: Reactions) -> dict:
            self.graph.remove_relation(rel.id, actor=command.principal)
            self.depends_on.removed(rel)
            reactions.unlinked(rel, target, self._last_event_id())
            return {"relation_id": rel.id}

        return apply

    def _plan_join(self, command: Command, body: protocol.JoinBody) -> Callable[[Reactions], dict]:
        goal = self._goal(body.id)
        _check_scope(command, goal)
        member = _member(command)
        recorded = goal.data["sys"].get("joined", [])
        joined = _unlapsed(recorded, member)
        if any(_same_member(entry, member) for entry in joined):
            if joined == recorded:
                return lambda _reactions: {"id": goal.id, "version": goal.version}
            return self._rejoined(command, goal, joined)
        if len(joined) >= MAX_JOINED:
            raise _invalid("id", f"the goal has the most members it can record, {MAX_JOINED}")
        return self._rejoined(command, goal, [*joined, member])

    def _plan_leave(self, command: Command, body: protocol.LeaveBody) -> Callable[[Reactions], dict]:
        goal = self._goal(body.id)
        _check_scope(command, goal)
        member = _member(command)
        recorded = goal.data["sys"].get("joined", [])
        joined = [entry for entry in _unlapsed(recorded, member) if not _same_member(entry, member)]
        if joined == recorded:
            return lambda _reactions: {"id": goal.id, "version": goal.version}
        return self._rejoined(command, goal, joined)

    def _rejoined(self, command: Command, goal, joined: list) -> Callable[[Reactions], dict]:
        record = {**goal.data, "sys": {**goal.data["sys"], "joined": joined}}
        sys = _validate(RECORD_MODELS["goal"], record)["sys"]

        def apply(_reactions: Reactions) -> dict:
            self.graph.patch_object(goal.id, {"sys": sys}, actor=command.principal)
            return {"id": goal.id, "version": self.graph.get_object(goal.id).version}

        return apply

    # ---------- state helpers ----------

    def _goal(self, object_id: str):
        goal = self._live(object_id, "id")
        if goal.type != "goal":
            raise _invalid("id", f"only a goal can be joined, not a {goal.type}")
        return goal

    def _object(self, object_id: str, path: str):
        obj = self.graph.get_object(object_id)
        if obj is None:
            raise Refusal("not_found", f"no such object ({path})", {"id": object_id})
        return obj

    def _live(self, object_id: str, path: str):
        obj = self._object(object_id, path)
        if obj.data["sys"]["archived"]:
            raise _invalid(path, "the object is archived")
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


def _check_scope(command: Command, *objects) -> None:
    for obj in objects:
        scope = obj.data["sys"]["scope"]
        if scope not in command.writable_scopes:
            raise Refusal("forbidden_scope", "the command may not write this scope", {"scope": scope})


def _check_fields(member: type[BaseModel], fields, values: dict[str, Any], command: Command) -> None:
    unknown = sorted(field for field in fields if field not in member.model_fields)
    if unknown:
        raise Refusal("forbidden_field", "these fields are not member-writable", {"fields": unknown})
    if values.get("assignee_key") not in (None, command.auth.key.token_id):
        raise Refusal(
            "forbidden_field",
            "a task may be assigned only to the acting Key, or cleared",
            {"fields": ["assignee_key"]},
        )


def _sys(command: Command, scope: str) -> dict[str, Any]:
    return {"scope": scope, "created_by": _member(command), "archived": False}


def _member(command: Command) -> dict[str, Any]:
    auth = command.auth
    return {
        "key": auth.key.model_dump(mode="json"),
        "ownership_epoch": auth.ownership_epoch,
        "kind": auth.kind,
        "wallet": auth.operator_wallet,
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
