// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice The one-time step before any fleet: deploys the asset registry every fleet on the
/// manifest's chain shares, bound to the manifest's Regents Safe and USDC.
/// @dev Run once per chain. Its address is then written into the manifest's `assetRegistry`, and
/// only then can `DeployKeyfleets` deploy a fleet. A manifest that already names a registry is
/// refused, so running this step twice cannot put a second registry on the chain.
///
/// `deploy` takes a `Manifest` value and touches neither the filesystem nor the environment;
/// `run` is the only part that reads a file or an environment variable, and it writes nothing: the
/// address is printed and kept in Forge's broadcast.
contract DeployKeyfleetAssetRegistry is KeyfleetManifest {
    /// @notice The manifest already names the chain's asset registry.
    error AssetRegistryAlreadyNamed(address registry);

    /// @notice Reads the manifest named by `KEYFLEET_MANIFEST` and deploys its chain's registry.
    /// @dev Signing is the caller's business — `--ledger` or `--trezor` — and this script never
    /// reads a private key.
    function run() external {
        Manifest memory manifest = readSharedWiring(vm.envString("KEYFLEET_MANIFEST"));

        vm.startBroadcast();
        KeyfleetAssetRegistry registry = deploy(manifest);
        vm.stopBroadcast();

        console2.log("Asset registry, to write into the manifest's assetRegistry:", address(registry));
    }

    /// @notice Deploys the registry under the manifest's Safe and USDC.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    function deploy(Manifest memory manifest) public returns (KeyfleetAssetRegistry) {
        _requireSharedWiringFitsChain(manifest);
        if (manifest.assetRegistry != address(0)) revert AssetRegistryAlreadyNamed(manifest.assetRegistry);

        return new KeyfleetAssetRegistry(manifest.regentSafe, manifest.usdc);
    }
}
