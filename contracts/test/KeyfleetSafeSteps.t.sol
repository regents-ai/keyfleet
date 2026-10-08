// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetManifest} from "../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../script/KeyfleetSafeSteps.s.sol";
import {KeyfleetScriptFixture} from "./helpers/KeyfleetScriptFixture.sol";
import {MockClubPass} from "./mocks/MockClubPass.sol";
import {MockContractWallet} from "./mocks/MockContractWallet.sol";

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
        assertEq(calls.length, 5, "One call per founding fleet");
        for (uint256 index = 0; index < 5; ++index) {
            assertEq(calls[index].name, string.concat("founding-fleet-", vm.toString(index + 1)), "Named");
            assertEq(calls[index].to, address(deployed), "To the factory");
        }

        _make(calls, safe);

        assertEq(collection.fleetCount(), 5, "Five fleets");
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
            assertFalse(collection.salesOpen(fleetId), "Sales stay closed");
        }
        assertEq(collection.phase(), 0, "No phase moved");
    }

    /// @dev Run again partway, the step names only the founding fleets still missing, and once all
    /// five exist it names none.
    function test_foundingStepNamesOnlyTheFleetsStillMissing() public {
        KeyfleetManifest.Manifest memory manifest = _manifest();
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(manifest, deployed);
        KeyfleetSafeSteps.SafeCall[] memory firstTwo = new KeyfleetSafeSteps.SafeCall[](2);
        (firstTwo[0], firstTwo[1]) = (calls[0], calls[1]);
        _make(firstTwo, safe);

        calls = safeSteps.foundingFleetCalls(manifest, deployed);
        assertEq(calls.length, 3, "Three left");
        assertEq(calls[0].name, "founding-fleet-3", "Accelerant next");
        assertEq(calls[1].name, "founding-fleet-4", "Cascade then");
        assertEq(calls[2].name, "founding-fleet-5", "the Regents Club last");
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
