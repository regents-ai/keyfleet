// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one call a fleet makes on the deployed Regents revenue staking contract.
/// @dev Deliberately minimal: a fleet registers USDC revenue and reads back how much arrived.
/// Nothing else of that contract's surface is declared here, so a fleet cannot stake, withdraw,
/// pause or configure anything on it. The live contract pulls the USDC with `transferFrom`, so the
/// caller approves it first, and it rejects the call while it is paused, which is what makes a
/// failed registration revert the whole deposit, or the whole protocol-share send, instead of
/// silently skipping the payment.
interface IRegentRevenueStaking {
    /// @notice Registers `amount` of USDC as revenue and returns the amount actually received.
    /// @param amount Atomic USDC units to pull from the caller.
    /// @param sourceTag Caller-chosen label for the revenue source.
    /// @param sourceRef Caller-chosen reference for this particular payment.
    /// @return received Atomic USDC units the staking contract observed arriving.
    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received);
}
