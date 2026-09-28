// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The reads a fleet makes on the shared Autolaunch strategy.
/// @dev Deliberately minimal: a fleet reads the recorded state of its own auction, and the raise a
/// floor and a minimum imply, and nothing else. None of the strategy's writing surface — migration,
/// refunds, claims — is declared here, so a fleet cannot reach any of it.
///
/// The struct is copied field for field, in order, from `RegentLBPStrategyV2` and checked against
/// the frozen `contracts/revstake-v2/abi/RegentLBPStrategyV2.json` in the Autolaunch repository,
/// because decoding the returned struct depends on every field being present in the right place.
/// `poolId` is a `PoolId` there, a Uniswap v4 user-defined value type over `bytes32`, which is
/// ABI-identical to the `bytes32` declared here.
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
        uint256 floorPriceQ96;
        uint256 launchId;
        address subject;
        address escrow;
        address treasury;
        address splitter;
        address receiver;
        bytes32 poolId;
        uint256 lpTokenId;
    }

    /// @notice The REGENT an auction at this floor must raise to graduate: the whole sale at the
    /// floor, rounded up, or the launcher's own minimum when that is higher.
    /// @dev Pure. Reverts with the strategy's own errors for a floor below the auction's minimum or
    /// off the grid of a hundred bid ticks, and for a minimum no auction could ever raise.
    function requiredRegentRaisedFor(uint256 floorPriceQ96, uint128 minimumRegentRaised)
        external
        pure
        returns (uint128 requiredRegentRaised);

    /// @notice One launch's complete recorded state, or an all-zero record for an unknown auction.
    function distribution(address auction) external view returns (Distribution memory);
}
