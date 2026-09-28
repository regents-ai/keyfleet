// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployKeyfleets} from "../script/DeployKeyfleets.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {RecordKeyfleets} from "../script/RecordKeyfleets.s.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken, StrategyPublishingFactory} from "./DeployKeyfleets.t.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Stands in for the Autolaunch strategy: the record step reads only its address and its code.
contract StandInStrategy {}

contract RecordKeyfleetsTest is Test {
    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    uint256 private constant BASE_CHAIN_ID = 8453;
    address private constant SAFE = address(0x5AFE);
    address private constant STAKING = address(0x57A1);
    uint256 private constant DEPLOYMENT_BLOCK = 7;
    bytes32 private constant KEY_HASH = keccak256("lab gas lane");
    bytes32 private constant TRAIT_TABLE = keccak256("trait table");

    DeployKeyfleets private deployer;
    RecordKeyfleets private recorder;
    MockToken private regent;
    MockToken private usdc;
    StandInStrategy private strategy;
    StrategyPublishingFactory private factory;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private subscriptionId;

    function setUp() public {
        deployer = new DeployKeyfleets();
        recorder = new RecordKeyfleets();
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        strategy = new StandInStrategy();
        factory = new StrategyPublishingFactory(address(strategy));
        vrf = new MockVRFCoordinatorV2Plus();
        vrf.addProvingKey(KEY_HASH, 30 gwei);
        subscriptionId = vrf.createSubscription();
    }

    function test_recordPublishesTheFleetAsTheChainReportsIt() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        string memory json = recorder.record(manifest, _summary(fleet));

        assertEq(vm.parseJsonUint(json, ".chainId"), ANVIL_CHAIN_ID, "Chain");
        assertEq(vm.parseJsonUint(json, ".deploymentBlock"), DEPLOYMENT_BLOCK, "Deployment block");
        assertEq(vm.parseJsonAddress(json, ".regent"), address(regent), "REGENT");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "USDC");
        assertEq(vm.parseJsonUint(json, ".qUsdc"), KeyfleetPresets.Q_USDC, "Every first key costs 10 USDC");
        assertEq(vm.parseJsonAddress(json, ".staking"), STAKING, "Staking");
        assertEq(vm.parseJsonAddress(json, ".regentSafe"), SAFE, "Regents Safe");

        assertEq(vm.parseJsonString(json, ".fleet.slot"), "classic", "The key the manifest names the fleet by");
        assertEq(vm.parseJsonAddress(json, ".fleet.address"), address(fleet), "Fleet");
        assertEq(vm.parseJsonBytes32(json, ".fleet.codeHash"), address(fleet).codehash, "Fleet code");
        assertEq(vm.parseJsonAddress(json, ".fleet.rewards"), address(fleet.REWARDS()), "Ledger");
        assertEq(vm.parseJsonAddress(json, ".fleet.votes"), address(fleet.VOTES()), "Controller");
        assertEq(vm.parseJsonString(json, ".fleet.name"), manifest.fleet.name, "Name");
        assertEq(vm.parseJsonString(json, ".fleet.symbol"), manifest.fleet.symbol, "Symbol");
        assertEq(
            vm.parseJsonString(json, ".fleet.baseTokenURI"),
            manifest.fleet.baseTokenURI,
            "Metadata base read from the fleet"
        );
        assertEq(vm.parseJsonUint(json, ".fleet.maxSupply"), 144, "Classic's supply");

        address[] memory incomeTokens = vm.parseJsonAddressArray(json, ".incomeTokens");
        assertEq(incomeTokens.length, 2, "Two income tokens before any launch");
        assertEq(incomeTokens[0], address(usdc), "USDC");
        assertEq(incomeTokens[1], address(regent), "REGENT");

        assertEq(vm.parseJsonUint(json, ".bounds.fibonacciLevels"), 20, "Levels");
        assertEq(vm.parseJsonUint(json, ".bounds.fibonacciMaxTokenId"), 46_365, "Highest token id");
        assertEq(vm.parseJsonUint(json, ".bounds.classicSupply"), 144, "Classic seats");
        assertEq(vm.parseJsonUint(json, ".bounds.accelerantMaxKeys"), 2000, "Accelerant cap");
        assertEq(vm.parseJsonUint(json, ".bounds.fibonacciAutolaunchMinKeys"), 86, "Launch after level 7");
        assertEq(vm.parseJsonUint(json, ".bounds.fleetTechAutolaunchMinKeys"), 100, "Launch after 100 keys");
        assertEq(vm.parseJsonUint(json, ".bounds.maxCohorts"), 32, "Cohort bound");

        assertEq(vm.parseJsonUint(json, ".fees.protocolBps"), 200, "Protocol bps");
        assertEq(vm.parseJsonUint(json, ".fees.accelerantCapitalBps"), 1000, "Accelerant capital bps");
        assertEq(vm.parseJsonUint(json, ".fees.bpsDenominator"), 10_000, "Bps denominator");

        assertEq(vm.parseJsonString(json, ".autolaunch.abi"), "RegentsAutolaunchFactoryV2", "Factory ABI");
        assertEq(vm.parseJsonAddress(json, ".autolaunch.factory"), address(factory), "Autolaunch factory");
        assertEq(vm.parseJsonBytes32(json, ".autolaunch.factoryCodeHash"), address(factory).codehash, "Factory code");
        assertEq(vm.parseJsonAddress(json, ".autolaunch.strategy"), address(strategy), "Strategy read off the factory");
        assertEq(vm.parseJsonBytes32(json, ".autolaunch.strategyCodeHash"), address(strategy).codehash, "Strategy code");
        assertFalse(vm.parseJsonBool(json, ".autolaunch.factoryMayBeEmpty"), "No waiver in force");
        assertTrue(bytes(vm.parseJsonString(json, ".autolaunch.readiness")).length > 0, "Readiness");

        assertEq(vm.parseJsonString(json, ".disclosures.chat"), "Rooms and messages are public to read.", "Chat");
        assertEq(
            vm.parseJsonString(json, ".disclosures.refunds"),
            "No refunds and no escrow. A recorded payment is not proof of delivery.",
            "Refunds"
        );
        assertEq(vm.parseJsonString(json, ".disclosures.serviceRewardEligibility"), "Keys only.", "Eligibility");
        assertTrue(bytes(vm.parseJsonString(json, ".disclosures.feeComposition")).length > 0, "Fee composition");
        assertTrue(bytes(vm.parseJsonString(json, ".disclosures.safeAuthority")).length > 0, "Safe authority");

        assertEq(vm.parseJsonAddress(json, ".vrf.coordinator"), address(vrf), "VRF coordinator");
        assertEq(vm.parseJsonBytes32(json, ".vrf.coordinatorCodeHash"), address(vrf).codehash, "Coordinator code");
        assertEq(vm.parseJsonString(json, ".vrf.subscriptionId"), vm.toString(subscriptionId), "Subscription");
        assertEq(vm.parseJsonUint(json, ".vrf.subscriptionId"), subscriptionId, "Subscription, all its digits");
        assertEq(vm.parseJsonBytes32(json, ".vrf.keyHash"), KEY_HASH, "Gas lane");
        assertEq(vm.parseJsonBytes32(json, ".traitTableHash"), TRAIT_TABLE, "Trait table");
        assertEq(vm.parseJsonUint(json, ".vrf.requestConfirmations"), 3, "Confirmations");
        assertEq(vm.parseJsonUint(json, ".vrf.callbackGasLimit"), 100_000, "Callback gas");
        assertTrue(vm.parseJsonBool(json, ".vrf.nativePayment"), "Paid in ETH");
    }

    /// @dev Each fleet records on its own, straight after its own deployment, under its own key
    /// and with its own supply, whichever fleets are on chain already.
    function test_eachFleetRecordsOnItsOwn() public {
        string[4] memory keys = ["syndicate", "cascade", "classic", "accelerant"];
        uint256[4] memory supplies = [uint256(46_365), 46_365, 144, 2000];
        KeyfleetManifest.Manifest memory manifest = _manifest();

        for (uint8 order = 0; order < 4; ++order) {
            // Classic first, then the others.
            uint8 slot = (order + 2) % 4;
            manifest.slot = slot;
            manifest.fleet = KeyfleetManifest.FleetSpec(
                string.concat("Fleet ", keys[slot]), "KEYFLEET", string.concat("https://k/", keys[slot], "/")
            );
            Keyfleet fleet = _deployAndAddConsumer(manifest);

            string memory json = recorder.record(manifest, _summary(fleet));

            assertEq(vm.parseJsonString(json, ".fleet.slot"), keys[slot], "Key");
            assertEq(vm.parseJsonAddress(json, ".fleet.address"), address(fleet), "Fleet");
            assertEq(vm.parseJsonUint(json, ".fleet.maxSupply"), supplies[slot], "Supply");
        }
    }

    /// @dev Invariant: a fleet is published only once the subscription pays for its reveals, so
    /// the site never lists a fleet whose keys would stay unrevealed.
    function test_recordRefusesAFleetTheSubscriptionDoesNotListYet() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        Keyfleet fleet = deployer.deploy(manifest);

        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(RecordKeyfleets.FleetNotVrfConsumer.selector, fleet)
        );

        vrf.addConsumer(subscriptionId, address(fleet));
        recorder.record(manifest, _summary(fleet));
    }

    function test_recordOfALabWithoutTheAutolaunchFactoryRecordsNoStrategy() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.autolaunchFactory = address(0xFAC7);
        manifest.autolaunchFactoryMayBeEmpty = true;
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        string memory json = recorder.record(manifest, _summary(fleet));

        assertEq(vm.parseJsonAddress(json, ".autolaunch.strategy"), address(0), "No strategy to read");
        assertEq(vm.parseJsonBytes32(json, ".autolaunch.factoryCodeHash"), bytes32(0), "No factory code");
        assertTrue(vm.parseJsonBool(json, ".autolaunch.factoryMayBeEmpty"), "The lab shape is recorded");
    }

    function test_recordRefusesEveryValueThatDiffersFromTheManifest() public {
        Keyfleet fleet = _deployAndAddConsumer(_manifest());
        KeyfleetManifest.Manifest memory manifest;

        manifest = _manifest();
        manifest.slot = 1;
        manifest.fleet = KeyfleetManifest.FleetSpec("Keyfleet Classic", "KEYFLEET", "https://k/classic/");
        _expectRecordRefused(manifest, fleet, _released("preset"));

        manifest = _manifest();
        manifest.usdc = address(0xBEEF);
        _expectRecordRefused(manifest, fleet, _released("usdc"));

        manifest = _manifest();
        manifest.regent = address(usdc);
        _expectRecordRefused(manifest, fleet, _released("regent"));

        manifest = _manifest();
        manifest.staking = address(0xBEEF);
        _expectRecordRefused(manifest, fleet, _released("staking"));

        manifest = _manifest();
        manifest.autolaunchFactory = address(regent);
        _expectRecordRefused(manifest, fleet, _released("autolaunchFactory"));

        manifest = _manifest();
        manifest.vrf.coordinator = IVRFCoordinatorV2Plus(address(_otherCoordinatorKnowing(manifest)));
        _expectRecordRefused(manifest, fleet, _released("vrf.coordinator"));

        manifest = _manifest();
        manifest.vrf.subscriptionId = vrf.createSubscription();
        _expectRecordRefused(manifest, fleet, _released("vrf.subscriptionId"));

        manifest = _manifest();
        manifest.vrf.keyHash = keccak256("another lane");
        vrf.addProvingKey(manifest.vrf.keyHash, 30 gwei);
        _expectRecordRefused(manifest, fleet, _released("vrf.keyHash"));

        manifest = _manifest();
        manifest.traitTableHash = keccak256("another table");
        _expectRecordRefused(manifest, fleet, _released("traitTableHash"));

        manifest = _manifest();
        manifest.fleet.name = "Another name";
        _expectRecordRefused(manifest, fleet, _released("name"));

        manifest = _manifest();
        manifest.fleet.symbol = "OTHER";
        _expectRecordRefused(manifest, fleet, _released("symbol"));

        manifest = _manifest();
        manifest.fleet.baseTokenURI = "https://k/other/";
        _expectRecordRefused(manifest, fleet, _released("baseTokenURI"));
    }

    /// @dev A zero trait table is refused by the manifest check itself, before anything is read back
    /// from the chain, so the refusal names the missing table rather than a mismatch.
    function test_recordRefusesAManifestWithoutATraitTable() public {
        Keyfleet fleet = _deployAndAddConsumer(_manifest());
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.traitTableHash = bytes32(0);

        _expectRecordRefused(manifest, fleet, abi.encodeWithSelector(Keyfleet.TraitTableHashZero.selector));
    }

    /// @dev Invariant: on Base a fleet is published only while the Regents Safe owns the
    /// subscription that pays for its reveals, so nobody else can remove the fleet or cancel it.
    function test_recordOnBaseRefusesASubscriptionTheSafeDoesNotOwn() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        Keyfleet fleet = _deployAndAddConsumer(manifest);
        MockVRFCoordinatorV2Plus base = MockVRFCoordinatorV2Plus(address(manifest.vrf.coordinator));

        base.openSubscription(manifest.vrf.subscriptionId, address(0xBEEF));
        _expectRecordRefused(
            manifest,
            fleet,
            abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedBySafe.selector, address(0xBEEF), SAFE)
        );

        base.openSubscription(manifest.vrf.subscriptionId, SAFE);
        recorder.record(manifest, _summary(fleet));
    }

    function test_recordRefusesAManifestForAnotherChain() public {
        Keyfleet fleet = _deployAndAddConsumer(_manifest());
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;

        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, BASE_CHAIN_ID, ANVIL_CHAIN_ID)
        );
    }

    function test_emptyFactoryWaiverIsNeverRecordedOnBase() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        manifest.autolaunchFactoryMayBeEmpty = true;
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        string memory json = recorder.record(manifest, _summary(fleet));

        assertFalse(vm.parseJsonBool(json, ".autolaunch.factoryMayBeEmpty"), "Base ignores the waiver");
    }

    /// @dev Invariant: a Base record never publishes a USDC or a REGENT other than Base's own, even
    /// for a release that was deployed correctly.
    function test_recordOnBaseRefusesAnyUsdcOrRegentButBase() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        manifest.usdc = address(usdc);
        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.UsdcNotBaseUsdc.selector, address(usdc))
        );

        manifest = _baseManifest();
        manifest.regent = address(regent);
        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.RegentNotBaseRegent.selector, address(regent))
        );
    }

    /// @dev Invariant: the REGENT a record publishes always holds code, so a zero or mistyped
    /// address is never published into `regent`.
    function test_recordRefusesARegentWithoutCode() public {
        Keyfleet fleet = _deployAndAddConsumer(_manifest());
        KeyfleetManifest.Manifest memory manifest = _manifest();

        manifest.regent = address(0xBEEF);
        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.RegentMissing.selector, address(0xBEEF))
        );

        manifest.regent = address(0);
        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.RegentMissing.selector, address(0))
        );
    }

    function test_recordRefusesAFleetWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.FleetMissing.selector, address(0xF1)));
        recorder.record(_manifest(), _summary(Keyfleet(address(0xF1))));
    }

    function test_broadcastNamesItsFleetAndItsEarliestBlock() public view {
        RecordKeyfleets.BroadcastSummary memory summary = recorder.parseBroadcast(
            _broadcast('{"status": "0x1", "blockNumber": "0x10"}, {"status": "0x1", "blockNumber": "0xf"}')
        );

        assertEq(address(summary.fleet), address(0xF1), "Fleet from its creation");
        assertEq(summary.deploymentBlock, 15, "Lowest receipt block, not the first");
    }

    function test_broadcastWithAFailedReceiptIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.BroadcastReceiptFailed.selector, 1));
        recorder.parseBroadcast(
            _broadcast('{"status": "0x1", "blockNumber": "0xf"}, {"status": "0x0", "blockNumber": "0xf"}')
        );
    }

    function test_broadcastWithATransactionAwaitingItsReceiptIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.BroadcastIncomplete.selector, 2, 1));
        recorder.parseBroadcast(_broadcast('{"status": "0x1", "blockNumber": "0xf"}'));
    }

    function test_broadcastWithoutAFleetIsRefused() public {
        string memory json = string.concat(
            '{"transactions": [',
            '{"contractName": "MockToken", "contractAddress": "0x00000000000000000000000000000000000000a1"}',
            '], "receipts": [{"status": "0x1", "blockNumber": "0xf"}]}'
        );

        vm.expectRevert(RecordKeyfleets.FleetNotInBroadcast.selector);
        recorder.parseBroadcast(json);
    }

    /// @dev A broadcast in the shape Forge writes, whose fleet is not its first transaction, with
    /// the given receipts.
    function _broadcast(string memory receipts) private pure returns (string memory) {
        return string.concat(
            '{"transactions": [',
            '{"contractName": "MockToken", "contractAddress": "0x00000000000000000000000000000000000000a1"},',
            '{"contractName": "Keyfleet", "contractAddress": "0x00000000000000000000000000000000000000f1"}',
            '], "receipts": [',
            receipts,
            "]}"
        );
    }

    /// @dev Deploys, then adds the fleet to the manifest's subscription as its owner does between
    /// the two steps: the Safe on Base, the test contract on a lab chain.
    function _deployAndAddConsumer(KeyfleetManifest.Manifest memory manifest) private returns (Keyfleet fleet) {
        fleet = deployer.deploy(manifest);
        (,,, address owner,) = manifest.vrf.coordinator.getSubscription(manifest.vrf.subscriptionId);
        vm.prank(owner);
        manifest.vrf.coordinator.addConsumer(manifest.vrf.subscriptionId, address(fleet));
    }

    /// @dev A second coordinator that knows the manifest's gas lane and subscription id, so only
    /// the comparison with the fleet can refuse it.
    function _otherCoordinatorKnowing(KeyfleetManifest.Manifest memory manifest)
        private
        returns (MockVRFCoordinatorV2Plus other)
    {
        other = new MockVRFCoordinatorV2Plus();
        other.addProvingKey(manifest.vrf.keyHash, 30 gwei);
        other.openSubscription(manifest.vrf.subscriptionId, address(this));
    }

    function _expectRecordRefused(KeyfleetManifest.Manifest memory manifest, Keyfleet fleet, bytes memory expected)
        private
    {
        vm.expectRevert(expected);
        recorder.record(manifest, _summary(fleet));
    }

    function _released(string memory field) private pure returns (bytes memory) {
        return abi.encodeWithSelector(RecordKeyfleets.RecordedMismatch.selector, field);
    }

    function _summary(Keyfleet fleet) private pure returns (RecordKeyfleets.BroadcastSummary memory) {
        return RecordKeyfleets.BroadcastSummary({fleet: fleet, deploymentBlock: DEPLOYMENT_BLOCK});
    }

    /// @dev A Base manifest on Base, paid in Base USDC, naming Base REGENT and answered by Base's
    /// VRF coordinator on its 2 gwei lane, all stood in for by the local mocks' code, with the
    /// subscription owned by the Safe.
    function _baseManifest() private returns (KeyfleetManifest.Manifest memory manifest) {
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(deployer.BASE_USDC(), address(usdc).code);
        vm.etch(deployer.BASE_REGENT(), address(regent).code);
        MockVRFCoordinatorV2Plus base = MockVRFCoordinatorV2Plus(deployer.BASE_VRF_COORDINATOR());
        vm.etch(address(base), address(vrf).code);
        base.addProvingKey(deployer.BASE_VRF_KEY_HASH(), 2 gwei);
        manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;
        manifest.usdc = deployer.BASE_USDC();
        manifest.regent = deployer.BASE_REGENT();
        manifest.vrf.coordinator = IVRFCoordinatorV2Plus(address(base));
        manifest.vrf.subscriptionId = base.createSubscription();
        base.openSubscription(manifest.vrf.subscriptionId, SAFE);
        manifest.vrf.keyHash = deployer.BASE_VRF_KEY_HASH();
    }

    function _manifest() private view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.regent = address(regent);
        manifest.usdc = address(usdc);
        manifest.staking = STAKING;
        manifest.regentSafe = SAFE;
        manifest.autolaunchFactory = address(factory);
        manifest.autolaunchFactoryMayBeEmpty = false;
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
        });
        manifest.traitTableHash = TRAIT_TABLE;
        manifest.slot = 2;
        manifest.fleet = KeyfleetManifest.FleetSpec("Keyfleet Classic", "KEYFLEET", "https://k/classic/");
    }
}
