// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {V4PoolKey} from "../../src/interfaces/IUniswapV4PoolManager.sol";
import {KeyfleetForkFixture} from "./KeyfleetBaseFork.t.sol";
import {FULL_PIECE} from "../helpers/KeyfleetFixture.sol";

/// @notice v4-core's `IExtsload`, through which the PoolManager exposes its storage.
interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @notice The parts of a Uniswap v3 pool's state this test reads.
interface IUniswapV3PoolState {
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

/// @dev The shared REGENT buyer on a fork of Base, deployed from the committed Base manifest: the
/// real USDC/WETH v3 pool, the real PoolManager and the real WETH/REGENT v4 pool with its real
/// hook. It runs only when `BASE_RPC_URL` is set in the environment, and skips itself otherwise; the
/// URL is never printed.
///
/// It proves that the pinned v4 pool key names a pool that exists on the PoolManager, that a key
/// purchase only books the treasury's part and a piece delivers it as REGENT through both pools,
/// that a full 250 USDC piece stays under the 1% limit on the real pools, and that the protections
/// that exist hold: the buyer's callbacks answer only its own swap, and the purchase charges the
/// quote and keeps the buyer's highest price and deadline. The buyer takes no minimum and reads no
/// oracle; its only limit is the pools' own price move.
contract KeyfleetRegentBuyerForkTest is KeyfleetForkFixture {
    using stdStorage for StdStorage;

    address private constant BUYER = address(0xB0B0B0);
    address private constant PAYER = address(0x9A7E2);
    address private constant RECIPIENT = address(0x8EC1);
    /// @dev v4-core's `PoolManager` keeps `mapping(PoolId => Pool.State) _pools` at this slot.
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    /// @dev `Pool.State.liquidity` sits three slots after the state's first slot, `slot0`.
    uint256 private constant LIQUIDITY_OFFSET = 3;

    KeyfleetRegentBuyer private buyer;
    KeyfleetManager private classic;
    KeyfleetTreasury private treasury;

    function setUp() public {
        if (!_setUpFork(0)) return;
        _found(1);
        _advancePhase();
        buyer = factory.REGENT_BUYER();
        classic = _fleet(1);
        treasury = classic.TREASURY();
    }

    // --- the route -----------------------------------------------------------

    /// @dev The manifest's pinned key is the buyer's, its id is the one the buyer swaps on, and the
    /// PoolManager holds an initialised pool with liquidity under it.
    function test_thePinnedV4PoolKeyIsALivePoolOnThePoolManager() public view {
        V4PoolKey memory pinned = V4PoolKey({
            currency0: script.BASE_WETH(),
            currency1: script.BASE_REGENT(),
            fee: script.BASE_REGENT_POOL_FEE(),
            tickSpacing: script.BASE_REGENT_POOL_TICK_SPACING(),
            hooks: script.BASE_REGENT_POOL_HOOKS()
        });
        V4PoolKey memory used = buyer.v4PoolKey();
        assertEq(used.currency0, pinned.currency0, "currency0");
        assertEq(used.currency1, pinned.currency1, "currency1");
        assertEq(used.fee, pinned.fee, "fee");
        assertEq(used.tickSpacing, pinned.tickSpacing, "tick spacing");
        assertEq(used.hooks, pinned.hooks, "hooks");
        bytes32 poolId = keccak256(abi.encode(pinned));
        assertEq(buyer.V4_POOL_ID(), poolId, "the buyer swaps on the pinned pool");
        assertTrue(buyer.WETH_IS_V4_CURRENCY0(), "WETH sorts below REGENT");
        assertGt(pinned.hooks.code.length, 0, "the hook is deployed");

        assertGt(_sqrtPrice(poolId), 0, "the pool is initialised");
        assertGt(_liquidity(poolId), 0, "and has liquidity in range");

        V4PoolKey memory unhooked = pinned;
        unhooked.hooks = address(0);
        assertEq(_sqrtPrice(keccak256(abi.encode(unhooked))), 0, "a key differing only in its hook names no pool");
    }

    /// @dev The first leg is the pinned USDC/WETH pool at 0.05%, with liquidity in range.
    function test_theV3PoolIsTheUsdcWethPool() public view {
        assertEq(address(buyer.V3_POOL()), script.BASE_USDC_WETH_POOL(), "the pinned pool");
        assertEq(buyer.V3_POOL().token0(), script.BASE_WETH(), "WETH is token0");
        assertEq(buyer.V3_POOL().token1(), script.BASE_USDC(), "USDC is token1");
        assertFalse(buyer.USDC_IS_V3_TOKEN0(), "so the buyer swaps one for zero");
        assertEq(IUniswapV3PoolState(address(buyer.V3_POOL())).fee(), 500, "0.05%");
        assertGt(IUniswapV3PoolState(address(buyer.V3_POOL())).liquidity(), 0, "with liquidity in range");
    }

    // --- a purchase and a piece ------------------------------------------------

    /// @dev A purchase swaps nothing and books the quote's capital; the next piece sends it through
    /// both pools and the treasury receives the REGENT. Nothing stays in the buyer, no approval
    /// outlives the piece, and the protocol share stays in the manager.
    function test_aPurchaseBooksTheCapitalAndAPieceDeliversRegentToTheTreasury() public {
        KeyfleetPresets.PurchaseSplit memory split = classic.quote();
        assertGt(split.capital, 0, "a Classic sale sends capital to the treasury");

        uint256 poolUsdc = usdc.balanceOf(address(buyer.V3_POOL()));
        uint256[3] memory held = _buyerHoldings();
        uint256 price = _fund(classic, BUYER);
        vm.prank(BUYER);
        uint256 tokenId = classic.purchase(BUYER, price, block.timestamp, new bytes32[](0));
        assertEq(keys.ownerOf(tokenId), BUYER, "the key is sold");
        assertEq(classic.pendingConversion(), split.capital, "the capital is booked");
        assertEq(usdc.balanceOf(address(buyer.V3_POOL())), poolUsdc, "and nothing swapped");
        assertEq(regent.balanceOf(address(treasury)), 0, "no REGENT yet");

        vm.recordLogs();
        uint256 delivered = buyer.convert(FULL_PIECE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(delivered, 0, "the piece bought REGENT");
        assertEq(regent.balanceOf(address(treasury)), delivered, "for the treasury");
        assertEq(usdc.balanceOf(address(buyer.V3_POOL())) - poolUsdc, split.capital, "the capital went into v3");
        _assertBuyerEvent(logs, split.capital, delivered);

        uint256[3] memory after_ = _buyerHoldings();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(after_[i], held[i], "the buyer keeps nothing");
        }
        assertEq(classic.pendingConversion(), 0, "the booking is spent");
        assertEq(usdc.allowance(address(classic), address(buyer)), 0, "no approval outlives the piece");
        assertEq(usdc.balanceOf(address(classic)), classic.protocolShareOwed(), "the manager holds only the share");
        assertEq(classic.protocolShareOwed(), split.protocol, "which is the quote's");
        assertEq(usdc.balanceOf(address(treasury)), 0, "no USDC reaches the treasury unswapped");
    }

    /// @dev A full piece of 250 USDC goes through the real route under the 1% limit, measured on the
    /// pools' own prices, and the next piece waits 15 minutes.
    function test_aFullPieceStaysUnderTheLimitOnTheRealRoute() public {
        _book(classic, buyer.PIECE_USDC());
        uint256 v3Before = _v3SqrtPrice();
        uint256 v4Before = _sqrtPrice(buyer.V4_POOL_ID());
        uint256 regentOut = buyer.convert(FULL_PIECE);
        assertGt(regentOut, 0, "REGENT bought");
        assertGt(_v3SqrtPrice(), v3Before, "USDC in raises the v3 price, as WETH is token0");
        assertLt(_sqrtPrice(buyer.V4_POOL_ID()), v4Before, "WETH in lowers the v4 price, as WETH is currency0");
        assertEq(classic.pendingConversion(), 0);

        _book(classic, 1e6);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.PieceTooSoon.selector, block.timestamp + 15 minutes));
        buyer.convert(FULL_PIECE);
    }

    /// @dev A smaller piece moves the real route's prices less than a full one, so a fleet whose
    /// full piece would break the 1% limit still converts, and the next piece waits in proportion.
    function test_aSmallerPieceMovesTheRealRouteLessAndWaitsLess() public {
        _book(classic, 300e6);
        uint256 v4Before = _sqrtPrice(buyer.V4_POOL_ID());
        buyer.convert(50e6);
        uint256 smallMove = v4Before - _sqrtPrice(buyer.V4_POOL_ID());
        assertEq(classic.pendingConversion(), 250e6, "a 50 USDC piece");
        assertEq(buyer.nextPieceAt(), block.timestamp + 3 minutes, "waits a fifth of 15 minutes");

        vm.warp(buyer.nextPieceAt());
        v4Before = _sqrtPrice(buyer.V4_POOL_ID());
        buyer.convert(FULL_PIECE);
        uint256 fullMove = v4Before - _sqrtPrice(buyer.V4_POOL_ID());
        assertEq(classic.pendingConversion(), 0, "then a full piece");
        assertLt(smallMove * 4, fullMove, "the smaller piece moved the REGENT pool far less");
    }

    /// @dev The purchase charges exactly the quote, and refuses a price above the buyer's highest or
    /// a deadline passed, moving nothing.
    function test_thePurchaseKeepsTheQuoteTheHighestPriceAndTheDeadline() public {
        KeyfleetPresets.PurchaseSplit memory split = classic.quote();
        uint256 price = _fund(classic, BUYER);
        assertEq(split.protocol + split.capital + split.reserve + split.rebate, price, "the quote is the price");

        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.PriceAboveMax.selector, price, price - 1));
        classic.purchase(BUYER, price - 1, block.timestamp, new bytes32[](0));
        uint256 passed = block.timestamp - 1;
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.Expired.selector, passed));
        classic.purchase(BUYER, price, passed, new bytes32[](0));
        assertEq(usdc.balanceOf(BUYER), price, "nothing moved");
        assertEq(classic.totalMinted(), 0, "and nothing sold");
        assertEq(regent.balanceOf(address(treasury)), 0, "or bought");

        uint256 tokenId = keys.tokenIdOf(classic.FLEET_ID(), 1);
        vm.expectEmit(true, true, true, true, address(classic));
        emit KeyfleetManager.Purchased(
            tokenId, BUYER, BUYER, price, split.protocol, split.capital, split.reserve, split.rebate
        );
        vm.prank(BUYER);
        classic.purchase(BUYER, price, block.timestamp, new bytes32[](0));
        assertEq(usdc.balanceOf(BUYER), 0, "exactly the price was charged");
    }

    // --- the buyer on its own --------------------------------------------------

    /// @dev The real v3 pool and the real PoolManager reach the buyer's callbacks only during its own
    /// piece: outside one, each is refused.
    function test_theCallbacksRefuseTheRealPoolsOutsideAPiece() public {
        address v3Pool = address(buyer.V3_POOL());
        address poolManager = address(buyer.POOL_MANAGER());

        vm.prank(v3Pool);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, v3Pool));
        buyer.uniswapV3SwapCallback(0, 1, "");

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, poolManager));
        buyer.unlockCallback(abi.encode(uint256(1), RECIPIENT));
    }

    // --- helpers ---------------------------------------------------------------

    /// @dev The buyer's USDC, WETH and REGENT.
    function _buyerHoldings() private view returns (uint256[3] memory held) {
        held[0] = usdc.balanceOf(address(buyer));
        held[1] = buyer.WETH().balanceOf(address(buyer));
        held[2] = regent.balanceOf(address(buyer));
    }

    /// @dev The buyer reported the manager paying `usdcIn` for `regentOut` delivered to the treasury.
    function _assertBuyerEvent(Vm.Log[] memory logs, uint256 usdcIn, uint256 regentOut) private view {
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(buyer) || log.topics[0] != KeyfleetRegentBuyer.RegentBought.selector) continue;
            assertEq(address(uint160(uint256(log.topics[1]))), address(classic), "the manager paid");
            assertEq(address(uint160(uint256(log.topics[2]))), address(treasury), "for the treasury");
            (uint256 paid, uint256 wethMid, uint256 out) = abi.decode(log.data, (uint256, uint256, uint256));
            assertEq(paid, usdcIn, "the capital");
            assertGt(wethMid, 0, "through WETH");
            assertEq(out, regentOut, "the REGENT delivered");
            return;
        }
        revert("no RegentBought from the buyer");
    }

    /// @dev Books `amount` USDC in `fleet` as a purchase would, held by the manager, and queues it.
    function _book(KeyfleetManager fleet, uint256 amount) private {
        deal(address(usdc), address(fleet), usdc.balanceOf(address(fleet)) + amount);
        stdstore.target(address(fleet)).sig("pendingConversion()").checked_write(fleet.pendingConversion() + amount);
        vm.prank(address(fleet));
        buyer.enqueue();
    }

    /// @dev The v3 pool's square-root price.
    function _v3SqrtPrice() private view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = buyer.V3_POOL().slot0();
    }

    /// @dev A pool's price, read from the PoolManager's storage as v4-core's
    /// `StateLibrary.getSlot0` reads it: the low 160 bits of the state's first slot. Zero for a key
    /// that names no initialised pool.
    function _sqrtPrice(bytes32 poolId) private view returns (uint160) {
        return uint160(uint256(IExtsload(address(buyer.POOL_MANAGER())).extsload(_stateSlot(poolId))));
    }

    /// @dev A pool's in-range liquidity, as `StateLibrary.getLiquidity` reads it.
    function _liquidity(bytes32 poolId) private view returns (uint128) {
        bytes32 slot = bytes32(uint256(_stateSlot(poolId)) + LIQUIDITY_OFFSET);
        return uint128(uint256(IExtsload(address(buyer.POOL_MANAGER())).extsload(slot)));
    }

    function _stateSlot(bytes32 poolId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }
}
