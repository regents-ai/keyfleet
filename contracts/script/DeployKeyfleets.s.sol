// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";
import {KeyfleetSystem} from "./KeyfleetSystem.sol";

/// @notice Step one: deploys the Keyfleet system once per chain, and writes nothing.
/// @dev Five transactions from one account: the four deployers, then the factory, whose
/// constructor deploys the collection, the shard record and the REGENT buyer. No fleet exists
/// afterwards; the Safe creates the founding fleets with `KeyfleetSafeSteps`.
///
/// Forge simulates a script in full before it broadcasts anything, so any file this step wrote
/// would be written by a dry run too, and by a broadcast that failed partway. The deployed record
/// is therefore written by `RecordKeyfleets`, which runs afterwards and reads every value back from
/// the chain.
///
/// `deploy` takes a `Manifest` value and touches neither the filesystem nor the environment, so
/// the suite runs the real deployment against local stand-ins; `run` is the only part that reads a
/// file or an environment variable. The script moves no token and does not touch the VRF
/// subscription: the Safe owns it and adds the collection as its consumer.
contract DeployKeyfleets is KeyfleetManifest {
    /// @notice Reads the manifest named by `KEYFLEET_MANIFEST` and deploys the system.
    /// @dev There is no default manifest, because a default would pick a chain for the operator.
    /// Signing is the caller's business (`--ledger` or `--trezor`); this script never reads a
    /// private key.
    function run() external {
        Manifest memory manifest = readManifest(vm.envString("KEYFLEET_MANIFEST"));

        vm.startBroadcast();
        deploy(manifest);
        vm.stopBroadcast();
    }

    /// @notice Deploys the system the manifest describes.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    function deploy(Manifest memory manifest) public returns (KeyfleetFactory) {
        _requireManifestFitsChain(manifest);
        return KeyfleetSystem.deploy(manifest.bindings);
    }
}
