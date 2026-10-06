// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @notice Which keys of one fleet are present: renewed within the last 48 hours under their
/// current owner.
/// @dev Inlined into `KeyfleetVotes`. A key is present for `WINDOW` seconds after its latest
/// renewal, measured in block timestamps, never in blocks. Token ids fit in 32 bits, because the
/// fleet never mints past `type(uint32).max`.
///
/// Present keys sit in one queue ordered by expiry, one entry per key. Every renewal expires
/// exactly `WINDOW` after the block it lands in and block timestamps never go down, so appending
/// at the tail keeps the queue ordered, and a renewed key is unlinked and appended again in
/// constant time. Time alone removes nothing: an entry stays in the queue after it expires until a
/// sweep pops it from the head, so `queued` may count expired entries and is exact only once every
/// due entry has been swept.
///
/// Every renewal, every ownership change and every proposal opening raises one `revision`, and
/// each key keeps a checkpoint per renewal or ownership change, keyed by that revision, holding the
/// renewal's timestamp or zero for an ownership change. Whether a key was present at any recorded
/// moment is then read from its checkpoints, exactly even for several operations in one block,
/// without listing every present key anywhere.
library KeyfleetPresence {
    using Checkpoints for Checkpoints.Trace208;

    /// @notice How long a renewal keeps a key present: 48 hours, in seconds.
    uint64 internal constant WINDOW = 172_800;

    /// @notice One key's place in the queue. A key is queued exactly when `expiresAt` is not zero.
    struct Node {
        uint32 prev;
        uint32 next;
        uint64 expiresAt;
    }

    struct Queue {
        mapping(uint256 tokenId => Node) node;
        uint32 head;
        uint32 tail;
        uint32 queued;
        uint48 revision;
        mapping(uint256 tokenId => Checkpoints.Trace208) activity;
    }

    /// @notice Renews a key: moves it to the tail of the queue, expiring `WINDOW` from now, and
    /// records the renewal at a new revision.
    function touch(Queue storage queue, uint256 tokenId) internal returns (uint64 expiresAt) {
        uint32 id = uint32(tokenId);
        if (queue.node[id].expiresAt != 0) _unlink(queue, id);
        else ++queue.queued;

        expiresAt = uint64(block.timestamp) + WINDOW;
        uint32 tail = queue.tail;
        queue.node[id] = Node({prev: tail, next: 0, expiresAt: expiresAt});
        if (tail == 0) queue.head = id;
        else queue.node[tail].next = id;
        queue.tail = id;

        queue.activity[id].push(++queue.revision, uint208(block.timestamp));
    }

    /// @notice Ends a key's presence because it changed hands, and records that at a new revision.
    /// Its earlier checkpoints stay.
    function clear(Queue storage queue, uint256 tokenId) internal {
        uint32 id = uint32(tokenId);
        if (queue.node[id].expiresAt != 0) {
            _unlink(queue, id);
            --queue.queued;
        }
        queue.activity[id].push(++queue.revision, 0);
    }

    /// @notice Pops up to `limit` expired entries from the head of the queue.
    /// @return removed How many entries were popped.
    /// @return due Whether expired entries are still queued.
    function sweep(Queue storage queue, uint256 limit) internal returns (uint256 removed, bool due) {
        uint32 head = queue.head;
        while (removed < limit && head != 0 && queue.node[head].expiresAt <= block.timestamp) {
            uint32 next = queue.node[head].next;
            delete queue.node[head];
            head = next;
            ++removed;
        }
        if (removed != 0) {
            queue.head = head;
            if (head == 0) queue.tail = 0;
            else queue.node[head].prev = 0;
            queue.queued -= uint32(removed);
        }
        due = head != 0 && queue.node[head].expiresAt <= block.timestamp;
    }

    /// @notice Raises the revision for a moment that is not about one key, a proposal opening, and
    /// returns it.
    function mark(Queue storage queue) internal returns (uint48) {
        return ++queue.revision;
    }

    /// @notice When the key was last renewed under its current owner, or zero if it changed hands
    /// since or was never renewed.
    function lastActiveAt(Queue storage queue, uint256 tokenId) internal view returns (uint64) {
        return uint64(queue.activity[tokenId].latest());
    }

    /// @notice Whether the key is present now.
    function isActive(Queue storage queue, uint256 tokenId) internal view returns (bool) {
        uint256 at = queue.activity[tokenId].latest();
        return at != 0 && block.timestamp < at + WINDOW;
    }

    /// @notice Whether the key was present at time `at` as recorded at revision `revision`.
    function wasActive(Queue storage queue, uint256 tokenId, uint48 revision, uint64 at) internal view returns (bool) {
        uint256 renewedAt = queue.activity[tokenId].upperLookupRecent(revision);
        return renewedAt != 0 && renewedAt <= at && at < renewedAt + WINDOW;
    }

    function _unlink(Queue storage queue, uint32 id) private {
        Node storage linked = queue.node[id];
        uint32 prev = linked.prev;
        uint32 next = linked.next;
        if (prev == 0) queue.head = next;
        else queue.node[prev].next = next;
        if (next == 0) queue.tail = prev;
        else queue.node[next].prev = prev;
        delete queue.node[id];
    }
}
