// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetTradingFactory} from "../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../src/KeyfleetTradingTreasury.sol";
import {IKeyfleetFactory} from "../src/KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {DeployTradingFactory} from "../script/DeployTradingFactory.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../script/KeyfleetSafeSteps.s.sol";
import {RecordKeyfleets} from "../script/RecordKeyfleets.s.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";

/// @dev A factory the Safe adds, which registers a fleet whose manager is no fleet of the first
/// factory.
contract OtherFactory {
    function register(KeyfleetKeys collection) external {
        collection.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, address(this), bytes32(0), 0);
    }
}

/// @dev A manager that names a trading factory without being one of its fleets'.
contract Impostor {
    address public immutable FACTORY;

    constructor(address factory) {
        FACTORY = factory;
    }
}

/// @dev A factory the Safe adds, which registers an `Impostor` naming `trading` as a fleet's
/// manager.
contract ImpostorFactory {
    function register(KeyfleetKeys collection, address trading) external {
        collection.registerFleet(
            KeyfleetPresets.Preset.FleetTechAccelerant, address(new Impostor(trading)), bytes32(0), 0
        );
    }
}

/// @dev The existing factory of another system, as a trading factory reads it: this system's
/// collection, shard record and staking, but another USDC.
contract ElsewhereFactory {
    KeyfleetKeys public immutable KEYS;
    KeyfleetShards public immutable SHARDS;
    IERC20 public immutable USDC;
    IRegentRevenueStaking public immutable REGENT_STAKING;

    constructor(KeyfleetFactory like, IERC20 usdc) {
        KEYS = like.KEYS();
        SHARDS = like.SHARDS();
        USDC = usdc;
        REGENT_STAKING = like.REGENT_STAKING();
    }
}

contract RecordKeyfleetsTest is KeyfleetScriptFixture {
    RecordKeyfleets private recorder;
    DeployTradingFactory private tradingScript;

    function setUp() public {
        _setUpScripts();
        recorder = new RecordKeyfleets();
        tradingScript = new DeployTradingFactory();
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
        assertEq(vm.parseJsonAddress(json, ".regentsClubPass"), address(clubPass), "Regents Club Pass");
        address claims = address(deployed.CLUB_CLAIMS());
        assertEq(vm.parseJsonAddress(json, ".clubClaims.address"), claims, "Club claims");
        assertEq(vm.parseJsonBytes32(json, ".clubClaims.codeHash"), claims.codehash, "Club claims code");
        assertEq(vm.parseJsonUint(json, ".bounds.clubSupply"), 1998, "One key per Pass");
        assertEq(vm.parseJsonString(json, ".vrf.subscriptionId"), vm.toString(vrfSubscription), "Subscription");
        assertEq(vm.parseJsonBytes32(json, ".vrf.keyHash"), KEY_HASH, "Lane");
        assertEq(vm.parseJsonUint(json, ".vrf.callbackGasLimit"), 100_000, "Callback gas");
        assertEq(vm.parseJsonBytes32(json, ".traitTableHash"), manifest.bindings.traitTableHash, "Trait table");
        assertEq(vm.parseJsonUint(json, ".startPrice.min"), 10_000_000, "Least start price");
        assertEq(vm.parseJsonUint(json, ".startPrice.max"), 1_000_000_000_000, "Greatest start price");
        assertEq(vm.parseJsonUint(json, ".startPrice.step"), 10_000, "Whole cents");
        assertEq(vm.parseJsonUint(json, ".fees.protocolBps"), 1000, "Protocol share");
        assertTrue(vm.keyExistsJson(json, ".disclosures.regentPurchase"), "REGENT purchase disclosed");

        string[5] memory types = ["classic", "syndicate", "accelerant", "cascade", "regentsClub"];
        for (uint256 fleetId = 1; fleetId <= 5; ++fleetId) {
            _assertFleet(json, fleetId, types[fleetId - 1], _managerOf(deployed, fleetId));
            string memory fleet = string.concat(".fleets.", vm.toString(fleetId));
            assertEq(vm.parseJsonBytes32(json, string.concat(fleet, ".deckHash")), _deckHash(fleetId), "Deck");
            assertEq(
                vm.parseJsonUint(json, string.concat(fleet, ".deckSize")),
                fleetId == 5 ? KeyfleetPresets.CLUB_SUPPLY : DECK_SIZE,
                "Deck size"
            );
        }
        assertFalse(vm.keyExistsJson(json, ".fleets.6"), "Five fleets");
    }

    /// @dev Run again later, the record also lists every fleet created since, with its creator's
    /// terms and no deck yet.
    function test_recordListsFleetsCreatedSince() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _found(manifest, deployed);
        while (deployed.KEYS().phase() < deployed.KEYS().FINAL_PHASE()) {
            _openPhase(manifest, deployed);
        }
        KeyfleetManager.Requirements memory requirements;
        requirements.token = address(regent);
        requirements.tokenMin = 5e18;
        usdc.mint(creator, 25e6);
        vm.prank(creator);
        usdc.approve(address(deployed), 25e6);
        vm.prank(creator);
        deployed.createFleet(_terms(KeyfleetPresets.Preset.FibonacciCascade, 25e6, requirements));

        string memory json = recorder.record(manifest, _summary(deployed));

        _assertFleet(json, 6, "cascade", _managerOf(deployed, 6));
        assertEq(vm.parseJsonUint(json, ".fleets.6.typeNumber"), 2, "Cascade #2");
        assertEq(vm.parseJsonUint(json, ".fleets.6.startPrice"), 25e6, "Creator's start price");
        assertEq(vm.parseJsonBytes32(json, ".fleets.6.deckHash"), bytes32(0), "No deck yet");
        assertEq(vm.parseJsonAddress(json, ".fleets.6.requirements.token"), address(regent), "Requirement");
        assertEq(vm.parseJsonUint(json, ".fleets.6.requirements.tokenMin"), 5e18, "Requirement amount");
    }

    /// @dev Invariant: the record lists keys only while the subscription pays for their reveals. The
    /// step to phase 4 waits for the subscription to list the collection, and its owner can remove
    /// the collection afterwards: with a fleet that draws, the record then refuses it.
    function test_recordRefusesACollectionTheSubscriptionNoLongerLists() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory deployed = _deployListed(manifest);
        _drawnFleet(manifest, deployed);
        MockVRFCoordinatorV2Plus coordinator =
            MockVRFCoordinatorV2Plus(address(manifest.bindings.randomness.coordinator));
        uint256 subscriptionId = manifest.bindings.randomness.subscriptionId;
        vm.prank(coordinator.subscriptionOwner(subscriptionId));
        coordinator.removeConsumer(subscriptionId, address(deployed.KEYS()));
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
        manifest.bindings.clubPass = IERC721(other);
        _expectMismatch(manifest, deployed, "regentsClubPass");
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
        while (deployed.KEYS().phase() < deployed.KEYS().FINAL_PHASE()) {
            _openPhase(manifest, deployed);
        }
        KeyfleetKeys collection = deployed.KEYS();
        OtherFactory later = new OtherFactory();
        vm.prank(safe);
        collection.addFactory(address(later));
        later.register(collection);

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FleetNotBound.selector, 6, "manager"));
        recorder.record(manifest, _summary(deployed));
    }

    // --- Trading Fleets ------------------------------------------------------

    /// @dev A Trading Fleet is recorded as one: its type and number in the collection, its trading
    /// factory, its terms as they stand, its deck, its three contracts with their code hashes, its
    /// profile, its requirements and its staking tag.
    function test_recordListsATradingFleetAsATradingFleet() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        (KeyfleetFactory deployed, KeyfleetTradingFactory trading) = _withTradingFactory(manifest);
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms();
        terms.requirements.token = address(regent);
        terms.requirements.tokenMin = 5e18;
        KeyfleetTradingManager fleet = _createTrading(trading, terms);
        KeyfleetTradingTreasury treasury = fleet.TREASURY();
        address wallet = makeAddr("trading wallet");
        vm.startPrank(creator);
        fleet.setStep(800);
        treasury.setTradingWallet(wallet);
        vm.stopPrank();

        string memory json = recorder.record(manifest, _summary(deployed));

        assertEq(fleet.FLEET_ID(), 7, "after the Cascade");
        string memory entry = ".fleets.7";
        assertEq(vm.parseJsonKeys(json, entry).length, 24, "Twenty-four fields");
        assertEq(vm.parseJsonString(json, string.concat(entry, ".type")), "trading", "Marked as a Trading Fleet");
        assertEq(vm.parseJsonString(json, string.concat(entry, ".collectionType")), "accelerant", "Registered type");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".typeNumber")), 2, "Accelerant #2");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".tradingFactory")), address(trading), "Factory");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(entry, ".tradingFactoryCodeHash")),
            address(trading).codehash,
            "Factory code"
        );
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".firstPrice")), 25e6, "First price");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".stepBps")), 800, "Step as it stands");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".dailyPaybackBps")), 50, "Daily payback");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".keyCap")), 40, "Key cap");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".closedAt")), 0, "Open");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".tradingWallet")), wallet, "Trading wallet");
        assertEq(vm.parseJsonBytes32(json, string.concat(entry, ".deckHash")), bytes32(0), "No deck yet");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".deckSize")), 0, "No deck yet");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".manager")), address(fleet), "Manager");
        assertEq(vm.parseJsonBytes32(json, string.concat(entry, ".managerCodeHash")), address(fleet).codehash, "Code");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".treasury")), address(treasury), "Treasury");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(entry, ".treasuryCodeHash")), address(treasury).codehash, "Code"
        );
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".rewards")), address(fleet.REWARDS()), "Ledger");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(entry, ".rewardsCodeHash")),
            address(fleet.REWARDS()).codehash,
            "Code"
        );
        assertEq(vm.parseJsonString(json, string.concat(entry, ".name")), "Trading fleet", "Name");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".requirements.token")), address(regent), "Token");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".requirements.tokenMin")), 5e18, "Token amount");
        assertEq(
            vm.parseJsonBytes32(json, string.concat(entry, ".stakingSourceTag")),
            treasury.STAKING_SOURCE_TAG(),
            "Staking tag"
        );

        vm.prank(creator);
        treasury.close();
        json = recorder.record(manifest, _summary(deployed));
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".closedAt")), block.timestamp, "Closed");
    }

    /// @dev A Trading Fleet adds its own entry and changes nothing else the record writes.
    function test_aTradingFleetLeavesEveryOtherEntryAsItWas() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        (KeyfleetFactory deployed, KeyfleetTradingFactory trading) = _withTradingFactory(manifest);
        string memory before = recorder.record(manifest, _summary(deployed));

        _createTrading(trading, _tradingTerms());
        string memory later = recorder.record(manifest, _summary(deployed));

        string[] memory rootKeys = vm.parseJsonKeys(later, "$");
        assertEq(rootKeys.length, vm.parseJsonKeys(before, "$").length, "The same sections");
        for (uint256 index = 0; index < rootKeys.length; ++index) {
            if (_same(rootKeys[index], "fleets")) continue;
            string memory key = string.concat(".", rootKeys[index]);
            assertEq(vm.parseJson(later, key), vm.parseJson(before, key), rootKeys[index]);
        }
        assertEq(vm.parseJsonKeys(before, ".fleets").length, 6, "Six fleets before");
        assertEq(vm.parseJsonKeys(later, ".fleets").length, 7, "One more after");
        for (uint256 fleetId = 1; fleetId <= 6; ++fleetId) {
            string memory key = string.concat(".fleets.", vm.toString(fleetId));
            assertEq(vm.parseJson(later, key), vm.parseJson(before, key), key);
        }
    }

    /// @dev A fleet whose manager names the listed trading factory but is not where that factory
    /// places its fleets' managers is not recorded.
    function test_recordRefusesAManagerTheTradingFactoryDidNotPlace() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        (KeyfleetFactory deployed, KeyfleetTradingFactory trading) = _withTradingFactory(manifest);
        KeyfleetKeys collection = deployed.KEYS();
        ImpostorFactory impostors = new ImpostorFactory();
        vm.prank(safe);
        collection.addFactory(address(impostors));
        impostors.register(collection, address(trading));

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FleetNotBound.selector, 7, "manager"));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev A Trading Fleet of a trading factory built on another system's existing factory, even
    /// one the Safe added, is not recorded.
    function test_recordRefusesATradingFactoryOfAnotherSystem() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        (KeyfleetFactory deployed,) = _withTradingFactory(manifest);
        KeyfleetKeys collection = deployed.KEYS();
        MockToken otherUsdc = new MockToken("Other USD", "OUSD");
        KeyfleetTradingFactory elsewhere =
            new KeyfleetTradingFactory(IKeyfleetFactory(address(new ElsewhereFactory(deployed, otherUsdc))));
        vm.prank(safe);
        collection.addFactory(address(elsewhere));
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms();
        otherUsdc.mint(creator, terms.firstPrice);
        vm.startPrank(creator);
        otherUsdc.approve(address(elsewhere), terms.firstPrice);
        elsewhere.create(terms);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FleetNotBound.selector, 7, "tradingFactory"));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev On Base the record lists the system only while the Regents Safe owns the subscription,
    /// so nobody else can remove the collection or cancel the subscription.
    function test_recordOnBaseRefusesASubscriptionTheRegentsSafeDoesNotOwn() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory deployed = _deployListed(manifest);
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(deployScript.BASE_VRF_COORDINATOR());
        _drawnFleet(manifest, deployed);
        coordinator.openSubscription(subscriptionId, keeper);

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedByRegentsSafe.selector, keeper));
        recorder.record(manifest, _summary(deployed));
    }

    /// @dev The committed Base manifest, deployed, founded through the Safe step and recorded over
    /// a stand-in Base once the subscription and keeper are written in: the record publishes the
    /// collection on chain 8453 with the five founding fleets and their decks.
    function test_theBaseManifestDeploysFoundsAndRecords() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory deployed = deployScript.deploy(manifest);
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(deployScript.BASE_VRF_COORDINATOR());
        coordinator.openSubscription(subscriptionId, keeper);
        _make(safeSteps.foundingFleetCalls(manifest, deployed), manifest.bindings.safe);
        _openPhase(manifest, deployed);
        string memory clubOnly = recorder.record(manifest, _summary(deployed));
        assertEq(
            vm.parseJsonKeys(clubOnly, ".fleets").length, 1, "Only Club recorded without VRF consumer or Safe ownership"
        );
        _assertFleet(clubOnly, 5, "regentsClub", _managerOf(deployed, 5));
        _make(safeSteps.foundingFleetCalls(manifest, deployed), manifest.bindings.safe);
        _openPhase(manifest, deployed);
        string memory clubAndClassic = recorder.record(manifest, _summary(deployed));
        assertEq(vm.parseJsonKeys(clubAndClassic, ".fleets").length, 2, "Later Classic fills its own slot");
        _make(safeSteps.foundingFleetCalls(manifest, deployed), manifest.bindings.safe);

        string memory json = recorder.record(manifest, _summary(deployed));

        assertEq(vm.parseJsonUint(json, ".chainId"), 8453, "Base");
        assertEq(vm.parseJsonString(json, ".collection.baseTokenURI"), "https://keyfleet.ai/metadata/keys/", "Base");
        assertEq(vm.parseJsonAddress(json, ".usdc"), deployScript.BASE_USDC(), "Base USDC");
        assertEq(vm.parseJsonAddress(json, ".regentBuyer.poolManager"), deployScript.BASE_POOL_MANAGER(), "v4");
        assertEq(vm.parseJsonAddress(json, ".regentBuyer.v4Pool.hooks"), deployScript.BASE_REGENT_POOL_HOOKS(), "Hook");
        string[5] memory types = ["classic", "syndicate", "accelerant", "cascade", "regentsClub"];
        for (uint256 fleetId = 1; fleetId <= 5; ++fleetId) {
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

    function _drawnFleet(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory deployed) private {
        _found(manifest, deployed);
        while (deployed.KEYS().phase() < deployed.KEYS().FINAL_PHASE()) {
            _openPhase(manifest, deployed);
        }
        MockToken token = MockToken(address(deployed.USDC()));
        token.mint(creator, 10e6);
        vm.prank(creator);
        token.approve(address(deployed), 10e6);
        KeyfleetManager.Requirements memory anyone;
        vm.prank(creator);
        deployed.createFleet(_terms(KeyfleetPresets.Preset.FleetTechClassic, 10e6, anyone));
    }

    /// @dev The system with its founding fleets and every phase open, a Cascade `creator` created,
    /// and the trading factory deployed by its script and added to the collection by the Safe's
    /// call.
    function _withTradingFactory(KeyfleetManifest.Manifest memory manifest)
        private
        returns (KeyfleetFactory deployed, KeyfleetTradingFactory trading)
    {
        deployed = _deployListed(manifest);
        _found(manifest, deployed);
        while (deployed.KEYS().phase() < deployed.KEYS().FINAL_PHASE()) {
            _openPhase(manifest, deployed);
        }
        KeyfleetManager.Requirements memory anyone;
        usdc.mint(creator, 25e6);
        vm.startPrank(creator);
        usdc.approve(address(deployed), 25e6);
        deployed.createFleet(_terms(KeyfleetPresets.Preset.FibonacciCascade, 25e6, anyone));
        vm.stopPrank();

        trading = tradingScript.deploy(manifest, deployed);
        KeyfleetSafeSteps.SafeCall[] memory calls = new KeyfleetSafeSteps.SafeCall[](1);
        calls[0] = tradingScript.addFactoryCall(trading);
        _make(calls, manifest.bindings.safe);
    }

    /// @dev Terms of 25 USDC first, a 5% step, a 0.5% daily payback and 40 Keys, open to anyone.
    function _tradingTerms() private view returns (KeyfleetTradingFactory.TradingTerms memory terms) {
        terms.profile = _profile("Trading fleet");
        terms.firstPrice = 25e6;
        terms.stepBps = 500;
        terms.dailyPaybackBps = 50;
        terms.keyCap = 40;
        terms.deadline = block.timestamp;
    }

    /// @dev Creates a Trading Fleet as `creator`, who pays its first price.
    function _createTrading(KeyfleetTradingFactory trading, KeyfleetTradingFactory.TradingTerms memory terms)
        private
        returns (KeyfleetTradingManager)
    {
        usdc.mint(creator, terms.firstPrice);
        vm.startPrank(creator);
        usdc.approve(address(trading), terms.firstPrice);
        (uint256 fleetId,) = trading.create(terms);
        vm.stopPrank();
        return KeyfleetTradingManager(trading.KEYS().managerOf(fleetId));
    }

    function _same(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
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
