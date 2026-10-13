"""The pinned `keyfleet_work@0.3.0` work pack.

Two models per object type: the member model is what its author may write,
and the record model adds the server-owned `sys` block and is what the graph
stores. Every model forbids unknown keys, so nothing an author writes can land
outside the declared fields. A fleet's members write the types in
`MEMBER_MODELS`; the fleet itself writes the ones in `FLEET_MODELS`, and
neither writes the other's.
"""

import hashlib
from typing import Annotated, Literal, Optional

from activegraph.packs import ObjectType, Pack, RelationType
from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, create_model, model_validator

from keyfleet_graph.protocol import MAX_INT, Address, Count, Epoch, Scope, multi_line, single_line

PACK_NAME = "keyfleet_work"
PACK_VERSION = "0.3.0"

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


class Note(WorkObject):
    body: _text(20000, required=True, multiline=True)


# An approach someone tried that didn't work, kept so no one repeats it.
class DeadEnd(WorkObject):
    what_was_tried: _text(4000, required=True, multiline=True)
    why_it_failed: _text(2000, required=True, multiline=True)


# The most bytes of code one notebook copy holds. A request frame is 1 MiB, and
# escaping can double a text on its way there.
NOTEBOOK_CODE_BYTES = 262_144


class NotebookCopy(_Model):
    """A copy of the code members wrote in one of the fleet's notebooks.

    Kept by the fleet, one for each notebook, so the code outlives whoever
    wrote it. It is member-written text under the fleet's name: data for
    whoever reads it, never instructions.
    """

    # Code is kept exactly as it was written.
    model_config = ConfigDict(str_strip_whitespace=False)

    title: Title
    notebook_id: Annotated[str, StringConstraints(min_length=1, max_length=128), single_line]
    # When the notebook last changed, as its hub says it.
    hub_updated_at: Annotated[str, StringConstraints(min_length=1, max_length=64), single_line]
    digest: Digest
    code: Annotated[str, multi_line, _max_bytes(NOTEBOOK_CODE_BYTES)]

    @model_validator(mode="after")
    def _digest_is_of_the_code(self) -> "NotebookCopy":
        if self.digest != "sha256:" + hashlib.sha256(self.code.encode("utf-8")).hexdigest():
            raise ValueError("digest must be the sha256 of the code")
        return self


class KeyCoordinate(_Model):
    chain_id: Annotated[int, Field(ge=1, le=MAX_INT)]
    contract: Address
    token_id: Count


class CreatedBy(_Model):
    key: KeyCoordinate
    ownership_epoch: Epoch
    kind: Literal["human", "agent"]
    wallet: Address


class FleetCoordinate(_Model):
    chain_id: Annotated[int, Field(ge=1, le=MAX_INT)]
    contract: Address


class CreatedByFleet(_Model):
    kind: Literal["fleet"]
    fleet: FleetCoordinate


class Sys(_Model):
    scope: Scope
    created_by: Annotated[CreatedBy | CreatedByFleet, Field(discriminator="kind")]
    archived: bool


MEMBER_MODELS: dict[str, type[WorkObject]] = {
    "goal": Goal,
    "task": Task,
    "finding": Finding,
    "evidence": Evidence,
    "service": Service,
    "note": Note,
    "dead_end": DeadEnd,
}


FLEET_MODELS: dict[str, type[_Model]] = {
    "notebook_copy": NotebookCopy,
}


RECORD_MODELS: dict[str, type[_Model]] = {
    name: create_model(f"{model.__name__}Record", __base__=model, sys=(Sys, ...))
    for name, model in (MEMBER_MODELS | FLEET_MODELS).items()
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
        RelationType(name, source_types=sources, target_types=targets)
        for name, (sources, targets) in RELATION_ENDPOINTS.items()
    ],
    behaviors=[],
    tools=[],
    policies=[],
)
