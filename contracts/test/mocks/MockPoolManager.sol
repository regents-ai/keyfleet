// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IUniswapV4PoolManager,
    IUnlockCallback,
    V4PoolKey,
    V4SwapParams
} from "../../src/interfaces/IUniswapV4PoolManager.sol";

/// @dev A Uniswap v4 PoolManager stand-in for one pool at a fixed price, exact input only, with v4's
/// flash accounting: `unlock` calls the caller back, `swap` records what the caller owes and is
/// owed, `sync` and `settle` take payment, `take` pays out, and every debt must be zero when the
/// callback returns. A test can make it fill only part of an input, and can give the pool a "hook"
/// call it makes from inside every swap, as the REGENT pool's hook runs there, and can make every
/// swap move its price.
contract MockPoolManager is IUniswapV4PoolManager {
    /// @dev REGENT out per WETH in, and WETH out per REGENT in, scaled by 1e18.
    uint256 public immutable FORWARD_RATE;
    uint256 public immutable REVERSE_RATE;
    address public immutable INPUT;

    bool private _unlocked;
    address private _synced;
    uint256 private _syncedReserve;
    mapping(address currency => int256 delta) private _delta;
    address[] private _touched;

    uint256 public fillBps = 10_000;
    address public hookTarget;
    bytes public hookData;
    /// @dev When set, `swap` reports this delta instead of the real one.
    bool public reportOverride;
    int256 public reportedDelta;
    /// @dev The pool's square-root price, which moves only by `sqrtMoveBps` on every swap.
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    /// @dev How far each swap moves the square-root price, in basis points, up or down; zero
    /// normally.
    int256 public sqrtMoveBps;

    /// @param input The currency the forward rate prices: WETH.
    constructor(address input, uint256 forwardRate, uint256 reverseRate) {
        INPUT = input;
        FORWARD_RATE = forwardRate;
        REVERSE_RATE = reverseRate;
    }

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function setReportedDelta(int256 reported) external {
        reportOverride = true;
        reportedDelta = reported;
    }

    function clearReportedDelta() external {
        reportOverride = false;
    }

    function setSqrtMoveBps(int256 bps) external {
        sqrtMoveBps = bps;
    }

    /// @dev Every slot reads as the one pool's price, which is all the buyer reads.
    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked, "already unlocked");
        _unlocked = true;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i; i < _touched.length; ++i) {
            require(_delta[_touched[i]] == 0, "currency not settled");
        }
        delete _touched;
        _unlocked = false;
    }

    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata)
        external
        returns (int256 swapDelta)
    {
        require(_unlocked, "locked");
        require(params.amountSpecified < 0, "exact input only");
        (address currencyIn, address currencyOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 amountIn = (uint256(-params.amountSpecified) * fillBps) / 10_000;
        sqrtPriceX96 = uint160((uint256(sqrtPriceX96) * uint256(10_000 + sqrtMoveBps)) / 10_000);
        uint256 amountOut = (amountIn * (currencyIn == INPUT ? FORWARD_RATE : REVERSE_RATE)) / 1e18;
        _delta[currencyIn] -= int256(amountIn);
        _delta[currencyOut] += int256(amountOut);
        _touched.push(currencyIn);
        _touched.push(currencyOut);

        if (hookTarget != address(0)) {
            (bool ok, bytes memory reason) = hookTarget.call(hookData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }

        (int256 amount0, int256 amount1) =
            params.zeroForOne ? (-int256(amountIn), int256(amountOut)) : (int256(amountOut), -int256(amountIn));
        swapDelta =
            reportOverride ? reportedDelta : int256((amount0 << 128) | int256(uint256(uint128(int128(amount1)))));
    }

    function sync(address currency) external {
        _synced = currency;
        _syncedReserve = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedReserve;
        _delta[_synced] += int256(paid);
        _synced = address(0);
    }

    function take(address currency, address to, uint256 amount) external {
        _delta[currency] -= int256(amount);
        IERC20(currency).transfer(to, amount);
    }

    /// @dev Asserted by tests after every buy: nothing is left owed either way.
    function delta(address currency) external view returns (int256) {
        return _delta[currency];
    }
}
