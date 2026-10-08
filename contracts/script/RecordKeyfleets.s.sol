// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetDeployer} from "../src/KeyfleetDeployers.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {V4PoolKey} from "../src/interfaces/IUniswapV4PoolManager.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice The last step: reads the system and every fleet back from the chain, checks them
/// against the input manifest, and writes the published deployment record.
/// @dev Nothing here is taken on trust from the other steps. The deployment step's broadcast names
/// the factory and the blocks its transactions landed in; every other address and value is read
/// from the chain through the factory. The supply, price and split constants are the ones this
/// script was compiled with from `KeyfleetPresets`, and the runtime code hash of every contract is
/// recorded so each can be re-verified against its deployed code.
///
/// The record refuses, before it writes, a failed or unfinished broadcast, a factory with no code,
/// any value that differs from the manifest, a fleet whose four contracts are not the ones the
/// factory places for it or do not point at each other, a founding fleet of another type or deck
/// than the manifest's, and a collection the VRF subscription does not list as a consumer yet, so
/// the site only lists keys that can be revealed. Run it after the founding fleets exist, and again
/// whenever the record should list the fleets created since.
///
/// `record` takes values and returns JSON, so the suite runs it against systems deployed in the
/// test; `run` is the only part that reads or writes a file or reads the environment.
contract RecordKeyfleets is KeyfleetManifest {
    /// @notice The broadcast's factory has no code on this chain.
    error FactoryMissing(address factory);
    /// @notice A value on chain differs from the manifest.
    error RecordedMismatch(string field);
    /// @notice A fleet's `part` is missing, misplaced or bound to something else.
    error FleetNotBound(uint256 fleetId, string part);
    /// @notice The VRF subscription does not list the collection as a consumer yet.
    error CollectionNotVrfConsumer(address collection);
    /// @notice On Base, the VRF subscription is owned by someone other than the Regents Safe.
    error VrfSubscriptionNotOwnedByRegentsSafe(address owner);

    /// @notice Reads the manifest named by `KEYFLEET_MANIFEST` and the deployment's broadcast, and
    /// writes `deployments/<manifestName>.deployed.json`.
    function run() external {
        string memory manifestName = vm.envString("KEYFLEET_MANIFEST");
        string memory deployed = record(readManifest(manifestName), readBroadcast());
        vm.writeJson(deployed, string.concat("deployments/", manifestName, ".deployed.json"));
    }

    /// @notice Reads the system and its fleets back from the chain, checks them against the
    /// manifest, and returns the deployment record's JSON.
    function record(Manifest memory manifest, BroadcastSummary memory summary) public returns (string memory) {
        _requireManifestFitsChain(manifest);
        KeyfleetFactory factory = summary.factory;
        if (address(factory).code.length == 0) revert FactoryMissing(address(factory));
        KeyfleetKeys keys = factory.KEYS();
        _requireSystemMatches(manifest, factory, keys);
        _requireVrfConsumer(keys);

        string memory root = "deployed";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deploymentBlock", summary.deploymentBlock);
        vm.serializeString(root, "factory", _factoryJson(factory));
        vm.serializeString(root, "collection", _collectionJson(keys));
        vm.serializeString(root, "shards", _contractJson("shards", address(factory.SHARDS())));
        vm.serializeString(root, "regentBuyer", _buyerJson(factory.REGENT_BUYER()));
        vm.serializeAddress(root, "usdc", address(factory.USDC()));
        vm.serializeAddress(root, "regent", address(factory.REGENT()));
        vm.serializeAddress(root, "regentStaking", address(factory.REGENT_STAKING()));
        vm.serializeAddress(root, "autolaunchFactory", address(factory.AUTOLAUNCH()));
        vm.serializeString(root, "vrf", _vrfJson(keys));
        vm.serializeBytes32(root, "traitTableHash", keys.TRAIT_TABLE_HASH());
        vm.serializeString(root, "startPrice", _startPriceJson());
        vm.serializeString(root, "accelerantStepPercent", _accelerantStepJson());
        vm.serializeString(root, "bounds", _boundsJson());
        vm.serializeString(root, "fees", _feesJson());
        vm.serializeString(root, "fleets", _fleetsJson(manifest, factory, keys));
        return vm.serializeString(root, "disclosures", _disclosuresJson());
    }

    /// @dev The collection, the shard record, the REGENT buyer and the factory's bindings are the
    /// manifest's.
    function _requireSystemMatches(Manifest memory manifest, KeyfleetFactory factory, KeyfleetKeys keys) private view {
        _match(factory.SAFE() == manifest.bindings.safe && keys.SAFE() == manifest.bindings.safe, "safe");
        _match(keys.keeper() == manifest.bindings.keeper, "keeper");
        _match(keys.isFactory(address(factory)), "collection.factory");
        _match(_equal(keys.name(), manifest.bindings.collection.name), "collection.name");
        _match(_equal(keys.symbol(), manifest.bindings.collection.symbol), "collection.symbol");
        _match(_equal(keys.baseTokenURI(), manifest.bindings.collection.baseTokenURI), "collection.baseTokenURI");
        _match(_equal(keys.contractURI(), manifest.bindings.collection.contractURI), "collection.contractURI");
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId, bytes32 keyHash) = keys.randomness();
        _match(coordinator == manifest.bindings.randomness.coordinator, "vrf.coordinator");
        _match(subscriptionId == manifest.bindings.randomness.subscriptionId, "vrf.subscriptionId");
        _match(keyHash == manifest.bindings.randomness.keyHash, "vrf.keyHash");
        _match(keys.TRAIT_TABLE_HASH() == manifest.bindings.traitTableHash, "traitTableHash");
        _match(factory.SHARDS().KEYS() == keys, "shards.keys");
        _match(factory.REGENT_STAKING() == manifest.bindings.staking, "regentStaking");
        _match(factory.AUTOLAUNCH() == manifest.bindings.autolaunch, "autolaunchFactory");

        KeyfleetRegentBuyer buyer = factory.REGENT_BUYER();
        _match(address(buyer.USDC()) == manifest.bindings.route.usdc, "route.usdc");
        _match(address(buyer.WETH()) == manifest.bindings.route.weth, "route.weth");
        _match(address(buyer.REGENT()) == manifest.bindings.route.regent, "route.regent");
        _match(address(buyer.V3_POOL()) == manifest.bindings.route.v3Pool, "route.v3Pool");
        _match(address(buyer.POOL_MANAGER()) == manifest.bindings.route.poolManager, "route.poolManager");
        _match(
            keccak256(abi.encode(buyer.v4PoolKey())) == keccak256(abi.encode(manifest.bindings.route.v4Pool)),
            "route.v4Pool"
        );
    }

    /// @dev The subscription lists the collection, and on Base the Regents Safe owns it.
    function _requireVrfConsumer(KeyfleetKeys keys) private view {
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId,) = keys.randomness();
        (,,, address owner, address[] memory consumers) = coordinator.getSubscription(subscriptionId);
        if (block.chainid == BASE_CHAIN_ID && owner != BASE_REGENTS_SAFE) {
            revert VrfSubscriptionNotOwnedByRegentsSafe(owner);
        }
        for (uint256 index = 0; index < consumers.length; ++index) {
            if (consumers[index] == address(keys)) return;
        }
        revert CollectionNotVrfConsumer(address(keys));
    }

    /// @dev Fleet `fleetId`'s four contracts are where the factory places them, hold code and
    /// point at each other, the collection and the fleet; a founding fleet is the manifest's type
    /// with the manifest's deck.
    function _requireFleetBound(Manifest memory manifest, KeyfleetFactory factory, KeyfleetKeys keys, uint256 fleetId)
        private
        view
        returns (KeyfleetManager manager)
    {
        (address managerAt, address votes, address treasury, address rewards) = factory.predict(fleetId);
        KeyfleetKeys.Fleet memory fleet = keys.fleet(fleetId);
        _bound(fleet.manager == managerAt && managerAt.code.length != 0, fleetId, "manager");
        manager = KeyfleetManager(managerAt);
        _bound(manager.FLEET_ID() == fleetId && manager.KEYS() == keys, fleetId, "manager");
        _bound(manager.PRESET() == fleet.preset, fleetId, "preset");
        _bound(address(manager.VOTES()) == votes && votes.code.length != 0, fleetId, "votes");
        _bound(address(manager.TREASURY()) == treasury && treasury.code.length != 0, fleetId, "treasury");
        _bound(address(manager.REWARDS()) == rewards && rewards.code.length != 0, fleetId, "rewards");
        _bound(manager.VOTES().MANAGER() == manager, fleetId, "votes");
        _bound(manager.TREASURY().MANAGER() == manager, fleetId, "treasury");
        _bound(manager.REWARDS().MANAGER() == manager, fleetId, "rewards");
        if (fleetId <= manifest.founding.length) {
            FoundingFleet memory founding = manifest.founding[fleetId - 1];
            _bound(fleet.preset == founding.preset, fleetId, "preset");
            _bound(fleet.deckHash == founding.deckHash && fleet.deckSize == founding.deckSize, fleetId, "deck");
        }
    }

    function _match(bool matches, string memory field) private pure {
        if (!matches) revert RecordedMismatch(field);
    }

    function _bound(bool bound, uint256 fleetId, string memory part) private pure {
        if (!bound) revert FleetNotBound(fleetId, part);
    }

    /// @dev Every fleet the collection has, keyed by its number.
    function _fleetsJson(Manifest memory manifest, KeyfleetFactory factory, KeyfleetKeys keys)
        private
        returns (string memory fleets)
    {
        string memory object = "fleets";
        fleets = "{}";
        uint256 count = keys.fleetCount();
        for (uint256 fleetId = 1; fleetId <= count; ++fleetId) {
            KeyfleetManager manager = _requireFleetBound(manifest, factory, keys, fleetId);
            fleets = vm.serializeString(object, vm.toString(fleetId), _fleetJson(keys, fleetId, manager));
        }
    }

    /// @dev One fleet: its type and numbers, starting price, Accelerant step (zero for other types), deck, four contracts with their code
    /// hashes, profile, joining requirements, the tag its protocol share is deposited under and the
    /// assets its daily split shares.
    function _fleetJson(KeyfleetKeys keys, uint256 fleetId, KeyfleetManager manager) private returns (string memory) {
        KeyfleetKeys.Fleet memory fleet = keys.fleet(fleetId);
        string memory object = string.concat("fleet-", vm.toString(fleetId));
        vm.serializeString(object, "type", _typeKey(fleet.preset));
        vm.serializeUint(object, "typeNumber", fleet.typeNumber);
        vm.serializeUint(object, "startPrice", manager.START_PRICE());
        vm.serializeUint(object, "accelerantStepPercent", manager.ACCELERANT_STEP_PERCENT());
        vm.serializeBytes32(object, "deckHash", fleet.deckHash);
        vm.serializeUint(object, "deckSize", fleet.deckSize);
        vm.serializeAddress(object, "manager", address(manager));
        vm.serializeBytes32(object, "managerCodeHash", address(manager).codehash);
        vm.serializeAddress(object, "votes", address(manager.VOTES()));
        vm.serializeBytes32(object, "votesCodeHash", address(manager.VOTES()).codehash);
        vm.serializeAddress(object, "treasury", address(manager.TREASURY()));
        vm.serializeBytes32(object, "treasuryCodeHash", address(manager.TREASURY()).codehash);
        vm.serializeAddress(object, "rewards", address(manager.REWARDS()));
        vm.serializeBytes32(object, "rewardsCodeHash", address(manager.REWARDS()).codehash);
        KeyfleetManager.Profile memory profile = manager.profile();
        vm.serializeString(object, "name", profile.name);
        vm.serializeString(object, "description", profile.description);
        vm.serializeString(object, "imageLink", profile.imageLink);
        vm.serializeString(object, "requirements", _requirementsJson(fleetId, manager.requirements()));
        vm.serializeBytes32(object, "protocolShareTag", manager.TREASURY().PROTOCOL_SHARE_TAG());
        return vm.serializeAddress(object, "splitAssets", manager.TREASURY().splitAssets());
    }

    function _requirementsJson(uint256 fleetId, KeyfleetManager.Requirements memory requirements)
        private
        returns (string memory)
    {
        string memory object = string.concat("requirements-", vm.toString(fleetId));
        vm.serializeBytes32(object, "merkleRoot", requirements.merkleRoot);
        vm.serializeAddress(object, "nft", requirements.nft);
        vm.serializeAddress(object, "token", requirements.token);
        return vm.serializeUint(object, "tokenMin", requirements.tokenMin);
    }

    /// @dev The factory and its four deployers, each with its runtime code hash.
    function _factoryJson(KeyfleetFactory factory) private returns (string memory) {
        string memory object = "factory";
        vm.serializeAddress(object, "address", address(factory));
        vm.serializeBytes32(object, "codeHash", address(factory).codehash);
        _deployerJson(object, "managerDeployer", factory.MANAGER_DEPLOYER());
        _deployerJson(object, "votesDeployer", factory.VOTES_DEPLOYER());
        _deployerJson(object, "treasuryDeployer", factory.TREASURY_DEPLOYER());
        return _deployerJson(object, "rewardsDeployer", factory.REWARDS_DEPLOYER());
    }

    function _deployerJson(string memory object, string memory key, KeyfleetDeployer deployer)
        private
        returns (string memory)
    {
        vm.serializeAddress(object, key, address(deployer));
        return vm.serializeBytes32(object, string.concat(key, "CodeHash"), address(deployer).codehash);
    }

    /// @dev The collection: its identity, the Safe, the keeper and the resale royalty.
    function _collectionJson(KeyfleetKeys keys) private returns (string memory) {
        string memory object = "collection";
        vm.serializeAddress(object, "address", address(keys));
        vm.serializeBytes32(object, "codeHash", address(keys).codehash);
        vm.serializeString(object, "name", keys.name());
        vm.serializeString(object, "symbol", keys.symbol());
        vm.serializeString(object, "baseTokenURI", keys.baseTokenURI());
        vm.serializeString(object, "contractURI", keys.contractURI());
        vm.serializeAddress(object, "safe", keys.SAFE());
        vm.serializeAddress(object, "keeper", keys.keeper());
        return vm.serializeUint(object, "royaltyBps", keys.ROYALTY_BPS());
    }

    function _contractJson(string memory object, address account) private returns (string memory) {
        vm.serializeAddress(object, "address", account);
        return vm.serializeBytes32(object, "codeHash", account.codehash);
    }

    /// @dev The REGENT buyer and its fixed route.
    function _buyerJson(KeyfleetRegentBuyer buyer) private returns (string memory) {
        V4PoolKey memory pool = buyer.v4PoolKey();
        string memory poolObject = "v4Pool";
        vm.serializeAddress(poolObject, "currency0", pool.currency0);
        vm.serializeAddress(poolObject, "currency1", pool.currency1);
        vm.serializeUint(poolObject, "fee", pool.fee);
        vm.serializeInt(poolObject, "tickSpacing", pool.tickSpacing);
        string memory poolJson = vm.serializeAddress(poolObject, "hooks", pool.hooks);

        string memory object = "regentBuyer";
        vm.serializeAddress(object, "address", address(buyer));
        vm.serializeBytes32(object, "codeHash", address(buyer).codehash);
        vm.serializeAddress(object, "usdc", address(buyer.USDC()));
        vm.serializeAddress(object, "weth", address(buyer.WETH()));
        vm.serializeAddress(object, "regent", address(buyer.REGENT()));
        vm.serializeAddress(object, "v3Pool", address(buyer.V3_POOL()));
        vm.serializeAddress(object, "poolManager", address(buyer.POOL_MANAGER()));
        return vm.serializeString(object, "v4Pool", poolJson);
    }

    /// @dev The randomness every key's card comes from, read from the chain: the coordinator and
    /// its code hash, the subscription, the gas lane and the fixed request terms. The subscription
    /// id is written as a decimal string, because Chainlink subscription ids are 77-digit numbers
    /// that many JSON readers cannot hold exactly.
    function _vrfJson(KeyfleetKeys keys) private returns (string memory) {
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId, bytes32 keyHash) = keys.randomness();
        string memory object = "vrf";
        vm.serializeAddress(object, "coordinator", address(coordinator));
        vm.serializeBytes32(object, "coordinatorCodeHash", address(coordinator).codehash);
        vm.serializeString(object, "subscriptionId", vm.toString(subscriptionId));
        vm.serializeBytes32(object, "keyHash", keyHash);
        vm.serializeUint(object, "requestConfirmations", keys.REVEAL_CONFIRMATIONS());
        vm.serializeUint(object, "callbackGasLimit", keys.REVEAL_CALLBACK_GAS_LIMIT());
        return vm.serializeBool(object, "nativePayment", true);
    }

    /// @dev The starting prices anyone creating a fleet may choose, in atomic USDC.
    function _startPriceJson() private returns (string memory) {
        string memory object = "startPrice";
        vm.serializeUint(object, "min", KeyfleetPresets.MIN_START_USDC);
        vm.serializeUint(object, "max", KeyfleetPresets.MAX_START_USDC);
        return vm.serializeUint(object, "step", KeyfleetPresets.CENT_USDC);
    }

    /// @dev The whole-percent steps anyone creating an Accelerant fleet may choose.
    function _accelerantStepJson() private returns (string memory) {
        string memory object = "accelerantStepPercent";
        vm.serializeUint(object, "min", KeyfleetPresets.MIN_ACCELERANT_STEP_PERCENT);
        return vm.serializeUint(object, "max", KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT);
    }

    /// @dev The published supply limits. Only the two Fleet.Tech types have one; the Fibonacci
    /// types have no last level.
    function _boundsJson() private returns (string memory) {
        string memory object = "bounds";
        vm.serializeUint(object, "classicSupply", KeyfleetPresets.CLASSIC_SUPPLY);
        return vm.serializeUint(object, "accelerantMaxKeys", KeyfleetPresets.MAX_ACCELERANT_KEYS);
    }

    /// @dev The purchase split.
    function _feesJson() private returns (string memory) {
        string memory object = "fees";
        vm.serializeUint(object, "protocolBps", KeyfleetPresets.PROTOCOL_BPS);
        vm.serializeUint(object, "accelerantCapitalBps", KeyfleetPresets.ACCELERANT_CAPITAL_BPS);
        return vm.serializeUint(object, "bpsDenominator", KeyfleetPresets.BPS_DENOMINATOR);
    }

    /// @dev The terms the release publishes here because it publishes them nowhere else.
    function _disclosuresJson() private returns (string memory) {
        string memory object = "disclosures";
        vm.serializeString(object, "chat", "Rooms and messages are public to read.");
        vm.serializeString(object, "refunds", "No refunds and no escrow. A recorded payment is not proof of delivery.");
        vm.serializeString(object, "serviceRewardEligibility", "Keys only.");
        vm.serializeString(
            object,
            "feeComposition",
            "Keyfleet takes 10% of every key purchase for REGENT stakers and nothing from money a fleet"
            " receives afterwards. Resales ask 2.5% for the Regents Safe."
        );
        vm.serializeString(
            object,
            "regentPurchase",
            "The fleet treasury's part of each key purchase is turned into REGENT afterwards, a little at a time, at the market price, with no minimum."
        );
        return vm.serializeString(
            object,
            "safeAuthority",
            "The Regents Safe owns the randomness subscription and REGENT revenue staking, opens key sales"
            " step by step and names the wallet that records card decks. It has no vote, claim or price in"
            " any fleet and cannot move a fleet's money."
        );
    }

    /// @dev A type's key in the manifest and the record, listed in the order of `KeyfleetPresets.Preset`.
    function _typeKey(KeyfleetPresets.Preset preset) private pure returns (string memory) {
        return ["syndicate", "cascade", "classic", "accelerant"][uint8(preset)];
    }
}
