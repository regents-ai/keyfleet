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
/// deploys its own three deployers. The existing factory is, on Base, the live one pinned here
/// beside the live collection, so a run on Base needs no file but the manifest; on any other chain
/// it is the one the deployment step's latest broadcast on that chain created. Nothing is deployed
/// until it is proven to be the live one: its collection is the live collection (on Base, the
/// address pinned here; on every chain, the manifest's Safe, name, symbol, metadata links and trait
/// table), that collection lists it as a factory, and it has the manifest's Safe, REGENT revenue
/// staking and USDC.
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
    /// @notice The live Keyfleet collection on Base, deployed by the release and read from Base on
    /// 18 November 2026.
    address public constant BASE_KEYFLEET_COLLECTION = 0xaBC959B463542497639adA57388c65D05AB34A30;
    /// @notice The live Keyfleet factory on Base, read from Base on 18 November 2026: the collection
    /// is its first creation, it names that collection, and the collection lists it as a factory.
    address public constant BASE_KEYFLEET_FACTORY = 0x82F62aE092DcF99fFa7fF15a9ac63488D5b4F5C7;

    /// @notice The existing factory has no code on this chain.
    error FactoryMissing(address factory);
    /// @notice On Base, the existing factory's collection is not the live one.
    error CollectionNotPinned(address collection);
    /// @notice The existing factory's collection's `field` differs from the manifest's.
    error CollectionMismatch(string field);
    /// @notice The collection does not list the existing factory as one of its factories.
    error FactoryNotListed(address factory, address collection);
    /// @notice The existing factory's `field` differs from the manifest's.
    error FactoryMismatch(string field);

    /// @notice Reads the manifest named by `KEYFLEET_MANIFEST`, takes the existing factory (on Base
    /// the pinned one, elsewhere the deployment step's broadcast), deploys the trading factory and
    /// prints the Safe's call adding it to the collection.
    /// @dev Signing is the caller's business (`--ledger` or `--trezor`); this script never reads a
    /// private key. The printed address is the one this run's simulation gives; the signers check
    /// it against the broadcast's receipt before they sign.
    /// @return trading The trading factory this run deployed.
    /// @return call The Safe's call it printed.
    function run() external returns (KeyfleetTradingFactory trading, KeyfleetSafeSteps.SafeCall memory call) {
        Manifest memory manifest = readManifest(vm.envString("KEYFLEET_MANIFEST"));
        KeyfleetFactory factory =
            block.chainid == BASE_CHAIN_ID ? KeyfleetFactory(BASE_KEYFLEET_FACTORY) : readBroadcast().factory;

        vm.startBroadcast();
        trading = deploy(manifest, factory);
        vm.stopBroadcast();

        call = addFactoryCall(trading);
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

    /// @notice Deploys the trading factory on `factory`, once `factory` is proven to be the live
    /// collection's and checked against the manifest.
    /// @dev Reads no file and no environment variable, so this is the function the suite runs.
    function deploy(Manifest memory manifest, KeyfleetFactory factory) public returns (KeyfleetTradingFactory) {
        _requireManifestFitsChain(manifest);
        if (address(factory).code.length == 0) revert FactoryMissing(address(factory));
        KeyfleetKeys keys = factory.KEYS();
        if (block.chainid == BASE_CHAIN_ID && address(keys) != BASE_KEYFLEET_COLLECTION) {
            revert CollectionNotPinned(address(keys));
        }
        KeyfleetKeys.Collection memory collection = manifest.bindings.collection;
        _collection(keys.SAFE() == manifest.bindings.safe, "safe");
        _collection(_equal(keys.name(), collection.name), "name");
        _collection(_equal(keys.symbol(), collection.symbol), "symbol");
        _collection(_equal(keys.baseTokenURI(), collection.baseTokenURI), "baseTokenURI");
        _collection(_equal(keys.contractURI(), collection.contractURI), "contractURI");
        _collection(keys.TRAIT_TABLE_HASH() == manifest.bindings.traitTableHash, "traitTableHash");
        if (!keys.isFactory(address(factory))) revert FactoryNotListed(address(factory), address(keys));
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

    function _collection(bool matches, string memory field) private pure {
        if (!matches) revert CollectionMismatch(field);
    }

    function _match(bool matches, string memory field) private pure {
        if (!matches) revert FactoryMismatch(field);
    }
}
