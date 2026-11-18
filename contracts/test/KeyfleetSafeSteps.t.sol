// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../script/KeyfleetSafeSteps.s.sol";
import {RecordKeyfleets} from "../script/RecordKeyfleets.s.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";
import {MockClubPass} from "./mocks/MockClubPass.sol";
import {MockContractWallet} from "./mocks/MockContractWallet.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev A contract that cannot take an NFT sent with a safe transfer.
contract NoReceiver {}

/// @dev A contract that answers every call with nothing, which a safe transfer also refuses.
contract Silent {
    fallback() external {}
}

contract KeyfleetSafeStepsTest is KeyfleetScriptFixture {
    KeyfleetFactory private deployed;
    KeyfleetKeys private collection;

    function setUp() public {
        _setUpScripts();
        deployed = _deployListed(_manifest());
        collection = deployed.KEYS();
    }

    /// @dev The founding step is one call per founding fleet, in founding order, each creating the
    /// fleet with the manifest's type, deck and profile, and each its own transaction.
    function test_foundingStepCreatesEveryFoundingFleetWithTheManifestsDeckAndProfile() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, deployed);
        assertEq(calls.length, 1, "Only Club in phase zero");
        assertEq(calls[0].name, "founding-fleet-5");
        _make(calls, safe);
        assertFalse(collection.fleetExists(1));
        _openPhase(manifest, deployed);
        assertTrue(collection.salesOpen(5));
        assertFalse(collection.salesOpen(1));
        calls = safeSteps.foundingFleetCalls(manifest, deployed);
        assertEq(calls.length, 1, "Only Classic in phase one");
        assertEq(calls[0].name, "founding-fleet-1");
        _make(calls, safe);
        _openPhase(manifest, deployed);
        calls = safeSteps.foundingFleetCalls(manifest, deployed);
        assertEq(calls.length, 3, "Other sold founding fleets in phase two");
        _make(calls, safe);

        for (uint256 fleetId = 1; fleetId <= 5; ++fleetId) {
            KeyfleetManifest.FoundingFleet memory expected = manifest.founding[fleetId - 1];
            KeyfleetKeys.Fleet memory fleet = collection.fleet(fleetId);
            assertTrue(fleet.preset == expected.preset, "Type");
            assertEq(fleet.deckHash, expected.deckHash, "Deck");
            assertEq(fleet.deckSize, expected.deckSize, "Deck size");
            KeyfleetManager.Profile memory profile = _managerOf(deployed, fleetId).profile();
            assertEq(profile.name, expected.profile.name, "Name");
            assertEq(profile.description, expected.profile.description, "Description");
            assertEq(profile.imageLink, expected.profile.imageLink, "Image");
            assertEq(collection.salesOpen(fleetId), fleetId == 1 || fleetId == 5, "Only opened phases sell");
        }
        assertEq(collection.phase(), 2, "Club then Classic opened");
    }

    /// @dev Run again partway, the step names only the founding fleets still missing, and once all
    /// five exist it names none.
    function test_foundingStepNamesOnlyTheFleetsStillMissing() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, deployed);
        _make(calls, safe);
        assertEq(safeSteps.foundingFleetCalls(manifest, deployed).length, 0, "Club already exists");
        _openPhase(manifest, deployed);
        _make(safeSteps.foundingFleetCalls(manifest, deployed), safe);
        assertEq(safeSteps.foundingFleetCalls(manifest, deployed).length, 0, "Classic already exists");
        _openPhase(manifest, deployed);
        calls = safeSteps.foundingFleetCalls(manifest, deployed);
        KeyfleetSafeSteps.SafeCall[] memory first = new KeyfleetSafeSteps.SafeCall[](1);
        first[0] = calls[0];
        _make(first, safe);
        calls = safeSteps.foundingFleetCalls(manifest, deployed);
        assertEq(calls.length, 2);
        assertEq(calls[0].name, "founding-fleet-3");
        assertEq(calls[1].name, "founding-fleet-4");
        _make(calls, safe);
        assertEq(safeSteps.foundingFleetCalls(manifest, deployed).length, 0, "Nothing left");
    }

    /// @dev Only the Safe can make the founding calls.
    function test_foundingCallsFromAnyoneButTheSafeAreRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, deployed);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.OnlySafe.selector, keeper));
        this.make(calls, keeper);
    }

    /// @dev The phase step moves the collection one phase on, and is refused by the collection
    /// until the fleets that phase opens exist and once the last phase is reached.
    function test_phaseStepMovesOnePhaseAtATime() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        uint64 opensAt = uint64(block.timestamp + 1 days);
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.advancePhaseCalls(manifest, deployed, opensAt);
        assertEq(calls.length, 1, "One call");
        assertEq(calls[0].name, "phase-1", "Named for the phase it reaches");
        assertEq(calls[0].to, address(collection), "To the collection");
        assertEq(calls[0].data, abi.encodeCall(KeyfleetKeys.advancePhase, (opensAt)), "Opening when it says");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.FleetsMissing.selector, 1, 0));
        this.make(calls, safe);

        _found(manifest, deployed);
        for (uint8 phase = 1; phase <= collection.FINAL_PHASE(); ++phase) {
            calls = safeSteps.advancePhaseCalls(manifest, deployed, uint64(block.timestamp + 1));
            assertEq(calls[0].name, string.concat("phase-", vm.toString(phase)), "Next phase");
            _make(calls, safe);
            assertEq(collection.phase(), phase, "Moved");
            vm.warp(block.timestamp + 1);
        }
        assertTrue(collection.salesOpen(1) && collection.salesOpen(5), "Every founding fleet sells");

        calls = safeSteps.advancePhaseCalls(manifest, deployed, uint64(block.timestamp + 1));
        vm.expectRevert(KeyfleetKeys.NoNextPhase.selector);
        this.make(calls, safe);
    }

    function test_phaseCallsFromAnyoneButTheSafeAreRefused() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        _found(manifest, deployed);
        KeyfleetSafeSteps.SafeCall[] memory calls =
            safeSteps.advancePhaseCalls(manifest, deployed, uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlySafe.selector, keeper));
        this.make(calls, keeper);
    }

    /// @dev From phase 3 anyone may buy a founding Key past its deck, and from phase 4 create a
    /// fleet, so a Key may draw, and the record then lists the system only while the subscription
    /// lists the collection: the steps to phases 3 and 4 are each refused until it does, and the
    /// phases before them are not. Off Base its owner may be anyone.
    function test_theDrawingPhaseStepsWaitUntilTheSubscriptionListsTheCollection() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory unlisted = deployScript.deploy(manifest);
        KeyfleetKeys keys = unlisted.KEYS();
        MockVRFCoordinatorV2Plus coordinator =
            MockVRFCoordinatorV2Plus(address(manifest.bindings.randomness.coordinator));
        uint256 subscriptionId = manifest.bindings.randomness.subscriptionId;
        _found(manifest, unlisted);
        while (keys.phase() + 1 < safeSteps.FIRST_DRAWING_PHASE()) {
            _openPhase(manifest, unlisted);
        }

        while (keys.phase() < keys.FINAL_PHASE()) {
            vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.CollectionNotVrfConsumer.selector, address(keys)));
            safeSteps.advancePhaseCalls(manifest, unlisted, uint64(block.timestamp + 1));

            _listConsumer(manifest, keys);
            _openPhase(manifest, unlisted);
            vm.prank(coordinator.subscriptionOwner(subscriptionId));
            coordinator.removeConsumer(subscriptionId, address(keys));
        }
        assertEq(keys.phase(), keys.FINAL_PHASE(), "Each opened once it lists it");
    }

    /// @dev On Base the steps to phases 3 and 4 are each refused while anyone but the Regents Safe
    /// owns the subscription, even one that lists the collection, and prepared once the Safe owns
    /// it; the phases before them open whoever owns it.
    function test_onBaseTheDrawingPhaseStepsWaitUntilTheRegentsSafeOwnsTheSubscription() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        KeyfleetKeys keys = base.KEYS();
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(safeSteps.BASE_VRF_COORDINATOR());
        _found(manifest, base);
        coordinator.openSubscription(subscriptionId, keeper);
        while (keys.phase() + 1 < safeSteps.FIRST_DRAWING_PHASE()) {
            _openPhase(manifest, base);
        }

        while (keys.phase() < keys.FINAL_PHASE()) {
            coordinator.openSubscription(subscriptionId, keeper);
            vm.expectRevert(
                abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedByRegentsSafe.selector, keeper)
            );
            safeSteps.advancePhaseCalls(manifest, base, uint64(block.timestamp + 1));

            coordinator.openSubscription(subscriptionId, safeSteps.BASE_REGENTS_SAFE());
            _openPhase(manifest, base);
        }
        assertEq(keys.phase(), keys.FINAL_PHASE(), "Each opened once the Safe owns it");
    }

    /// @dev The call to phase 2 checks nothing of the subscription and names no phase, so the phase
    /// moves when the first file for it lands: on Base, of two phase-2 files written in phase 1,
    /// the second, landed after the first and before phase 2 has opened, opens phase 3 once the step
    /// has founded fleets 2 to 4, though another account owns the subscription by then, as its
    /// description warns.
    function test_aSecondPhaseTwoFileLandedBeforePhaseTwoOpensOpensPhaseThreeAsItsDescriptionWarns() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        KeyfleetKeys keys = base.KEYS();
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(safeSteps.BASE_VRF_COORDINATOR());
        address signers = manifest.bindings.safe;
        _make(safeSteps.foundingFleetCalls(manifest, base), signers);
        _openPhase(manifest, base);
        _make(safeSteps.foundingFleetCalls(manifest, base), signers);
        KeyfleetSafeSteps.SafeCall[] memory first =
            safeSteps.advancePhaseCalls(manifest, base, uint64(block.timestamp + 10 days));
        KeyfleetSafeSteps.SafeCall[] memory second =
            safeSteps.advancePhaseCalls(manifest, base, uint64(block.timestamp + 20 days));
        assertTrue(
            _names(second[0].description, "with no check of the randomness subscription: in phase 2, to phase 3, "),
            "Landed in phase 2 it opens phase 3, unchecked"
        );

        _make(first, signers);
        _make(safeSteps.foundingFleetCalls(manifest, base), signers);
        coordinator.openSubscription(subscriptionId, keeper);
        assertLt(block.timestamp, keys.phaseOpensAt(), "Phase 2 has not opened");
        _make(second, signers);
        assertEq(keys.phase(), 3, "The second phase-2 file opened phase 3");
        assertEq(keys.phaseOpensAt(), block.timestamp + 20 days, "At its own time");
        assertEq(coordinator.subscriptionOwner(subscriptionId), keeper, "With the subscription not the Safe's");
    }

    /// @dev On Base, each phase file written by the step, landed once other files have moved the
    /// collection on from the phase it was written in, moves the collection one more phase from each
    /// phase up to phase 3, opening it at the file's own time with the sales that phase opens, though
    /// by then the subscription is neither the Safe's nor lists the collection. In phase 4 it is
    /// refused, and from its own opening time it is refused in every phase.
    function test_aPhaseFileLandedAfterItsPhaseHasMovedOnMovesTheCollectionOneMorePhase() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        _found(manifest, base);
        for (uint256 file = 1; file <= base.KEYS().FINAL_PHASE(); ++file) {
            uint256 start = vm.snapshotState();
            _landAfterItsPhaseMovedOn(manifest, base, file);
            vm.revertToState(start);
        }
    }

    /// @dev Writes the file for phase `file` in phase `file - 1`, opening in 20 days, then moves the
    /// collection on by files written as each phase comes, each opening in 10 days, and in every
    /// phase it reaches lands the first file, and lands it again at its own opening time, putting the
    /// chain back after each.
    function _landAfterItsPhaseMovedOn(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory factory, uint256 file)
        private
    {
        KeyfleetKeys keys = factory.KEYS();
        address signers = manifest.bindings.safe;
        while (keys.phase() + 1 < file) {
            _openPhase(manifest, factory);
        }
        uint64 late = uint64(vm.getBlockTimestamp() + 20 days);
        uint64 sooner = uint64(vm.getBlockTimestamp() + 10 days);
        KeyfleetSafeSteps.SafeCall[] memory stale = safeSteps.advancePhaseCalls(manifest, factory, late);
        for (uint256 phase = file; phase <= keys.FINAL_PHASE(); ++phase) {
            _make(safeSteps.advancePhaseCalls(manifest, factory, sooner), signers);
            assertEq(keys.phase(), phase, "Moved on by another file");

            uint256 moved = vm.snapshotState();
            _unready(keys);
            if (phase == keys.FINAL_PHASE()) {
                vm.expectRevert(KeyfleetKeys.NoNextPhase.selector);
                this.make(stale, signers);
            } else {
                _make(stale, signers);
                assertEq(keys.phase(), phase + 1, "One more phase");
                assertEq(keys.phaseOpensAt(), late, "Opening at the file's own time");
                if (phase + 1 == 2) assertEq(keys.salesOpenAt(1), late, "Classic #1's sales");
                if (phase + 1 == 3) {
                    for (uint256 id = 2; id <= 4; ++id) {
                        assertEq(keys.salesOpenAt(id), late, "Syndicate, Accelerant and Cascade #1's sales");
                    }
                }
            }
            vm.revertToState(moved);

            moved = vm.snapshotState();
            vm.warp(late);
            if (phase == keys.FINAL_PHASE()) vm.expectRevert(KeyfleetKeys.NoNextPhase.selector);
            else vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OpensAtInvalid.selector, late));
            this.make(stale, signers);
            vm.revertToState(moved);
        }
    }

    /// @dev Leaves `keys`'s randomness subscription neither listing the collection nor owned by the
    /// Regents Safe.
    function _unready(KeyfleetKeys keys) private {
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId,) = keys.randomness();
        MockVRFCoordinatorV2Plus standIn = MockVRFCoordinatorV2Plus(address(coordinator));
        vm.prank(standIn.subscriptionOwner(subscriptionId));
        standIn.removeConsumer(subscriptionId, address(keys));
        standIn.openSubscription(subscriptionId, keeper);
    }

    /// @dev Off Base, in phase 2 with fleets 2 to 4 all created, the founding step prepares nothing
    /// and does not refuse, though the subscription no longer lists the collection.
    function test_withNoFoundingFleetMissingTheStepInPhaseTwoPreparesNothingWhateverTheSubscription() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        _found(manifest, deployed);
        _openPhase(manifest, deployed);
        _openPhase(manifest, deployed);
        assertEq(collection.phase(), 2);
        _unready(collection);
        assertEq(safeSteps.foundingFleetCalls(manifest, deployed).length, 0, "Nothing to prepare");
    }

    /// @dev The same on Base, with the subscription another account's.
    function test_onBaseWithNoFoundingFleetMissingTheStepInPhaseTwoPreparesNothingWhateverTheSubscription() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        _found(manifest, base);
        _openPhase(manifest, base);
        _openPhase(manifest, base);
        assertEq(base.KEYS().phase(), 2);
        _unready(base.KEYS());
        assertEq(safeSteps.foundingFleetCalls(manifest, base).length, 0, "Nothing to prepare");
    }

    /// @dev Off Base the founding step in phase 2, which founds Syndicate, Accelerant and Cascade,
    /// is refused while the subscription does not list the collection, since phase 3 cannot open
    /// without them, and prepared once it does, whoever owns it. The Regents Club and Classic are
    /// prepared before, with nothing for the signers to read.
    function test_theFoundingStepForFleetsTwoToFourWaitsUntilTheSubscriptionListsTheCollection() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetFactory unlisted = deployScript.deploy(manifest);
        KeyfleetKeys keys = unlisted.KEYS();
        MockVRFCoordinatorV2Plus(address(manifest.bindings.randomness.coordinator))
            .openSubscription(manifest.bindings.randomness.subscriptionId, keeper);
        _foundClubAndClassicByTheStep(manifest, unlisted);

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.CollectionNotVrfConsumer.selector, address(keys)));
        safeSteps.foundingFleetCalls(manifest, unlisted);

        _listConsumer(manifest, keys);
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, unlisted);
        _assertFoundingReads(manifest, unlisted, calls, false);
        _make(calls, manifest.bindings.safe);
        _openPhase(manifest, unlisted);
        assertEq(keys.phase(), 3, "Phase 3 opens with every founding fleet");
    }

    /// @dev On Base the founding step in phase 2 is refused while anyone but the Regents Safe owns
    /// the subscription, even one that lists the collection, and prepared once the Safe owns it.
    /// The Regents Club and Classic are prepared whoever owns it.
    function test_onBaseTheFoundingStepForFleetsTwoToFourWaitsUntilTheRegentsSafeOwnsTheSubscription() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(safeSteps.BASE_VRF_COORDINATOR());
        coordinator.openSubscription(subscriptionId, keeper);
        _foundClubAndClassicByTheStep(manifest, base);

        vm.expectRevert(abi.encodeWithSelector(RecordKeyfleets.VrfSubscriptionNotOwnedByRegentsSafe.selector, keeper));
        safeSteps.foundingFleetCalls(manifest, base);

        coordinator.openSubscription(subscriptionId, safeSteps.BASE_REGENTS_SAFE());
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, base);
        _assertFoundingReads(manifest, base, calls, true);
        _make(calls, manifest.bindings.safe);
        _openPhase(manifest, base);
        assertEq(base.KEYS().phase(), 3, "Phase 3 opens with every founding fleet");
    }

    /// @dev Founds the Regents Club in phase 0 and Classic in phase 1 by the step, each call asking
    /// the signers to read nothing, and opens phases 1 and 2 by the step.
    function _foundClubAndClassicByTheStep(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory factory) private {
        uint256[2] memory fleets = [uint256(5), 1];
        for (uint256 index = 0; index < fleets.length; ++index) {
            KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, factory);
            assertEq(calls.length, 1, "One founding fleet");
            assertEq(
                calls[0].name, string.concat("founding-fleet-", vm.toString(fleets[index])), "The Club, then Classic"
            );
            assertEq(calls[0].description, "", "Nothing to read");
            _make(calls, manifest.bindings.safe);
            _openPhase(manifest, factory);
        }
    }

    /// @dev `calls`, the founding step in phase 2, creates fleets 2, 3 and 4 in order, and each
    /// call's description names the collection and phase 2, then exactly what the phase-3 call's
    /// asks the signers to read of the subscription, its owner included when `namesOwner`. Each
    /// value it names is the real one: the fleet, the factory it calls, the chain, the collection,
    /// the subscription and its coordinator, and on Base the Regents Safe.
    function _assertFoundingReads(
        KeyfleetManifest.Manifest memory manifest,
        KeyfleetFactory factory,
        KeyfleetSafeSteps.SafeCall[] memory calls,
        bool namesOwner
    ) private view {
        string memory phaseThree =
            safeSteps.advancePhaseCalls(manifest, factory, uint64(block.timestamp + 1))[0].description;
        string memory collectionInPhaseTwo =
            string.concat(" that the collection ", vm.toString(address(factory.KEYS())), " is in phase 2");
        assertEq(calls.length, 3, "Syndicate, Accelerant and Cascade");
        for (uint256 index = 0; index < calls.length; ++index) {
            string memory description = calls[index].description;
            assertEq(calls[index].name, string.concat("founding-fleet-", vm.toString(index + 2)), "In order");
            assertTrue(_names(description, collectionInPhaseTwo), "The collection, in phase 2");
            assertEq(
                vm.split(description, " is in phase 2")[1],
                vm.split(phaseThree, " is in phase 2")[1],
                "The subscription, read as for phase 3"
            );
            assertEq(_names(description, "Regents Safe"), namesOwner, "Its owner, on Base");
            assertEq(vm.parseUint(_named(description, "Creates founding fleet ")), index + 2, "The fleet it creates");
            assertEq(calls[index].to, address(factory), "Called on the factory");
            assertEq(vm.parseAddress(_named(description, " through the factory ")), address(factory), "The factory");
            assertEq(vm.parseUint(_named(description, " on chain ")), block.chainid, "The chain to read");
            assertEq(
                vm.parseAddress(_named(description, " the collection ")), address(factory.KEYS()), "The collection"
            );
            _assertSubscriptionNamed(description, factory.KEYS(), namesOwner);
        }
    }

    /// @dev That `description` names `keys`'s randomness subscription and its coordinator as the
    /// collection names them, and, when `namesOwner`, the Regents Safe as the owner to read.
    function _assertSubscriptionNamed(string memory description, KeyfleetKeys keys, bool namesOwner) private view {
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId,) = keys.randomness();
        assertEq(vm.parseUint(_named(description, "randomness subscription ")), subscriptionId, "The subscription");
        assertEq(vm.parseAddress(_named(description, " on the coordinator ")), address(coordinator), "Its coordinator");
        if (namesOwner) {
            assertEq(
                vm.parseAddress(_named(description, "that the Regents Safe ")),
                safeSteps.BASE_REGENTS_SAFE(),
                "The owner to read"
            );
        }
    }

    /// @dev The value `text` names right after the first `marker`, without the comma or full stop
    /// that follows it.
    function _named(string memory text, string memory marker) private pure returns (string memory value) {
        string[] memory parts = vm.split(text, marker);
        require(parts.length > 1, string.concat("Nothing named after: ", marker));
        value = vm.split(parts[1], " ")[0];
        value = vm.replace(vm.replace(value, ",", ""), ".", "");
    }

    /// @dev Both steps check the manifest first.
    function test_stepsRefuseAManifestForAnotherChain() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        manifest.chainId = 1;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, 1, block.chainid));
        safeSteps.foundingFleetCalls(manifest, deployed);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, 1, block.chainid));
        safeSteps.advancePhaseCalls(manifest, deployed, uint64(block.timestamp + 1));
    }

    /// @dev Each call becomes a Safe Transaction Builder file of one transaction for the Safe on
    /// this chain, carrying the call exactly.
    function test_eachCallIsWrittenAsATransactionBuilderFile() public view {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetSafeSteps.SafeCall memory call = safeSteps.foundingFleetCalls(manifest, deployed)[0];

        string memory file = safeSteps.safeBatch(safe, call);

        assertEq(vm.parseJsonString(file, ".version"), "1.0", "Version");
        assertEq(vm.parseJsonString(file, ".chainId"), vm.toString(block.chainid), "Chain, as a string");
        assertGt(vm.parseJsonUint(file, ".createdAt"), 0, "Created at");
        assertEq(vm.parseJsonString(file, ".meta.name"), "Keyfleet founding-fleet-5", "Name");
        assertEq(vm.parseJsonAddress(file, ".meta.createdFromSafeAddress"), safe, "The Safe");
        assertFalse(vm.keyExistsJson(file, ".transactions[1]"), "One transaction");
        assertEq(vm.parseJsonAddress(file, ".transactions[0].to"), call.to, "To");
        assertEq(vm.parseJsonString(file, ".transactions[0].value"), "0", "No value");
        assertEq(vm.parseJsonBytes(file, ".transactions[0].data"), call.data, "The call");
    }

    /// @dev Off Base each phase's batch names no owner of the subscription, since the step checks
    /// none there, even for the calls to phases 3 and 4.
    function test_eachPhaseBatchSaysWhatTheSignersReadFirst() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        _found(manifest, deployed);
        _assertPhaseBatches(manifest, deployed, false);
    }

    /// @dev On Base the calls to phases 3 and 4 also name the Regents Safe as the subscription's
    /// owner, as the step checks there.
    function test_onBaseEachPhaseBatchAlsoNamesTheSafeAsTheSubscriptionsOwner() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        _found(manifest, base);
        _assertPhaseBatches(manifest, base, true);
    }

    /// @dev Moves `factory`'s collection through every phase by the step, checking each batch as the
    /// step writes it: its phase's name and its own description, which names the collection and the
    /// opening time, says what the file does once the collection has left the phase it was written
    /// in (checked by landing it so), and only for the calls to phases 3 and 4 names the
    /// subscription the signers read first, by its id and its coordinator, the balance it must
    /// hold, and the Safe as its owner when `namesOwner`. Each value it names is the real one: the
    /// collection, the phase, the opening, the chain, the phase to read and, for phases 3 and 4,
    /// the subscription, its coordinator and on Base the Regents Safe.
    function _assertPhaseBatches(KeyfleetManifest.Manifest memory manifest, KeyfleetFactory factory, bool namesOwner)
        private
    {
        KeyfleetKeys keys = factory.KEYS();
        address signers = manifest.bindings.safe;
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId,) = keys.randomness();
        for (uint256 phase = 1; phase <= keys.FINAL_PHASE(); ++phase) {
            uint64 opensAt = uint64(block.timestamp + 1);
            KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.advancePhaseCalls(manifest, factory, opensAt);
            string memory file = safeSteps.safeBatch(signers, calls[0]);

            assertEq(vm.parseJsonString(file, ".meta.name"), string.concat("Keyfleet ", calls[0].name), "Name");
            assertEq(calls[0].name, string.concat("phase-", vm.toString(phase)), "Its phase");
            string memory description = vm.parseJsonString(file, ".meta.description");
            assertEq(description, calls[0].description, "The call's own description");
            assertEq(vm.parseAddress(_named(description, "Moves the collection ")), address(keys), "The collection");
            assertEq(vm.parseUint(_named(description, " to phase ")), phase, "The phase it names");
            assertEq(vm.parseUint(_named(description, "opening at Unix time ")), opensAt, "The opening");
            assertEq(vm.parseUint(_named(description, " on chain ")), manifest.chainId, "The chain to read");
            assertEq(
                vm.parseUint(_named(description, "that the collection is in phase ")), phase - 1, "The phase to read"
            );
            bool reads = phase >= safeSteps.FIRST_DRAWING_PHASE();
            if (reads) _assertSubscriptionNamed(description, keys, namesOwner);
            _assertLandedAfterAnother(calls, description, keys, signers, phase);
            assertEq(
                _names(description, string.concat("subscription ", vm.toString(subscriptionId))),
                reads,
                "The subscription, before phases 3 and 4"
            );
            assertEq(_names(description, vm.toString(address(coordinator))), reads, "Its coordinator");
            assertEq(
                _names(
                    description,
                    string.concat(
                        "its native ETH balance, the second value getSubscription returns (the first is its LINK balance), is at least ",
                        vm.toString(safeSteps.SUBSCRIPTION_FUNDING()),
                        " wei."
                    )
                ),
                reads,
                "Its balance, before phases 3 and 4"
            );
            assertEq(_names(description, vm.toString(signers)), reads && namesOwner, "Its owner, where checked");

            _make(calls, signers);
            vm.warp(opensAt);
        }
    }

    /// @dev `calls`, a file for phase `phase`, landed and then landed again and again with the
    /// subscription no longer listing the collection or owned by the Regents Safe, each landing as
    /// `description` says: before its opening, from each phase it lands in up to phase 3, it moves
    /// the collection on one more phase, to the one it names, and in phase 4 it is refused. The
    /// chain is then put back as it was.
    function _assertLandedAfterAnother(
        KeyfleetSafeSteps.SafeCall[] memory calls,
        string memory description,
        KeyfleetKeys keys,
        address signers,
        uint256 phase
    ) private {
        uint256 before = vm.snapshotState();
        _make(calls, signers);
        _unready(keys);

        for (uint256 landed = phase; landed < keys.FINAL_PHASE(); ++landed) {
            assertTrue(
                _names(
                    description,
                    string.concat("in phase ", vm.toString(landed), ", to phase ", vm.toString(landed + 1), ", ")
                ),
                "Names the phase each later landing opens"
            );
            _make(calls, signers);
            assertEq(keys.phase(), landed + 1, "One more phase, as it says");
        }
        assertTrue(
            _names(description, string.concat("in phase ", vm.toString(keys.FINAL_PHASE()), " it is refused.")),
            "Says it is refused in phase 4"
        );
        vm.expectRevert(KeyfleetKeys.NoNextPhase.selector);
        this.make(calls, signers);
        vm.revertToState(before);
    }

    /// @dev Whether `text` holds `value`.
    function _names(string memory text, string memory value) private pure returns (bool) {
        return vm.indexOf(text, value) != type(uint256).max;
    }

    /// @dev The gift step gives every Regents Club key, `CLUB_GIFT_BATCH` to a call: key N to the
    /// holder of Pass N when the step runs, or to the claims contract when that holder is a contract
    /// that a safe transfer would refuse, when Pass N has no holder, or when the Safe's signers name
    /// key N. Run again partway, it names only the keys still to give, and once all are given it
    /// names none.
    function test_clubGiftStepGivesEveryKeyToItsPassOrTheClaimsContract() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        _found(manifest, deployed);
        _openPhase(manifest, deployed);
        _openPhase(manifest, deployed);
        MockClubPass pass = MockClubPass(address(manifest.bindings.clubPass));
        address claims = address(deployed.CLUB_CLAIMS());
        address wallet = address(new MockContractWallet(keeper));
        address[4] memory contracts = [address(new NoReceiver()), address(new Silent()), wallet, wallet];
        for (uint256 n = 1; n <= KeyfleetPresets.CLUB_SUPPLY; ++n) {
            if (n != 6) pass.mint(n >= 2 && n <= 5 ? contracts[n - 2] : _wallet(n), n);
        }
        uint256[] memory toClaims = new uint256[](1);
        toClaims[0] = 7;

        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.clubGiftCalls(manifest, deployed, toClaims);
        assertEq(safeSteps.CLUB_GIFT_BATCH(), 80);
        assertEq(calls.length, 25, "1,998 keys, 80 a call");
        KeyfleetManager club = _managerOf(deployed, 5);
        address[] memory first = new address[](80);
        for (uint256 n = 1; n <= 80; ++n) {
            first[n - 1] = n == 2 || n == 3 || n == 6 || n == 7 ? claims : pass.ownerOf(n);
        }
        assertEq(calls[0].name, "club-gifts-1-80");
        assertEq(calls[0].to, address(club), "To the Club");
        assertEq(calls[0].data, abi.encodeCall(KeyfleetManager.give, (first)), "Each key to its Pass, or held");
        assertEq(calls[24].name, "club-gifts-1921-1998", "The last call stops at the last key");

        KeyfleetSafeSteps.SafeCall[] memory firstTwo = new KeyfleetSafeSteps.SafeCall[](2);
        (firstTwo[0], firstTwo[1]) = (calls[0], calls[1]);
        _make(firstTwo, safe);
        calls = safeSteps.clubGiftCalls(manifest, deployed, new uint256[](0));
        assertEq(calls.length, 23, "Only the keys still to give");
        assertEq(calls[0].name, "club-gifts-161-240");
        _make(calls, safe);

        assertEq(club.totalMinted(), KeyfleetPresets.CLUB_SUPPLY, "Every key given");
        assertEq(collection.ownerOf(collection.tokenIdOf(5, 2)), claims, "Held for a contract without a receiver");
        assertEq(collection.ownerOf(collection.tokenIdOf(5, 3)), claims, "Held for a contract that answers nothing");
        assertEq(collection.ownerOf(collection.tokenIdOf(5, 4)), wallet, "A contract wallet takes its own");
        assertEq(collection.ownerOf(collection.tokenIdOf(5, 6)), claims, "Held for a Pass nobody holds");
        assertEq(collection.ownerOf(collection.tokenIdOf(5, 7)), claims, "Held as the signers named");
        assertEq(collection.ownerOf(collection.tokenIdOf(5, 1998)), _wallet(1998));
        assertEq(safeSteps.clubGiftCalls(manifest, deployed, new uint256[](0)).length, 0, "Nothing left");
    }

    /// @dev Makes `calls` from `from` in a call of its own, so a test can expect its revert.
    function make(KeyfleetSafeSteps.SafeCall[] memory calls, address from) external {
        _make(calls, from);
    }
}
