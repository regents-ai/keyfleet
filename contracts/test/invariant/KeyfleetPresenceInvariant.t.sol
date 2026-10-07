// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresence} from "../../src/KeyfleetPresence.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// @dev Drives sales, renewals, transfers, sweeps, proposal openings and the passing of time over a
/// small fleet, as its buyers and keys' owners would. A renewal of a key minted less than
/// `KEY_MATURITY` ago must be refused with `KeyTooNew`.
contract PresenceHandler is Test {
    uint256 internal constant KEYS = 8;

    KeyfleetManager internal immutable fleet;
    KeyfleetKeys internal immutable keys;
    KeyfleetVotes internal immutable votes;
    MockToken internal immutable usdc;
    address[3] internal holders = [address(0xA1), address(0xA2), address(0xA3)];

    constructor(KeyfleetManager fleet_, MockToken usdc_) {
        fleet = fleet_;
        keys = fleet_.KEYS();
        votes = fleet_.VOTES();
        usdc = usdc_;
    }

    /// @dev One of the keys sold so far.
    function _key(uint256 seed) private view returns (uint256) {
        return keys.tokenIdOf(fleet.FLEET_ID(), bound(seed, 1, fleet.totalMinted()));
    }

    function buy(uint256 to) external {
        if (fleet.totalMinted() == KEYS) return;
        uint256 price = fleet.nextPrice();
        usdc.mint(address(this), price);
        usdc.approve(address(fleet), price);
        fleet.purchase(holders[to % holders.length], price, block.timestamp, new bytes32[](0));
    }

    function present(uint256 seed) external {
        uint256 tokenId = _key(seed);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        address owner = keys.ownerOf(tokenId);
        uint64 maturesAt = keys.mintedAt(tokenId) + votes.KEY_MATURITY();
        if (block.timestamp < maturesAt) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyTooNew.selector, tokenId, maturesAt));
        }
        vm.prank(owner);
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
        try votes.propose(tokenId, bytes32(0), new KeyfleetTreasury.Call[](0)) {} catch {}
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
    }
}

/// @dev The presence lists' invariants (plan §4.1). Each list is ordered by the time its entries
/// fall due and its count is the number of its linked entries; no key is listed twice; only the
/// fleet's own sold keys are listed; a waiting key falls due exactly `KEY_MATURITY` after its mint,
/// and a key present from its automatic start falls due `PRESENCE_WINDOW` after that; every key in
/// `automatic` or `renewed` is mature; the entries of `automatic` and `renewed` that have not fallen
/// due, plus the waiting entries whose start has come, are exactly the present keys; and a key with
/// no record is neither present nor listed. The fleet is the founding Classic fleet on the shared
/// collection, so every listed id is a full token id of that fleet.
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
        _buy(fleet, address(0xA1));
        _buy(fleet, address(0xA2));

        handler = new PresenceHandler(fleet, usdc);
        targetContract(address(handler));
    }

    /// @dev Walks one list from head to tail, checking the links, the order and what each entry
    /// says on the way. `listed` is indexed by key number and shared by all three walks.
    /// @return count How many entries the list links.
    /// @return present How many of them are present now.
    function _walk(KeyfleetPresence.Place place, bool[KEYS + 1] memory listed)
        private
        view
        returns (uint256 count, uint256 present)
    {
        (uint64 head, uint64 tail, uint32 counted) = votes.presenceList(place);
        uint64 prev;
        uint64 lastDue;
        for (uint64 id = head; id != 0;) {
            uint256 keyNumber = keys.keyNumberOf(id);
            assertFalse(listed[keyNumber], "no key is listed twice");
            listed[keyNumber] = true;
            ++count;
            (uint64 next, uint64 dueAt, bool isPresent) = _checkEntry(place, id, prev, lastDue);
            if (isPresent) ++present;
            lastDue = dueAt;
            prev = id;
            id = next;
        }
        assertEq(prev, tail, "the walk ends at the tail");
        assertEq(count, counted, "a list's count is the number of its linked entries");
    }

    /// @dev Checks one listed entry: whose key it is, its list, its link back, its order and its
    /// due time.
    function _checkEntry(KeyfleetPresence.Place place, uint64 id, uint64 prev, uint64 lastDue)
        private
        view
        returns (uint64 next, uint64 dueAt, bool isPresent)
    {
        assertEq(keys.fleetOf(id), fleet.FLEET_ID(), "only the fleet's own keys are listed");
        uint256 keyNumber = keys.keyNumberOf(id);
        assertGe(keyNumber, 1, "only real keys are listed");
        assertLe(keyNumber, fleet.totalMinted(), "only sold keys are listed");

        KeyfleetPresence.Place at;
        uint64 back;
        (at, back, next, dueAt) = votes.presenceEntry(id);
        assertEq(uint8(at), uint8(place), "an entry knows its list");
        assertEq(back, prev, "each entry links back to the one before it");
        assertGe(dueAt, lastDue, "due times never go down from head to tail");
        uint64 startsAt = keys.mintedAt(id) + votes.KEY_MATURITY();
        if (place == KeyfleetPresence.Place.Waiting) {
            assertEq(dueAt, startsAt, "a waiting key falls due at its automatic start");
            return (next, dueAt, dueAt <= block.timestamp && block.timestamp < dueAt + votes.PRESENCE_WINDOW());
        }
        assertGe(block.timestamp, startsAt, "every key present or once present is mature");
        if (place == KeyfleetPresence.Place.Automatic) {
            assertEq(dueAt, startsAt + votes.PRESENCE_WINDOW(), "an automatic presence lasts one window");
        }
        isPresent = dueAt > block.timestamp;
    }

    function _walkAll() private view returns (bool[KEYS + 1] memory listed, uint256 present) {
        (, uint256 waiting) = _walk(KeyfleetPresence.Place.Waiting, listed);
        (, uint256 automatic) = _walk(KeyfleetPresence.Place.Automatic, listed);
        (, uint256 renewed) = _walk(KeyfleetPresence.Place.Renewed, listed);
        present = waiting + automatic + renewed;
    }

    function invariant_theListsAreOrderedAndCountedExactly() public view {
        (bool[KEYS + 1] memory listed,) = _walkAll();
        for (uint256 k = 1; k <= fleet.totalMinted(); ++k) {
            (KeyfleetPresence.Place place,,, uint64 dueAt) = votes.presenceEntry(_key(fleet, k));
            assertEq(listed[k], place != KeyfleetPresence.Place.None, "a key is linked exactly when it has a list");
            assertEq(listed[k], dueAt != 0, "a key is linked exactly when it has a due time");
        }
    }

    function invariant_theListedPresencesAreExactlyThePresentKeys() public view {
        (bool[KEYS + 1] memory listed, uint256 listedPresent) = _walkAll();
        uint256 present;
        for (uint256 k = 1; k <= fleet.totalMinted(); ++k) {
            if (!votes.isActive(_key(fleet, k))) continue;
            ++present;
            assertTrue(listed[k], "a present key is listed");
        }
        assertEq(listedPresent, present, "the listed presences that have not ended are the present keys");
    }

    function invariant_aKeyWithNoRecordIsNotPresent() public view {
        for (uint256 k = 1; k <= fleet.totalMinted(); ++k) {
            uint256 tokenId = _key(fleet, k);
            if (votes.presentFrom(tokenId) != 0) continue;
            assertFalse(votes.isActive(tokenId), "no record, not present");
            (KeyfleetPresence.Place place,,,) = votes.presenceEntry(tokenId);
            assertEq(uint8(place), uint8(KeyfleetPresence.Place.None), "and not listed");
        }
    }

    function invariant_aKeyNeverMovedAfterItsStartIsPresentThroughItsFirstWindow() public view {
        for (uint256 k = 1; k <= fleet.totalMinted(); ++k) {
            uint256 tokenId = _key(fleet, k);
            uint64 startsAt = keys.mintedAt(tokenId) + votes.KEY_MATURITY();
            if (block.timestamp < startsAt || block.timestamp >= startsAt + votes.PRESENCE_WINDOW()) continue;
            if (votes.presentFrom(tokenId) == 0) continue; // it changed hands after its start
            assertTrue(votes.isActive(tokenId), "present from its automatic start without renewing");
        }
    }
}
