// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetDeployer} from "./KeyfleetDeployers.sol";
import {KeyfleetTradingManager} from "./KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "./KeyfleetTradingTreasury.sol";
import {IKeyfleetFactory} from "./KeyfleetWiring.sol";

/// @notice Deploys each Trading Fleet's `KeyfleetTradingManager` for the trading factory, with
/// CREATE2 and salt = the fleet number.
contract KeyfleetTradingManagerDeployer is KeyfleetDeployer {
    constructor(IKeyfleetFactory factory) KeyfleetDeployer(factory) {}

    function _creationCode() internal pure override returns (bytes memory) {
        return type(KeyfleetTradingManager).creationCode;
    }

    function _deploy(bytes32 salt) internal override returns (address) {
        return address(new KeyfleetTradingManager{salt: salt}());
    }
}

/// @notice Deploys each Trading Fleet's `KeyfleetTradingTreasury` for the trading factory, with
/// CREATE2 and salt = the fleet number.
contract KeyfleetTradingTreasuryDeployer is KeyfleetDeployer {
    constructor(IKeyfleetFactory factory) KeyfleetDeployer(factory) {}

    function _creationCode() internal pure override returns (bytes memory) {
        return type(KeyfleetTradingTreasury).creationCode;
    }

    function _deploy(bytes32 salt) internal override returns (address) {
        return address(new KeyfleetTradingTreasury{salt: salt}());
    }
}
