// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice Step one of two: deploys one fleet, and writes nothing.
/// @dev Each fleet goes on chain on its own run.
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
/// The script moves no token and does not touch the VRF subscription: the Safe owns it and adds the
/// fleet as a consumer afterwards.
contract DeployKeyfleets is KeyfleetManifest {
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

    /// @notice Deploys the manifest's fleet.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    /// The fleet deploys its own reward ledger and voting controller in its own constructor, so
    /// there is no window in which it exists without them.
    function deploy(Manifest memory manifest) public returns (Keyfleet fleet) {
        _requireManifestFitsChain(manifest);

        fleet = new Keyfleet(
            _presets()[manifest.slot],
            IERC20(manifest.usdc),
            IERC20(manifest.regent),
            IRegentRevenueStaking(manifest.staking),
            IRegentsAutolaunchFactoryV2(manifest.autolaunchFactory),
            Keyfleet.Metadata({
                name: manifest.fleet.name, symbol: manifest.fleet.symbol, baseTokenURI: manifest.fleet.baseTokenURI
            }),
            manifest.vrf,
            manifest.traitTableHash
        );
    }
}
