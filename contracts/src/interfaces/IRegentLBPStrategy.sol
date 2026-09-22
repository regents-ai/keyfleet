// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one read a fleet makes on the shared Autolaunch strategy.
/// @dev Deliberately minimal: a fleet reads the recorded state of its own auction and nothing else.
/// None of the strategy's writing surface — bidding, migration, refunds, staking, claims — is
/// declared here, so a fleet cannot reach any of it.
///
/// The struct is copied field for field, in order, from `RegentLBPStrategy` and checked against the
/// frozen `abi/RegentLBPStrategy.json`, because decoding the returned struct depends on every field
/// being present in the right place. `poolId` is a `PoolId` there, a Uniswap v4 user-defined value
/// type over `bytes32`, which is ABI-identical to the `bytes32` declared here.
interface IRegentLBPStrategy {
    /// @notice The only lifecycle a recorded launch can occupy.
    /// @dev `Active` persists after the auction ends and until someone calls the strategy's
    /// `migrate`, so it means "not settled yet", not "still taking bids".
    enum Lifecycle {
        None,
        Active,
        Graduated,
        Failed
    }

    /// @notice One launch's complete recorded state.
    struct Distribution {
        Lifecycle lifecycle;
        uint64 startBlock;
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint128 requiredRegentRaised;
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

    /// @notice The largest required raise a real auction can settle on, and the ceiling the
    /// strategy enforces on every launch.
    function MAX_REACHABLE_RAISE() external view returns (uint128);

    /// @notice One launch's complete recorded state, or an all-zero record for an unknown auction.
    function distribution(address auction) external view returns (Distribution memory);
}
