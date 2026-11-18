// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTradingTreasury} from "../src/KeyfleetTradingTreasury.sol";
import {KeyfleetTradingFixture} from "./helpers/KeyfleetTradingFixture.sol";

contract KeyfleetTradingTreasuryTest is KeyfleetTradingFixture {
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpTrading();
        _createTrading();
    }

    // --- the trading wallet -------------------------------------------------------

    function test_creatorNamesTheTradingWallet() public {
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.TradingWalletNamed(wallet);
        vm.prank(creator);
        treasury.setTradingWallet(wallet);
        assertEq(treasury.tradingWallet(), wallet);
    }

    function test_tradingWalletRefusedFromOthersOrZero() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, stranger));
        treasury.setTradingWallet(wallet);
        vm.prank(creator);
        vm.expectRevert(KeyfleetTradingTreasury.ZeroAddress.selector);
        treasury.setTradingWallet(address(0));
    }

    function test_creatorSendsAnyAmountToTrading() public {
        _return(90e6);
        vm.startPrank(creator);
        treasury.setTradingWallet(wallet);
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.SentToTrading(wallet, 30e6);
        treasury.sendToTrading(30e6);
        treasury.sendToTrading(70e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(wallet), 100e6);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_sendToTradingRefusals() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, stranger));
        treasury.sendToTrading(1);

        vm.startPrank(creator);
        vm.expectRevert(KeyfleetTradingTreasury.NoTradingWallet.selector);
        treasury.sendToTrading(1);
        treasury.setTradingWallet(wallet);
        vm.expectRevert(KeyfleetTradingTreasury.ZeroAmount.selector);
        treasury.sendToTrading(0);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetTradingTreasury.AboveBalance.selector, FIRST_PRICE + 1, FIRST_PRICE)
        );
        treasury.sendToTrading(FIRST_PRICE + 1);
        treasury.close();
        vm.expectRevert(KeyfleetTradingTreasury.FleetClosed.selector);
        treasury.sendToTrading(1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(wallet), 0);
    }

    function test_usdcComesBackByPlainTransfer() public {
        vm.startPrank(creator);
        treasury.setTradingWallet(wallet);
        treasury.sendToTrading(FIRST_PRICE);
        vm.stopPrank();
        // The trade made 5 USDC.
        usdc.mint(wallet, 5e6);
        vm.prank(wallet);
        usdc.transfer(address(treasury), FIRST_PRICE + 5e6);
        assertEq(usdc.balanceOf(address(treasury)), FIRST_PRICE + 5e6);
    }

    function test_treasuryRefusesEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // --- the payback routine ----------------------------------------------------------

    function test_paybackSendsOnePercentToStakingAndSplitsTheRest() public {
        _tbuyMany(2);
        _tcount();
        _return(1_000e6);
        uint256 amount = 300e6 + 7;
        uint256 balance = usdc.balanceOf(address(treasury));
        uint256 staked = Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil);
        uint256 perKey = (amount - staked) / 3;

        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.PaidBack(
            creator, KeyfleetTradingTreasury.Payback.Creator, amount, staked, perKey, 3
        );
        vm.expectEmit(address(rewards));
        emit KeyfleetRewards.SplitFunded(address(usdc), perKey, 3, perKey);
        vm.prank(creator);
        treasury.payback(amount);

        assertEq(staked, 3e6 + 1);
        assertEq(staking.totalUsdcReceived(), staked);
        assertEq(staking.lastSourceTag(), keccak256("keyfleet.trading_payback"));
        assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(fleet)))));
        assertEq(usdc.allowance(address(treasury), address(staking)), 0);
        assertEq(usdc.balanceOf(address(rewards)), perKey * 3);
        assertEq(rewards.backed(address(usdc)), perKey * 3);
        assertEq(usdc.balanceOf(address(treasury)), balance - staked - perKey * 3);
        assertFalse(treasury.splitInProgress());
        for (uint256 n = 1; n <= 3; ++n) {
            assertEq(rewards.accrued(address(usdc), _tkey(n)), perKey);
        }
    }

    function test_onlyTheCreatorStartsAPayback() public {
        _tcount();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, stranger));
        treasury.payback(1e6);
    }

    function test_paybackRefusedWhileNoKeyCounts() public {
        vm.prank(creator);
        vm.expectRevert(KeyfleetTradingTreasury.NoKeysCount.selector);
        treasury.payback(1e6);
    }

    function test_paybackRefusedAboveTheBalance() public {
        _tcount();
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetTradingTreasury.AboveBalance.selector, FIRST_PRICE + 1, FIRST_PRICE)
        );
        treasury.payback(FIRST_PRICE + 1);
    }

    function test_paybackRefusedWhenTooSmallForAWholeUnitEach() public {
        _tbuyMany(2);
        _tcount();
        // Staking takes 1 unit of 3 or 4 (1%, rounded up): 2 units do not cover three Keys, 3 do.
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, 3, 3));
        treasury.payback(3);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, 0, 3));
        treasury.payback(0);
        treasury.payback(4);
        vm.stopPrank();
        assertEq(staking.totalUsdcReceived(), 1);
        assertEq(rewards.accrued(address(usdc), _tkey(3)), 1);
    }

    function test_paybackStopsWhenStakingRefuses() public {
        _tcount();
        staking.setPaused(true);
        vm.prank(creator);
        vm.expectRevert("PAUSED");
        treasury.payback(5e6);

        staking.setPaused(false);
        staking.setShort(1, 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.StakingDepositFailed.selector, 5e4, 5e4));
        treasury.payback(5e6);

        staking.setShort(0, 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.StakingDepositFailed.selector, 5e4, 5e4 - 1));
        treasury.payback(5e6);
        assertEq(usdc.balanceOf(address(treasury)), FIRST_PRICE);
    }

    function test_ledgerTakesFundingOnlyFromInsideAPayback() public {
        _tcount();
        usdc.mint(address(rewards), 1e6);
        vm.expectRevert(KeyfleetRewards.OnlyTreasury.selector);
        rewards.fundSplit(address(usdc), 1e6, 1);
        vm.prank(address(treasury));
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        rewards.fundSplit(address(usdc), 1e6, 1);
    }

    /// @dev Any amount the treasury holds, paid back to any number of counting Keys, gives staking
    /// exactly 1% rounded up, each Key the same whole amount, and keeps the remainder.
    function testFuzz_paybackSharesAnyAmountAmongAnyCount(uint256 count, uint256 amount, uint256 extra) public {
        count = bound(count, 1, 60);
        _tbuyMany(count - 1);
        _tcount();
        _return(bound(extra, 0, 1e15));
        uint256 balance = usdc.balanceOf(address(treasury));
        amount = bound(amount, 0, balance);
        uint256 staked = Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil);
        uint256 perKey = amount > staked ? (amount - staked) / count : 0;

        vm.prank(creator);
        if (perKey == 0) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, amount, count));
            treasury.payback(amount);
            return;
        }
        treasury.payback(amount);
        assertEq(staking.totalUsdcReceived(), staked);
        assertLe(perKey * count * 100, amount * 99);
        assertEq(usdc.balanceOf(address(rewards)), perKey * count);
        assertEq(usdc.balanceOf(address(treasury)), balance - staked - perKey * count);
        assertLt(amount - staked - perKey * count, count);
        assertEq(rewards.accrued(address(usdc), _tkey(1)), perKey);
        assertEq(rewards.accrued(address(usdc), _tkey(count)), perKey);
    }

    // --- the daily payback ---------------------------------------------------------------

    function test_dailyPaybackIsDueADayAfterKeyOne() public {
        uint256 mintedAt = keys.mintedAt(_tkey(1));
        assertEq(treasury.nextDailyAt(), mintedAt + 1 days);
        vm.warp(mintedAt + 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.DailyNotDue.selector, mintedAt + 1 days));
        treasury.runDailyPayback();
    }

    function test_aRefusedDailyRunUsesUpNothing() public {
        uint256 mintedAt = keys.mintedAt(_tkey(1));
        vm.warp(mintedAt + 1 days);
        // Key 1 counts only after two days.
        vm.expectRevert(KeyfleetTradingTreasury.NoKeysCount.selector);
        treasury.runDailyPayback();
        assertEq(treasury.lastDailyAt(), 0);
        assertEq(treasury.nextDailyAt(), mintedAt + 1 days);

        vm.warp(mintedAt + 2 days);
        vm.prank(stranger);
        treasury.runDailyPayback();
        assertEq(treasury.lastDailyAt(), mintedAt + 2 days);
    }

    function test_anyoneRunsTheDailyPaybackOfTheBalanceAtTheRun() public {
        _tcount();
        _return(990e6);
        uint256 balance = usdc.balanceOf(address(treasury));
        uint256 amount = balance * DAILY_BPS / 10_000;
        uint256 staked = Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil);

        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.PaidBack(
            stranger, KeyfleetTradingTreasury.Payback.Daily, amount, staked, amount - staked, 1
        );
        vm.prank(stranger);
        treasury.runDailyPayback();
        assertEq(rewards.accrued(address(usdc), _tkey(1)), amount - staked);
        assertEq(usdc.balanceOf(address(treasury)), balance - amount);
    }

    function test_missedDaysAreNotMadeUp() public {
        _tcount();
        _return(990e6);
        vm.warp(block.timestamp + 5 days);
        uint256 balance = usdc.balanceOf(address(treasury));
        treasury.runDailyPayback();
        assertEq(usdc.balanceOf(address(treasury)), balance - balance * DAILY_BPS / 10_000);
        assertEq(treasury.nextDailyAt(), block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.DailyNotDue.selector, block.timestamp + 1 days));
        treasury.runDailyPayback();
        vm.warp(block.timestamp + 1 days);
        treasury.runDailyPayback();
    }

    function test_dailyPaybackOfAnEmptiedTreasuryIsRefused() public {
        _tcount();
        vm.startPrank(creator);
        treasury.setTradingWallet(wallet);
        treasury.sendToTrading(FIRST_PRICE);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, 0, 1));
        treasury.runDailyPayback();
    }

    // --- closing --------------------------------------------------------------------------

    function test_creatorClosesOnce() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, stranger));
        treasury.close();

        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.Closed(creator);
        vm.prank(creator);
        treasury.close();
        assertEq(treasury.closedAt(), block.timestamp);

        vm.prank(creator);
        vm.expectRevert(KeyfleetTradingTreasury.FleetClosed.selector);
        treasury.close();
    }

    function test_payBackEverythingOnlyAfterTheClose() public {
        _tcount();
        vm.expectRevert(KeyfleetTradingTreasury.FleetOpen.selector);
        treasury.paybackAll();
    }

    function test_afterTheClosePaybacksWaitForEveryMintedKey() public {
        _tcount();
        _tbuy(stranger);
        vm.prank(creator);
        treasury.close();

        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.KeysMaturing.selector, 1, 2));
        treasury.paybackAll();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.KeysMaturing.selector, 1, 2));
        treasury.payback(1e6);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.KeysMaturing.selector, 1, 2));
        treasury.runDailyPayback();

        _tcount();
        treasury.paybackAll();
        assertEq(rewards.accrued(address(usdc), _tkey(1)), rewards.accrued(address(usdc), _tkey(2)));
        assertGt(rewards.accrued(address(usdc), _tkey(2)), 0);
    }

    function test_anyonePaysBackEverythingAgainAsUsdcComesBack() public {
        _tbuyMany(2);
        _tcount();
        vm.prank(creator);
        treasury.close();

        uint256 balance = usdc.balanceOf(address(treasury));
        uint256 staked = Math.mulDiv(balance, 100, 10_000, Math.Rounding.Ceil);
        uint256 perKey = (balance - staked) / 3;
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.PaidBack(
            stranger, KeyfleetTradingTreasury.Payback.Closed, balance, staked, perKey, 3
        );
        vm.prank(stranger);
        treasury.paybackAll();
        assertEq(usdc.balanceOf(address(treasury)), balance - staked - perKey * 3);

        _return(500e6);
        vm.prank(stranger);
        treasury.paybackAll();
        assertLt(usdc.balanceOf(address(treasury)), 3);
    }

    function test_closeEndsSalesAndTradingSendsButNotPaybacks() public {
        _tcount();
        vm.startPrank(creator);
        treasury.setTradingWallet(wallet);
        treasury.close();
        vm.expectRevert(KeyfleetTradingTreasury.FleetClosed.selector);
        treasury.sendToTrading(1);
        treasury.payback(1e6);
        vm.stopPrank();
        assertEq(fleet.totalMinted(), 1);
    }
}
