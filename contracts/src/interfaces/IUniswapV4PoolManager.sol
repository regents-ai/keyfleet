// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A Uniswap v4 pool's key, as v4-core's `PoolKey` with its currencies and hook written as
/// plain addresses, which is how the ABI carries them. Its `keccak256(abi.encode(key))` is the pool id.
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice v4-core's swap parameters. A negative `amountSpecified` is an exact input.
struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice The parts of the Uniswap v4 PoolManager the REGENT buyer uses, as v4-core's
/// `IPoolManager` declares them. Currencies are plain addresses; `BalanceDelta` is an `int256`
/// holding currency0's change to the caller in its upper 128 bits and currency1's in the lower.
interface IUniswapV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    /// @notice One word of the PoolManager's storage, as v4-core's `IExtsload` exposes it.
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

/// @notice The callback the PoolManager makes on whoever called `unlock`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
