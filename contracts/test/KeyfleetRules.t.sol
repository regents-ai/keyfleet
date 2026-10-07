// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresence} from "../src/KeyfleetPresence.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev The fleet rules Sean set on 7 October 2026, each pinned on its own: the 60% approval of
/// the present keys, rounded up, decided at closing; a key's 2-day wait from its mint; its
/// automatic presence from day 2 to day 4; the 7-day opening in which no proposal may move money;
/// and the Accelerant step a creator chooses.
contract KeyfleetRulesTest is KeyfleetFixture {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    address private constant OPERATOR = address(0x0E0E);

    KeyfleetManager private classic;
    KeyfleetVotes private votes;
    KeyfleetTreasury private treasury;

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = classic.VOTES();
        treasury = classic.TREASURY();
    }

    // --- helpers ---------------------------------------------------------

    function _pay(uint256 amount) private view returns (KeyfleetTreasury.Call[] memory) {
        return _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (address(usdc), OPERATOR, amount)));
    }

    function _propose(uint256 tokenId, KeyfleetTreasury.Call[] memory calls) private returns (uint256) {
        vm.prank(keys.ownerOf(tokenId));
        return votes.propose(tokenId, keccak256("narrative"), uint64(block.timestamp + 1 days), calls);
    }

    function _vote(uint256 proposalId, uint256 tokenId, KeyfleetVotes.Choice choice) private {
        vm.prank(keys.ownerOf(tokenId));
        votes.castBallot(proposalId, _ids(tokenId), choice);
    }

    function _present(uint256 tokenId) private {
        vm.prank(keys.ownerOf(tokenId));
        votes.present(_ids(tokenId));
    }

    /// @dev Moves past the fleet's opening and past every key's automatic presence, so no key is
    /// present until it is renewed.
    function _pastOpening() private {
        vm.warp(votes.treasuryOpensAt());
        votes.sweepExpired(type(uint256).max);
    }

    function _wasCleared(Vm.Log[] memory logs) private pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == KeyfleetVotes.PresenceCleared.selector) return true;
        }
        return false;
    }

    // --- 1. approval: 60% of the present keys, rounded up ----------------

    function test_approvalsNeededForOneToTenVoters() public view {
        uint256[10] memory expected = [uint256(1), 2, 2, 3, 3, 4, 5, 5, 6, 6];
        for (uint256 voters = 1; voters <= 10; ++voters) {
            assertEq(votes.approvalsNeeded(voters), expected[voters - 1], "Sean's table");
            assertEq(votes.approvalsNeeded(voters), (voters * 3 + 4) / 5, "integer 60%, rounded up");
        }
    }

    function testFuzz_approvalsNeededIsSixtyPercentRoundedUp(uint32 voters) public view {
        uint256 needed = votes.approvalsNeeded(voters);
        assertEq(needed, (uint256(voters) * 3 + 4) / 5, "integer 60%, rounded up");
        assertGe(needed * 100, uint256(voters) * 60, "enough");
        if (needed > 0) assertLt((needed - 1) * 100, uint256(voters) * 60, "and not one more");
    }

    function test_oneVoterAloneApprovesAPayment() public {
        uint256 first = _buy(classic, ALICE);
        _buy(classic, BOB);
        _pastOpening();
        usdc.mint(address(treasury), 5e6);

        // Alice's key is not present; she presses Present, proposes, votes, and passes 1/1.
        assertFalse(votes.isActive(first), "inactive before pressing Present");
        _present(first);
        uint256 proposalId = _propose(first, _pay(5e6));
        assertEq(votes.proposal(proposalId).e0, 1, "one present voter");
        _vote(proposalId, first, KeyfleetVotes.Choice.Yes);
        assertEq(uint8(votes.status(proposalId)), uint8(KeyfleetVotes.Status.Open), "decided only at closing");

        vm.warp(votes.proposal(proposalId).closesAt);
        assertEq(uint8(votes.status(proposalId)), uint8(KeyfleetVotes.Status.Approved), "1/1");
        votes.execute(proposalId, _pay(5e6));
        assertEq(usdc.balanceOf(OPERATOR), 5e6, "paid");
    }

    function test_twoVotersNeedTwoYes() public {
        uint256 first = _buy(classic, ALICE);
        uint256 second = _buy(classic, BOB);
        _pastOpening();
        _present(second);
        uint256 one = _propose(first, _pay(1e6));
        assertEq(votes.proposal(one).e0, 2, "two present voters");
        _vote(one, first, KeyfleetVotes.Choice.Yes);
        uint256 both = _propose(first, _pay(1e6));
        _vote(both, first, KeyfleetVotes.Choice.Yes);
        _vote(both, second, KeyfleetVotes.Choice.Yes);

        vm.warp(votes.proposal(both).closesAt);
        assertEq(uint8(votes.status(one)), uint8(KeyfleetVotes.Status.Rejected), "1/2 fails");
        assertEq(uint8(votes.status(both)), uint8(KeyfleetVotes.Status.Approved), "2/2 passes");
    }

    function test_fiveVotersNeedThreeYes() public {
        _buyMany(classic, 5);
        _pastOpening();
        for (uint256 k = 2; k <= 5; ++k) {
            _present(_key(classic, k));
        }
        uint256 two = _propose(_key(classic, 1), _pay(1e6));
        uint256 three = _propose(_key(classic, 1), _pay(1e6));
        assertEq(votes.proposal(two).e0, 5, "five present voters");
        for (uint256 k = 1; k <= 2; ++k) {
            _vote(two, _key(classic, k), KeyfleetVotes.Choice.Yes);
        }
        for (uint256 k = 1; k <= 3; ++k) {
            _vote(three, _key(classic, k), KeyfleetVotes.Choice.Yes);
        }
        vm.warp(votes.proposal(three).closesAt);
        assertEq(uint8(votes.status(two)), uint8(KeyfleetVotes.Status.Rejected), "2/5 fails");
        assertEq(uint8(votes.status(three)), uint8(KeyfleetVotes.Status.Approved), "3/5 passes");
    }

    function test_aBallotMayChangeUntilClosingAndTheOutcomeIsDecidedThen() public {
        uint256 first = _buy(classic, ALICE);
        _pastOpening();
        uint256 proposalId = _propose(first, _pay(1e6));
        _vote(proposalId, first, KeyfleetVotes.Choice.Yes);
        uint64 closesAt = votes.proposal(proposalId).closesAt;

        vm.warp(closesAt - 1);
        _vote(proposalId, first, KeyfleetVotes.Choice.No);
        assertEq(votes.proposal(proposalId).yes, 0, "the change moved the key's one ballot");
        assertEq(votes.proposal(proposalId).no, 1, "to No");

        vm.warp(closesAt);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.BallotsClosed.selector, proposalId));
        votes.castBallot(proposalId, _ids(first), KeyfleetVotes.Choice.Yes);
        assertEq(uint8(votes.status(proposalId)), uint8(KeyfleetVotes.Status.Rejected), "No at closing");
    }

    function test_anApprovedProposalMayBeCarriedOutForFortyEightHoursFromClosing() public {
        uint256 first = _buy(classic, ALICE);
        _pastOpening();
        usdc.mint(address(treasury), 1e6);
        uint256 proposalId = _propose(first, _pay(1e6));
        _vote(proposalId, first, KeyfleetVotes.Choice.Yes);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.executionExpiry, stored.closesAt + 48 hours, "48 hours from closing");

        vm.warp(stored.closesAt - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(proposalId, _pay(1e6));

        vm.warp(stored.executionExpiry);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.ExecutionExpired)
        );
        votes.execute(proposalId, _pay(1e6));

        vm.warp(stored.executionExpiry - 1);
        votes.execute(proposalId, _pay(1e6));
        assertEq(usdc.balanceOf(OPERATOR), 1e6, "carried out in its last second");
    }

    // --- 2. the 2-day wait from mint -------------------------------------

    function test_aKeyWaitsTwoDaysFromItsMint() public {
        uint256 first = _buy(classic, ALICE);
        uint64 maturesAt = uint64(block.timestamp) + 2 days;
        assertEq(votes.KEY_MATURITY(), 2 days, "two days");
        assertEq(votes.maturesAt(first), maturesAt, "from its mint");

        vm.warp(maturesAt - 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyTooNew.selector, first, maturesAt));
        votes.present(_ids(first));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyTooNew.selector, first, maturesAt));
        votes.propose(first, bytes32(0), uint64(block.timestamp + 1 hours), new KeyfleetTreasury.Call[](0));

        vm.warp(maturesAt);
        _present(first);
        assertTrue(votes.isActive(first), "it takes part from its second day");
    }

    function test_aTransferDoesNotRestartTheWait() public {
        uint256 first = _buy(classic, ALICE);
        uint64 maturesAt = uint64(block.timestamp) + 2 days;
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        keys.transferFrom(ALICE, BOB, first);
        assertEq(votes.maturesAt(first), maturesAt, "still two days from the mint");

        vm.warp(maturesAt);
        _present(first);
        assertTrue(votes.isActive(first), "the new holder takes part on the mint's second day");
    }

    function test_aKeyInItsWaitCannotVoteOnAnOpenProposal() public {
        uint256 first = _buy(classic, ALICE);
        _pastOpening();
        uint256 proposalId = _propose(first, new KeyfleetTreasury.Call[](0));
        uint256 fresh = _buy(classic, BOB);
        uint64 maturesAt = uint64(block.timestamp) + 2 days;
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyTooNew.selector, fresh, maturesAt));
        votes.castBallot(proposalId, _ids(fresh), KeyfleetVotes.Choice.Yes);
    }

    // --- 3. automatic presence from day 2 to day 4 -----------------------

    function test_aNewKeyIsPresentOnItsOwnFromDayTwoToDayFour() public {
        uint256 first = _buy(classic, ALICE);
        uint64 startsAt = uint64(block.timestamp) + 2 days;
        assertEq(votes.presentFrom(first), startsAt, "scheduled at its sale");

        vm.warp(startsAt - 1);
        assertFalse(votes.isActive(first), "not present during its wait");
        vm.warp(startsAt);
        assertTrue(votes.isActive(first), "present from day 2 without pressing");
        vm.warp(startsAt + 2 days - 1);
        assertTrue(votes.isActive(first), "until the end of day 4");
        vm.warp(startsAt + 2 days);
        assertFalse(votes.isActive(first), "then only by pressing Present");
        _present(first);
        assertTrue(votes.isActive(first), "present again once renewed");
    }

    function test_anOpeningCountsTheKeysPresentOnTheirOwn() public {
        _buyMany(classic, 3);
        _mature();
        uint256 proposalId = _propose(_key(classic, 1), new KeyfleetTreasury.Call[](0));
        assertEq(votes.proposal(proposalId).e0, 3, "all three present without pressing");
        for (uint256 k = 1; k <= 3; ++k) {
            assertTrue(votes.wasActiveAtOpening(proposalId, _key(classic, k)), "counted at opening");
        }
    }

    function test_aKeyWhoseStartFallsInAnOpenProposalJoinsLate() public {
        uint256 first = _buy(classic, ALICE);
        vm.warp(block.timestamp + 1 hours);
        uint256 second = _buy(classic, BOB);
        vm.warp(votes.maturesAt(first));
        uint256 proposalId = _propose(first, new KeyfleetTreasury.Call[](0));
        assertEq(votes.proposal(proposalId).e0, 1, "the second key still waits");

        vm.warp(votes.presentFrom(second));
        assertTrue(votes.isActive(second), "present from its start");
        _vote(proposalId, second, KeyfleetVotes.Choice.Yes);
        assertEq(votes.proposal(proposalId).late, 1, "and joins late with its first ballot");
    }

    function test_aMoveBeforeTheStartKeepsItAndAMoveAfterEndsIt() public {
        uint256 first = _buy(classic, ALICE);
        uint256 second = _buy(classic, ALICE);
        uint64 startsAt = uint64(block.timestamp) + 2 days;

        vm.recordLogs();
        vm.prank(ALICE);
        keys.transferFrom(ALICE, BOB, first);
        assertFalse(_wasCleared(vm.getRecordedLogs()), "nothing to clear during the wait");
        assertEq(votes.presentFrom(first), startsAt, "the start stays");
        vm.warp(startsAt);
        assertTrue(votes.isActive(first), "the new holder's key is present from day 2");

        vm.recordLogs();
        vm.prank(ALICE);
        keys.transferFrom(ALICE, CAROL, second);
        assertTrue(_wasCleared(vm.getRecordedLogs()), "a move after the start ends the presence");
        assertFalse(votes.isActive(second), "not present after the move");
        assertEq(votes.presentFrom(second), 0, "and not until renewed");
    }

    function test_theSweepMovesStartedKeysAndDropsEndedOnes() public {
        _buyMany(classic, 3);
        (,, uint32 waiting) = votes.presenceList(KeyfleetPresence.Place.Waiting);
        assertEq(waiting, 3, "three waiting");

        vm.warp(block.timestamp + 2 days);
        (uint256 moved, bool due) = votes.sweepExpired(10);
        assertEq(moved, 3, "three started");
        assertFalse(due, "nothing left due");
        (,, uint32 automatic) = votes.presenceList(KeyfleetPresence.Place.Automatic);
        assertEq(automatic, 3, "three present on their own");

        vm.warp(block.timestamp + 2 days);
        (moved, due) = votes.sweepExpired(2);
        assertEq(moved, 2, "two ended");
        assertTrue(due, "one still due");
        (moved, due) = votes.sweepExpired(2);
        assertEq(moved, 1, "the last ended");
        assertFalse(due, "nothing due");
        (,, automatic) = votes.presenceList(KeyfleetPresence.Place.Automatic);
        assertEq(automatic, 0, "none left");
    }

    function test_aKeyThatStartedAndEndedBeforeAnySweepLeavesAtOnce() public {
        _buy(classic, ALICE);
        vm.warp(block.timestamp + 6 days);
        (uint256 moved, bool due) = votes.sweepExpired(10);
        assertEq(moved, 1, "one entry moved");
        assertFalse(due, "nothing due");
        (,, uint32 automatic) = votes.presenceList(KeyfleetPresence.Place.Automatic);
        assertEq(automatic, 0, "and it is not listed as present");
    }

    // --- 4. the 7-day opening --------------------------------------------

    function test_theOpeningCountsFromTheFoundingFleetsPhase() public view {
        // The fixture opened phase 1 and phase 2 at this same moment.
        assertEq(keys.salesOpenedAt(1), block.timestamp, "fleet 1 at phase 1");
        assertEq(keys.salesOpenedAt(4), block.timestamp, "fleets 2 to 4 at phase 2");
        assertEq(votes.treasuryOpensAt(), block.timestamp + 7 days, "seven days after its sales opened");
    }

    function test_aFoundingFleetHasNoOpeningBeforeItsPhase() public {
        // A new collection: the founding fleets exist, but phase 2 has not opened fleets 2 to 4.
        _setUpFixture();
        for (uint256 id = 1; id <= keys.FOUNDING_FLEETS(); ++id) {
            _createFounding(keys.foundingPreset(id));
        }
        vm.prank(safe);
        keys.advancePhase();
        uint256 phaseOne = block.timestamp;
        vm.warp(block.timestamp + 1 days);
        assertEq(keys.salesOpenedAt(1), phaseOne, "fleet 1 opened at phase 1");
        assertEq(keys.salesOpenedAt(2), 0, "fleet 2 not yet");
        assertFalse(keys.salesOpen(2), "so it does not sell");
        assertEq(KeyfleetManager(keys.managerOf(2)).VOTES().treasuryOpensAt(), 0, "and has no opening yet");
        vm.prank(safe);
        keys.advancePhase();
        assertEq(keys.salesOpenedAt(2), block.timestamp, "fleet 2 opens at phase 2");
        assertEq(keys.salesOpenedAt(1), phaseOne, "fleet 1 keeps its time");
    }

    function test_anOpenFleetsOpeningCountsFromItsCreation() public {
        KeyfleetManager open = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        assertEq(keys.salesOpenedAt(open.FLEET_ID()), block.timestamp, "sells from its creation");
        assertEq(open.VOTES().treasuryOpensAt(), block.timestamp + 7 days, "seven days after");
    }

    function test_noProposalMovesMoneyDuringTheOpening() public {
        uint256 first = _buy(classic, ALICE);
        _mature();
        uint64 opensAt = votes.treasuryOpensAt();
        KeyfleetTreasury.Call[][6] memory held = [
            _pay(1e6),
            _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.runVotedSplit, ())),
            _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.approveSignatureHash, (bytes32(uint256(1))))),
            _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.admitOusd, (usdc))),
            _one(address(treasury), 1, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (100))),
            _one(address(classic), 0, hex"")
        ];
        for (uint256 i = 0; i < held.length; ++i) {
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.TreasuryOpening.selector, opensAt));
            votes.propose(first, bytes32(i), uint64(block.timestamp + 1 hours), held[i]);
        }

        vm.warp(opensAt - 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.TreasuryOpening.selector, opensAt));
        votes.propose(first, bytes32(0), uint64(block.timestamp + 1 hours), _pay(1e6));

        vm.warp(opensAt);
        _present(first);
        _propose(first, _pay(1e6));
    }

    function test_aCallMovingMoneyIsRefusedEvenBesideAnAllowedOne() public {
        uint256 first = _buy(classic, ALICE);
        _mature();
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = KeyfleetTreasury.Call(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (100)));
        calls[1] = _pay(1e6)[0];
        uint64 opensAt = votes.treasuryOpensAt();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.TreasuryOpening.selector, opensAt));
        votes.propose(first, bytes32(0), uint64(block.timestamp + 1 hours), calls);
    }

    function test_theOpeningAllowsDecisionsProfileSplitRateAndEdits() public {
        uint256 first = _buy(classic, ALICE);
        _mature();
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](3);
        calls[0] = KeyfleetTreasury.Call(
            address(classic), 0, abi.encodeCall(KeyfleetManager.setProfile, (_profile("Renamed")))
        );
        calls[1] = KeyfleetTreasury.Call(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (100)));
        calls[2] =
            KeyfleetTreasury.Call(address(votes), 0, abi.encodeCall(KeyfleetVotes.setEditsRestricted, (first, true)));
        _propose(first, new KeyfleetTreasury.Call[](0));
        uint256 proposalId = _propose(first, calls);
        _vote(proposalId, first, KeyfleetVotes.Choice.Yes);
        vm.warp(votes.proposal(proposalId).closesAt);
        votes.execute(proposalId, calls);
        assertEq(classic.profile().name, "Renamed", "renamed");
        assertEq(treasury.dailySplitBps(), 100, "rate set");
        assertTrue(votes.editsRestricted(first), "edits restricted");
    }

    function test_theDailySplitRunsDuringTheOpening() public {
        _buy(classic, ALICE);
        usdc.mint(address(treasury), 1_000e6);
        vm.warp(treasury.nextRunAt());
        assertLt(block.timestamp, votes.treasuryOpensAt(), "still in the opening");
        treasury.runDailySplit();
        assertLt(usdc.balanceOf(address(treasury)), 1_000e6, "the split paid out");
    }

    // --- 5. the Accelerant step ------------------------------------------

    function test_aCreatorChoosesAWholeStepFromOneToFivePercent() public {
        _openCreation();
        for (uint256 step = 1; step <= 5; ++step) {
            KeyfleetManager fleet = _createAccelerant(step);
            assertEq(fleet.ACCELERANT_STEP_PERCENT(), step, "the chosen step");
            uint256 price = fleet.nextPrice();
            assertEq(price, (10e6 * (100 + step) + 99) / 100, "key 2 is the step dearer, rounded up");
            _buy(fleet, BOB);
            assertEq(fleet.nextPrice(), (price * (100 + step) + 99) / 100, "and key 3 the step again");
        }
    }

    function test_theFoundingAccelerantStepsFivePercent() public view {
        KeyfleetManager accelerant = KeyfleetManager(keys.managerOf(3));
        assertEq(uint8(accelerant.PRESET()), uint8(KeyfleetPresets.Preset.FleetTechAccelerant), "fleet 3");
        assertEq(accelerant.ACCELERANT_STEP_PERCENT(), 5, "5%");
        assertEq(classic.ACCELERANT_STEP_PERCENT(), 0, "other types have none");
    }

    function test_aStepOutsideOneToFiveOrOnAnotherTypeIsRefused() public {
        _openCreation();
        uint256[2] memory badSteps = [uint256(0), 6];
        for (uint256 i = 0; i < badSteps.length; ++i) {
            KeyfleetFactory.FleetTerms memory terms =
                _terms(KeyfleetPresets.Preset.FleetTechAccelerant, 10e6, _anyone());
            terms.accelerantStepPercent = badSteps[i];
            vm.prank(creator);
            vm.expectRevert(
                abi.encodeWithSelector(
                    KeyfleetFactory.AccelerantStepInvalid.selector,
                    KeyfleetPresets.Preset.FleetTechAccelerant,
                    badSteps[i]
                )
            );
            factory.createFleet(terms);
        }
        KeyfleetFactory.FleetTerms memory classicTerms =
            _terms(KeyfleetPresets.Preset.FleetTechClassic, 10e6, _anyone());
        classicTerms.accelerantStepPercent = 1;
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                KeyfleetFactory.AccelerantStepInvalid.selector, KeyfleetPresets.Preset.FleetTechClassic, 1
            )
        );
        factory.createFleet(classicTerms);
    }

    function _anyone() private pure returns (KeyfleetManager.Requirements memory anyone) {}

    function _createAccelerant(uint256 step) private returns (KeyfleetManager fleet) {
        KeyfleetFactory.FleetTerms memory terms = _terms(KeyfleetPresets.Preset.FleetTechAccelerant, 10e6, _anyone());
        terms.accelerantStepPercent = step;
        usdc.mint(creator, 10e6);
        vm.startPrank(creator);
        usdc.approve(address(factory), 10e6);
        (uint256 id,) = factory.createFleet(terms);
        vm.stopPrank();
        fleet = KeyfleetManager(keys.managerOf(id));
    }
}
