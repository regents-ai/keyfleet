// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockRegent} from "./mocks/MockRegent.sol";
import {MockAutolaunchFactory} from "./mocks/MockAutolaunchFactory.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";

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

contract KeyfleetVotesTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";
    /// @dev Measured cost of an agent casting ten first ballots on Classic keys in one call through
    /// its shards, plus a fifth, rounded up.
    uint256 private constant TEN_KEY_BALLOT_CEILING = 1_250_000;
    /// @dev Measured marginal cost of one more key in an agent's ballot, plus a fifth, rounded up.
    uint256 private constant PER_KEY_BALLOT_CEILING = 125_000;

    KeyfleetVotes.Choice private constant YES = KeyfleetVotes.Choice.Yes;
    KeyfleetVotes.Choice private constant NO = KeyfleetVotes.Choice.No;
    KeyfleetVotes.Choice private constant ABSTAIN = KeyfleetVotes.Choice.Abstain;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    address private buyer = address(0xB0B0B0);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private mallory = address(0x4A11);

    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed authorKey,
        address indexed proposer,
        bytes32 proposalHash,
        bytes32 contentHash,
        uint64 closesAt,
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
        usdc = new MockToken("USD Coin", "USDC");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);
        vm.roll(1_000);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = KeyfleetStack.deploy(
            preset,
            usdc,
            new MockRegentRevenueStaking(usdc),
            new MockRegent(),
            new MockAutolaunchFactory(),
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    function _classic() private returns (Keyfleet fleet, KeyfleetVotes votes) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();
    }

    function _buy(Keyfleet fleet, address receiver) private returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, price, block.timestamp);
        vm.stopPrank();
    }

    /// @dev One key per wallet, which every preset allows and the two Fibonacci ones require below
    /// level 8. Key `i` therefore belongs to `_wallet(i)` unless a test moves it.
    function _buyMany(Keyfleet fleet, uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
    }

    function _wallet(uint256 index) private pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _range(uint256 first, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    function _noCalls() private pure returns (KeyfleetTreasury.Call[] memory) {
        return new KeyfleetTreasury.Call[](0);
    }

    /// @dev One call from the treasury restricting a key's edits.
    function _restrict(KeyfleetVotes votes, uint256 tokenId, bool restricted)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory calls)
    {
        calls = new KeyfleetTreasury.Call[](1);
        calls[0] =
            KeyfleetTreasury.Call(address(votes), 0, abi.encodeCall(votes.setEditsRestricted, (tokenId, restricted)));
    }

    /// @dev Renews keys as their current owners.
    function _present(KeyfleetVotes votes, uint256[] memory tokenIds) private {
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            vm.prank(votes.FLEET().ownerOf(tokenIds[i]));
            votes.present(_ids(tokenIds[i]));
        }
    }

    /// @dev Opens a proposal with key `authorKey` as its owner, closing a day from now.
    function _propose(KeyfleetVotes votes, uint256 authorKey, KeyfleetTreasury.Call[] memory calls)
        private
        returns (uint256 proposalId)
    {
        vm.prank(votes.FLEET().ownerOf(authorKey));
        proposalId = votes.propose(authorKey, keccak256("narrative"), uint64(block.timestamp + 1 days), calls);
    }

    function _propose(KeyfleetVotes votes) private returns (uint256) {
        return _propose(votes, 1, _noCalls());
    }

    /// @dev Casts one key's ballot as its current owner.
    function _ballot(KeyfleetVotes votes, uint256 proposalId, uint256 tokenId, KeyfleetVotes.Choice choice) private {
        vm.prank(votes.FLEET().ownerOf(tokenId));
        votes.castBallot(proposalId, _ids(tokenId), choice);
    }

    function _ballots(
        KeyfleetVotes votes,
        uint256 proposalId,
        uint256 first,
        uint256 count,
        KeyfleetVotes.Choice choice
    ) private {
        for (uint256 i = 0; i < count; ++i) {
            _ballot(votes, proposalId, first + i, choice);
        }
    }

    function _status(KeyfleetVotes votes, uint256 proposalId) private view returns (KeyfleetVotes.Status) {
        return votes.status(proposalId);
    }

    function _closeOf(KeyfleetVotes votes, uint256 proposalId) private {
        vm.warp(votes.proposal(proposalId).closesAt);
    }

    function _d(KeyfleetVotes votes, uint256 proposalId) private view returns (uint256) {
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        return uint256(stored.e0) + stored.late;
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet, its voting controller and its treasury are bound to each other, so
    /// no deployment step can leave a fleet taking orders from someone else's vote.
    function test_constructorDeploysAndBindsItsOwnVotingController() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();

        assertEq(address(votes.FLEET()), address(fleet), "the controller is bound to this fleet");
        assertEq(address(votes.SHARDS()), address(fleet.SHARDS()));
        assertEq(address(votes.TREASURY()), address(fleet.TREASURY()));
        assertEq(address(fleet.TREASURY().VOTES()), address(votes), "the treasury takes calls from it");
        assertEq(votes.proposalCount(), 0, "no proposal exists yet");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.WrongFleet.selector, address(fleet)));
        new KeyfleetVotes(fleet);
    }

    // --- 2. proposals -----------------------------------------------------

    /// @dev Invariant: a proposal records its author key, content, exact calls, opening, closing and
    /// execution expiry, binds them in one hash, renews its author key and casts no ballot.
    function test_aProposalRecordsItsOpeningAndBindsItsWholeContent() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        _present(votes, _ids(2));

        KeyfleetTreasury.Call[] memory calls = _restrict(votes, 3, true);
        bytes32 content = keccak256("restrict key 3");
        uint64 closesAt = uint64(block.timestamp + 12 hours);
        uint64 expiry = closesAt + 48 hours;
        bytes32 actionsHash = keccak256(abi.encode(calls));
        bytes32 proposalHash = keccak256(
            abi.encode(
                block.chainid,
                address(votes),
                address(fleet.TREASURY()),
                uint256(1),
                uint256(1),
                fleet.ownershipEpoch(1),
                content,
                actionsHash,
                closesAt,
                expiry
            )
        );

        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(1, 1, _wallet(1), proposalHash, content, closesAt, expiry, 2, 3, calls);
        vm.prank(_wallet(1));
        uint256 proposalId = votes.propose(1, content, closesAt, calls);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(proposalId, 1, "proposal ids start at one");
        assertEq(stored.authorKey, 1);
        assertEq(stored.contentHash, content);
        assertEq(stored.actionsHash, actionsHash);
        assertEq(stored.proposalHash, proposalHash);
        assertEq(stored.openRevision, 3, "key 2's renewal, the author's renewal, then the opening");
        assertEq(stored.openedAt, uint64(block.timestamp));
        assertEq(stored.closesAt, closesAt);
        assertEq(stored.executionExpiry, expiry, "48 hours after closing");
        assertEq(stored.e0, 2, "key 2 and the author key were present");
        assertTrue(votes.isActive(1), "the author key was renewed");
        assertEq(stored.yes + stored.no + stored.abstain + stored.late, 0, "proposing casts no ballot");
        assertEq(uint256(votes.ballotOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.None));
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open));
    }

    /// @dev Invariant: a proposal closes after it opens and at most 48 hours later, both ends of
    /// the range checked.
    function test_aProposalClosesWithinFortyEightHours() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 1);
        uint64 nowAt = uint64(block.timestamp);

        vm.startPrank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ClosingOutOfRange.selector, nowAt));
        votes.propose(1, bytes32(0), nowAt, _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ClosingOutOfRange.selector, nowAt + 48 hours + 1));
        votes.propose(1, bytes32(0), nowAt + 48 hours + 1, _noCalls());
        votes.propose(1, bytes32(0), nowAt + 1, _noCalls());
        votes.propose(1, bytes32(0), nowAt + 48 hours, _noCalls());
        vm.stopPrank();
        assertEq(votes.proposalCount(), 2);
    }

    /// @dev Invariant: proposing needs standing. The author key must be one the caller may vote:
    /// its owner, or a wallet holding an active shard of it while its agent voting is on.
    function test_proposingRequiresAKeyTheCallerMayVote() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 2);
        uint64 closesAt = uint64(block.timestamp + 1 days);

        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 3));
        votes.propose(3, bytes32(0), closesAt, _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, carol));
        votes.propose(1, bytes32(0), closesAt, _noCalls());
        vm.stopPrank();

        vm.startPrank(_wallet(1));
        fleet.SHARDS().issue(_ids(1), carol, 30);
        vm.stopPrank();
        vm.expectEmit(true, true, true, false, address(votes));
        emit ProposalCreated(1, 1, carol, bytes32(0), bytes32(0), 0, 0, 0, 0, _noCalls());
        vm.prank(carol);
        votes.propose(1, bytes32(0), closesAt, _noCalls());
    }

    /// @dev Invariant: an identical proposal made again is a new proposal, with its own id, hash
    /// and electorate; nothing deduplicates it and nothing is reserved.
    function test_anIdenticalResubmissionIsANewProposal() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        KeyfleetTreasury.Call[] memory calls = _restrict(votes, 2, true);
        uint256 first = _propose(votes, 1, calls);
        _present(votes, _ids(2));
        uint256 second = _propose(votes, 1, calls);

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
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 1);
        _propose(votes);

        uint256[2] memory unknown = [uint256(0), 2];
        for (uint256 i = 0; i < unknown.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.status(unknown[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.proposal(unknown[i]);
            vm.prank(_wallet(1));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.castBallot(unknown[i], _ids(1), YES);
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
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 5);
        uint256 proposalId = _propose(votes);
        _ballot(votes, proposalId, 1, YES);

        assertEq(_d(votes, proposalId), 1, "D = 1");
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(proposalId, _noCalls());

        vm.warp(votes.proposal(proposalId).closesAt - 1);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Open), "open to its last second");
        vm.warp(votes.proposal(proposalId).closesAt);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved));
    }

    /// @dev Invariant: Yes must be more than half of D. A tie fails, and so does Yes at exactly
    /// half with the rest abstaining.
    function test_tiesFail() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 4);
        _present(votes, _range(2, 3));
        uint256 proposalId = _propose(votes);
        _ballots(votes, proposalId, 1, 2, YES);
        _ballots(votes, proposalId, 3, 2, ABSTAIN);

        uint256 tie = _propose(votes);
        _ballot(votes, tie, 1, YES);
        _ballot(votes, tie, 2, NO);

        _closeOf(votes, tie);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(_d(votes, proposalId), 4);
        assertEq(stored.yes, 2);
        assertEq(stored.abstain, 2);
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Rejected), "2 of 4 fails");
        assertEq(_d(votes, tie), 4, "the silent present keys count");
        assertEq(uint256(_status(votes, tie)), uint256(KeyfleetVotes.Status.Rejected), "1 to 1 fails");
    }

    /// @dev Invariant: a key that was not present at opening joins by casting a ballot, whatever
    /// its choice, and adds exactly one to D; a key present at opening adds nothing when it votes,
    /// and a key bought after opening joins the same way.
    function test_lateBallotsJoinTheElectorate() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 5);
        _present(votes, _ids(2));
        uint256 proposalId = _propose(votes);
        assertEq(_d(votes, proposalId), 2);

        _ballot(votes, proposalId, 2, YES);
        assertEq(_d(votes, proposalId), 2, "an included key adds nothing");
        _ballot(votes, proposalId, 3, YES);
        _ballot(votes, proposalId, 4, NO);
        _ballot(votes, proposalId, 5, ABSTAIN);
        assertEq(votes.proposal(proposalId).late, 3, "a late Yes, No and Abstain each join");
        assertEq(_d(votes, proposalId), 5);

        uint256 minted = _buy(fleet, carol);
        _ballot(votes, proposalId, minted, NO);
        assertEq(_d(votes, proposalId), 6, "a key minted during voting joins by voting");
        assertFalse(votes.wasActiveAtOpening(proposalId, minted));
    }

    /// @dev Invariant: a key in the electorate stays counted when it expires, and an expired key
    /// that was included adds nothing when it votes later.
    function test_anIncludedKeyThatExpiresStaysCounted() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        _present(votes, _range(2, 2));
        vm.warp(block.timestamp + 47 hours);
        vm.prank(_wallet(1));
        uint256 proposalId = votes.propose(1, bytes32(0), uint64(block.timestamp + 2 hours), _noCalls());
        assertEq(_d(votes, proposalId), 3);

        vm.warp(block.timestamp + 1 hours);
        votes.sweepExpired(10);
        assertFalse(votes.isActive(2), "key 2 expired");
        assertEq(_d(votes, proposalId), 3, "D does not shrink");
        _ballot(votes, proposalId, 2, YES);
        assertEq(_d(votes, proposalId), 3, "and its ballot does not add it twice");
    }

    /// @dev Invariant: a key that changes hands keeps its one slot. The new holder replaces its
    /// ballot, which moves its contribution without adding to D, and moving it back and forth never
    /// adds a ballot.
    function test_aTransferredKeyReplacesItsBallotWithoutDoubleCounting() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        _present(votes, _ids(2));
        uint256 proposalId = _propose(votes);
        _ballot(votes, proposalId, 2, YES);
        _ballot(votes, proposalId, 3, YES);

        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), carol, 2);
        vm.prank(_wallet(3));
        fleet.transferFrom(_wallet(3), carol, 3);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, _wallet(2)));
        votes.castBallot(proposalId, _ids(2), NO);

        vm.prank(carol);
        votes.castBallot(proposalId, _range(2, 2), NO);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes, 0, "both keys left Yes");
        assertEq(stored.no, 2, "and hold one No each");
        assertEq(_d(votes, proposalId), 3, "D is unchanged: key 2 was included, key 3 already joined");
        assertTrue(votes.wasActiveAtOpening(proposalId, 2), "key 2 stays in the opening electorate");
    }

    /// @dev Invariant: renewing a key changes no open proposal: D moves only by a ballot.
    function test_presentAloneLeavesAnOpenElectorateUnchanged() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 4);
        uint256 proposalId = _propose(votes);
        _present(votes, _range(2, 3));
        assertEq(_d(votes, proposalId), 1, "three keys renewed, none joined");
        assertEq(_propose(votes), 2);
        assertEq(_d(votes, 2), 4, "they count for the next proposal");
    }

    /// @dev Invariant: repeating a ballot changes no tally, though it renews the key.
    function test_repeatingABallotChangesNothingButRenewsTheKey() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 2);
        uint256 proposalId = _propose(votes);
        _ballot(votes, proposalId, 2, YES);
        vm.warp(block.timestamp + 1 hours);
        _ballot(votes, proposalId, 2, YES);

        uint256[] memory twice = new uint256[](2);
        (twice[0], twice[1]) = (2, 2);
        vm.prank(_wallet(2));
        votes.castBallot(proposalId, twice, YES);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes, 1, "one key, one Yes");
        assertEq(stored.late, 1);
        assertEq(votes.lastActiveAt(2), uint64(block.timestamp), "renewed by the repeat");
    }

    /// @dev Invariant: from closing on, no ballot is accepted, late or not, and none on a cancelled
    /// proposal; a ballot is Yes, No or Abstain and names at least one key.
    function test_noBallotAfterClosingOrCancelling() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        uint256 proposalId = _propose(votes);
        uint256 cancelled = _propose(votes);

        vm.startPrank(_wallet(2));
        vm.expectRevert(KeyfleetVotes.InvalidChoice.selector);
        votes.castBallot(proposalId, _ids(2), KeyfleetVotes.Choice.None);
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.castBallot(proposalId, new uint256[](0), YES);
        vm.stopPrank();

        vm.prank(_wallet(1));
        votes.cancel(cancelled);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.BallotsClosed.selector, cancelled));
        votes.castBallot(cancelled, _ids(2), YES);

        _closeOf(votes, proposalId);
        vm.prank(_wallet(3));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.BallotsClosed.selector, proposalId));
        votes.castBallot(proposalId, _ids(3), YES);
        assertEq(_d(votes, proposalId), 1);
    }

    /// @dev The spec's §6 example table, row by row, on one fleet of twelve keys.
    function test_theSpecExampleTable() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 12);
        uint256 t0 = block.timestamp;

        // Row 1: D=1, Yes=1 passes at the deadline.
        uint256 single = _propose(votes);
        _ballot(votes, single, 1, YES);

        // Row 2: D=4, Yes=2, No=0, Abstain=2 fails.
        _present(votes, _range(2, 3));
        uint256 four = _propose(votes);
        _ballots(votes, four, 1, 2, YES);
        _ballots(votes, four, 3, 2, ABSTAIN);

        // Row 3: D=9, Yes=5 meets the threshold but cannot be carried out early. Keys 1 and 2
        // vote at the opening; keys 3 to 5 an hour later.
        _present(votes, _range(5, 5));
        vm.prank(_wallet(1));
        uint256 nine = votes.propose(1, bytes32(0), uint64(t0 + 48 hours), _noCalls());
        _ballots(votes, nine, 1, 2, YES);
        vm.warp(t0 + 1 hours);
        _ballots(votes, nine, 3, 3, YES);
        assertEq(_d(votes, nine), 9);
        assertGt(votes.proposal(nine).yes, _d(votes, nine) / 2, "5 of 9 meets the threshold now");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(nine, _noCalls());

        // Row 4: two dormant keys vote No: D=11, Yes=5 does not meet the threshold.
        vm.warp(t0 + 2 hours);
        _ballots(votes, nine, 10, 2, NO);
        assertEq(_d(votes, nine), 11);
        assertEq(votes.proposal(nine).yes, 5);

        vm.warp(t0 + 1 days);
        assertEq(uint256(_status(votes, single)), uint256(KeyfleetVotes.Status.Approved), "row 1 passed");
        assertEq(uint256(_status(votes, four)), uint256(KeyfleetVotes.Status.Rejected), "row 2 failed");

        // Row 5: six included keys expire (1, 2 and 6 to 9, renewed at t0); D stays 11.
        vm.warp(t0 + 48 hours);
        (uint256 removed,) = votes.sweepExpired(100);
        assertEq(removed, 6, "six included keys expired");
        assertEq(_d(votes, nine), 11, "D stays 11");
        assertEq(uint256(_status(votes, nine)), uint256(KeyfleetVotes.Status.Rejected), "5 of 11 fails");

        // Row 6: the next proposal opens with one active key and has D=1; the old one keeps 11.
        vm.warp(t0 + 51 hours);
        uint256 next = _propose(votes, 12, _noCalls());
        assertEq(_d(votes, next), 1, "a new proposal can have D = 1");
        assertEq(_d(votes, nine), 11, "the old one does not shrink");
    }

    // --- 4. who may vote ----------------------------------------------------

    /// @dev Invariant: an owner and their key's agent share the one slot each key has. Either may
    /// replace its ballot, whoever acted last decides it, and an agent whose shard ended loses
    /// authority at once.
    function test_anOwnerAndTheirAgentShareOneSlotPerKey() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        for (uint256 i = 0; i < 3; ++i) {
            _buy(fleet, carol);
        }
        vm.startPrank(carol);
        fleet.SHARDS().issue(_range(1, 3), bob, 30);
        vm.stopPrank();
        uint256 proposalId = _propose(votes);

        vm.prank(bob);
        votes.castBallot(proposalId, _ids(1), YES);
        vm.prank(carol);
        votes.castBallot(proposalId, _ids(1), NO);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yes + stored.no, 1, "one key, one slot, whoever cast it");
        assertEq(stored.no, 1, "the owner acted last");

        vm.startPrank(carol);
        fleet.SHARDS().end(_ids(2), bob);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, bob));
        votes.castBallot(proposalId, _ids(2), YES);
    }

    /// @dev Invariant: the owner's agent-voting switch decides whether a key's agent may cast
    /// ballots, propose or cancel; renewing stays open to the agent either way. A new owner starts
    /// with it on.
    function test_agentVotingOffStopsTheAgentVotingButNotRenewing() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        vm.startPrank(_wallet(2));
        fleet.SHARDS().issue(_ids(2), bob, 30);
        vm.stopPrank();
        vm.prank(bob);
        uint256 authored = votes.propose(2, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        uint256 proposalId = _propose(votes);
        vm.prank(bob);
        votes.castBallot(proposalId, _ids(2), YES);

        vm.startPrank(_wallet(2));
        fleet.SHARDS().setAgentVoting(_ids(2), false);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, bob));
        votes.castBallot(proposalId, _ids(2), NO);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, bob));
        votes.propose(2, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, bob));
        votes.cancel(authored);
        votes.present(_ids(2));
        vm.stopPrank();
        assertEq(votes.proposal(proposalId).yes, 1, "the agent's earlier ballot stands");

        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), carol, 2);
        vm.startPrank(carol);
        fleet.SHARDS().issue(_ids(2), bob, 30);
        vm.stopPrank();
        vm.prank(bob);
        votes.castBallot(proposalId, _ids(2), NO);
        assertEq(votes.proposal(proposalId).no, 1, "the new owner's agent votes with no switch");
    }

    /// @dev Invariant: an agent holding shards of many keys, from several owners, votes them all in
    /// one call; a batch with one key it holds no shard of is refused whole.
    function test_anAgentVotesTheKeysOfManyOwnersInOneCall() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 4);
        for (uint256 tokenId = 1; tokenId <= 3; ++tokenId) {
            vm.startPrank(_wallet(tokenId));
            fleet.SHARDS().issue(_ids(tokenId), bob, 30);
            vm.stopPrank();
        }
        uint256 proposalId = _propose(votes);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 4, bob));
        votes.castBallot(proposalId, _range(1, 4), YES);
        assertEq(votes.proposal(proposalId).yes, 0, "nothing before the failure");

        uint256[] memory three = _range(1, 3);
        vm.expectEmit(true, true, true, true, address(votes));
        emit BallotCast(proposalId, bob, ABSTAIN, three);
        vm.prank(bob);
        votes.castBallot(proposalId, three, ABSTAIN);
        assertEq(votes.proposal(proposalId).abstain, 3, "three owners' keys, one call");
    }

    /// @dev Invariant: a marketplace approval is not delegation. An address approved for one key or
    /// for all of an owner's keys may move them but cannot renew, vote, propose or cancel with them.
    function test_aMarketplaceApprovalIsNotDelegation() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 1);
        _buy(fleet, _wallet(1)); // key 2
        uint256 proposalId = _propose(votes);
        vm.startPrank(_wallet(1));
        fleet.approve(mallory, 1);
        fleet.setApprovalForAll(mallory, true);
        vm.stopPrank();

        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.present(_ids(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.castBallot(proposalId, _ids(1), YES);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, mallory));
        votes.propose(2, bytes32(0), uint64(block.timestamp + 1 days), _noCalls());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.cancel(proposalId);
        vm.stopPrank();
    }

    // --- 5. cancelling -------------------------------------------------------

    /// @dev Invariant: whoever may vote the author key now cancels, while the proposal is open or
    /// approved, renewing that key; nobody else can, and nothing closed can be cancelled.
    function test_theAuthorKeyCancelsWhileOpenOrApproved() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 2);
        uint256 open = _propose(votes);
        uint256 approved = _propose(votes);
        _ballot(votes, approved, 1, YES);
        uint256 rejected = _propose(votes);

        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(2)));
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
        fleet.transferFrom(_wallet(1), carol, 1);
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.cancel(approved);
        vm.prank(carol);
        votes.cancel(approved);
        assertTrue(votes.isActive(1), "cancelling renewed the author key under its new owner");
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
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        KeyfleetTreasury.Call[] memory calls = _restrict(votes, 3, true);
        uint256 proposalId = _propose(votes, 1, calls);
        _ballot(votes, proposalId, 1, YES);
        _closeOf(votes, proposalId);
        uint64 renewedAt = votes.lastActiveAt(1);

        vm.expectEmit(true, true, true, true, address(votes));
        emit EditsRestrictionSet(3, true);
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, mallory);
        vm.prank(mallory);
        votes.execute(proposalId, calls);

        assertTrue(votes.editsRestricted(3));
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Executed));
        assertEq(votes.lastActiveAt(1), renewedAt, "carrying out renewed nobody");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Executed));
        votes.execute(proposalId, calls);
    }

    /// @dev Invariant: the calls must be exactly the proposal's: a changed target, value, data or
    /// order, a dropped call or an extra one is refused.
    function test_changedCallsAreRefused() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _restrict(votes, 2, true)[0];
        calls[1] = _restrict(votes, 3, true)[0];
        uint256 proposalId = _propose(votes, 1, calls);
        _ballot(votes, proposalId, 1, YES);
        _closeOf(votes, proposalId);

        KeyfleetTreasury.Call[][] memory changed = new KeyfleetTreasury.Call[][](6);
        for (uint256 i = 0; i < 4; ++i) {
            changed[i] = new KeyfleetTreasury.Call[](2);
            changed[i][0] = _restrict(votes, 2, true)[0];
            changed[i][1] = _restrict(votes, 3, true)[0];
        }
        changed[0][0].target = address(fleet);
        changed[1][0].value = 1;
        changed[2][1].data = abi.encodeCall(votes.setEditsRestricted, (3, false));
        (changed[3][0], changed[3][1]) = (calls[1], calls[0]);
        changed[4] = _restrict(votes, 2, true);
        changed[5] = new KeyfleetTreasury.Call[](3);
        (changed[5][0], changed[5][1], changed[5][2]) = (calls[0], calls[1], calls[1]);
        for (uint256 i = 0; i < changed.length; ++i) {
            vm.expectRevert(KeyfleetVotes.ActionsMismatch.selector);
            votes.execute(proposalId, changed[i]);
        }
        votes.execute(proposalId, calls);
        assertTrue(votes.editsRestricted(2) && votes.editsRestricted(3));
    }

    /// @dev Invariant: a batch whose call reverts reverts whole, with the call's reason, and the
    /// proposal stays approved and can be retried until its execution expiry, never after.
    function test_aFailedBatchCanBeRetriedUntilItExpires() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        MockSwitch target = new MockSwitch();
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _restrict(votes, 3, true)[0];
        calls[1] = KeyfleetTreasury.Call(address(target), 0, abi.encodeCall(target.ping, ()));
        uint256 proposalId = _propose(votes, 1, calls);
        uint256 expiring = _propose(votes, 1, calls);
        _ballot(votes, proposalId, 1, YES);
        _ballot(votes, expiring, 1, YES);
        _closeOf(votes, proposalId);

        vm.expectRevert(MockSwitch.Failing.selector);
        votes.execute(proposalId, calls);
        assertFalse(votes.editsRestricted(3), "the first call was undone with the batch");
        assertEq(uint256(_status(votes, proposalId)), uint256(KeyfleetVotes.Status.Approved), "still approved");

        target.setFailing(false);
        votes.execute(proposalId, calls);
        assertEq(target.pings(), 1);
        assertTrue(votes.editsRestricted(3));

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
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 3);
        KeyfleetTreasury.Call[] memory inner = _restrict(votes, 2, true);
        uint256 innerId = _propose(votes, 1, inner);
        KeyfleetTreasury.Call[] memory outer = new KeyfleetTreasury.Call[](1);
        outer[0] = KeyfleetTreasury.Call(address(votes), 0, abi.encodeCall(votes.execute, (innerId, inner)));
        uint256 outerId = _propose(votes, 1, outer);
        _ballot(votes, innerId, 1, YES);
        _ballot(votes, outerId, 1, YES);
        _closeOf(votes, outerId);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        votes.execute(outerId, outer);
        assertEq(uint256(_status(votes, innerId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(uint256(_status(votes, outerId)), uint256(KeyfleetVotes.Status.Approved));
    }

    /// @dev Invariant: only the treasury sets a key's edit restriction, and only for a key already
    /// sold; only the voting controller hands the treasury calls.
    function test_onlyACarriedOutProposalReachesTheTreasuryAndTheRestriction() public {
        (Keyfleet fleet, KeyfleetVotes votes) = _classic();
        _buyMany(fleet, 1);
        KeyfleetTreasury treasury = fleet.TREASURY();

        vm.prank(_wallet(1));
        vm.expectRevert(KeyfleetVotes.OnlyTreasury.selector);
        votes.setEditsRestricted(1, true);
        vm.prank(_wallet(1));
        vm.expectRevert(KeyfleetTreasury.OnlyVotes.selector);
        treasury.executeBatch(_restrict(votes, 1, true));

        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotMinted.selector, 2));
        votes.setEditsRestricted(2, true);

        uint256 proposalId = _propose(votes, 1, _restrict(votes, 1, true));
        _ballot(votes, proposalId, 1, YES);
        _closeOf(votes, proposalId);
        votes.execute(proposalId, _restrict(votes, 1, true));
        uint256 lift = _propose(votes, 1, _restrict(votes, 1, false));
        _ballot(votes, lift, 1, YES);
        _closeOf(votes, lift);
        votes.execute(lift, _restrict(votes, 1, false));
        assertFalse(votes.editsRestricted(1), "a later proposal lifts it");
    }

    // --- 7. gas -------------------------------------------------------------

    /// @dev Invariant: casting ballots is the one call whose cost grows with what it is asked, and
    /// only with the number of keys named, never with the fleet. Each first ballot costs the slot,
    /// the authority check, the look-up of the key at opening and the key's renewal, and the preset
    /// makes no difference. It is measured for the dearer caller, an agent through its shards.
    function test_ballotsCostAFixedAmountPerKeyNamed() public {
        Keyfleet flat = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        for (uint256 i = 0; i < 40; ++i) {
            _buy(flat, _wallet(1));
        }
        vm.startPrank(_wallet(1));
        flat.SHARDS().issue(_range(1, 40), bob, 30);
        vm.stopPrank();
        uint256 flatTen = _measureBallot(flat.VOTES(), bob, 2, 10);
        uint256 flatPerKey = (_measureBallot(flat.VOTES(), bob, 12, 29) - flatTen) / 19;

        // One agent for ten Fibonacci keys across three levels: each owner issues Bob a shard, which
        // is also the only way a single call can name keys the holding limit spreads over wallets.
        Keyfleet levelled = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buyMany(levelled, 10);
        for (uint256 i = 1; i <= 10; ++i) {
            vm.startPrank(_wallet(i));
            levelled.SHARDS().issue(_ids(i), bob, 30);
            vm.stopPrank();
        }
        uint256 levelledTwo = _measureBallot(levelled.VOTES(), bob, 2, 2);
        uint256 levelledPerKey = (_measureBallot(levelled.VOTES(), bob, 4, 6) - levelledTwo) / 4;

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
    function _measureBallot(KeyfleetVotes votes, address caster, uint256 firstTokenId, uint256 count)
        private
        returns (uint256 used)
    {
        uint256 proposalId = _propose(votes);
        uint256[] memory tokenIds = _range(firstTokenId, count);
        vm.prank(caster);
        uint256 before = gasleft();
        votes.castBallot(proposalId, tokenIds, YES);
        used = before - gasleft();
    }
}
