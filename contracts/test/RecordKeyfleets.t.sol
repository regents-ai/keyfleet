// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployKeyfleets} from "../script/DeployKeyfleets.s.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {RecordKeyfleets} from "../script/RecordKeyfleets.s.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "./DeployKeyfleets.t.sol";
import {MockRegent} from "./mocks/MockRegent.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

contract RecordKeyfleetsTest is Test {
    uint256 private constant ANVIL_CHAIN_ID = 31_337;
    uint256 private constant BASE_CHAIN_ID = 8453;
    address private constant REGENTS_SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    uint256 private constant DEPLOYMENT_BLOCK = 7;
    bytes32 private constant KEY_HASH = keccak256("lab gas lane");
    bytes32 private constant TRAIT_TABLE = keccak256("trait table");

    DeployKeyfleets private deployer;
    RecordKeyfleets private recorder;
    MockToken private usdc;
    MockRegentRevenueStaking private staking;
    MockRegent private regent;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private subscriptionId;

    function setUp() public {
        deployer = new DeployKeyfleets();
        recorder = new RecordKeyfleets();
        usdc = new MockToken("USD Coin", "USDC");
        staking = new MockRegentRevenueStaking(usdc);
        regent = new MockRegent();
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
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "USDC");
        assertEq(vm.parseJsonUint(json, ".qUsdc"), KeyfleetPresets.Q_USDC, "The reference price Q");
        assertEq(vm.parseJsonAddress(json, ".regentStaking"), address(staking), "Staking");
        assertEq(
            vm.parseJsonBytes32(json, ".protocolShareTag"), keccak256("keyfleet.protocol_share"), "Protocol share tag"
        );

        assertEq(vm.parseJsonString(json, ".fleet.slot"), "classic", "The key the manifest names the fleet by");
        assertEq(vm.parseJsonAddress(json, ".fleet.address"), address(fleet), "Fleet");
        assertEq(vm.parseJsonBytes32(json, ".fleet.codeHash"), address(fleet).codehash, "Fleet code");
        _assertFiveContracts(json, fleet);
        assertEq(vm.parseJsonString(json, ".fleet.name"), manifest.fleet.name, "Name");
        assertEq(vm.parseJsonString(json, ".fleet.symbol"), manifest.fleet.symbol, "Symbol");
        assertEq(
            vm.parseJsonString(json, ".fleet.baseTokenURI"),
            manifest.fleet.baseTokenURI,
            "Metadata base read from the fleet"
        );

        assertEq(vm.parseJsonAddress(json, ".regent"), address(regent), "REGENT");
        address[] memory splitAssets = vm.parseJsonAddressArray(json, ".splitAssets");
        assertEq(splitAssets.length, 3, "The assets the daily split shares");
        assertEq(splitAssets[0], address(0), "ETH");
        assertEq(splitAssets[1], address(regent), "REGENT");
        assertEq(splitAssets[2], address(usdc), "USDC");

        assertEq(vm.parseJsonUint(json, ".bounds.classicSupply"), 1024, "Classic keys");
        assertEq(vm.parseJsonUint(json, ".bounds.accelerantMaxKeys"), 2000, "Accelerant limit");
        assertEq(vm.parseJsonKeys(json, ".bounds").length, 2, "Only the Fleet.Tech presets have a limit");

        assertEq(vm.parseJsonUint(json, ".fees.protocolBps"), 1000, "Protocol bps");
        assertEq(vm.parseJsonUint(json, ".fees.accelerantCapitalBps"), 2000, "Accelerant capital bps");
        assertEq(vm.parseJsonUint(json, ".fees.bpsDenominator"), 10_000, "Bps denominator");

        assertEq(vm.parseJsonString(json, ".disclosures.chat"), "Rooms and messages are public to read.", "Chat");
        assertEq(
            vm.parseJsonString(json, ".disclosures.refunds"),
            "No refunds and no escrow. A recorded payment is not proof of delivery.",
            "Refunds"
        );
        assertEq(vm.parseJsonString(json, ".disclosures.serviceRewardEligibility"), "Keys only.", "Eligibility");
        assertEq(
            vm.parseJsonString(json, ".disclosures.feeComposition"),
            "Keyfleet takes 10% of every key purchase for REGENT stakers and nothing from money a fleet"
            " receives afterwards.",
            "Fee composition"
        );
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

    /// @dev The committed Base manifest, deployed and recorded over a stand-in Base: the record
    /// publishes the fleet's five contracts on chain 8453, depositing into REGENT revenue staking
    /// and splitting REGENT, once the operator writes in the subscription the Regents Safe owns.
    function test_theBaseManifestDeploysAndRecordsAllFiveContracts() public {
        KeyfleetManifest.Manifest memory stand = _baseManifest();
        KeyfleetManifest.Manifest memory manifest = deployer.readManifest("base", "classic");
        manifest.vrf.subscriptionId = stand.vrf.subscriptionId;
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        string memory json = recorder.record(manifest, _summary(fleet));

        assertEq(vm.parseJsonUint(json, ".chainId"), BASE_CHAIN_ID, "Base");
        assertEq(vm.parseJsonAddress(json, ".usdc"), deployer.BASE_USDC(), "Base USDC");
        assertEq(vm.parseJsonAddress(json, ".regentStaking"), deployer.BASE_REGENT_REVENUE_STAKING(), "Staking");
        assertEq(vm.parseJsonAddress(json, ".regent"), deployer.BASE_REGENT(), "REGENT");
        assertEq(vm.parseJsonString(json, ".fleet.name"), "Keyfleet Classic", "Name from the Base manifest");
        _assertFiveContracts(json, fleet);
    }

    /// @dev Each fleet records on its own, straight after its own deployment, under its own key,
    /// whichever fleets are on chain already.
    function test_eachFleetRecordsOnItsOwn() public {
        string[4] memory keys = ["syndicate", "cascade", "classic", "accelerant"];
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
        manifest.regentStaking = address(new MockRegentRevenueStaking(usdc));
        _expectRecordRefused(manifest, fleet, _released("regentStaking"));

        manifest = _manifest();
        manifest.regent = address(new MockRegent());
        _expectRecordRefused(manifest, fleet, _released("regent"));

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
    function test_recordOnBaseRefusesASubscriptionTheRegentsSafeDoesNotOwn() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        Keyfleet fleet = _deployAndAddConsumer(manifest);
        MockVRFCoordinatorV2Plus base = MockVRFCoordinatorV2Plus(address(manifest.vrf.coordinator));

        base.openSubscription(manifest.vrf.subscriptionId, address(0xBEEF));
        _expectRecordRefused(
            manifest,
            fleet,
            abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedByRegentsSafe.selector, address(0xBEEF))
        );

        base.openSubscription(manifest.vrf.subscriptionId, REGENTS_SAFE);
        recorder.record(manifest, _summary(fleet));
    }

    /// @dev Invariant: a Base record never publishes a staking contract other than REGENT revenue
    /// staking.
    function test_recordOnBaseRefusesAnyStakingButRegentRevenueStaking() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        manifest.regentStaking = address(staking);
        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.RegentStakingNotBase.selector, address(staking))
        );
    }

    function test_recordRefusesAManifestForAnotherChain() public {
        Keyfleet fleet = _deployAndAddConsumer(_manifest());
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;

        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, BASE_CHAIN_ID, ANVIL_CHAIN_ID)
        );
    }

    /// @dev Invariant: a Base record never publishes a USDC other than Base's own, even
    /// for a release that was deployed correctly.
    function test_recordOnBaseRefusesAnyUsdcButBaseUsdc() public {
        KeyfleetManifest.Manifest memory manifest = _baseManifest();
        Keyfleet fleet = _deployAndAddConsumer(manifest);

        manifest.usdc = address(usdc);
        _expectRecordRefused(
            manifest, fleet, abi.encodeWithSelector(KeyfleetManifest.UsdcNotBaseUsdc.selector, address(usdc))
        );
    }

    /// @dev Invariant: a fleet is published only once all five of its contracts exist and are bound
    /// to it, so a deployment that stopped after the fleet itself is never listed.
    function test_recordRefusesAFleetWhoseTreasuryWasNeverDeployed() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        Keyfleet.Companions memory companions = KeyfleetStack.companionsOfNextFleet();
        Keyfleet fleet = new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            Keyfleet.Metadata(manifest.fleet.name, manifest.fleet.symbol, manifest.fleet.baseTokenURI),
            manifest.vrf,
            manifest.traitTableHash,
            companions
        );
        new KeyfleetVotes(fleet);
        vrf.addConsumer(subscriptionId, address(fleet));

        _expectRecordRefused(
            manifest,
            fleet,
            abi.encodeWithSelector(RecordKeyfleets.CompanionNotBound.selector, "treasury", address(companions.treasury))
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

    /// @dev The record names the fleet's four other contracts and every one of the five
    /// contracts' runtime code hashes, as the chain reports them.
    function _assertFiveContracts(string memory json, Keyfleet fleet) private view {
        assertEq(vm.parseJsonAddress(json, ".fleet.address"), address(fleet), "Fleet");
        assertEq(vm.parseJsonBytes32(json, ".fleet.codeHash"), address(fleet).codehash, "Fleet code");
        assertEq(vm.parseJsonAddress(json, ".fleet.rewards"), address(fleet.REWARDS()), "Ledger");
        assertEq(vm.parseJsonBytes32(json, ".fleet.rewardsCodeHash"), address(fleet.REWARDS()).codehash, "Ledger code");
        assertEq(vm.parseJsonAddress(json, ".fleet.votes"), address(fleet.VOTES()), "Controller");
        assertEq(vm.parseJsonBytes32(json, ".fleet.votesCodeHash"), address(fleet.VOTES()).codehash, "Controller code");
        assertEq(vm.parseJsonAddress(json, ".fleet.treasury"), address(fleet.TREASURY()), "Treasury");
        assertEq(
            vm.parseJsonBytes32(json, ".fleet.treasuryCodeHash"), address(fleet.TREASURY()).codehash, "Treasury code"
        );
        assertEq(vm.parseJsonAddress(json, ".fleet.shards"), address(fleet.SHARDS()), "Shard record");
        assertEq(
            vm.parseJsonBytes32(json, ".fleet.shardsCodeHash"), address(fleet.SHARDS()).codehash, "Shard record code"
        );
        assertTrue(address(fleet.TREASURY()).codehash != bytes32(0), "Code is on chain");
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

    /// @dev A Base manifest on Base, paid in Base USDC and answered by Base's VRF
    /// coordinator on its 2 gwei lane, depositing into REGENT revenue staking and splitting REGENT,
    /// all stood in for by the local mocks' code, with the Regents Safe as the subscription's owner.
    function _baseManifest() private returns (KeyfleetManifest.Manifest memory manifest) {
        vm.chainId(BASE_CHAIN_ID);
        vm.etch(deployer.BASE_USDC(), address(usdc).code);
        vm.etch(deployer.BASE_REGENT_REVENUE_STAKING(), address(staking).code);
        vm.etch(deployer.BASE_REGENT(), address(regent).code);
        MockVRFCoordinatorV2Plus base = MockVRFCoordinatorV2Plus(deployer.BASE_VRF_COORDINATOR());
        vm.etch(address(base), address(vrf).code);
        base.addProvingKey(deployer.BASE_VRF_KEY_HASH_2_GWEI(), 2 gwei);
        manifest = _manifest();
        manifest.chainId = BASE_CHAIN_ID;
        manifest.usdc = deployer.BASE_USDC();
        manifest.vrf.coordinator = IVRFCoordinatorV2Plus(address(base));
        manifest.vrf.subscriptionId = base.createSubscription();
        base.openSubscription(manifest.vrf.subscriptionId, REGENTS_SAFE);
        manifest.vrf.keyHash = deployer.BASE_VRF_KEY_HASH_2_GWEI();
        manifest.regentStaking = deployer.BASE_REGENT_REVENUE_STAKING();
        manifest.regent = deployer.BASE_REGENT();
    }

    function _manifest() private view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.usdc = address(usdc);
        manifest.regentStaking = address(staking);
        manifest.regent = address(regent);
        manifest.vrf = Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
        });
        manifest.traitTableHash = TRAIT_TABLE;
        manifest.slot = 2;
        manifest.fleet = KeyfleetManifest.FleetSpec("Keyfleet Classic", "KEYFLEET", "https://k/classic/");
    }
}
