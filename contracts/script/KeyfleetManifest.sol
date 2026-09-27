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
/// key, so each fleet goes on chain on its own. `parseManifest` and `parseSharedWiring` take the JSON text and `readManifest` and
/// `readSharedWiring` are the only parts that open a file, so the suite parses manifests without
/// writing any.
abstract contract KeyfleetManifest is Script {
    /// @notice The chain the release deploys to. A manifest naming it is held to the strictest
    /// checks the deployment has.
    uint256 public constant BASE_CHAIN_ID = 8453;
    /// @notice Base USDC, the only USDC a manifest may name on Base. Every key price assumes its six
    /// decimals.
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice Base REGENT, the only REGENT a manifest may name on Base.
    address public constant BASE_REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    /// @notice The Chainlink VRF v2.5 coordinator on Base, the only one a manifest may name there.
    address public constant BASE_VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    /// @notice The Base VRF gas lane with the 2 gwei price cap, the only one a manifest may name there.
    bytes32 public constant BASE_VRF_KEY_HASH = 0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab;

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
    /// @param regent The REGENT token, an income token of every fleet. It must hold code, and on
    /// Base it must be `BASE_REGENT`.
    /// @param usdc The USDC every key is paid in, and an income token of every fleet. On Base it
    /// must be `BASE_USDC`.
    /// @param staking The Regents revenue staking contract that registers the 2% protocol share of
    /// every purchase.
    /// @param regentSafe The Regents Safe, which owns the VRF subscription on Base.
    /// @param autolaunchFactory The one Autolaunch factory the fleets may ever launch through.
    /// @param autolaunchFactoryMayBeEmpty Whether the Autolaunch factory may have no code yet. It
    /// is ignored on Base, where the factory must already exist.
    /// @param vrf The VRF coordinator, subscription and gas lane, the same for every fleet on the
    /// chain. On Base the coordinator and gas lane must be `BASE_VRF_COORDINATOR` and
    /// `BASE_VRF_KEY_HASH`.
    /// @param traitTableHash `keccak256` of the published trait-table file, byte for byte, the same
    /// for every fleet on the chain. Never zero.
    /// @param slot The fleet's slot: 0 Syndicate, 1 Cascade, 2 Classic, 3 Accelerant. It decides
    /// the fleet's preset.
    /// @param fleet The fleet's name, symbol and metadata base, from the file's `fleets.<key>`.
    struct Manifest {
        uint256 chainId;
        address regent;
        address usdc;
        address staking;
        address regentSafe;
        address autolaunchFactory;
        bool autolaunchFactoryMayBeEmpty;
        Keyfleet.Randomness vrf;
        bytes32 traitTableHash;
        uint8 slot;
        FleetSpec fleet;
    }

    /// @notice The manifest is for another chain.
    error WrongChain(uint256 expected, uint256 actual);
    /// @notice A Base manifest names a USDC other than Base USDC.
    error UsdcNotBaseUsdc(address usdc);
    /// @notice A Base manifest names a REGENT other than Base REGENT.
    error RegentNotBaseRegent(address regent);
    /// @notice The manifest's REGENT address holds no code on this chain.
    error RegentMissing(address regent);
    /// @notice The Autolaunch factory address holds no code and the manifest does not allow that.
    error AutolaunchFactoryMissing(address factory);
    /// @notice A Base manifest names a VRF coordinator other than Base's.
    error VrfCoordinatorNotBase(address coordinator);
    /// @notice A Base manifest names a VRF gas lane other than Base's 2 gwei lane.
    error VrfKeyHashNotBase(bytes32 keyHash);
    /// @notice The manifest's VRF coordinator address holds no code on this chain.
    error VrfCoordinatorMissing(address coordinator);
    /// @notice The coordinator has no proving key for the manifest's gas lane.
    error VrfKeyHashUnknown(bytes32 keyHash);
    /// @notice No fleet has this key.
    error UnknownFleet(string fleetKey);

    /// @notice Reads `deployments/<manifestName>.json` for the fleet with key `fleetKey`.
    function readManifest(string memory manifestName, string memory fleetKey) public view returns (Manifest memory) {
        return parseManifest(vm.readFile(string.concat("deployments/", manifestName, ".json")), fleetKey);
    }

    /// @notice Reads what every fleet shares from `deployments/<manifestName>.json`, naming no fleet.
    function readSharedWiring(string memory manifestName) public view returns (Manifest memory) {
        return parseSharedWiring(vm.readFile(string.concat("deployments/", manifestName, ".json")));
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

    /// @notice Parses what every fleet on the manifest's chain shares, leaving the slot and the
    /// fleet empty.
    /// @dev Every field is read by name rather than decoded from the whole object, so the file is
    /// keyed by what it says and not by the order it says it in.
    function parseSharedWiring(string memory json) public pure returns (Manifest memory manifest) {
        manifest.chainId = vm.parseJsonUint(json, ".chainId");
        manifest.regent = vm.parseJsonAddress(json, ".regent");
        manifest.usdc = vm.parseJsonAddress(json, ".usdc");
        manifest.staking = vm.parseJsonAddress(json, ".staking");
        manifest.regentSafe = vm.parseJsonAddress(json, ".regentSafe");
        manifest.autolaunchFactory = vm.parseJsonAddress(json, ".autolaunchFactory");
        manifest.autolaunchFactoryMayBeEmpty = vm.parseJsonBool(json, ".autolaunchFactoryMayBeEmpty");
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

    /// @dev The manifest must fit this chain. Its chain must be this chain. On Base its USDC must be
    /// Base USDC and its REGENT Base REGENT, and on every chain its REGENT must hold code. Its
    /// Autolaunch factory must hold code unless the manifest waives that for a lab. The waiver is
    /// ignored on Base. On Base the VRF coordinator and gas lane must be Base's own, and on every
    /// chain the coordinator must hold code, know the gas lane and know the subscription; a
    /// subscription it does not know reverts with the coordinator's own `InvalidSubscription`. The
    /// trait table hash must not be zero.
    function _requireManifestFitsChain(Manifest memory manifest) internal view {
        if (block.chainid != manifest.chainId) revert WrongChain(manifest.chainId, block.chainid);
        address coordinator = address(manifest.vrf.coordinator);
        if (block.chainid == BASE_CHAIN_ID) {
            if (manifest.usdc != BASE_USDC) revert UsdcNotBaseUsdc(manifest.usdc);
            if (manifest.regent != BASE_REGENT) revert RegentNotBaseRegent(manifest.regent);
            if (coordinator != BASE_VRF_COORDINATOR) revert VrfCoordinatorNotBase(coordinator);
            if (manifest.vrf.keyHash != BASE_VRF_KEY_HASH) revert VrfKeyHashNotBase(manifest.vrf.keyHash);
        }
        if (manifest.regent.code.length == 0) revert RegentMissing(manifest.regent);
        if (!_factoryMayBeEmpty(manifest) && manifest.autolaunchFactory.code.length == 0) {
            revert AutolaunchFactoryMissing(manifest.autolaunchFactory);
        }
        if (coordinator.code.length == 0) revert VrfCoordinatorMissing(coordinator);
        (bool keyExists,) = IVRFProvingKeys(coordinator).s_provingKeys(manifest.vrf.keyHash);
        if (!keyExists) revert VrfKeyHashUnknown(manifest.vrf.keyHash);
        manifest.vrf.coordinator.getSubscription(manifest.vrf.subscriptionId);
        if (manifest.traitTableHash == bytes32(0)) revert Keyfleet.TraitTableHashZero();
    }

    /// @dev Whether the manifest's empty-factory waiver applies on this chain. It never does on Base.
    function _factoryMayBeEmpty(Manifest memory manifest) internal view returns (bool) {
        return manifest.autolaunchFactoryMayBeEmpty && block.chainid != BASE_CHAIN_ID;
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
