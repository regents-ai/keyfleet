// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one function of REGENT revenue staking on Base that a fleet uses.
/// @dev Copied from the deployed contract's verified source, `RegentRevenueStaking` at
/// `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`. USDC counts as revenue there only when it arrives
/// through this call; a plain transfer sits as surplus that only the contract's owner can move.
interface IRegentRevenueStaking {
    /// @notice Pulls `amount` USDC from the caller with `transferFrom` and credits it as revenue.
    /// Reverts on a zero amount and while the contract is paused.
    /// @param sourceTag What kind of revenue this is.
    /// @param sourceRef Which source it came from.
    /// @return received The USDC the contract received.
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
