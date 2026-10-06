// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetStack} from "../../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "../KeyfleetIncome.t.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Drives renewals, transfers, sweeps, proposal openings and the passing of time over a small
/// fleet, as the keys' owners would.
contract PresenceHandler is Test {
    uint256 internal constant KEYS = 8;

    Keyfleet internal immutable fleet;
    KeyfleetVotes internal immutable votes;
    address[3] internal holders = [address(0xA1), address(0xA2), address(0xA3)];

    constructor(Keyfleet fleet_) {
        fleet = fleet_;
        votes = fleet_.VOTES();
    }

    function _key(uint256 seed) private pure returns (uint256) {
        return bound(seed, 1, KEYS);
    }

    function present(uint256 seed) external {
        uint256 tokenId = _key(seed);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.prank(fleet.ownerOf(tokenId));
        votes.present(ids);
    }

    function transfer(uint256 seed, uint256 to) external {
        uint256 tokenId = _key(seed);
        address from = fleet.ownerOf(tokenId);
        vm.prank(from);
        fleet.transferFrom(from, holders[to % holders.length], tokenId);
    }

    function sweep(uint256 limit) external {
        votes.sweepExpired(bound(limit, 0, KEYS));
    }

    function propose(uint256 seed) external {
        uint256 tokenId = _key(seed);
        vm.prank(fleet.ownerOf(tokenId));
        try votes.proposeDecision(tokenId, "", bytes32(0)) {} catch {}
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }
}

/// @dev The presence queue's invariants (plan §4.1): it is ordered by expiry, `queued` is the
/// number of linked entries, no key is queued twice, the entries that have not expired are exactly
/// the present keys, and a key with no record is not present.
/// forge-config: default.invariant.runs = 64
contract KeyfleetPresenceInvariantTest is Test {
    uint256 private constant KEYS = 8;

    Keyfleet private fleet;
    KeyfleetVotes private votes;
    PresenceHandler private handler;

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
        for (uint256 i = 0; i < KEYS; ++i) {
            uint256 price = fleet.nextPrice();
            usdc.mint(buyer, price);
            vm.startPrank(buyer);
            usdc.approve(address(fleet), price);
            fleet.purchase(address(uint160(0xA1 + (i % 3))), price, block.timestamp);
            vm.stopPrank();
        }

        handler = new PresenceHandler(fleet);
        targetContract(address(handler));
    }

    /// @dev Walks the queue from head to tail, checking the links and the order on the way.
    function _walk() private view returns (bool[KEYS + 1] memory linked, uint256 count, uint256 unexpired) {
        (uint32 head, uint32 tail,) = votes.presenceQueue();
        uint32 prev;
        uint64 lastExpiry;
        for (uint32 id = head; id != 0;) {
            assertLe(id, KEYS, "only real keys are queued");
            assertFalse(linked[id], "no key is queued twice");
            linked[id] = true;
            ++count;
            (uint32 back, uint32 next, uint64 expiresAt) = votes.presenceEntry(id);
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
        for (uint256 tokenId = 1; tokenId <= KEYS; ++tokenId) {
            (,, uint64 expiresAt) = votes.presenceEntry(tokenId);
            assertEq(linked[tokenId], expiresAt != 0, "a key is linked exactly when it has an expiry");
        }
    }

    function invariant_theUnexpiredEntriesAreExactlyThePresentKeys() public view {
        (bool[KEYS + 1] memory linked,, uint256 unexpired) = _walk();
        uint256 present;
        for (uint256 tokenId = 1; tokenId <= KEYS; ++tokenId) {
            if (!votes.isActive(tokenId)) continue;
            ++present;
            assertTrue(linked[tokenId], "a present key is queued");
        }
        assertEq(unexpired, present, "queued minus due is the count of present keys");
    }

    function invariant_aKeyWithNoRecordIsNotPresent() public view {
        for (uint256 tokenId = 1; tokenId <= KEYS; ++tokenId) {
            if (votes.lastActiveAt(tokenId) != 0) continue;
            assertFalse(votes.isActive(tokenId), "no record, not present");
            (,, uint64 expiresAt) = votes.presenceEntry(tokenId);
            assertEq(expiresAt, 0, "and not queued");
        }
    }
}
