// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice Step two of two: after `DeployKeyfleets` has broadcast one fleet, reads it back from
/// the chain, checks it against the input manifest, and writes that fleet's published deployment
/// manifest.
/// @dev Nothing here is taken on trust from the deployment step. The broadcast Forge wrote names
/// the fleet and the blocks the transactions landed in. Every address and value, the vote window,
/// the deposit fee and the reward-ledger bounds are read from the chain through that fleet. REGENT
/// is the one address taken from the manifest, because no fleet holds it: it is published only as
/// a deposit asset the Regents Safe is expected to admit, so it must hold code, and on Base it must
/// be Base REGENT, as on Base the USDC must be Base USDC. The supply, USDC price and split
/// constants are the ones this script was compiled with from `KeyfleetPresets`, and the fleet's
/// runtime code hash is recorded so it can be re-verified against the deployed code.
/// `factoryMayBeEmpty` is the manifest's waiver as it applies on this chain. A receipt that
/// failed, a transaction with no receipt, a fleet with no code, a fleet of another preset, any
/// value that differs from the manifest, or a fleet the VRF subscription does not yet list as a
/// consumer stops the step before it writes. The Safe adds the consumer between the two steps, so
/// the site only ever lists a fleet whose keys can be revealed.
///
/// `parseBroadcast` and `record` take values and return values, so the suite runs them against
/// fleets deployed in the test; `run` is the only part that reads or writes a file or reads the
/// environment.
contract RecordKeyfleets is KeyfleetManifest {
    /// @notice The name of the frozen ABI the fleet's Autolaunch factory is called through.
    string public constant AUTOLAUNCH_FACTORY_ABI = "RegentsAutolaunchFactoryV1";

    /// @notice What the deployment step's broadcast establishes.
    /// @param fleet The fleet the broadcast created.
    /// @param deploymentBlock The lowest block any of the broadcast's transactions landed in, so a
    /// reader starting there sees every event of the fleet from its first block.
    struct BroadcastSummary {
        Keyfleet fleet;
        uint256 deploymentBlock;
    }

    /// @notice The broadcast has transactions without receipts: it did not finish.
    error BroadcastIncomplete(uint256 transactions, uint256 receipts);
    /// @notice The receipt at `index` did not succeed.
    error BroadcastReceiptFailed(uint256 index);
    /// @notice The broadcast names no `Keyfleet`.
    error FleetNotInBroadcast();
    /// @notice The broadcast's fleet has no code on this chain.
    error FleetMissing(address fleet);
    /// @notice A value of the deployed fleet differs from the manifest.
    error RecordedMismatch(string field);
    /// @notice The VRF subscription does not list the fleet as a consumer yet.
    error FleetNotVrfConsumer(address fleet);
    /// @notice On Base, the VRF subscription is owned by someone other than the manifest's Safe.
    error VrfSubscriptionNotOwnedBySafe(address owner, address regentSafe);

    /// @notice Reads the named manifest for the named fleet and that fleet's broadcast, and writes
    /// `deployments/<manifestName>.<fleetKey>.deployed.json`.
    /// @dev Run against the RPC the deployment was broadcast to, with the same `KEYFLEET_MANIFEST`
    /// and `KEYFLEET_FLEET`, straight after that fleet's deployment: Forge keeps only the latest
    /// broadcast as `run-latest.json`.
    function run() external {
        string memory manifestName = vm.envString("KEYFLEET_MANIFEST");
        string memory fleetKey = vm.envString("KEYFLEET_FLEET");
        Manifest memory manifest = readManifest(manifestName, fleetKey);
        string memory broadcast = vm.readFile(
            string.concat("broadcast/DeployKeyfleets.s.sol/", vm.toString(manifest.chainId), "/run-latest.json")
        );

        string memory deployed = record(manifest, parseBroadcast(broadcast));

        vm.writeJson(deployed, string.concat("deployments/", manifestName, ".", fleetKey, ".deployed.json"));
    }

    /// @notice Reads the fleet address and the deployment block out of Forge's broadcast JSON.
    /// @dev Every transaction must have a receipt and every receipt must have succeeded. The fleet
    /// is the broadcast's `Keyfleet`.
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
            if (_equal(vm.parseJsonString(json, string.concat(transaction, ".contractName")), "Keyfleet")) {
                summary.fleet = Keyfleet(vm.parseJsonAddress(json, string.concat(transaction, ".contractAddress")));
                return summary;
            }
        }
        revert FleetNotInBroadcast();
    }

    /// @notice Reads the broadcast's fleet back from the chain, checks it against the manifest, and
    /// returns its deployed manifest's JSON.
    /// @dev The fleet's preset must be the manifest slot's. Its USDC is not compared on its own: a
    /// fleet refuses at construction any USDC but its registry's `BASE_USDC`, and the registry is
    /// compared. The fleet must be a consumer of the subscription, and on Base the subscription
    /// must be owned by the manifest's Safe.
    function record(Manifest memory manifest, BroadcastSummary memory summary) public returns (string memory) {
        _requireManifestFitsChain(manifest);
        Keyfleet fleet = summary.fleet;
        if (address(fleet).code.length == 0) revert FleetMissing(address(fleet));

        if (fleet.PRESET() != _presets()[manifest.slot]) revert RecordedMismatch("preset");
        KeyfleetAssetRegistry registry = fleet.ASSET_REGISTRY();
        if (manifest.assetRegistry != address(0) && address(registry) != manifest.assetRegistry) {
            revert RecordedMismatch("assetRegistry");
        }
        if (registry.REGENT_SAFE() != manifest.regentSafe) revert RecordedMismatch("regentSafe");
        if (registry.BASE_USDC() != manifest.usdc) revert RecordedMismatch("usdc");
        if (fleet.TREASURY() != manifest.treasury) revert RecordedMismatch("treasury");
        if (address(fleet.STAKING()) != manifest.staking) revert RecordedMismatch("staking");
        if (address(fleet.FACTORY()) != manifest.autolaunchFactory) revert RecordedMismatch("autolaunchFactory");
        if (fleet.VOTES().VOTING_WINDOW() != manifest.votingWindow) revert RecordedMismatch("votingWindow");
        _requireRandomnessMatches(manifest.vrf, fleet);
        if (fleet.TRAIT_TABLE_HASH() != manifest.traitTableHash) revert RecordedMismatch("traitTableHash");
        if (!_equal(fleet.name(), manifest.fleet.name)) revert RecordedMismatch("name");
        if (!_equal(fleet.symbol(), manifest.fleet.symbol)) revert RecordedMismatch("symbol");
        if (!_equal(fleet.baseTokenURI(), manifest.fleet.baseTokenURI)) revert RecordedMismatch("baseTokenURI");

        (,,, address subscriptionOwner, address[] memory consumers) =
            manifest.vrf.coordinator.getSubscription(manifest.vrf.subscriptionId);
        if (block.chainid == BASE_CHAIN_ID && subscriptionOwner != manifest.regentSafe) {
            revert VrfSubscriptionNotOwnedBySafe(subscriptionOwner, manifest.regentSafe);
        }
        if (!_contains(consumers, address(fleet))) revert FleetNotVrfConsumer(address(fleet));

        string memory root = "deployed";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deploymentBlock", summary.deploymentBlock);
        vm.serializeAddress(root, "assetRegistry", address(registry));
        vm.serializeAddress(root, "regent", manifest.regent);
        vm.serializeAddress(root, "usdc", registry.BASE_USDC());
        vm.serializeUint(root, "qUsdc", KeyfleetPresets.Q_USDC);
        vm.serializeAddress(root, "treasury", fleet.TREASURY());
        vm.serializeAddress(root, "staking", address(fleet.STAKING()));
        vm.serializeAddress(root, "regentSafe", registry.REGENT_SAFE());
        vm.serializeUint(root, "votingWindow", fleet.VOTES().VOTING_WINDOW());
        vm.serializeString(root, "fleet", _fleetJson(_fleetKeys()[manifest.slot], fleet));
        vm.serializeString(root, "bounds", _boundsJson(fleet.REWARDS()));
        vm.serializeString(root, "fees", _feesJson(fleet));
        vm.serializeString(root, "autolaunch", _autolaunchJson(manifest, address(fleet.FACTORY())));
        vm.serializeString(root, "vrf", _vrfJson(fleet));
        vm.serializeBytes32(root, "traitTableHash", fleet.TRAIT_TABLE_HASH());
        vm.serializeString(root, "initialAssetFlags", _initialAssetFlagsJson(registry.BASE_USDC(), manifest.regent));
        return vm.serializeString(root, "disclosures", _disclosuresJson());
    }

    /// @dev The three randomness values the manifest decides, read back off the fleet.
    function _requireRandomnessMatches(Keyfleet.Randomness memory vrf, Keyfleet fleet) private view {
        if (fleet.VRF_COORDINATOR() != vrf.coordinator) revert RecordedMismatch("vrf.coordinator");
        if (fleet.VRF_SUBSCRIPTION_ID() != vrf.subscriptionId) revert RecordedMismatch("vrf.subscriptionId");
        if (fleet.VRF_KEY_HASH() != vrf.keyHash) revert RecordedMismatch("vrf.keyHash");
    }

    /// @dev The randomness every key's traits come from, read from the chain: the coordinator and
    /// its code hash, the subscription, the gas lane and the fixed request terms.
    /// The subscription id is written as a decimal string, because Chainlink subscription ids are
    /// 77-digit numbers that many JSON readers cannot hold exactly.
    function _vrfJson(Keyfleet fleet) private returns (string memory) {
        address coordinator = address(fleet.VRF_COORDINATOR());
        string memory vrf = "vrf";
        vm.serializeAddress(vrf, "coordinator", coordinator);
        vm.serializeBytes32(vrf, "coordinatorCodeHash", coordinator.codehash);
        vm.serializeString(vrf, "subscriptionId", vm.toString(fleet.VRF_SUBSCRIPTION_ID()));
        vm.serializeBytes32(vrf, "keyHash", fleet.VRF_KEY_HASH());
        vm.serializeUint(vrf, "requestConfirmations", fleet.REVEAL_CONFIRMATIONS());
        vm.serializeUint(vrf, "callbackGasLimit", fleet.REVEAL_CALLBACK_GAS_LIMIT());
        vm.serializeUint(vrf, "retryAfterSeconds", fleet.REVEAL_RETRY_AFTER());
        return vm.serializeBool(vrf, "nativePayment", true);
    }

    /// @dev The fleet, with `slot` the key the input manifest names it by.
    function _fleetJson(string memory fleetKey, Keyfleet fleet) private returns (string memory) {
        string memory fleetJson = "fleet";
        vm.serializeString(fleetJson, "slot", fleetKey);
        vm.serializeAddress(fleetJson, "address", address(fleet));
        vm.serializeBytes32(fleetJson, "codeHash", address(fleet).codehash);
        vm.serializeAddress(fleetJson, "rewards", address(fleet.REWARDS()));
        vm.serializeAddress(fleetJson, "votes", address(fleet.VOTES()));
        vm.serializeString(fleetJson, "name", fleet.name());
        vm.serializeString(fleetJson, "symbol", fleet.symbol());
        vm.serializeString(fleetJson, "baseTokenURI", fleet.baseTokenURI());
        return vm.serializeUint(fleetJson, "maxSupply", fleet.maxSupply());
    }

    /// @dev The published numeric bounds. The two reward-ledger bounds are read from the chain; the
    /// others are this script's compiled `KeyfleetPresets`, which the fleet's recorded code hash
    /// lets anyone re-verify.
    function _boundsJson(KeyfleetRewards rewards) private returns (string memory) {
        string memory bounds = "bounds";
        vm.serializeUint(bounds, "fibonacciLevels", KeyfleetPresets.MAX_FIBONACCI_LEVEL);
        vm.serializeUint(bounds, "fibonacciMaxTokenId", KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);
        vm.serializeUint(bounds, "classicSupply", KeyfleetPresets.CLASSIC_SUPPLY);
        vm.serializeUint(bounds, "accelerantMaxKeys", KeyfleetPresets.MAX_ACCELERANT_KEYS);
        vm.serializeUint(bounds, "fibonacciAutolaunchMinKeys", KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS);
        vm.serializeUint(bounds, "fleetTechAutolaunchMinKeys", KeyfleetPresets.FLEET_TECH_AUTOLAUNCH_MIN_KEYS);
        vm.serializeUint(bounds, "maxRewardAssets", rewards.MAX_REWARD_ASSETS());
        return vm.serializeUint(bounds, "maxCohorts", rewards.MAX_COHORTS());
    }

    /// @dev The deposit fee is read from the chain; the purchase split is this script's compiled
    /// `KeyfleetPresets`, like the supply bounds.
    function _feesJson(Keyfleet fleet) private returns (string memory) {
        string memory fees = "fees";
        vm.serializeUint(fees, "protocolBps", KeyfleetPresets.PROTOCOL_BPS);
        vm.serializeUint(fees, "referralBps", KeyfleetPresets.REFERRAL_BPS);
        vm.serializeUint(fees, "accelerantCapitalBps", KeyfleetPresets.ACCELERANT_CAPITAL_BPS);
        vm.serializeUint(fees, "depositFeeBps", fleet.DEPOSIT_FEE_BPS());
        return vm.serializeUint(fees, "bpsDenominator", KeyfleetPresets.BPS_DENOMINATOR);
    }

    /// @dev The factory the fleet is pinned to, the strategy it publishes, the code each holds and
    /// the ABI they are called through, so the binding can be re-checked against the Autolaunch
    /// ceremony's own manifest. A factory without code — which only a lab manifest's waiver lets
    /// through — publishes no strategy, and the zero strategy is recorded as the chain reports it.
    /// `factoryMayBeEmpty` is the waiver as it applied here, so it is never true on Base.
    function _autolaunchJson(Manifest memory manifest, address factory) private returns (string memory) {
        address strategy =
            factory.code.length == 0 ? address(0) : address(IRegentsAutolaunchFactoryV1(factory).strategy());

        string memory autolaunch = "autolaunch";
        vm.serializeString(autolaunch, "abi", AUTOLAUNCH_FACTORY_ABI);
        vm.serializeAddress(autolaunch, "factory", factory);
        vm.serializeBytes32(autolaunch, "factoryCodeHash", factory.codehash);
        vm.serializeAddress(autolaunch, "strategy", strategy);
        vm.serializeBytes32(autolaunch, "strategyCodeHash", strategy.codehash);
        vm.serializeBool(autolaunch, "factoryMayBeEmpty", _factoryMayBeEmpty(manifest));
        return vm.serializeString(
            autolaunch,
            "readiness",
            "A fleet may launch once, by vote, with itself as launcher and treasury, after it has sold"
            " the last key of level 7 (Syndicate, Cascade) or 100 keys (Classic, Accelerant). Creation"
            " is not graduation: the app reads the strategy for the lifecycle, and a SUBJECT is"
            " admitted for deposits only after the Regents Safe allows it."
        );
    }

    /// @dev The flags the Regents Safe is expected to set after deployment: USDC and REGENT in the
    /// global catalogue and for this fleet. The deployment sets none of them.
    function _initialAssetFlagsJson(address usdc, address regent) private returns (string memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = usdc;
        tokens[1] = regent;

        string memory flags = "assetFlags";
        vm.serializeString(flags, "status", "awaiting the Regents Safe");
        vm.serializeAddress(flags, "global", tokens);
        return vm.serializeAddress(flags, "fleet", tokens);
    }

    /// @dev The terms the release publishes here because it publishes them nowhere else: there is
    /// no configuration UI and no settings page behind which any of this could change.
    function _disclosuresJson() private returns (string memory) {
        string memory disclosures = "disclosures";
        vm.serializeString(disclosures, "chat", "Rooms and messages are public to read.");
        vm.serializeString(
            disclosures, "refunds", "No refunds and no escrow. A recorded payment is not proof of delivery."
        );
        vm.serializeString(disclosures, "serviceRewardEligibility", "Keys only.");
        vm.serializeString(
            disclosures,
            "feeComposition",
            "Autolaunch's splitter takes 2% of the revenue it recognizes and Keyfleet takes 2% of the"
            " external receipt when that payout is deposited. They are two separate deductions."
        );
        return vm.serializeString(
            disclosures,
            "safeAuthority",
            "The Regents Safe controls deposit admission only, and no fleet vote, claim or price."
        );
    }

    /// @dev The number of elements of a JSON array.
    function _length(string memory json, string memory array) private view returns (uint256 length) {
        while (vm.keyExistsJson(json, _element(array, length))) ++length;
    }

    function _element(string memory array, uint256 index) private pure returns (string memory) {
        return string.concat(array, "[", vm.toString(index), "]");
    }

    function _contains(address[] memory accounts, address account) private pure returns (bool) {
        for (uint256 index = 0; index < accounts.length; ++index) {
            if (accounts[index] == account) return true;
        }
        return false;
    }

    function _equal(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
