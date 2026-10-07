// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of Autolaunch Revstake v2's `RegentLBPStrategyV2` a fleet reads: the recorded
/// outcome of a launch. Copied from `src/strategy/RegentLBPStrategyV2.sol` of the selected
/// deployment, on Base at `0x4dEEd15f650F45900F2e55a44eADe7bD5Fd556d9`; `poolId` is Uniswap's
/// `PoolId`, a `bytes32`.
interface IRegentLBPStrategyV2 {
    /// @notice A launch is `Active` until its auction is settled, then `Graduated` when it sold, or
    /// `Failed` when it did not; `None` for an auction the strategy never created.
    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice One launch's recorded state, keyed by its auction.
    struct Distribution {
        Lifecycle lifecycle;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint128 reserve;
        uint128 lpRegentUsed;
        uint128 lpSubjectUsed;
        uint160 finalSqrtPriceX96;
        uint256 launchId;
        address subject;
        address escrow;
        address treasury;
        address splitter;
        address receiver;
        bytes32 poolId;
        uint256 lpTokenId;
    }

    /// @notice One launch's recorded state.
    function distribution(address auction) external view returns (Distribution memory);
}
