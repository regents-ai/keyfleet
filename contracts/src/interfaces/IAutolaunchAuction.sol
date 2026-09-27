// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The one read a fleet makes on its own Autolaunch auction.
/// @dev Copied from Uniswap's `ContinuousClearingAuction`, which the Autolaunch strategy graduates
/// from. The strategy sweeps exactly `currencyRaised` REGENT out of the auction at graduation, puts
/// `lpRegentUsed` of it into the pool and sends the rest to the launch treasury, so these two figures
/// together are exactly the REGENT a fleet receives at graduation.
interface IAutolaunchAuction {
    /// @notice The auction's final figures, available once it has ended and graduated.
    struct LBPInitializationParams {
        uint256 initialPriceX96;
        uint256 tokensSold;
        uint256 currencyRaised;
    }

    /// @notice The final figures of a finished, graduated auction. Reverts before then.
    function lbpInitializationParams() external view returns (LBPInitializationParams memory);
}
