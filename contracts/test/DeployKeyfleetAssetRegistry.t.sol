// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployKeyfleetAssetRegistry} from "../script/DeployKeyfleetAssetRegistry.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";

contract DeployKeyfleetAssetRegistryTest is Test {
    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    uint256 private constant BASE_CHAIN_ID = 8453;
    address private constant SAFE = address(0x5AFE);
    address private constant USDC = address(0x05DC);

    DeployKeyfleetAssetRegistry private script;

    function setUp() public {
        script = new DeployKeyfleetAssetRegistry();
    }

    function test_deploysTheRegistryUnderTheManifestsSafeAndUsdc() public {
        uint256 nonceBefore = vm.getNonce(address(script));

        KeyfleetAssetRegistry registry = script.deploy(_manifest());

        assertEq(vm.getNonce(address(script)) - nonceBefore, 1, "The registry and nothing else");
        assertEq(registry.REGENT_SAFE(), SAFE, "Administered by the manifest's Safe");
        assertEq(registry.BASE_USDC(), USDC, "Bound to the manifest's USDC");
        assertFalse(registry.factoryTokenAllowed(USDC), "No token is admitted");
    }

    /// @dev Invariant: once a manifest names the chain's registry, the step cannot put a second one
    /// on the chain, however many times it runs.
    function test_manifestAlreadyNamingARegistryIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.assetRegistry = address(script.deploy(manifest));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployKeyfleetAssetRegistry.AssetRegistryAlreadyNamed.selector, manifest.assetRegistry
            )
        );
        script.deploy(manifest);
    }

    function test_manifestForAnotherChainIsRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, BASE_CHAIN_ID, ANVIL_CHAIN_ID));
        script.deploy(manifest);
    }

    /// @dev Invariant: on Base the registry every fleet shares is bound to Base USDC.
    function test_baseManifestNamingAnyUsdcButBaseUsdcIsRefused() public {
        vm.chainId(BASE_CHAIN_ID);
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.UsdcNotBaseUsdc.selector, USDC));
        script.deploy(manifest);

        manifest.usdc = script.BASE_USDC();
        assertEq(script.deploy(manifest).BASE_USDC(), script.BASE_USDC(), "Base USDC is accepted");
    }

    function test_sharedWiringIsReadWithoutNamingAFleet() public view {
        KeyfleetManifest.Manifest memory base = script.readSharedWiring("base");

        assertEq(base.chainId, BASE_CHAIN_ID, "chainId");
        assertEq(base.usdc, script.BASE_USDC(), "usdc");
        assertEq(base.assetRegistry, address(0), "No registry yet");
        assertEq(bytes(base.fleet.name).length, 0, "No fleet");
    }

    function _manifest() private pure returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.usdc = USDC;
        manifest.regentSafe = SAFE;
    }
}
