// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";

/// @dev Drives renewals, transfers, sweeps, proposal openings and the passing of time over a small
/// fleet, as the keys' owners would.
contract PresenceHandler is Test {
    uint256 internal constant KEYS = 8;

    KeyfleetManager internal immutable fleet;
    KeyfleetKeys internal immutable keys;
    KeyfleetVotes internal immutable votes;
    address[3] internal holders = [address(0xA1), address(0xA2), address(0xA3)];

    constructor(KeyfleetManager fleet_) {
        fleet = fleet_;
        keys = fleet_.KEYS();
        votes = fleet_.VOTES();
    }

    function _key(uint256 seed) private view returns (uint256) {
        return keys.tokenIdOf(fleet.FLEET_ID(), bound(seed, 1, KEYS));
    }

    function present(uint256 seed) external {
        uint256 tokenId = _key(seed);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.prank(keys.ownerOf(tokenId));
        votes.present(ids);
    }

    function transfer(uint256 seed, uint256 to) external {
        uint256 tokenId = _key(seed);
        address from = keys.ownerOf(tokenId);
        vm.prank(from);
        keys.transferFrom(from, holders[to % holders.length], tokenId);
    }

    function sweep(uint256 limit) external {
        votes.sweepExpired(bound(limit, 0, KEYS));
    }

    function propose(uint256 seed) external {
        uint256 tokenId = _key(seed);
        vm.prank(keys.ownerOf(tokenId));
        try votes.propose(tokenId, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0)) {}
            catch {}
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }
}

/// @dev The presence queue's invariants (plan §4.1): it is ordered by expiry, `queued` is the
/// number of linked entries, no key is queued twice, only the fleet's own keys are queued, the
/// entries that have not expired are exactly the present keys, and a key with no record is not
/// present. The fleet is the founding Classic fleet on the shared collection, so every queued id is
/// a full token id of that fleet.
/// forge-config: default.invariant.runs = 256
contract KeyfleetPresenceInvariantTest is KeyfleetFixture {
    uint256 private constant KEYS = 8;

    KeyfleetManager private fleet;
    KeyfleetVotes private votes;
    PresenceHandler private handler;

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();
        for (uint256 i = 0; i < KEYS; ++i) {
            _buy(fleet, address(uint160(0xA1 + (i % 3))));
        }

        handler = new PresenceHandler(fleet);
        targetContract(address(handler));
    }

    /// @dev Walks the queue from head to tail, checking the links and the order on the way. `linked`
    /// is indexed by key number.
    function _walk() private view returns (bool[KEYS + 1] memory linked, uint256 count, uint256 unexpired) {
        (uint64 head, uint64 tail,) = votes.presenceQueue();
        uint64 prev;
        uint64 lastExpiry;
        for (uint64 id = head; id != 0;) {
            assertEq(keys.fleetOf(id), fleet.FLEET_ID(), "only the fleet's own keys are queued");
            uint256 keyNumber = keys.keyNumberOf(id);
            assertGe(keyNumber, 1, "only real keys are queued");
            assertLe(keyNumber, KEYS, "only sold keys are queued");
            assertFalse(linked[keyNumber], "no key is queued twice");
            linked[keyNumber] = true;
            ++count;
            (uint64 back, uint64 next, uint64 expiresAt) = votes.presenceEntry(id);
            assertEq(back, prev, "each entry links back to the one before it");
            assertGe(expiresAt, lastExpiry, "expiries never go down from head to tail");
            assertGt(expiresAt, 0, "a queued entry has an expiry");
            if (expiresAt > block.timestamp) ++unexpired;
            lastExpiry = expiresAt;
            prev = id;
            id = next;
        }
        assertEq(prev, tail, "the walk ends at the tail");
    }

    function invariant_theQueueIsOrderedAndCountedExactly() public view {
        (bool[KEYS + 1] memory linked, uint256 count,) = _walk();
        (,, uint32 queued) = votes.presenceQueue();
        assertEq(count, queued, "queued is the number of linked entries");
        for (uint256 k = 1; k <= KEYS; ++k) {
            (,, uint64 expiresAt) = votes.presenceEntry(_key(fleet, k));
            assertEq(linked[k], expiresAt != 0, "a key is linked exactly when it has an expiry");
        }
    }

    function invariant_theUnexpiredEntriesAreExactlyThePresentKeys() public view {
        (bool[KEYS + 1] memory linked,, uint256 unexpired) = _walk();
        uint256 present;
        for (uint256 k = 1; k <= KEYS; ++k) {
            if (!votes.isActive(_key(fleet, k))) continue;
            ++present;
            assertTrue(linked[k], "a present key is queued");
        }
        assertEq(unexpired, present, "queued minus due is the count of present keys");
    }

    function invariant_aKeyWithNoRecordIsNotPresent() public view {
        for (uint256 k = 1; k <= KEYS; ++k) {
            uint256 tokenId = _key(fleet, k);
            if (votes.lastActiveAt(tokenId) != 0) continue;
            assertFalse(votes.isActive(tokenId), "no record, not present");
            (,, uint64 expiresAt) = votes.presenceEntry(tokenId);
            assertEq(expiresAt, 0, "and not queued");
        }
    }
}
