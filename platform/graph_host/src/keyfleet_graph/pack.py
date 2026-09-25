"""The pinned `keyfleet_work@0.1.0` work pack.

Two models per object type: the member model is what a member may write, and
the record model adds the server-owned `sys` block and is what the graph
stores. Every model forbids unknown keys, so nothing a member writes can land
outside the declared fields.
"""

from typing import Annotated, Literal, Optional

from activegraph.packs import ObjectType, Pack, RelationType
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, create_model

from keyfleet_graph.protocol import MAX_INT, Address, Count, Scope, multi_line, single_line

PACK_NAME = "keyfleet_work"
PACK_VERSION = "0.1.0"

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


class Task(WorkObject):
    deliverable: Optional[_text(2000, multiline=True)] = None
    assignee_key: Optional[Count] = None
    progress: Literal["todo", "doing", "blocked", "done"] = "todo"
    next_step: Optional[_text(1000, multiline=True)] = None
    result_ref: Optional[Uri] = None


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


class LaunchCard(WorkObject):
    who_we_serve: Optional[_text(4000, multiline=True)] = None
    what_we_sell: Optional[_text(4000, multiline=True)] = None
    what_works: Optional[_text(4000, multiline=True)] = None
    why_raise: Optional[_text(4000, multiline=True)] = None
    commitments: Optional[_text(4000, multiline=True)] = None
    narrative: Optional[_text(20000, multiline=True)] = None
    name: Optional[Annotated[str, single_line, _max_bytes(64)]] = None
    symbol: Optional[Annotated[str, single_line, _max_bytes(16)]] = None
    description: Optional[Annotated[str, multi_line, _max_bytes(512)]] = None
    website: Optional[Annotated[str, single_line, _max_bytes(256)]] = None
    image: Optional[Annotated[str, single_line, _max_bytes(256)]] = None
    required_regent_raised: Optional[DecimalString] = None


class Note(WorkObject):
    body: _text(20000, required=True, multiline=True)


class KeyCoordinate(_Model):
    chain_id: Annotated[int, Field(ge=1, le=MAX_INT)]
    contract: Address
    token_id: Count


class CreatedBy(_Model):
    key: KeyCoordinate
    ownership_epoch: Count
    kind: Literal["human", "agent"]
    wallet: Address


class Sys(_Model):
    scope: Scope
    created_by: CreatedBy
    archived: bool


MEMBER_MODELS: dict[str, type[WorkObject]] = {
    "goal": Goal,
    "task": Task,
    "finding": Finding,
    "evidence": Evidence,
    "service": Service,
    "launch_card": LaunchCard,
    "note": Note,
}


RECORD_MODELS: dict[str, type[WorkObject]] = {
    name: create_model(f"{member.__name__}Record", __base__=member, sys=(Sys, ...))
    for name, member in MEMBER_MODELS.items()
}


class RelationData(_Model):
    note: Optional[_text(500)] = None


_ALL = tuple(MEMBER_MODELS)
_PLANS = ("goal", "task", "service", "launch_card")

RELATION_ENDPOINTS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "supports": (("finding", "evidence"), ("finding", "goal", "task", "service", "launch_card")),
    "contradicts": (("finding", "evidence"), ("finding", "goal", "service", "launch_card")),
    "depends_on": (_PLANS, _PLANS),
    "implements": (("task", "service"), ("goal", "service")),
    "produces": (("task",), ("evidence", "finding", "note", "launch_card")),
    "references": (_ALL, _ALL),
}

PACK = Pack(
    name=PACK_NAME,
    version=PACK_VERSION,
    description="Keyfleet shared work graph.",
    object_types=[ObjectType(name, model) for name, model in RECORD_MODELS.items()],
    relation_types=[
        RelationType(name, source_types=sources, target_types=targets)
        for name, (sources, targets) in RELATION_ENDPOINTS.items()
    ],
    behaviors=[],
    tools=[],
    policies=[],
)
