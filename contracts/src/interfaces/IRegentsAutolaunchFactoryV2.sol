// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRegentLBPStrategy} from "./IRegentLBPStrategy.sol";

/// @notice The calls a fleet makes on the pinned Autolaunch factory.
/// @dev Deliberately minimal: a fleet creates one launch and reads back the provenance of it. The
/// factory's governance surface — pausing and unpausing launches — and its custom payment receivers
/// are not declared here, so a fleet cannot reach any of them; `launchesPaused` is a read, for the
/// app to explain why an execution reverted.
///
/// The two structs are copied field for field, in order, from `RegentsAutolaunchFactoryV2` and
/// checked against the frozen `contracts/revstake-v2/abi/RegentsAutolaunchFactoryV2.json` in the
/// Autolaunch repository. `launch` costs the caller gas only: no token moves, no allowance is
/// needed and no signature is asked for. The caller is recorded as `launcher` for provenance and is
/// granted no authority anywhere by it.
///
/// The five byte caps are declared as reads rather than copied into this repository, so a fleet
/// judges an envelope by the factory's own published figures and can never hold a stale opinion of
/// what the factory will accept.
interface IRegentsAutolaunchFactoryV2 {
    /// @notice Everything a launcher supplies, in exactly this order.
    /// @dev `floorPriceQ96` is the auction's floor, REGENT base units per SUBJECT base unit times
    /// `2^96`, on the strategy's grid. `minimumRegentRaised` is the launcher's own minimum raise,
    /// zero for none; the auction must raise the larger of it and the whole sale at the floor.
    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        address treasury;
        uint256 floorPriceQ96;
        uint128 minimumRegentRaised;
    }

    /// @notice One recorded launch. Provenance and identity only; it carries no authority.
    struct Launch {
        address launcher;
        address subject;
        address auction;
        address escrow;
        address treasury;
    }

    /// @notice Inclusive byte cap on a launch's name, which must also be nonempty.
    function MAX_NAME_BYTES() external view returns (uint256);

    /// @notice Inclusive byte cap on a launch's symbol, which must also be nonempty.
    function MAX_SYMBOL_BYTES() external view returns (uint256);

    /// @notice Inclusive byte cap on a launch's description, which must also be nonempty.
    function MAX_DESCRIPTION_BYTES() external view returns (uint256);

    /// @notice Inclusive byte cap on a launch's website, which must also be nonempty.
    function MAX_WEBSITE_BYTES() external view returns (uint256);

    /// @notice Inclusive byte cap on a launch's image, which must also be nonempty.
    function MAX_IMAGE_BYTES() external view returns (uint256);

    /// @notice Whether the factory is currently refusing new launches.
    function launchesPaused() external view returns (bool);

    /// @notice The one shared strategy this factory deployed and is permanently bound to.
    function strategy() external view returns (IRegentLBPStrategy);

    /// @notice The launch a SUBJECT belongs to, or zero if this factory never created it.
    function launchIdOfSubject(address subject) external view returns (uint256 launchId);

    /// @notice One recorded launch's complete identity, or an all-zero record for an unknown id.
    function launches(uint256 launchId) external view returns (Launch memory);

    /// @notice Creates one launch: its SUBJECT, its pending escrow and its canonical auction.
    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow);
}
