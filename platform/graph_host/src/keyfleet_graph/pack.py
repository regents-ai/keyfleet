"""The pinned `keyfleet_work@0.10.0` work pack.

Two models per object type: the member model is what a member may write, and
the record model adds the server-owned `sys` block and is what the graph
stores. Every model forbids unknown keys, so nothing a member writes can land
outside the declared fields.

A task is marked done only by submitting it, which records who submitted it
and the evidence it rests on in `sys.submitted`. A review is written only by
the review op: its member fields are the reviewer's decision and reasons, and
`sys.review` binds it to the task version and the submission it judged.
"""

from typing import Annotated, Literal, Optional

from activegraph.packs import ObjectType, Pack, RelationType
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, create_model, model_validator

from keyfleet_graph.protocol import MAX_INT, Address, Count, Epoch, ProjectName, multi_line, single_line

PACK_NAME = "keyfleet_work"
PACK_VERSION = "0.10.0"

URI_SCHEMES = ("https://", "ipfs://", "ar://", "git+https://")


class _Model(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)


def _text(max_chars: int, *, required: bool = False, multiline: bool = False) -> type:
    length = StringConstraints(min_length=1 if required else 0, max_length=max_chars)
    return Annotated[str, length, multi_line if multiline else single_line]


def _max_bytes(limit: int):
    def check(value: str) -> str:
        if len(value.encode("utf-8")) > limit:
            raise ValueError(f"must be at most {limit} bytes")
        return value

    return AfterValidator(check)


def _uri(value: str) -> str:
    if not value.startswith(URI_SCHEMES) or any(ch.isspace() for ch in value):
        raise ValueError("must be an https, ipfs, ar or git+https URI")
    return value


Uri = Annotated[str, StringConstraints(min_length=1), single_line, AfterValidator(_uri), _max_bytes(512)]
DecimalString = Annotated[str, StringConstraints(pattern=r"^(0|[1-9][0-9]{0,77})(\.[0-9]{1,18})?$")]
Digest = Annotated[str, StringConstraints(pattern=r"^sha256:[0-9a-f]{64}$")]
Title = _text(200, required=True)
# The project every workspace starts with; the starting goals are its own.
GENERAL = "general"


def _items():
    return Field(default_factory=list, max_length=20)


class DiscussionLink(_Model):
    # Any room's address: a fleet's own rooms and the rooms its agents created
    # share one shape. Whether the fleet has the room is the reader's question.
    room: Annotated[str, StringConstraints(pattern=r"^[a-z0-9]+(-[a-z0-9]+)*$", max_length=63)]
    seq: Annotated[int, Field(ge=1, le=MAX_INT)]


class WorkObject(_Model):
    title: Title
    discussion: list[DiscussionLink] = _items()


class Goal(WorkObject):
    outcome: _text(2000, required=True, multiline=True)
    success_criteria: list[_text(500)] = _items()
    # A question is never empty, so a goal's first one is always one to ask.
    open_questions: list[_text(500, required=True)] = _items()
    status: Literal["open", "achieved", "dropped"] = "open"


# A file a rerun reads or writes: a path inside a fresh clone of the task's
# commit, or an address outside it, with what it is for and its digest.
class RerunFile(_Model):
    path: _text(500, required=True)
    role: Optional[_text(200)] = None
    digest: Optional[Digest] = None


# How anyone runs a task's work again from its `commit_ref`: the command, run
# from the root of a fresh clone; the lockfile that pins its environment; the
# files it reads; and the files it writes, with the digests a matching rerun
# gives.
class Rerun(_Model):
    command: _text(4000, required=True, multiline=True)
    lockfile: Optional[RerunFile] = None
    inputs: list[RerunFile] = _items()
    outputs: list[RerunFile] = _items()


class Task(WorkObject):
    """`progress` "done" and `result_ref` are written only by submitting the task.

    Who works on a task is who joined it (`sys.joined`), never a field a
    member writes. `reviewer_key` names the Key asked to review it. `commit_ref` is the exact
    commit of the work and `notebook_ref` the notebook it was worked in; a
    review judges the task version that holds both, so changing either asks
    for review again. `rerun` says how to run the work again from that commit.
    """

    deliverable: Optional[_text(2000, multiline=True)] = None
    acceptance_criteria: list[_text(500)] = _items()
    reviewer_key: Optional[Count] = None
    progress: Literal["todo", "doing", "blocked", "done"] = "todo"
    next_step: Optional[_text(1000, multiline=True)] = None
    commit_ref: Optional[Uri] = None
    notebook_ref: Optional[Uri] = None
    result_ref: Optional[Uri] = None
    rerun: Optional[Rerun] = None


class Finding(WorkObject):
    statement: _text(4000, required=True, multiline=True)
    confidence: Literal["low", "medium", "high"] = "low"
    uncertainty: Optional[_text(2000, multiline=True)] = None


class Evidence(WorkObject):
    source_uri: Uri
    digest: Optional[Digest] = None
    excerpt: Optional[_text(4000, multiline=True)] = None
    # `provenance` is a reserved top-level key upstream, so how the evidence
    # was obtained is recorded under this name.
    how_obtained: Optional[_text(1000, multiline=True)] = None


class Service(WorkObject):
    customer: _text(500, required=True)
    problem: _text(2000, required=True, multiline=True)
    deliverable: _text(2000, required=True, multiline=True)
    payment_asset: Optional[Literal["USDC", "REGENT", "FLEET_TOKEN"]] = None
    price_proposal: Optional[DecimalString] = None
    implementation_refs: list[Uri] = _items()


class Note(WorkObject):
    body: _text(20000, required=True, multiline=True)


# An approach someone tried that didn't work, kept so no one repeats it.
class DeadEnd(WorkObject):
    what_was_tried: _text(4000, required=True, multiline=True)
    why_it_failed: _text(2000, required=True, multiline=True)


# One member's judgement of one submitted task version. Reviews are never
# edited, archived or linked by hand; a reviewer who changes their mind
# reviews the task's next version.
class Review(_Model):
    decision: Literal["accept", "dispute"]
    rationale: _text(4000, required=True, multiline=True)
    # Anything that could sway the reviewer, such as owning the submitting Key
    # or sharing in its pay; "none" when there is nothing to declare.
    conflicts_of_interest: _text(1000, required=True, multiline=True)
    # Whether the reviewer ran the work again from the task's commit and got
    # its result; absent when they did not try.
    reproduction: Optional[Literal["passed", "failed"]] = None

    @model_validator(mode="after")
    def _failed_disputes(self):
        if self.reproduction == "failed" and self.decision != "dispute":
            raise ValueError("a review whose reproduction failed disputes the task")
        return self


class KeyCoordinate(_Model):
    chain_id: Annotated[int, Field(ge=1, le=MAX_INT)]
    contract: Address
    token_id: Count


# A member as one write stamped it: the Key it wrote as, at which of the
# Key's ownerships, and the wallet that signed.
class Member(_Model):
    key: KeyCoordinate
    ownership_epoch: Epoch
    kind: Literal["human", "agent"]
    wallet: Address


class Submitted(Member):
    # The task version the submission made: the version its reviews judge
    # until the task changes again.
    version: Annotated[int, Field(ge=2, le=MAX_INT)]
    evidence: list[str] = _items()


class ReviewedEvidence(_Model):
    id: str
    version: Annotated[int, Field(ge=1, le=MAX_INT)]


class ReviewReceipt(_Model):
    task: str
    task_version: Annotated[int, Field(ge=1, le=MAX_INT)]
    submitted_by: Member
    evidence: list[ReviewedEvidence] = _items()
    # The task's commit at the version judged, when it named one.
    commit_ref: Optional[Uri] = Field(default=None, exclude_if=lambda value: value is None)


class Sys(_Model):
    # Every item belongs to one project of the fleet, set when it is made and
    # never changed. Every member reads and builds on every project's items;
    # only the Key an item belongs to changes or archives it.
    project: ProjectName
    created_by: Member
    archived: bool


# The most starting goals a workspace holds.
MAX_STARTING = 20


# A goal or task records who joined it, in the order they joined: one entry
# for each Key and wallet, with no limit on how many join.
class JoinableSys(Sys):
    joined: list[Member] = Field(default_factory=list)


# A starting goal is one of the ideas every workspace begins with, by its
# number in the list; no member created it, and it stays.
class GoalSys(JoinableSys):
    created_by: Optional[Member]
    starting: Optional[Annotated[int, Field(ge=1, le=MAX_STARTING)]] = None

    @model_validator(mode="after")
    def _one_author(self):
        if (self.created_by is None) == (self.starting is None):
            raise ValueError("a goal is either created by a member or a starting goal")
        return self


# A task records its latest submission once it has one.
class TaskSys(JoinableSys):
    submitted: Optional[Submitted] = Field(default=None, exclude_if=lambda value: value is None)


# A review records what it judged.
class ReviewSys(Sys):
    review: ReviewReceipt


_RECORD_SYS: dict[str, type[Sys]] = {"goal": GoalSys, "task": TaskSys, "review": ReviewSys}


MEMBER_MODELS: dict[str, type[WorkObject]] = {
    "goal": Goal,
    "task": Task,
    "finding": Finding,
    "evidence": Evidence,
    "service": Service,
    "note": Note,
    "dead_end": DeadEnd,
}


RECORD_MODELS: dict[str, type[BaseModel]] = {
    name: create_model(f"{member.__name__}Record", __base__=member, sys=(_RECORD_SYS.get(name, Sys), ...))
    for name, member in {**MEMBER_MODELS, "review": Review}.items()
}


class RelationData(_Model):
    note: Optional[_text(500)] = None


_ALL = tuple(MEMBER_MODELS)
_PLANS = ("goal", "task", "service")

RELATION_ENDPOINTS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "supports": (("finding", "evidence"), ("finding", "goal", "task", "service")),
    "contradicts": (("finding", "evidence"), ("finding", "goal", "service")),
    "depends_on": (_PLANS, _PLANS),
    "implements": (("task", "service"), ("goal", "service")),
    "produces": (("task",), ("evidence", "finding", "note", "dead_end")),
    "references": (_ALL, _ALL),
}

PACK = Pack(
    name=PACK_NAME,
    version=PACK_VERSION,
    description="Keyfleet shared work graph.",
    object_types=[ObjectType(name, model) for name, model in RECORD_MODELS.items()],
    relation_types=[
        *(
            RelationType(name, source_types=sources, target_types=targets)
            for name, (sources, targets) in RELATION_ENDPOINTS.items()
        ),
        # From a review to the task it judged; only the review op makes one.
        RelationType("reviews", source_types=("review",), target_types=("task",)),
        # From a forked task to the task it was copied from; only the fork op makes one.
        RelationType("forks", source_types=("task",), target_types=("task",)),
    ],
    behaviors=[],
    tools=[],
    policies=[],
)
