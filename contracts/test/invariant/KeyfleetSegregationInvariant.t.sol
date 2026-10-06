// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {MockToken} from "../KeyfleetIncome.t.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";

/// @dev Hands each fleet's treasury random batches of calls exactly as a carried-out proposal
/// would, aimed at all five of the fleet's contracts and at USDC, between purchases that each mint
/// to a wallet of their own. Around every batch it records whether anything protected went down:
/// the core's owed protocol share, its Cascade reserve outside a level completion, a wallet's
/// credit in the ledger, or the unsettled accrual of a key the treasury does not hold.
contract SegregationHandler is Test {
    address internal constant NATIVE = address(0);

    uint256 internal constant MAX_KEYS = 60;

    Keyfleet[2] internal fleets;
    MockToken internal immutable usdc;
    address internal buyer = address(0xB0B0B0);

    /// @notice Set, with the reason, the first time a batch lowered something protected.
    string public breach;

    constructor(Keyfleet cascade, Keyfleet accelerant, MockToken usdc_) {
        fleets = [cascade, accelerant];
        usdc = usdc_;
    }

    /// @notice The wallet a purchase of key `tokenId` mints to, one per key so that no Fibonacci
    /// holding limit is ever met.
    function holderOf(uint256 tokenId) public pure returns (address) {
        return address(uint160(0xA0000 + tokenId));
    }

    function buy(uint256 fleetSeed) external {
        Keyfleet fleet = fleets[fleetSeed % 2];
        if (fleet.totalMinted() >= MAX_KEYS) return;
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        fleet.purchase(holderOf(fleet.totalMinted() + 1), price, block.timestamp);
        vm.stopPrank();
    }

    function fundEth(uint256 fleetSeed, uint256 amount) external {
        vm.deal(address(fleets[fleetSeed % 2].TREASURY()), bound(amount, 0, 10 ether));
    }

    function approvedBatch(uint256 fleetSeed, uint256[2] calldata seeds, uint256 length) external {
        Keyfleet fleet = fleets[fleetSeed % 2];
        uint256 minted = fleet.totalMinted();
        if (minted == 0) return;
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](bound(length, 1, 2));
        for (uint256 i = 0; i < calls.length; ++i) {
            calls[i] = _call(fleet, seeds[i]);
        }

        uint256 owed = fleet.protocolShareOwed();
        uint256 reserve = fleet.cascadeReserve();
        (uint256[] memory credited, uint256[] memory accrued) = _ledger(fleet, minted);

        address treasury = address(fleet.TREASURY());
        vm.prank(address(fleet.VOTES()));
        (bool carriedOut,) = treasury.call(abi.encodeCall(KeyfleetTreasury.executeBatch, (calls)));
        if (!carriedOut) return;

        if (fleet.protocolShareOwed() < owed) _breach("the owed protocol share went down");
        if (fleet.cascadeReserve() < reserve && fleet.totalMinted() == minted) {
            _breach("the Cascade reserve went down without a level completing");
        }
        (uint256[] memory creditedAfter, uint256[] memory accruedAfter) = _ledger(fleet, minted);
        for (uint256 i = 0; i < minted; ++i) {
            if (creditedAfter[i] < credited[i]) _breach("a wallet's credit went down");
            if (accruedAfter[i] < accrued[i]) _breach("a key's accrual went down");
        }
    }

    /// @dev Each first holder's credit, and each key's unsettled accrual, zero for a key the
    /// treasury holds, whose owner may move it.
    function _ledger(Keyfleet fleet, uint256 minted)
        internal
        view
        returns (uint256[] memory credited, uint256[] memory accrued)
    {
        KeyfleetRewards rewards = fleet.REWARDS();
        credited = new uint256[](minted);
        accrued = new uint256[](minted);
        for (uint256 i = 0; i < minted; ++i) {
            credited[i] = rewards.credits(address(usdc), holderOf(i + 1));
            if (fleet.ownerOf(i + 1) != address(fleet.TREASURY())) accrued[i] = rewards.accrued(address(usdc), i + 1);
        }
    }

    function _breach(string memory reason) internal {
        if (bytes(breach).length == 0) breach = reason;
    }

    /// @dev What one menu call is aimed at and with, drawn from a seed.
    struct Draw {
        Keyfleet fleet;
        KeyfleetTreasury treasury;
        KeyfleetRewards rewards;
        uint256 arg;
        uint256 tokenId;
        address someone;
        uint256 amount;
    }

    /// @dev One call from a menu reaching every contract of the fleet and USDC, with arguments
    /// drawn from `seed`: payments and advances, raw token moves and approvals, purchases, surplus
    /// and the protocol share, key transfers, every ledger entry point, the controller's and the
    /// shard record's, and the treasury's own, the daily split and its rate included.
    function _call(Keyfleet fleet, uint256 seed) internal view returns (KeyfleetTreasury.Call memory) {
        Draw memory d;
        d.fleet = fleet;
        d.treasury = fleet.TREASURY();
        d.rewards = fleet.REWARDS();
        d.arg = uint256(keccak256(abi.encode(seed)));
        d.tokenId = 1 + d.arg % fleet.totalMinted();
        d.someone = d.arg % 4 == 0 ? holderOf(d.tokenId) : address(uint160(d.arg));
        d.amount = d.arg % (usdc.balanceOf(address(d.treasury)) + 2);
        uint256 pick = seed % 24;
        return pick < 9 ? _moneyCall(d, pick) : _contractCall(d, pick);
    }

    function _moneyCall(Draw memory d, uint256 pick) internal view returns (KeyfleetTreasury.Call memory) {
        address treasury = address(d.treasury);
        address[4] memory targets = [address(d.fleet), address(d.rewards), address(d.fleet.VOTES()), treasury];
        if (pick == 0) return _c(treasury, 0, abi.encodeCall(d.treasury.pay, (address(usdc), d.someone, d.amount)));
        if (pick == 1) return _c(treasury, 0, abi.encodeCall(d.treasury.pay, (NATIVE, d.someone, d.arg % 2 ether)));
        if (pick == 2) {
            return _c(
                treasury,
                0,
                abi.encodeCall(d.treasury.advance, (d.arg % 4, d.someone, address(usdc), d.amount, bytes32(d.arg)))
            );
        }
        if (pick == 3) return _c(address(usdc), 0, abi.encodeCall(usdc.transfer, (targets[d.arg % 4], d.amount)));
        if (pick == 4) return _c(address(usdc), 0, abi.encodeCall(usdc.approve, (targets[d.arg % 4], d.amount)));
        if (pick == 5) {
            address from = d.arg % 2 == 0 ? address(d.fleet) : address(d.rewards);
            return _c(address(usdc), 0, abi.encodeCall(usdc.transferFrom, (from, d.someone, d.amount)));
        }
        if (pick == 6) {
            return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.purchase, (treasury, d.amount, block.timestamp)));
        }
        if (pick == 7) return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.recognizeSurplus, (address(usdc))));
        return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.sendProtocolShare, ()));
    }

    function _contractCall(Draw memory d, uint256 pick) internal view returns (KeyfleetTreasury.Call memory) {
        KeyfleetRewards rewards = d.rewards;
        KeyfleetVotes votes = d.fleet.VOTES();
        uint256[] memory ids = new uint256[](1);
        ids[0] = d.tokenId;
        if (pick == 9) {
            address owner = d.fleet.ownerOf(d.tokenId);
            return _c(
                address(d.fleet),
                0,
                abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, d.someone, d.tokenId)
            );
        }
        if (pick == 10) {
            address[] memory assets = new address[](2);
            (assets[0], assets[1]) = (address(usdc), NATIVE);
            return _c(address(rewards), 0, abi.encodeCall(rewards.claim, (ids, assets)));
        }
        if (pick == 11) {
            return
                _c(address(rewards), 0, abi.encodeCall(rewards.credit, (address(usdc), address(d.treasury), d.amount)));
        }
        if (pick == 12) {
            return
                _c(address(rewards), 0, abi.encodeCall(rewards.allocateToCohort, (address(usdc), d.arg % 3, d.amount)));
        }
        if (pick == 13) return _c(address(rewards), 0, abi.encodeCall(rewards.settleKey, (d.tokenId, d.someone)));
        if (pick == 14) return _c(address(rewards), 0, abi.encodeCall(rewards.enrollKey, (d.tokenId + 1, d.arg % 3)));
        if (pick == 15) {
            return _c(address(votes), 0, abi.encodeCall(votes.setEditsRestricted, (d.tokenId, d.arg % 2 == 0)));
        }
        if (pick == 16) return _c(address(votes), 0, abi.encodeCall(votes.onKeyMoved, (d.tokenId)));
        if (pick == 17) {
            return _c(address(votes), 0, abi.encodeCall(votes.execute, (1, new KeyfleetTreasury.Call[](0))));
        }
        if (pick == 18) {
            KeyfleetShards shards = d.fleet.SHARDS();
            return _c(address(shards), 0, abi.encodeCall(shards.issue, (ids, d.someone, 30)));
        }
        if (pick == 19) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.depositProtocolShare, (d.amount)));
        }
        if (pick == 20) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.returnAdvance, (d.arg % 4, 0)));
        }
        if (pick == 21) return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.runVotedSplit, ()));
        if (pick == 22) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.setDailySplitBps, (d.arg % 250)));
        }
        return _c([address(d.fleet), address(rewards), address(votes)][d.arg % 3], d.arg % 1 ether, "");
    }

    function _c(address target, uint256 value, bytes memory data) internal pure returns (KeyfleetTreasury.Call memory) {
        return KeyfleetTreasury.Call(target, value, data);
    }
}

/// @dev Segregation (plan §4.8): no batch of calls a proposal could carry out, against any of the
/// fleet's five contracts, lowers the core's owed protocol share or Cascade reserve or what the
/// ledger owes any holder, and the core and the ledger always hold at least what they have booked.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract KeyfleetSegregationInvariantTest is KeyfleetFixture {
    SegregationHandler internal handler;
    Keyfleet internal cascade;
    Keyfleet internal accelerant;

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        cascade = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        handler = new SegregationHandler(cascade, accelerant, usdc);
        targetContract(address(handler));
    }

    function invariant_noBatchLowersAnythingProtected() public view {
        assertEq(handler.breach(), "");
    }

    function invariant_theCoreAndTheLedgerHoldWhatTheyBooked() public view {
        Keyfleet[2] memory fleets = [cascade, accelerant];
        for (uint256 f = 0; f < 2; ++f) {
            Keyfleet fleet = fleets[f];
            KeyfleetRewards rewards = fleet.REWARDS();
            assertGe(usdc.balanceOf(address(fleet)), fleet.cascadeReserve() + fleet.protocolShareOwed());
            assertGe(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)));
        }
    }
}
