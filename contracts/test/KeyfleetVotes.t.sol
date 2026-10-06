// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";

contract KeyfleetVotesTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";
    /// @dev Measured cost of voting ten Classic keys in one call, plus a fifth, rounded up.
    uint256 private constant TEN_KEY_VOTE_CEILING = 1_199_000;
    /// @dev Measured marginal cost of one more key in a vote, plus a fifth, rounded up.
    uint256 private constant PER_KEY_VOTE_CEILING = 117_000;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    address private buyer = address(0xB0B0B0);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);
    address private mallory = address(0x4A11);

    event ProposalCreated(
        uint256 indexed proposalId,
        KeyfleetVotes.Kind indexed kind,
        address indexed proposer,
        uint48 openRevision,
        uint64 openedAt,
        uint32 e0,
        bytes32 digest,
        string text
    );
    event VotingDelegateSet(address indexed owner, address indexed delegate);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);
    event VoteWithdrawn(uint256 indexed proposalId, address indexed caller, uint256[] tokenIds);
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);
    event RestrictEditsProposed(uint256 indexed proposalId, uint256 indexed targetTokenId, bool restricted);
    event EditsRestrictionSet(uint256 indexed targetTokenId, bool restricted, uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

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
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    /// @dev A fleet's randomness: the mock coordinator and the suite's subscription.
    function _randomness() private view returns (Keyfleet.Randomness memory) {
        return Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)),
            subscriptionId: vrfSubscription,
            keyHash: keccak256("key hash")
        });
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
    /// level 8. Key `i` therefore belongs to `_wallet(i)` throughout this suite.
    function _buyMany(Keyfleet fleet, uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
    }

    function _wallet(uint256 index) private pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    /// @dev Renews key `tokenId` as its current owner.
    function _present(KeyfleetVotes votes, uint256 tokenId) private {
        vm.prank(votes.FLEET().ownerOf(tokenId));
        votes.present(_ids(tokenId));
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

    /// @dev Votes one key as its current owner.
    function _vote(KeyfleetVotes votes, uint256 proposalId, uint256 tokenId, bool support) private {
        vm.prank(votes.FLEET().ownerOf(tokenId));
        votes.vote(proposalId, _ids(tokenId), support);
    }

    /// @dev Creates a Decision from the owner of key 1.
    function _propose(KeyfleetVotes votes) private returns (uint256 proposalId) {
        vm.prank(votes.FLEET().ownerOf(1));
        proposalId = votes.proposeDecision(1, "record it", bytes32(0));
    }

    function _state(KeyfleetVotes votes, uint256 proposalId) private view returns (uint256) {
        return uint256(votes.state(proposalId));
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet and its voting controller are bound to each other, so no deployment
    /// step can leave a fleet taking orders from someone else's vote, and no second controller can
    /// bind to it.
    function test_constructorDeploysAndBindsItsOwnVotingController() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();

        assertEq(address(votes.FLEET()), address(fleet), "the controller is bound to this fleet");
        assertEq(votes.proposalCount(), 0, "no proposal exists yet");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.WrongFleet.selector, address(fleet)));
        new KeyfleetVotes(fleet);
    }

    // --- 2. one vote per key ---------------------------------------------

    /// @dev Invariant: every key is one vote on every preset, whatever its level. A Fibonacci
    /// level-1 key and a level-3 key each add exactly one.
    function test_everyKeyIsOneVoteOnEveryPreset() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];
        for (uint256 i = 0; i < presets.length; ++i) {
            Keyfleet fleet = _deploy(presets[i]);
            KeyfleetVotes votes = fleet.VOTES();
            _buyMany(fleet, 10);
            uint256 proposalId = _propose(votes);

            _vote(votes, proposalId, 1, true);
            _vote(votes, proposalId, 10, false);
            KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
            assertEq(stored.yesVotes, 1, "the first key is one vote");
            assertEq(stored.noVotes, 1, "and so is the tenth, whatever its level");
        }
    }

    // --- 3. proposals -----------------------------------------------------

    /// @dev Invariant: a proposal records its opening revision, its opening time and the exact count
    /// of present keys, renewing the proposer's key first, and stores its digest but not its text.
    function test_aProposalRecordsItsOpening() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        _present(votes, 2);

        bytes32 digest = keccak256("base..head");
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(
            1, KeyfleetVotes.Kind.Decision, _wallet(1), 3, uint64(block.timestamp), 2, digest, "merge the branch"
        );
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeDecision(1, "merge the branch", digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(proposalId, 1, "proposal ids start at one");
        assertEq(votes.proposalCount(), 1);
        assertEq(uint256(stored.kind), uint256(KeyfleetVotes.Kind.Decision));
        assertEq(stored.proposer, _wallet(1));
        assertEq(stored.openRevision, 3, "key 2's renewal, the proposer's renewal, then the opening");
        assertEq(stored.openedAt, uint64(block.timestamp));
        assertEq(stored.e0, 2, "key 2 and the proposer's own key were present");
        assertTrue(votes.wasActiveAtOpening(proposalId, 1), "the proposer's key was present");
        assertFalse(votes.wasActiveAtOpening(proposalId, 3), "a key nobody renewed was not");
        assertEq(stored.digest, digest, "the digest is stored, the text is not");
        assertFalse(stored.executed);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open));
    }

    /// @dev Invariant: proposing needs standing. The proposer names a key and must be its owner or
    /// that owner's registered delegate, which is the same authorization voting applies. Standing is
    /// not a vote.
    function test_proposingRequiresAKeyTheCallerMayVote() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 2);

        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        votes.proposeDecision(0, "no key at all", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 3));
        votes.proposeDecision(3, "a key nobody has bought", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.proposeDecision(1, "somebody else's key", bytes32(0));
        vm.stopPrank();

        vm.prank(_wallet(1));
        votes.setVotingDelegate(carol);
        vm.prank(carol);
        uint256 proposalId = votes.proposeDecision(1, "the delegate may propose", bytes32(0));
        assertEq(votes.proposal(proposalId).proposer, carol, "the delegate is the proposer");
        assertEq(uint256(votes.voteOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.None), "standing is not a vote");
    }

    /// @dev Invariant: every entry point refuses an id that names no proposal, so a mistyped id can
    /// never be read or voted as if it were an empty proposal.
    function test_anUnknownProposalIsRefusedEverywhere() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        _propose(votes);

        uint256[2] memory unknown = [uint256(0), 2];
        for (uint256 i = 0; i < unknown.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.state(unknown[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.proposal(unknown[i]);
            vm.prank(_wallet(1));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.vote(unknown[i], _ids(1), true);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.execute(unknown[i]);
        }
    }

    /// @dev Invariant: proposing has no per-key limit: one key can open any number of proposals.
    function test_oneKeyMayOpenAnyNumberOfProposals() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        vm.startPrank(_wallet(1));
        for (uint256 i = 0; i < 50; ++i) {
            votes.proposeDecision(1, "one more", bytes32(0));
        }
        vm.stopPrank();
        assertEq(votes.proposalCount(), 50, "fifty proposals from one key");
    }

    // --- 4. who may vote ----------------------------------------------------

    /// @dev Invariant: every key sold counts in the approval rule, so a later sale can take an
    /// approved proposal back to open, and a key bought after the proposal opened may vote on it.
    function test_keysBoughtAfterAProposalOpensCountAndMayVote() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);

        uint256 proposalId = _propose(votes);
        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "two of three keys");

        _buyMany(fleet, 2);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "two of five keys is not more than half");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 2, 5));
        votes.execute(proposalId);

        _vote(votes, proposalId, 4, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "three of five keys");
        votes.execute(proposalId);
    }

    /// @dev Invariant: a key has one vote per proposal whoever holds it. A key that moves keeps the
    /// vote it had, its new holder may change it, and moving it back and forth never adds a vote.
    function test_aKeyThatMovesKeepsItsOneVoteAndItsNewHolderMayChangeIt() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        for (uint256 i = 0; i < 4; ++i) {
            _buy(fleet, carol);
        }
        _buyMany(fleet, 6);

        uint256 proposalId = _propose(votes);
        vm.prank(carol);
        votes.vote(proposalId, _ids(1), true);

        vm.startPrank(carol);
        for (uint256 tokenId = 1; tokenId <= 4; ++tokenId) {
            fleet.transferFrom(carol, dave, tokenId);
        }
        vm.stopPrank();

        vm.startPrank(dave);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, 1));
        votes.vote(proposalId, _ids(1), true);
        votes.vote(proposalId, _ids(1), false);
        for (uint256 tokenId = 1; tokenId <= 4; ++tokenId) {
            fleet.transferFrom(dave, carol, tokenId);
        }
        vm.stopPrank();

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 0, "the vote moved off YES");
        assertEq(stored.noVotes, 1, "key 1 still has exactly one vote");
        assertEq(uint256(votes.voteOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.No));
    }

    /// @dev Invariant: a key may change its vote until the proposal is carried out, and each key is
    /// counted once, on the side it is on now. Asking for the vote a key already has is refused, and
    /// nothing can be voted once the proposal has been carried out.
    function test_aKeyMayChangeItsVoteUntilTheProposalIsCarriedOut() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        uint256 proposalId = _propose(votes);

        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved));

        _vote(votes, proposalId, 2, false);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 1, "the changed key left the YES side");
        assertEq(stored.noVotes, 1, "and joined the NO side");
        assertEq(uint256(votes.voteOf(proposalId, 2)), uint256(KeyfleetVotes.Choice.No));
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "a change can take approval away");

        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, 2));
        votes.vote(proposalId, _ids(2), false);

        _vote(votes, proposalId, 2, true);
        _vote(votes, proposalId, 3, false);
        stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 2);
        assertEq(stored.noVotes, 1);

        votes.execute(proposalId);
        vm.prank(_wallet(3));
        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.vote(proposalId, _ids(3), true);
    }

    /// @dev Invariant: whoever holds a key now, or their delegate, may withdraw the vote it carries,
    /// whoever cast it. Keys borrowed, voted and handed back do not bind their owners: each owner
    /// takes the borrowed vote back, and the proposal loses the approval those votes gave it.
    function test_whoeverHoldsAKeyNowMayWithdrawItsVote() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 10);
        for (uint256 tokenId = 1; tokenId <= 6; ++tokenId) {
            vm.prank(_wallet(tokenId));
            fleet.transferFrom(_wallet(tokenId), mallory, tokenId);
        }
        uint256 proposalId = _propose(votes);
        vm.startPrank(mallory);
        votes.vote(proposalId, _range(1, 6), true);
        for (uint256 tokenId = 1; tokenId <= 6; ++tokenId) {
            fleet.transferFrom(mallory, _wallet(tokenId), tokenId);
        }
        vm.stopPrank();
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "the borrowed votes approve it");

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.withdrawVote(proposalId, _ids(1));

        vm.expectEmit(true, true, true, true, address(votes));
        emit VoteWithdrawn(proposalId, _wallet(1), _ids(1));
        vm.prank(_wallet(1));
        votes.withdrawVote(proposalId, _ids(1));
        assertEq(uint256(votes.voteOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.None), "key 1 has no vote");
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "five of ten is not more than half");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 5, 10));
        votes.execute(proposalId);

        vm.prank(_wallet(2));
        votes.setVotingDelegate(bob);
        vm.prank(bob);
        votes.withdrawVote(proposalId, _ids(2));

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 4, "a delegate withdraws for the holder too");
        assertEq(stored.noVotes, 0);
    }

    /// @dev Invariant: withdrawing takes a key's vote off whichever side it is on, needs a key the
    /// caller may vote that has a vote, and ends when the proposal is carried out. Any refused id
    /// reverts the whole call, and a key may vote again after withdrawing.
    function test_withdrawingTakesAVoteOffItsSideUntilTheProposalIsCarriedOut() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        uint256 proposalId = _propose(votes);
        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);
        _vote(votes, proposalId, 3, false);

        vm.startPrank(_wallet(3));
        votes.withdrawVote(proposalId, _ids(3));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NoVote.selector, 3));
        votes.withdrawVote(proposalId, _ids(3));
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.withdrawVote(proposalId, new uint256[](0));
        vm.stopPrank();
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 2);
        assertEq(stored.noVotes, 0, "the NO came off the NO side");

        uint256[] memory twice = new uint256[](2);
        (twice[0], twice[1]) = (2, 2);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NoVote.selector, 2));
        votes.withdrawVote(proposalId, twice);
        assertEq(votes.proposal(proposalId).yesVotes, 2, "the refused call withdrew nothing");

        _vote(votes, proposalId, 3, true);
        assertEq(votes.proposal(proposalId).yesVotes, 3, "a withdrawn key votes again");

        votes.execute(proposalId);
        vm.prank(_wallet(1));
        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.withdrawVote(proposalId, _ids(1));
    }

    /// @dev Invariant: an owner and their delegate share the one vote each key has. Either may set
    /// or change it, whoever acted last decides it, and the tallies count the key once either way.
    /// A delegate the owner replaced loses authority at once, and one id named twice in a call is
    /// refused.
    function test_anOwnerAndTheirDelegateShareOneVotePerKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        for (uint256 i = 0; i < 3; ++i) {
            _buy(fleet, carol);
        }
        vm.prank(carol);
        votes.setVotingDelegate(bob);
        uint256 proposalId = _propose(votes);

        vm.prank(bob);
        votes.vote(proposalId, _ids(1), true);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, 1));
        votes.vote(proposalId, _ids(1), true);
        vm.prank(carol);
        votes.vote(proposalId, _ids(1), false);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes + stored.noVotes, 1, "one key, one vote, whoever cast it");
        assertEq(stored.noVotes, 1, "the owner acted last");

        vm.prank(carol);
        votes.setVotingDelegate(dave);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, carol));
        votes.vote(proposalId, _ids(2), true);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, 1));
        votes.vote(proposalId, _ids(1), false);

        uint256[] memory twice = new uint256[](2);
        (twice[0], twice[1]) = (2, 2);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, 2));
        votes.vote(proposalId, twice, true);
    }

    /// @dev Invariant: financial authority is registered on chain and nowhere else. A delegate the
    /// owner named may vote their keys; once the owner clears it, that address is a stranger again.
    /// Nothing here moves a key, a reward or the owner's own right to vote.
    function test_aRegisteredDelegateMayVoteAndAClearedOneMayNot() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 4);

        uint256 first = _propose(votes);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.vote(first, _ids(1), true);

        vm.expectEmit(true, true, true, true, address(votes));
        emit VotingDelegateSet(_wallet(1), bob);
        vm.prank(_wallet(1));
        votes.setVotingDelegate(bob);
        assertEq(votes.votingDelegate(_wallet(1)), bob);

        vm.prank(bob);
        votes.vote(first, _ids(1), true);
        assertEq(votes.proposal(first).yesVotes, 1, "the delegate voted the owner's key");
        assertEq(fleet.ownerOf(1), _wallet(1), "and the key never moved");

        // The owner keeps their own vote on their other keys.
        vm.prank(_wallet(2));
        votes.setVotingDelegate(bob);
        vm.prank(_wallet(2));
        votes.vote(first, _ids(2), true);

        uint256 second = _propose(votes);
        vm.prank(_wallet(1));
        votes.setVotingDelegate(address(0));
        assertEq(votes.votingDelegate(_wallet(1)), address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.vote(second, _ids(1), true);
        vm.prank(bob);
        votes.vote(second, _ids(2), true);
    }

    /// @dev Invariant: delegation runs one way only. Registering somebody as your own delegate
    /// gives you nothing over their keys, so a stranger cannot point a delegation at a holder and
    /// vote that holder's keys with it. The holder, who really is the stranger's delegate, may vote
    /// the stranger's key, and that authority does not reach back the other way.
    function test_delegationRunsOneWayOnly() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 2);

        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), mallory, 2);
        vm.prank(mallory);
        votes.setVotingDelegate(_wallet(1));

        uint256 proposalId = _propose(votes);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.vote(proposalId, _ids(1), true);

        vm.prank(_wallet(1));
        votes.vote(proposalId, _ids(2), true);
        assertEq(votes.proposal(proposalId).yesVotes, 1, "exactly one key's vote moved");
        assertEq(
            uint256(votes.voteOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.None), "the holder's key is untouched"
        );
    }

    /// @dev Invariant: a vote names at least one key. An empty set would otherwise record a voter
    /// who moved no vote at all.
    function test_aVoteMustNameAtLeastOneKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        uint256 proposalId = _propose(votes);

        vm.prank(_wallet(1));
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.vote(proposalId, new uint256[](0), true);
    }

    /// @dev Invariant: a set of keys is voted whole or not at all, so a holder cannot half-vote a
    /// batch because one id in it belongs to somebody else.
    function test_aBatchOfKeysIsVotedWholeOrNotAtAll() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), _wallet(1), 2);
        uint256 proposalId = _propose(votes);

        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 3, _wallet(3)));
        votes.vote(proposalId, _range(1, 3), true);
        assertEq(uint256(votes.voteOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.None), "nothing before the failure");
        assertEq(votes.proposal(proposalId).yesVotes, 0);

        uint256[] memory pair = _range(1, 2);
        vm.expectEmit(true, true, true, true, address(votes));
        emit VoteCast(proposalId, _wallet(1), true, pair);
        vm.prank(_wallet(1));
        votes.vote(proposalId, pair, true);
        assertEq(votes.proposal(proposalId).yesVotes, 2, "both keys counted once");
    }

    // --- 5. the approval rule -----------------------------------------------

    /// @dev Invariant: YES must be more than half of all the keys sold so far, not half of the keys
    /// that bothered to vote. Exactly half is not enough, one key more is, and a key that stayed
    /// silent counts against the proposal just as a NO would. On a Fibonacci fleet the early levels
    /// get no extra say: level 1's two keys are two votes out of five.
    function test_yesMustBeMoreThanHalfOfAllTheKeysSold() public {
        // Exactly half: one of two Classic keys.
        Keyfleet even = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes evenVotes = even.VOTES();
        _buyMany(even, 2);
        uint256 tied = _propose(evenVotes);
        _vote(evenVotes, tied, 1, true);
        assertEq(_state(evenVotes, tied), uint256(KeyfleetVotes.State.Open));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 1, 2));
        evenVotes.execute(tied);

        // Silence is not neutral: one YES out of three keys, with nobody voting NO, is not enough.
        Keyfleet quiet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes quietVotes = quiet.VOTES();
        _buyMany(quiet, 3);
        uint256 abstained = _propose(quietVotes);
        _vote(quietVotes, abstained, 1, true);
        assertEq(quietVotes.proposal(abstained).noVotes, 0, "nobody voted against it");
        assertEq(_state(quietVotes, abstained), uint256(KeyfleetVotes.State.Open), "and it is still not approved");

        // Fibonacci: all of level 1 is two keys of five, which is not a majority; one level-2 key
        // more is.
        Keyfleet fib = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes fibVotes = fib.VOTES();
        _buyMany(fib, 5);
        uint256 narrow = _propose(fibVotes);
        _vote(fibVotes, narrow, 1, true);
        _vote(fibVotes, narrow, 2, true);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 2, 5));
        fibVotes.execute(narrow);

        _vote(fibVotes, narrow, 5, true);
        assertEq(_state(fibVotes, narrow), uint256(KeyfleetVotes.State.Approved), "three keys of five");
        fibVotes.execute(narrow);
        assertEq(_state(fibVotes, narrow), uint256(KeyfleetVotes.State.Executed));
    }

    /// @dev Invariant: approval has no deadline. An approved proposal stays open, and can still be
    /// voted and carried out by anyone, however much later that is.
    function test_anApprovedProposalStaysOpenUntilSomeoneCarriesItOut() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        uint256 proposalId = _propose(votes);
        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);

        vm.warp(block.timestamp + 10 * 365 days);
        vm.roll(block.number + 10_000_000);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved));
        _vote(votes, proposalId, 3, false);

        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, mallory);
        vm.prank(mallory);
        votes.execute(proposalId);
    }

    /// @dev Invariant: an approved Decision records agreement and does nothing else. It is carried
    /// out once and cannot be carried out a second time by anyone.
    function test_anApprovedDecisionRecordsOnce() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        bytes32 digest = keccak256("commit");
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeDecision(1, "ship it", digest);
        _vote(votes, proposalId, 1, true);

        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, carol);
        vm.expectEmit(true, true, true, true, address(votes));
        emit DecisionRecorded(proposalId, digest);
        vm.prank(carol);
        votes.execute(proposalId);

        assertTrue(votes.proposal(proposalId).executed);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Executed));

        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.execute(proposalId);
    }

    // --- 6. restricting a key's edits ---------------------------------------

    /// @dev Proposes a RestrictEdits from the owner of key 1.
    function _proposeRestrict(KeyfleetVotes votes, uint256 target, bool restricted)
        private
        returns (uint256 proposalId)
    {
        vm.prank(votes.FLEET().ownerOf(1));
        proposalId = votes.proposeRestrictEdits(1, target, restricted, "stop the edits", bytes32(0));
    }

    /// @dev Invariant: a RestrictEdits proposal names a key and a direction, is kind 1, stores
    /// both and carries its reason in the creation event only.
    function test_aRestrictEditsProposalStoresItsKeyAndDirection() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);

        bytes32 digest = keccak256("edit log");
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(
            1, KeyfleetVotes.Kind.RestrictEdits, _wallet(1), 2, uint64(block.timestamp), 1, digest, "spam"
        );
        vm.expectEmit(true, true, true, true, address(votes));
        emit RestrictEditsProposed(1, 3, true);
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeRestrictEdits(1, 3, true, "spam", digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(uint256(stored.kind), 1, "RestrictEdits is kind 1");
        assertEq(stored.targetTokenId, 3);
        assertTrue(stored.restricted);
        assertEq(stored.digest, digest);
        assertFalse(votes.editsRestricted(3), "nothing is restricted until it is carried out");
    }

    /// @dev Invariant: a RestrictEdits needs YES from at least three fifths of all the keys sold,
    /// where a Decision needs more than half. With five keys two YES is 40% and fails, and three YES
    /// is exactly 60% and passes; carrying it out restricts the key and says so. A key sold
    /// afterwards counts against it, so three of six, 50%, takes it back to open.
    function test_restrictEditsNeedsThreeFifthsOfAllKeysSold() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 5);
        uint256 proposalId = _proposeRestrict(votes, 4, true);

        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "two of five is 40%");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 2, 5));
        votes.execute(proposalId);

        _vote(votes, proposalId, 3, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "three of five is exactly 60%");

        _buyMany(fleet, 1);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "three of six is 50%");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 3, 6));
        votes.execute(proposalId);

        // For comparison, a Decision with the same three YES of six keys is not approved either.
        uint256 decision = _propose(votes);
        _vote(votes, decision, 1, true);
        _vote(votes, decision, 2, true);
        _vote(votes, decision, 3, true);
        assertEq(_state(votes, decision), uint256(KeyfleetVotes.State.Open), "a Decision needs more than half too");

        _vote(votes, proposalId, 5, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "four of six is 66.7%");
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, mallory);
        vm.expectEmit(true, true, true, true, address(votes));
        emit EditsRestrictionSet(4, true, proposalId);
        vm.prank(mallory);
        votes.execute(proposalId);

        assertTrue(votes.editsRestricted(4), "key 4's edits are restricted");
        assertFalse(votes.editsRestricted(1), "and no other key's");
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Executed));
        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.execute(proposalId);
    }

    /// @dev Invariant: the three-fifths line is exact. Of a thousand keys, 599 YES is 59.9% and
    /// fails, and 600 YES is exactly 60% and passes.
    function test_restrictEditsFailsAtFiftyNinePointNinePercentAndPassesAtSixty() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        for (uint256 i = 0; i < 1000; ++i) {
            _buy(fleet, dave);
        }
        vm.prank(dave);
        uint256 proposalId = votes.proposeRestrictEdits(1, 1000, true, "", bytes32(0));

        vm.prank(dave);
        votes.vote(proposalId, _range(1, 599), true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "599 of 1000 is 59.9%");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 599, 1000));
        votes.execute(proposalId);

        vm.prank(dave);
        votes.vote(proposalId, _ids(600), true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "600 of 1000 is 60%");
        votes.execute(proposalId);
        assertTrue(votes.editsRestricted(1000));
    }

    /// @dev Invariant: a later RestrictEdits can lift a restriction by the same three-fifths vote,
    /// and the latest one carried out is what stands.
    function test_aRestrictionCanBeLiftedByALaterVote() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 5);

        uint256 restrict = _proposeRestrict(votes, 2, true);
        for (uint256 tokenId = 1; tokenId <= 3; ++tokenId) {
            _vote(votes, restrict, tokenId, true);
        }
        votes.execute(restrict);
        assertTrue(votes.editsRestricted(2));

        uint256 lift = _proposeRestrict(votes, 2, false);
        assertFalse(votes.proposal(lift).restricted, "the proposal unrestricts");
        for (uint256 tokenId = 3; tokenId <= 5; ++tokenId) {
            _vote(votes, lift, tokenId, true);
        }
        vm.expectEmit(true, true, true, true, address(votes));
        emit EditsRestrictionSet(2, false, lift);
        votes.execute(lift);
        assertFalse(votes.editsRestricted(2), "the restriction is lifted");
    }

    /// @dev Invariant: only a key already sold can be named, whoever owns it, including the
    /// proposer's own. Key zero and any key past the last one sold are refused before anything is
    /// created.
    function test_restrictEditsNamesOnlyAMintedKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);

        vm.startPrank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotMinted.selector, 0));
        votes.proposeRestrictEdits(1, 0, true, "", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotMinted.selector, 4));
        votes.proposeRestrictEdits(1, 4, true, "", bytes32(0));
        assertEq(votes.proposalCount(), 0, "nothing was created");

        votes.proposeRestrictEdits(1, 1, true, "my own key", bytes32(0));
        votes.proposeRestrictEdits(1, 3, true, "another holder's key", bytes32(0));
        vm.stopPrank();
        assertEq(votes.proposalCount(), 2);

        _buyMany(fleet, 1);
        vm.prank(_wallet(1));
        votes.proposeRestrictEdits(1, 4, true, "sold since", bytes32(0));
        assertEq(votes.proposal(3).targetTokenId, 4, "a key sold since can be named");
    }

    /// @dev Invariant: proposing a RestrictEdits takes the same standing as any proposal: the key's
    /// owner or the owner's voting delegate may, and nobody else.
    function test_aVotingDelegateMayProposeRestrictEdits() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.proposeRestrictEdits(1, 2, true, "", bytes32(0));

        vm.prank(_wallet(1));
        votes.setVotingDelegate(carol);
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(1, KeyfleetVotes.Kind.RestrictEdits, carol, 2, uint64(block.timestamp), 1, bytes32(0), "");
        vm.prank(carol);
        uint256 proposalId = votes.proposeRestrictEdits(1, 2, true, "", bytes32(0));
        assertEq(votes.proposal(proposalId).targetTokenId, 2, "the delegate proposed it");
    }

    // --- 7. gas -------------------------------------------------------------

    /// @dev Invariant: voting is the one call whose cost grows with what the caller asks of it, and
    /// it grows only with the number of keys named, never with the fleet. The per-key cost is the
    /// vote record, the ownership read and the key's renewal, and the preset makes no
    /// difference to it. A holder with more keys than one block can carry splits the vote across
    /// calls.
    function test_votingCostsAFixedAmountPerKeyNamed() public {
        Keyfleet flat = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        for (uint256 i = 0; i < 40; ++i) {
            _buy(flat, _wallet(1));
        }
        uint256 flatTen = _measureVote(flat.VOTES(), _wallet(1), 2, 10);
        uint256 flatPerKey = (_measureVote(flat.VOTES(), _wallet(1), 12, 29) - flatTen) / 19;

        // One caster for ten Fibonacci keys across three levels: each owner delegates to Bob, which
        // is also the only way a single call can name keys the holding limit spreads over wallets.
        Keyfleet levelled = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes levelledVotes = levelled.VOTES();
        _buyMany(levelled, 10);
        for (uint256 i = 1; i <= 10; ++i) {
            vm.prank(_wallet(i));
            levelledVotes.setVotingDelegate(bob);
        }
        uint256 levelledTwo = _measureVote(levelledVotes, bob, 2, 2);
        uint256 levelledPerKey = (_measureVote(levelledVotes, bob, 4, 6) - levelledTwo) / 4;

        console2.log("vote gas for ten Classic keys:", flatTen);
        console2.log("marginal vote gas per Classic key:", flatPerKey);
        console2.log("marginal vote gas per Fibonacci key:", levelledPerKey);

        assertLt(flatTen, TEN_KEY_VOTE_CEILING, "a ten-key vote stays under the published ceiling");
        assertLt(flatPerKey, PER_KEY_VOTE_CEILING, "each extra key costs a fixed amount");
        assertApproxEqAbs(levelledPerKey, flatPerKey, 500, "a Fibonacci key costs what a Classic key costs");
    }

    /// @dev Votes `count` consecutive ids from `firstTokenId` in one call and returns the gas used.
    /// Key 1 proposes, which renews it, so the measured ranges leave it out and every key they name
    /// is renewed for the first time.
    function _measureVote(KeyfleetVotes votes, address caster, uint256 firstTokenId, uint256 count)
        private
        returns (uint256 used)
    {
        uint256 proposalId = _propose(votes);
        uint256[] memory tokenIds = _range(firstTokenId, count);
        vm.prank(caster);
        uint256 before = gasleft();
        votes.vote(proposalId, tokenIds, true);
        used = before - gasleft();
    }

    // --- 8. fuzz invariant ---------------------------------------------------

    /// @dev Invariant: across random votes, changes of vote and withdrawals on a Fibonacci fleet
    /// spanning three levels, with keys still being sold, each side's tally is always exactly the number of keys
    /// whose current vote is on that side, and the two together never exceed the keys sold.
    function testFuzz_eachKeyCountsOnceOnTheSideItIsOnNow(uint256 seed) public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 10); // levels 1, 2 and 3.
        uint256 proposalId = _propose(votes);

        KeyfleetVotes.Choice[11] memory current;
        for (uint256 i = 0; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (seed % 5 == 0 && fleet.totalMinted() < 20) {
                _buyMany(fleet, 1); // a later sale: counted in the approval rule
                continue;
            }
            uint256 tokenId = ((seed >> 8) % 10) + 1;
            bool support = (seed >> 16) % 2 == 0;
            KeyfleetVotes.Choice choice = support ? KeyfleetVotes.Choice.Yes : KeyfleetVotes.Choice.No;

            vm.prank(fleet.ownerOf(tokenId));
            if (seed % 7 == 1) {
                if (current[tokenId] == KeyfleetVotes.Choice.None) {
                    vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NoVote.selector, tokenId));
                }
                votes.withdrawVote(proposalId, _ids(tokenId));
                current[tokenId] = KeyfleetVotes.Choice.None;
            } else if (current[tokenId] == choice) {
                vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, tokenId));
                votes.vote(proposalId, _ids(tokenId), support);
            } else {
                votes.vote(proposalId, _ids(tokenId), support);
                current[tokenId] = choice;
            }

            uint256 yes;
            uint256 no;
            for (uint256 k = 1; k <= 10; ++k) {
                if (current[k] == KeyfleetVotes.Choice.Yes) ++yes;
                if (current[k] == KeyfleetVotes.Choice.No) ++no;
                assertEq(
                    uint256(votes.voteOf(proposalId, k)), uint256(current[k]), "the stored vote is the last one cast"
                );
            }
            KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
            assertEq(stored.yesVotes, yes, "YES is exactly the keys now voting YES");
            assertEq(stored.noVotes, no, "NO is exactly the keys now voting NO");
            assertLe(stored.yesVotes + stored.noVotes, fleet.totalMinted(), "never more votes than keys sold");
        }
    }
}
