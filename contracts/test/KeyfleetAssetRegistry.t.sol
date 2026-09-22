// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";

interface Vm {
    function prank(address msgSender, address txOrigin) external;
    function expectRevert(bytes4 selector) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
}

/// @dev Only a caller stand-in: this does not implement or test Safe signature validation.
contract SafeCaller {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setFactory(KeyfleetAssetRegistry registry, address token, bool allowed) external {
        require(msg.sender == owner, "Only owner");
        registry.setFactoryTokenAllowed(token, allowed);
    }

    function setFleet(KeyfleetAssetRegistry registry, address fleet, address token, bool allowed) external {
        require(msg.sender == owner, "Only owner");
        registry.setFleetTokenAllowed(fleet, token, allowed);
    }
}

contract KeyfleetAssetRegistryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant USDC = address(0x100);
    address private constant TOKEN = address(0x200);
    address private constant FLEET = address(0x300);
    address private constant OTHER_FLEET = address(0x400);

    SafeCaller private safe;
    KeyfleetAssetRegistry private registry;

    event FactoryTokenAllowedSet(address indexed token, bool allowed);
    event FleetTokenAllowedSet(address indexed fleet, address indexed token, bool allowed);

    function setUp() public {
        safe = new SafeCaller(address(this));
        registry = new KeyfleetAssetRegistry(address(safe), USDC);
    }

    function testConstructorBindsAddressesWithoutImplicitApproval() public view {
        require(registry.REGENT_SAFE() == address(safe), "Safe binding");
        require(registry.BASE_USDC() == USDC, "USDC binding");
        require(!registry.isTokenAllowed(FLEET, USDC), "USDC needs approval");
        require(!registry.factoryTokenAllowed(USDC), "No implicit global approval");
        require(!registry.fleetTokenAllowed(FLEET, USDC), "No implicit local approval");
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        new KeyfleetAssetRegistry(address(0), USDC);
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        new KeyfleetAssetRegistry(address(safe), address(0));
    }

    function testIndividualSafeOwnerAndDeployerCannotChangeEitherScope() public {
        require(safe.owner() == address(this), "Caller is Safe owner and registry deployer");
        vm.expectRevert(KeyfleetAssetRegistry.OnlyRegentSafe.selector);
        registry.setFactoryTokenAllowed(TOKEN, true);
        vm.expectRevert(KeyfleetAssetRegistry.OnlyRegentSafe.selector);
        registry.setFleetTokenAllowed(FLEET, TOKEN, true);
    }

    function testFuzzEveryOtherCallerIsRejectedEvenWithSafeOrigin(address caller, bool allowed) public {
        if (caller == address(safe)) return;
        safe.setFactory(registry, TOKEN, !allowed);
        safe.setFleet(registry, FLEET, TOKEN, !allowed);

        vm.expectRevert(KeyfleetAssetRegistry.OnlyRegentSafe.selector);
        vm.prank(caller, address(safe));
        registry.setFactoryTokenAllowed(TOKEN, allowed);
        vm.expectRevert(KeyfleetAssetRegistry.OnlyRegentSafe.selector);
        vm.prank(caller, address(safe));
        registry.setFleetTokenAllowed(FLEET, TOKEN, allowed);

        require(registry.factoryTokenAllowed(TOKEN) == !allowed, "Global state unchanged");
        require(registry.fleetTokenAllowed(FLEET, TOKEN) == !allowed, "Local state unchanged");
    }

    function testBothScopesRequiredAndEitherRevocationTakesEffectImmediately() public {
        require(!registry.isTokenAllowed(FLEET, TOKEN), "Neither scope");
        safe.setFactory(registry, TOKEN, true);
        require(!registry.isTokenAllowed(FLEET, TOKEN), "Global only");
        safe.setFleet(registry, FLEET, TOKEN, true);
        require(registry.isTokenAllowed(FLEET, TOKEN), "Both scopes");

        safe.setFactory(registry, TOKEN, false);
        require(!registry.isTokenAllowed(FLEET, TOKEN), "Local only after global revocation");
        require(registry.fleetTokenAllowed(FLEET, TOKEN), "Global revocation preserves local approval");
        safe.setFactory(registry, TOKEN, true);
        require(registry.isTokenAllowed(FLEET, TOKEN), "Global reapproval");
        safe.setFleet(registry, FLEET, TOKEN, false);
        require(!registry.isTokenAllowed(FLEET, TOKEN), "Local revocation");
        require(registry.factoryTokenAllowed(TOKEN), "Local revocation preserves global approval");
        safe.setFleet(registry, FLEET, TOKEN, true);
        require(registry.isTokenAllowed(FLEET, TOKEN), "Local reapproval");
    }

    function testApprovalsRemainSpecificToFleetAndToken() public {
        safe.setFactory(registry, TOKEN, true);
        safe.setFleet(registry, FLEET, TOKEN, true);
        require(!registry.isTokenAllowed(OTHER_FLEET, TOKEN), "Other fleet needs local approval");
        safe.setFleet(registry, OTHER_FLEET, USDC, true);
        require(!registry.isTokenAllowed(OTHER_FLEET, USDC), "Other token needs global approval");
        safe.setFactory(registry, USDC, true);
        require(registry.isTokenAllowed(OTHER_FLEET, USDC), "Other pair admitted");
        require(!registry.isTokenAllowed(FLEET, USDC), "Other token needs local approval");
        safe.setFleet(registry, FLEET, TOKEN, false);
        require(registry.isTokenAllowed(OTHER_FLEET, USDC), "Other pair remains admitted");
    }

    function testFuzzSettersRejectZeroAddresses(bool allowed) public {
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        safe.setFactory(registry, address(0), allowed);
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        safe.setFleet(registry, address(0), TOKEN, allowed);
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        safe.setFleet(registry, FLEET, address(0), allowed);
    }

    function testAdmissionRejectsZeroAddresses() public {
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        registry.isTokenAllowed(address(0), TOKEN);
        vm.expectRevert(KeyfleetAssetRegistry.ZeroAddress.selector);
        registry.isTokenAllowed(FLEET, address(0));
    }

    function testFuzzBothSettersEmitScopeAndNewValue(bool allowed) public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit FactoryTokenAllowedSet(TOKEN, allowed);
        safe.setFactory(registry, TOKEN, allowed);
        vm.expectEmit(true, true, false, true, address(registry));
        emit FleetTokenAllowedSet(FLEET, TOKEN, allowed);
        safe.setFleet(registry, FLEET, TOKEN, allowed);
    }
}
