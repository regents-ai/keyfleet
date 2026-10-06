// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Keyfleet} from "./Keyfleet.sol";

/// @notice The treasury of one fleet: the only place the fleet's free capital is held.
/// @dev One instance is permanently bound to one fleet. It is deployed straight after the fleet,
/// at the address the fleet was given for it, and refuses to deploy for a fleet that names another
/// treasury. The capital part of every purchase, a completed Cascade level's released surplus and
/// every token other than USDC that reaches the fleet are sent here. Income in USDC never comes
/// here: it goes from the fleet to the keys. There is no administrator, no upgrade path and no
/// pause.
contract KeyfleetTreasury {
    /// @notice The fleet this treasury holds the capital of.
    Keyfleet public immutable FLEET;

    /// @notice The fleet does not name this contract as its treasury.
    error WrongFleet(address fleet);

    /// @notice Binds this treasury to its fleet.
    /// @param fleet The fleet, which must name this contract's address as its treasury.
    constructor(Keyfleet fleet) {
        if (address(fleet.TREASURY()) != address(this)) revert WrongFleet(address(fleet));
        FLEET = fleet;
    }
}
