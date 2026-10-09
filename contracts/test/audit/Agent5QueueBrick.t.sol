// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3Pool.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetFixture, FULL_PIECE} from "../helpers/KeyfleetFixture.sol";

/// @dev AUDIT PoC helper (Agent 5). A fixed-price v3 pool stand-in that takes its fee the way a real
/// Uniswap v3 pool does in `SwapMath.computeSwapStep` for an exact input that does not reach the next
/// tick: amountRemainingLessFee = floor(amountIn * (1e6 - fee) / 1e6), and the whole remainder is the
/// fee. With the Base USDC/WETH pool's fee of 500, a 1-atomic-unit input leaves 0 to swap, so the pool
/// takes the 1 unit as fee and returns 0 WETH (amount0/amount1 = +1 / 0).
contract Agent5FeeV3Pool is IUniswapV3Pool {
    uint256 private _unusedSlot0; // overwrites the old mock's first slot when placed over it
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable ZERO_FOR_ONE_RATE;
    uint256 public immutable ONE_FOR_ZERO_RATE;
    uint24 public constant FEE = 500;
    uint160 public sqrtPriceX96;

    constructor(address token0_, address token1_, uint256 zeroForOneRate, uint256 oneForZeroRate) {
        token0 = token0_;
        token1 = token1_;
        ZERO_FOR_ONE_RATE = zeroForOneRate;
        ONE_FOR_ZERO_RATE = oneForZeroRate;
        sqrtPriceX96 = uint160(1 << 96);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = uint256(amountSpecified);
        uint256 lessFee = (amountIn * (1e6 - FEE)) / 1e6;
        uint256 amountOut = (lessFee * (zeroForOne ? ZERO_FOR_ONE_RATE : ONE_FOR_ZERO_RATE)) / 1e18;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        if (amountOut != 0) IERC20(tokenOut).transfer(recipient, amountOut);
        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "input not paid");
    }
}

/// @dev Swaps 1 atomic unit of `token` on a v3 pool and pays the pool from its own balance.
contract OneUnitSwapper is IUniswapV3SwapCallback {
    address private token;

    function run(IUniswapV3Pool pool, address tokenIn) external returns (uint256 out) {
        token = tokenIn;
        bool zeroForOne = tokenIn == pool.token0();
        (int256 amount0, int256 amount1) = pool.swap(address(this), zeroForOne, 1, 0, "");
        int256 delta = zeroForOne ? amount1 : amount0;
        out = uint256(-delta);
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        uint256 owed = uint256(amount0 > 0 ? amount0 : amount1);
        IERC20(token).transfer(msg.sender, owed);
    }
}

/// @dev AUDIT PoC (Agent 5), KF-A-01, re-checked at e05deae. The original attack left a
/// 1-atomic-USDC remainder at the head of the one shared queue, which then reverted `NothingBought`
/// for every fleet for good. With `takePiece` now taking the whole booking whenever a piece would
/// leave less than `MIN_PIECE_USDC`, the same steps leave nothing booked, the queue moves on and the
/// honest fleets convert. The pool keeps Uniswap's fee rounding, so a 1-unit piece would still
/// buy nothing if one could ever be left.
contract Agent5QueueBrickTest is KeyfleetFixture {
    address internal attacker;

    function setUp() public {
        _setUpFixture();
        // Same tokens, same price as the fixture's pool, but with Uniswap's fee rounding.
        deployCodeTo(
            "Agent5QueueBrick.t.sol:Agent5FeeV3Pool",
            abi.encode(address(usdc), address(weth), WETH_PER_USDC, USDC_PER_WETH),
            address(v3Pool)
        );
        attacker = creator;
    }

    function _waitForPiece() private {
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
    }

    /// Sanity: a normal piece still converts on the fee-rounding pool, so the setup is fair.
    function test_agent5_normalPieceStillConverts() public {
        KeyfleetManager honest = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(honest, _wallet(1));
        uint256 booked = honest.pendingConversion();
        assertGt(booked, 0);
        _convertAll();
        assertEq(honest.pendingConversion(), 0);
        assertGt(regent.balanceOf(address(honest.TREASURY())), 0);
    }

    /// Sanity: the pool really rounds a 1-unit input to nothing, as Base's 0.05% pool does, so a
    /// 1-unit piece would still buy nothing if the fix ever let one be left.
    function test_agent5_aOneUnitInputStillBuysNothingOnThisPool() public {
        OneUnitSwapper swapper = new OneUnitSwapper();
        usdc.mint(address(swapper), 1);
        uint256 wethOut = swapper.run(IUniswapV3Pool(address(v3Pool)), address(usdc));
        assertEq(wethOut, 0, "1 atomic USDC buys 0 WETH");
    }

    /// KF-A-01 FIXED: the original attack steps, asserting the safe outcome.
    function test_KFA01_fixed_dustRemainderCanNoLongerBeLeftAndTheQueueMoves() public {
        // 1. The attacker opens a fleet nobody can ever buy into. The creator's key 1 books 9 USDC.
        KeyfleetManager.Requirements memory nobody;
        nobody.merkleRoot = keccak256("no leaf anyone can prove");
        KeyfleetManager trap = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, nobody);
        uint256 trapBooked = trap.pendingConversion();
        assertEq(trapBooked, 9e6, "creator's key 1 books 9 USDC");
        assertEq(regentBuyer.nextInQueue(), address(trap), "trap fleet heads the queue");

        // 2. The attacker asks for all but one atomic unit: the whole booking is taken instead.
        vm.prank(attacker);
        uint256 out = regentBuyer.convert(trapBooked - 1);
        assertGt(out, 0, "the piece bought REGENT");
        assertEq(trap.pendingConversion(), 0, "nothing is left booked");
        assertFalse(regentBuyer.isQueued(address(trap)), "the trap fleet left the queue");

        // 3. Honest fleets keep selling, and every one of their pieces converts.
        KeyfleetManager honest = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyMany(honest, 5);
        uint256[3] memory sizes = [uint256(1), 1e6, 250e6];
        for (uint256 round = 0; round < 3; ++round) {
            _waitForPiece();
            regentBuyer.convert(sizes[round]);
            uint256 left = honest.pendingConversion();
            assertTrue(left == 0 || left >= regentBuyer.MIN_PIECE_USDC(), "never a dust remainder");
        }
        _convertAll();
        assertEq(honest.pendingConversion(), 0, "the honest fleet converted");
        assertGt(regent.balanceOf(address(honest.TREASURY())), 0, "and its treasury holds REGENT");
    }

    /// KF-A-01 FIXED: the natural variant (a keeper asking for booked - 1) also takes the whole booking.
    function test_KFA01_fixed_naturalRemainderOfOneIsTakenWithThePiece() public {
        KeyfleetManager honest = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(honest, _wallet(1));
        uint256 booked = honest.pendingConversion();
        regentBuyer.convert(booked - 1);
        assertEq(honest.pendingConversion(), 0);
        assertEq(regentBuyer.queueLength(), 0);
    }

    /// KF-A-01 FIXED: whatever piece size anyone asks for, what stays booked is nothing or at least
    /// one minimum piece, and the next piece always buys.
    function testFuzz_KFA01_fixed_whatStaysBookedIsNothingOrAMinimumPiece(uint256 ask, uint8 sales) public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyMany(fleet, bound(sales, 1, 40));
        while (regentBuyer.queueLength() != 0) {
            _waitForPiece();
            regentBuyer.convert(ask);
            uint256 left = fleet.pendingConversion();
            assertTrue(left == 0 || left >= regentBuyer.MIN_PIECE_USDC(), "never a dust remainder");
            ask = uint256(keccak256(abi.encode(ask)));
        }
        assertEq(fleet.pendingConversion(), 0);
    }
}
