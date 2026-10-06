// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetStack} from "../../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "../KeyfleetIncome.t.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockRegent} from "../mocks/MockRegent.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Drives proposals, ballots, transfers, renewals, sweeps, sales and the passing of time over a
/// small fleet, as the keys' owners would, and records whether any proposal's `D` ever went down.
contract ElectorateHandler is Test {
    uint256 internal constant MAX_KEYS = 12;

    Keyfleet internal immutable fleet;
    KeyfleetVotes internal immutable votes;
    MockToken internal immutable usdc;
    address[3] internal holders = [address(0xA1), address(0xA2), address(0xA3)];

    /// @notice Set if any proposal's `D` was ever seen lower than before.
    bool public dDecreased;
    mapping(uint256 proposalId => uint256 d) private _lastD;

    constructor(Keyfleet fleet_, MockToken usdc_) {
        fleet = fleet_;
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
        return bound(seed, 1, fleet.totalMinted());
    }

    function _ids(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    function propose(uint256 seed, uint256 period) external checksD {
        uint256 tokenId = _key(seed);
        uint64 closesAt = uint64(block.timestamp + bound(period, 1, 48 hours));
        vm.prank(fleet.ownerOf(tokenId));
        votes.propose(tokenId, bytes32(seed), closesAt, new KeyfleetTreasury.Call[](0));
    }

    function castBallot(uint256 proposalSeed, uint256 keySeed, uint8 choice) external checksD {
        uint256 count = votes.proposalCount();
        if (count == 0) return;
        uint256 proposalId = bound(proposalSeed, 1, count);
        if (block.timestamp >= votes.proposal(proposalId).closesAt) return;
        uint256 tokenId = _key(keySeed);
        vm.prank(fleet.ownerOf(tokenId));
        votes.castBallot(proposalId, _ids(tokenId), KeyfleetVotes.Choice(bound(choice, 1, 3)));
    }

    function transfer(uint256 seed, uint256 to) external checksD {
        uint256 tokenId = _key(seed);
        address from = fleet.ownerOf(tokenId);
        vm.prank(from);
        fleet.transferFrom(from, holders[to % holders.length], tokenId);
    }

    function present(uint256 seed) external checksD {
        uint256 tokenId = _key(seed);
        vm.prank(fleet.ownerOf(tokenId));
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
        fleet.purchase(holders[to % holders.length], price, block.timestamp);
    }
}

/// @dev The growing electorate's invariants (plan §4.4): no proposal's `D` ever goes down; the
/// tallies count each key with a ballot exactly once and never exceed `D`; `late` is exactly the
/// keys with a ballot that were not present at opening; `e0` is never zero; and `D` never exceeds
/// the keys sold.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract KeyfleetElectorateInvariantTest is Test {
    Keyfleet private fleet;
    KeyfleetVotes private votes;
    ElectorateHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        MockToken usdc = new MockToken("USD Coin", "USDC");
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        uint256 subscription = vrf.createSubscription();
        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            new MockRegentRevenueStaking(usdc),
            new MockRegent(),
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

        handler = new ElectorateHandler(fleet, usdc);
        for (uint256 i = 0; i < 4; ++i) {
            handler.buy(i);
        }
        targetContract(address(handler));
    }

    function invariant_dNeverDecreases() public view {
        assertFalse(handler.dDecreased(), "no proposal's D ever went down");
    }

    function invariant_theTalliesMatchTheBallotsAndTheElectorate() public view {
        uint256 minted = fleet.totalMinted();
        for (uint256 id = 1; id <= votes.proposalCount(); ++id) {
            KeyfleetVotes.Proposal memory stored = votes.proposal(id);
            uint256 balloted;
            uint256 lateKeys;
            for (uint256 tokenId = 1; tokenId <= minted; ++tokenId) {
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
