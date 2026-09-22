// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared deposit-token admission. Both factory and fleet approval are required.
/// @dev The constructor caller must supply the intended Safe and canonical Base USDC.
contract KeyfleetAssetRegistry {
    error ZeroAddress();
    error OnlyRegentSafe();

    address public immutable REGENT_SAFE;
    address public immutable BASE_USDC;

    mapping(address token => bool allowed) public factoryTokenAllowed;
    mapping(address fleet => mapping(address token => bool allowed)) public fleetTokenAllowed;

    event FactoryTokenAllowedSet(address indexed token, bool allowed);
    event FleetTokenAllowedSet(address indexed fleet, address indexed token, bool allowed);

    constructor(address regentSafe, address baseUsdc) {
        if (regentSafe == address(0) || baseUsdc == address(0)) revert ZeroAddress();
        REGENT_SAFE = regentSafe;
        BASE_USDC = baseUsdc;
    }

    modifier onlyRegentSafe() {
        if (msg.sender != REGENT_SAFE) revert OnlyRegentSafe();
        _;
    }

    function setFactoryTokenAllowed(address token, bool allowed) external onlyRegentSafe {
        if (token == address(0)) revert ZeroAddress();
        factoryTokenAllowed[token] = allowed;
        emit FactoryTokenAllowedSet(token, allowed);
    }

    function setFleetTokenAllowed(address fleet, address token, bool allowed) external onlyRegentSafe {
        if (fleet == address(0) || token == address(0)) revert ZeroAddress();
        fleetTokenAllowed[fleet][token] = allowed;
        emit FleetTokenAllowedSet(fleet, token, allowed);
    }

    function isTokenAllowed(address fleet, address token) external view returns (bool) {
        if (fleet == address(0) || token == address(0)) revert ZeroAddress();
        return factoryTokenAllowed[token] && fleetTokenAllowed[fleet][token];
    }
}
