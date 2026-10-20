"""The two reactions a write can set off, run inside the write's own transaction.

A reaction only asks members to look at something. It emits
`keyfleet.attention` events and never changes an object or a link:

- `task_unblocked`: a task no longer waits on anything, because the last of
  its unfinished `depends_on` targets was submitted, archived or unlinked;
- `needs_review`: new evidence supports or contradicts an object, a task
  produces something new, or a task is submitted.

A target is finished once it is archived, or when it is a task marked done;
other types have no finished state of their own. A task waits while it is
neither archived nor done.

Each reaction reads only the write's own change and the graph as the write
left it, and does no I/O. Only a member's change sets one off; attention
events never do, so a reaction never leads to another and the cascade depth
is one. Each attention event names its cause, the event of the change that
set it off, and a `dedupe_key` built from the fleet's log id, its kind, object
and cause. A cause is one durable event whose reactions run once, in its own
transaction: the same command again is answered from the ledger, and a
restart runs nothing again. So no key is ever asked twice, in any fleet, and
readers can rely on it.

Every command is bounded by `MAX_ATTENTION` events and `MAX_WORK` dependency
links read, whatever the size of the fleet; see the design note, §7.6.
"""

from collections.abc import Iterable
from typing import Any

ATTENTION_EVENT = "keyfleet.attention"

# The most attention events one command may emit. A notice is a hint to look,
# so fifty is more than a fleet can act on at once; past it the rest are not
# asked, and the command still commits.
MAX_ATTENTION = 50
# The most `depends_on` links one command's reactions may read: two thousand
# dictionary lookups, a few milliseconds, whatever the fan-out. A task whose
# check is cut short is not announced, since it cannot be known to be
# unblocked.
MAX_WORK = 2_000

# Links that ask for a review of their target, by the source types that do.
_REVIEWED_LINKS = {
    "supports": ("evidence",),
    "contradicts": ("evidence",),
    "produces": ("task",),
}


def dedupe_key(log_id: str, kind: str, object_id: str, cause: str) -> str:
    return f"{log_id}:{kind}:{object_id}:{cause}"


class DependsOnLinks:
    """Every `depends_on` link of a fleet, by source and by target, in the order they were made.

    The host gathers them once, when it opens the fleet's graph, and records
    each link made or removed after that, so a reaction reads only the links
    of the objects it looks at.
    """

    def __init__(self, graph):
        self._targets: dict[str, dict[str, str]] = {}
        self._sources: dict[str, dict[str, str]] = {}
        for rel in graph.relations(type="depends_on"):
            self.made(rel)

    def made(self, rel) -> None:
        if rel.type == "depends_on":
            self._targets.setdefault(rel.source, {})[rel.id] = rel.target
            self._sources.setdefault(rel.target, {})[rel.id] = rel.source

    def removed(self, rel) -> None:
        if rel.type == "depends_on":
            self._targets[rel.source].pop(rel.id)
            self._sources[rel.target].pop(rel.id)

    def targets_of(self, object_id: str) -> Iterable[str]:
        """What `object_id` depends on."""
        return self._targets.get(object_id, {}).values()

    def sources_of(self, object_id: str) -> Iterable[str]:
        """What depends on `object_id`."""
        return self._sources.get(object_id, {}).values()


class Reactions:
    """The attention one command asks for, within the per-command bounds.

    The host calls one hook after the command's change, with the id of the
    event that recorded it, then emits `attention` in order. `links` already
    includes the command's own change.
    """

    def __init__(self, graph, links: DependsOnLinks, log_id: str):
        self._graph = graph
        self._links = links
        self._log_id = log_id
        self._work = 0
        self.attention: list[dict[str, Any]] = []

    def submitted(self, task, was_done: bool, cause: str) -> None:
        """`was_done` says the task was already done, so its dependents were already told."""
        self._ask("needs_review", task.id, cause)
        if not was_done:
            self._dependents_of(task.id, cause)

    def archived(self, obj, cause: str) -> None:
        # Archiving leaves the rest of the object as it was, so a task that was
        # done before it was archived was already finished.
        if not _done(obj):
            self._dependents_of(obj.id, cause)

    def linked(self, rel, source, cause: str) -> None:
        if source.type in _REVIEWED_LINKS.get(rel.type, ()):
            self._ask("needs_review", rel.target, cause)

    def unlinked(self, rel, target, cause: str) -> None:
        """`rel` is the link as it stood before it was removed."""
        if rel.type == "depends_on" and not _finished(target):
            self._check(rel.source, cause)

    def _dependents_of(self, target_id: str, cause: str) -> None:
        for source_id in self._links.sources_of(target_id):
            if not self._spend():
                return
            self._check(source_id, cause)

    def _check(self, source_id: str, cause: str) -> None:
        if not _waiting(self._graph.get_object(source_id)):
            return
        for target_id in self._links.targets_of(source_id):
            if not self._spend():
                return
            if not _finished(self._graph.get_object(target_id)):
                return
        self._ask("task_unblocked", source_id, cause)

    # Every read of a dependency link spends from the work bound. Once the
    # command has asked all it may, reading on would find nothing to ask, so
    # this is also where the attention bound holds.
    def _spend(self) -> bool:
        if self._work >= MAX_WORK or len(self.attention) >= MAX_ATTENTION:
            return False
        self._work += 1
        return True

    def _ask(self, kind: str, object_id: str, cause: str) -> None:
        self.attention.append(
            {
                "kind": kind,
                "object_id": object_id,
                "cause": {"event_id": cause},
                "dedupe_key": dedupe_key(self._log_id, kind, object_id, cause),
            }
        )


def _done(obj) -> bool:
    return obj.type == "task" and obj.data.get("progress") == "done"


def _finished(obj) -> bool:
    return obj.data["sys"]["archived"] or _done(obj)


def _waiting(obj) -> bool:
    return obj.type == "task" and not _finished(obj)
