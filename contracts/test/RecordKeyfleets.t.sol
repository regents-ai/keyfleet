// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {RecordKeyfleets} from "../script/RecordKeyfleets.s.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";

/// @dev A factory the Safe adds, which registers a fleet whose manager is no fleet of the first
/// factory.
contract OtherFactory {
    function register(KeyfleetKeys collection) external {
        collection.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, address(this), bytes32(0), 0);
    }
}

contract RecordKeyfleetsTest is KeyfleetScriptFixture {
    RecordKeyfleets private recorder;

    function setUp() public {
        _setUpScripts();
        recorder = new RecordKeyfleets();
    }

    /// @dev The record publishes the system and each founding fleet as the chain reports them:
    /// every address with its runtime code hash, the collection's identity, the route, the
    /// randomness, and each fleet's type, deck, start price, profile and contracts.
    function test_recordPublishesTheSystemAndEveryFleetAsTheChainReportsIt() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);
        KeyfleetKeys collection = deployed.KEYS();

        string memory json = recorder.record(manifest, _summary(deployed));

        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid, "Chain");
        assertEq(vm.parseJsonUint(json, ".deploymentBlock"), 7, "Deployment block");
        assertEq(vm.parseJsonAddress(json, ".factory.address"), address(deployed), "Factory");
        assertEq(vm.parseJsonBytes32(json, ".factory.codeHash"), address(deployed).codehash, "Factory code");
        assertEq(
            vm.parseJsonAddress(json, ".factory.managerDeployer"), address(deployed.MANAGER_DEPLOYER()), "Deployer"
        );
        assertEq(
            vm.parseJsonBytes32(json, ".factory.rewardsDeployerCodeHash"),
            address(deployed.REWARDS_DEPLOYER()).codehash,
            "Deployer code"
        );
        assertEq(vm.parseJsonAddress(json, ".collection.address"), address(collection), "Collection");
        assertEq(vm.parseJsonBytes32(json, ".collection.codeHash"), address(collection).codehash, "Collection code");
        assertEq(vm.parseJsonString(json, ".collection.name"), "Keyfleet", "Name");
        assertEq(vm.parseJsonString(json, ".collection.symbol"), "KEYFLEET", "Symbol");
        assertEq(
            vm.parseJsonString(json, ".collection.baseTokenURI"), manifest.bindings.collection.baseTokenURI, "Base"
        );
        assertEq(vm.parseJsonAddress(json, ".collection.safe"), safe, "Safe");
        assertEq(vm.parseJsonAddress(json, ".collection.keeper"), keeper, "Keeper");
        assertEq(vm.parseJsonUint(json, ".collection.royaltyBps"), 250, "Royalty");
        assertEq(vm.parseJsonAddress(json, ".shards.address"), address(deployed.SHARDS()), "Shards");
        assertEq(vm.parseJsonAddress(json, ".regentBuyer.address"), address(deployed.REGENT_BUYER()), "Buyer");
        assertEq(vm.parseJsonAddress(json, ".regentBuyer.v3Pool"), address(v3Pool), "v3 pool");
        assertEq(vm.parseJsonUint(json, ".regentBuyer.v4Pool.fee"), DYNAMIC_FEE, "v4 fee");
        assertEq(vm.parseJsonInt(json, ".regentBuyer.v4Pool.tickSpacing"), TICK_SPACING, "v4 tick spacing");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "USDC");
        assertEq(vm.parseJsonAddress(json, ".regent"), address(regent), "REGENT");
        assertEq(vm.parseJsonAddress(json, ".regentStaking"), address(staking), "Staking");
        assertEq(vm.parseJsonAddress(json, ".autolaunchFactory"), address(autolaunch), "Autolaunch");
        assertEq(vm.parseJsonString(json, ".vrf.subscriptionId"), vm.toString(vrfSubscription), "Subscription");
        assertEq(vm.parseJsonBytes32(json, ".vrf.keyHash"), KEY_HASH, "Lane");
        assertEq(vm.parseJsonUint(json, ".vrf.callbackGasLimit"), 100_000, "Callback gas");
        assertEq(vm.parseJsonBytes32(json, ".traitTableHash"), manifest.bindings.traitTableHash, "Trait table");
        assertEq(vm.parseJsonUint(json, ".startPrice.min"), 10_000_000, "Least start price");
        assertEq(vm.parseJsonUint(json, ".startPrice.max"), 1_000_000_000_000, "Greatest start price");
        assertEq(vm.parseJsonUint(json, ".startPrice.step"), 10_000, "Whole cents");
        assertEq(vm.parseJsonUint(json, ".fees.protocolBps"), 1000, "Protocol share");
        assertTrue(vm.keyExistsJson(json, ".disclosures.regentPurchase"), "REGENT purchase disclosed");

        string[4] memory types = ["classic", "syndicate", "accelerant", "cascade"];
        for (uint256 fleetId = 1; fleetId <= 4; ++fleetId) {
            _assertFleet(json, fleetId, types[fleetId - 1], _managerOf(deployed, fleetId));
            string memory fleet = string.concat(".fleets.", vm.toString(fleetId));
            assertEq(vm.parseJsonBytes32(json, string.concat(fleet, ".deckHash")), _deckHash(fleetId), "Deck");
            assertEq(vm.parseJsonUint(json, string.concat(fleet, ".deckSize")), DECK_SIZE, "Deck size");
        }
        assertFalse(vm.keyExistsJson(json, ".fleets.5"), "Four fleets");
    }

    /// @dev Run again later, the record also lists every fleet created since, with its creator's
    /// terms and no deck yet.
    function test_recordListsFleetsCreatedSince() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);
        _openPhase(manifest, deployed);
        _openPhase(manifest, deployed);
        _openPhase(manifest, deployed);
        KeyfleetManager.Requirements memory requirements;
        requirements.token = address(regent);
        requirements.tokenMin = 5e18;
        usdc.mint(creator, 25e6);
        vm.prank(creator);
        usdc.approve(address(deployed), 25e6);
        vm.prank(creator);
        deployed.createFleet(_terms(KeyfleetPresets.Preset.FibonacciCascade, 25e6, requirements));

        string memory json = recorder.record(manifest, _summary(deployed));

        _assertFleet(json, 5, "cascade", _managerOf(deployed, 5));
        assertEq(vm.parseJsonUint(json, ".fleets.5.typeNumber"), 2, "Cascade #2");
        assertEq(vm.parseJsonUint(json, ".fleets.5.startPrice"), 25e6, "Creator's start price");
        assertEq(vm.parseJsonBytes32(json, ".fleets.5.deckHash"), bytes32(0), "No deck yet");
        assertEq(vm.parseJsonAddress(json, ".fleets.5.requirements.token"), address(regent), "Requirement");
        assertEq(vm.parseJsonUint(json, ".fleets.5.requirements.tokenMin"), 5e18, "Requirement amount");
    }

    /// @dev Invariant: the record lists keys only once the subscription pays for their reveals.
    function test_recordRefusesACollectionTheSubscriptionDoesNotListYet() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = deployScript.deploy(manifest);
        vm.expectRevert(
            abi.encodeWithSelector(RecordKeyfleets.CollectionNotVrfConsumer.selector, address(deployed.KEYS()))
        );
        recorder.record(manifest, _summary(deployed));
    }

    function test_recordRefusesAFactoryWithoutCode() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        address nothing = makeAddr("nothing");
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FactoryMissing.selector, nothing));
        recorder.record(
            manifest, KeyfleetManifest.BroadcastSummary({factory: KeyfleetFactory(nothing), deploymentBlock: 1})
        );
    }

    function test_recordRefusesAManifestForAnotherChain() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        manifest.chainId = 1;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, 1, block.chainid));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev Every value the record checks, changed in the manifest alone, stops the record with
    /// that value's name.
    function test_recordRefusesEveryValueThatDiffersFromTheManifest() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        address other = makeAddr("other");

        manifest.bindings.safe = other;
        _expectMismatch(manifest, deployed, "safe");
        manifest = _manifest();
        manifest.bindings.keeper = other;
        _expectMismatch(manifest, deployed, "keeper");
        manifest = _manifest();
        manifest.bindings.collection.name = "Other";
        _expectMismatch(manifest, deployed, "collection.name");
        manifest = _manifest();
        manifest.bindings.collection.symbol = "OTHER";
        _expectMismatch(manifest, deployed, "collection.symbol");
        manifest = _manifest();
        manifest.bindings.collection.baseTokenURI = "https://other/";
        _expectMismatch(manifest, deployed, "collection.baseTokenURI");
        manifest = _manifest();
        manifest.bindings.collection.contractURI = "https://other.json";
        _expectMismatch(manifest, deployed, "collection.contractURI");
        manifest = _manifest();
        manifest.bindings.randomness.coordinator = IVRFCoordinatorV2Plus(address(_otherCoordinatorKnowing(manifest)));
        _expectMismatch(manifest, deployed, "vrf.coordinator");
        manifest = _manifest();
        manifest.bindings.randomness.subscriptionId = vrf.createSubscription();
        _expectMismatch(manifest, deployed, "vrf.subscriptionId");
        manifest = _manifest();
        vrf.addProvingKey(keccak256("other lane"), 30 gwei);
        manifest.bindings.randomness.keyHash = keccak256("other lane");
        _expectMismatch(manifest, deployed, "vrf.keyHash");
        manifest = _manifest();
        manifest.bindings.traitTableHash = keccak256("other table");
        _expectMismatch(manifest, deployed, "traitTableHash");
        manifest = _manifest();
        manifest.bindings.staking = IRegentRevenueStaking(other);
        _expectMismatch(manifest, deployed, "regentStaking");
        manifest = _manifest();
        manifest.bindings.autolaunch = IRegentsAutolaunchFactoryV2(other);
        _expectMismatch(manifest, deployed, "autolaunchFactory");
        manifest = _manifest();
        manifest.bindings.route.usdc = other;
        _expectMismatch(manifest, deployed, "route.usdc");
        manifest = _manifest();
        manifest.bindings.route.weth = other;
        _expectMismatch(manifest, deployed, "route.weth");
        manifest = _manifest();
        manifest.bindings.route.regent = other;
        _expectMismatch(manifest, deployed, "route.regent");
        manifest = _manifest();
        manifest.bindings.route.v3Pool = other;
        _expectMismatch(manifest, deployed, "route.v3Pool");
        manifest = _manifest();
        manifest.bindings.route.poolManager = other;
        _expectMismatch(manifest, deployed, "route.poolManager");
        manifest = _manifest();
        manifest.bindings.route.v4Pool.hooks = other;
        _expectMismatch(manifest, deployed, "route.v4Pool");
    }

    /// @dev A founding fleet created with another deck than the manifest's is not recorded.
    function test_recordRefusesAFoundingFleetWithAnotherDeck() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);
        manifest.founding[2].deckHash = keccak256("another deck");
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FleetNotBound.selector, 3, "deck"));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev A fleet that is not one of this factory's, such as one a later factory the Safe added
    /// registers, is not recorded as one.
    function test_recordRefusesAFleetThatIsNotTheFactorys() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);
        _openPhase(manifest, deployed);
        _openPhase(manifest, deployed);
        _openPhase(manifest, deployed);
        KeyfleetKeys collection = deployed.KEYS();
        OtherFactory later = new OtherFactory();
        vm.prank(safe);
        collection.addFactory(address(later));
        later.register(collection);

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FleetNotBound.selector, 5, "manager"));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev On Base the record lists the system only while the Regents Safe owns the subscription,
    /// so nobody else can remove the collection or cancel the subscription.
    function test_recordOnBaseRefusesASubscriptionTheRegentsSafeDoesNotOwn() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory deployed = _deployListed(manifest);
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(deployScript.BASE_VRF_COORDINATOR());
        coordinator.openSubscription(subscriptionId, keeper);

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedByRegentsSafe.selector, keeper));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev The committed Base manifest, deployed, founded through the Safe step and recorded over
    /// a stand-in Base once the subscription and keeper are written in: the record publishes the
    /// collection on chain 8453 with the four founding fleets and their decks.
    function test_theBaseManifestDeploysFoundsAndRecords() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);

        string memory json = recorder.record(manifest, _summary(deployed));

        assertEq(vm.parseJsonUint(json, ".chainId"), 8453, "Base");
        assertEq(vm.parseJsonString(json, ".collection.baseTokenURI"), "https://keyfleet.ai/metadata/keys/", "Base");
        assertEq(vm.parseJsonAddress(json, ".usdc"), deployScript.BASE_USDC(), "Base USDC");
        assertEq(vm.parseJsonAddress(json, ".regentBuyer.poolManager"), deployScript.BASE_POOL_MANAGER(), "v4");
        assertEq(vm.parseJsonAddress(json, ".regentBuyer.v4Pool.hooks"), deployScript.BASE_REGENT_POOL_HOOKS(), "Hook");
        string[4] memory types = ["classic", "syndicate", "accelerant", "cascade"];
        for (uint256 fleetId = 1; fleetId <= 4; ++fleetId) {
            _assertFleet(json, fleetId, types[fleetId - 1], _managerOf(deployed, fleetId));
            assertEq(
                vm.parseJsonBytes32(json, string.concat(".fleets.", vm.toString(fleetId), ".deckHash")),
                manifest.founding[fleetId - 1].deckHash,
                "The NFTs lane's deck"
            );
        }
    }

    // --- broadcast ---------------------------------------------------------

    function test_broadcastNamesItsFactoryAndItsEarliestBlock() public view {
        KeyfleetManifest.BroadcastSummary memory summary = recorder.parseBroadcast(
            _broadcast(
                "{\"status\":\"0x1\",\"blockNumber\":\"0x9\"},{\"status\":\"0x1\",\"blockNumber\":\"0x7\"},"
                "{\"status\":\"0x1\",\"blockNumber\":\"0x8\"}"
            )
        );
        assertEq(address(summary.factory), address(0xFAC7), "Factory");
        assertEq(summary.deploymentBlock, 7, "Earliest block");
    }

    function test_broadcastWithAFailedReceiptIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.BroadcastReceiptFailed.selector, 1));
        recorder.parseBroadcast(
            _broadcast(
                "{\"status\":\"0x1\",\"blockNumber\":\"0x7\"},{\"status\":\"0x0\",\"blockNumber\":\"0x7\"},"
                "{\"status\":\"0x1\",\"blockNumber\":\"0x7\"}"
            )
        );
    }

    function test_broadcastWithATransactionAwaitingItsReceiptIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.BroadcastIncomplete.selector, 3, 2));
        recorder.parseBroadcast(
            _broadcast("{\"status\":\"0x1\",\"blockNumber\":\"0x7\"},{\"status\":\"0x1\",\"blockNumber\":\"0x7\"}")
        );
    }

    function test_broadcastWithoutAFactoryIsRefused() public {
        vm.expectRevert(KeyfleetManifest.FactoryNotInBroadcast.selector);
        recorder.parseBroadcast(
            "{\"transactions\":[{\"contractName\":\"KeyfleetManagerDeployer\",\"contractAddress\":"
            "\"0x0000000000000000000000000000000000000001\"}],\"receipts\":[{\"status\":\"0x1\",\"blockNumber\":\"0x7\"}]}"
        );
    }

    // --- helpers -------------------------------------------------------------

    /// @dev A broadcast in the shape Forge writes: two deployers, then the factory, with the given
    /// receipts.
    function _broadcast(string memory receipts) private pure returns (string memory) {
        return string.concat(
            "{\"transactions\":[",
            "{\"contractName\":\"KeyfleetManagerDeployer\",\"contractAddress\":\"0x0000000000000000000000000000000000000001\"},",
            "{\"contractName\":\"KeyfleetVotesDeployer\",\"contractAddress\":\"0x0000000000000000000000000000000000000002\"},",
            "{\"contractName\":\"KeyfleetFactory\",\"contractAddress\":\"0x000000000000000000000000000000000000fAc7\"}",
            "],\"receipts\":[",
            receipts,
            "]}"
        );
    }

    function _summary(KeyfleetFactory deployed) private pure returns (KeyfleetManifest.BroadcastSummary memory) {
        return KeyfleetManifest.BroadcastSummary({factory: deployed, deploymentBlock: 7});
    }

    /// @dev A second coordinator that knows the manifest's gas lane and subscription id, so only
    /// the comparison with the collection can refuse it.
    function _otherCoordinatorKnowing(KeyfleetManifest.Manifest memory manifest)
        private
        returns (MockVRFCoordinatorV2Plus other)
    {
        other = new MockVRFCoordinatorV2Plus();
        other.addProvingKey(manifest.bindings.randomness.keyHash, 30 gwei);
        other.openSubscription(manifest.bindings.randomness.subscriptionId, address(this));
    }

    /// @dev The record names fleet `fleetId`'s type and its four contracts with their runtime code
    /// hashes, its profile and the assets its split shares, as the chain reports them.
    function _assertFleet(string memory json, uint256 fleetId, string memory fleetType, KeyfleetManager manager)
        private
        view
    {
        string memory fleet = string.concat(".fleets.", vm.toString(fleetId));
        assertEq(vm.parseJsonString(json, string.concat(fleet, ".type")), fleetType, "Type");
        assertEq(vm.parseJsonUint(json, string.concat(fleet, ".startPrice")), manager.START_PRICE(), "Start price");
        assertEq(vm.parseJsonAddress(json, string.concat(fleet, ".manager")), address(manager), "Manager");
        assertEq(vm.parseJsonBytes32(json, string.concat(fleet, ".managerCodeHash")), address(manager).codehash, "Code");
        assertEq(vm.parseJsonAddress(json, string.concat(fleet, ".votes")), address(manager.VOTES()), "Votes");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(fleet, ".votesCodeHash")), address(manager.VOTES()).codehash, "Code"
        );
        assertEq(vm.parseJsonAddress(json, string.concat(fleet, ".treasury")), address(manager.TREASURY()), "Treasury");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(fleet, ".treasuryCodeHash")),
            address(manager.TREASURY()).codehash,
            "Code"
        );
        assertEq(vm.parseJsonAddress(json, string.concat(fleet, ".rewards")), address(manager.REWARDS()), "Rewards");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(fleet, ".rewardsCodeHash")),
            address(manager.REWARDS()).codehash,
            "Code"
        );
        assertEq(vm.parseJsonString(json, string.concat(fleet, ".name")), manager.profile().name, "Name");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(fleet, ".protocolShareTag")),
            manager.TREASURY().PROTOCOL_SHARE_TAG(),
            "Protocol share tag"
        );
        address[] memory assets = vm.parseJsonAddressArray(json, string.concat(fleet, ".splitAssets"));
        assertEq(assets.length, 3, "ETH, REGENT and USDC");
        assertEq(assets[1], address(manager.TREASURY().REGENT()), "REGENT second");
    }

    function _expectMismatch(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory deployed, string memory field)
        private
    {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.RecordedMismatch.selector, field));
        recorder.record(manifest, _summary(deployed));
    }
}
