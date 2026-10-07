// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The parts of a Uniswap v3 pool the REGENT buyer uses, as Uniswap's `IUniswapV3Pool`
/// declares them.
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Swaps one token for the other. A positive `amountSpecified` is an exact input. The
    /// pool pays the output first, then calls `uniswapV3SwapCallback` on the caller for the input.
    /// @return amount0 The pool's change in token0: positive is paid in, negative paid out.
    /// @return amount1 The pool's change in token1.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice The callback a Uniswap v3 pool makes on whoever called `swap`.
interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
