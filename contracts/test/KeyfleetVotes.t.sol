// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";

contract KeyfleetVotesTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";
    /// @dev Measured cost of voting ten Classic keys in one call, plus a fifth, rounded up.
    uint256 private constant TEN_KEY_VOTE_CEILING = 342_000;
    /// @dev Measured marginal cost of one more key in a vote, plus a fifth, rounded up.
    uint256 private constant PER_KEY_VOTE_CEILING = 31_000;

    MockToken private usdc;
    MockToken private regent;
    MockToken private other;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    /// @dev Purchases never call the staking contract, and these suites never send the owed share.
    IRegentRevenueStaking private staking = IRegentRevenueStaking(address(0x57A1));
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV1 private factory = IRegentsAutolaunchFactoryV1(address(0xFAC7));

    address private buyer = address(0xB0B0B0);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);
    address private mallory = address(0x4A11);

    event ProposalCreated(
        uint256 indexed proposalId,
        KeyfleetVotes.Kind indexed kind,
        address indexed proposer,
        uint64 openedBlock,
        bytes32 digest,
        string text
    );
    event VotingDelegateSet(address indexed owner, address indexed delegate);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);
    event VoteWithdrawn(uint256 indexed proposalId, address indexed caller, uint256[] tokenIds);
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        regent = new MockToken("Regent", "REGENT");
        other = new MockToken("Other", "OTH");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);
        vm.roll(1_000);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            IERC20(address(regent)),
            staking,
            factory,
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

    /// @dev Sends `amount` of `token`, which is not an income token, to the fleet and sorts it, so
    /// it becomes shared money.
    function _receiveSharedMoney(Keyfleet fleet, MockToken token, uint256 amount) private {
        token.mint(address(fleet), amount);
        fleet.recognizeSurplus(address(token));
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

    /// @dev Moves to the next block, so every key bought so far last moved before the proposal
    /// opens, then creates a Decision from the owner of key 1.
    function _propose(KeyfleetVotes votes) private returns (uint256 proposalId) {
        vm.roll(block.number + 1);
        vm.prank(votes.FLEET().ownerOf(1));
        proposalId = votes.proposeDecision(1, "record it", bytes32(0));
    }

    function _state(KeyfleetVotes votes, uint256 proposalId) private view returns (uint256) {
        return uint256(votes.state(proposalId));
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet and its voting controller are born together and correctly bound, so
    /// no deployment step can leave a fleet taking orders from someone else's vote.
    function test_constructorDeploysAndBindsItsOwnVotingController() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();

        assertEq(address(votes.FLEET()), address(fleet), "the controller is bound to this fleet");
        assertEq(votes.proposalCount(), 0, "no proposal exists yet");

        vm.expectRevert(KeyfleetVotes.ZeroAddress.selector);
        new KeyfleetVotes(Keyfleet(address(0)));
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

    /// @dev Invariant: a proposal records the block it opened in, which is the whole of what decides
    /// which keys may vote on it, and stores its digest but not its text.
    function test_aProposalRecordsTheBlockItOpenedIn() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        vm.roll(block.number + 1);

        bytes32 digest = keccak256("base..head");
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(
            1, KeyfleetVotes.Kind.Decision, _wallet(1), uint64(block.number), digest, "merge the branch"
        );
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeDecision(1, "merge the branch", digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(proposalId, 1, "proposal ids start at one");
        assertEq(votes.proposalCount(), 1);
        assertEq(uint256(stored.kind), uint256(KeyfleetVotes.Kind.Decision));
        assertEq(stored.proposer, _wallet(1));
        assertEq(stored.openedBlock, uint64(block.number));
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

    /// @dev Invariant: proposing reserves nothing and has no per-key limit. A Pay far above all the
    /// shared money the fleet holds can be proposed, one key can open any number of proposals, and
    /// the shared money is untouched until a Pay is carried out.
    function test_proposingReservesNothingAndOneKeyMayOpenAnyNumber() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        _receiveSharedMoney(fleet, other, 1_000_000);

        vm.startPrank(_wallet(1));
        for (uint256 i = 0; i < 50; ++i) {
            votes.proposePay(1, address(other), 1e30, bob, "far more than the fleet holds", bytes32(0));
        }
        vm.stopPrank();
        assertEq(votes.proposalCount(), 50, "fifty proposals from one key");
        assertEq(fleet.freeCapital(address(other)), 1_000_000, "nothing reserved");
    }

    // --- 4. who may vote ----------------------------------------------------

    /// @dev Invariant: a key may vote only if it last moved before the block the proposal opened
    /// in. A key bought after the proposal opened cannot vote on it, but every key sold counts in
    /// the approval rule, so a later sale can take an approved proposal back to open.
    function test_keysBoughtAfterAProposalOpensCannotVoteButCountAgainstIt() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);

        uint256 proposalId = _propose(votes);
        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "two of three keys");

        vm.roll(block.number + 1);
        _buyMany(fleet, 2);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Open), "two of five keys is not more than half");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 2, 5));
        votes.execute(proposalId);

        vm.prank(_wallet(4));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 4));
        votes.vote(proposalId, _ids(4), true);

        // The third original key is still eligible and carries it again.
        _vote(votes, proposalId, 3, true);
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "three of five keys");
        votes.execute(proposalId);

        // The later keys may vote on the next proposal.
        uint256 later = _propose(votes);
        _vote(votes, later, 4, true);
    }

    /// @dev Invariant: a key bought in the very block a proposal opens cannot vote on it, so a
    /// purchase ordered before the proposal inside one block adds no vote either.
    function test_aKeyBoughtInTheBlockAProposalOpensCannotVoteOnIt() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        vm.roll(block.number + 1);

        _buyMany(fleet, 1);
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeDecision(1, "same block", bytes32(0));
        assertEq(fleet.lastMovedBlock(2), votes.proposal(proposalId).openedBlock);

        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 2));
        votes.vote(proposalId, _ids(2), true);
        _vote(votes, proposalId, 1, true);
    }

    /// @dev Invariant: moving a key after a proposal opens can never add a vote. A holder who lends
    /// four unvoted keys to a friend after a proposal opens gives the friend nothing to vote with,
    /// the key that had already voted keeps its vote but can no longer change it, only have it
    /// withdrawn, and the keys stay unable to vote on that proposal when they come back.
    function test_aKeyThatMovesAfterAProposalOpensCannotVoteOnItAndItsVoteStands() public {
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
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 2));
        votes.vote(proposalId, _range(2, 3), true);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 1));
        votes.vote(proposalId, _ids(1), false);
        for (uint256 tokenId = 1; tokenId <= 4; ++tokenId) {
            fleet.transferFrom(dave, carol, tokenId);
        }
        vm.stopPrank();

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 2));
        votes.vote(proposalId, _range(2, 3), true);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 1, "the one vote cast before the key moved still stands");
        assertEq(stored.noVotes, 0);
        assertEq(uint256(votes.voteOf(proposalId, 1)), uint256(KeyfleetVotes.Choice.Yes));

        // The moved keys vote on the next proposal like any other.
        uint256 next = _propose(votes);
        vm.prank(carol);
        votes.vote(next, _range(1, 4), true);
        assertEq(votes.proposal(next).yesVotes, 4);
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
    /// whoever cast it, but a key that moved after the proposal opened still cannot cast a new one.
    /// Keys borrowed before a proposal opens, voted and handed back do not bind their owners: each
    /// owner takes the borrowed vote back, and the proposal loses the approval those votes gave it.
    function test_whoeverHoldsAKeyNowMayWithdrawItsVoteButNotCastANewOne() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 10);
        for (uint256 tokenId = 1; tokenId <= 6; ++tokenId) {
            vm.prank(_wallet(tokenId));
            fleet.transferFrom(_wallet(tokenId), mallory, tokenId);
        }
        uint256 proposalId = _propose(votes);
        vm.roll(block.number + 1);
        vm.startPrank(mallory);
        votes.vote(proposalId, _range(1, 6), true);
        for (uint256 tokenId = 1; tokenId <= 6; ++tokenId) {
            fleet.transferFrom(mallory, _wallet(tokenId), tokenId);
        }
        vm.stopPrank();
        assertEq(_state(votes, proposalId), uint256(KeyfleetVotes.State.Approved), "the borrowed votes approve it");

        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 1));
        votes.vote(proposalId, _ids(1), false);
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
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 1));
        votes.vote(proposalId, _ids(1), true);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.yesVotes, 4, "a delegate withdraws for the holder too");
        assertEq(stored.noVotes, 0);
    }

    /// @dev Invariant: withdrawing takes a key's vote off whichever side it is on, needs a key the
    /// caller may vote that has a vote, and ends when the proposal is carried out. Any refused id
    /// reverts the whole call, and a key that could always vote may vote again after withdrawing.
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
        assertEq(votes.proposal(proposalId).yesVotes, 3, "a key that could always vote votes again");

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
    /// out once, moves no tokens, and cannot be carried out a second time by anyone.
    function test_anApprovedDecisionRecordsOnceAndMovesNothing() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        _receiveSharedMoney(fleet, other, 10_000);
        vm.roll(block.number + 1);

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
        assertEq(fleet.freeCapital(address(other)), 10_000, "a Decision spends nothing");
        assertEq(other.balanceOf(address(fleet)), 10_000);

        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.execute(proposalId);
    }

    // --- 6. gas -------------------------------------------------------------

    /// @dev Invariant: voting is the one call whose cost grows with what the caller asks of it, and
    /// it grows only with the number of keys named, never with the fleet. The per-key cost is the
    /// vote record and the ownership and last-moved reads behind it, and the preset makes no
    /// difference to it. A holder with more keys than one block can carry splits the vote across
    /// calls.
    function test_votingCostsAFixedAmountPerKeyNamed() public {
        Keyfleet flat = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        for (uint256 i = 0; i < 40; ++i) {
            _buy(flat, _wallet(1));
        }
        uint256 flatTen = _measureVote(flat.VOTES(), _wallet(1), 1, 10);
        uint256 flatPerKey = (_measureVote(flat.VOTES(), _wallet(1), 11, 30) - flatTen) / 20;

        // One caster for ten Fibonacci keys across three levels: each owner delegates to Bob, which
        // is also the only way a single call can name keys the holding limit spreads over wallets.
        Keyfleet levelled = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes levelledVotes = levelled.VOTES();
        _buyMany(levelled, 10);
        for (uint256 i = 1; i <= 10; ++i) {
            vm.prank(_wallet(i));
            levelledVotes.setVotingDelegate(bob);
        }
        uint256 levelledTwo = _measureVote(levelledVotes, bob, 1, 2);
        uint256 levelledPerKey = (_measureVote(levelledVotes, bob, 3, 8) - levelledTwo) / 6;

        console2.log("vote gas for ten Classic keys:", flatTen);
        console2.log("marginal vote gas per Classic key:", flatPerKey);
        console2.log("marginal vote gas per Fibonacci key:", levelledPerKey);

        assertLt(flatTen, TEN_KEY_VOTE_CEILING, "a ten-key vote stays under the published ceiling");
        assertLt(flatPerKey, PER_KEY_VOTE_CEILING, "each extra key costs a fixed amount");
        assertApproxEqAbs(levelledPerKey, flatPerKey, 500, "a Fibonacci key costs what a Classic key costs");
    }

    /// @dev Votes `count` consecutive ids from `firstTokenId` in one call and returns the gas used.
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

    // --- 7. fuzz invariant ---------------------------------------------------

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
                _buyMany(fleet, 1); // a later sale: counted, never eligible here
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
