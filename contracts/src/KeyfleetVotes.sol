// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";

/// @notice The one fixed vote of a fleet: a proposal, a fixed window, and a single pass rule.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// There are no councils, no moderators, no rule amendments and no configurable presets. A proposal
/// runs for exactly `VOTING_WINDOW` seconds and passes only if YES exceeds half of the *total*
/// eligible snapshot weight, so an abstention counts against it. Execution happens after the window
/// closes and never before.
///
/// Weight is fixed by the preset, not by anything anyone can set here. A Fleet.Tech key is worth
/// `WEIGHT_SCALE`. A Fibonacci key is worth `WEIGHT_SCALE / fibonacciLevelSupply(level)`, floored,
/// which is the fixed-precision approximation of one vote per level. A proposal's eligible set is
/// the token ids `1..snapshotMinted` recorded when it was created, so later mints are ineligible for
/// it and a transfer can never produce a second vote for the same key.
///
/// There are two kinds. A `Decision` records agreement and has no external side effect; its text is
/// carried in the creation event only and an optional digest pins the exact artifact or commit. A
/// `TransferCapital` moves an accounted asset out of the fleet's *free* capital to a named
/// recipient, once. The fleet's Cascade completion reserve and the reward ledger's backing are not
/// free capital and are unreachable from here by construction.
///
/// There is no administrator, no upgrade path, no pause, no cancellation, no quorum tuning and no
/// delegation by signature. This deliberately does not solve a majority takeover: a majority of
/// snapshot weight can authorize a harmful free-capital transfer, and no hidden signer is introduced
/// to disguise that. Claim and reserve solvency hold regardless of any vote.
contract KeyfleetVotes is ReentrancyGuard {
    /// @notice What a proposal does when it passes.
    enum Kind {
        Decision,
        TransferCapital
    }

    /// @notice Where a proposal stands right now.
    enum State {
        Active,
        Defeated,
        Passed,
        Executed
    }

    /// @notice One proposal. Everything a vote is counted against is fixed at creation.
    /// @param kind Decision or TransferCapital.
    /// @param proposer The address that created it.
    /// @param createdAt Block timestamp of creation.
    /// @param closesAt Last moment plus one: voting is open strictly before this, execution from it.
    /// @param snapshotMinted Keys minted when it was created; the eligible ids are `1..snapshotMinted`.
    /// @param totalWeight Total weight of that eligible set, computed once at creation.
    /// @param yesWeight Weight voted in favour.
    /// @param noWeight Weight voted against.
    /// @param executed Whether it has already executed.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param asset TransferCapital only: the asset to move.
    /// @param amount TransferCapital only: the atomic amount to move.
    /// @param recipient TransferCapital only: who receives it.
    struct Proposal {
        Kind kind;
        address proposer;
        uint64 createdAt;
        uint64 closesAt;
        uint256 snapshotMinted;
        uint256 totalWeight;
        uint256 yesWeight;
        uint256 noWeight;
        bool executed;
        bytes32 digest;
        address asset;
        uint256 amount;
        address recipient;
    }

    /// @notice The fleet address supplied at construction was zero.
    error ZeroAddress();
    /// @notice The voting window is outside `MIN_VOTING_WINDOW..MAX_VOTING_WINDOW`.
    error VotingWindowOutOfBounds(uint64 window);
    /// @notice No proposal carries this id.
    error UnknownProposal(uint256 proposalId);
    /// @notice A TransferCapital proposal of zero, or to nobody, is rejected.
    error ZeroAmount();
    /// @notice The recipient of a TransferCapital proposal was zero.
    error ZeroRecipient();
    /// @notice The key is outside this proposal's eligible snapshot, or is not a key at all.
    error KeyNotEligible(uint256 tokenId);
    /// @notice The caller is neither the key's owner nor that owner's registered voting delegate.
    error NotAuthorizedForKey(uint256 tokenId, address owner);
    /// @notice The key has already voted on this proposal.
    error AlreadyVoted(uint256 tokenId);
    /// @notice A vote must name at least one key.
    error NoKeys();
    /// @notice The voting window has closed.
    error VotingClosed(uint64 closesAt);
    /// @notice The voting window is still open, so nothing can execute yet.
    error VotingOpen(uint64 closesAt);
    /// @notice The proposal has already executed. Every proposal executes at most once.
    error AlreadyExecuted();
    /// @notice YES did not exceed half of the total eligible snapshot weight.
    error NotPassed(uint256 yesWeight, uint256 totalWeight);

    /// @notice A proposal was created. `text` is carried here and stored nowhere.
    /// @param proposalId The new proposal.
    /// @param kind Decision or TransferCapital.
    /// @param proposer The address that created it.
    /// @param closesAt When voting closes and execution becomes possible.
    /// @param snapshotMinted Keys minted at creation; the eligible ids are `1..snapshotMinted`.
    /// @param totalWeight Total eligible weight this proposal is measured against.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param text The proposal text, for readers; the contract never reads it back.
    event ProposalCreated(
        uint256 indexed proposalId,
        Kind indexed kind,
        address indexed proposer,
        uint64 closesAt,
        uint256 snapshotMinted,
        uint256 totalWeight,
        bytes32 digest,
        string text
    );

    /// @notice The payload of a TransferCapital proposal, emitted beside its `ProposalCreated`.
    event TransferCapitalProposed(
        uint256 indexed proposalId, address indexed asset, uint256 amount, address indexed recipient
    );

    /// @notice An owner set or cleared the address that may vote their keys for them.
    event VotingDelegateSet(address indexed owner, address indexed delegate);

    /// @notice Keys were voted. Each id is counted exactly once for the life of the proposal.
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight, uint256[] tokenIds);

    /// @notice A passed Decision was recorded. Nothing else happens on chain.
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);

    /// @notice A proposal executed. It can never execute again.
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    /// @notice Weight of one Fleet.Tech key, and the numerator of every Fibonacci key's weight.
    uint256 public constant WEIGHT_SCALE = 1e18;
    /// @notice Shortest voting window a fleet may be deployed with. Anything briefer could close
    /// before holders in other time zones had a chance to see the proposal at all.
    uint64 public constant MIN_VOTING_WINDOW = 1 hours;
    /// @notice Longest voting window a fleet may be deployed with. Anything longer would leave a
    /// passed proposal executing against a fleet nobody recognizes any more.
    uint64 public constant MAX_VOTING_WINDOW = 30 days;

    /// @notice The fleet that deployed this controller and holds the keys that vote.
    Keyfleet public immutable FLEET;
    /// @notice Seconds a proposal stays open. Fixed at deployment within
    /// `MIN_VOTING_WINDOW..MAX_VOTING_WINDOW`; production is 24 hours and a testnet fleet uses a
    /// shorter, visibly labelled window. There is no setter.
    uint64 public immutable VOTING_WINDOW;

    /// @notice Proposals created so far. Proposal ids are `1..proposalCount`.
    uint256 public proposalCount;
    /// @notice The address an owner has authorized to vote their keys. Zero means nobody.
    /// @dev An attached chat agent gets nothing from this; financial authority is registered here
    /// and only here.
    mapping(address owner => address delegate) public votingDelegate;
    /// @notice Whether a key has already been voted on a proposal.
    mapping(uint256 proposalId => mapping(uint256 tokenId => bool used)) public hasVoted;

    mapping(uint256 proposalId => Proposal proposal) private _proposals;

    /// @notice Binds this controller to the fleet that deploys it.
    /// @param fleet The fleet whose keys vote here.
    /// @param votingWindow Seconds a proposal stays open, within
    /// `MIN_VOTING_WINDOW..MAX_VOTING_WINDOW`.
    constructor(Keyfleet fleet, uint64 votingWindow) {
        if (address(fleet) == address(0)) revert ZeroAddress();
        if (votingWindow < MIN_VOTING_WINDOW || votingWindow > MAX_VOTING_WINDOW) {
            revert VotingWindowOutOfBounds(votingWindow);
        }
        FLEET = fleet;
        VOTING_WINDOW = votingWindow;
    }

    // --- views -----------------------------------------------------------

    /// @notice Voting weight of one key, from the preset alone.
    /// @dev A Fleet.Tech key is worth `WEIGHT_SCALE`. A Fibonacci key is worth
    /// `WEIGHT_SCALE / fibonacciLevelSupply(level)`, floored, so a level carries one vote shared
    /// equally by its keys and the floor is the fixed-precision approximation the spec asks for.
    /// This answers for any valid token id, minted or not, because the id alone fixes the level.
    function weightOf(uint256 tokenId) public view returns (uint256) {
        return _weightOf(tokenId, _isFibonacci());
    }

    /// @notice Total eligible weight a proposal is measured against.
    function eligibleWeight(uint256 proposalId) external view returns (uint256) {
        return _require(proposalId).totalWeight;
    }

    /// @notice The whole proposal record.
    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _require(proposalId);
    }

    /// @notice Where a proposal stands: open, defeated, passed and waiting, or already executed.
    function state(uint256 proposalId) external view returns (State) {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) return State.Executed;
        if (block.timestamp < stored.closesAt) return State.Active;
        return _passed(stored) ? State.Passed : State.Defeated;
    }

    // --- delegation ------------------------------------------------------

    /// @notice Authorizes one address to vote every key the caller owns, or clears it with zero.
    /// @dev Delegation follows the owner, not the key: it applies to whatever keys the caller holds
    /// when a vote is cast, and it never moves a key or a reward. The owner can always vote too.
    function setVotingDelegate(address delegate) external {
        votingDelegate[msg.sender] = delegate;
        emit VotingDelegateSet(msg.sender, delegate);
    }

    // --- proposals -------------------------------------------------------

    /// @notice Proposes a Decision: text that records agreement, with no automatic side effect.
    /// @dev The text is emitted and never stored, because nothing on chain reads it back. The digest
    /// is stored so a passed decision can be pinned to an exact artifact or commit; zero means none.
    /// @param tokenId An eligible key the caller owns or is the registered delegate of. It is the
    /// caller's standing to propose and nothing else: it is not a vote and it stays free to vote.
    /// @param text The proposal text, for readers.
    /// @param digest Optional exact artifact or commit digest.
    /// @return proposalId The new proposal.
    function proposeDecision(uint256 tokenId, string calldata text, bytes32 digest)
        external
        returns (uint256 proposalId)
    {
        return _propose(tokenId, Kind.Decision, text, digest);
    }

    /// @notice Proposes moving free working capital out of the fleet to a named recipient.
    /// @dev Nothing is checked against the fleet's balance here. The spec is explicit that a
    /// proposal over free capital simply fails to execute while the capital is short, so the balance
    /// is read at execution and never at creation.
    /// @param tokenId An eligible key the caller owns or is the registered delegate of.
    /// @param asset The accounted asset to move.
    /// @param amount Atomic units to move, which must be nonzero.
    /// @param recipient Who receives them, which must be nonzero.
    /// @param digest Optional exact artifact or commit digest.
    /// @return proposalId The new proposal.
    function proposeTransferCapital(uint256 tokenId, address asset, uint256 amount, address recipient, bytes32 digest)
        external
        returns (uint256 proposalId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroRecipient();
        proposalId = _propose(tokenId, Kind.TransferCapital, "", digest);
        Proposal storage stored = _proposals[proposalId];
        stored.asset = asset;
        stored.amount = amount;
        stored.recipient = recipient;
        emit TransferCapitalProposed(proposalId, asset, amount, recipient);
    }

    // --- voting ----------------------------------------------------------

    /// @notice Votes a set of keys for or against a proposal, while its window is open.
    /// @dev Every id must be inside the proposal's snapshot, must not have voted on it before, and
    /// must be owned by the caller or by an owner who has registered the caller as their delegate.
    /// A key that has voted is spent for that proposal: transferring it cannot produce a second
    /// vote, and a key that has not voted yet votes with whoever owns it at the time.
    ///
    /// The whole call reverts if any one id fails, so a caller never half-votes a set by accident.
    /// @param proposalId The proposal being voted on.
    /// @param tokenIds The keys to vote, each at most once.
    /// @param support True for YES, false for NO.
    /// @return weight The weight this call added.
    function vote(uint256 proposalId, uint256[] calldata tokenIds, bool support) external returns (uint256 weight) {
        Proposal storage stored = _require(proposalId);
        if (block.timestamp >= stored.closesAt) revert VotingClosed(stored.closesAt);
        if (tokenIds.length == 0) revert NoKeys();

        uint256 snapshotMinted = stored.snapshotMinted;
        bool isFibonacci = _isFibonacci();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (tokenId == 0 || tokenId > snapshotMinted) revert KeyNotEligible(tokenId);
            if (hasVoted[proposalId][tokenId]) revert AlreadyVoted(tokenId);
            _requireCaster(tokenId);
            hasVoted[proposalId][tokenId] = true;
            weight += _weightOf(tokenId, isFibonacci);
        }

        if (support) stored.yesWeight += weight;
        else stored.noWeight += weight;
        emit VoteCast(proposalId, msg.sender, support, weight, tokenIds);
    }

    // --- execution -------------------------------------------------------

    /// @notice Executes a proposal that passed, once its window has closed.
    /// @dev Permissionless: the result is the vote's, not the caller's. The pass rule is
    /// `yesWeight * 2 > totalWeight`, so YES must exceed half of the *whole* eligible snapshot
    /// weight and every key that stayed silent counts against it.
    ///
    /// The proposal is marked executed before the fleet is called, so a token that calls back can
    /// never execute it twice. A TransferCapital that the fleet's free capital cannot cover reverts
    /// the whole call, which rolls that mark back as well: the proposal stays executable and can be
    /// executed later once the capital exists, which is exactly what the spec asks for.
    /// @param proposalId The proposal to execute.
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage stored = _require(proposalId);
        if (block.timestamp < stored.closesAt) revert VotingOpen(stored.closesAt);
        if (stored.executed) revert AlreadyExecuted();
        if (!_passed(stored)) revert NotPassed(stored.yesWeight, stored.totalWeight);

        stored.executed = true;
        emit ProposalExecuted(proposalId, msg.sender);

        if (stored.kind == Kind.Decision) {
            emit DecisionRecorded(proposalId, stored.digest);
        } else {
            FLEET.transferCapital(stored.asset, stored.amount, stored.recipient);
        }
    }

    // --- internals -------------------------------------------------------

    /// @dev Records a proposal and freezes its eligible set and total weight in the same call. The
    /// standing check is the same one `vote` applies: the caller owns the named key or is the
    /// registered delegate of whoever does, and the key is inside the snapshot this call just took.
    function _propose(uint256 tokenId, Kind kind, string memory text, bytes32 digest)
        private
        returns (uint256 proposalId)
    {
        uint256 snapshotMinted = FLEET.totalMinted();
        if (tokenId == 0 || tokenId > snapshotMinted) revert KeyNotEligible(tokenId);
        _requireCaster(tokenId);

        proposalId = proposalCount + 1;
        proposalCount = proposalId;

        Proposal storage stored = _proposals[proposalId];
        stored.kind = kind;
        stored.proposer = msg.sender;
        stored.createdAt = uint64(block.timestamp);
        stored.closesAt = uint64(block.timestamp) + VOTING_WINDOW;
        stored.snapshotMinted = snapshotMinted;
        stored.totalWeight = _snapshotWeight(snapshotMinted);
        stored.digest = digest;

        emit ProposalCreated(
            proposalId, kind, msg.sender, stored.closesAt, snapshotMinted, stored.totalWeight, digest, text
        );
    }

    /// @dev Total weight of the token ids `1..minted`, computed by walking at most twenty levels and
    /// never a single key, so the cost is bounded by the preset rather than by the fleet: creating a
    /// proposal on a Fibonacci fleet holding two keys in one level measured about 146,000 gas, and
    /// on one at the level-20 ceiling about 186,000, with nothing in between depending on how many
    /// keys exist. A Fleet.Tech fleet has one weight per key and needs no walk at all.
    function _snapshotWeight(uint256 minted) private view returns (uint256 total) {
        if (!_isFibonacci()) return minted * WEIGHT_SCALE;

        uint256 previousEnd;
        for (uint256 level = 1; level <= KeyfleetPresets.MAX_FIBONACCI_LEVEL; ++level) {
            uint256 supply = KeyfleetPresets.fibonacciLevelSupply(level);
            uint256 end = previousEnd + supply;
            uint256 last = minted < end ? minted : end;
            total += (last - previousEnd) * (WEIGHT_SCALE / supply);
            if (minted <= end) break;
            previousEnd = end;
        }
    }

    /// @dev The preset is read once per call and passed in, because it cannot change and a vote may
    /// name many keys.
    function _weightOf(uint256 tokenId, bool isFibonacci) private pure returns (uint256) {
        if (!isFibonacci) return WEIGHT_SCALE;
        return WEIGHT_SCALE / KeyfleetPresets.fibonacciLevelSupply(KeyfleetPresets.fibonacciLevelOf(tokenId));
    }

    /// @dev The caster of a key is its current owner or that owner's registered delegate.
    function _requireCaster(uint256 tokenId) private view {
        address owner = FLEET.ownerOf(tokenId);
        if (msg.sender != owner && votingDelegate[owner] != msg.sender) revert NotAuthorizedForKey(tokenId, owner);
    }

    /// @dev YES must exceed half of the total eligible weight, so an abstention counts against.
    function _passed(Proposal storage stored) private view returns (bool) {
        return stored.yesWeight * 2 > stored.totalWeight;
    }

    function _require(uint256 proposalId) private view returns (Proposal storage stored) {
        if (proposalId == 0 || proposalId > proposalCount) revert UnknownProposal(proposalId);
        return _proposals[proposalId];
    }

    function _isFibonacci() private view returns (bool) {
        KeyfleetPresets.Preset preset = FLEET.PRESET();
        return preset == KeyfleetPresets.Preset.FibonacciSyndicate || preset == KeyfleetPresets.Preset.FibonacciCascade;
    }
}
