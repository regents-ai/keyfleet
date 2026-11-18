// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTradingFixture} from "./helpers/KeyfleetTradingFixture.sol";

/// @dev The existing `KeyfleetRewards` ledger, unchanged, behind a Trading Fleet: what each Key
/// earns from paybacks, who keeps it when the Key is sold, and how it is claimed.
contract KeyfleetTradingRewardsTest is KeyfleetTradingFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _setUpTrading();
        _createTrading();
        _return(10_000e6);
    }

    /// @dev What each counting Key receives from a creator's payback of `amount`.
    function _payback(uint256 amount) internal returns (uint256 perKey) {
        uint256 counting = fleet.matureKeys();
        perKey = (amount - Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil)) / counting;
        vm.prank(keys.ownerOf(_tkey(1)));
        treasury.payback(amount);
    }

    function test_keysAreEnrolledAndPaidBack() public {
        uint256 key2 = _tbuy(alice);
        _tcount();
        assertEq(rewards.keyCohort(key2), 0);
        assertEq(rewards.accrued(address(usdc), key2), 0);

        uint256 perKey = _payback(1_000e6);
        assertEq(perKey, 495e6);
        assertEq(rewards.accrued(address(usdc), _tkey(1)), perKey);
        assertEq(rewards.accrued(address(usdc), key2), perKey);
        assertEq(rewards.splitIndex(address(usdc)), perKey);
    }

    function test_aSoldKeysEarningsStayWithTheSeller() public {
        uint256 key2 = _tbuy(alice);
        _tcount();
        uint256 first = _payback(1_000e6);

        vm.prank(alice);
        keys.transferFrom(alice, bob, key2);
        assertEq(rewards.credits(address(usdc), alice), first);
        assertEq(rewards.accrued(address(usdc), key2), 0);

        uint256 second = _payback(400e6);
        assertEq(rewards.accrued(address(usdc), key2), second);

        assertEq(_claimAll(bob, key2), second);
        assertEq(usdc.balanceOf(bob), second);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory none;
        vm.prank(alice);
        rewards.claim(none, assets);
        assertEq(usdc.balanceOf(alice), first);
    }

    function test_aKeyThatDidNotCountGetsNoneOfThatPayback() public {
        _tcount();
        uint256 key2 = _tbuy(alice);
        assertEq(fleet.matureKeys(), 1);

        uint256 first = _payback(1_000e6);
        assertEq(rewards.accrued(address(usdc), _tkey(1)), first);
        assertEq(rewards.accrued(address(usdc), key2), 0);

        _tcount();
        uint256 second = _payback(1_000e6);
        assertEq(rewards.accrued(address(usdc), _tkey(1)), first + second);
        assertEq(rewards.accrued(address(usdc), key2), second);
    }

    function test_theHolderClaims() public {
        uint256 key2 = _tbuy(alice);
        _tcount();
        uint256 perKey = _payback(1_000e6);

        vm.expectEmit(address(rewards));
        emit KeyfleetRewards.Claimed(address(usdc), alice, alice, perKey);
        assertEq(_claimAll(alice, key2), perKey);
        assertEq(usdc.balanceOf(alice), perKey);
        assertEq(rewards.accrued(address(usdc), key2), 0);
        assertEq(rewards.backed(address(usdc)), perKey);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory ids = _ids(key2);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, key2));
        vm.prank(bob);
        rewards.claim(ids, assets);
    }

    function test_anAgentWithAShardClaimsForTheHolder() public {
        uint256 key2 = _tbuy(alice);
        _tcount();
        uint256 perKey = _payback(1_000e6);
        vm.prank(alice);
        shards.issue(_ids(key2), bob, 30);

        assertEq(_claimAll(bob, key2), perKey);
        assertEq(usdc.balanceOf(alice), perKey);
        assertEq(usdc.balanceOf(bob), 0);
    }

    function test_fiveKeysEarnFiveTimesOne() public {
        _tbuy(alice);
        for (uint256 i = 0; i < 5; ++i) {
            _tbuy(bob);
        }
        _tcount();
        _payback(3_000e6);
        _payback(777e6);

        uint256 aliceEarned = _claimAll(alice, _tkey(2));
        uint256[] memory bobs = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            bobs[i] = _tkey(3 + i);
        }
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        vm.prank(bob);
        uint256 bobEarned = rewards.claim(bobs, assets)[0];
        assertGt(aliceEarned, 0);
        assertEq(bobEarned, 5 * aliceEarned);
    }

    function test_theLedgerNeverOwesMoreThanItHolds() public {
        _tbuyMany(9);
        _tcount();
        _payback(1_234_567_891);
        _payback(98_765_432);
        uint256 owed;
        for (uint256 n = 1; n <= 10; ++n) {
            owed += rewards.accrued(address(usdc), _tkey(n));
        }
        assertEq(owed, rewards.backed(address(usdc)));
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)));
    }
}
