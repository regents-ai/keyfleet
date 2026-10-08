// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "../../src/interfaces/IUniswapV3Pool.sol";

/// @dev A Uniswap v3 pool stand-in at a fixed price, exact input only, with Uniswap's order: it
/// pays the output first, then asks the caller's callback for the input and checks it arrived. A
/// test can make it fill only part of an input, call its callback twice, or pass the callback a
/// different amount than it swapped, and can make every swap move its price.
contract MockUniswapV3Pool is IUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    /// @dev Output per unit of input, scaled by 1e18, for each direction.
    uint256 public immutable ZERO_FOR_ONE_RATE;
    uint256 public immutable ONE_FOR_ZERO_RATE;

    /// @dev The share of an input the pool takes, in basis points; 10,000 normally.
    uint256 public fillBps = 10_000;
    /// @dev When set, the pool asks the callback to pay this much more than it took.
    uint256 public overcharge;
    /// @dev When set, the pool calls the callback a second time.
    bool public callbackTwice;
    /// @dev The pool's square-root price, which moves only by `sqrtMoveBps` on every swap.
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    /// @dev How far each swap moves the square-root price, in basis points, up or down; zero
    /// normally.
    int256 public sqrtMoveBps;

    constructor(address token0_, address token1_, uint256 zeroForOneRate, uint256 oneForZeroRate) {
        token0 = token0_;
        token1 = token1_;
        ZERO_FOR_ONE_RATE = zeroForOneRate;
        ONE_FOR_ZERO_RATE = oneForZeroRate;
    }

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function setOvercharge(uint256 amount) external {
        overcharge = amount;
    }

    function setCallbackTwice(bool twice) external {
        callbackTwice = twice;
    }

    function setSqrtMoveBps(int256 bps) external {
        sqrtMoveBps = bps;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = (uint256(amountSpecified) * fillBps) / 10_000;
        sqrtPriceX96 = uint160((uint256(sqrtPriceX96) * uint256(10_000 + sqrtMoveBps)) / 10_000);
        uint256 amountOut = (amountIn * (zeroForOne ? ZERO_FOR_ONE_RATE : ONE_FOR_ZERO_RATE)) / 1e18;
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        IERC20(tokenOut).transfer(recipient, amountOut);

        uint256 owed = amountIn + overcharge;
        (amount0, amount1) = zeroForOne ? (int256(owed), -int256(amountOut)) : (-int256(amountOut), int256(owed));
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        if (callbackTwice) IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + owed, "input not paid");
    }
}
