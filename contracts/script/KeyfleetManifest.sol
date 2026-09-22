// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";

/// @notice The input manifest both deployment steps share: its shape, its reader, and the two
/// refusals that hold for the manifest before anything is deployed or recorded.
/// @dev `parseManifest` takes the JSON text and `readManifest` is the only part that opens a file,
/// so the suite parses manifests without writing any.
abstract contract KeyfleetManifest is Script {
    /// @notice The chain the release deploys to. A manifest naming it is held to the strictest
    /// checks the deployment has.
    uint256 public constant BASE_CHAIN_ID = 8453;

    /// @notice What one fleet is deployed with. The three metadata fields are `Keyfleet.Metadata`.
    /// @param q Reference price in atomic REGENT units.
    /// @param name ERC721 collection name.
    /// @param symbol ERC721 collection symbol.
    /// @param baseTokenURI Metadata base for this fleet's keys.
    struct FleetSpec {
        uint256 q;
        string name;
        string symbol;
        string baseTokenURI;
    }

    /// @notice One deployment's complete inputs.
    /// @param chainId The chain this manifest is for. Both steps refuse any other.
    /// @param regent The REGENT token every primary purchase is paid in.
    /// @param usdc The canonical USDC of this chain, and the only fee that takes the staking route.
    /// @param treasury The Regents treasury, paid its share of every purchase.
    /// @param staking The Regents revenue staking contract that registers USDC fees.
    /// @param regentSafe The Safe that administers deposit admission, bound into a new registry.
    /// @param autolaunchFactory The one Autolaunch factory the fleets may ever launch through.
    /// @param assetRegistry An existing shared registry, or zero to deploy one for this release.
    /// @param autolaunchFactoryMayBeEmpty Whether the Autolaunch factory may have no code yet. It
    /// is ignored on Base, where the factory must already exist.
    /// @param votingWindow Seconds a proposal stays open, identical on all four fleets.
    /// @param fleets Syndicate, Cascade, Classic and Accelerant, in that order.
    struct Manifest {
        uint256 chainId;
        address regent;
        address usdc;
        address treasury;
        address staking;
        address regentSafe;
        address autolaunchFactory;
        address assetRegistry;
        bool autolaunchFactoryMayBeEmpty;
        uint64 votingWindow;
        FleetSpec[4] fleets;
    }

    /// @notice The manifest is for another chain.
    error WrongChain(uint256 expected, uint256 actual);
    /// @notice The Autolaunch factory address holds no code and the manifest does not allow that.
    error AutolaunchFactoryMissing(address factory);
    /// @notice The manifest's voting window does not fit the seconds a fleet is deployed with. The
    /// controller bounds it far more tightly again, to one hour through thirty days.
    error VotingWindowTooLarge(uint256 votingWindow);

    /// @notice Reads `deployments/<manifestName>.json`.
    function readManifest(string memory manifestName) public view returns (Manifest memory) {
        return parseManifest(vm.readFile(string.concat("deployments/", manifestName, ".json")));
    }

    /// @notice Parses manifest JSON into the value both steps take.
    /// @dev Every field is read by name rather than decoded from the whole object, so the file is
    /// keyed by what it says and not by the order it says it in. `q` is a decimal string because a
    /// reference price is far above the range a JSON number carries exactly.
    function parseManifest(string memory json) public pure returns (Manifest memory manifest) {
        manifest.chainId = vm.parseJsonUint(json, ".chainId");
        manifest.regent = vm.parseJsonAddress(json, ".regent");
        manifest.usdc = vm.parseJsonAddress(json, ".usdc");
        manifest.treasury = vm.parseJsonAddress(json, ".treasury");
        manifest.staking = vm.parseJsonAddress(json, ".staking");
        manifest.regentSafe = vm.parseJsonAddress(json, ".regentSafe");
        manifest.autolaunchFactory = vm.parseJsonAddress(json, ".autolaunchFactory");
        manifest.assetRegistry = vm.parseJsonAddress(json, ".assetRegistry");
        manifest.autolaunchFactoryMayBeEmpty = vm.parseJsonBool(json, ".autolaunchFactoryMayBeEmpty");
        uint256 votingWindow = vm.parseJsonUint(json, ".votingWindow");
        if (votingWindow > type(uint64).max) revert VotingWindowTooLarge(votingWindow);
        manifest.votingWindow = uint64(votingWindow);

        string[4] memory keys = _fleetKeys();
        for (uint256 slot = 0; slot < 4; ++slot) {
            string memory key = string.concat(".fleets.", keys[slot]);
            manifest.fleets[slot] = FleetSpec({
                q: vm.parseUint(vm.parseJsonString(json, string.concat(key, ".q"))),
                name: vm.parseJsonString(json, string.concat(key, ".name")),
                symbol: vm.parseJsonString(json, string.concat(key, ".symbol")),
                baseTokenURI: vm.parseJsonString(json, string.concat(key, ".baseTokenURI"))
            });
        }
    }

    /// @dev The manifest's chain must be this chain, and its Autolaunch factory must hold code
    /// unless the manifest waives that for a lab. The waiver is ignored on Base.
    function _requireChainAndFactory(Manifest memory manifest) internal view {
        if (block.chainid != manifest.chainId) revert WrongChain(manifest.chainId, block.chainid);
        if (!_factoryMayBeEmpty(manifest) && manifest.autolaunchFactory.code.length == 0) {
            revert AutolaunchFactoryMissing(manifest.autolaunchFactory);
        }
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
