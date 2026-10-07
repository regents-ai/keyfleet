// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {V4PoolKey} from "../src/interfaces/IUniswapV4PoolManager.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

/// @dev Calls the buyer's callbacks from inside a swap, as a pool's hook could.
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

contract KeyfleetRegentBuyerTest is KeyfleetFixture {
    address private payer = makeAddr("payer");
    address private recipient = makeAddr("recipient");

    function setUp() public {
        _setUpFixture();
    }

    // --- route -----------------------------------------------------------------

    function test_RouteIsFixedAtDeployment() public view {
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
    }

    function test_RouteRefusesAnAddressWithoutCode() public {
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.poolManager = address(0x1234);
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route);

        route = _bindings().route;
        route.weth = address(0);
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route);
    }

    function test_RouteRefusesAV3PoolOfOtherTokens() public {
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v3Pool = address(new MockUniswapV3Pool(address(usdc), address(regent), 1e18, 1e18));
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route);
    }

    function test_RouteRefusesAV4PoolOfOtherCurrencies() public {
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v4Pool.currency1 = address(usdc);
        vm.expectRevert(KeyfleetRegentBuyer.RouteInvalid.selector);
        new KeyfleetRegentBuyer(route);
    }

    // --- buying ----------------------------------------------------------------

    function test_BuySpendsExactlyTheUsdcAndPaysTheRecipient() public {
        uint256 usdcIn = 90e6;
        _fund(usdcIn);
        vm.expectEmit(address(regentBuyer));
        emit KeyfleetRegentBuyer.RegentBought(payer, recipient, usdcIn, usdcIn * 4e8, _regentFor(usdcIn));
        vm.prank(payer);
        uint256 out = regentBuyer.buy(usdcIn, recipient);

        assertEq(out, _regentFor(usdcIn));
        assertEq(regent.balanceOf(recipient), out);
        assertEq(usdc.balanceOf(payer), 0);
        assertEq(usdc.allowance(payer, address(regentBuyer)), 0);
        _assertBuyerEmpty();
        assertEq(poolManager.delta(address(weth)), 0);
        assertEq(poolManager.delta(address(regent)), 0);
    }

    function test_BuyWorksWithTheTokensInTheOtherOrder() public {
        MockUniswapV3Pool flippedV3 = new MockUniswapV3Pool(address(weth), address(usdc), USDC_PER_WETH, WETH_PER_USDC);
        MockPoolManager flippedManager = new MockPoolManager(address(weth), REGENT_PER_WETH, WETH_PER_REGENT);
        weth.mint(address(flippedV3), 1e36);
        regent.mint(address(flippedManager), 1e45);
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v3Pool = address(flippedV3);
        route.poolManager = address(flippedManager);
        route.v4Pool.currency0 = address(regent);
        route.v4Pool.currency1 = address(weth);
        KeyfleetRegentBuyer flipped = new KeyfleetRegentBuyer(route);
        assertFalse(flipped.USDC_IS_V3_TOKEN0());
        assertFalse(flipped.WETH_IS_V4_CURRENCY0());

        usdc.mint(payer, 7e6);
        vm.startPrank(payer);
        usdc.approve(address(flipped), 7e6);
        uint256 out = flipped.buy(7e6, recipient);
        vm.stopPrank();
        assertEq(out, _regentFor(7e6));
        assertEq(regent.balanceOf(recipient), out);
        assertEq(weth.balanceOf(address(flipped)), 0);
        assertEq(usdc.balanceOf(address(flipped)), 0);
    }

    function test_BuyOfNothingReverts() public {
        vm.expectRevert(KeyfleetRegentBuyer.ZeroAmount.selector);
        regentBuyer.buy(0, recipient);
    }

    function test_BuyNeedsTheCallersApproval() public {
        usdc.mint(payer, 5e6);
        vm.prank(payer);
        vm.expectRevert();
        regentBuyer.buy(5e6, recipient);
    }

    function test_BuyRefusesAPartialFillOnTheUsdcLeg() public {
        v3Pool.setFillBps(9000);
        _fund(10e6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, 10e6, 9e6));
        regentBuyer.buy(10e6, recipient);
    }

    function test_BuyRefusesAPartialFillOnTheWethLeg() public {
        poolManager.setFillBps(9000);
        _fund(10e6);
        uint256 wethIn = 10e6 * 4e8;
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, wethIn, wethIn * 9 / 10));
        regentBuyer.buy(10e6, recipient);
    }

    function test_BuyRefusesAV3PoolAskingForMoreThanTheSwap() public {
        v3Pool.setOvercharge(1);
        _fund(10e6 + 1);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, 10e6, 10e6 + 1));
        regentBuyer.buy(10e6, recipient);
    }

    function test_BuyPaysTheV3PoolOnlyOnce() public {
        v3Pool.setCallbackTwice(true);
        _fund(20e6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, 0, 10e6));
        regentBuyer.buy(10e6, recipient);
    }

    function test_BuyRefusesASwapThatPaysNoRegent() public {
        uint256 wethIn = 10e6 * 4e8;
        // The PoolManager reports the WETH spent and nothing out.
        poolManager.setReportedDelta(-int256(wethIn) << 128);
        _fund(10e6);
        vm.prank(payer);
        vm.expectRevert(KeyfleetRegentBuyer.NothingBought.selector);
        regentBuyer.buy(10e6, recipient);
    }

    function test_BuyRefusesAV3SwapThatPaysNoWeth() public {
        MockUniswapV3Pool dry = new MockUniswapV3Pool(address(usdc), address(weth), 0, 0);
        KeyfleetRegentBuyer.Route memory route = _bindings().route;
        route.v3Pool = address(dry);
        KeyfleetRegentBuyer buyer_ = new KeyfleetRegentBuyer(route);
        usdc.mint(payer, 10e6);
        vm.startPrank(payer);
        usdc.approve(address(buyer_), 10e6);
        vm.expectRevert(KeyfleetRegentBuyer.NothingBought.selector);
        buyer_.buy(10e6, recipient);
        vm.stopPrank();
    }

    // --- callbacks -------------------------------------------------------------

    function test_V3CallbackRefusesAnyoneButThePool() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(this)));
        regentBuyer.uniswapV3SwapCallback(1, 0, "");
    }

    function test_V3CallbackRefusesThePoolOutsideABuy() public {
        usdc.mint(payer, 10e6);
        vm.prank(payer);
        usdc.approve(address(regentBuyer), 10e6);
        vm.prank(address(v3Pool));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(v3Pool)));
        regentBuyer.uniswapV3SwapCallback(10e6, 0, "");
        assertEq(usdc.balanceOf(payer), 10e6);
    }

    function test_UnlockCallbackRefusesAnyoneButThePoolManager() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(this)));
        regentBuyer.unlockCallback(abi.encode(uint256(1), recipient));
    }

    function test_UnlockCallbackRefusesThePoolManagerOutsideABuy() public {
        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(poolManager)));
        regentBuyer.unlockCallback(abi.encode(uint256(1), recipient));
    }

    function test_TheHookCannotBuyAgainInsideABuy() public {
        CallbackCaller hook = new CallbackCaller();
        poolManager.setHook(
            address(hook),
            abi.encodeCall(
                CallbackCaller.call, (address(regentBuyer), abi.encodeCall(KeyfleetRegentBuyer.buy, (1, recipient)))
            )
        );
        _fund(10e6);
        vm.prank(payer);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        regentBuyer.buy(10e6, recipient);
    }

    function test_TheHookCannotCallTheBuyersCallbacks() public {
        CallbackCaller hook = new CallbackCaller();
        poolManager.setHook(
            address(hook),
            abi.encodeCall(
                CallbackCaller.call,
                (address(regentBuyer), abi.encodeCall(KeyfleetRegentBuyer.uniswapV3SwapCallback, (int256(1), 0, "")))
            )
        );
        _fund(10e6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(hook)));
        regentBuyer.buy(10e6, recipient);
    }

    function testFuzz_BuyAlwaysPaysAtTheMarketAndKeepsNothing(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 1, 1e15);
        _fund(usdcIn);
        vm.prank(payer);
        uint256 out = regentBuyer.buy(usdcIn, recipient);
        assertEq(out, _regentFor(usdcIn));
        _assertBuyerEmpty();
    }

    function _fund(uint256 amount) private {
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(regentBuyer), amount);
    }

    function _assertBuyerEmpty() private view {
        assertEq(usdc.balanceOf(address(regentBuyer)), 0);
        assertEq(weth.balanceOf(address(regentBuyer)), 0);
        assertEq(regent.balanceOf(address(regentBuyer)), 0);
        assertEq(weth.allowance(address(regentBuyer), address(poolManager)), 0);
    }
}
