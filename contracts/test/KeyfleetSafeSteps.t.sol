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

    /// @dev The call to phase 2 checks nothing of the subscription and names no phase: on Base, with
    /// another account owning the subscription, a phase-2 file written in phase 1 and landed once
    /// phase 2 has opened opens phase 3, as its description warns.
    function test_aPhaseTwoFileLandedOncePhaseTwoHasOpenedOpensPhaseThreeAsItsDescriptionWarns() public {
        uint256 subscriptionId = _standInBase();
        KeyfleetManifest.Manifest memory manifest = _committedBaseManifest(subscriptionId);
        KeyfleetFactory base = _deployListed(manifest);
        KeyfleetKeys keys = base.KEYS();
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(safeSteps.BASE_VRF_COORDINATOR());
        coordinator.openSubscription(subscriptionId, keeper);
        _found(manifest, base);
        _openPhase(manifest, base);

        KeyfleetSafeSteps.SafeCall[] memory phaseTwo =
            safeSteps.advancePhaseCalls(manifest, base, uint64(block.timestamp + 1 days));
        assertTrue(
            _names(
                phaseTwo[0].description,
                " Landed once phase 2 has opened, it opens phase 3, with no check of the randomness subscription. Once phase 2 has opened, throw this file away."
            ),
            "Its description warns of it"
        );
        _openPhase(manifest, base);
        _make(phaseTwo, manifest.bindings.safe);
        assertEq(keys.phase(), 3, "The phase-2 file opened phase 3");
        assertEq(coordinator.subscriptionOwner(subscriptionId), keeper, "With the subscription not the Safe's");
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
    /// opening time and says to throw the file away once its phase has opened for every phase, warns
    /// only in the calls to phases 1 and 2 that landed once phase 2 has opened either opens phase 3
    /// with no check of the subscription, and only for the calls to phases 3 and 4 names the
    /// subscription the signers read first, by its id and its coordinator, the balance it must hold,
    /// and the Safe as its owner when `namesOwner`.
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
            assertTrue(_names(description, vm.toString(address(keys))), "The collection");
            assertTrue(_names(description, vm.toString(uint256(opensAt))), "The opening");
            bool reads = phase >= safeSteps.FIRST_DRAWING_PHASE();
            assertTrue(
                _names(
                    description, string.concat(" Once phase ", vm.toString(phase), " has opened, throw this file away.")
                ),
                "Thrown away once its phase has opened"
            );
            assertEq(
                _names(description, "it opens phase 3, with no check of the randomness subscription"),
                !reads,
                "The calls to phases 1 and 2 warn of phase 3"
            );
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
                        "its native ETH balance, the second value getSubscription returns, is at least ",
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
