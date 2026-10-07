// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRegentLBPStrategyV2} from "./IRegentLBPStrategyV2.sol";

/// @notice The part of Autolaunch Revstake v2's `RegentsAutolaunchFactoryV2` a fleet uses: the
/// launch call its treasury makes through an approved proposal, and the reads that prove a launch
/// was the fleet's own and succeeded. Copied from `src/factory/RegentsAutolaunchFactoryV2.sol` of the
/// selected deployment, on Base at `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E`.
interface IRegentsAutolaunchFactoryV2 {
    /// @notice Everything a launcher supplies. Each string is nonempty and within its byte cap:
    /// name 64, symbol 16, description 512, website 256, image 256.
    /// @param treasury Receives the launch's vesting tokens, its share of the raise and its share of
    /// every payment. A fleet names its own treasury.
    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        address treasury;
    }

    /// @notice One recorded launch, all zero for an unknown id.
    /// @param launcher Whoever called `launch`.
    /// @param subject The launched token.
    /// @param auction The launch's auction, by which the strategy records its outcome.
    /// @param escrow Holds the 70% that vests to the treasury.
    /// @param treasury The treasury the launch named.
    struct Launch {
        address launcher;
        address subject;
        address auction;
        address escrow;
        address treasury;
    }

    /// @notice Creates one launch. Takes no ETH and no token from the caller.
    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow);

    /// @notice One recorded launch.
    function launches(uint256 launchId) external view returns (Launch memory);

    /// @notice The one strategy every launch of this factory runs through.
    function strategy() external view returns (IRegentLBPStrategyV2);
}
