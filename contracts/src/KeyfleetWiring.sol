// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "./KeyfleetRegentBuyer.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "./interfaces/IRegentsAutolaunchFactoryV2.sol";

/// @notice What one fleet's four contracts are built with: the fleet, its type, starting price and
/// Accelerant step, and the address of each of the four, which the factory works out before deploying any.
/// @param fleetId The fleet's number in the collection.
/// @param preset The fleet's type.
/// @param startPrice The USDC price of the fleet's first key, in atomic USDC.
/// @param accelerantStepPercent On Accelerant, how many percent each primary mint costs more than
/// the one before, 1 to 5; zero on every other type.
/// @param manager Where the fleet's `KeyfleetManager` is deployed.
/// @param votes Where the fleet's `KeyfleetVotes` is deployed.
/// @param treasury Where the fleet's `KeyfleetTreasury` is deployed.
/// @param rewards Where the fleet's `KeyfleetRewards` is deployed.
struct FleetWiring {
    uint256 fleetId;
    KeyfleetPresets.Preset preset;
    uint256 startPrice;
    uint256 accelerantStepPercent;
    address manager;
    address votes;
    address treasury;
    address rewards;
}

/// @notice What a fleet contract reads from the factory while the factory is deploying it.
/// @dev `wiring` is held in the factory's transient storage only while it deploys one fleet's four
/// contracts, and is all zero at every other moment, so a contract deployed outside a creation
/// never finds its own address in it.
interface IKeyfleetFactory {
    function wiring() external view returns (FleetWiring memory);
    function KEYS() external view returns (KeyfleetKeys);
    function SHARDS() external view returns (KeyfleetShards);
    function REGENT_BUYER() external view returns (KeyfleetRegentBuyer);
    function USDC() external view returns (IERC20);
    function REGENT() external view returns (IERC20);
    function REGENT_STAKING() external view returns (IRegentRevenueStaking);
    function AUTOLAUNCH() external view returns (IRegentsAutolaunchFactoryV2);
}

/// @notice A deployer of one of a fleet's four contracts, which names the factory it serves.
interface IKeyfleetDeployer {
    function FACTORY() external view returns (IKeyfleetFactory);
}

/// @notice Reads the wiring of the fleet contract being constructed.
library KeyfleetWiring {
    /// @notice The contract under construction is not where the factory is deploying the role it
    /// claims, so it was not deployed by the factory's own creation.
    error NotWired(address self);

    /// @notice The factory behind the deployer that is constructing the caller, and the wiring it
    /// holds now.
    /// @dev Called from a constructor, where `msg.sender` is the deployer.
    function read() internal view returns (IKeyfleetFactory factory, FleetWiring memory wiring) {
        factory = IKeyfleetDeployer(msg.sender).FACTORY();
        wiring = factory.wiring();
    }

    /// @notice Refuses unless `expected`, the address the wiring gives the caller's role, is the
    /// contract under construction.
    function requireSelf(address expected) internal view {
        if (expected != address(this)) revert NotWired(address(this));
    }
}
