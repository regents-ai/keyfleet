// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice Step one of two: deploys one fleet — and the shared asset registry if the manifest
/// names none — and writes nothing.
/// @dev Each fleet goes on chain on its own run. The first run deploys the registry; every later
/// fleet on the chain must share it, so its address is written into the manifest's
/// `assetRegistry` before the next fleet is deployed.
///
/// Forge simulates a script in full before it broadcasts anything, so any file this step wrote
/// would be written by a dry run too, and by a broadcast that failed partway. The deployed
/// manifest is therefore written by `RecordKeyfleets`, which runs after the broadcast and reads
/// every value back from the chain.
///
/// `deploy` takes a `Manifest` value and touches neither the filesystem nor the environment, so
/// the suite runs the real deployment against local mocks; `run` is the only part that reads a
/// file or an environment variable.
///
/// The script sets no allowlist flag and moves no token. Deposit admission belongs to the Regents
/// Safe alone, and USDC and REGENT are admitted by the Safe after this script has run. Nor does it
/// touch the VRF subscription: the Safe owns it and adds the fleet as a consumer afterwards.
contract DeployKeyfleets is KeyfleetManifest {
    /// @notice What one run of `deploy` created or reused.
    /// @param registry The shared asset registry, whether newly deployed or supplied.
    /// @param fleet The fleet deployed.
    struct Deployment {
        KeyfleetAssetRegistry registry;
        Keyfleet fleet;
    }

    /// @notice The supplied registry is administered by a different Safe than the manifest names.
    error RegistrySafeMismatch(address expected, address found);

    /// @notice Reads the named manifest for the named fleet and deploys it.
    /// @dev The manifest name comes from `KEYFLEET_MANIFEST` and the fleet from `KEYFLEET_FLEET`
    /// (`syndicate`, `cascade`, `classic` or `accelerant`). Both are required: there is no default,
    /// because a default would pick a chain or a fleet for the operator. Signing is the caller's
    /// business — `--ledger` or `--trezor` — and this script never reads a private key. The record
    /// step reads the broadcast Forge writes, so the deployment is sent by Forge itself.
    function run() external {
        Manifest memory manifest = readManifest(vm.envString("KEYFLEET_MANIFEST"), vm.envString("KEYFLEET_FLEET"));

        vm.startBroadcast();
        deploy(manifest);
        vm.stopBroadcast();
    }

    /// @notice Deploys the registry if the manifest does not name one, then the manifest's fleet.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    /// The fleet deploys its own reward ledger and voting controller in its own constructor, so
    /// there is no window in which it exists without them.
    function deploy(Manifest memory manifest) public returns (Deployment memory deployment) {
        _requireManifestFitsChain(manifest);

        deployment.registry = manifest.assetRegistry == address(0)
            ? new KeyfleetAssetRegistry(manifest.regentSafe, manifest.usdc)
            : KeyfleetAssetRegistry(manifest.assetRegistry);
        if (deployment.registry.REGENT_SAFE() != manifest.regentSafe) {
            revert RegistrySafeMismatch(manifest.regentSafe, deployment.registry.REGENT_SAFE());
        }

        deployment.fleet = new Keyfleet(
            _presets()[manifest.slot],
            IERC20(manifest.usdc),
            manifest.treasury,
            deployment.registry,
            IRegentRevenueStaking(manifest.staking),
            IRegentsAutolaunchFactoryV1(manifest.autolaunchFactory),
            manifest.votingWindow,
            Keyfleet.Metadata({
                name: manifest.fleet.name, symbol: manifest.fleet.symbol, baseTokenURI: manifest.fleet.baseTokenURI
            }),
            manifest.vrf,
            manifest.traitTableHash
        );
    }
}
