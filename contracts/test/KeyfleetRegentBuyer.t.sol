// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {V4PoolKey} from "../src/interfaces/IUniswapV4PoolManager.sol";
import {FULL_PIECE, KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// @dev Calls the buyer from inside a swap, as a pool's hook could.
contract CallbackCaller {
    function call(address target, bytes calldata data) external {
        (bool ok, bytes memory reason) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

/// @dev A registered fleet manager reduced to what the buyer asks of one: booked USDC, and a piece
/// of it on request, approved to the buyer. For a buyer other than the factory's.
contract PieceManager {
    IERC20 private immutable USDC;
    KeyfleetRegentBuyer private immutable BUYER;
    address private immutable TREASURY;
    uint256 public pendingConversion;

    constructor(IERC20 usdc, KeyfleetRegentBuyer buyer, address treasury) {
        USDC = usdc;
        BUYER = buyer;
        TREASURY = treasury;
    }

    function book(uint256 amount) external {
        pendingConversion += amount;
        BUYER.enqueue();
    }

    function takePiece(uint256 limit) external returns (uint256 amount, address recipient) {
        require(msg.sender == address(BUYER), "only the buyer");
        amount = Math.min(pendingConversion, limit);
        pendingConversion -= amount;
        USDC.approve(address(BUYER), amount);
        recipient = TREASURY;
    }
}

/// @dev The shared REGENT buyer: purchases only book the treasury's USDC; pieces of at most 250 USDC,
/// smaller on request, run no faster than 250 USDC per 15 minutes across every fleet, fleets take
/// turns, and a piece that moves the route's price by more than 1% reverts.
contract KeyfleetRegentBuyerTest is KeyfleetFixture {
    address private stranger = makeAddr("stranger");

    function setUp() public {
        _setUpFixture();
    }

    // --- route -----------------------------------------------------------------

    function test_RouteIsFixedAtDeployment() public view {
        assertEq(address(regentBuyer.KEYS()), address(keys));
        assertEq(address(regentBuyer.USDC()), address(usdc));
        assertEq(address(regentBuyer.WETH()), address(weth));
        assertEq(address(regentBuyer.REGENT()), address(regent));
        assertEq(address(regentBuyer.V3_POOL()), address(v3Pool));
        assertEq(address(regentBuyer.POOL_MANAGER()), address(poolManager));
        assertTrue(regentBuyer.USDC_IS_V3_TOKEN0());
        assertTrue(regentBuyer.WETH_IS_V4_CURRENCY0());
        V4PoolKey memory key = regentBuyer.v4PoolKey();
        assertEq(key.currency0, address(weth));
        assertEq(key.currency1, address(regent));
        assertEq(key.fee, DYNAMIC_FEE);
        assertEq(key.tickSpacing, TICK_SPACING);
        assertEq(key.hooks, address(0));
        assertEq(regentBuyer.V4_POOL_ID(), keccak256(abi.encode(key)));
        assertEq(regentBuyer.PIECE_USDC(), 250e6, "250 USDC a piece");
        assertEq(regentBuyer.PIECE_INTERVAL(), 15 minutes, "one piece every 15 minutes");
        assertEq(regentBuyer.MAX_PRICE_MOVE_BPS(), 100, "1% at most");
    }

    function test_RouteRefusesAnAddressWithoutCode() public {
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.poolManager = address(0x1234);
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route, keys);

        route = _bindings().route;
        route.weth = address(0);
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route, keys);
    }

    function test_RouteRefusesAV3PoolOfOtherTokens() public {
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v3Pool = address(new MockUniswapV3Pool(address(usdc), address(regent), 1e18, 1e18));
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route, keys);
    }

    function test_RouteRefusesAV4PoolOfOtherCurrencies() public {
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v4Pool.currency1 = address(usdc);
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route, keys);
    }

    // --- booking ---------------------------------------------------------------

    /// @dev Invariant: a purchase swaps nothing. The treasury's part stays in the manager, booked
    /// as `pendingConversion`, and the fleet joins the queue once.
    function test_APurchaseSwapsNothingAndBooksTheTreasurysPart() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 first = fleet.nextPrice();
        vm.recordLogs();
        _buy(fleet, stranger);
        assertEq(_queuedIn(vm.getRecordedLogs(), address(fleet)), 1, "the first purchase queues the fleet");
        uint256 second = fleet.nextPrice();
        vm.recordLogs();
        _buy(fleet, stranger);
        assertEq(_queuedIn(vm.getRecordedLogs(), address(fleet)), 0, "a queued fleet is not queued again");

        uint256 booked = first - first / 10 + second - second / 10;
        assertEq(fleet.pendingConversion(), booked, "the treasury's part is booked");
        assertEq(usdc.balanceOf(address(fleet)), booked + fleet.protocolShareOwed(), "and held by the manager");
        assertEq(fleet.accountedBalance(address(usdc)), usdc.balanceOf(address(fleet)), "with a purpose");
        assertEq(usdc.balanceOf(address(v3Pool)), 0, "nothing reached the pool");
        assertEq(regent.balanceOf(address(fleet.TREASURY())), 0, "no REGENT yet");
        assertEq(usdc.balanceOf(address(fleet.TREASURY())), 0, "and no USDC in the treasury");
        assertEq(regentBuyer.queueLength(), 1, "queued once");
        assertEq(regentBuyer.nextInQueue(), address(fleet));
        _assertBuyerEmpty();
    }

    /// @dev Invariant: a Cascade level's released surplus joins the same queue.
    function test_ACascadeLevelReleaseIsQueued() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buy(fleet, stranger);
        assertEq(fleet.pendingConversion(), 0, "a Cascade purchase only fills the reserve");
        assertEq(regentBuyer.queueLength(), 0, "so the fleet is not queued");

        uint256 reserve = fleet.cascadeReserve();
        uint256 price = fleet.nextPrice();
        vm.recordLogs();
        _buy(fleet, stranger);
        assertEq(_queuedIn(vm.getRecordedLogs(), address(fleet)), 1, "the release queues the fleet");
        assertEq(fleet.pendingConversion(), reserve + price - price / 10, "level 1's whole reserve is booked");
        assertEq(fleet.cascadeReserve(), 0);
        assertEq(regentBuyer.nextInQueue(), address(fleet));

        regentBuyer.convert(FULL_PIECE);
        assertEq(regent.balanceOf(address(fleet.TREASURY())), _regentFor(reserve + price - price / 10));
        assertEq(fleet.pendingConversion(), 0);
    }

    /// @dev Invariant: booked USDC is never the treasury's to split, spend or sort as surplus.
    function test_BookedUsdcNeverReachesTheTreasurysSplit() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        assertEq(fleet.pendingConversion(), 900e6, "the creator's key books 900 USDC");
        assertEq(fleet.surplus(address(usdc)), 0, "none of it is surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 0, "so none is sorted to the treasury");

        _mature();
        uint256 runAt = fleet.TREASURY().nextRunAt();
        if (block.timestamp < runAt) vm.warp(runAt);
        assertEq(fleet.matureKeys(), 1, "the creator's key takes part");
        fleet.TREASURY().runDailySplit();
        assertEq(usdc.balanceOf(address(fleet.REWARDS())), 0, "the split shared no USDC");
        assertEq(fleet.pendingConversion(), 900e6, "the booking is untouched");
        assertEq(usdc.balanceOf(address(fleet.TREASURY())), 0);
    }

    function test_OnlyARegisteredManagerJoinsTheQueue() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.NotManager.selector, stranger));
        regentBuyer.enqueue();
    }

    function test_OnlyTheBuyerTakesAPiece() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        vm.prank(stranger);
        vm.expectRevert(KeyfleetManager.OnlyRegentBuyer.selector);
        fleet.takePiece(FULL_PIECE);
    }

    // --- pieces ----------------------------------------------------------------

    function test_ConvertTurnsOnePieceIntoRegentForTheTreasury() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        uint256 booked = fleet.pendingConversion();

        vm.expectEmit(address(regentBuyer));
        emit KeyfleetRegentBuyer.RegentBought(
            address(fleet), address(fleet.TREASURY()), booked, booked * 4e8, _regentFor(booked)
        );
        vm.prank(stranger);
        uint256 out = regentBuyer.convert(FULL_PIECE);

        assertEq(out, _regentFor(booked));
        assertEq(regent.balanceOf(address(fleet.TREASURY())), out, "REGENT goes to the treasury");
        assertEq(fleet.pendingConversion(), 0);
        assertEq(usdc.balanceOf(address(fleet)), fleet.protocolShareOwed(), "the 10% share is untouched");
        assertEq(usdc.allowance(address(fleet), address(regentBuyer)), 0, "no allowance is left");
        assertEq(regentBuyer.queueLength(), 0, "and the fleet leaves the queue");
        assertEq(regentBuyer.nextPieceAt(), block.timestamp + _waitFor(booked), "the wait matches the piece");
        _assertBuyerEmpty();
        assertEq(poolManager.delta(address(weth)), 0);
        assertEq(poolManager.delta(address(regent)), 0);
    }

    /// @dev Invariant: a piece is at most 250 USDC; the rest stays booked and the fleet goes back in
    /// line.
    function test_APieceIsAtMost250Usdc() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        regentBuyer.convert(FULL_PIECE);
        assertEq(usdc.balanceOf(address(v3Pool)), 250e6, "one piece of 250 USDC");
        assertEq(fleet.pendingConversion(), 650e6, "the rest stays booked");
        assertEq(regentBuyer.nextInQueue(), address(fleet), "and waits its turn again");

        _convertAll();
        assertEq(regent.balanceOf(address(fleet.TREASURY())), _regentFor(900e6), "four pieces in all");
        assertEq(fleet.pendingConversion(), 0);
        assertEq(regentBuyer.queueLength(), 0);
    }

    /// @dev Invariant: a full piece makes every fleet wait 15 minutes, so never two in one block.
    function test_AFullPieceMakesEveryFleetWaitFifteenMinutes() public {
        _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        KeyfleetManager syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buy(syndicate, stranger);
        assertEq(regentBuyer.nextPieceAt(), 0, "the first piece may run at once");

        regentBuyer.convert(FULL_PIECE);
        uint256 next = block.timestamp + 15 minutes;
        assertEq(regentBuyer.nextPieceAt(), next);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.PieceTooSoon.selector, next));
        regentBuyer.convert(FULL_PIECE);

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.PieceTooSoon.selector, next));
        regentBuyer.convert(FULL_PIECE);
        assertEq(syndicate.pendingConversion(), Q_SYNDICATE_BOOKED, "the other fleet waits too");

        vm.warp(next);
        regentBuyer.convert(FULL_PIECE);
        assertEq(syndicate.pendingConversion(), 0, "its piece runs once the wait is over");
    }

    /// @dev Invariant: whatever the time between them and however small the piece, two pieces never
    /// run in the same block.
    function testFuzz_NeverTwoPiecesInOneBlock(uint256 gap, uint256 maxUsdc) public {
        KeyfleetManager classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buy(classic, stranger);
        _buy(syndicate, stranger);
        vm.warp(block.timestamp + bound(gap, 0, 365 days));
        regentBuyer.convert(bound(maxUsdc, 1, type(uint256).max));
        vm.expectPartialRevert(KeyfleetRegentBuyer.PieceTooSoon.selector);
        regentBuyer.convert(FULL_PIECE);
    }

    /// @dev Invariant: fleets take turns, one piece each, whatever their bookings.
    function test_FleetsTakeTurns() public {
        KeyfleetManager big = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        KeyfleetManager small = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);

        _convertOne();
        assertEq(big.pendingConversion(), 650e6, "the first fleet's first piece");
        assertEq(regentBuyer.nextInQueue(), address(small), "then the second fleet");
        _convertOne();
        assertEq(small.pendingConversion(), 0, "whose single piece empties it");
        assertEq(regentBuyer.nextInQueue(), address(big), "then the first again");
        assertEq(regentBuyer.queueLength(), 1);
    }

    /// @dev Invariant: a fleet whose USDC will not move, for instance because USDC's issuer froze its
    /// manager, is skipped with its booking whole and waits at the back; the clock does not move, so
    /// the next fleet converts straight away.
    function test_AFleetWhoseUsdcWillNotMoveIsSkippedAndTheNextConverts() public {
        KeyfleetManager frozen = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        KeyfleetManager next = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 frozenBooked = frozen.pendingConversion();
        uint256 nextBooked = next.pendingConversion();
        usdc.freeze(address(frozen));
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);

        vm.expectEmit(address(regentBuyer));
        emit KeyfleetRegentBuyer.PieceSkipped(address(frozen));
        assertEq(regentBuyer.convert(FULL_PIECE), 0, "nothing is bought for it");
        assertEq(frozen.pendingConversion(), frozenBooked, "it keeps its whole booking");
        assertEq(usdc.allowance(address(frozen), address(regentBuyer)), 0, "and approves nothing");
        assertEq(regentBuyer.nextPieceAt(), opensAt, "the clock does not move");
        assertEq(regentBuyer.nextInQueue(), address(next), "the next fleet is at the front");
        assertEq(regentBuyer.queueLength(), 2, "and the skipped one waits at the back");
        _assertBuyerEmpty();

        assertEq(regentBuyer.convert(FULL_PIECE), _regentFor(nextBooked), "the next fleet converts at once");
        assertEq(next.pendingConversion(), 0);
        assertEq(regentBuyer.nextInQueue(), address(frozen));
        assertEq(frozen.pendingConversion(), frozenBooked);
    }

    /// @dev Invariant: a caller cannot make a working fleet be skipped by sending too little gas;
    /// the call either converts its piece or reverts with the fleet's booking and place untouched.
    function testFuzz_NoGasLimitMakesAWorkingFleetBeSkipped(uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 100_000, 3_000_000);
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 booked = fleet.pendingConversion();
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);

        vm.recordLogs();
        (bool ok,) = address(regentBuyer).call{gas: gasLimit}(abi.encodeCall(KeyfleetRegentBuyer.convert, (FULL_PIECE)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != KeyfleetRegentBuyer.PieceSkipped.selector, "never skipped");
        }
        if (ok) {
            assertEq(fleet.pendingConversion(), 0, "converted");
        } else {
            assertEq(fleet.pendingConversion(), booked, "or untouched");
            assertEq(regentBuyer.nextInQueue(), address(fleet), "in its place");
        }
    }

    function test_ConvertWithTooLittleGasForTheHandOverReverts() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
        vm.expectRevert(KeyfleetRegentBuyer.NotEnoughGas.selector);
        regentBuyer.convert{gas: 300_000}(FULL_PIECE);
        assertEq(regentBuyer.nextInQueue(), address(fleet));
    }

    function test_ConvertWithNothingQueuedReverts() public {
        vm.expectRevert(KeyfleetRegentBuyer.NothingQueued.selector);
        regentBuyer.convert(FULL_PIECE);
    }

    // --- smaller pieces --------------------------------------------------------

    /// @dev Invariant: anyone may take a smaller piece; it converts only that much, the fleet keeps
    /// the rest and its turn comes round again, and the wait shrinks in proportion.
    function test_ASmallerPieceConvertsLessAndWaitsInProportion() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        vm.prank(stranger);
        uint256 out = regentBuyer.convert(50e6);
        assertEq(out, _regentFor(50e6), "a 50 USDC piece");
        assertEq(regent.balanceOf(address(fleet.TREASURY())), out, "for the treasury");
        assertEq(fleet.pendingConversion(), 850e6, "the rest stays booked");
        assertEq(regentBuyer.nextInQueue(), address(fleet), "and waits its turn again");
        uint256 next = block.timestamp + 3 minutes;
        assertEq(regentBuyer.nextPieceAt(), next, "a fifth of a piece waits a fifth of 15 minutes");

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.PieceTooSoon.selector, next));
        regentBuyer.convert(1);
        vm.warp(next);
        regentBuyer.convert(FULL_PIECE);
        assertEq(fleet.pendingConversion(), 600e6, "then a full piece");
    }

    /// @dev Invariant: asking for more than a piece takes a piece.
    function test_AskingForMoreThanAPieceTakesOnePiece() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        regentBuyer.convert(type(uint256).max);
        assertEq(fleet.pendingConversion(), 650e6, "250 USDC and no more");
        assertEq(regentBuyer.nextPieceAt(), block.timestamp + 15 minutes);
    }

    /// @dev Invariant: a request under 1 USDC, zero included, converts 1 USDC and holds the next
    /// piece back 4 seconds, so a run of tiny requests cannot keep full pieces out.
    function test_ATinyRequestConvertsTheMinimumPiece() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        uint256 out = regentBuyer.convert(1);
        assertEq(out, _regentFor(1e6), "1 USDC, not one atomic unit");
        assertEq(fleet.pendingConversion(), 899e6);
        // 1 USDC is 3.6 seconds of the rate, rounded up to 4.
        assertEq(regentBuyer.nextPieceAt(), block.timestamp + 4, "waits 4 seconds");

        vm.warp(block.timestamp + 4);
        regentBuyer.convert(0);
        assertEq(fleet.pendingConversion(), 898e6, "zero asks for the minimum too");
    }

    /// @dev Invariant: a piece that would leave the fleet less than the minimum booked takes the
    /// rest with it, so no booking is ever left too small to buy anything (audit KF-A-01).
    function test_APieceThatWouldLeaveUnderTheMinimumTakesTheRest() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        for (uint256 i; i < 3; ++i) {
            if (i != 0) vm.warp(regentBuyer.nextPieceAt());
            regentBuyer.convert(FULL_PIECE);
        }
        assertEq(fleet.pendingConversion(), 150e6);

        vm.warp(regentBuyer.nextPieceAt());
        regentBuyer.convert(150e6 - 1);
        assertEq(fleet.pendingConversion(), 0, "not one atomic unit left behind");
        assertEq(regentBuyer.nextPieceAt(), block.timestamp + 540, "150 USDC waits 9 minutes");
        assertEq(regentBuyer.queueLength(), 0, "and the fleet leaves the queue");
    }

    /// @dev Invariant: a fleet whose full piece moves the price too far is not stuck at the front;
    /// a smaller piece, which moves it less, converts.
    function test_APieceRefusedAsTooLargeConvertsSmaller() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1000e6);
        // The stand-in pool moves a set amount per swap: a full piece moves 1.02%.
        poolManager.setSqrtMoveBps(51);
        vm.expectPartialRevert(KeyfleetRegentBuyer.PriceMoved.selector);
        regentBuyer.convert(FULL_PIECE);
        // A fifth of the piece moves a fifth as far.
        poolManager.setSqrtMoveBps(10);
        regentBuyer.convert(50e6);
        assertEq(fleet.pendingConversion(), 850e6, "the smaller piece converted");
    }

    /// @dev Invariant: whatever pieces anyone asks for and whenever, USDC converts no faster than
    /// 250 per 15 minutes: everything before the latest piece fits inside the time it has taken.
    function testFuzz_NeverFasterThan250UsdcPer15Minutes(uint256[8] memory asks, uint256[8] memory gaps) public {
        (KeyfleetRegentBuyer buyer_, PieceManager manager) = _standalone(_bindings().route);
        manager.book(100_000e6);
        uint256 first;
        uint256 converted;
        uint256 lastPiece;
        for (uint256 i = 0; i < asks.length; ++i) {
            vm.warp(Math.max(block.timestamp + bound(gaps[i], 0, 30 minutes), buyer_.nextPieceAt()));
            uint256 before = manager.pendingConversion();
            buyer_.convert(bound(asks[i], 1, 1000e6));
            lastPiece = before - manager.pendingConversion();
            if (i == 0) first = block.timestamp;
            converted += lastPiece;
            assertLe(lastPiece, 250e6, "never more than a piece");
            assertEq(buyer_.nextPieceAt(), block.timestamp + _waitFor(lastPiece), "the wait matches the piece");
        }
        assertLe((converted - lastPiece) * 15 minutes, (block.timestamp - first) * 250e6, "within the rate");
    }

    // --- the 1% limit ----------------------------------------------------------

    /// @dev Invariant: a piece that moves the route's price by more than 1% reverts, and the fleet
    /// keeps its booking, its place and the clock.
    function test_APieceThatMovesThePriceMoreThanOnePercentReverts() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        uint256 booked = fleet.pendingConversion();

        // 0.51% on the square-root price is a 1.0226% move of the price.
        poolManager.setSqrtMoveBps(51);
        vm.expectPartialRevert(KeyfleetRegentBuyer.PriceMoved.selector);
        regentBuyer.convert(FULL_PIECE);
        assertEq(fleet.pendingConversion(), booked, "the booking stays");
        assertEq(regentBuyer.nextInQueue(), address(fleet), "and so does its place");
        assertEq(regentBuyer.nextPieceAt(), 0, "and the clock");

        // The two legs' moves multiply: 0.25% and 0.25% on the square roots is 1.0038% in all.
        poolManager.setSqrtMoveBps(25);
        v3Pool.setSqrtMoveBps(25);
        vm.expectPartialRevert(KeyfleetRegentBuyer.PriceMoved.selector);
        regentBuyer.convert(FULL_PIECE);

        // 0.49% on the square-root price is 0.9824%, which is allowed.
        v3Pool.setSqrtMoveBps(0);
        poolManager.setSqrtMoveBps(49);
        regentBuyer.convert(FULL_PIECE);
        assertEq(fleet.pendingConversion(), 0);
        assertEq(regent.balanceOf(address(fleet.TREASURY())), _regentFor(booked));
    }

    /// @dev Invariant: the price falling counts as much as rising, on either leg.
    function test_TheLimitCountsAFallAsMuchAsARise() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        // A 0.51% fall of the square-root price is a 1.03% move of the price, measured larger over smaller.
        poolManager.setSqrtMoveBps(-51);
        vm.expectPartialRevert(KeyfleetRegentBuyer.PriceMoved.selector);
        regentBuyer.convert(FULL_PIECE);
        // A rise on one leg and a fall on the other still add up.
        poolManager.setSqrtMoveBps(-25);
        v3Pool.setSqrtMoveBps(25);
        vm.expectPartialRevert(KeyfleetRegentBuyer.PriceMoved.selector);
        regentBuyer.convert(FULL_PIECE);
        // A 0.49% fall is under the limit.
        v3Pool.setSqrtMoveBps(0);
        poolManager.setSqrtMoveBps(-49);
        regentBuyer.convert(FULL_PIECE);
        assertEq(fleet.pendingConversion(), 0);
    }

    // --- faults ----------------------------------------------------------------

    function test_ConvertRefusesAPartialFillOnTheUsdcLeg() public {
        uint256 booked = _bookClassic();
        v3Pool.setFillBps(9000);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, booked, booked * 9 / 10));
        regentBuyer.convert(FULL_PIECE);
    }

    function test_ConvertRefusesAPartialFillOnTheWethLeg() public {
        uint256 booked = _bookClassic();
        poolManager.setFillBps(9000);
        uint256 wethIn = booked * 4e8;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, wethIn, wethIn * 9 / 10));
        regentBuyer.convert(FULL_PIECE);
    }

    function test_ConvertRefusesAV3PoolAskingForMoreThanTheSwap() public {
        uint256 booked = _bookClassic();
        v3Pool.setOvercharge(1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, booked, booked + 1));
        regentBuyer.convert(FULL_PIECE);
    }

    function test_ConvertPaysTheV3PoolOnlyOnce() public {
        _bookClassic();
        v3Pool.setCallbackTwice(true);
        // The first callback pays and clears what is owed; a second one is refused outright.
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(v3Pool)));
        regentBuyer.convert(FULL_PIECE);
    }

    function test_ConvertRefusesASwapThatPaysNoRegent() public {
        uint256 booked = _bookClassic();
        // The PoolManager reports the WETH spent and nothing out.
        poolManager.setReportedDelta(-int256(booked * 4e8) << 128);
        vm.expectRevert(KeyfleetRegentBuyer.NothingBought.selector);
        regentBuyer.convert(FULL_PIECE);
    }

    function test_ConvertRefusesAV3SwapThatPaysNoWeth() public {
        MockUniswapV3Pool dry = new MockUniswapV3Pool(address(usdc), address(weth), 0, 0);
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v3Pool = address(dry);
        (KeyfleetRegentBuyer buyer_, PieceManager manager) = _standalone(route);
        manager.book(10e6);
        vm.expectRevert(KeyfleetRegentBuyer.NothingBought.selector);
        buyer_.convert(FULL_PIECE);
    }

    function test_ConvertWorksWithTheTokensInTheOtherOrder() public {
        MockUniswapV3Pool flippedV3 = new MockUniswapV3Pool(address(weth), address(usdc), USDC_PER_WETH, WETH_PER_USDC);
        MockPoolManager flippedManager = new MockPoolManager(address(weth), REGENT_PER_WETH, WETH_PER_REGENT);
        weth.mint(address(flippedV3), 1e36);
        regent.mint(address(flippedManager), 1e45);
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v3Pool = address(flippedV3);
        route.poolManager = address(flippedManager);
        route.v4Pool.currency0 = address(regent);
        route.v4Pool.currency1 = address(weth);
        (KeyfleetRegentBuyer flipped, PieceManager manager) = _standalone(route);
        assertFalse(flipped.USDC_IS_V3_TOKEN0());
        assertFalse(flipped.WETH_IS_V4_CURRENCY0());

        manager.book(7e6);
        uint256 out = flipped.convert(FULL_PIECE);
        assertEq(out, _regentFor(7e6));
        assertEq(regent.balanceOf(stranger), out);
        assertEq(weth.balanceOf(address(flipped)), 0);
        assertEq(usdc.balanceOf(address(flipped)), 0);
    }

    // --- callbacks -------------------------------------------------------------

    function test_V3CallbackRefusesAnyoneButThePool() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(this)));
        regentBuyer.uniswapV3SwapCallback(1, 0, "");
    }

    function test_V3CallbackRefusesThePoolOutsideAPiece() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        vm.prank(address(v3Pool));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(v3Pool)));
        regentBuyer.uniswapV3SwapCallback(1, 0, "");
    }

    function test_UnlockCallbackRefusesAnyoneButThePoolManager() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(this)));
        regentBuyer.unlockCallback(abi.encode(uint256(1), stranger));
    }

    function test_UnlockCallbackRefusesThePoolManagerOutsideAPiece() public {
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(poolManager)));
        regentBuyer.unlockCallback(abi.encode(uint256(1), stranger));
    }

    function test_TheHookCannotRunASecondPieceInsideAPiece() public {
        KeyfleetManager classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buy(classic, stranger);
        _buy(syndicate, stranger);
        CallbackCaller hook = new CallbackCaller();
        poolManager.setHook(
            address(hook),
            abi.encodeCall(
                CallbackCaller.call, (address(regentBuyer), abi.encodeCall(KeyfleetRegentBuyer.convert, (FULL_PIECE)))
            )
        );
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        regentBuyer.convert(FULL_PIECE);
    }

    function test_TheHookCannotCallTheBuyersCallbacks() public {
        _bookClassic();
        CallbackCaller hook = new CallbackCaller();
        poolManager.setHook(
            address(hook),
            abi.encodeCall(
                CallbackCaller.call,
                (address(regentBuyer), abi.encodeCall(KeyfleetRegentBuyer.uniswapV3SwapCallback, (int256(1), 0, "")))
            )
        );
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(hook)));
        regentBuyer.convert(FULL_PIECE);
    }

    /// @dev Invariant: a hook that buys a key of the fleet being served, inside its piece, leaves every
    /// unit booked: the new booking waits in the queue and the manager holds exactly its purposes.
    function test_AHookThatBuysInsideAPieceKeepsEveryUnitBooked() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        uint256 price = fleet.nextPrice();
        CallbackCaller hook = new CallbackCaller();
        usdc.mint(address(hook), price);
        vm.prank(address(hook));
        usdc.approve(address(fleet), price);
        poolManager.setHook(
            address(hook),
            abi.encodeCall(
                CallbackCaller.call,
                (
                    address(fleet),
                    abi.encodeCall(KeyfleetManager.purchase, (stranger, price, block.timestamp, new bytes32[](0)))
                )
            )
        );
        regentBuyer.convert(FULL_PIECE);

        assertEq(fleet.totalMinted(), 2, "the hook's purchase went through");
        assertEq(fleet.pendingConversion(), price - price / 10, "and is booked");
        assertEq(regentBuyer.nextInQueue(), address(fleet), "with the fleet back in the queue");
        assertEq(regentBuyer.queueLength(), 1, "once");
        assertEq(usdc.balanceOf(address(fleet)), fleet.accountedBalance(address(usdc)), "every unit has a purpose");
    }

    function testFuzz_EveryPieceIsAtTheMarketAndKeepsNothing(uint256 amount, uint256 maxUsdc) public {
        amount = bound(amount, 1, 20 * 250e6);
        maxUsdc = bound(maxUsdc, 25e6, type(uint256).max);
        (KeyfleetRegentBuyer buyer_, PieceManager manager) = _standalone(_bindings().route);
        manager.book(amount);
        uint256 converted;
        while (buyer_.queueLength() != 0) {
            uint256 opensAt = buyer_.nextPieceAt();
            if (block.timestamp < opensAt) vm.warp(opensAt);
            uint256 before = manager.pendingConversion();
            uint256 out = buyer_.convert(maxUsdc);
            uint256 piece = before - manager.pendingConversion();
            assertLe(piece, Math.min(maxUsdc, 250e6), "never more than asked, nor than a piece");
            assertEq(out, _regentFor(piece), "at the market");
            converted += piece;
        }
        assertEq(converted, amount, "every unit converted");
        assertEq(regent.balanceOf(stranger), _regentFor(amount));
        assertEq(usdc.balanceOf(address(buyer_)), 0);
        assertEq(weth.balanceOf(address(buyer_)), 0);
    }

    // --- helpers ---------------------------------------------------------------

    /// @dev What one Syndicate #1 key books: 90% of its first price.
    uint256 private constant Q_SYNDICATE_BOOKED = 9e6;

    /// @dev The wait after a piece of `usdcIn`: 15 minutes for a full piece, in proportion, rounded up.
    function _waitFor(uint256 usdcIn) private pure returns (uint256) {
        return Math.ceilDiv(15 minutes * usdcIn, 250e6);
    }

    /// @dev Books one Classic #1 key's treasury part and returns it.
    function _bookClassic() private returns (uint256 booked) {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, stranger);
        booked = fleet.pendingConversion();
    }

    /// @dev Runs the next piece, once its time has come.
    function _convertOne() private {
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
        regentBuyer.convert(FULL_PIECE);
    }

    /// @dev A buyer on `route` with one registered manager, holding USDC to book, whose REGENT goes
    /// to `stranger`.
    function _standalone(KeyfleetRegentBuyer.Route memory route)
        private
        returns (KeyfleetRegentBuyer buyer_, PieceManager manager)
    {
        _openCreation();
        buyer_ = new KeyfleetRegentBuyer(route, keys);
        manager = new PieceManager(usdc, buyer_, stranger);
        vm.prank(safe);
        keys.addFactory(address(this));
        keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, address(manager), bytes32(0), 0);
        usdc.mint(address(manager), 1e15);
    }

    /// @dev How many `Queued` events for `manager` the buyer emitted among `logs`.
    function _queuedIn(Vm.Log[] memory logs, address manager) private view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(regentBuyer) && logs[i].topics[0] == KeyfleetRegentBuyer.Queued.selector
                    && logs[i].topics[1] == bytes32(uint256(uint160(manager)))
            ) ++count;
        }
    }

    function _assertBuyerEmpty() private view {
        assertEq(usdc.balanceOf(address(regentBuyer)), 0);
        assertEq(weth.balanceOf(address(regentBuyer)), 0);
        assertEq(regent.balanceOf(address(regentBuyer)), 0);
        assertEq(weth.allowance(address(regentBuyer), address(poolManager)), 0);
    }
}
