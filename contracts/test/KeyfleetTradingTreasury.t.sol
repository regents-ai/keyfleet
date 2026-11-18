// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTradingTreasury} from "../src/KeyfleetTradingTreasury.sol";
import {KeyfleetTradingFixture} from "./helpers/KeyfleetTradingFixture.sol";

/// @dev Put over REGENT staking's address with `vm.etch`. On each deposit it first tries every
/// treasury function that moves USDC, recording how each one ended (`WENT` if it went through),
/// then takes the deposit as asked.
contract ReenteringStaking {
    bytes4 internal constant WENT = 0xffffffff;

    IERC20 internal immutable USDC;
    KeyfleetTradingTreasury internal immutable TREASURY;

    /// @dev How each reentry ended, in the order `depositUSDC` tries them.
    bytes4[5] public ended;

    constructor(IERC20 usdc_, KeyfleetTradingTreasury treasury_) {
        USDC = usdc_;
        TREASURY = treasury_;
    }

    function depositUSDC(uint256 amount, bytes32, bytes32) external returns (uint256) {
        bytes[5] memory calls = [
            abi.encodeCall(KeyfleetTradingTreasury.paybackAll, ()),
            abi.encodeCall(KeyfleetTradingTreasury.runDailyPayback, ()),
            abi.encodeCall(KeyfleetTradingTreasury.payback, (amount)),
            abi.encodeCall(KeyfleetTradingTreasury.sendToTrading, (1)),
            abi.encodeCall(KeyfleetTradingTreasury.sendToStaking, ())
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(TREASURY).call(calls[i]);
            ended[i] = ok ? WENT : bytes4(reason);
        }
        require(USDC.transferFrom(msg.sender, address(this), amount), "pull");
        return amount;
    }
}

contract KeyfleetTradingTreasuryTest is KeyfleetTradingFixture {
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpTrading();
        _createTrading();
    }

    // --- the trading wallet -------------------------------------------------------

    function test_creatorNamesTheTradingWallet() public {
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.TradingWalletNamed(creator, wallet);
        vm.prank(creator);
        treasury.setTradingWallet(wallet);
        assertEq(treasury.tradingWallet(), wallet);
        assertEq(treasury.tradingWalletOf(creator), wallet);
    }

    function test_tradingWalletRefusedFromOthersOrZero() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, stranger));
        treasury.setTradingWallet(wallet);
        vm.prank(creator);
        vm.expectRevert(KeyfleetTradingTreasury.ZeroAddress.selector);
        treasury.setTradingWallet(address(0));
    }

    /// @dev Once Key 1 is sold, its new holder sends nothing until they name a wallet themselves; the
    /// seller's wallet never receives the new holder's send. A wallet stays its namer's: if Key 1
    /// comes back to them, so does their wallet.
    function test_aSoldKeyOneLeavesNoTradingWalletUntilItsNewHolderNamesOne() public {
        address sellersWallet = makeAddr("seller's wallet");
        address newCreator = makeAddr("new creator");
        address newWallet = makeAddr("new creator's wallet");
        _return(1_000e6);
        uint256 key1 = _tkey(1);
        vm.startPrank(creator);
        treasury.setTradingWallet(sellersWallet);
        keys.transferFrom(creator, newCreator, key1);
        vm.stopPrank();

        assertEq(treasury.tradingWallet(), address(0), "no wallet for the new holder");
        vm.startPrank(newCreator);
        vm.expectRevert(KeyfleetTradingTreasury.NoTradingWallet.selector);
        treasury.sendToTrading(1);
        treasury.setTradingWallet(newWallet);
        treasury.sendToTrading(400e6);
        keys.transferFrom(newCreator, creator, key1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(newWallet), 400e6);
        assertEq(usdc.balanceOf(sellersWallet), 0, "the seller's wallet got nothing");

        assertEq(treasury.tradingWallet(), sellersWallet);
        vm.prank(creator);
        treasury.sendToTrading(100e6);
        assertEq(usdc.balanceOf(sellersWallet), 100e6);
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
            abi.encodeWithSelector(KeyfleetTradingTreasury.AboveAvailable.selector, FIRST_PRICE + 1, FIRST_PRICE)
        );
        treasury.sendToTrading(FIRST_PRICE + 1);
        treasury.close();
        vm.expectRevert(KeyfleetTradingTreasury.FleetClosed.selector);
        treasury.sendToTrading(1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(wallet), 0);
    }

    /// @dev What a payback owes staking is never the creator's to send: the send stops at the
    /// fleet's own USDC, and what is owed stays for staking.
    function test_sendToTradingNeverTakesWhatIsOwedToStaking() public {
        _tcount();
        _return(990e6);
        vm.startPrank(creator);
        treasury.payback(100e6);
        treasury.setTradingWallet(wallet);
        uint256 owed = treasury.stakingOwed();
        uint256 own = treasury.available();
        assertEq(owed, 1e6);
        assertEq(own, usdc.balanceOf(address(treasury)) - owed);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.AboveAvailable.selector, own + 1, own));
        treasury.sendToTrading(own + 1);
        treasury.sendToTrading(own);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(treasury)), owed);
        assertEq(treasury.available(), 0);

        vm.prank(keeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(usdc.balanceOf(address(treasury)), 0);
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

    /// @dev A payback sends the Keys their 99% at once and only sets staking's 1% aside; the keeper
    /// then sends what is owed to staking, with the tag, the manager as reference and no approval
    /// left.
    function test_paybackSetsOnePercentAsideAndTheKeeperSendsItToStaking() public {
        _tbuyMany(2);
        _tcount();
        _return(1_000e6);
        uint256 amount = 300e6 + 7;
        uint256 balance = usdc.balanceOf(address(treasury));
        uint256 forStaking = 3e6 + 1;
        uint256 perKey = (amount - forStaking) / 3;

        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.PaidBack(
            creator, KeyfleetTradingTreasury.Payback.Creator, amount, forStaking, perKey, 3
        );
        vm.expectEmit(address(rewards));
        emit KeyfleetRewards.SplitFunded(address(usdc), perKey, 3, perKey);
        vm.prank(creator);
        treasury.payback(amount);

        assertEq(staking.totalUsdcReceived(), 0, "nothing sent to staking by the payback");
        assertEq(treasury.stakingOwed(), forStaking);
        assertEq(usdc.balanceOf(address(rewards)), perKey * 3);
        assertEq(rewards.backed(address(usdc)), perKey * 3);
        assertEq(usdc.balanceOf(address(treasury)), balance - perKey * 3);
        assertEq(treasury.available(), balance - forStaking - perKey * 3);
        assertFalse(treasury.splitInProgress());
        for (uint256 n = 1; n <= 3; ++n) {
            assertEq(rewards.accrued(address(usdc), _tkey(n)), perKey);
        }

        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.SentToStaking(keeper, forStaking);
        vm.prank(keeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), forStaking);
        assertEq(staking.lastSourceTag(), keccak256("keyfleet.trading_payback"));
        assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(fleet)))));
        assertEq(usdc.allowance(address(treasury), address(staking)), 0);
        assertEq(treasury.stakingOwed(), 0);
        assertEq(usdc.balanceOf(address(treasury)), balance - forStaking - perKey * 3);
    }

    /// @dev What is owed adds up over paybacks of every kind and goes to staking in one send.
    function test_stakingIsOwedEveryPaybacksPartUntilSent() public {
        _tcount();
        _return(990e6);
        vm.prank(creator);
        treasury.payback(101);
        uint256 own = treasury.available();
        treasury.runDailyPayback();
        uint256 daily = own * DAILY_BPS / 10_000;
        vm.prank(creator);
        treasury.close();
        own = treasury.available();
        treasury.paybackAll();
        uint256 owed = 2 + Math.ceilDiv(daily, 100) + Math.ceilDiv(own, 100);
        assertEq(treasury.stakingOwed(), owed);

        vm.prank(keeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(treasury.stakingOwed(), 0);
        vm.prank(keeper);
        vm.expectRevert(KeyfleetTradingTreasury.ZeroAmount.selector);
        treasury.sendToStaking();
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

    function test_paybackRefusedAboveTheFleetsOwnUsdc() public {
        _tcount();
        vm.startPrank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetTradingTreasury.AboveAvailable.selector, FIRST_PRICE + 1, FIRST_PRICE)
        );
        treasury.payback(FIRST_PRICE + 1);
        treasury.payback(FIRST_PRICE / 2);
        uint256 own = treasury.available();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.AboveAvailable.selector, own + 1, own));
        treasury.payback(own + 1);
        vm.stopPrank();
    }

    function test_paybackRefusedWhenTooSmallForAWholeUnitEach() public {
        _tbuyMany(2);
        _tcount();
        // Staking is owed 1 unit of 3 or 4 (1%, rounded up): 2 units do not cover three Keys, 3 do.
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, 3, 3));
        treasury.payback(3);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, 0, 3));
        treasury.payback(0);
        treasury.payback(4);
        vm.stopPrank();
        assertEq(treasury.stakingOwed(), 1);
        assertEq(rewards.accrued(address(usdc), _tkey(3)), 1);
    }

    /// @dev While staking refuses, every payback still pays the Keys and what is owed waits; the
    /// send to staking goes through once staking takes deposits again.
    function test_paybacksRunWhileStakingRefuses() public {
        _tcount();
        _return(990e6);
        staking.setPaused(true);
        vm.prank(creator);
        treasury.payback(100e6);
        treasury.runDailyPayback();
        vm.prank(creator);
        treasury.close();
        treasury.paybackAll();
        uint256 owed = treasury.stakingOwed();
        assertEq(rewards.accrued(address(usdc), _tkey(1)), usdc.balanceOf(address(rewards)), "the Keys were paid");
        assertEq(treasury.available(), 0, "everything of the fleet's own paid out");

        vm.prank(keeper);
        vm.expectRevert("PAUSED");
        treasury.sendToStaking();
        assertEq(treasury.stakingOwed(), owed, "still owed");
        staking.setPaused(false);
        vm.prank(keeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    /// @dev Staking that takes less than it is sent, or reports less, stops the send whole; what is
    /// owed stays owed and no approval is left.
    function test_sendToStakingStopsWholeWhenStakingMisbehaves() public {
        _tcount();
        vm.prank(creator);
        treasury.payback(5e6);
        uint256 owed = treasury.stakingOwed();
        assertEq(owed, 5e4);

        staking.setShort(1, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.StakingDepositFailed.selector, owed, owed));
        treasury.sendToStaking();
        staking.setShort(0, 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.StakingDepositFailed.selector, owed, owed - 1));
        treasury.sendToStaking();
        assertEq(treasury.stakingOwed(), owed);
        assertEq(usdc.allowance(address(treasury), address(staking)), 0);
        assertEq(staking.totalUsdcReceived(), 0);
    }

    /// @dev Staking that calls back into the treasury while taking its deposit is refused by the
    /// lock on every function that moves USDC, Key 1's powers included, and the deposit is exactly
    /// what was owed. The fleet is closed, every Key counts and a daily run is due, so without the
    /// lock the reentered paybacks would pay the Keys from what staking has not yet taken.
    function test_stakingThatReentersIsRefusedEverywhere() public {
        _tbuyMany(2);
        _tcount();
        _return(1_000e6);
        ReenteringStaking placed = ReenteringStaking(address(staking));
        vm.etch(address(staking), address(new ReenteringStaking(usdc, treasury)).code);
        vm.startPrank(creator);
        treasury.payback(100e6);
        keys.transferFrom(creator, address(placed), _tkey(1));
        vm.stopPrank();
        vm.startPrank(address(placed));
        treasury.setTradingWallet(address(placed));
        treasury.close();
        vm.stopPrank();
        assertLe(treasury.nextDailyAt(), block.timestamp, "a daily run is due");
        uint256 owed = treasury.stakingOwed();
        uint256 balance = usdc.balanceOf(address(treasury));
        uint256 accrued = rewards.accrued(address(usdc), _tkey(1));

        vm.prank(keeper);
        treasury.sendToStaking();

        for (uint256 i = 0; i < 5; ++i) {
            assertEq(placed.ended(i), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        }
        assertEq(usdc.balanceOf(address(placed)), owed, "staking took exactly what was owed");
        assertEq(usdc.balanceOf(address(treasury)), balance - owed);
        assertEq(rewards.accrued(address(usdc), _tkey(1)), accrued, "no payback slipped in");
        assertEq(treasury.stakingOwed(), 0);
        assertEq(usdc.allowance(address(treasury), address(placed)), 0);
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

    /// @dev Any amount of the fleet's own USDC, paid back to any number of counting Keys, sets
    /// exactly 1% rounded up aside for staking, gives each Key the same whole amount, and keeps the
    /// remainder as the fleet's own.
    function testFuzz_paybackSharesAnyAmountAmongAnyCount(uint256 count, uint256 amount, uint256 extra) public {
        count = bound(count, 1, 60);
        _tbuyMany(count - 1);
        _tcount();
        _return(bound(extra, 0, 1e15));
        uint256 balance = usdc.balanceOf(address(treasury));
        amount = bound(amount, 0, balance);
        uint256 forStaking = (amount + 99) / 100;
        uint256 perKey = amount > forStaking ? (amount - forStaking) / count : 0;

        vm.prank(creator);
        if (perKey == 0) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.PaybackTooSmall.selector, amount, count));
            treasury.payback(amount);
            return;
        }
        treasury.payback(amount);
        assertEq(treasury.stakingOwed(), forStaking);
        assertLe(perKey * count * 100, amount * 99);
        assertEq(usdc.balanceOf(address(rewards)), perKey * count);
        assertEq(usdc.balanceOf(address(treasury)), balance - perKey * count);
        assertEq(treasury.available(), balance - forStaking - perKey * count);
        assertLt(amount - forStaking - perKey * count, count);
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

    /// @dev The daily payback is its share of the fleet's own USDC at the run, leaving out what is
    /// already owed to staking.
    function test_anyoneRunsTheDailyPaybackOfTheFleetsOwnUsdcAtTheRun() public {
        _tcount();
        _return(990e6);
        vm.prank(creator);
        treasury.payback(100e6);
        uint256 balance = usdc.balanceOf(address(treasury));
        uint256 own = treasury.available();
        uint256 amount = own * DAILY_BPS / 10_000;
        uint256 forStaking = (amount + 99) / 100;

        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.PaidBack(
            stranger, KeyfleetTradingTreasury.Payback.Daily, amount, forStaking, amount - forStaking, 1
        );
        vm.prank(stranger);
        treasury.runDailyPayback();
        assertEq(rewards.accrued(address(usdc), _tkey(1)), 99e6 + amount - forStaking);
        assertEq(usdc.balanceOf(address(treasury)), balance - (amount - forStaking));
        assertEq(treasury.stakingOwed(), 1e6 + forStaking);
    }

    function test_missedDaysAreNotMadeUp() public {
        _tcount();
        _return(990e6);
        vm.warp(block.timestamp + 5 days);
        uint256 own = treasury.available();
        treasury.runDailyPayback();
        assertEq(treasury.available(), own - own * DAILY_BPS / 10_000);
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
        uint256 forStaking = (balance + 99) / 100;
        uint256 perKey = (balance - forStaking) / 3;
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.PaidBack(
            stranger, KeyfleetTradingTreasury.Payback.Closed, balance, forStaking, perKey, 3
        );
        vm.prank(stranger);
        treasury.paybackAll();
        assertEq(usdc.balanceOf(address(treasury)), balance - perKey * 3);
        assertEq(treasury.available(), balance - forStaking - perKey * 3);

        _return(500e6);
        vm.prank(stranger);
        treasury.paybackAll();
        assertLt(treasury.available(), 3);
        vm.prank(safe);
        treasury.sendToStaking();
        assertLt(usdc.balanceOf(address(treasury)), 3, "less than a unit per Key stays for good");
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

    // --- the send to staking -----------------------------------------------------------------

    function test_theKeeperSendsWhatIsOwedToStaking() public {
        uint256 owed = _oweStaking();
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.SentToStaking(keeper, owed);
        vm.prank(keeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(treasury.stakingOwed(), 0);
    }

    function test_theRegentsSafeSendsWhatIsOwedToStaking() public {
        uint256 owed = _oweStaking();
        vm.expectEmit(address(treasury));
        emit KeyfleetTradingTreasury.SentToStaking(safe, owed);
        vm.prank(safe);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(treasury.stakingOwed(), 0);
    }

    function test_theCreatorMayNotSendToStaking() public {
        _oweStaking();
        _assertSendToStakingRefused(creator);
    }

    function test_aStrangerMayNotSendToStaking() public {
        _oweStaking();
        _assertSendToStakingRefused(stranger);
    }

    function test_aKeyHolderMayNotSendToStaking() public {
        address holder = makeAddr("key holder");
        _tbuy(holder);
        _oweStaking();
        _assertSendToStakingRefused(holder);
    }

    function testFuzz_onlyTheKeeperOrTheRegentsSafeSendsToStaking(address caller) public {
        assumeNotForgeAddress(caller);
        vm.assume(caller != keeper && caller != safe);
        _oweStaking();
        _assertSendToStakingRefused(caller);
    }

    /// @dev Once the Safe names a new keeper, the old one is refused and the new one sends.
    function test_aNewKeeperSendsAndTheOldOneIsRefused() public {
        uint256 owed = _oweStaking();
        address newKeeper = makeAddr("new keeper");
        vm.prank(safe);
        keys.setKeeper(newKeeper);
        _assertSendToStakingRefused(keeper);

        vm.prank(newKeeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(treasury.stakingOwed(), 0);
    }

    /// @dev With the fleet closed and Key 1 sent where nobody can use it, what every payback owes
    /// staking still goes there.
    function test_theSendWorksAfterTheCloseWithKeyOneUnusable() public {
        _oweStaking();
        vm.startPrank(creator);
        treasury.close();
        keys.transferFrom(creator, address(0xdead), _tkey(1));
        vm.stopPrank();
        treasury.paybackAll();
        uint256 owed = treasury.stakingOwed();

        vm.prank(keeper);
        treasury.sendToStaking();
        assertEq(staking.totalUsdcReceived(), owed);
        assertEq(treasury.stakingOwed(), 0);
        assertEq(treasury.available(), usdc.balanceOf(address(treasury)));
    }

    /// @dev The creator pays back 100 USDC once every Key counts, so staking is owed 1 USDC.
    function _oweStaking() private returns (uint256 owed) {
        _tcount();
        _return(990e6);
        vm.prank(creator);
        treasury.payback(100e6);
        owed = treasury.stakingOwed();
        assertEq(owed, 1e6);
    }

    /// @dev `caller`'s send to staking is refused, naming them, and leaves what is owed, the
    /// approval and every balance as they were.
    function _assertSendToStakingRefused(address caller) private {
        uint256 owed = treasury.stakingOwed();
        uint256 held = usdc.balanceOf(address(treasury));
        uint256 stakingHeld = usdc.balanceOf(address(staking));
        uint256 callerHeld = usdc.balanceOf(caller);
        uint256 received = staking.totalUsdcReceived();

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyKeeperOrSafe.selector, caller));
        treasury.sendToStaking();

        assertEq(treasury.stakingOwed(), owed, "still owed");
        assertEq(usdc.allowance(address(treasury), address(staking)), 0, "no approval");
        assertEq(usdc.balanceOf(address(treasury)), held, "the treasury's balance");
        assertEq(usdc.balanceOf(address(staking)), stakingHeld, "staking's balance");
        assertEq(usdc.balanceOf(caller), callerHeld, "the caller's balance");
        assertEq(staking.totalUsdcReceived(), received, "nothing deposited");
    }
}
