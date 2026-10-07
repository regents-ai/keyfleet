// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";
import {KeyfleetTreasury} from "./KeyfleetTreasury.sol";
import {KeyfleetVotes} from "./KeyfleetVotes.sol";
import {IKeyfleetDeployer, IKeyfleetFactory} from "./KeyfleetWiring.sol";

/// @notice Deploys one of a fleet's four contracts for one factory, at an address fixed by the
/// fleet number alone.
/// @dev The factory cannot carry all four creation codes itself, so each lives in its own deployer.
/// A deployer serves the one factory it names, and only that factory may deploy through it. Each
/// contract is deployed with CREATE2, salt = the fleet number, and takes no constructor arguments,
/// so its address is known before anything is deployed.
abstract contract KeyfleetDeployer is IKeyfleetDeployer {
    /// @notice Only the factory may deploy.
    error OnlyFactory(address caller);

    /// @notice The factory this deployer serves. Fixed before the factory exists, from its
    /// predicted address.
    IKeyfleetFactory public immutable FACTORY;

    constructor(IKeyfleetFactory factory) {
        FACTORY = factory;
    }

    /// @notice Where this deployer puts the contract of fleet `fleetId`.
    function predict(uint256 fleetId) external view returns (address) {
        return Create2.computeAddress(bytes32(fleetId), keccak256(_creationCode()));
    }

    /// @notice Deploys the contract of fleet `fleetId`. Only the factory, while it holds that
    /// fleet's wiring.
    function deploy(uint256 fleetId) external returns (address) {
        if (msg.sender != address(FACTORY)) revert OnlyFactory(msg.sender);
        return _deploy(bytes32(fleetId));
    }

    function _creationCode() internal pure virtual returns (bytes memory);

    function _deploy(bytes32 salt) internal virtual returns (address);
}

/// @notice Deploys each fleet's `KeyfleetManager`.
contract KeyfleetManagerDeployer is KeyfleetDeployer {
    constructor(IKeyfleetFactory factory) KeyfleetDeployer(factory) {}

    function _creationCode() internal pure override returns (bytes memory) {
        return type(KeyfleetManager).creationCode;
    }

    function _deploy(bytes32 salt) internal override returns (address) {
        return address(new KeyfleetManager{salt: salt}());
    }
}

/// @notice Deploys each fleet's `KeyfleetVotes`.
contract KeyfleetVotesDeployer is KeyfleetDeployer {
    constructor(IKeyfleetFactory factory) KeyfleetDeployer(factory) {}

    function _creationCode() internal pure override returns (bytes memory) {
        return type(KeyfleetVotes).creationCode;
    }

    function _deploy(bytes32 salt) internal override returns (address) {
        return address(new KeyfleetVotes{salt: salt}());
    }
}

/// @notice Deploys each fleet's `KeyfleetTreasury`.
contract KeyfleetTreasuryDeployer is KeyfleetDeployer {
    constructor(IKeyfleetFactory factory) KeyfleetDeployer(factory) {}

    function _creationCode() internal pure override returns (bytes memory) {
        return type(KeyfleetTreasury).creationCode;
    }

    function _deploy(bytes32 salt) internal override returns (address) {
        return address(new KeyfleetTreasury{salt: salt}());
    }
}

/// @notice Deploys each fleet's `KeyfleetRewards`.
contract KeyfleetRewardsDeployer is KeyfleetDeployer {
    constructor(IKeyfleetFactory factory) KeyfleetDeployer(factory) {}

    function _creationCode() internal pure override returns (bytes memory) {
        return type(KeyfleetRewards).creationCode;
    }

    function _deploy(bytes32 salt) internal override returns (address) {
        return address(new KeyfleetRewards{salt: salt}());
    }
}
