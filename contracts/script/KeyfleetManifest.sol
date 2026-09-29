// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";

/// @notice The VRF v2.5 coordinator's public proving-key table, which the vendored interface does
/// not declare.
interface IVRFProvingKeys {
    function s_provingKeys(bytes32 keyHash) external view returns (bool exists, uint64 maxGas);
}

/// @notice The input manifest both deployment steps share: its shape, its reader, and the
/// refusals that hold for the manifest before anything is deployed or recorded.
/// @dev A manifest file holds what every fleet on its chain shares and the name, symbol and
/// metadata base of each of the four fleets. One run deploys or records one fleet, named by its
/// key, so each fleet goes on chain on its own. The protocol treasury is not in the file: each run
/// takes it from `KEYFLEET_PROTOCOL_TREASURY`, which has no default. `parseManifest` and
/// `parseSharedWiring` take the JSON text and `readManifest` and `readSharedWiring` are the only
/// parts that open a file or read the environment, so the suite parses manifests without writing
/// any.
abstract contract KeyfleetManifest is Script {
    /// @notice The chain the release deploys to: Ethereum. A manifest naming it is held to the
    /// strictest checks the deployment has.
    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    /// @notice USDC on Ethereum, the only USDC a manifest may name there. Every key price assumes
    /// its six decimals.
    address public constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice The Chainlink VRF v2.5 coordinator on Ethereum, the only one a manifest may name
    /// there.
    address public constant ETHEREUM_VRF_COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
    /// @notice The Ethereum VRF gas lane with the 200 gwei price cap, the only one a manifest may
    /// name there.
    bytes32 public constant ETHEREUM_VRF_KEY_HASH = 0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9;

    /// @notice What one fleet is deployed with, which is exactly `Keyfleet.Metadata`.
    /// @param name ERC721 collection name.
    /// @param symbol ERC721 collection symbol.
    /// @param baseTokenURI Metadata base for this fleet's keys.
    struct FleetSpec {
        string name;
        string symbol;
        string baseTokenURI;
    }

    /// @notice One fleet's deployment inputs.
    /// @param chainId The chain this manifest is for. Both steps refuse any other.
    /// @param usdc The USDC every key is paid in, and every fleet's one income token. On Ethereum it
    /// must be `ETHEREUM_USDC`.
    /// @param protocolTreasury The Regents Safe, which receives the 10% protocol share of every
    /// purchase and, on Ethereum, owns the VRF subscription. Taken from
    /// `KEYFLEET_PROTOCOL_TREASURY`, never from the file.
    /// @param vrf The VRF coordinator, subscription and gas lane, the same for every fleet on the
    /// chain. On Ethereum the coordinator and gas lane must be `ETHEREUM_VRF_COORDINATOR` and
    /// `ETHEREUM_VRF_KEY_HASH`.
    /// @param traitTableHash `keccak256` of the published trait-table file, byte for byte, the same
    /// for every fleet on the chain. Never zero.
    /// @param slot The fleet's slot: 0 Syndicate, 1 Cascade, 2 Classic, 3 Accelerant. It decides
    /// the fleet's preset.
    /// @param fleet The fleet's name, symbol and metadata base, from the file's `fleets.<key>`.
    struct Manifest {
        uint256 chainId;
        address usdc;
        address protocolTreasury;
        Keyfleet.Randomness vrf;
        bytes32 traitTableHash;
        uint8 slot;
        FleetSpec fleet;
    }

    /// @notice The manifest is for another chain.
    error WrongChain(uint256 expected, uint256 actual);
    /// @notice An Ethereum manifest names a USDC other than USDC on Ethereum.
    error UsdcNotEthereumUsdc(address usdc);
    /// @notice An Ethereum manifest names a VRF coordinator other than Ethereum's.
    error VrfCoordinatorNotEthereum(address coordinator);
    /// @notice An Ethereum manifest names a VRF gas lane other than Ethereum's 200 gwei lane.
    error VrfKeyHashNotEthereum(bytes32 keyHash);
    /// @notice The manifest's VRF coordinator address holds no code on this chain.
    error VrfCoordinatorMissing(address coordinator);
    /// @notice The coordinator has no proving key for the manifest's gas lane.
    error VrfKeyHashUnknown(bytes32 keyHash);
    /// @notice No fleet has this key.
    error UnknownFleet(string fleetKey);

    /// @notice Reads `deployments/<manifestName>.json` for the fleet with key `fleetKey`, with the
    /// protocol treasury from `KEYFLEET_PROTOCOL_TREASURY`.
    function readManifest(string memory manifestName, string memory fleetKey)
        public
        view
        returns (Manifest memory manifest)
    {
        manifest = parseManifest(vm.readFile(string.concat("deployments/", manifestName, ".json")), fleetKey);
        manifest.protocolTreasury = vm.envAddress("KEYFLEET_PROTOCOL_TREASURY");
    }

    /// @notice Reads what every fleet shares from `deployments/<manifestName>.json`, naming no fleet,
    /// with the protocol treasury from `KEYFLEET_PROTOCOL_TREASURY`.
    function readSharedWiring(string memory manifestName) public view returns (Manifest memory manifest) {
        manifest = parseSharedWiring(vm.readFile(string.concat("deployments/", manifestName, ".json")));
        manifest.protocolTreasury = vm.envAddress("KEYFLEET_PROTOCOL_TREASURY");
    }

    /// @notice Parses manifest JSON into the value both fleet steps take, for the fleet with key
    /// `fleetKey`.
    function parseManifest(string memory json, string memory fleetKey) public pure returns (Manifest memory manifest) {
        manifest = parseSharedWiring(json);
        manifest.slot = fleetSlot(fleetKey);
        string memory key = string.concat(".fleets.", fleetKey);
        manifest.fleet = FleetSpec({
            name: vm.parseJsonString(json, string.concat(key, ".name")),
            symbol: vm.parseJsonString(json, string.concat(key, ".symbol")),
            baseTokenURI: vm.parseJsonString(json, string.concat(key, ".baseTokenURI"))
        });
    }

    /// @notice Parses what every fleet on the manifest's chain shares, leaving the protocol
    /// treasury, the slot and the fleet empty.
    /// @dev Every field is read by name rather than decoded from the whole object, so the file is
    /// keyed by what it says and not by the order it says it in.
    function parseSharedWiring(string memory json) public pure returns (Manifest memory manifest) {
        manifest.chainId = vm.parseJsonUint(json, ".chainId");
        manifest.usdc = vm.parseJsonAddress(json, ".usdc");
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(vm.parseJsonAddress(json, ".vrf.coordinator")),
            subscriptionId: vm.parseJsonUint(json, ".vrf.subscriptionId"),
            keyHash: vm.parseJsonBytes32(json, ".vrf.keyHash")
        });
        manifest.traitTableHash = vm.parseJsonBytes32(json, ".traitTableHash");
    }

    /// @notice The slot of the fleet with key `fleetKey`: `syndicate`, `cascade`, `classic` or
    /// `accelerant`.
    function fleetSlot(string memory fleetKey) public pure returns (uint8) {
        string[4] memory keys = _fleetKeys();
        for (uint8 slot = 0; slot < 4; ++slot) {
            if (keccak256(bytes(keys[slot])) == keccak256(bytes(fleetKey))) return slot;
        }
        revert UnknownFleet(fleetKey);
    }

    /// @dev The manifest must fit this chain. Its chain must be this chain. On Ethereum its USDC,
    /// VRF coordinator and gas lane must be Ethereum's own, and on every chain the protocol
    /// treasury must not be zero and the coordinator must hold code, know the gas lane and know the
    /// subscription; a subscription it does not know reverts with the coordinator's own
    /// `InvalidSubscription`. The trait table hash must not be zero.
    function _requireManifestFitsChain(Manifest memory manifest) internal view {
        if (block.chainid != manifest.chainId) revert WrongChain(manifest.chainId, block.chainid);
        address coordinator = address(manifest.vrf.coordinator);
        if (block.chainid == ETHEREUM_CHAIN_ID) {
            if (manifest.usdc != ETHEREUM_USDC) revert UsdcNotEthereumUsdc(manifest.usdc);
            if (coordinator != ETHEREUM_VRF_COORDINATOR) revert VrfCoordinatorNotEthereum(coordinator);
            if (manifest.vrf.keyHash != ETHEREUM_VRF_KEY_HASH) revert VrfKeyHashNotEthereum(manifest.vrf.keyHash);
        }
        if (manifest.protocolTreasury == address(0)) revert Keyfleet.ZeroAddress();
        if (coordinator.code.length == 0) revert VrfCoordinatorMissing(coordinator);
        (bool keyExists,) = IVRFProvingKeys(coordinator).s_provingKeys(manifest.vrf.keyHash);
        if (!keyExists) revert VrfKeyHashUnknown(manifest.vrf.keyHash);
        manifest.vrf.coordinator.getSubscription(manifest.vrf.subscriptionId);
        if (manifest.traitTableHash == bytes32(0)) revert Keyfleet.TraitTableHashZero();
    }

    /// @dev The manifest's fleet keys, in slot order.
    function _fleetKeys() internal pure returns (string[4] memory) {
        return ["syndicate", "cascade", "classic", "accelerant"];
    }

    /// @dev The preset each slot holds, in slot order.
    function _presets() internal pure returns (KeyfleetPresets.Preset[4] memory) {
        return [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];
    }
}
