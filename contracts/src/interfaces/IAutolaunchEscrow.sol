// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one read a fleet makes on its launch's vesting escrow.
/// @dev `ConditionalVestingEscrowV2` vests the launch's 65%, and whatever SUBJECT the strategy has
/// left over at graduation, over 365 days. It releases vested SUBJECT only ever to the launch
/// treasury, which for a fleet's launch is the fleet itself, and counts every unit it has released.
interface IAutolaunchEscrow {
    /// @notice The cumulative SUBJECT already released to the treasury.
    function totalReleased() external view returns (uint256);
}
