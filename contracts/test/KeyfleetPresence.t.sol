// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Presence: a key is present for 48 hours after it is renewed under its current owner,
/// stops being present when it changes hands, and a proposal opens only on an exact count.
contract KeyfleetPresenceTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";
    uint64 private constant WINDOW = 172_800;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private mallory = address(0x4A11);

    event Present(uint256 indexed tokenId, uint64 at, uint64 blockNumber, uint64 epoch);
    event PresenceCleared(uint256 indexed tokenId);
    event Swept(uint256 removed, bool due);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);
        vm.roll(1_000);
    }

    function _deploy() private returns (Keyfleet fleet) {
        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            new MockRegentRevenueStaking(usdc),
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    /// @dev Buys `count` Classic keys for `receiver`.
    function _buy(Keyfleet fleet, address receiver, uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            uint256 price = fleet.nextPrice();
            usdc.mint(buyer, price);
            vm.startPrank(buyer);
            usdc.approve(address(fleet), price);
            fleet.purchase(receiver, price, block.timestamp);
            vm.stopPrank();
        }
    }

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _range(uint256 first, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    function _queued(KeyfleetVotes votes) private view returns (uint32 queued) {
        (,, queued) = votes.presenceQueue();
    }

    // --- the window -----------------------------------------------------

    /// @dev Invariant: a renewal keeps a key present for exactly 48 hours: one second before the
    /// end it is present, at the end it is not.
    function test_aKeyIsPresentForExactlyFortyEightHours() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 1);
        assertFalse(votes.isActive(1), "a key nobody renewed is not present");
        assertEq(votes.lastActiveAt(1), 0);

        uint256 t = block.timestamp;
        vm.expectEmit(true, true, true, true, address(votes));
        emit Present(1, uint64(t), uint64(block.number), 1);
        vm.prank(alice);
        votes.present(_ids(1));
        assertEq(votes.lastActiveAt(1), t);
        (,, uint64 expiresAt) = votes.presenceEntry(1);
        assertEq(expiresAt, t + WINDOW, "queued to expire 48 hours on");

        vm.warp(t + WINDOW - 1);
        assertTrue(votes.isActive(1), "present one second before the end");
        vm.warp(t + WINDOW);
        assertFalse(votes.isActive(1), "not present at the end");
    }

    /// @dev Invariant: after three days without a transaction no key is present, the stale entries
    /// stay queued until something sweeps them, and the next proposal sweeps them and counts only
    /// its proposer's key.
    function test_afterThreeDaysWithoutTransactionsNoKeyIsPresent() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 3);
        vm.prank(alice);
        votes.present(_range(1, 3));

        vm.warp(block.timestamp + 3 days);
        for (uint256 tokenId = 1; tokenId <= 3; ++tokenId) {
            assertFalse(votes.isActive(tokenId), "no key is present");
        }
        assertEq(_queued(votes), 3, "time alone removes nothing from the queue");

        vm.prank(alice);
        uint256 proposalId =
            votes.propose(2, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        assertEq(votes.proposal(proposalId).e0, 1, "only the proposer's key counts");
        assertEq(_queued(votes), 1);
        assertTrue(votes.wasActiveAtOpening(proposalId, 2));
        assertFalse(votes.wasActiveAtOpening(proposalId, 1));
    }

    /// @dev Invariant: when every key is dormant anyone holding a key can still renew it and open a
    /// proposal; the fleet never needs a present key to wake up.
    function test_aKeyMayBeRenewedAndProposeWhenEveryKeyIsDormant() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 2);
        _buy(fleet, bob, 1);
        assertEq(_queued(votes), 0, "nothing is present");

        vm.prank(bob);
        votes.present(_ids(3));
        assertTrue(votes.isActive(3));

        vm.warp(block.timestamp + WINDOW);
        assertEq(_queued(votes), 1, "an expired entry");
        vm.prank(alice);
        uint256 proposalId =
            votes.propose(1, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        assertEq(votes.proposal(proposalId).e0, 1);
    }

    /// @dev Invariant: renewing a key whose entry expired but was never swept moves that one entry
    /// to the back with a new expiry; the key is never queued twice.
    function test_renewingAnUnsweptExpiredEntryRequeuesItOnce() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 2);
        vm.prank(alice);
        votes.present(_range(1, 2));

        vm.warp(block.timestamp + WINDOW + 10);
        assertFalse(votes.isActive(1));
        vm.prank(alice);
        votes.present(_ids(1));

        (uint32 head, uint32 tail, uint32 queued) = votes.presenceQueue();
        assertEq(queued, 2, "still one entry per key");
        assertEq(head, 2, "the expired key 2 is at the front");
        assertEq(tail, 1, "the renewed key 1 is at the back");
        (uint32 prev, uint32 next, uint64 expiresAt) = votes.presenceEntry(1);
        assertEq(prev, 2);
        assertEq(next, 0);
        assertEq(expiresAt, block.timestamp + WINDOW);
        assertTrue(votes.isActive(1));

        (uint256 removed, bool due) = votes.sweepExpired(10);
        assertEq(removed, 1, "only key 2 was due");
        assertFalse(due);
        (head, tail, queued) = votes.presenceQueue();
        assertEq(head, 1);
        assertEq(tail, 1);
        assertEq(queued, 1);
    }

    // --- sweeping and opening -------------------------------------------

    /// @dev Invariant: a sweep removes at most `limit` expired entries, says whether more are due,
    /// and never removes an entry that has not expired.
    function test_sweepingIsBoundedByItsLimit() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 12);
        vm.prank(alice);
        votes.present(_range(1, 8));
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        votes.present(_range(9, 4));
        vm.warp(block.timestamp + WINDOW - 1);

        vm.expectEmit(true, true, true, true, address(votes));
        emit Swept(3, true);
        (uint256 removed, bool due) = votes.sweepExpired(3);
        assertEq(removed, 3, "no more than the limit");
        assertTrue(due, "and more are due");
        assertEq(_queued(votes), 9);

        (removed, due) = votes.sweepExpired(1_000);
        assertEq(removed, 5, "only the expired entries");
        assertFalse(due);
        assertEq(_queued(votes), 4, "the later four have not expired");
        (uint32 head,,) = votes.presenceQueue();
        assertEq(head, 9);

        (removed, due) = votes.sweepExpired(1_000);
        assertEq(removed, 0, "nothing more is due");
        (removed, due) = votes.sweepExpired(0);
        assertEq(removed, 0, "a zero limit removes nothing");
    }

    /// @dev Invariant: a proposal never opens on a count that includes expired keys. When more
    /// expired entries are queued than opening sweeps, it reverts and changes nothing; once
    /// anyone has swept the rest, it opens with the exact count.
    function test_aStaleCountIsRefusedWhenOpeningAProposal() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        uint256 keys = votes.SWEEP_IN_PROPOSE() + 4;
        _buy(fleet, alice, keys);
        vm.prank(alice);
        votes.present(_range(1, keys));
        vm.warp(block.timestamp + WINDOW);

        vm.prank(alice);
        vm.expectRevert(KeyfleetVotes.MaintenanceRequired.selector);
        votes.propose(1, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        assertEq(_queued(votes), keys, "the refused opening swept nothing");

        (uint256 removed, bool due) = votes.sweepExpired(5);
        assertEq(removed, 5);
        assertTrue(due);
        vm.prank(alice);
        uint256 proposalId =
            votes.propose(1, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        assertEq(votes.proposal(proposalId).e0, 1, "an exact count: the proposer's key alone");
        assertEq(_queued(votes), 1);
    }

    /// @dev Invariant: inside one block the order of renewals, transfers and openings decides who
    /// was present at an opening, with no block passing between them. Renew, transfer, then open:
    /// not present. Renew, open, then transfer: present, though no longer present now.
    function test_sameBlockRenewalTransferAndOpeningKeepTheirOrder() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 3);
        uint256 blockNumber = block.number;
        uint256 timestamp = block.timestamp;

        vm.startPrank(alice);
        votes.present(_ids(2));
        fleet.transferFrom(alice, bob, 2);
        uint256 first = votes.propose(1, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        votes.present(_ids(3));
        uint256 second = votes.propose(1, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        fleet.transferFrom(alice, bob, 3);
        vm.stopPrank();

        assertEq(block.number, blockNumber, "all in one block");
        assertEq(block.timestamp, timestamp);
        assertFalse(votes.wasActiveAtOpening(first, 2), "renewed, moved, then opened: not present");
        assertEq(votes.proposal(first).e0, 1, "the proposer's key alone");
        assertTrue(votes.wasActiveAtOpening(second, 3), "renewed, opened, then moved: present");
        assertEq(votes.proposal(second).e0, 2);
        assertFalse(votes.isActive(3), "but not present now");
        assertEq(votes.lastActiveAt(3), 0);
    }

    /// @dev Invariant: presence is measured in seconds, never in blocks. Many blocks in no time
    /// leave a key present; 48 hours in one block end it.
    function test_presenceIsMeasuredInSecondsNotBlocks() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 1);
        vm.prank(alice);
        votes.present(_ids(1));

        vm.roll(block.number + 10_000_000);
        assertTrue(votes.isActive(1), "blocks without time change nothing");
        vm.warp(block.timestamp + WINDOW);
        assertFalse(votes.isActive(1), "time without blocks ends it");
    }

    // --- who may renew --------------------------------------------------

    /// @dev Invariant: only a key's owner or a wallet holding an active shard of it may renew it,
    /// whether or not the key's agent voting is on. A keeper, an approved operator or any stranger
    /// cannot, a batch with one such key renews none, and an empty batch is refused.
    function test_aKeeperCannotMarkSomeoneElsePresent() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 2);
        _buy(fleet, mallory, 1);

        vm.prank(alice);
        fleet.setApprovalForAll(mallory, true);
        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.present(_ids(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.present(_range(1, 3));
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.present(new uint256[](0));
        vm.stopPrank();
        assertEq(_queued(votes), 0, "nothing was renewed");

        vm.startPrank(alice);
        fleet.SHARDS().issue(_range(1, 2), bob, 30);
        fleet.SHARDS().setAgentVoting(_range(1, 2), false);
        vm.stopPrank();
        vm.prank(bob);
        votes.present(_range(1, 2));
        assertTrue(votes.isActive(1) && votes.isActive(2), "the key's agent may, with agent voting off");
    }

    /// @dev Invariant: only the fleet reports a key changing hands; nobody else can end a key's
    /// presence.
    function test_onlyTheFleetReportsAKeyMoving() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 1);
        vm.prank(alice);
        votes.present(_ids(1));

        vm.prank(mallory);
        vm.expectRevert(KeyfleetVotes.OnlyFleet.selector);
        votes.onKeyMoved(1);
        assertTrue(votes.isActive(1));
    }

    /// @dev Invariant: a sale writes no presence, a transfer ends the key's presence at once and
    /// takes it out of the queue, and the new owner renews it under the new ownership epoch.
    function test_aTransferEndsPresenceAndTheNewOwnerRenewsIt() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 2);
        uint48 revision = votes.presenceRevision();
        assertEq(revision, 0, "a sale writes no presence");

        vm.prank(alice);
        votes.present(_range(1, 2));
        vm.expectEmit(true, true, true, true, address(votes));
        emit PresenceCleared(1);
        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);
        assertFalse(votes.isActive(1), "not present after it changed hands");
        assertEq(_queued(votes), 1, "and out of the queue");
        (uint32 head,,) = votes.presenceQueue();
        assertEq(head, 2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, alice));
        votes.present(_ids(1));

        vm.expectEmit(true, true, true, true, address(votes));
        emit Present(1, uint64(block.timestamp), uint64(block.number), 2);
        vm.prank(bob);
        votes.present(_ids(1));
        assertTrue(votes.isActive(1));

        vm.prank(bob);
        fleet.transferFrom(bob, alice, 1);
        assertFalse(votes.isActive(1), "a transfer of a key nobody renewed since is harmless too");
        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);
        assertEq(_queued(votes), 1);
    }

    /// @dev Invariant: voting and proposing renew the keys they name, as renewing does.
    function test_votingAndProposingRenewTheirKeys() public {
        Keyfleet fleet = _deploy();
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, alice, 3);

        vm.prank(alice);
        uint256 proposalId =
            votes.propose(1, bytes32(0), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
        assertTrue(votes.isActive(1), "the proposer's key");
        assertFalse(votes.isActive(2));
        vm.prank(alice);
        votes.castBallot(proposalId, _range(2, 2), KeyfleetVotes.Choice.Yes);
        assertTrue(votes.isActive(2), "each voted key");
        assertTrue(votes.isActive(3));
        assertEq(_queued(votes), 3);
    }
}

/// @dev Presence gas, measured in a transaction of its own after the fleet, its keys and their
/// renewals were set up in earlier ones, with every account cold, so no slot is cheaper for having
/// been written earlier in the same transaction.
contract KeyfleetPresenceGasTest is Test {
    uint64 private constant WINDOW = 172_800;
    /// @dev Measured cost of a key's first renewal, plus a fifth, rounded up.
    uint256 private constant FIRST_RENEWAL_CEILING = 110_000;
    /// @dev Measured cost of renewing a key already queued, plus a fifth, rounded up.
    uint256 private constant LATER_RENEWAL_CEILING = 84_000;
    /// @dev Measured marginal cost of sweeping one expired entry, plus a fifth, rounded up.
    uint256 private constant SWEEP_PER_ENTRY_CEILING = 6_000;
    /// @dev Measured cost of transferring a present key, plus a fifth, rounded up.
    uint256 private constant PRESENT_TRANSFER_CEILING = 137_000;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    Keyfleet private fleet;
    KeyfleetVotes private votes;

    function setUp() public {
        vm.warp(1_000_000);
        MockToken usdc = new MockToken("USD Coin", "USDC");
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        uint256 subscription = vrf.createSubscription();
        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            new MockRegentRevenueStaking(usdc),
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", "https://keys.regents.sh/alpha/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: subscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(subscription, address(fleet));
        votes = fleet.VOTES();

        address buyer = address(0xB0B0B0);
        for (uint256 i = 0; i < 41; ++i) {
            uint256 price = fleet.nextPrice();
            usdc.mint(buyer, price);
            vm.startPrank(buyer);
            usdc.approve(address(fleet), price);
            fleet.purchase(alice, price, block.timestamp);
            vm.stopPrank();
        }
        uint256[] memory ids = new uint256[](40);
        for (uint256 i = 0; i < 40; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        votes.present(ids);
    }

    function _cool() private {
        vm.cool(address(votes));
        vm.cool(address(fleet));
        vm.cool(address(fleet.REWARDS()));
        vm.cool(bob);
    }

    function _one(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    /// @dev Invariant: a key's first renewal writes one queue entry and one checkpoint, whatever
    /// the fleet's size.
    function test_aFirstRenewalCostsAFixedAmount() public {
        _cool();
        vm.prank(alice);
        uint256 before = gasleft();
        votes.present(_one(41));
        uint256 used = before - gasleft();
        console2.log("first renewal gas:", used);
        assertLt(used, FIRST_RENEWAL_CEILING);
    }

    /// @dev Invariant: renewing a queued key moves its entry to the back and adds a checkpoint.
    function test_aLaterRenewalCostsAFixedAmount() public {
        vm.warp(block.timestamp + 1);
        _cool();
        vm.prank(alice);
        uint256 before = gasleft();
        votes.present(_one(20));
        uint256 used = before - gasleft();
        console2.log("later renewal gas:", used);
        assertLt(used, LATER_RENEWAL_CEILING);
    }

    /// @dev Invariant: sweeping costs a fixed amount per expired entry.
    function test_sweepingCostsAFixedAmountPerEntry() public {
        vm.warp(block.timestamp + WINDOW);
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

    /// @dev Invariant: transferring a present key pays a fixed amount on top of the transfer to end
    /// its presence.
    function test_transferringAPresentKeyCostsAFixedAmount() public {
        _cool();
        vm.prank(alice);
        uint256 before = gasleft();
        fleet.transferFrom(alice, bob, 20);
        uint256 present = before - gasleft();
        _cool();
        vm.prank(alice);
        before = gasleft();
        fleet.transferFrom(alice, bob, 41);
        uint256 absent = before - gasleft();
        console2.log("transfer of a present key gas:", present);
        console2.log("transfer of a key never renewed gas:", absent);
        assertLt(present, PRESENT_TRANSFER_CEILING);
    }
}
