// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @notice Which keys of one fleet are present: renewed within the last 48 hours under their
/// current owner, or within 48 hours of their automatic start.
/// @dev Inlined into `KeyfleetVotes`. A key is present for `WINDOW` seconds from the start of its
/// latest presence, measured in block timestamps, never in blocks. A presence starts either when the
/// key is renewed or, once only, at the automatic start the key is enrolled with when it is sold, as
/// if it had been renewed at that moment. Token ids fit in 64 bits, because the collection never
/// numbers a fleet past `KeyfleetKeys.MAX_FLEETS`, so no token id reaches 10^19.
///
/// Every key sits in at most one of three lists, each ordered by the time its entries fall due:
/// `waiting` holds enrolled keys whose automatic start is still to come, due at that start;
/// `automatic` holds keys present from their automatic start and not renewed since, due when that
/// presence ends; `renewed` holds keys present from a renewal, due when it ends. Every renewal ends
/// exactly `WINDOW` after the block it lands in, every automatic start is the same fixed time after
/// the block its key was sold in, and block timestamps never go down, so appending at the tail keeps
/// each list ordered, and an entry is unlinked from any place in constant time. Time alone moves
/// nothing: a sweep moves due entries from the heads, a started waiting key to `automatic` and an
/// ended presence out, so `automatic.count + renewed.count` is the exact number of present keys
/// only once every due entry has been swept.
///
/// Every enrolment, renewal, ownership change and proposal opening raises one `revision`, and each
/// key keeps a checkpoint per enrolment, renewal or ownership change, keyed by that revision,
/// holding the start of the presence it began (the automatic start for an enrolment, the renewal's
/// timestamp for a renewal) or zero for an ownership change. Whether a key was present at any
/// recorded moment is then read from its checkpoints, exactly even for several operations in one
/// block, without listing every present key anywhere.
library KeyfleetPresence {
    using Checkpoints for Checkpoints.Trace208;

    /// @notice How long a presence lasts: 48 hours, in seconds.
    uint64 internal constant WINDOW = 172_800;

    /// @notice The list a key is in.
    enum Place {
        None,
        Waiting,
        Automatic,
        Renewed
    }

    /// @notice One key's place in its list. `dueAt` is when it falls due: its automatic start while
    /// it waits, the end of its presence otherwise.
    struct Node {
        uint64 prev;
        uint64 next;
        uint64 dueAt;
        Place place;
    }

    /// @notice One list's ends and its entry count.
    struct List {
        uint64 head;
        uint64 tail;
        uint32 count;
    }

    struct Queue {
        mapping(uint256 tokenId => Node) node;
        List waiting;
        List automatic;
        List renewed;
        uint48 revision;
        mapping(uint256 tokenId => Checkpoints.Trace208) activity;
    }

    /// @notice Enrols a newly sold key: it waits until `startsAt`, and is then present for `WINDOW`
    /// without being renewed. Records that presence at a new revision.
    function enroll(Queue storage queue, uint256 tokenId, uint64 startsAt) internal {
        uint64 id = uint64(tokenId);
        _append(queue, queue.waiting, Place.Waiting, id, startsAt);
        queue.activity[id].push(++queue.revision, uint208(startsAt));
    }

    /// @notice Renews a key: moves it to the tail of `renewed`, ending `WINDOW` from now, and
    /// records the renewal at a new revision.
    function touch(Queue storage queue, uint256 tokenId) internal returns (uint64 expiresAt) {
        uint64 id = uint64(tokenId);
        _unlink(queue, id);
        expiresAt = uint64(block.timestamp) + WINDOW;
        _append(queue, queue.renewed, Place.Renewed, id, expiresAt);
        queue.activity[id].push(++queue.revision, uint208(block.timestamp));
    }

    /// @notice Ends a key's presence because it changed hands, and records that at a new revision.
    /// Its earlier checkpoints stay. A key whose automatic start is still to come has no presence
    /// to end and keeps that start, so nothing is recorded for it.
    /// @return cleared Whether anything was recorded.
    function clear(Queue storage queue, uint256 tokenId) internal returns (bool cleared) {
        uint64 id = uint64(tokenId);
        Node storage linked = queue.node[id];
        if (linked.place == Place.Waiting && linked.dueAt > block.timestamp) return false;
        _unlink(queue, id);
        queue.activity[id].push(++queue.revision, 0);
        return true;
    }

    /// @notice Moves up to `limit` due entries: waiting keys whose automatic start has come move to
    /// `automatic`, or out if that presence has ended too, then ended presences leave `automatic`
    /// and `renewed`.
    /// @return moved How many entries were moved.
    /// @return due Whether due entries are still listed.
    function sweep(Queue storage queue, uint256 limit) internal returns (uint256 moved, bool due) {
        uint64 head = queue.waiting.head;
        while (moved < limit && head != 0 && queue.node[head].dueAt <= block.timestamp) {
            uint64 endsAt = queue.node[head].dueAt + WINDOW;
            _unlink(queue, head);
            if (endsAt > block.timestamp) _append(queue, queue.automatic, Place.Automatic, head, endsAt);
            ++moved;
            head = queue.waiting.head;
        }
        moved += _pop(queue, queue.automatic, limit - moved);
        moved += _pop(queue, queue.renewed, limit - moved);
        due = _isDue(queue, queue.waiting) || _isDue(queue, queue.automatic) || _isDue(queue, queue.renewed);
    }

    /// @notice Raises the revision for a moment that is not about one key, a proposal opening, and
    /// returns it.
    function mark(Queue storage queue) internal returns (uint48) {
        return ++queue.revision;
    }

    /// @notice How many keys are listed as present. Exact once nothing is due.
    function presentCount(Queue storage queue) internal view returns (uint32) {
        return queue.automatic.count + queue.renewed.count;
    }

    /// @notice When the key's latest presence starts: its latest renewal or, for a key not renewed
    /// since it was sold, its automatic start, which is still to come while it waits. Zero once it
    /// changed hands after that start.
    function presentFrom(Queue storage queue, uint256 tokenId) internal view returns (uint64) {
        return uint64(queue.activity[tokenId].latest());
    }

    /// @notice Whether the key is present now.
    function isActive(Queue storage queue, uint256 tokenId) internal view returns (bool) {
        uint256 from = queue.activity[tokenId].latest();
        return from != 0 && from <= block.timestamp && block.timestamp < from + WINDOW;
    }

    /// @notice Whether the key was present at time `at` as recorded at revision `revision`.
    function wasActive(Queue storage queue, uint256 tokenId, uint48 revision, uint64 at) internal view returns (bool) {
        uint256 from = queue.activity[tokenId].upperLookupRecent(revision);
        return from != 0 && from <= at && at < from + WINDOW;
    }

    function _append(Queue storage queue, List storage list, Place place, uint64 id, uint64 dueAt) private {
        uint64 tail = list.tail;
        queue.node[id] = Node({prev: tail, next: 0, dueAt: dueAt, place: place});
        if (tail == 0) list.head = id;
        else queue.node[tail].next = id;
        list.tail = id;
        ++list.count;
    }

    /// @dev Unlinks the key from whichever list holds it; a key in none is left as it is.
    function _unlink(Queue storage queue, uint64 id) private {
        Node storage linked = queue.node[id];
        Place place = linked.place;
        if (place == Place.None) return;
        List storage list = _list(queue, place);
        uint64 prev = linked.prev;
        uint64 next = linked.next;
        if (prev == 0) list.head = next;
        else queue.node[prev].next = next;
        if (next == 0) list.tail = prev;
        else queue.node[next].prev = prev;
        --list.count;
        delete queue.node[id];
    }

    /// @dev Pops up to `limit` ended presences from the head of `list`.
    function _pop(Queue storage queue, List storage list, uint256 limit) private returns (uint256 popped) {
        uint64 head = list.head;
        while (popped < limit && head != 0 && queue.node[head].dueAt <= block.timestamp) {
            uint64 next = queue.node[head].next;
            delete queue.node[head];
            head = next;
            ++popped;
        }
        if (popped != 0) {
            list.head = head;
            if (head == 0) list.tail = 0;
            else queue.node[head].prev = 0;
            list.count -= uint32(popped);
        }
    }

    function _isDue(Queue storage queue, List storage list) private view returns (bool) {
        uint64 head = list.head;
        return head != 0 && queue.node[head].dueAt <= block.timestamp;
    }

    function _list(Queue storage queue, Place place) private view returns (List storage) {
        if (place == Place.Waiting) return queue.waiting;
        if (place == Place.Automatic) return queue.automatic;
        return queue.renewed;
    }
}
