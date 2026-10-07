// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {V4PoolKey} from "../../src/interfaces/IUniswapV4PoolManager.sol";
import {KeyfleetForkFixture} from "./KeyfleetBaseFork.t.sol";

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
/// purchase delivers REGENT to the fleet's treasury through both pools, and that the protections
/// that exist hold: the buyer's own (it spends exactly the USDC it is given or nothing, it refuses a
/// buy of nothing, and its callbacks answer only its own swap) and the purchase's (the quote is
/// what is charged, and the buyer's highest price and deadline are kept). The buyer itself takes no
/// minimum and reads no oracle: the founder chose a plain swap at the pool's price.
contract KeyfleetRegentBuyerForkTest is KeyfleetForkFixture {
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

    // --- a purchase ----------------------------------------------------------

    /// @dev A purchase sends the quote's capital through both pools and the treasury receives exactly
    /// what a direct buy of that USDC would have given it at that moment. Nothing stays in the buyer,
    /// no approval outlives the purchase, and the protocol share stays in the manager.
    function test_aPurchaseDeliversRegentToTheTreasury() public {
        KeyfleetPresets.PurchaseSplit memory split = classic.quote();
        assertGt(split.capital, 0, "a Classic sale sends capital to the treasury");

        uint256 snapshot = vm.snapshotState();
        deal(address(usdc), address(classic), split.capital);
        vm.prank(address(classic));
        usdc.approve(address(buyer), split.capital);
        vm.prank(address(classic));
        uint256 direct = buyer.buy(split.capital, address(treasury));
        vm.revertToState(snapshot);
        assertGt(direct, 0, "a direct buy of the capital returns REGENT");

        uint256 treasuryRegent = regent.balanceOf(address(treasury));
        uint256 poolUsdc = usdc.balanceOf(address(buyer.V3_POOL()));
        uint256[3] memory held = _buyerHoldings();
        uint256 price = _fund(classic, BUYER);
        vm.recordLogs();
        vm.prank(BUYER);
        uint256 tokenId = classic.purchase(BUYER, price, block.timestamp, new bytes32[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(keys.ownerOf(tokenId), BUYER, "the key is sold");
        uint256 delivered = regent.balanceOf(address(treasury)) - treasuryRegent;
        assertEq(delivered, direct, "the treasury receives the market's REGENT for the capital");
        assertEq(usdc.balanceOf(address(buyer.V3_POOL())) - poolUsdc, split.capital, "the capital went into v3");
        _assertBuyerEvent(logs, split.capital, delivered);
        _assertManagerEvent(logs, split.capital, delivered);

        uint256[3] memory after_ = _buyerHoldings();
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(after_[i], held[i], "the buyer keeps nothing");
        }
        assertEq(usdc.allowance(address(classic), address(buyer)), 0, "no approval outlives the purchase");
        assertEq(usdc.balanceOf(address(classic)), classic.protocolShareOwed(), "the manager holds only the share");
        assertEq(classic.protocolShareOwed(), split.protocol, "which is the quote's");
        assertEq(usdc.balanceOf(address(treasury)), 0, "no USDC reaches the treasury unswapped");
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

    /// @dev A direct buy spends exactly the USDC given, pays the REGENT to the recipient, and
    /// reports it. A buy of nothing, or of more than was approved, is refused.
    function test_aDirectBuySpendsExactlyWhatItIsGiven() public {
        uint256 amount = 100e6;
        deal(address(usdc), PAYER, amount);

        vm.prank(PAYER);
        usdc.approve(address(buyer), amount - 1);
        vm.prank(PAYER);
        vm.expectRevert();
        buyer.buy(amount, RECIPIENT);

        vm.prank(PAYER);
        vm.expectRevert(KeyfleetRegentBuyer.ZeroAmount.selector);
        buyer.buy(0, RECIPIENT);

        vm.prank(PAYER);
        usdc.approve(address(buyer), amount);
        uint256 before = regent.balanceOf(RECIPIENT);
        vm.recordLogs();
        vm.prank(PAYER);
        uint256 regentOut = buyer.buy(amount, RECIPIENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(regentOut, 0, "REGENT bought");
        assertEq(regent.balanceOf(RECIPIENT) - before, regentOut, "paid to the recipient, as reported");
        assertEq(usdc.balanceOf(PAYER), 0, "exactly the amount spent");
        assertEq(usdc.allowance(PAYER, address(buyer)), 0, "and the whole approval used");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(buyer) || logs[i].topics[0] != KeyfleetRegentBuyer.RegentBought.selector) {
                continue;
            }
            assertEq(address(uint160(uint256(logs[i].topics[1]))), PAYER, "payer");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), RECIPIENT, "recipient");
            (uint256 usdcIn, uint256 wethMid, uint256 out) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(usdcIn, amount, "USDC in");
            assertGt(wethMid, 0, "WETH between the legs");
            assertEq(out, regentOut, "REGENT out");
            found = true;
        }
        assertTrue(found, "the buyer reported the buy");
    }

    /// @dev The real v3 pool and the real PoolManager reach the buyer's callbacks only during its own
    /// buy: outside one, each is refused.
    function test_theCallbacksRefuseTheRealPoolsOutsideABuy() public {
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

    /// @dev The manager reported the same buy.
    function _assertManagerEvent(Vm.Log[] memory logs, uint256 usdcIn, uint256 regentOut) private view {
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(classic) || log.topics[0] != KeyfleetManager.RegentBought.selector) continue;
            (uint256 paid, uint256 out) = abi.decode(log.data, (uint256, uint256));
            assertEq(paid, usdcIn, "the manager reports the capital");
            assertEq(out, regentOut, "and the REGENT delivered");
            return;
        }
        revert("no RegentBought from the manager");
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
