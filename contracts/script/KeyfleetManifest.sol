// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {V4PoolKey} from "../src/interfaces/IUniswapV4PoolManager.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {KeyfleetSystem} from "./KeyfleetSystem.sol";

/// @notice The VRF v2.5 coordinator's public proving-key table, which the vendored interface does
/// not declare.
interface IVRFProvingKeys {
    function s_provingKeys(bytes32 keyHash) external view returns (bool exists, uint64 maxGas);
}

/// @notice The input manifest every deployment step shares: its shape, its reader, the refusals
/// that hold before anything is deployed, sent or recorded, and the reader of the deployment's
/// broadcast.
/// @dev A manifest file holds what the whole system is deployed with, once per chain, and the
/// deck and profile of each of the five founding fleets. `parseManifest` and `parseBroadcast` take
/// JSON text and `readManifest` and `readBroadcast` are the only parts that open a file, so the
/// suite parses manifests and broadcasts without writing any.
abstract contract KeyfleetManifest is Script {
    /// @notice Base mainnet, the chain the release deploys to. A manifest naming it is held to every
    /// Base pin below.
    uint256 public constant BASE_CHAIN_ID = 8453;
    /// @notice A local anvil chain. The Safe steps send their calls directly there.
    uint256 public constant ANVIL_CHAIN_ID = 31_337;

    /// @notice The Regents Safe on Base, a 2-of-3 Safe v1.4.1: runs the collection's phases and
    /// creates the founding fleets. The same address on Ethereum is a different Safe.
    address public constant BASE_REGENTS_SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    /// @notice Native USDC on Base, which every key is paid in. Source: Circle's USDC contract
    /// addresses page.
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @notice WETH on Base, between the two legs of the REGENT route.
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    /// @notice REGENT on Base, the token Regent pins in Autolaunch's Base bindings. 18 decimals.
    address public constant BASE_REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    /// @notice REGENT revenue staking on Base (verified source `RegentRevenueStaking`), where every
    /// fleet's protocol share is deposited.
    address public constant BASE_REGENT_REVENUE_STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    /// @notice Autolaunch Revstake v2's factory on Base (`RegentsAutolaunchFactoryV2`, deployed 6
    /// October 2026), the only launch factory a treasury may bind.
    address public constant BASE_AUTOLAUNCH_FACTORY = 0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E;
    /// @notice The Regents Club Pass collection on Base (on-chain name "Animata Access Card - Regent",
    /// 1,998 Passes): Pass N names who receives Regents Club key N.
    address public constant BASE_REGENTS_CLUB_PASS = 0x2208aaDBdEcd47D3B4430b5b75a175f6d885D487;
    /// @notice The Chainlink VRF v2.5 coordinator on Base. Source: Chainlink's VRF v2.5
    /// supported-networks page, Base Mainnet.
    address public constant BASE_VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    /// @notice The Base VRF gas lane with the 2 gwei price cap, the lane the release uses.
    bytes32 public constant BASE_VRF_KEY_HASH_2_GWEI =
        0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab;
    /// @notice The Base VRF gas lane with the 30 gwei price cap, the only other lane a Base
    /// manifest may name.
    bytes32 public constant BASE_VRF_KEY_HASH_30_GWEI =
        0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;
    /// @notice The Uniswap v3 USDC/WETH pool of the route's first leg (0.05% fee).
    address public constant BASE_USDC_WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    /// @notice The Uniswap v4 PoolManager on Base, which holds the route's second leg.
    address public constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    /// @notice The WETH/REGENT v4 pool's fee field: the dynamic-fee flag.
    uint24 public constant BASE_REGENT_POOL_FEE = 0x800000;
    /// @notice The WETH/REGENT v4 pool's tick spacing.
    int24 public constant BASE_REGENT_POOL_TICK_SPACING = 200;
    /// @notice The WETH/REGENT v4 pool's hook.
    address public constant BASE_REGENT_POOL_HOOKS = 0xd60D6B218116cFd801E28F78d011a203D2b068Cc;
    /// @notice The collection's name on Base (Sean, KF-SOL-8).
    string public constant BASE_COLLECTION_NAME = "Keyfleet";
    /// @notice The collection's symbol on Base (Sean, KF-SOL-8).
    string public constant BASE_COLLECTION_SYMBOL = "KEYFLEET";
    /// @notice The fixed metadata base on Base: each key's metadata on keyfleet.ai (Sean, KF-SOL-5).
    string public constant BASE_METADATA_BASE = "https://keyfleet.ai/metadata/keys/";

    /// @notice One founding fleet's creation inputs.
    /// @param preset Its type.
    /// @param deckHash `keccak256` of its deck file, byte for byte.
    /// @param deckSize How many cards its deck holds.
    /// @param profile Its name, description and image link.
    struct FoundingFleet {
        KeyfleetPresets.Preset preset;
        bytes32 deckHash;
        uint256 deckSize;
        KeyfleetManager.Profile profile;
    }

    /// @notice What the system on one chain is deployed and founded with.
    /// @param chainId The chain this manifest is for. Every step refuses any other.
    /// @param bindings What the factory is deployed with.
    /// @param founding The five founding fleets in creation order: fleet 1 to fleet 5.
    struct Manifest {
        uint256 chainId;
        KeyfleetSystem.Bindings bindings;
        FoundingFleet[5] founding;
    }

    /// @notice What the deployment step's broadcast establishes.
    /// @param factory The factory the broadcast created.
    /// @param deploymentBlock The lowest block any of the broadcast's transactions landed in, so a
    /// reader starting there sees every event of the system from its first block.
    struct BroadcastSummary {
        KeyfleetFactory factory;
        uint256 deploymentBlock;
    }

    /// @notice The manifest is for another chain.
    error WrongChain(uint256 expected, uint256 actual);
    /// @notice A Base manifest names something other than Base's own for `field`.
    error NotBasePin(string field);
    /// @notice The coordinator has no proving key for the manifest's gas lane.
    error VrfKeyHashUnknown(bytes32 keyHash);
    /// @notice The broadcast has transactions without receipts: it did not finish.
    error BroadcastIncomplete(uint256 transactions, uint256 receipts);
    /// @notice The receipt at `index` did not succeed.
    error BroadcastReceiptFailed(uint256 index);
    /// @notice The broadcast names no `KeyfleetFactory`.
    error FactoryNotInBroadcast();

    /// @notice Reads `deployments/<manifestName>.json`.
    function readManifest(string memory manifestName) public view returns (Manifest memory) {
        return parseManifest(vm.readFile(string.concat("deployments/", manifestName, ".json")));
    }

    /// @notice Reads the deployment step's latest broadcast on this chain.
    function readBroadcast() public view returns (BroadcastSummary memory) {
        return parseBroadcast(
            vm.readFile(
                string.concat("broadcast/DeployKeyfleets.s.sol/", vm.toString(block.chainid), "/run-latest.json")
            )
        );
    }

    /// @notice Parses manifest JSON.
    /// @dev Every field is read by name rather than decoded from the whole object, so the file is
    /// keyed by what it says and not by the order it says it in. The founding fleets are keyed by
    /// type and read in the collection's founding order.
    function parseManifest(string memory json) public pure returns (Manifest memory manifest) {
        manifest.chainId = vm.parseJsonUint(json, ".chainId");
        manifest.bindings = KeyfleetSystem.Bindings({
            safe: vm.parseJsonAddress(json, ".safe"),
            keeper: vm.parseJsonAddress(json, ".keeper"),
            staking: IRegentRevenueStaking(vm.parseJsonAddress(json, ".regentStaking")),
            autolaunch: IRegentsAutolaunchFactoryV2(vm.parseJsonAddress(json, ".autolaunchFactory")),
            clubPass: IERC721(vm.parseJsonAddress(json, ".regentsClubPass")),
            collection: KeyfleetKeys.Collection({
                name: vm.parseJsonString(json, ".collection.name"),
                symbol: vm.parseJsonString(json, ".collection.symbol"),
                baseTokenURI: vm.parseJsonString(json, ".collection.baseTokenURI"),
                contractURI: vm.parseJsonString(json, ".collection.contractURI")
            }),
            randomness: KeyfleetKeys.Randomness({
                coordinator: IVRFCoordinatorV2Plus(vm.parseJsonAddress(json, ".vrf.coordinator")),
                subscriptionId: vm.parseJsonUint(json, ".vrf.subscriptionId"),
                keyHash: vm.parseJsonBytes32(json, ".vrf.keyHash")
            }),
            traitTableHash: vm.parseJsonBytes32(json, ".traitTableHash"),
            route: _parseRoute(json)
        });
        string[5] memory keys = foundingKeys();
        KeyfleetPresets.Preset[5] memory presets = foundingPresets();
        for (uint256 index = 0; index < 5; ++index) {
            string memory key = string.concat(".foundingFleets.", keys[index]);
            manifest.founding[index] = FoundingFleet({
                preset: presets[index],
                deckHash: vm.parseJsonBytes32(json, string.concat(key, ".deckHash")),
                deckSize: vm.parseJsonUint(json, string.concat(key, ".deckSize")),
                profile: KeyfleetManager.Profile({
                    name: vm.parseJsonString(json, string.concat(key, ".profile.name")),
                    description: vm.parseJsonString(json, string.concat(key, ".profile.description")),
                    imageLink: vm.parseJsonString(json, string.concat(key, ".profile.imageLink"))
                })
            });
        }
    }

    /// @notice Reads the factory and the deployment block out of Forge's broadcast JSON.
    /// @dev Every transaction must have a receipt and every receipt must have succeeded.
    function parseBroadcast(string memory json) public view returns (BroadcastSummary memory summary) {
        uint256 transactions = _length(json, ".transactions");
        uint256 receipts = _length(json, ".receipts");
        if (receipts != transactions) revert BroadcastIncomplete(transactions, receipts);

        summary.deploymentBlock = type(uint256).max;
        for (uint256 index = 0; index < receipts; ++index) {
            string memory receipt = _element(".receipts", index);
            if (vm.parseJsonUint(json, string.concat(receipt, ".status")) != 1) revert BroadcastReceiptFailed(index);
            uint256 blockNumber = vm.parseJsonUint(json, string.concat(receipt, ".blockNumber"));
            if (blockNumber < summary.deploymentBlock) summary.deploymentBlock = blockNumber;
        }

        for (uint256 index = 0; index < transactions; ++index) {
            string memory transaction = _element(".transactions", index);
            if (_equal(vm.parseJsonString(json, string.concat(transaction, ".contractName")), "KeyfleetFactory")) {
                summary.factory =
                    KeyfleetFactory(vm.parseJsonAddress(json, string.concat(transaction, ".contractAddress")));
                return summary;
            }
        }
        revert FactoryNotInBroadcast();
    }

    /// @notice The founding fleets' keys in the manifest file, in founding order.
    function foundingKeys() public pure returns (string[5] memory) {
        return ["classic", "syndicate", "accelerant", "cascade", "regentsClub"];
    }

    /// @notice The founding fleets' types, in founding order, as `KeyfleetKeys.foundingPreset`
    /// gives them.
    function foundingPresets() public pure returns (KeyfleetPresets.Preset[5] memory) {
        return [
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FleetTechAccelerant,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.RegentsClub
        ];
    }

    /// @dev The manifest must fit this chain. Its chain must be this chain, and on Base everything
    /// it names must be Base's own: the Safe, the route, staking, Autolaunch, the Regents Club Pass,
    /// the coordinator and
    /// gas lane, and the collection's name, symbol and metadata base. On every chain the coordinator
    /// must know the gas lane and the subscription; a subscription it does not know reverts with the
    /// coordinator's own `InvalidSubscription`. Everything else, such as code at every address and a
    /// trait table and keeper that are not zero, the contracts check themselves when deployed.
    function _requireManifestFitsChain(Manifest memory manifest) internal view {
        if (block.chainid != manifest.chainId) revert WrongChain(manifest.chainId, block.chainid);
        KeyfleetSystem.Bindings memory bindings = manifest.bindings;
        if (block.chainid == BASE_CHAIN_ID) _requireBasePins(bindings);
        IVRFCoordinatorV2Plus coordinator = bindings.randomness.coordinator;
        (bool keyExists,) = IVRFProvingKeys(address(coordinator)).s_provingKeys(bindings.randomness.keyHash);
        if (!keyExists) revert VrfKeyHashUnknown(bindings.randomness.keyHash);
        coordinator.getSubscription(bindings.randomness.subscriptionId);
    }

    function _requireBasePins(KeyfleetSystem.Bindings memory bindings) private pure {
        _pin(bindings.safe == BASE_REGENTS_SAFE, "safe");
        _pin(address(bindings.staking) == BASE_REGENT_REVENUE_STAKING, "regentStaking");
        _pin(address(bindings.autolaunch) == BASE_AUTOLAUNCH_FACTORY, "autolaunchFactory");
        _pin(address(bindings.clubPass) == BASE_REGENTS_CLUB_PASS, "regentsClubPass");
        _pin(address(bindings.randomness.coordinator) == BASE_VRF_COORDINATOR, "vrf.coordinator");
        bytes32 keyHash = bindings.randomness.keyHash;
        _pin(keyHash == BASE_VRF_KEY_HASH_2_GWEI || keyHash == BASE_VRF_KEY_HASH_30_GWEI, "vrf.keyHash");
        _pin(_equal(bindings.collection.name, BASE_COLLECTION_NAME), "collection.name");
        _pin(_equal(bindings.collection.symbol, BASE_COLLECTION_SYMBOL), "collection.symbol");
        _pin(_equal(bindings.collection.baseTokenURI, BASE_METADATA_BASE), "collection.baseTokenURI");
        KeyfleetRegentBuyer.Route memory route = bindings.route;
        _pin(route.usdc == BASE_USDC, "route.usdc");
        _pin(route.weth == BASE_WETH, "route.weth");
        _pin(route.regent == BASE_REGENT, "route.regent");
        _pin(route.v3Pool == BASE_USDC_WETH_POOL, "route.v3Pool");
        _pin(route.poolManager == BASE_POOL_MANAGER, "route.poolManager");
        V4PoolKey memory pool = route.v4Pool;
        _pin(pool.currency0 == BASE_WETH && pool.currency1 == BASE_REGENT, "route.v4Pool.currencies");
        _pin(pool.fee == BASE_REGENT_POOL_FEE, "route.v4Pool.fee");
        _pin(pool.tickSpacing == BASE_REGENT_POOL_TICK_SPACING, "route.v4Pool.tickSpacing");
        _pin(pool.hooks == BASE_REGENT_POOL_HOOKS, "route.v4Pool.hooks");
    }

    function _pin(bool matches, string memory field) private pure {
        if (!matches) revert NotBasePin(field);
    }

    function _parseRoute(string memory json) private pure returns (KeyfleetRegentBuyer.Route memory) {
        return KeyfleetRegentBuyer.Route({
            usdc: vm.parseJsonAddress(json, ".route.usdc"),
            weth: vm.parseJsonAddress(json, ".route.weth"),
            regent: vm.parseJsonAddress(json, ".route.regent"),
            v3Pool: vm.parseJsonAddress(json, ".route.v3Pool"),
            poolManager: vm.parseJsonAddress(json, ".route.poolManager"),
            v4Pool: V4PoolKey({
                currency0: vm.parseJsonAddress(json, ".route.v4Pool.currency0"),
                currency1: vm.parseJsonAddress(json, ".route.v4Pool.currency1"),
                fee: uint24(vm.parseJsonUint(json, ".route.v4Pool.fee")),
                tickSpacing: int24(vm.parseJsonInt(json, ".route.v4Pool.tickSpacing")),
                hooks: vm.parseJsonAddress(json, ".route.v4Pool.hooks")
            })
        });
    }

    /// @dev The number of elements of a JSON array.
    function _length(string memory json, string memory array) internal view returns (uint256 length) {
        while (vm.keyExistsJson(json, _element(array, length))) ++length;
    }

    function _element(string memory array, uint256 index) internal pure returns (string memory) {
        return string.concat(array, "[", vm.toString(index), "]");
    }

    function _equal(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
