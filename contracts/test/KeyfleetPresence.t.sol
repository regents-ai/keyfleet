// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresence} from "../src/KeyfleetPresence.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev Presence: a key is present for 48 hours from its automatic start at maturity and for 48
/// hours after it is renewed under its current owner, stops being present when it changes hands, and
/// a proposal opens only on an exact count.
contract KeyfleetPresenceTest is KeyfleetFixture {
    using stdStorage for StdStorage;

    uint64 private constant WINDOW = 172_800;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private mallory = address(0x4A11);

    /// @dev The founding Classic fleet, fleet 1, and its voting controller.
    KeyfleetManager private fleet;
    KeyfleetVotes private votes;
    /// @dev The founding Classic fleet's token id for key number zero, so key `n` is this plus `n`
    /// without a call that a pending prank or expected revert would catch.
    uint256 private keyBase;

    event Present(uint256 indexed tokenId, uint64 at, uint64 blockNumber, uint64 epoch);
    event PresenceCleared(uint256 indexed tokenId);
    event Swept(uint256 moved, bool due);

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(1_000);
        _setUpFixture();
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();
        keyBase = keys.tokenIdOf(fleet.FLEET_ID(), 0);
    }

    /// @dev The token id of key `keyNumber` of the founding Classic fleet.
    function _k(uint256 keyNumber) private view returns (uint256) {
        return keyBase + keyNumber;
    }

    /// @dev Buys `count` keys of `manager` for `receiver`.
    function _buy(KeyfleetManager manager, address receiver, uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            _buy(manager, receiver);
        }
    }

    /// @dev How many keys `v` lists as present from a renewal, swept or not.
    function _renewed(KeyfleetVotes v) private view returns (uint32 count) {
        (,, count) = v.presenceList(KeyfleetPresence.Place.Renewed);
    }

    function _noCalls() private pure returns (KeyfleetTreasury.Call[] memory) {
        return new KeyfleetTreasury.Call[](0);
    }

    // --- the window -----------------------------------------------------

    /// @dev Invariant: the automatic start and a renewal each keep a key present for exactly 48
    /// hours: one second before the end it is present, at the end it is not.
    function test_aKeyIsPresentForExactlyFortyEightHours() public {
        _buy(fleet, alice, 1);
        uint256 k1 = _k(1);
        uint256 startsAt = block.timestamp + votes.KEY_MATURITY();
        assertFalse(votes.isActive(k1), "a key still waiting is not present");
        assertEq(votes.presentFrom(k1), startsAt, "it starts at maturity");
        _mature();
        assertTrue(votes.isActive(k1), "present from its automatic start");
        vm.warp(startsAt + WINDOW - 1);
        assertTrue(votes.isActive(k1), "present one second before the automatic end");
        vm.warp(startsAt + WINDOW);
        assertFalse(votes.isActive(k1), "not present at the automatic end");

        uint256 t = block.timestamp;
        vm.expectEmit(true, true, true, true, address(votes));
        emit Present(k1, uint64(t), uint64(block.number), 1);
        vm.prank(alice);
        votes.present(_ids(k1));
        assertEq(votes.presentFrom(k1), t);
        (KeyfleetPresence.Place place,,, uint64 expiresAt) = votes.presenceEntry(k1);
        assertEq(uint8(place), uint8(KeyfleetPresence.Place.Renewed));
        assertEq(expiresAt, t + WINDOW, "listed to end 48 hours on");

        vm.warp(t + WINDOW - 1);
        assertTrue(votes.isActive(k1), "present one second before the end");
        vm.warp(t + WINDOW);
        assertFalse(votes.isActive(k1), "not present at the end");
    }

    /// @dev Invariant: after three days without a transaction no key is present, the stale entries
    /// stay queued until something sweeps them, and the next proposal sweeps them and counts only
    /// its proposer's key.
    function test_afterThreeDaysWithoutTransactionsNoKeyIsPresent() public {
        _buy(fleet, alice, 3);
        _mature();
        vm.prank(alice);
        votes.present(_range(_k(1), 3));

        vm.warp(block.timestamp + 3 days);
        for (uint256 n = 1; n <= 3; ++n) {
            assertFalse(votes.isActive(_k(n)), "no key is present");
        }
        assertEq(_renewed(votes), 3, "time alone removes nothing from the list");

        vm.prank(alice);
        uint256 proposalId = votes.propose(_k(2), bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        assertEq(votes.proposal(proposalId).e0, 1, "only the proposer's key counts");
        assertEq(_renewed(votes), 1);
        assertTrue(votes.wasActiveAtOpening(proposalId, _k(2)));
        assertFalse(votes.wasActiveAtOpening(proposalId, _k(1)));
    }

    /// @dev Invariant: when every key is dormant anyone holding a key can still renew it and open a
    /// proposal; the fleet never needs a present key to wake up.
    function test_aKeyMayBeRenewedAndProposeWhenEveryKeyIsDormant() public {
        _buy(fleet, alice, 2);
        _buy(fleet, bob, 1);
        _mature();
        _lapse();
        for (uint256 n = 1; n <= 3; ++n) {
            assertFalse(votes.isActive(_k(n)), "nothing is present");
        }

        vm.prank(bob);
        votes.present(_ids(_k(3)));
        assertTrue(votes.isActive(_k(3)));

        vm.warp(block.timestamp + WINDOW);
        assertFalse(votes.isActive(_k(3)), "dormant again");
        assertEq(_renewed(votes), 1, "an ended entry");
        vm.prank(alice);
        uint256 proposalId = votes.propose(_k(1), bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        assertEq(votes.proposal(proposalId).e0, 1);
    }

    /// @dev Invariant: renewing a key whose entry expired but was never swept moves that one entry
    /// to the back with a new expiry; the key is never queued twice.
    function test_renewingAnUnsweptExpiredEntryRequeuesItOnce() public {
        _buy(fleet, alice, 2);
        _mature();
        uint256 k1 = _k(1);
        uint256 k2 = _k(2);
        vm.prank(alice);
        votes.present(_range(k1, 2));

        vm.warp(block.timestamp + WINDOW + 10);
        assertFalse(votes.isActive(k1));
        vm.prank(alice);
        votes.present(_ids(k1));

        (uint64 head, uint64 tail, uint32 queued) = votes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(queued, 2, "still one entry per key");
        assertEq(head, k2, "the expired key 2 is at the front");
        assertEq(tail, k1, "the renewed key 1 is at the back");
        (KeyfleetPresence.Place place, uint64 prev, uint64 next, uint64 expiresAt) = votes.presenceEntry(k1);
        assertEq(uint8(place), uint8(KeyfleetPresence.Place.Renewed));
        assertEq(prev, k2);
        assertEq(next, 0);
        assertEq(expiresAt, block.timestamp + WINDOW);
        assertTrue(votes.isActive(k1));

        (uint256 removed, bool due) = votes.sweepExpired(10);
        assertEq(removed, 1, "only key 2 was due");
        assertFalse(due);
        (head, tail, queued) = votes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(head, k1);
        assertEq(tail, k1);
        assertEq(queued, 1);
    }

    // --- sweeping and opening -------------------------------------------

    /// @dev Invariant: a sweep removes at most `limit` expired entries, says whether more are due,
    /// and never removes an entry that has not expired.
    function test_sweepingIsBoundedByItsLimit() public {
        _buy(fleet, alice, 12);
        _mature();
        vm.prank(alice);
        votes.present(_range(_k(1), 8));
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        votes.present(_range(_k(9), 4));
        vm.warp(block.timestamp + WINDOW - 1);

        vm.expectEmit(true, true, true, true, address(votes));
        emit Swept(3, true);
        (uint256 removed, bool due) = votes.sweepExpired(3);
        assertEq(removed, 3, "no more than the limit");
        assertTrue(due, "and more are due");
        assertEq(_renewed(votes), 9);

        (removed, due) = votes.sweepExpired(1_000);
        assertEq(removed, 5, "only the expired entries");
        assertFalse(due);
        assertEq(_renewed(votes), 4, "the later four have not expired");
        (uint64 head,,) = votes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(head, _k(9));

        (removed, due) = votes.sweepExpired(1_000);
        assertEq(removed, 0, "nothing more is due");
        (removed, due) = votes.sweepExpired(0);
        assertEq(removed, 0, "a zero limit removes nothing");
    }

    /// @dev Invariant: a proposal never opens on a count that includes expired keys. When more
    /// expired entries are queued than opening sweeps, it reverts and changes nothing; once
    /// anyone has swept the rest, it opens with the exact count.
    function test_aStaleCountIsRefusedWhenOpeningAProposal() public {
        uint256 count = votes.SWEEP_IN_PROPOSE() + 4;
        _buy(fleet, alice, count);
        _mature();
        uint256 k1 = _k(1);
        vm.prank(alice);
        votes.present(_range(k1, count));
        vm.warp(block.timestamp + WINDOW);

        vm.prank(alice);
        vm.expectRevert(KeyfleetVotes.MaintenanceRequired.selector);
        votes.propose(k1, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        assertEq(_renewed(votes), count, "the refused opening swept nothing");

        (uint256 removed, bool due) = votes.sweepExpired(5);
        assertEq(removed, 5);
        assertTrue(due);
        vm.prank(alice);
        uint256 proposalId = votes.propose(k1, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        assertEq(votes.proposal(proposalId).e0, 1, "an exact count: the proposer's key alone");
        assertEq(_renewed(votes), 1);
    }

    /// @dev Invariant: inside one block the order of renewals, transfers and openings decides who
    /// was present at an opening, with no block passing between them. Renew, transfer, then open:
    /// not present. Renew, open, then transfer: present, though no longer present now.
    function test_sameBlockRenewalTransferAndOpeningKeepTheirOrder() public {
        _buy(fleet, alice, 3);
        _mature();
        _lapse();
        uint256 k1 = _k(1);
        uint256 k2 = _k(2);
        uint256 k3 = _k(3);
        uint256 blockNumber = block.number;
        uint256 timestamp = block.timestamp;

        vm.startPrank(alice);
        votes.present(_ids(k2));
        keys.transferFrom(alice, bob, k2);
        uint256 first = votes.propose(k1, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        votes.present(_ids(k3));
        uint256 second = votes.propose(k1, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        keys.transferFrom(alice, bob, k3);
        vm.stopPrank();

        assertEq(block.number, blockNumber, "all in one block");
        assertEq(block.timestamp, timestamp);
        assertFalse(votes.wasActiveAtOpening(first, k2), "renewed, moved, then opened: not present");
        assertEq(votes.proposal(first).e0, 1, "the proposer's key alone");
        assertTrue(votes.wasActiveAtOpening(second, k3), "renewed, opened, then moved: present");
        assertEq(votes.proposal(second).e0, 2);
        assertFalse(votes.isActive(k3), "but not present now");
        assertEq(votes.presentFrom(k3), 0);
    }

    /// @dev Invariant: presence is measured in seconds, never in blocks. Many blocks in no time
    /// leave a key present; 48 hours in one block end it.
    function test_presenceIsMeasuredInSecondsNotBlocks() public {
        _buy(fleet, alice, 1);
        _mature();
        uint256 k1 = _k(1);
        vm.prank(alice);
        votes.present(_ids(k1));

        vm.roll(block.number + 10_000_000);
        assertTrue(votes.isActive(k1), "blocks without time change nothing");
        vm.warp(block.timestamp + WINDOW);
        assertFalse(votes.isActive(k1), "time without blocks ends it");
    }

    // --- token ids that need 64 bits ---------------------------------------

    /// @dev Invariant: the queue carries whole token ids. On the last fleet the collection numbers,
    /// whose token ids are above 2^63, every renewal, link, unlink, transfer, opening, ballot and
    /// sweep names the exact token id, so no two keys share an entry and none is lost.
    function test_presenceKeepsWholeTokenIdsOnTheLastFleet() public {
        _openCreation();
        uint256 lastFleet = keys.MAX_FLEETS();
        stdstore.target(address(keys)).sig(keys.fleetCount.selector).checked_write(lastFleet - 1);
        KeyfleetManager top = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10_000_000);
        KeyfleetVotes topVotes = top.VOTES();
        assertEq(top.FLEET_ID(), lastFleet, "the last fleet the collection numbers");
        _buy(top, alice, 3);
        _mature();

        uint256 t1 = keys.tokenIdOf(lastFleet, 1);
        uint256 t2 = t1 + 1;
        uint256 t3 = t1 + 2;
        uint256 t4 = t1 + 3;
        assertEq(keys.ownerOf(t1), creator);
        assertEq(keys.ownerOf(t4), alice);
        assertGe(t1, uint256(1) << 63, "the top bit of 64 is set");
        assertLt(t4, uint256(type(uint64).max), "and every id fits in 64 bits");

        vm.prank(creator);
        topVotes.present(_ids(t1));
        vm.prank(alice);
        topVotes.present(_range(t2, 3));
        (uint64 head, uint64 tail, uint32 queued) = topVotes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(head, t1);
        assertEq(tail, t4);
        assertEq(queued, 4);
        (, uint64 prev, uint64 next, uint64 expiresAt) = topVotes.presenceEntry(t2);
        assertEq(prev, t1);
        assertEq(next, t3);
        assertEq(expiresAt, block.timestamp + WINDOW);

        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        topVotes.present(_ids(t2));
        vm.prank(alice);
        keys.transferFrom(alice, bob, t3);
        (, prev, next,) = topVotes.presenceEntry(t1);
        assertEq(next, t4, "key 2 moved to the back and key 3 left: 1, 4, 2");
        (, prev, next,) = topVotes.presenceEntry(t4);
        assertEq(prev, t1);
        assertEq(next, t2);
        (head, tail, queued) = topVotes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(head, t1);
        assertEq(tail, t2);
        assertEq(queued, 3);
        assertFalse(topVotes.isActive(t3), "the moved key is not present");
        assertTrue(topVotes.isActive(t2));

        vm.prank(creator);
        uint256 proposalId = topVotes.propose(t1, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        assertEq(topVotes.proposal(proposalId).authorKey, t1, "the author key is stored whole");
        assertEq(topVotes.proposal(proposalId).e0, 3);
        assertTrue(topVotes.wasActiveAtOpening(proposalId, t4));
        assertFalse(topVotes.wasActiveAtOpening(proposalId, t3));
        vm.prank(bob);
        topVotes.castBallot(proposalId, _ids(t3), KeyfleetVotes.Choice.Yes);
        assertEq(topVotes.proposal(proposalId).late, 1, "the moved key joins late under its new owner");

        vm.warp(block.timestamp + WINDOW);
        (uint256 removed, bool due) = topVotes.sweepExpired(10);
        assertEq(removed, 4, "every entry swept by its whole id");
        assertFalse(due);
        (head, tail, queued) = topVotes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(head, 0);
        assertEq(tail, 0);
        assertEq(queued, 0);
    }

    // --- who may renew --------------------------------------------------

    /// @dev Invariant: only a key's owner or a wallet holding an active shard of it may renew it,
    /// whether or not the key's agent voting is on. A keeper, an approved operator or any stranger
    /// cannot, a batch with one such key renews none, and an empty batch is refused.
    function test_aKeeperCannotMarkSomeoneElsePresent() public {
        _buy(fleet, alice, 2);
        _buy(fleet, mallory, 1);
        _mature();
        uint256 k1 = _k(1);

        vm.prank(alice);
        keys.setApprovalForAll(mallory, true);
        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.present(_ids(k1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.present(_range(k1, 3));
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.present(new uint256[](0));
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, keeper));
        votes.present(_ids(k1));
        assertEq(_renewed(votes), 0, "nothing was renewed");

        vm.startPrank(alice);
        shards.issue(_range(k1, 2), bob, 30);
        shards.setAgentVoting(_range(k1, 2), false);
        vm.stopPrank();
        vm.prank(bob);
        votes.present(_range(k1, 2));
        assertTrue(votes.isActive(k1) && votes.isActive(_k(2)), "the key's agent may, with agent voting off");
    }

    /// @dev Invariant: only the fleet's own manager reports a key changing hands. A stranger, the
    /// shared collection, the fleet's own treasury and another fleet's manager cannot end a key's
    /// presence; the manager can.
    function test_onlyTheManagerReportsAKeyMoving() public {
        _buy(fleet, alice, 1);
        _mature();
        uint256 k1 = _k(1);
        vm.prank(alice);
        votes.present(_ids(k1));
        KeyfleetManager other = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        address[4] memory strangers = [mallory, address(keys), address(fleet.TREASURY()), address(other)];

        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(KeyfleetVotes.OnlyManager.selector);
            votes.onKeyMoved(k1);
        }
        assertTrue(votes.isActive(k1), "still present");
        assertEq(_renewed(votes), 1);

        vm.expectEmit(true, true, true, true, address(votes));
        emit PresenceCleared(k1);
        vm.prank(address(fleet));
        votes.onKeyMoved(k1);
        assertFalse(votes.isActive(k1), "the manager ends it");
        assertEq(_renewed(votes), 0);
    }

    /// @dev Invariant: a sale only schedules its key's automatic start, a transfer ends the key's
    /// presence at once and takes it off its list, and the new owner renews it under the new
    /// ownership epoch.
    function test_aTransferEndsPresenceAndTheNewOwnerRenewsIt() public {
        _buy(fleet, alice, 2);
        _mature();
        uint256 k1 = _k(1);
        assertEq(votes.presenceRevision(), 2, "each sale schedules one automatic start");

        vm.prank(alice);
        votes.present(_range(k1, 2));
        vm.expectEmit(true, true, true, true, address(votes));
        emit PresenceCleared(k1);
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        assertFalse(votes.isActive(k1), "not present after it changed hands");
        assertEq(_renewed(votes), 1, "and off the list");
        (uint64 head,,) = votes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(head, _k(2));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, alice));
        votes.present(_ids(k1));

        vm.expectEmit(true, true, true, true, address(votes));
        emit Present(k1, uint64(block.timestamp), uint64(block.number), 2);
        vm.prank(bob);
        votes.present(_ids(k1));
        assertTrue(votes.isActive(k1));

        vm.prank(bob);
        keys.transferFrom(bob, alice, k1);
        assertFalse(votes.isActive(k1), "a transfer of a key nobody renewed since is harmless too");
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        assertEq(_renewed(votes), 1);
    }

    /// @dev Invariant: voting and proposing renew the keys they name, as renewing does.
    function test_votingAndProposingRenewTheirKeys() public {
        _buy(fleet, alice, 3);
        _mature();
        _lapse();

        vm.prank(alice);
        uint256 proposalId = votes.propose(_k(1), bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        assertTrue(votes.isActive(_k(1)), "the proposer's key");
        assertFalse(votes.isActive(_k(2)));
        vm.prank(alice);
        votes.castBallot(proposalId, _range(_k(2), 2), KeyfleetVotes.Choice.Yes);
        assertTrue(votes.isActive(_k(2)), "each voted key");
        assertTrue(votes.isActive(_k(3)));
        assertEq(_renewed(votes), 3);
    }
}

/// @dev Presence gas, measured in a transaction of its own after the fleet, its keys and their
/// renewals were set up in earlier ones, with every account cold, so no slot is cheaper for having
/// been written earlier in the same transaction.
contract KeyfleetPresenceGasTest is KeyfleetFixture {
    uint64 private constant WINDOW = 172_800;
    /// @dev Measured cost of a key's first renewal, plus a fifth, rounded up.
    uint256 private constant FIRST_RENEWAL_CEILING = 111_000;
    /// @dev Measured cost of renewing a key already queued, plus a fifth, rounded up.
    uint256 private constant LATER_RENEWAL_CEILING = 85_000;
    /// @dev Measured marginal cost of sweeping one expired entry, plus a fifth, rounded up.
    uint256 private constant SWEEP_PER_ENTRY_CEILING = 6_000;
    /// @dev Measured cost of moving one started key from waiting to automatic in a sweep (26,130),
    /// plus a fifth, rounded up.
    uint256 private constant SWEEP_PER_START_CEILING = 32_000;
    /// @dev Measured cost of transferring a present key, plus a fifth, rounded up.
    uint256 private constant PRESENT_TRANSFER_CEILING = 144_000;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    KeyfleetManager private fleet;
    KeyfleetVotes private votes;

    function setUp() public {
        vm.warp(1_000_000);
        _setUpFixture();
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();
        for (uint256 i = 0; i < 41; ++i) {
            _buy(fleet, alice);
        }
        _mature();
        uint256[] memory renewed = _range(_key(fleet, 1), 40);
        vm.prank(alice);
        votes.present(renewed);
    }

    function _cool() private {
        vm.cool(address(votes));
        vm.cool(address(keys));
        vm.cool(address(fleet));
        vm.cool(address(fleet.REWARDS()));
        vm.cool(address(shards));
        vm.cool(bob);
    }

    /// @dev Invariant: a key's first renewal writes one queue entry and one checkpoint, whatever
    /// the fleet's size.
    function test_aFirstRenewalCostsAFixedAmount() public {
        uint256[] memory tokenIds = _ids(_key(fleet, 41));
        _cool();
        vm.prank(alice);
        uint256 before = gasleft();
        votes.present(tokenIds);
        uint256 used = before - gasleft();
        console2.log("first renewal gas:", used);
        assertLt(used, FIRST_RENEWAL_CEILING);
    }

    /// @dev Invariant: renewing a queued key moves its entry to the back and adds a checkpoint.
    function test_aLaterRenewalCostsAFixedAmount() public {
        uint256[] memory tokenIds = _ids(_key(fleet, 20));
        vm.warp(block.timestamp + 1);
        _cool();
        vm.prank(alice);
        uint256 before = gasleft();
        votes.present(tokenIds);
        uint256 used = before - gasleft();
        console2.log("later renewal gas:", used);
        assertLt(used, LATER_RENEWAL_CEILING);
    }

    /// @dev Invariant: sweeping costs a fixed amount per expired entry.
    function test_sweepingCostsAFixedAmountPerEntry() public {
        vm.warp(block.timestamp + WINDOW);
        // The one key never renewed, whose automatic presence ended too, leaves its own list first.
        votes.sweepExpired(1);
        _cool();
        uint256 before = gasleft();
        votes.sweepExpired(10);
        uint256 ten = before - gasleft();
        _cool();
        before = gasleft();
        votes.sweepExpired(30);
        uint256 thirty = before - gasleft();
        uint256 perEntry = (thirty - ten) / 20;
        console2.log("sweep gas per expired entry:", perEntry);
        assertLt(perEntry, SWEEP_PER_ENTRY_CEILING);
    }

    /// @dev Invariant: sweeping costs a fixed amount per key whose automatic start has come.
    function test_sweepingStartedKeysCostsAFixedAmountPerKey() public {
        for (uint256 i = 0; i < 41; ++i) {
            _buy(fleet, bob);
        }
        vm.warp(block.timestamp + votes.KEY_MATURITY());
        // Key 41, whose automatic presence has ended, leaves the waiting list first.
        votes.sweepExpired(1);
        _cool();
        uint256 before = gasleft();
        votes.sweepExpired(10);
        uint256 ten = before - gasleft();
        _cool();
        before = gasleft();
        votes.sweepExpired(30);
        uint256 thirty = before - gasleft();
        (,, uint32 automatic) = votes.presenceList(KeyfleetPresence.Place.Automatic);
        assertEq(automatic, 40, "forty of the new keys started");
        uint256 perKey = (thirty - ten) / 20;
        console2.log("sweep gas per started key:", perKey);
        assertLt(perKey, SWEEP_PER_START_CEILING);
    }

    /// @dev Invariant: transferring a present key pays a fixed amount on top of the transfer to end
    /// its presence, whether it came from a renewal or from its automatic start.
    function test_transferringAPresentKeyCostsAFixedAmount() public {
        uint256 present = _key(fleet, 20);
        uint256 automatic = _key(fleet, 41);
        _cool();
        vm.prank(alice);
        uint256 before = gasleft();
        keys.transferFrom(alice, bob, present);
        uint256 presentGas = before - gasleft();
        _cool();
        vm.prank(alice);
        before = gasleft();
        keys.transferFrom(alice, bob, automatic);
        uint256 automaticGas = before - gasleft();
        console2.log("transfer of a renewed key gas:", presentGas);
        console2.log("transfer of a key present from its automatic start gas:", automaticGas);
        assertLt(presentGas, PRESENT_TRANSFER_CEILING);
        assertLt(automaticGas, PRESENT_TRANSFER_CEILING);
    }
}
