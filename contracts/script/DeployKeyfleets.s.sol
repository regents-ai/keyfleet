// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetDirectory} from "../src/KeyfleetDirectory.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice Step one of two: deploys the release — the shared asset registry if it is needed, the
/// four fixed fleets, and the directory that names them — and writes nothing.
/// @dev Forge simulates a script in full before it broadcasts anything, so any file this step
/// wrote would be written by a dry run too, and by a broadcast that failed partway. The deployed
/// manifest is therefore written by `RecordKeyfleets`, which runs after the broadcast and reads
/// every value back from the chain.
///
/// `deploy` takes a `Manifest` value and touches neither the filesystem nor the environment, so
/// the suite runs the real deployment against local mocks; `run` is the only part that reads a
/// file or an environment variable.
///
/// The script sets no allowlist flag and moves no token. Deposit admission belongs to the Regents
/// Safe alone, and USDC and REGENT are admitted by the Safe after this script has run. Nor does it
/// touch the VRF subscription: the Safe owns it and adds the four fleets as consumers afterwards.
contract DeployKeyfleets is KeyfleetManifest {
    /// @notice What one run of `deploy` created or reused.
    /// @param registry The shared asset registry, whether newly deployed or supplied.
    /// @param directory The directory naming the four fleets.
    /// @param fleets The four fleets, in the directory's slot order.
    struct Deployment {
        KeyfleetAssetRegistry registry;
        KeyfleetDirectory directory;
        Keyfleet[4] fleets;
    }

    /// @notice The supplied registry is administered by a different Safe than the manifest names.
    error RegistrySafeMismatch(address expected, address found);

    /// @notice Reads the named manifest and deploys from it.
    /// @dev The manifest name comes from `KEYFLEET_MANIFEST`, which is required: there is no
    /// default, because a default would pick a chain for the operator. Signing is the caller's
    /// business — `--ledger` or `--trezor` — and this script never reads a private key. The record
    /// step reads the broadcast Forge writes, so the deployment is sent by Forge itself.
    function run() external {
        Manifest memory manifest = readManifest(vm.envString("KEYFLEET_MANIFEST"));

        vm.startBroadcast();
        deploy(manifest);
        vm.stopBroadcast();
    }

    /// @notice Deploys the registry if the manifest does not name one, the four fleets and the
    /// directory.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    /// Deployment order is fixed: registry, Syndicate, Cascade, Classic, Accelerant, directory.
    /// Each fleet deploys its own reward ledger and voting controller in its own constructor, so
    /// there is no window in which a fleet exists without them. The directory's constructor
    /// refuses a set whose presets are out of order or whose shared wiring differs.
    function deploy(Manifest memory manifest) public returns (Deployment memory deployment) {
        _requireManifestFitsChain(manifest);

        deployment.registry = manifest.assetRegistry == address(0)
            ? new KeyfleetAssetRegistry(manifest.regentSafe, manifest.usdc)
            : KeyfleetAssetRegistry(manifest.assetRegistry);
        if (deployment.registry.REGENT_SAFE() != manifest.regentSafe) {
            revert RegistrySafeMismatch(manifest.regentSafe, deployment.registry.REGENT_SAFE());
        }

        KeyfleetPresets.Preset[4] memory presets = _presets();
        for (uint8 slot = 0; slot < 4; ++slot) {
            deployment.fleets[slot] = new Keyfleet(
                presets[slot],
                IERC20(manifest.usdc),
                manifest.treasury,
                deployment.registry,
                IRegentRevenueStaking(manifest.staking),
                IRegentsAutolaunchFactoryV1(manifest.autolaunchFactory),
                manifest.votingWindow,
                Keyfleet.Metadata({
                    name: manifest.fleets[slot].name,
                    symbol: manifest.fleets[slot].symbol,
                    baseTokenURI: manifest.fleets[slot].baseTokenURI
                }),
                manifest.vrf,
                manifest.traitTableHash
            );
        }

        deployment.directory = new KeyfleetDirectory(
            deployment.fleets[0], deployment.fleets[1], deployment.fleets[2], deployment.fleets[3]
        );
    }
}
