"""Port framing and the request envelope.

Each message is a 4-byte big-endian length followed by one UTF-8 JSON object,
matching Erlang's `{:packet, 4}`. The envelope models refuse anything outside
the declared shape; a refusal here is a `bad_request`.
"""

import json
import re
import struct
from typing import Annotated, Any, BinaryIO, Literal, Optional

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints, model_validator

MAX_REQUEST_BYTES = 1 << 20
# The most evidence one patch or submission may name.
MAX_EVIDENCE = 20
# SQLite stores integers as signed 64-bit; every integer a request carries fits.
MAX_INT = (1 << 63) - 1
_HEADER = struct.Struct(">I")


class TooLarge:
    """A frame longer than MAX_REQUEST_BYTES, read past without being kept."""


def read_frame(stream: BinaryIO) -> Optional[bytes | TooLarge]:
    """Return the next frame, or None when the peer closed the stream between frames.

    A frame whose header declares more than MAX_REQUEST_BYTES is refused from
    the header alone: its body is read and dropped in pieces, so the stream
    stays in step and the next frame is served as usual.
    """
    header = _read_exact(stream, _HEADER.size)
    if header is None:
        return None
    (length,) = _HEADER.unpack(header)
    if length > MAX_REQUEST_BYTES:
        _skip(stream, length)
        return TooLarge()
    frame = _read_exact(stream, length)
    if frame is None:
        raise EOFError("the stream closed inside a frame")
    return frame


def write_frame(stream: BinaryIO, message: dict[str, Any]) -> None:
    data = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    stream.write(_HEADER.pack(len(data)) + data)
    stream.flush()


def _read_exact(stream: BinaryIO, size: int) -> Optional[bytes]:
    chunks = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            if remaining == size:
                return None
            raise EOFError("the stream closed inside a frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _skip(stream: BinaryIO, size: int) -> None:
    remaining = size
    while remaining:
        chunk = stream.read(min(remaining, 1 << 16))
        if not chunk:
            raise EOFError("the stream closed inside a frame")
        remaining -= len(chunk)


class _Shape(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


# The bidirectional embedding, override and isolate controls count as control
# characters too: they can make stored text display in a different order from
# the one it is read in.
_BIDI = "\u202a-\u202e\u2066-\u2069"
_CONTROL = re.compile(rf"[\x00-\x1f\x7f-\x9f{_BIDI}]")
_CONTROL_EXCEPT_LINES = re.compile(rf"[\x00-\x08\x0b-\x1f\x7f-\x9f{_BIDI}]")


def _refuse(pattern: re.Pattern, what: str):
    def check(value: str) -> str:
        if pattern.search(value):
            raise ValueError(what)
        return value

    return AfterValidator(check)


# Text on one line refuses every control character; longer text may also hold
# newlines and tabs.
single_line = _refuse(_CONTROL, "must not contain control characters")
multi_line = _refuse(_CONTROL_EXCEPT_LINES, "must not contain control characters other than newline and tab")

Count = Annotated[int, Field(ge=0, le=MAX_INT)]
Version = Annotated[int, Field(ge=1, le=MAX_INT)]
Epoch = Annotated[int, Field(ge=1, le=MAX_INT)]
Address = Annotated[str, StringConstraints(pattern=r"^0x[0-9a-f]{40}$")]
Id = Annotated[str, StringConstraints(min_length=1, max_length=128), single_line]
Name = Annotated[str, StringConstraints(max_length=64), single_line]
Reason = Annotated[str, StringConstraints(max_length=1000), multi_line]
Sha256Ref = Annotated[str, StringConstraints(pattern=r"^sha256:[0-9a-f]{64}$")]
UtcTimestamp = Annotated[str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$")]


class KeyRef(_Shape):
    chain_id: Annotated[int, Field(ge=1, le=MAX_INT)]
    contract: Address
    token_id: Count


class Auth(_Shape):
    key: KeyRef
    ownership_epoch: Epoch
    kind: Literal["human", "agent"]
    operator_wallet: Address
    credential_ref: Optional[Sha256Ref]
    beneficiary_privy_user_id: Optional[str] = None
    pairing_id: Optional[str] = None
    checked_at: UtcTimestamp
    chain_block: Optional[Count]


class Command(_Shape):
    id: Id
    principal: str
    auth: Auth

    @model_validator(mode="after")
    def _principal_names_the_audited_key(self) -> "Command":
        if self.principal != member_principal(self.auth):
            raise ValueError("principal must name the audited key, epoch and wallet")
        return self


def member_principal(auth: Auth) -> str:
    key = auth.key
    return (
        f"member:{key.chain_id}:{key.contract}:{key.token_id}"
        f"@{auth.ownership_epoch}/{auth.kind}:{auth.operator_wallet}"
    )


class Request(_Shape):
    v: Literal[1]
    req: Id
    op: str
    command: Optional[Command] = None
    body: dict[str, Any]


class HelloBody(_Shape):
    pass


class ChangesBody(_Shape):
    after_seq: Count
    limit: Annotated[int, Field(ge=1, le=500)]


class CreateBody(_Shape):
    type: Name
    data: dict[str, Any]

class PatchBody(_Shape):
    id: Id
    expected_version: Version
    set: dict[str, Any] = Field(default_factory=dict)
    unset: Annotated[list[Name], Field(max_length=64)] = Field(default_factory=list)
    reason: Optional[Reason] = None
    evidence: Annotated[list[Id], Field(max_length=MAX_EVIDENCE)] = Field(default_factory=list)


class LinkBody(_Shape):
    source: Id
    target: Id
    type: Name
    note: Optional[str] = None


class UnlinkBody(_Shape):
    relation_id: Id


class JoinBody(_Shape):
    id: Id


class LeaveBody(_Shape):
    id: Id


class ArchiveBody(_Shape):
    id: Id
    expected_version: Version
    reason: Optional[Reason] = None


class SubmitBody(_Shape):
    id: Id
    expected_version: Version
    result_ref: Optional[str] = None
    evidence: Annotated[list[Id], Field(max_length=MAX_EVIDENCE)] = Field(default_factory=list)
    reason: Optional[Reason] = None


class ForkBody(_Shape):
    id: Id


class ReviewBody(_Shape):
    task: Id
    task_version: Version
    decision: str
    rationale: str
    conflicts_of_interest: str
    reproduction: Optional[str] = None


READ_OPS: dict[str, type[_Shape]] = {
    "hello": HelloBody,
    "changes": ChangesBody,
}

WRITE_OPS: dict[str, type[_Shape]] = {
    "create": CreateBody,
    "patch": PatchBody,
    "link": LinkBody,
    "unlink": UnlinkBody,
    "archive": ArchiveBody,
    "join": JoinBody,
    "leave": LeaveBody,
    "submit": SubmitBody,
    "review": ReviewBody,
    "fork": ForkBody,
}
