// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../script/KeyfleetSafeSteps.s.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";

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
        assertEq(calls.length, 4, "One call per founding fleet");
        for (uint256 index = 0; index < 4; ++index) {
            assertEq(calls[index].name, string.concat("founding-fleet-", vm.toString(index + 1)), "Named");
            assertEq(calls[index].to, address(deployed), "To the factory");
        }

        _make(calls, safe);

        assertEq(collection.fleetCount(), 4, "Four fleets");
        for (uint256 fleetId = 1; fleetId <= 4; ++fleetId) {
            KeyfleetManifest.FoundingFleet memory expected = manifest.founding[fleetId - 1];
            KeyfleetKeys.Fleet memory fleet = collection.fleet(fleetId);
            assertTrue(fleet.preset == expected.preset, "Type");
            assertEq(fleet.deckHash, expected.deckHash, "Deck");
            assertEq(fleet.deckSize, expected.deckSize, "Deck size");
            KeyfleetManager.Profile memory profile = _managerOf(deployed, fleetId).profile();
            assertEq(profile.name, expected.profile.name, "Name");
            assertEq(profile.description, expected.profile.description, "Description");
            assertEq(profile.imageLink, expected.profile.imageLink, "Image");
            assertFalse(collection.salesOpen(fleetId), "Sales stay closed");
        }
        assertEq(collection.phase(), 0, "No phase moved");
    }

    /// @dev Run again partway, the step names only the founding fleets still missing, and once all
    /// four exist it names none.
    function test_foundingStepNamesOnlyTheFleetsStillMissing() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, deployed);
        KeyfleetSafeSteps.SafeCall[] memory firstTwo = new KeyfleetSafeSteps.SafeCall[](2);
        (firstTwo[0], firstTwo[1]) = (calls[0], calls[1]);
        _make(firstTwo, safe);

        calls = safeSteps.foundingFleetCalls(manifest, deployed);
        assertEq(calls.length, 2, "Two left");
        assertEq(calls[0].name, "founding-fleet-3", "Accelerant next");
        assertEq(calls[1].name, "founding-fleet-4", "Cascade last");
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
        for (uint8 phase = 1; phase <= 3; ++phase) {
            calls = safeSteps.advancePhaseCalls(manifest, deployed, uint64(block.timestamp + 1));
            assertEq(calls[0].name, string.concat("phase-", vm.toString(phase)), "Next phase");
            _make(calls, safe);
            assertEq(collection.phase(), phase, "Moved");
            vm.warp(block.timestamp + 1);
        }
        assertTrue(collection.salesOpen(1) && collection.salesOpen(4), "Every founding fleet sells");

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
        assertEq(vm.parseJsonString(file, ".meta.name"), "Keyfleet founding-fleet-1", "Name");
        assertEq(vm.parseJsonAddress(file, ".meta.createdFromSafeAddress"), safe, "The Safe");
        assertFalse(vm.keyExistsJson(file, ".transactions[1]"), "One transaction");
        assertEq(vm.parseJsonAddress(file, ".transactions[0].to"), call.to, "To");
        assertEq(vm.parseJsonString(file, ".transactions[0].value"), "0", "No value");
        assertEq(vm.parseJsonBytes(file, ".transactions[0].data"), call.data, "The call");
    }

    /// @dev Makes `calls` from `from` in a call of its own, so a test can expect its revert.
    function make(KeyfleetSafeSteps.SafeCall[] memory calls, address from) external {
        _make(calls, from);
    }
}
