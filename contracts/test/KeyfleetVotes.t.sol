// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

/// @dev Reports six decimals, as Base USDC does, because a fleet refuses a USDC with any other.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract KeyfleetVotesTest is Test {
    uint64 private constant VOTING_WINDOW = 24 hours;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private other;
    KeyfleetAssetRegistry private registry;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    IRegentRevenueStaking private staking = IRegentRevenueStaking(address(0x57A1));
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV1 private factory = IRegentsAutolaunchFactoryV1(address(0xFAC7));

    address private safe = address(0x5AFE);
    address private treasury = address(0x7EA5);
    address private buyer = address(0xB0B0B0);
    address private payer = address(0xDEDE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);
    address private mallory = address(0x4A11);

    event ProposalCreated(
        uint256 indexed proposalId,
        KeyfleetVotes.Kind indexed kind,
        address indexed proposer,
        uint64 closesAt,
        uint256 snapshotMinted,
        bytes32 digest,
        string text
    );
    event VotingDelegateSet(address indexed owner, address indexed delegate);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        registry = new KeyfleetAssetRegistry(safe, address(usdc));
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet) {
        return _deploy(preset, VOTING_WINDOW);
    }

    function _deploy(KeyfleetPresets.Preset preset, uint64 votingWindow) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            treasury,
            registry,
            staking,
            factory,
            votingWindow,
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
        tokenId = fleet.purchase(receiver, address(0), 2 * price, block.timestamp);
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

    /// @dev Admits `token` and pays `amount` of it in as capital.
    function _depositCapital(Keyfleet fleet, MockToken token, uint256 amount) private {
        vm.startPrank(safe);
        registry.setFactoryTokenAllowed(address(token), true);
        registry.setFleetTokenAllowed(address(fleet), address(token), true);
        vm.stopPrank();

        token.mint(payer, amount);
        vm.startPrank(payer);
        token.approve(address(fleet), amount);
        fleet.depositCapital(address(token), amount);
        vm.stopPrank();
    }

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    /// @dev Votes one key as its current owner.
    function _vote(KeyfleetVotes votes, uint256 proposalId, uint256 tokenId, bool support) private {
        vm.prank(votes.FLEET().ownerOf(tokenId));
        votes.vote(proposalId, _ids(tokenId), support);
    }

    /// @dev Creates a Decision from the owner of key 1, which every fleet in this suite has minted.
    function _propose(KeyfleetVotes votes) private returns (uint256 proposalId) {
        vm.prank(votes.FLEET().ownerOf(1));
        proposalId = votes.proposeDecision(1, "record it", bytes32(0));
    }

    function _close(KeyfleetVotes votes, uint256 proposalId) private {
        vm.warp(votes.proposal(proposalId).closesAt);
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet and its voting controller are born together and correctly bound, so
    /// no deployment step can leave a fleet taking orders from someone else's vote.
    function test_constructorDeploysAndBindsItsOwnVotingController() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();

        assertEq(address(votes.FLEET()), address(fleet), "the controller is bound to this fleet");
        assertEq(votes.VOTING_WINDOW(), VOTING_WINDOW, "the window is exposed for the app to label");
        assertEq(votes.proposalCount(), 0, "no proposal exists yet");
    }

    /// @dev Invariant: the window is fixed at deployment and must be a window people can actually
    /// vote in. Zero would close in the block it opened, anything under an hour could close before
    /// holders elsewhere saw the proposal at all, and anything over a month would execute against a
    /// fleet nobody recognizes any more. All three are refused at deployment rather than discovered
    /// on the first proposal.
    function test_constructorBoundsTheVotingWindowAndRejectsAZeroFleet() public {
        uint64[3] memory refused = [uint64(0), 1 hours - 1, 30 days + 1];
        for (uint256 i = 0; i < refused.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotingWindowOutOfBounds.selector, refused[i]));
            _deploy(KeyfleetPresets.Preset.FleetTechClassic, refused[i]);
        }

        KeyfleetVotes shortest = _deploy(KeyfleetPresets.Preset.FleetTechClassic, 1 hours).VOTES();
        KeyfleetVotes longest = _deploy(KeyfleetPresets.Preset.FleetTechClassic, 30 days).VOTES();
        assertEq(shortest.VOTING_WINDOW(), shortest.MIN_VOTING_WINDOW(), "the bounds themselves are accepted");
        assertEq(longest.VOTING_WINDOW(), longest.MAX_VOTING_WINDOW());

        vm.expectRevert(KeyfleetVotes.ZeroAddress.selector);
        new KeyfleetVotes(Keyfleet(address(0)), VOTING_WINDOW);
    }

    // --- 2. one vote per key ---------------------------------------------

    /// @dev Invariant: every key is one vote on every preset, whatever its level. A Fibonacci
    /// level-1 key and a level-3 key each add exactly one, and a proposal is measured against
    /// every key in its snapshot at one vote each.
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
            assertEq(stored.snapshotMinted, 10, "ten keys are ten votes");
        }
    }

    // --- 3. proposals -----------------------------------------------------

    /// @dev Invariant: a proposal freezes everything it will be judged by in the transaction that
    /// creates it: the eligible set and the closing time.
    function test_aProposalFreezesItsSnapshotAndWindow() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);

        bytes32 digest = keccak256("base..head");
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(
            1,
            KeyfleetVotes.Kind.Decision,
            _wallet(1),
            uint64(block.timestamp) + VOTING_WINDOW,
            3,
            digest,
            "merge the branch"
        );
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeDecision(1, "merge the branch", digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(proposalId, 1, "proposal ids start at one");
        assertEq(votes.proposalCount(), 1);
        assertEq(uint256(stored.kind), uint256(KeyfleetVotes.Kind.Decision));
        assertEq(stored.proposer, _wallet(1));
        assertEq(stored.createdAt, uint64(block.timestamp));
        assertEq(stored.closesAt, uint64(block.timestamp) + VOTING_WINDOW);
        assertEq(stored.snapshotMinted, 3);
        assertEq(stored.digest, digest, "the digest is stored, the text is not");
        assertFalse(stored.executed);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Active));
    }

    /// @dev Invariant: proposing needs standing. The proposer names an eligible key and must be its
    /// owner or that owner's registered delegate, which is the same authorization voting applies.
    function test_proposingRequiresAnEligibleKeyTheCallerMayVote() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 2);

        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 0));
        votes.proposeDecision(0, "no key at all", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 3));
        votes.proposeDecision(3, "a key nobody has minted", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, _wallet(1)));
        votes.proposeDecision(1, "somebody else's key", bytes32(0));
        vm.stopPrank();

        vm.prank(_wallet(1));
        votes.setVotingDelegate(carol);
        vm.prank(carol);
        uint256 proposalId = votes.proposeDecision(1, "the delegate may propose", bytes32(0));
        assertEq(votes.proposal(proposalId).proposer, carol, "the delegate is the proposer");
        assertFalse(votes.hasVoted(proposalId, 1), "standing is not a vote, and the key is still free");
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

    // --- 4. eligibility ----------------------------------------------------

    /// @dev Invariant: the eligible set is the snapshot and nothing else. A key minted after a
    /// proposal was created cannot vote on it and was never counted in its snapshot, so a fresh
    /// purchase can neither add a vote to a running proposal nor dilute one.
    function test_keysMintedAfterCreationCannotVoteAndWereNeverCounted() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 2);

        uint256 proposalId = _propose(votes);
        assertEq(votes.proposal(proposalId).snapshotMinted, 2);

        _buyMany(fleet, 3);
        assertEq(fleet.totalMinted(), 5);
        assertEq(votes.proposal(proposalId).snapshotMinted, 2, "the snapshot did not move");

        vm.prank(_wallet(3));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 3));
        votes.vote(proposalId, _ids(3), true);

        // The later keys are eligible for the next proposal, which takes its own snapshot.
        uint256 later = _propose(votes);
        assertEq(votes.proposal(later).snapshotMinted, 5);
        _vote(votes, later, 3, true);
    }

    /// @dev Invariant: one vote per key per proposal, whoever holds it. A key that has voted is
    /// spent for that proposal and a transfer cannot recharge it; a key that has not voted votes
    /// with whoever owns it at the time, and the previous owner loses the right with the key.
    function test_aKeyVotesOnceAndTheRightToVoteItFollowsOwnership() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        uint256 first = _propose(votes);

        _vote(votes, first, 1, true);
        assertTrue(votes.hasVoted(first, 1));
        vm.prank(_wallet(1));
        fleet.transferFrom(_wallet(1), dave, 1);

        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, 1));
        votes.vote(first, _ids(1), false);
        assertEq(votes.proposal(first).yesVotes, 1, "the one vote it cast still stands");
        assertEq(votes.proposal(first).noVotes, 0);

        // A key that has not voted yet moves its right with it.
        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), dave, 2);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, dave));
        votes.vote(first, _ids(2), true);
        vm.prank(dave);
        votes.vote(first, _ids(2), false);
        assertEq(votes.proposal(first).noVotes, 1, "the new owner voted it");

        // A spent key is spent for that proposal only.
        uint256 second = _propose(votes);
        vm.prank(dave);
        votes.vote(second, _ids(1), true);
        assertTrue(votes.hasVoted(second, 1));
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
        assertFalse(votes.hasVoted(proposalId, 1), "and the holder's own key is untouched");
    }

    /// @dev Invariant: token id zero is refused by the eligibility bound under its own name, before
    /// any ownership lookup, so it can never surface as a bare ERC721 error from `ownerOf`.
    function test_tokenIdZeroIsRefusedByNameBeforeAnyOwnershipLookup() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        uint256 proposalId = _propose(votes);

        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 0));
        votes.vote(proposalId, _ids(0), true);
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
    /// batch because one id in it was already spent or belongs to somebody else.
    function test_aBatchOfKeysIsVotedWholeOrNotAtAll() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 3);
        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), _wallet(1), 2);
        uint256 proposalId = _propose(votes);

        uint256[] memory batch = new uint256[](3);
        (batch[0], batch[1], batch[2]) = (1, 2, 3);
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 3, _wallet(3)));
        votes.vote(proposalId, batch, true);
        assertFalse(votes.hasVoted(proposalId, 1), "the ids before the failure were not spent");
        assertEq(votes.proposal(proposalId).yesVotes, 0);

        uint256[] memory pair = new uint256[](2);
        (pair[0], pair[1]) = (1, 2);
        vm.expectEmit(true, true, true, true, address(votes));
        emit VoteCast(proposalId, _wallet(1), true, pair);
        vm.prank(_wallet(1));
        votes.vote(proposalId, pair, true);
        assertEq(votes.proposal(proposalId).yesVotes, 2, "both keys counted once");
    }

    // --- 5. the window ----------------------------------------------------

    /// @dev Invariant: voting is open strictly before `closesAt` and execution strictly from it, so
    /// the two never overlap and nobody can execute a result that is still moving.
    function test_votingClosesExactlyWhereExecutionOpens() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 2);
        uint256 proposalId = _propose(votes);
        uint64 closesAt = votes.proposal(proposalId).closesAt;

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotingOpen.selector, closesAt));
        votes.execute(proposalId);

        vm.warp(closesAt - 1);
        _vote(votes, proposalId, 1, true);
        _vote(votes, proposalId, 2, true);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Active), "still open one second out");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotingOpen.selector, closesAt));
        votes.execute(proposalId);

        vm.warp(closesAt);
        vm.prank(_wallet(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotingClosed.selector, closesAt));
        votes.vote(proposalId, _ids(1), true);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Passed));
        votes.execute(proposalId);
    }

    // --- 6. the pass rule --------------------------------------------------

    /// @dev Invariant: YES must exceed half of all the keys in the snapshot, not half of the keys
    /// that bothered to vote. Exactly half fails, one key more passes, and a key that stayed silent
    /// counts against the proposal just as a NO would. On a Fibonacci fleet the early levels get no
    /// extra say: level 1's two keys are two votes out of five.
    function test_yesMustExceedHalfOfAllTheKeys() public {
        // Exactly half: one of two Classic keys.
        Keyfleet even = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes evenVotes = even.VOTES();
        _buyMany(even, 2);
        uint256 tied = _propose(evenVotes);
        _vote(evenVotes, tied, 1, true);
        _close(evenVotes, tied);
        assertEq(evenVotes.proposal(tied).yesVotes * 2, evenVotes.proposal(tied).snapshotMinted, "exactly half");
        assertEq(uint256(evenVotes.state(tied)), uint256(KeyfleetVotes.State.Defeated));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotPassed.selector, 1, 2));
        evenVotes.execute(tied);

        // Silence is not neutral: one YES out of three keys, with nobody voting NO, still fails.
        Keyfleet quiet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes quietVotes = quiet.VOTES();
        _buyMany(quiet, 3);
        uint256 abstained = _propose(quietVotes);
        _vote(quietVotes, abstained, 1, true);
        _close(quietVotes, abstained);
        assertEq(quietVotes.proposal(abstained).noVotes, 0, "nobody voted against it");
        assertEq(uint256(quietVotes.state(abstained)), uint256(KeyfleetVotes.State.Defeated), "and it still fails");

        // Fibonacci: all of level 1 is two keys of five, which is not a majority; one level-2 key
        // more is.
        Keyfleet fib = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes fibVotes = fib.VOTES();
        _buyMany(fib, 5);
        uint256 narrow = _propose(fibVotes);
        _vote(fibVotes, narrow, 1, true);
        _vote(fibVotes, narrow, 2, true);
        _close(fibVotes, narrow);
        assertEq(uint256(fibVotes.state(narrow)), uint256(KeyfleetVotes.State.Defeated), "a whole level is two votes");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotPassed.selector, 2, 5));
        fibVotes.execute(narrow);

        uint256 three = _propose(fibVotes);
        _vote(fibVotes, three, 1, true);
        _vote(fibVotes, three, 2, true);
        _vote(fibVotes, three, 5, true);
        _close(fibVotes, three);
        assertEq(uint256(fibVotes.state(three)), uint256(KeyfleetVotes.State.Passed), "three keys of five pass");
        fibVotes.execute(three);
    }

    /// @dev Invariant: a passed Decision records agreement and does nothing else. It executes once,
    /// moves no tokens, and cannot be executed a second time by anyone.
    function test_aPassedDecisionRecordsOnceAndMovesNothing() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        _depositCapital(fleet, other, 10_000);
        uint256 capital = fleet.freeCapital(address(other));

        bytes32 digest = keccak256("commit");
        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeDecision(1, "ship it", digest);
        _vote(votes, proposalId, 1, true);
        _close(votes, proposalId);

        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, carol);
        vm.expectEmit(true, true, true, true, address(votes));
        emit DecisionRecorded(proposalId, digest);
        vm.prank(carol);
        votes.execute(proposalId);

        assertTrue(votes.proposal(proposalId).executed);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Executed));
        assertEq(fleet.freeCapital(address(other)), capital, "a Decision spends nothing");
        assertEq(other.balanceOf(address(fleet)), capital);

        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.execute(proposalId);
    }

    // --- 7. gas -------------------------------------------------------------

    /// @dev Invariant: voting is the one call whose cost grows with what the caller asks of it, and
    /// it grows only with the number of keys named, never with the fleet. The per-key cost is the
    /// one-vote-per-key record and the ownership read behind it, and the preset makes no difference
    /// to it. A holder with more keys than one block can carry splits the vote across calls, which
    /// the one-vote-per-key rule makes safe to do.
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

        assertLt(flatTen, 290_000, "a ten-key vote stays under the published ceiling");
        assertLt(flatPerKey, 26_000, "each extra key costs about twenty-three thousand gas");
        assertGt(flatPerKey, 20_000, "which is the one-vote record and the ownership read behind it");
        assertApproxEqAbs(levelledPerKey, flatPerKey, 500, "a Fibonacci key costs what a Classic key costs");
    }

    /// @dev Votes `count` consecutive ids from `firstTokenId` in one call and returns the gas used.
    function _measureVote(KeyfleetVotes votes, address caster, uint256 firstTokenId, uint256 count)
        private
        returns (uint256 used)
    {
        uint256 proposalId = _propose(votes);
        uint256[] memory tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            tokenIds[i] = firstTokenId + i;
        }
        vm.prank(caster);
        uint256 before = gasleft();
        votes.vote(proposalId, tokenIds, true);
        used = before - gasleft();
    }

    // --- 8. fuzz invariant ---------------------------------------------------

    /// @dev Invariant: across random sets of votes on a Fibonacci fleet spanning three levels, the
    /// votes recorded for and against are always exactly the number of keys that actually voted,
    /// each key counts at most once for the life of the proposal, and the two sides together can
    /// never exceed the keys in the snapshot.
    function testFuzz_everyKeyVotesAtMostOnceAndNeverBeyondTheSnapshot(uint256 seed) public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 10); // levels 1, 2 and 3.
        uint256 proposalId = _propose(votes);

        bool[11] memory spent;
        uint256 cast;
        for (uint256 i = 0; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 tokenId = (seed % 10) + 1;
            bool support = (seed >> 8) % 2 == 0;
            address owner = fleet.ownerOf(tokenId);

            vm.prank(owner);
            if (spent[tokenId]) {
                vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, tokenId));
                votes.vote(proposalId, _ids(tokenId), support);
            } else {
                votes.vote(proposalId, _ids(tokenId), support);
                spent[tokenId] = true;
                ++cast;
            }

            KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
            assertTrue(votes.hasVoted(proposalId, tokenId), "the key is spent for this proposal");
            assertEq(stored.yesVotes + stored.noVotes, cast, "recorded votes are exactly the keys that voted");
            assertLe(stored.yesVotes + stored.noVotes, stored.snapshotMinted, "and never exceed the snapshot");
        }

        assertEq(votes.proposal(proposalId).snapshotMinted, 10, "the snapshot never moved");
    }
}
