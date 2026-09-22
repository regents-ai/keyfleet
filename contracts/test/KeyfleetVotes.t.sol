// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A capital asset that calls back into `execute` the first time it moves, from inside the
/// transfer the fleet is in the middle of making on the vote's behalf. It is armed only after the
/// deposit that funds the fleet, so the hook fires on the voted transfer and nowhere else.
contract ReenteringToken is ERC20 {
    KeyfleetVotes private _votes;
    uint256 private _proposalId;
    bool private _entered;

    constructor() ERC20("Reenter", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(KeyfleetVotes votes, uint256 proposalId) external {
        _votes = votes;
        _proposalId = proposalId;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(_votes) == address(0) || _entered) return;
        _entered = true;
        _votes.execute(_proposalId);
    }
}

/// @dev A capital asset whose hook fires before its own balances move, the ERC777 `tokensToSend`
/// shape. Inside the hook the fleet still holds the tokens it is paying out while `freeCapital` has
/// already been debited, which is the window a second entry point could misread.
contract PreHookToken is ERC20 {
    /// @notice What the hook saw of the fleet while the payout was half done.
    uint256 public seenBalance;
    uint256 public seenFreeCapital;
    /// @notice Whether the hook ran, and how the call it made came back.
    bool public fired;
    bool public lastOk;
    bytes public lastReturn;

    Keyfleet private _fleet;
    address private _target;
    bytes private _payload;

    constructor() ERC20("PreHook", "PRE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(Keyfleet fleet, address target, bytes calldata payload) external {
        _fleet = fleet;
        _target = target;
        _payload = payload;
        fired = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_target != address(0) && !fired && from == address(_fleet)) {
            fired = true;
            seenBalance = balanceOf(address(_fleet));
            seenFreeCapital = _fleet.freeCapital(address(this));
            (lastOk, lastReturn) = _target.call(_payload);
        }
        super._update(from, to, value);
    }
}

/// @dev Reads the proposal's executed flag from inside the payout, so the ordering is observed
/// directly rather than inferred from the reentrancy guard.
contract FlagReadingToken is ERC20 {
    /// @notice What the hook read while the payout was running.
    bool public sawExecuted;
    bool public fired;

    KeyfleetVotes private _votes;
    uint256 private _proposalId;

    constructor() ERC20("Flag", "FLG") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(KeyfleetVotes votes, uint256 proposalId) external {
        _votes = votes;
        _proposalId = proposalId;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(_votes) == address(0) || fired) return;
        fired = true;
        sawExecuted = _votes.proposal(_proposalId).executed;
    }
}

contract KeyfleetVotesTest is Test {
    using stdStorage for StdStorage;

    uint256 private constant Q = 10e18;
    uint64 private constant VOTING_WINDOW = 24 hours;
    uint256 private constant SCALE = 1e18;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    StdStorage private fleetStore;

    MockToken private regent;
    MockToken private usdc;
    MockToken private other;
    KeyfleetAssetRegistry private registry;
    IRegentRevenueStaking private staking = IRegentRevenueStaking(address(0x57A1));

    address private safe = address(0x5AFE);
    address private treasury = address(0x7EA5);
    address private buyer = address(0xB0B0B0);
    address private payer = address(0xDEDE);
    address private alice = address(0xA11CE);
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
        uint256 totalWeight,
        bytes32 digest,
        string text
    );
    event TransferCapitalProposed(
        uint256 indexed proposalId, address indexed asset, uint256 amount, address indexed recipient
    );
    event VotingDelegateSet(address indexed owner, address indexed delegate);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight, uint256[] tokenIds);
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event CapitalTransferred(address indexed asset, uint256 amount, address indexed recipient);

    function setUp() public {
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        registry = new KeyfleetAssetRegistry(safe, address(usdc));
        vm.warp(1_000_000);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet) {
        return _deploy(preset, VOTING_WINDOW);
    }

    function _deploy(KeyfleetPresets.Preset preset, uint64 votingWindow) private returns (Keyfleet) {
        return new Keyfleet(
            preset, Q, regent, usdc, treasury, registry, staking, votingWindow, "Keyfleet Alpha", "KFA", BASE_URI
        );
    }

    function _buy(Keyfleet fleet, address receiver) private returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        regent.mint(buyer, price);
        vm.startPrank(buyer);
        regent.approve(address(fleet), price);
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

    function _admit(Keyfleet fleet, address token) private {
        vm.startPrank(safe);
        registry.setFactoryTokenAllowed(token, true);
        registry.setFleetTokenAllowed(address(fleet), token, true);
        vm.stopPrank();
    }

    /// @dev Admits an already-minted token and pays `amount` of it in as capital.
    function _payCapitalIn(Keyfleet fleet, ERC20 token, uint256 amount) private {
        _admit(fleet, address(token));
        vm.startPrank(payer);
        token.approve(address(fleet), amount);
        fleet.depositCapital(address(token), amount);
        vm.stopPrank();
    }

    /// @dev Pays `amount` in as capital and returns the net that actually reached `freeCapital`.
    function _depositCapital(Keyfleet fleet, MockToken token, uint256 amount) private returns (uint256 net) {
        token.mint(payer, amount);
        _payCapitalIn(fleet, token, amount);
        net = amount - (amount * fleet.DEPOSIT_FEE_BPS()) / 10_000;
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
        assertEq(votes.WEIGHT_SCALE(), SCALE);
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

    // --- 2. weight --------------------------------------------------------

    /// @dev Invariant: weight comes from the preset alone. A Fleet.Tech key is one vote; a Fibonacci
    /// level is one vote shared equally by its keys, floored, so a small early level's key weighs
    /// far more than a level-20 key.
    function test_keyWeightIsOnePerFleetTechKeyAndOnePerFibonacciLevel() public {
        KeyfleetVotes classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic).VOTES();
        assertEq(classic.weightOf(1), SCALE, "a Classic key is one whole vote");
        assertEq(classic.weightOf(KeyfleetPresets.CLASSIC_SUPPLY), SCALE, "and so is the last one");

        KeyfleetVotes accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant).VOTES();
        assertEq(accelerant.weightOf(1), SCALE, "an Accelerant key is one whole vote");

        KeyfleetVotes syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate).VOTES();
        assertEq(KeyfleetPresets.fibonacciLevelSupply(1), 2);
        assertEq(syndicate.weightOf(1), 5e17, "level 1 has two keys, so each is half a vote");
        assertEq(syndicate.weightOf(2), 5e17);
        assertEq(syndicate.weightOf(3), SCALE / 3, "level 2 has three keys");
        assertEq(KeyfleetPresets.fibonacciLevelSupply(20), 17_711);
        assertEq(syndicate.weightOf(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID), SCALE / 17_711, "level 20 is floored");

        KeyfleetVotes cascade = _deploy(KeyfleetPresets.Preset.FibonacciCascade).VOTES();
        assertEq(cascade.weightOf(3), SCALE / 3, "Cascade weighs its levels the same way");

        vm.expectRevert(KeyfleetPresets.TokenIdOutOfBounds.selector);
        syndicate.weightOf(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID + 1);
    }

    /// @dev Invariant: the total eligible weight a proposal is measured against is exactly the sum
    /// of its eligible keys' weights, although it is computed by walking at most twenty levels and
    /// never a single key. The snapshot is checked full, part-way through a level, and at the
    /// preset's ceiling, where summing key by key would be impossible on chain.
    function test_snapshotWeightMatchesTheSumOverEveryEligibleKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 10); // levels 1, 2 and 3 exactly filled.

        uint256 proposalId = _propose(votes);
        assertEq(votes.proposal(proposalId).snapshotMinted, 10);
        assertEq(votes.eligibleWeight(proposalId), _bruteForceWeight(votes, 10), "ten keys, three whole levels");

        // Part-way through level 8, which runs from id 87 to id 141.
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(uint256(100));
        uint256 midLevel = _propose(votes);
        assertEq(votes.eligibleWeight(midLevel), _bruteForceWeight(votes, 100), "a half-filled level counts its keys");
        assertLt(votes.eligibleWeight(midLevel), 8 * SCALE, "eight levels are worth less than eight whole votes");

        // Every level filled: twenty votes less the floor of each level's division.
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);
        uint256 full = _propose(votes);
        assertEq(votes.eligibleWeight(full), _levelWeight(20), "the walk over levels agrees level by level");
        assertLe(votes.eligibleWeight(full), 20 * SCALE, "twenty levels are worth at most twenty votes");
        assertGt(
            votes.eligibleWeight(full),
            20 * SCALE - KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID,
            "and a level's floor loses less than one atomic unit per key in it"
        );

        // A Fleet.Tech fleet is one whole vote per key, with no levels to walk at all.
        Keyfleet classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyMany(classic, 5);
        uint256 flat = _propose(classic.VOTES());
        assertEq(classic.VOTES().eligibleWeight(flat), 5 * SCALE, "five Classic keys are five whole votes");
    }

    function _bruteForceWeight(KeyfleetVotes votes, uint256 minted) private view returns (uint256 total) {
        for (uint256 tokenId = 1; tokenId <= minted; ++tokenId) {
            total += votes.weightOf(tokenId);
        }
    }

    function _levelWeight(uint256 levels) private pure returns (uint256 total) {
        for (uint256 level = 1; level <= levels; ++level) {
            uint256 supply = KeyfleetPresets.fibonacciLevelSupply(level);
            total += supply * (SCALE / supply);
        }
    }

    // --- 3. proposals -----------------------------------------------------

    /// @dev Invariant: a proposal freezes everything it will be judged by in the transaction that
    /// creates it: the eligible set, the total weight and the closing time.
    function test_aProposalFreezesItsSnapshotWindowAndTotalWeight() public {
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
            3 * SCALE,
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
        assertEq(stored.totalWeight, 3 * SCALE);
        assertEq(stored.digest, digest, "the digest is stored, the text is not");
        assertEq(stored.asset, address(0), "a Decision carries no payload");
        assertEq(stored.amount, 0);
        assertEq(stored.recipient, address(0));
        assertFalse(stored.executed);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Active));
    }

    /// @dev Invariant: a TransferCapital proposal names a real payment. A zero asset, a zero amount
    /// or a zero recipient is refused at creation, because none of them could ever be executed.
    function test_aTransferCapitalProposalNamesAnAssetAnAmountAndARecipient() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        vm.startPrank(_wallet(1));
        vm.expectRevert(KeyfleetVotes.ZeroAddress.selector);
        votes.proposeTransferCapital(1, address(0), 10_000, dave, bytes32(0));
        vm.expectRevert(KeyfleetVotes.ZeroAmount.selector);
        votes.proposeTransferCapital(1, address(other), 0, dave, bytes32(0));
        vm.expectRevert(KeyfleetVotes.ZeroRecipient.selector);
        votes.proposeTransferCapital(1, address(other), 10_000, address(0), bytes32(0));

        vm.expectEmit(true, true, true, true, address(votes));
        emit TransferCapitalProposed(1, address(other), 10_000, dave);
        uint256 proposalId = votes.proposeTransferCapital(1, address(other), 10_000, dave, bytes32(0));
        vm.stopPrank();

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(uint256(stored.kind), uint256(KeyfleetVotes.Kind.TransferCapital));
        assertEq(stored.asset, address(other));
        assertEq(stored.amount, 10_000);
        assertEq(stored.recipient, dave);
        assertEq(fleet.freeCapital(address(other)), 0, "nothing is checked or reserved at creation");
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
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.eligibleWeight(unknown[i]);
            vm.prank(_wallet(1));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.vote(unknown[i], _ids(1), true);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.UnknownProposal.selector, unknown[i]));
            votes.execute(unknown[i]);
        }
    }

    // --- 4. eligibility ----------------------------------------------------

    /// @dev Invariant: the eligible set is the snapshot and nothing else. A key minted after a
    /// proposal was created cannot vote on it and was never counted in its total weight, so a fresh
    /// purchase can neither add weight to a running vote nor dilute one.
    function test_keysMintedAfterCreationCannotVoteAndWereNeverCounted() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 2);

        uint256 proposalId = _propose(votes);
        assertEq(votes.eligibleWeight(proposalId), 2 * SCALE);

        _buyMany(fleet, 3);
        assertEq(fleet.totalMinted(), 5);
        assertEq(votes.eligibleWeight(proposalId), 2 * SCALE, "the snapshot did not move");
        assertEq(votes.proposal(proposalId).snapshotMinted, 2);

        vm.prank(_wallet(3));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 3));
        votes.vote(proposalId, _ids(3), true);

        // The later keys are eligible for the next proposal, which takes its own snapshot.
        uint256 later = _propose(votes);
        assertEq(votes.eligibleWeight(later), 5 * SCALE);
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
        assertEq(votes.proposal(first).yesWeight, SCALE, "the one vote it cast still stands");
        assertEq(votes.proposal(first).noWeight, 0);

        // A key that has not voted yet moves its right with it.
        vm.prank(_wallet(2));
        fleet.transferFrom(_wallet(2), dave, 2);
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 2, dave));
        votes.vote(first, _ids(2), true);
        vm.prank(dave);
        votes.vote(first, _ids(2), false);
        assertEq(votes.proposal(first).noWeight, SCALE, "the new owner voted it");

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
        assertEq(votes.proposal(first).yesWeight, SCALE, "the delegate voted the owner's key");
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
        assertEq(votes.proposal(proposalId).yesWeight, SCALE, "exactly one key of weight moved");
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
    /// who moved no weight at all.
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
        assertEq(votes.proposal(proposalId).yesWeight, 0);

        uint256[] memory pair = new uint256[](2);
        (pair[0], pair[1]) = (1, 2);
        vm.expectEmit(true, true, true, true, address(votes));
        emit VoteCast(proposalId, _wallet(1), true, 2 * SCALE, pair);
        vm.prank(_wallet(1));
        assertEq(votes.vote(proposalId, pair, true), 2 * SCALE, "both keys counted once");
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

    /// @dev Invariant: YES must exceed half of the total eligible weight, not half of the weight
    /// that bothered to vote. Exactly half fails, half plus one atomic unit passes, and a key that
    /// stayed silent counts against the proposal just as a NO would.
    function test_yesMustExceedHalfOfAllEligibleWeight() public {
        // Exactly half: one of two Classic keys.
        Keyfleet even = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes evenVotes = even.VOTES();
        _buyMany(even, 2);
        uint256 tied = _propose(evenVotes);
        _vote(evenVotes, tied, 1, true);
        _close(evenVotes, tied);
        assertEq(evenVotes.proposal(tied).yesWeight * 2, evenVotes.eligibleWeight(tied), "exactly half of the weight");
        assertEq(uint256(evenVotes.state(tied)), uint256(KeyfleetVotes.State.Defeated));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotPassed.selector, SCALE, 2 * SCALE));
        evenVotes.execute(tied);

        // Silence is not neutral: one YES out of three keys, with nobody voting NO, still fails.
        Keyfleet quiet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes quietVotes = quiet.VOTES();
        _buyMany(quiet, 3);
        uint256 abstained = _propose(quietVotes);
        _vote(quietVotes, abstained, 1, true);
        _close(quietVotes, abstained);
        assertEq(quietVotes.proposal(abstained).noWeight, 0, "nobody voted against it");
        assertEq(uint256(quietVotes.state(abstained)), uint256(KeyfleetVotes.State.Defeated), "and it still fails");

        // Half plus one atomic unit: level 1's two keys against level 2's three floored thirds.
        Keyfleet fib = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes fibVotes = fib.VOTES();
        _buyMany(fib, 5);
        uint256 narrow = _propose(fibVotes);
        assertEq(fibVotes.eligibleWeight(narrow), SCALE + 3 * (SCALE / 3), "the level-2 floor loses one unit");
        _vote(fibVotes, narrow, 1, true);
        _close(fibVotes, narrow);
        assertEq(uint256(fibVotes.state(narrow)), uint256(KeyfleetVotes.State.Defeated), "one level is not enough");

        uint256 both = _propose(fibVotes);
        _vote(fibVotes, both, 1, true);
        _vote(fibVotes, both, 2, true);
        _close(fibVotes, both);
        assertEq(
            fibVotes.proposal(both).yesWeight * 2 - fibVotes.eligibleWeight(both), 1, "it passes by one atomic unit"
        );
        assertEq(uint256(fibVotes.state(both)), uint256(KeyfleetVotes.State.Passed));
        fibVotes.execute(both);
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

    // --- 7. capital transfers ----------------------------------------------

    /// @dev Invariant: a passed TransferCapital that free capital cannot cover reverts and stays
    /// executable. The proposal is not consumed by the failure, and once the capital exists it pays
    /// exactly the voted amount out of exactly that bucket.
    function test_aTransferCapitalShortOfFreeCapitalRevertsAndStaysExecutable() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeTransferCapital(1, address(other), 10_000, dave, bytes32(0));
        _vote(votes, proposalId, 1, true);
        _close(votes, proposalId);

        vm.expectRevert(
            abi.encodeWithSelector(Keyfleet.InsufficientFreeCapital.selector, address(other), 10_000, uint256(0))
        );
        votes.execute(proposalId);
        assertFalse(votes.proposal(proposalId).executed, "the failure did not consume the proposal");
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Passed), "it is still executable");

        uint256 net = _depositCapital(fleet, other, 20_000);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit CapitalTransferred(address(other), 10_000, dave);
        votes.execute(proposalId);

        assertEq(other.balanceOf(dave), 10_000, "the recipient was paid exactly the voted amount");
        assertEq(fleet.freeCapital(address(other)), net - 10_000, "and free capital fell by exactly that");
        assertEq(other.balanceOf(address(fleet)), net - 10_000, "the balance matches the bucket");
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Executed));

        vm.expectRevert(KeyfleetVotes.AlreadyExecuted.selector);
        votes.execute(proposalId);
    }

    /// @dev Invariant: a vote reaches free working capital and nothing else. A Cascade fleet whose
    /// whole REGENT balance is an incomplete level's completion reserve has no free capital, so the
    /// vote is refused even though the tokens are sitting in the fleet.
    function test_aVoteCannotBorrowTheCascadeCompletionReserve() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        uint256 reserve = fleet.cascadeReserve();
        assertGt(reserve, 0, "the first Cascade key funds the reserve");
        assertEq(fleet.freeCapital(address(regent)), 0, "and none of it is free capital");
        assertEq(regent.balanceOf(address(fleet)), reserve, "the fleet is holding it");

        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeTransferCapital(1, address(regent), reserve, dave, bytes32(0));
        _vote(votes, proposalId, 1, true);
        _close(votes, proposalId);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Passed), "the vote itself passed");

        vm.expectRevert(
            abi.encodeWithSelector(Keyfleet.InsufficientFreeCapital.selector, address(regent), reserve, uint256(0))
        );
        votes.execute(proposalId);

        assertEq(fleet.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(regent.balanceOf(address(fleet)), reserve);
        assertEq(regent.balanceOf(dave), 0);
    }

    /// @dev Invariant: a vote cannot withdraw a member's claim. Reward backing does not sit in the
    /// fleet at all, so the fleet's free capital in a revenue asset is zero however much of it the
    /// ledger is holding for holders.
    function test_aVoteCannotWithdrawRewardBacking() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 1);

        _admit(fleet, address(other));
        other.mint(payer, 10_000);
        vm.startPrank(payer);
        other.approve(address(fleet), 10_000);
        fleet.depositRevenue(address(other), 10_000, bytes32("svc"));
        vm.stopPrank();

        assertEq(rewards.backed(address(other)), 9_800, "the ledger is holding the members' money");
        assertEq(fleet.freeCapital(address(other)), 0, "and the fleet has no free capital in it");

        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeTransferCapital(1, address(other), 9_800, dave, bytes32(0));
        _vote(votes, proposalId, 1, true);
        _close(votes, proposalId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Keyfleet.InsufficientFreeCapital.selector, address(other), uint256(9_800), uint256(0)
            )
        );
        votes.execute(proposalId);

        assertEq(rewards.backed(address(other)), 9_800, "the recorded liability is unchanged");
        assertEq(other.balanceOf(address(rewards)), 9_800, "and the tokens behind it never moved");
    }

    /// @dev Invariant: the shortfall boundary is exact and is refused by name. One atomic unit over
    /// the free capital reverts with `InsufficientFreeCapital` carrying all three figures, not with
    /// an arithmetic panic, and the whole of free capital to the unit goes through.
    function test_oneAtomicUnitOverFreeCapitalIsTheNamedShortfallNotAPanic() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);
        uint256 net = _depositCapital(fleet, other, 20_000);

        vm.startPrank(_wallet(1));
        uint256 over = votes.proposeTransferCapital(1, address(other), net + 1, dave, bytes32(0));
        uint256 exact = votes.proposeTransferCapital(1, address(other), net, dave, bytes32(0));
        votes.vote(over, _ids(1), true);
        votes.vote(exact, _ids(1), true);
        vm.stopPrank();
        _close(votes, exact);

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.InsufficientFreeCapital.selector, address(other), net + 1, net));
        votes.execute(over);

        votes.execute(exact);
        assertEq(other.balanceOf(dave), net, "the whole bucket to the unit goes through");
        assertEq(fleet.freeCapital(address(other)), 0);
    }

    /// @dev Invariant: free capital is debited before the tokens move, and the fleet's own guard
    /// closes the window that opens in between. A token whose hook fires before its balances move
    /// sees the fleet still holding what it is paying out while the bucket has already fallen, and
    /// a second entry point would book that gap as a fresh surplus: capital the fleet is about to
    /// stop holding, credited twice, which a later vote could spend against the reserve's backing.
    /// The guard refuses it, and nothing phantom is left behind.
    function test_theFleetGuardClosesTheWindowAPreHookAssetOpensDuringAPayout() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        PreHookToken token = new PreHookToken();
        token.mint(payer, 20_000);
        _payCapitalIn(fleet, token, 20_000);
        uint256 net = fleet.freeCapital(address(token));

        vm.startPrank(_wallet(1));
        uint256 proposalId = votes.proposeTransferCapital(1, address(token), 10_000, dave, bytes32(0));
        votes.vote(proposalId, _ids(1), true);
        vm.stopPrank();
        _close(votes, proposalId);

        token.arm(fleet, address(fleet), abi.encodeCall(Keyfleet.recognizeSurplus, (address(token))));
        votes.execute(proposalId);

        assertTrue(token.fired(), "the hook ran inside the payout");
        assertEq(token.seenBalance() - token.seenFreeCapital(), 10_000, "the window really is the voted amount wide");
        assertFalse(token.lastOk(), "and the fleet's guard closed it");
        assertEq(bytes4(token.lastReturn()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);

        assertEq(fleet.freeCapital(address(token)), net - 10_000, "free capital fell by exactly the voted amount");
        assertEq(token.balanceOf(address(fleet)), net - 10_000, "and the balance still matches the bucket");
        assertEq(fleet.surplus(address(token)), 0, "nothing phantom was created");
    }

    /// @dev Invariant: the proposal is marked executed before the fleet is called, observed from
    /// inside the payout itself, so the ordering does not rest on the reentrancy guard alone.
    function test_theProposalIsMarkedExecutedBeforeTheFleetIsCalled() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        FlagReadingToken token = new FlagReadingToken();
        token.mint(payer, 20_000);
        _payCapitalIn(fleet, token, 20_000);

        vm.startPrank(_wallet(1));
        uint256 proposalId = votes.proposeTransferCapital(1, address(token), 10_000, dave, bytes32(0));
        votes.vote(proposalId, _ids(1), true);
        vm.stopPrank();
        _close(votes, proposalId);

        token.arm(votes, proposalId);
        votes.execute(proposalId);

        assertTrue(token.fired(), "the hook ran inside the payout");
        assertTrue(token.sawExecuted(), "the proposal was already marked executed before the tokens moved");
    }

    /// @dev Invariant: the fleet takes capital instructions from its own voting controller and from
    /// nobody else, so no holder, treasury or stranger can move capital directly.
    function test_onlyTheVotingControllerMayMoveFreeCapital() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyMany(fleet, 1);
        uint256 net = _depositCapital(fleet, other, 10_000);

        address[4] memory strangers = [alice, treasury, safe, address(fleet.REWARDS())];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(Keyfleet.OnlyVotes.selector);
            fleet.transferCapital(address(other), 1, dave);
        }

        // Nor may another fleet's controller, which is bound to its own fleet.
        Keyfleet stranger = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        vm.prank(address(stranger.VOTES()));
        vm.expectRevert(Keyfleet.OnlyVotes.selector);
        fleet.transferCapital(address(other), 1, dave);

        assertEq(fleet.freeCapital(address(other)), net, "capital is exactly where it was");
    }

    /// @dev Invariant: the guard holds against the asset being paid out. A token that calls back
    /// into `execute` from inside the transfer cannot execute the proposal a second time, and the
    /// attempt takes the whole payout down with it rather than paying twice.
    function test_reenteringExecuteFromTheRecipientTokenIsRejected() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 1);

        ReenteringToken token = new ReenteringToken();
        token.mint(payer, 20_000);
        _payCapitalIn(fleet, token, 20_000);
        uint256 net = fleet.freeCapital(address(token));

        vm.prank(_wallet(1));
        uint256 proposalId = votes.proposeTransferCapital(1, address(token), 10_000, dave, bytes32(0));
        _vote(votes, proposalId, 1, true);
        _close(votes, proposalId);

        token.arm(votes, proposalId);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        votes.execute(proposalId);

        assertFalse(votes.proposal(proposalId).executed, "nothing executed");
        assertEq(fleet.freeCapital(address(token)), net, "and nothing was paid out");
        assertEq(token.balanceOf(dave), 0);
    }

    // --- 8. gas -------------------------------------------------------------

    /// @dev Invariant: creating a proposal walks levels, never keys, so its cost is bounded by the
    /// preset rather than by how large the fleet has grown. This is the worst case: a Fibonacci
    /// fleet at the level-20 ceiling, with every slot the call touches cold.
    function test_worstCaseProposalCreationGasAtTwentyLevels() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        _buy(fleet, _wallet(1));
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);

        vm.cool(address(fleet));
        vm.cool(address(votes));

        vm.prank(_wallet(1));
        uint256 before = gasleft();
        uint256 proposalId = votes.proposeDecision(1, "merge the branch", keccak256("base..head"));
        uint256 used = before - gasleft();

        console2.log("worst-case proposal creation gas at twenty levels:", used);
        assertLt(used, 223_000, "worst-case creation stays under the published ceiling");
        assertEq(votes.proposal(proposalId).snapshotMinted, KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);
        assertEq(votes.eligibleWeight(proposalId), _levelWeight(20), "and it counted all twenty levels");

        // A fleet with two keys in one level is barely cheaper than one with every level filled,
        // which is what walking levels instead of keys buys.
        Keyfleet small = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buyMany(small, 2);
        KeyfleetVotes smallVotes = small.VOTES();
        vm.cool(address(small));
        vm.cool(address(smallVotes));
        vm.prank(_wallet(1));
        before = gasleft();
        smallVotes.proposeDecision(1, "merge the branch", keccak256("base..head"));
        uint256 smallUsed = before - gasleft();
        console2.log("proposal creation gas at one level:", smallUsed);
        assertLt(used - smallUsed, 48_000, "the other nineteen levels together cost about two thousand gas each");
    }

    /// @dev Invariant: voting is the one call whose cost grows with what the caller asks of it, and
    /// it grows only with the number of keys named, never with the fleet. The per-key cost is almost
    /// entirely the one-vote-per-key record and the ownership read behind it, so a Fibonacci fleet,
    /// which also looks each key's level up, is barely dearer than a flat one. A holder with more
    /// keys than one block can carry splits the vote across calls, which the one-vote-per-key rule
    /// makes safe to do.
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
        assertLt(levelledPerKey - flatPerKey, 2_000, "looking a level up adds almost nothing per key");
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

    // --- 9. fuzz invariant ---------------------------------------------------

    /// @dev Invariant: across random sets of votes on a fleet with three different key weights, the
    /// weight recorded for and against is always exactly the weight of the keys that actually voted,
    /// each key counts at most once for the life of the proposal, and the two sides together can
    /// never exceed the eligible weight the proposal was created with.
    function testFuzz_everyKeyVotesAtMostOnceAndNeverBeyondTheEligibleWeight(uint256 seed) public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        _buyMany(fleet, 10); // levels 1, 2 and 3: weights of a half, a third and a fifth of a vote.
        uint256 proposalId = _propose(votes);

        bool[11] memory spent;
        uint256 cast;
        for (uint256 i = 0; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 tokenId = (seed % 10) + 1;
            bool support = (seed >> 8) % 2 == 0;
            address owner = fleet.ownerOf(tokenId);

            if (spent[tokenId]) {
                vm.prank(owner);
                vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyVoted.selector, tokenId));
                votes.vote(proposalId, _ids(tokenId), support);
            } else {
                vm.prank(owner);
                assertEq(votes.vote(proposalId, _ids(tokenId), support), votes.weightOf(tokenId));
                spent[tokenId] = true;
                cast += votes.weightOf(tokenId);
            }

            KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
            assertTrue(votes.hasVoted(proposalId, tokenId), "the key is spent for this proposal");
            assertEq(stored.yesWeight + stored.noWeight, cast, "recorded weight is exactly the keys that voted");
            assertLe(stored.yesWeight + stored.noWeight, stored.totalWeight, "and never exceeds the eligible weight");
        }

        assertEq(votes.eligibleWeight(proposalId), _bruteForceWeight(votes, 10), "the snapshot never moved");
    }
}
