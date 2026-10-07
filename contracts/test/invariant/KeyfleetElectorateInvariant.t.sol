// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// @dev Drives proposals, ballots, transfers, renewals, sweeps, sales and the passing of time over a
/// small fleet, as the keys' owners would, and records whether any proposal's `D` ever went down,
/// whether any opening counted a key minted less than `KEY_MATURITY` before, and whether any
/// opening's `e0` differed from the keys present then, counted one by one. Every renewal, proposal
/// and ballot naming a key minted less than `KEY_MATURITY` ago must be refused with `KeyTooNew`.
contract ElectorateHandler is Test {
    uint256 internal constant MAX_KEYS = 12;

    KeyfleetManager internal immutable fleet;
    KeyfleetKeys internal immutable keys;
    KeyfleetVotes internal immutable votes;
    MockToken internal immutable usdc;
    address[3] internal holders = [address(0xA1), address(0xA2), address(0xA3)];

    /// @notice Set if any proposal's `D` was ever seen lower than before.
    bool public dDecreased;
    /// @notice Set if any proposal counted a key at its opening that was not mature then.
    bool public immatureAtOpening;
    /// @notice Set if any opening's `e0` was not the number of keys present then.
    bool public e0Inexact;
    mapping(uint256 proposalId => uint256 d) private _lastD;

    constructor(KeyfleetManager fleet_, MockToken usdc_) {
        fleet = fleet_;
        keys = fleet_.KEYS();
        votes = fleet_.VOTES();
        usdc = usdc_;
    }

    modifier checksD() {
        _;
        for (uint256 id = 1; id <= votes.proposalCount(); ++id) {
            KeyfleetVotes.Proposal memory stored = votes.proposal(id);
            uint256 d = uint256(stored.e0) + stored.late;
            if (d < _lastD[id]) dDecreased = true;
            _lastD[id] = d;
        }
    }

    function _key(uint256 seed) private view returns (uint256) {
        return keys.tokenIdOf(fleet.FLEET_ID(), bound(seed, 1, fleet.totalMinted()));
    }

    function _ids(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    /// @dev Acts as `tokenId`'s owner for the next call, and expects `KeyTooNew` from it when the
    /// key is not mature. Says whether it is.
    function _actAsOwner(uint256 tokenId) private returns (bool mature) {
        address owner = keys.ownerOf(tokenId);
        uint64 maturesAt = keys.mintedAt(tokenId) + votes.KEY_MATURITY();
        mature = block.timestamp >= maturesAt;
        if (!mature) vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyTooNew.selector, tokenId, maturesAt));
        vm.prank(owner);
    }

    function propose(uint256 seed) external checksD {
        uint256 tokenId = _key(seed);
        bool mature = _actAsOwner(tokenId);
        uint256 proposalId = votes.propose(tokenId, bytes32(seed), new KeyfleetTreasury.Call[](0));
        if (!mature) return;
        uint256 presentKeys;
        for (uint256 k = 1; k <= fleet.totalMinted(); ++k) {
            uint256 key = keys.tokenIdOf(fleet.FLEET_ID(), k);
            if (votes.isActive(key)) ++presentKeys;
            if (
                votes.wasActiveAtOpening(proposalId, key) && block.timestamp < keys.mintedAt(key) + votes.KEY_MATURITY()
            ) {
                immatureAtOpening = true;
            }
        }
        if (votes.proposal(proposalId).e0 != presentKeys) e0Inexact = true;
    }

    function castBallot(uint256 proposalSeed, uint256 keySeed, uint8 choice) external checksD {
        uint256 count = votes.proposalCount();
        if (count == 0) return;
        uint256 proposalId = bound(proposalSeed, 1, count);
        if (block.timestamp >= votes.proposal(proposalId).closesAt) return;
        uint256 tokenId = _key(keySeed);
        _actAsOwner(tokenId);
        votes.castBallot(proposalId, _ids(tokenId), KeyfleetVotes.Choice(bound(choice, 1, 3)));
    }

    function transfer(uint256 seed, uint256 to) external checksD {
        uint256 tokenId = _key(seed);
        address from = keys.ownerOf(tokenId);
        vm.prank(from);
        keys.transferFrom(from, holders[to % holders.length], tokenId);
    }

    function present(uint256 seed) external checksD {
        uint256 tokenId = _key(seed);
        _actAsOwner(tokenId);
        votes.present(_ids(tokenId));
    }

    function sweep(uint256 limit) external checksD {
        votes.sweepExpired(bound(limit, 0, MAX_KEYS));
    }

    function wait(uint256 secs) external checksD {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    function buy(uint256 to) external checksD {
        if (fleet.totalMinted() >= MAX_KEYS) return;
        uint256 price = fleet.nextPrice();
        usdc.mint(address(this), price);
        usdc.approve(address(fleet), price);
        fleet.purchase(holders[to % holders.length], price, block.timestamp, new bytes32[](0));
    }
}

/// @dev The growing electorate's invariants (plan §4.4): no proposal's `D` ever goes down; the
/// tallies count each key with a ballot exactly once and never exceed `D`; `late` is exactly the
/// keys with a ballot that were not present at opening; `e0` is never zero; `D` never exceeds the
/// keys sold; no opening counts a key minted less than `KEY_MATURITY` before; and every `e0` is the
/// number of keys present at the opening, those present on their own since their automatic start
/// included. The fleet is the founding Classic fleet on the shared collection.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract KeyfleetElectorateInvariantTest is KeyfleetFixture {
    KeyfleetManager private fleet;
    KeyfleetVotes private votes;
    ElectorateHandler private handler;

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();

        handler = new ElectorateHandler(fleet, usdc);
        for (uint256 i = 0; i < 4; ++i) {
            handler.buy(i);
        }
        targetContract(address(handler));
    }

    function invariant_dNeverDecreases() public view {
        assertFalse(handler.dDecreased(), "no proposal's D ever went down");
    }

    function invariant_noOpeningCountsAnImmatureKey() public view {
        assertFalse(handler.immatureAtOpening(), "every key present at an opening was mature");
    }

    function invariant_everyE0IsTheExactCountOfPresentKeys() public view {
        assertFalse(handler.e0Inexact(), "every opening counted exactly the keys present then");
    }

    function invariant_theTalliesMatchTheBallotsAndTheElectorate() public view {
        uint256 minted = fleet.totalMinted();
        for (uint256 id = 1; id <= votes.proposalCount(); ++id) {
            KeyfleetVotes.Proposal memory stored = votes.proposal(id);
            uint256 balloted;
            uint256 lateKeys;
            for (uint256 k = 1; k <= minted; ++k) {
                uint256 tokenId = _key(fleet, k);
                if (votes.ballotOf(id, tokenId) == KeyfleetVotes.Choice.None) continue;
                ++balloted;
                if (!votes.wasActiveAtOpening(id, tokenId)) ++lateKeys;
            }
            uint256 d = uint256(stored.e0) + stored.late;
            assertGe(stored.e0, 1, "e0 is never zero");
            assertEq(uint256(stored.yes) + stored.no + stored.abstain, balloted, "one ballot per key");
            assertLe(balloted, d, "the ballots never exceed D");
            assertEq(stored.late, lateKeys, "late is the keys with a ballot not present at opening");
            assertLe(d, minted, "D never exceeds the keys sold");
        }
    }
}
