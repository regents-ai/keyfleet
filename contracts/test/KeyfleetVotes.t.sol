// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresence} from "../src/KeyfleetPresence.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IKeyfleetFactory, KeyfleetWiring} from "../src/KeyfleetWiring.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev A call target that fails until told otherwise, for retrying a failed batch.
contract MockSwitch {
    error Failing();

    bool public failing = true;
    uint256 public pings;

    function setFailing(bool value) external {
        failing = value;
    }

    function ping() external {
        if (failing) revert Failing();
        ++pings;
    }
}

/// @dev Names the real factory and deploys a voting controller outside any creation, as a
/// deployer would, to show a controller only deploys inside the factory's own creation.
contract RogueVotesDeployer {
    IKeyfleetFactory public immutable FACTORY;

    constructor(IKeyfleetFactory factory) {
        FACTORY = factory;
    }

    function deployVotes() external returns (address) {
        return address(new KeyfleetVotes());
    }
}

contract KeyfleetVotesTest is KeyfleetFixture {
    /// @dev The published ceiling (contracts README) on an agent casting ten first ballots on
    /// Classic keys in one call through its shards. Measured 838,670 on a factory-made fleet.
    uint256 private constant TEN_KEY_BALLOT_CEILING = 1_250_000;
    /// @dev The published ceiling on one more key in an agent's ballot. Measured 83,338.
    uint256 private constant PER_KEY_BALLOT_CEILING = 125_000;
    /// @dev The starting price of the open fleets these tests create: 10 USDC.
    uint256 private constant OPEN_START = 10_000_000;

    KeyfleetVotes.Choice private constant YES = KeyfleetVotes.Choice.Yes;
    KeyfleetVotes.Choice private constant NO = KeyfleetVotes.Choice.No;
    KeyfleetVotes.Choice private constant ABSTAIN = KeyfleetVotes.Choice.Abstain;

    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private mallory = address(0x4A11);

    /// @dev The founding Classic fleet, fleet 1, and its voting controller.
    KeyfleetManager private fleet;
    KeyfleetVotes private votes;
    /// @dev The founding Classic fleet's token id for key number zero, so key `n` is this plus `n`
    /// without a call that a pending prank or expected revert would catch.
    uint256 private keyBase;

    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed authorKey,
        address indexed proposer,
        bytes32 proposalHash,
        bytes32 contentHash,
        uint64 closesAt,
        uint64 executableAt,
        uint64 executionExpiry,
        uint32 e0,
        uint48 openRevision,
        KeyfleetTreasury.Call[] calls
    );
    event BallotCast(
        uint256 indexed proposalId, address indexed voter, KeyfleetVotes.Choice choice, uint256[] tokenIds
    );
    event ProposalCancelled(uint256 indexed proposalId, address indexed by);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event EditsRestrictionSet(uint256 indexed tokenId, bool restricted);

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(1_000);
        _setUpFixture();
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();
        keyBase = keys.tokenIdOf(fleet.FLEET_ID(), 0);
    }

    // --- helpers ---------------------------------------------------------

    /// @dev The token id of key `keyNumber` of the founding Classic fleet.
    function _k(uint256 keyNumber) private view returns (uint256) {
        return keyBase + keyNumber;
    }

    function _noCalls() private pure returns (KeyfleetTreasury.Call[] memory) {
        return new KeyfleetTreasury.Call[](0);
    }

    /// @dev One call from the treasury restricting a key's edits.
    function _restrict(KeyfleetVotes v, uint256 tokenId, bool restricted)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(v), 0, abi.encodeCall(v.setEditsRestricted, (tokenId, restricted)));
    }

    /// @dev Renews keys as their current owners.
    function _present(KeyfleetVotes v, uint256[] memory tokenIds) private {
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            vm.prank(keys.ownerOf(tokenIds[i]));
            v.present(_ids(tokenIds[i]));
        }
    }

    /// @dev Opens a proposal with key `authorKey` as its owner; it closes a day from now.
    function _propose(KeyfleetVotes v, uint256 authorKey, KeyfleetTreasury.Call[] memory calls)
        private
        returns (uint256 proposalId)
    {
        vm.prank(keys.ownerOf(authorKey));
        proposalId = v.propose(authorKey, keccak256("narrative"), calls);
    }

    /// @dev Opens a proposal with the fleet's key 1 and no calls.
    function _propose(KeyfleetVotes v) private returns (uint256) {
        return _propose(v, _key(v.MANAGER(), 1), _noCalls());
    }

    /// @dev Casts one key's ballot as its current owner.
    function _ballot(KeyfleetVotes v, uint256 proposalId, uint256 tokenId, KeyfleetVotes.Choice choice) private {
        vm.prank(keys.ownerOf(tokenId));
        v.castBallot(proposalId, _ids(tokenId), choice);
    }

    function _ballots(KeyfleetVotes v, uint256 proposalId, uint256 first, uint256 count, KeyfleetVotes.Choice choice)
        private
    {
        for (uint256 i = 0; i < count; ++i) {
            _ballot(v, proposalId, first + i, choice);
        }
    }

    function _status(KeyfleetVotes v, uint256 proposalId) private view returns (KeyfleetVotes.Status) {
        return v.status(proposalId);
    }

    function _closeOf(KeyfleetVotes v, uint256 proposalId) private {
        vm.warp(v.proposal(proposalId).closesAt);
    }

    /// @dev Waits until a proposal may first be carried out: its closing, plus a day if it moves
    /// money.
    function _carryOutOf(KeyfleetVotes v, uint256 proposalId) private {
        vm.warp(v.executableAt(proposalId));
    }

    function _d(KeyfleetVotes v, uint256 proposalId) private view returns (uint256) {
        KeyfleetVotes.Proposal memory stored = v.proposal(proposalId);
        return uint256(stored.e0) + stored.late;
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet, its voting controller and its treasury are bound to each other, so
    /// no deployment step can leave a fleet taking orders from someone else's vote, and a
    /// controller deployed outside the factory's own creation does not deploy at all.
    function test_theFactoryDeploysAndBindsEachFleetsOwnVotingController() public {
        KeyfleetManager syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes bound = syndicate.VOTES();

        assertEq(address(bound.MANAGER()), address(syndicate), "the controller is bound to this fleet");
        assertEq(bound.FLEET_ID(), syndicate.FLEET_ID());
        assertEq(bound.FLEET_ID(), 2, "the founding Syndicate is fleet 2");
        assertEq(address(bound.KEYS()), address(keys), "the shared collection");
        assertEq(address(bound.SHARDS()), address(shards), "the shared shard record");
        assertEq(address(bound.TREASURY()), address(syndicate.TREASURY()));
        assertEq(address(syndicate.TREASURY().VOTES()), address(bound), "the treasury takes calls from it");
        assertEq(bound.proposalCount(), 0, "no proposal exists yet");
        assertTrue(address(bound) != address(votes), "each fleet has its own controller");

        RogueVotesDeployer rogue = new RogueVotesDeployer(factory);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetWiring.NotWired.selector, vm.computeCreateAddress(address(rogue), 1))
        );
        rogue.deployVotes();
    }

    // --- 2. proposals -----------------------------------------------------

    /// @dev Invariant: a proposal records its author key, content, exact calls, opening, closing and
    /// execution expiry, binds them in one hash, renews its author key and casts no ballot.
    function test_aProposalRecordsItsOpeningAndBindsItsWholeContent() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        uint256 k1 = _k(1);
        _present(votes, _ids(_k(2)));

        KeyfleetTreasury.Call[] memory calls = _restrict(votes, _k(3), true);
        bytes32 content = keccak256("restrict key 3");
        uint64 closesAt = uint64(block.timestamp + 24 hours);
        bytes32 actionsHash = keccak256(abi.encode(calls));
        bytes32 proposalHash = keccak256(
            abi.encode(
                block.chainid,
                address(votes),
                address(fleet.TREASURY()),
                uint256(1),
                k1,
                keys.ownershipEpoch(k1),
                content,
                actionsHash,
                closesAt,
                closesAt + 48 hours
            )
        );

        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(
            1, k1, _wallet(1), proposalHash, content, closesAt, closesAt, closesAt + 48 hours, 2, 6, calls
        );
        vm.prank(_wallet(1));
        uint256 proposalId = votes.propose(k1, content, calls);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(proposalId, 1, "proposal ids start at one");
        assertEq(stored.authorKey, k1);
        assertEq(stored.contentHash, content);
        assertEq(stored.actionsHash, actionsHash);
        assertEq(stored.proposalHash, proposalHash);
        assertEq(stored.openRevision, 6, "three sales, key 2's renewal, the author's renewal, then the opening");
        assertEq(stored.openedAt, uint64(block.timestamp));
        assertEq(stored.closesAt, closesAt, "24 hours after opening");
        assertEq(stored.executionExpiry, closesAt + 48 hours, "48 hours after closing");
        assertEq(stored.e0, 2, "key 2 and the author key were present");
        assertTrue(votes.isActive(k1), "the author key was renewed");
        assertEq(stored.yes + stored.no + stored.abstain + stored.late, 0, "proposing casts no ballot");
        assertEq(uint256(votes.ballotOf(proposalId, k1)), uint256(KeyfleetVotes.Choice.None));
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open));
    }

    /// @dev Invariant: every proposal is open for exactly 24 hours, takes ballots up to the last
    /// second before closing and none from closing on, and may be carried out for 48 hours after.
    function test_everyProposalIsOpenForExactlyTwentyFourHours() public {
        _buyMany(fleet, 1);
        _mature();
        uint256 k1 = _k(1);
        uint64 nowAt = uint64(block.timestamp);
        assertEq(votes.VOTING_PERIOD(), 24 hours);

        uint256 proposalId = _propose(votes, k1, _noCalls());
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.openedAt, nowAt);
        assertEq(stored.closesAt, nowAt + 24 hours);
        assertEq(votes.executableAt(proposalId), nowAt + 24 hours, "moving no money, it waits nothing more");
        assertEq(stored.executionExpiry, nowAt + 24 hours + 48 hours);

        vm.warp(nowAt + 24 hours - 1);
        _ballot(votes, proposalId, k1, KeyfleetVotes.Choice.Yes);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open));
        vm.warp(nowAt + 24 hours);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved));
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.BallotsClosed.selector, proposalId));
        votes.castBallot(proposalId, _ids(k1), KeyfleetVotes.Choice.No);
        vm.warp(nowAt + 72 hours - 1);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved));
        vm.warp(nowAt + 72 hours);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.ExecutionExpired));
    }

    /// @dev Invariant: proposing needs standing. The author key must be one the caller may vote:
    /// its owner, or a wallet holding an active shard of it while its agent voting is on.
    function test_proposingRequiresAKeyTheCallerMayVote() public {
        _buyMany(fleet, 2);
        _mature();
        uint256 k1 = _k(1);

        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _k(3)));
        votes.propose(_k(3), bytes32(0), _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, carol));
        votes.propose(k1, bytes32(0), _noCalls());
        vm.stopPrank();

        vm.prank(_wallet(1));
        shards.issue(_ids(k1), carol, 30);
        vm.expectEmit(true, true, true, false, address(votes));
        emit ProposalCreated(1, k1, carol, bytes32(0), bytes32(0), 0, 0, 0, 0, 0, _noCalls());
        vm.prank(carol);
        votes.propose(k1, bytes32(0), _noCalls());
    }

    /// @dev Invariant: an identical proposal made again is a new proposal, with its own id, hash
    /// and electorate; nothing deduplicates it and nothing is reserved.
    function test_anIdenticalResubmissionIsANewProposal() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        KeyfleetTreasury.Call[] memory calls = _restrict(votes, _k(2), true);
        uint256 first = _propose(votes, _k(1), calls);
        _present(votes, _ids(_k(2)));
        uint256 second = _propose(votes, _k(1), calls);

        KeyfleetVotes.Proposal memory a = votes.proposal(first);
        KeyfleetVotes.Proposal memory b = votes.proposal(second);
        assertEq(second, first + 1);
        assertEq(a.actionsHash, b.actionsHash, "the same calls");
        assertTrue(a.proposalHash != b.proposalHash, "but its own proposal");
        assertEq(a.e0, 1);
        assertEq(b.e0, 2, "and its own electorate");
    }

    /// @dev Invariant: every entry point refuses an id that names no proposal.
    function test_anUnknownProposalIsRefusedEverywhere() public {
        _buyMany(fleet, 1);
        _mature();
        _propose(votes);

        uint256[2] memory unknown = [uint256(0), 2];
        for (uint256 i = 0; i < unknown.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.status(unknown[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.proposal(unknown[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.wasActiveAtOpening(unknown[i], _k(1));
            vm.prank(_wallet(1));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.castBallot(unknown[i], _ids(_k(1)), YES);
            vm.prank(_wallet(1));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.cancel(unknown[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.execute(unknown[i], _noCalls());
        }
    }

    // --- 3. the growing electorate -------------------------------------------

    /// @dev Invariant: with one key present and its Yes, the proposal passes at its deadline, and
    /// not before: it is open until then and cannot be carried out early.
    function test_oneKeyPresentAndItsYesPassesAtTheDeadline() public {
        _buyMany(fleet, 5);
        _mature();
        _lapse();
        uint256 proposalId = _propose(votes);
        _ballot(votes, proposalId, _k(1), YES);

        assertEq(_d(votes, proposalId), 1, "D = 1");
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(proposalId, _noCalls());

        vm.warp(votes.proposal(proposalId).closesAt - 1);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open), "open to its last second");
        vm.warp(votes.proposal(proposalId).closesAt);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved));
    }

    /// @dev Invariant: Yes must reach 60% of D, rounded up. A tie fails, and so does Yes at exactly
    /// half with the rest abstaining.
    function test_tiesFail() public {
        _buyMany(fleet, 4);
        _mature();
        _lapse();
        _present(votes, _range(_k(2), 3));
        uint256 proposalId = _propose(votes);
        _ballots(votes, proposalId, _k(1), 2, YES);
        _ballots(votes, proposalId, _k(3), 2, ABSTAIN);

        uint256 tie = _propose(votes);
        _ballot(votes, tie, _k(1), YES);
        _ballot(votes, tie, _k(2), NO);

        _closeOf(votes, tie);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(_d(votes, proposalId), 4);
        assertEq(votes.approvalsNeeded(4), 3, "60% of four, rounded up");
        assertEq(stored.yes, 2);
        assertEq(stored.abstain, 2);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Rejected), "2 of 4 fails");
        assertEq(_d(votes, tie), 4, "the silent present keys count");
        assertEq(uint256(_status(votes, tie)), uint256(KeyfleetVotes.Status.Rejected), "1 to 1 fails");
    }

    /// @dev Invariant: a key that was not present at opening joins by casting a ballot, whatever
    /// its choice, and adds exactly one to D; a key present at opening adds nothing when it votes.
    /// A key bought after opening cannot join: it is still too new when the proposal closes.
    function test_lateBallotsJoinTheElectorate() public {
        _buyMany(fleet, 5);
        _mature();
        _lapse();
        _present(votes, _ids(_k(2)));
        uint256 proposalId = _propose(votes);
        assertEq(_d(votes, proposalId), 2);

        _ballot(votes, proposalId, _k(2), YES);
        assertEq(_d(votes, proposalId), 2, "an included key adds nothing");
        _ballot(votes, proposalId, _k(3), YES);
        _ballot(votes, proposalId, _k(4), NO);
        _ballot(votes, proposalId, _k(5), ABSTAIN);
        assertEq(votes.proposal(proposalId).late, 3, "a late Yes, No and Abstain each join");
        assertEq(_d(votes, proposalId), 5);

        uint256 minted = _buy(fleet, carol);
        uint64 maturesAt = uint64(block.timestamp) + votes.KEY_MATURITY();
        assertGe(maturesAt, votes.proposal(proposalId).closesAt, "it matures only once voting has closed");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyTooNew.selector, minted, maturesAt));
        votes.castBallot(proposalId, _ids(minted), NO);
        assertEq(_d(votes, proposalId), 5, "a key minted during voting does not join");
        assertFalse(votes.wasActiveAtOpening(proposalId, minted));
    }

    /// @dev Invariant: a key in the electorate stays counted when it expires, and an expired key
    /// that was included adds nothing when it votes later.
    function test_anIncludedKeyThatExpiresStaysCounted() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        _present(votes, _range(_k(2), 2));
        vm.warp(block.timestamp + 47 hours);
        vm.prank(_wallet(1));
        uint256 proposalId = votes.propose(_k(1), bytes32(0), _noCalls());
        assertEq(_d(votes, proposalId), 3);

        vm.warp(block.timestamp + 1 hours);
        votes.sweepExpired(10);
        assertFalse(votes.isActive(_k(2)), "key 2 expired");
        assertEq(_d(votes, proposalId), 3, "D does not shrink");
        _ballot(votes, proposalId, _k(2), YES);
        assertEq(_d(votes, proposalId), 3, "and its ballot does not add it twice");
    }

    /// @dev Invariant: a key that changes hands keeps its one slot. The new holder replaces its
    /// ballot, which moves its contribution without adding to D, and moving it back and forth never
    /// adds a ballot.
    function test_aTransferredKeyReplacesItsBallotWithoutDoubleCounting() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        uint256 k2 = _k(2);
        uint256 k3 = _k(3);
        _present(votes, _ids(k2));
        uint256 proposalId = _propose(votes);
        _ballot(votes, proposalId, k2, YES);
        _ballot(votes, proposalId, k3, YES);

        vm.prank(_wallet(2));
        keys.transferFrom(_wallet(2), carol, k2);
        vm.prank(_wallet(3));
        keys.transferFrom(_wallet(3), carol, k3);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k2, _wallet(2)));
        votes.castBallot(proposalId, _ids(k2), NO);

        vm.prank(carol);
        votes.castBallot(proposalId, _range(k2, 2), NO);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes, 0, "both keys left Yes");
        assertEq(stored.no, 2, "and hold one No each");
        assertEq(_d(votes, proposalId), 3, "D is unchanged: key 2 was included, key 3 already joined");
        assertTrue(votes.wasActiveAtOpening(proposalId, k2), "key 2 stays in the opening electorate");
    }

    /// @dev Invariant: renewing a key changes no open proposal: D moves only by a ballot.
    function test_presentAloneLeavesAnOpenElectorateUnchanged() public {
        _buyMany(fleet, 4);
        _mature();
        _lapse();
        uint256 proposalId = _propose(votes);
        _present(votes, _range(_k(2), 3));
        assertEq(_d(votes, proposalId), 1, "three keys renewed, none joined");
        assertEq(_propose(votes), 2);
        assertEq(_d(votes, 2), 4, "they count for the next proposal");
    }

    /// @dev Invariant: repeating a ballot changes no tally, though it renews the key.
    function test_repeatingABallotChangesNothingButRenewsTheKey() public {
        _buyMany(fleet, 2);
        _mature();
        _lapse();
        uint256 k2 = _k(2);
        uint256 proposalId = _propose(votes);
        _ballot(votes, proposalId, k2, YES);
        vm.warp(block.timestamp + 1 hours);
        _ballot(votes, proposalId, k2, YES);

        uint256[] memory twice = new uint256[](2);
        (twice[0], twice[1]) = (k2, k2);
        vm.prank(_wallet(2));
        votes.castBallot(proposalId, twice, YES);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes, 1, "one key, one Yes");
        assertEq(stored.late, 1);
        assertEq(votes.presentFrom(k2), uint64(block.timestamp), "renewed by the repeat");
    }

    /// @dev Invariant: from closing on, no ballot is accepted, late or not, and none on a cancelled
    /// proposal; a ballot is Yes, No or Abstain and names at least one key.
    function test_noBallotAfterClosingOrCancelling() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        uint256 proposalId = _propose(votes);
        uint256 cancelled = _propose(votes);

        vm.startPrank(_wallet(2));
        vm.expectRevert(KeyfleetVotes.InvalidChoice.selector);
        votes.castBallot(proposalId, _ids(_k(2)), KeyfleetVotes.Choice.None);
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.castBallot(proposalId, new uint256[](0), YES);
        vm.stopPrank();

        vm.prank(_wallet(1));
        votes.cancel(cancelled);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.BallotsClosed.selector, cancelled));
        votes.castBallot(cancelled, _ids(_k(2)), YES);

        _closeOf(votes, proposalId);
        vm.prank(_wallet(3));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.BallotsClosed.selector, proposalId));
        votes.castBallot(proposalId, _ids(_k(3)), YES);
        assertEq(_d(votes, proposalId), 1);
    }

    /// @dev The spec's §6 example table, row by row, on one fleet of twelve keys, at the threshold
    /// of 60% of D rounded up: row 3 needs six Yes of nine, row 4 seven of eleven.
    function test_theSpecExampleTable() public {
        _buyMany(fleet, 12);
        _mature();
        _lapse();
        uint256 t0 = block.timestamp;

        // Row 1: D=1, Yes=1 passes at the deadline.
        uint256 single = _propose(votes);
        _ballot(votes, single, _k(1), YES);

        // Row 2: D=4, Yes=2, No=0, Abstain=2 fails.
        _present(votes, _range(_k(2), 3));
        uint256 four = _propose(votes);
        _ballots(votes, four, _k(1), 2, YES);
        _ballots(votes, four, _k(3), 2, ABSTAIN);

        // Row 3: D=9, Yes=6 meets the threshold but cannot be carried out early. Keys 1 to 3
        // vote at the opening; keys 4 to 6 an hour later.
        _present(votes, _range(_k(5), 5));
        vm.prank(_wallet(1));
        uint256 nine = votes.propose(_k(1), bytes32(0), _noCalls());
        _ballots(votes, nine, _k(1), 3, YES);
        vm.warp(t0 + 1 hours);
        _ballots(votes, nine, _k(4), 3, YES);
        assertEq(_d(votes, nine), 9);
        assertEq(votes.proposal(nine).yes, votes.approvalsNeeded(9), "6 of 9 meets the threshold now");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(nine, _noCalls());

        // Row 4: two dormant keys vote No: D=11, Yes=6 does not meet the threshold.
        vm.warp(t0 + 2 hours);
        _ballots(votes, nine, _k(10), 2, NO);
        assertEq(_d(votes, nine), 11);
        assertEq(votes.proposal(nine).yes, 6);
        assertLt(votes.proposal(nine).yes, votes.approvalsNeeded(11), "7 of 11 are needed");

        vm.warp(t0 + 1 days);
        assertEq(uint256(_status(votes, single)), uint256(KeyfleetVotes.Status.Approved), "row 1 passed");
        assertEq(uint256(_status(votes, four)), uint256(KeyfleetVotes.Status.Rejected), "row 2 failed");

        // Row 5: six included keys expire (1 to 3 and 7 to 9, renewed at t0); D stays 11.
        vm.warp(t0 + 48 hours);
        (uint256 removed,) = votes.sweepExpired(100);
        assertEq(removed, 6, "six included keys expired");
        assertEq(_d(votes, nine), 11, "D stays 11");
        assertEq(uint256(_status(votes, nine)), uint256(KeyfleetVotes.Status.Rejected), "6 of 11 fails");

        // Row 6: the next proposal opens with one active key and has D=1; the old one keeps 11.
        vm.warp(t0 + 51 hours);
        uint256 next = _propose(votes, _k(12), _noCalls());
        assertEq(_d(votes, next), 1, "a new proposal can have D = 1");
        assertEq(_d(votes, nine), 11, "the old one does not shrink");
    }

    // --- 4. who may vote ----------------------------------------------------

    /// @dev Invariant: an owner and their key's agent share the one slot each key has. Either may
    /// replace its ballot, whoever acted last decides it, and an agent whose shard ended loses
    /// authority at once.
    function test_anOwnerAndTheirAgentShareOneSlotPerKey() public {
        for (uint256 i = 0; i < 3; ++i) {
            _buy(fleet, carol);
        }
        _mature();
        uint256 k1 = _k(1);
        uint256 k2 = _k(2);
        vm.prank(carol);
        shards.issue(_range(k1, 3), bob, 30);
        uint256 proposalId = _propose(votes);

        vm.prank(bob);
        votes.castBallot(proposalId, _ids(k1), YES);
        vm.prank(carol);
        votes.castBallot(proposalId, _ids(k1), NO);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes + stored.no, 1, "one key, one slot, whoever cast it");
        assertEq(stored.no, 1, "the owner acted last");

        vm.prank(carol);
        shards.end(_ids(k2), bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k2, bob));
        votes.castBallot(proposalId, _ids(k2), YES);
    }

    /// @dev Invariant: the owner's agent-voting switch decides whether a key's agent may cast
    /// ballots, propose or cancel; renewing stays open to the agent either way. A new owner starts
    /// with it on.
    function test_agentVotingOffStopsTheAgentVotingButNotRenewing() public {
        _buyMany(fleet, 3);
        _mature();
        uint256 k2 = _k(2);
        vm.prank(_wallet(2));
        shards.issue(_ids(k2), bob, 30);
        vm.prank(bob);
        uint256 authored = votes.propose(k2, bytes32(0), _noCalls());
        uint256 proposalId = _propose(votes);
        vm.prank(bob);
        votes.castBallot(proposalId, _ids(k2), YES);

        vm.prank(_wallet(2));
        shards.setAgentVoting(_ids(k2), false);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k2, bob));
        votes.castBallot(proposalId, _ids(k2), NO);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k2, bob));
        votes.propose(k2, bytes32(0), _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k2, bob));
        votes.cancel(authored);
        votes.present(_ids(k2));
        vm.stopPrank();
        assertEq(votes.proposal(proposalId).yes, 1, "the agent's earlier ballot stands");

        vm.prank(_wallet(2));
        keys.transferFrom(_wallet(2), carol, k2);
        vm.prank(carol);
        shards.issue(_ids(k2), bob, 30);
        vm.prank(bob);
        votes.castBallot(proposalId, _ids(k2), NO);
        assertEq(votes.proposal(proposalId).no, 1, "the new owner's agent votes with no switch");
    }

    /// @dev Invariant: an agent holding shards of many keys, from several owners, votes them all in
    /// one call; a batch with one key it holds no shard of is refused whole.
    function test_anAgentVotesTheKeysOfManyOwnersInOneCall() public {
        _buyMany(fleet, 4);
        _mature();
        for (uint256 n = 1; n <= 3; ++n) {
            vm.prank(_wallet(n));
            shards.issue(_ids(_k(n)), bob, 30);
        }
        uint256 proposalId = _propose(votes);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, _k(4), bob));
        votes.castBallot(proposalId, _range(_k(1), 4), YES);
        assertEq(votes.proposal(proposalId).yes, 0, "nothing before the failure");

        uint256[] memory three = _range(_k(1), 3);
        vm.expectEmit(true, true, true, true, address(votes));
        emit BallotCast(proposalId, bob, ABSTAIN, three);
        vm.prank(bob);
        votes.castBallot(proposalId, three, ABSTAIN);
        assertEq(votes.proposal(proposalId).abstain, 3, "three owners' keys, one call");
    }

    /// @dev Invariant: a marketplace approval is not delegation. An address approved for one key or
    /// for all of an owner's keys may move them but cannot renew, vote, propose or cancel with them.
    function test_aMarketplaceApprovalIsNotDelegation() public {
        _buyMany(fleet, 1);
        _buy(fleet, _wallet(1)); // key 2
        _mature();
        uint256 k1 = _k(1);
        uint256 proposalId = _propose(votes);
        vm.startPrank(_wallet(1));
        keys.approve(mallory, k1);
        keys.setApprovalForAll(mallory, true);
        vm.stopPrank();

        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.present(_ids(k1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.castBallot(proposalId, _ids(k1), YES);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, _k(2), mallory));
        votes.propose(_k(2), bytes32(0), _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.cancel(proposalId);
        vm.stopPrank();
    }

    // --- 5. cancelling -------------------------------------------------------

    /// @dev Invariant: whoever may vote the author key now cancels, while the proposal is open or
    /// approved, renewing that key; nobody else can, and nothing closed can be cancelled.
    function test_theAuthorKeyCancelsWhileOpenOrApproved() public {
        _buyMany(fleet, 2);
        _mature();
        _lapse();
        uint256 k1 = _k(1);
        uint256 open = _propose(votes);
        uint256 approved = _propose(votes);
        _ballot(votes, approved, k1, YES);
        uint256 rejected = _propose(votes);

        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, _wallet(2)));
        votes.cancel(open);

        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCancelled(open, _wallet(1));
        vm.prank(_wallet(1));
        votes.cancel(open);
        assertEq(uint256(_status(votes, open)), uint256(KeyfleetVotes.Status.Cancelled));
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotCancellable.selector, KeyfleetVotes.Status.Cancelled));
        votes.cancel(open);

        _closeOf(votes, approved);
        vm.prank(_wallet(1));
        keys.transferFrom(_wallet(1), carol, k1);
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, _wallet(1)));
        votes.cancel(approved);
        vm.prank(carol);
        votes.cancel(approved);
        assertTrue(votes.isActive(k1), "cancelling renewed the author key under its new owner");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Cancelled));
        votes.execute(approved, _noCalls());

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotCancellable.selector, KeyfleetVotes.Status.Rejected));
        votes.cancel(rejected);
    }

    // --- 6. carrying out -----------------------------------------------------

    /// @dev Invariant: anyone carries out an approved proposal, once, with exactly its calls, which
    /// the treasury makes; carrying out renews no key.
    function test_anApprovedProposalIsCarriedOutOnceWithItsExactCalls() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        uint256 k1 = _k(1);
        uint256 k3 = _k(3);
        KeyfleetTreasury.Call[] memory calls = _restrict(votes, k3, true);
        uint256 proposalId = _propose(votes, k1, calls);
        _ballot(votes, proposalId, k1, YES);
        _closeOf(votes, proposalId);
        uint64 renewedAt = votes.presentFrom(k1);

        vm.expectEmit(true, true, true, true, address(votes));
        emit EditsRestrictionSet(k3, true);
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, mallory);
        vm.prank(mallory);
        votes.execute(proposalId, calls);

        assertTrue(votes.editsRestricted(k3));
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Executed));
        assertEq(votes.presentFrom(k1), renewedAt, "carrying out renewed nobody");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Executed));
        votes.execute(proposalId, calls);
    }

    /// @dev Invariant: the calls must be exactly the proposal's: a changed target, value, data or
    /// order, a dropped call or an extra one is refused.
    function test_changedCallsAreRefused() public {
        _buyMany(fleet, 3);
        _mature();
        _lapse();
        uint256 k2 = _k(2);
        uint256 k3 = _k(3);
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _restrict(votes, k2, true)[0];
        calls[1] = _restrict(votes, k3, true)[0];
        uint256 proposalId = _propose(votes, _k(1), calls);
        _ballot(votes, proposalId, _k(1), YES);
        _closeOf(votes, proposalId);

        KeyfleetTreasury.Call[][] memory changed = new KeyfleetTreasury.Call[][](6);
        for (uint256 i = 0; i < 4; ++i) {
            changed[i] = new KeyfleetTreasury.Call[](2);
            changed[i][0] = _restrict(votes, k2, true)[0];
            changed[i][1] = _restrict(votes, k3, true)[0];
        }
        changed[0][0].target = address(fleet);
        changed[1][0].value = 1;
        changed[2][1].data = abi.encodeCall(votes.setEditsRestricted, (k3, false));
        (changed[3][0], changed[3][1]) = (calls[1], calls[0]);
        changed[4] = _restrict(votes, k2, true);
        changed[5] = new KeyfleetTreasury.Call[](3);
        (changed[5][0], changed[5][1], changed[5][2]) = (calls[0], calls[1], calls[1]);
        for (uint256 i = 0; i < changed.length; ++i) {
            vm.expectRevert(KeyfleetVotes.ActionsMismatch.selector);
            votes.execute(proposalId, changed[i]);
        }
        votes.execute(proposalId, calls);
        assertTrue(votes.editsRestricted(k2) && votes.editsRestricted(k3));
    }

    /// @dev Invariant: a batch whose call reverts reverts whole, with the call's reason, and the
    /// proposal stays approved and can be retried until its execution expiry, never after.
    function test_aFailedBatchCanBeRetriedUntilItExpires() public {
        _buyMany(fleet, 3);
        _mature();
        _openTreasury(fleet);
        uint256 k1 = _k(1);
        uint256 k3 = _k(3);
        MockSwitch target = new MockSwitch();
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _restrict(votes, k3, true)[0];
        calls[1] = KeyfleetTreasury.Call(address(target), 0, abi.encodeCall(target.ping, ()));
        uint256 proposalId = _propose(votes, k1, calls);
        uint256 expiring = _propose(votes, k1, calls);
        _ballot(votes, proposalId, k1, YES);
        _ballot(votes, expiring, k1, YES);
        _carryOutOf(votes, proposalId);

        vm.expectRevert(MockSwitch.Failing.selector);
        votes.execute(proposalId, calls);
        assertFalse(votes.editsRestricted(k3), "the first call was undone with the batch");
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved), "still approved");

        target.setFailing(false);
        votes.execute(proposalId, calls);
        assertEq(target.pings(), 1);
        assertTrue(votes.editsRestricted(k3));

        vm.warp(votes.proposal(expiring).executionExpiry - 1);
        assertEq(uint256(_status(votes, expiring)), uint256(KeyfleetVotes.Status.Approved));
        vm.warp(votes.proposal(expiring).executionExpiry);
        assertEq(uint256(_status(votes, expiring)), uint256(KeyfleetVotes.Status.ExecutionExpired));
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.ExecutionExpired)
        );
        votes.execute(expiring, calls);
        vm.prank(_wallet(1));
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetVotes.NotCancellable.selector, KeyfleetVotes.Status.ExecutionExpired)
        );
        votes.cancel(expiring);
    }

    /// @dev Invariant: an approved call cannot carry out another proposal inside itself.
    function test_anApprovedCallCannotCarryOutAnotherProposal() public {
        _buyMany(fleet, 3);
        _mature();
        _openTreasury(fleet);
        uint256 k1 = _k(1);
        KeyfleetTreasury.Call[] memory inner = _restrict(votes, _k(2), true);
        uint256 innerId = _propose(votes, k1, inner);
        KeyfleetTreasury.Call[] memory outer = _one(address(votes), 0, abi.encodeCall(votes.execute, (innerId, inner)));
        uint256 outerId = _propose(votes, k1, outer);
        _ballot(votes, innerId, k1, YES);
        _ballot(votes, outerId, k1, YES);
        _carryOutOf(votes, outerId);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        votes.execute(outerId, outer);
        assertEq(uint256(_status(votes, innerId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(uint256(_status(votes, outerId)), uint256(KeyfleetVotes.Status.Approved));
    }

    /// @dev Invariant: only the treasury sets a key's edit restriction, and only for a key of this
    /// fleet already sold; only the voting controller hands the treasury calls.
    function test_onlyACarriedOutProposalReachesTheTreasuryAndTheRestriction() public {
        _buyMany(fleet, 1);
        _mature();
        uint256 k1 = _k(1);
        KeyfleetTreasury treasury = fleet.TREASURY();

        vm.prank(_wallet(1));
        vm.expectRevert(KeyfleetVotes.OnlyTreasury.selector);
        votes.setEditsRestricted(k1, true);
        vm.prank(_wallet(1));
        vm.expectRevert(KeyfleetTreasury.OnlyVotes.selector);
        treasury.executeBatch(_restrict(votes, k1, true));

        vm.startPrank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotMinted.selector, _k(2)));
        votes.setEditsRestricted(_k(2), true);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotMinted.selector, _k(0)));
        votes.setEditsRestricted(_k(0), true);
        vm.stopPrank();

        uint256 proposalId = _propose(votes, k1, _restrict(votes, k1, true));
        _ballot(votes, proposalId, k1, YES);
        _closeOf(votes, proposalId);
        votes.execute(proposalId, _restrict(votes, k1, true));
        assertTrue(votes.editsRestricted(k1));
        uint256 lift = _propose(votes, k1, _restrict(votes, k1, false));
        _ballot(votes, lift, k1, YES);
        _closeOf(votes, lift);
        votes.execute(lift, _restrict(votes, k1, false));
        assertFalse(votes.editsRestricted(k1), "a later proposal lifts it");
    }

    // --- 7. keys of other fleets ---------------------------------------------

    /// @dev A second Classic fleet, created by `creator` (who holds its key 1), with its key 2 sold
    /// to `_wallet(1)`, who also holds key 1 of the founding fleet. The two fleets are the same
    /// type, so only the fleet binding tells their keys apart.
    function _otherFleet() private returns (KeyfleetManager other) {
        _buyMany(fleet, 1);
        other = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, OPEN_START);
        _buy(other, _wallet(1));
        assertEq(keys.ownerOf(_key(other, 2)), _wallet(1));
        assertEq(uint256(other.PRESET()), uint256(fleet.PRESET()), "a fleet of the same type");
    }

    /// @dev Invariant: renewing refuses a key of another fleet with `ForeignKey` before anything
    /// else, its age included, even when the caller owns it and could renew it in its own fleet; a
    /// token id of a fleet that does not exist, and token id zero, are foreign too, and a batch
    /// with one foreign key renews nothing.
    function test_renewingRefusesAKeyOfAnotherFleetFirst() public {
        KeyfleetManager other = _otherFleet();
        uint256 foreign = _key(other, 2);

        assertGt(other.VOTES().maturesAt(foreign), block.timestamp, "the foreign key is still too new");
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.present(_ids(foreign));

        _mature();
        vm.startPrank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.present(_ids(foreign));
        uint256[] memory mixed = new uint256[](2);
        (mixed[0], mixed[1]) = (_k(1), foreign);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.present(mixed);
        vm.stopPrank();

        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.present(_ids(foreign));
        uint256 unknownFleet = keys.tokenIdOf(99, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, unknownFleet));
        votes.present(_ids(unknownFleet));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, 0));
        votes.present(_ids(0));
        vm.stopPrank();

        (,, uint32 renewed) = votes.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(renewed, 0, "nothing was renewed here");
        assertEq(votes.presenceRevision(), 1, "only key 1's sale is recorded here");
        assertFalse(votes.isActive(foreign));

        KeyfleetVotes otherVotes = other.VOTES();
        vm.prank(_wallet(1));
        otherVotes.present(_ids(foreign));
        assertTrue(otherVotes.isActive(foreign), "its own fleet renews it");
    }

    /// @dev Invariant: proposing refuses an author key of another fleet with `ForeignKey` before
    /// it checks the caller's standing, so no proposal ever has a foreign author key and `cancel`
    /// only ever meets this fleet's keys.
    function test_proposingRefusesAnAuthorKeyOfAnotherFleetFirst() public {
        KeyfleetManager other = _otherFleet();
        uint256 foreign = _key(other, 2);

        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.propose(foreign, bytes32(0), _noCalls());
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.propose(foreign, bytes32(0), _noCalls());

        vm.prank(_wallet(1));
        shards.issue(_ids(foreign), bob, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.propose(foreign, bytes32(0), _noCalls());

        assertEq(votes.proposalCount(), 0, "no proposal was made");
        assertFalse(votes.isActive(foreign));
    }

    /// @dev Invariant: casting a ballot refuses a key of another fleet with `ForeignKey` before it
    /// checks the voter's standing, whether the owner or the key's agent casts it; a batch with one
    /// foreign key is refused whole and moves no tally.
    function test_castingABallotRefusesAKeyOfAnotherFleetFirst() public {
        KeyfleetManager other = _otherFleet();
        _mature();
        uint256 foreign = _key(other, 2);
        uint256 proposalId = _propose(votes);

        vm.startPrank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.castBallot(proposalId, _ids(foreign), YES);
        uint256[] memory mixed = new uint256[](2);
        (mixed[0], mixed[1]) = (_k(1), foreign);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.castBallot(proposalId, mixed, YES);
        shards.issue(_ids(foreign), bob, 30);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.castBallot(proposalId, _ids(foreign), YES);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.castBallot(proposalId, _ids(foreign), YES);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes + stored.no + stored.abstain + stored.late, 0, "no tally moved");
        assertEq(_d(votes, proposalId), 1);
        assertEq(uint256(votes.ballotOf(proposalId, foreign)), uint256(KeyfleetVotes.Choice.None));
    }

    /// @dev Invariant: an approved proposal cannot restrict the edits of another fleet's key: the
    /// treasury's call is refused with `ForeignKey`, the whole batch reverts, and the proposal
    /// stays approved. Another fleet's treasury cannot set this fleet's restrictions at all.
    function test_restrictingEditsRefusesAKeyOfAnotherFleet() public {
        KeyfleetManager other = _otherFleet();
        _mature();
        uint256 foreign = _key(other, 2);
        KeyfleetTreasury.Call[] memory calls = _restrict(votes, foreign, true);
        uint256 proposalId = _propose(votes, _k(1), calls);
        _ballot(votes, proposalId, _k(1), YES);
        _closeOf(votes, proposalId);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.execute(proposalId, calls);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved), "still approved");
        assertFalse(votes.editsRestricted(foreign));
        assertFalse(other.VOTES().editsRestricted(foreign), "its own fleet's record is untouched");

        vm.prank(address(other.TREASURY()));
        vm.expectRevert(KeyfleetVotes.OnlyTreasury.selector);
        votes.setEditsRestricted(_k(1), true);
        vm.prank(address(fleet.TREASURY()));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votes.setEditsRestricted(foreign, true);
    }

    // --- 8. fleets are independent -------------------------------------------

    /// @dev Everything one fleet's controller records that another fleet's activity could touch.
    function _snapshot(KeyfleetVotes v, uint256[] memory tokenIds) private view returns (bytes32) {
        bytes memory state = abi.encode(v.presenceRevision(), v.proposalCount());
        for (uint8 place = 1; place <= uint8(KeyfleetPresence.Place.Renewed); ++place) {
            (uint64 head, uint64 tail, uint32 count) = v.presenceList(KeyfleetPresence.Place(place));
            state = bytes.concat(state, abi.encode(head, tail, count));
        }
        for (uint256 id = 1; id <= v.proposalCount(); ++id) {
            state = bytes.concat(state, abi.encode(v.proposal(id), v.status(id)));
        }
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            state = bytes.concat(state, _keySnapshot(v, tokenIds[i]));
        }
        return keccak256(state);
    }

    /// @dev One key's presence entry, presence, ballot on proposal 1 and edit restriction.
    function _keySnapshot(KeyfleetVotes v, uint256 tokenId) private view returns (bytes memory) {
        (KeyfleetPresence.Place place, uint64 prev, uint64 next, uint64 dueAt) = v.presenceEntry(tokenId);
        return bytes.concat(
            abi.encode(place, prev, next, dueAt, v.isActive(tokenId), v.presentFrom(tokenId)),
            abi.encode(v.ballotOf(1, tokenId), v.editsRestricted(tokenId))
        );
    }

    /// @dev Invariant: two fleets of the same type keep separate presence lists, electorates,
    /// tallies and proposals. Renewals, proposals, ballots, transfers, cancelling, carrying out and
    /// sweeping in fleet B, by the same wallets that hold fleet A's keys, change nothing in fleet A,
    /// and fleet B's first proposal counts only fleet B's present keys.
    function test_activityInOneFleetChangesNothingInAnother() public {
        KeyfleetManager a = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, OPEN_START);
        KeyfleetManager b = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, OPEN_START);
        KeyfleetVotes votesA = a.VOTES();
        KeyfleetVotes votesB = b.VOTES();
        for (uint256 n = 2; n <= 4; ++n) {
            _buy(a, _wallet(n));
            _buy(b, _wallet(n));
        }
        _mature();
        _lapse();

        _present(votesA, _range(_key(a, 2), 2));
        uint256 proposalA = _propose(votesA);
        _ballot(votesA, proposalA, _key(a, 2), YES);
        _ballot(votesA, proposalA, _key(a, 4), NO);
        uint256[] memory keysA = _range(_key(a, 1), 4);
        bytes32 before = _snapshot(votesA, keysA);
        assertEq(votesA.proposal(proposalA).e0, 3, "fleet A: keys 1 to 3 present");

        _present(votesB, _ids(_key(b, 4)));
        uint256 proposalB = _propose(votesB, _key(b, 1), _restrict(votesB, _key(b, 3), true));
        assertEq(proposalB, proposalA, "both fleets number their proposals from one");
        assertEq(votesB.proposal(proposalB).e0, 2, "fleet B counts only its own present keys");
        assertTrue(
            votesB.proposal(proposalB).proposalHash != votesA.proposal(proposalA).proposalHash, "and its own hash"
        );
        _ballots(votesB, proposalB, _key(b, 1), 4, YES);
        uint256 cancelled = _propose(votesB);
        vm.prank(creator);
        votesB.cancel(cancelled);
        uint256 moved = _key(b, 2);
        vm.prank(_wallet(2));
        keys.transferFrom(_wallet(2), carol, moved);
        assertEq(_snapshot(votesA, keysA), before, "fleet A unchanged by renewals, ballots and transfers in B");

        _closeOf(votesB, proposalB);
        votesB.execute(proposalB, _restrict(votesB, _key(b, 3), true));
        assertTrue(votesB.editsRestricted(_key(b, 3)));
        bytes32 later = _snapshot(votesA, keysA);
        vm.warp(block.timestamp + 3 days);
        bytes32 expired = _snapshot(votesA, keysA);
        (uint256 removed,) = votesB.sweepExpired(100);
        assertEq(removed, 3, "fleet B's three present keys expired; the moved key 2 was not queued");
        assertEq(_snapshot(votesA, keysA), expired, "fleet A unchanged by a sweep in B");
        (,, uint32 renewedA) = votesA.presenceList(KeyfleetPresence.Place.Renewed);
        assertEq(renewedA, 4, "fleet A's expired entries wait for its own sweep");

        vm.warp(block.timestamp - 3 days);
        assertEq(_snapshot(votesA, keysA), later, "fleet A unchanged by carrying out in B");
        assertEq(_d(votesA, proposalA), 4, "fleet A's own electorate: three at opening, one late");
        assertEq(votesA.proposal(proposalA).yes, 1, "and its own tally");
        assertEq(votesA.proposal(proposalA).no, 1);
        assertEq(uint256(_status(votesA, proposalA)), uint256(KeyfleetVotes.Status.Rejected), "closed on its own tally");
    }

    // --- 9. gas -------------------------------------------------------------

    /// @dev Invariant: casting ballots is the one call whose cost grows with what it is asked, and
    /// only with the number of keys named, never with the fleet. Each first ballot costs the slot,
    /// the fleet check, the authority check, the look-up of the key at opening, the key's maturity
    /// check and its renewal, and the preset makes no difference. It is measured for the dearer caller, an agent
    /// through its shards.
    function test_ballotsCostAFixedAmountPerKeyNamed() public {
        for (uint256 i = 0; i < 40; ++i) {
            _buy(fleet, _wallet(1));
        }
        _mature();
        _lapse();
        vm.prank(_wallet(1));
        shards.issue(_range(_k(1), 40), bob, 30);
        uint256 flatTen = _measureBallot(votes, bob, _k(2), 10);
        uint256 flatPerKey = (_measureBallot(votes, bob, _k(12), 29) - flatTen) / 19;

        // One agent for ten Fibonacci keys across three levels, each held by its own wallet: each
        // owner issues Bob a shard, so one call names keys of many wallets.
        KeyfleetManager levelled = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buyMany(levelled, 10);
        _mature();
        _lapse();
        for (uint256 n = 1; n <= 10; ++n) {
            uint256 tokenId = _key(levelled, n);
            vm.prank(_wallet(n));
            shards.issue(_ids(tokenId), bob, 30);
        }
        uint256 levelledTwo = _measureBallot(levelled.VOTES(), bob, _key(levelled, 2), 2);
        uint256 levelledPerKey = (_measureBallot(levelled.VOTES(), bob, _key(levelled, 4), 6) - levelledTwo) / 4;

        console2.log("ballot gas for ten Classic keys:", flatTen);
        console2.log("marginal ballot gas per Classic key:", flatPerKey);
        console2.log("marginal ballot gas per Fibonacci key:", levelledPerKey);

        assertLt(flatTen, TEN_KEY_BALLOT_CEILING, "a ten-key ballot stays under the published ceiling");
        assertLt(flatPerKey, PER_KEY_BALLOT_CEILING, "each extra key costs a fixed amount");
        assertApproxEqAbs(levelledPerKey, flatPerKey, 500, "a Fibonacci key costs what a Classic key costs");
    }

    /// @dev Casts `count` consecutive ids from `firstTokenId` in one call on a new proposal and
    /// returns the gas used. Key 1 proposes, which renews it, so the measured ranges leave it out
    /// and every key they name is renewed and joins for the first time.
    function _measureBallot(KeyfleetVotes v, address caster, uint256 firstTokenId, uint256 count)
        private
        returns (uint256 used)
    {
        uint256 proposalId = _propose(v);
        uint256[] memory tokenIds = _range(firstTokenId, count);
        vm.prank(caster);
        uint256 before = gasleft();
        v.castBallot(proposalId, tokenIds, YES);
        used = before - gasleft();
    }
}
