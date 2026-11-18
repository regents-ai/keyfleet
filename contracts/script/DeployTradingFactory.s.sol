// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {console2} from "forge-std/console2.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetTradingFactory} from "../src/KeyfleetTradingFactory.sol";
import {IKeyfleetFactory} from "../src/KeyfleetWiring.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "./KeyfleetSafeSteps.s.sol";

/// @notice Deploys the Trading Fleet factory on a Keyfleet system that is already live, and prints
/// the Regents Safe's call that lets it register fleets.
/// @dev One transaction from one account: the trading factory, whose constructor reads the
/// collection, the shard record, USDC and REGENT revenue staking from the existing factory and
/// deploys its own three deployers. The existing factory is the one the deployment step's latest
/// broadcast on this chain created, and it must be the manifest's: the manifest's Safe, REGENT
/// revenue staking and USDC.
///
/// The trading factory can register nothing until the Safe calls `KeyfleetKeys.addFactory` with
/// its address. This script does not make that call: it runs it once from the Safe's address
/// against this run's copy of the chain, so a call that would revert stops the script with the
/// collection's own error, then prints it, as the call's target and data and as a Safe Transaction
/// Builder batch, for the Safe's signers to check and sign. Like the deployment step it writes no
/// file, since a dry run would write the same file.
///
/// `deploy` and `addFactoryCall` take values and touch neither the filesystem nor the environment,
/// so the suite runs them against systems deployed in the test; `run` is the only part that reads a
/// file or an environment variable.
contract DeployTradingFactory is KeyfleetManifest {
    /// @notice The existing factory has no code on this chain.
    error FactoryMissing(address factory);
    /// @notice The existing factory's `field` differs from the manifest's.
    error FactoryMismatch(string field);

    /// @notice Reads the manifest named by `KEYFLEET_MANIFEST` and the deployment step's broadcast,
    /// deploys the trading factory and prints the Safe's call adding it to the collection.
    /// @dev Signing is the caller's business (`--ledger` or `--trezor`); this script never reads a
    /// private key. The printed address is the one this run's simulation gives; the signers check
    /// it against the broadcast's receipt before they sign.
    function run() external {
        Manifest memory manifest = readManifest(vm.envString("KEYFLEET_MANIFEST"));
        KeyfleetFactory factory = readBroadcast().factory;

        vm.startBroadcast();
        KeyfleetTradingFactory trading = deploy(manifest, factory);
        vm.stopBroadcast();

        KeyfleetSafeSteps.SafeCall memory call = addFactoryCall(trading);
        vm.prank(manifest.bindings.safe);
        Address.functionCall(call.to, call.data);

        console2.log("Trading factory:", address(trading));
        console2.log("Safe:", manifest.bindings.safe);
        console2.log("Safe call to:", call.to);
        console2.log("Safe call value: 0");
        console2.log("Safe call data:", vm.toString(call.data));
        console2.log("Safe Transaction Builder batch:");
        console2.log(new KeyfleetSafeSteps().safeBatch(manifest.bindings.safe, call));
    }

    /// @notice Deploys the trading factory on `factory`, once `factory` is checked against the
    /// manifest.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    function deploy(Manifest memory manifest, KeyfleetFactory factory) public returns (KeyfleetTradingFactory) {
        _requireManifestFitsChain(manifest);
        if (address(factory).code.length == 0) revert FactoryMissing(address(factory));
        _match(factory.SAFE() == manifest.bindings.safe, "safe");
        _match(factory.REGENT_STAKING() == manifest.bindings.staking, "regentStaking");
        _match(address(factory.USDC()) == manifest.bindings.route.usdc, "route.usdc");
        return new KeyfleetTradingFactory(IKeyfleetFactory(address(factory)));
    }

    /// @notice The Safe's call letting `trading` register fleets in the collection.
    function addFactoryCall(KeyfleetTradingFactory trading) public view returns (KeyfleetSafeSteps.SafeCall memory) {
        return KeyfleetSafeSteps.SafeCall({
            name: "add-trading-factory",
            to: address(trading.KEYS()),
            data: abi.encodeCall(KeyfleetKeys.addFactory, (address(trading)))
        });
    }

    function _match(bool matches, string memory field) private pure {
        if (!matches) revert FactoryMismatch(field);
    }
}
