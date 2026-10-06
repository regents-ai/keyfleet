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
/// key, so each fleet goes on chain on its own. `parseManifest` and `parseSharedWiring` take the
/// JSON text and `readManifest` and `readSharedWiring` are the only parts that open a file, so the
/// suite parses manifests without writing any.
abstract contract KeyfleetManifest is Script {
    /// @notice The chain the release deploys to: Base mainnet. A manifest naming it is held to the
    /// strictest checks the deployment has.
    uint256 public constant BASE_CHAIN_ID = 8453;
    /// @notice Native USDC on Base, the only USDC a manifest may name there. Every key price assumes
    /// its six decimals. Source: Circle's USDC contract addresses page.
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice REGENT on Base, the token Regent pins in Autolaunch's Base bindings. 18 decimals.
    address public constant BASE_REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    /// @notice REGENT revenue staking on Base (verified source `RegentRevenueStaking`), the only
    /// staking contract a manifest may name there. Every fleet's protocol share is deposited into it
    /// through `depositUSDC`, the only way revenue counts there.
    address public constant BASE_REGENT_REVENUE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// @notice The Regents Safe on Base, a 2-of-3 Safe v1.4.1. It owns the staking contract and the
    /// VRF subscription. The same address on Ethereum is a different Safe with different signers.
    address public constant BASE_REGENTS_SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    /// @notice The Chainlink VRF v2.5 coordinator on Base, the only one a manifest may name there.
    /// Source: Chainlink's VRF v2.5 supported-networks page, Base Mainnet.
    address public constant BASE_VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    /// @notice The Base VRF gas lane with the 2 gwei price cap, the lane the release uses.
    bytes32 public constant BASE_VRF_KEY_HASH_2_GWEI =
        0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab;
    /// @notice The Base VRF gas lane with the 30 gwei price cap, the only other lane a manifest may
    /// name there.
    bytes32 public constant BASE_VRF_KEY_HASH_30_GWEI =
        0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;

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
    /// @param usdc The USDC every key is paid in, and every fleet's one income token. On Base it
    /// must be `BASE_USDC`.
    /// @param regentStaking Where every fleet's treasury deposits the 10% protocol share. On Base it
    /// must be `BASE_REGENT_REVENUE_STAKING`.
    /// @param vrf The VRF coordinator, subscription and gas lane, the same for every fleet on the
    /// chain. On Base the coordinator must be `BASE_VRF_COORDINATOR` and the gas lane one of the two
    /// Base lanes.
    /// @param traitTableHash `keccak256` of the published trait-table file, byte for byte, the same
    /// for every fleet on the chain. Never zero.
    /// @param slot The fleet's slot: 0 Syndicate, 1 Cascade, 2 Classic, 3 Accelerant. It decides
    /// the fleet's preset.
    /// @param fleet The fleet's name, symbol and metadata base, from the file's `fleets.<key>`.
    struct Manifest {
        uint256 chainId;
        address usdc;
        address regentStaking;
        Keyfleet.Randomness vrf;
        bytes32 traitTableHash;
        uint8 slot;
        FleetSpec fleet;
    }

    /// @notice The manifest is for another chain.
    error WrongChain(uint256 expected, uint256 actual);
    /// @notice A Base manifest names a USDC other than native USDC on Base.
    error UsdcNotBaseUsdc(address usdc);
    /// @notice A Base manifest names a VRF coordinator other than Base's.
    error VrfCoordinatorNotBase(address coordinator);
    /// @notice A Base manifest names a VRF gas lane other than Base's 2 gwei or 30 gwei lane.
    error VrfKeyHashNotBase(bytes32 keyHash);
    /// @notice A Base manifest names a staking contract other than REGENT revenue staking.
    error RegentStakingNotBase(address regentStaking);
    /// @notice The manifest's staking address holds no code on this chain.
    error RegentStakingMissing(address regentStaking);
    /// @notice The manifest's VRF coordinator address holds no code on this chain.
    error VrfCoordinatorMissing(address coordinator);
    /// @notice The coordinator has no proving key for the manifest's gas lane.
    error VrfKeyHashUnknown(bytes32 keyHash);
    /// @notice No fleet has this key.
    error UnknownFleet(string fleetKey);

    /// @notice Reads `deployments/<manifestName>.json` for the fleet with key `fleetKey`.
    function readManifest(string memory manifestName, string memory fleetKey)
        public
        view
        returns (Manifest memory manifest)
    {
        return parseManifest(vm.readFile(string.concat("deployments/", manifestName, ".json")), fleetKey);
    }

    /// @notice Reads what every fleet shares from `deployments/<manifestName>.json`, naming no fleet.
    function readSharedWiring(string memory manifestName) public view returns (Manifest memory manifest) {
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
        manifest.usdc = vm.parseJsonAddress(json, ".usdc");
        manifest.regentStaking = vm.parseJsonAddress(json, ".regentStaking");
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

    /// @dev The manifest must fit this chain. Its chain must be this chain. On Base its USDC,
    /// staking contract, VRF coordinator and gas lane must be Base's own, and on every chain the
    /// staking contract must hold code and the coordinator must hold code, know the gas lane and
    /// know the subscription; a subscription it does not know reverts with the coordinator's own
    /// `InvalidSubscription`. The trait table hash must not be zero.
    function _requireManifestFitsChain(Manifest memory manifest) internal view {
        if (block.chainid != manifest.chainId) revert WrongChain(manifest.chainId, block.chainid);
        address coordinator = address(manifest.vrf.coordinator);
        if (block.chainid == BASE_CHAIN_ID) {
            if (manifest.usdc != BASE_USDC) revert UsdcNotBaseUsdc(manifest.usdc);
            if (coordinator != BASE_VRF_COORDINATOR) revert VrfCoordinatorNotBase(coordinator);
            bytes32 keyHash = manifest.vrf.keyHash;
            if (keyHash != BASE_VRF_KEY_HASH_2_GWEI && keyHash != BASE_VRF_KEY_HASH_30_GWEI) {
                revert VrfKeyHashNotBase(keyHash);
            }
            if (manifest.regentStaking != BASE_REGENT_REVENUE_STAKING) {
                revert RegentStakingNotBase(manifest.regentStaking);
            }
        }
        if (manifest.regentStaking.code.length == 0) revert RegentStakingMissing(manifest.regentStaking);
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
