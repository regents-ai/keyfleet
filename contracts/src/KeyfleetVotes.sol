// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRegentsAutolaunchFactoryV1} from "./interfaces/IRegentsAutolaunchFactoryV1.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";

/// @notice The one fixed vote of a fleet: a proposal, a fixed window, and a single pass rule.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// There are no councils, no moderators, no rule amendments and no configurable presets. A proposal
/// runs for exactly `VOTING_WINDOW` seconds and passes only if YES exceeds half of *all* the keys
/// in its snapshot, so an abstention counts against it. Execution happens after the window closes
/// and never before.
///
/// Every key is one vote on every kind of proposal, whatever the preset. A proposal's eligible set
/// is the token ids `1..snapshotMinted` recorded when it was created, so later mints are ineligible
/// for it and a transfer can never produce a second vote for the same key.
///
/// There are three kinds. A `Decision` records agreement and has no external side effect; its
/// text is carried in the creation event only and an optional digest pins the exact artifact or
/// commit. An `Autolaunch` carries the exact launch envelope the keys approve and, when it passes,
/// has the fleet call the pinned Autolaunch factory once with itself as launcher and treasury. A
/// fleet may propose one only once it has sold the keys its preset requires. A `Pay` carries an
/// asset, an amount and a recipient, with its reason in the creation event, and, when it passes,
/// has the fleet pay that amount of its shared money; it can be proposed only once the launch has
/// graduated or failed, it can execute only until `PAY_EXECUTION_WINDOW` after its vote closes,
/// and the fleet caps what all passed payments together can take from each asset's shared
/// money per period.
///
/// There are no arbitrary calls here. The three kinds are the whole surface, every payload is fixed
/// at creation, and any change to a payload is a new proposal rather than an edit.
///
/// There is no administrator, no upgrade path, no pause, no cancellation, no quorum tuning and no
/// delegation by signature. This deliberately does not solve a majority takeover: a majority of
/// keys can approve a launch or a payment the rest of the fleet did not want, and no hidden signer
/// is introduced to disguise that. The only tokens a vote can move are the fleet's shared money, within
/// the fleet's per-period cap, so claim and reserve solvency hold regardless of any vote.
contract KeyfleetVotes is ReentrancyGuard {
    /// @notice What a proposal does when it passes.
    enum Kind {
        Decision,
        Autolaunch,
        Pay
    }

    /// @notice Where a proposal stands right now.
    enum State {
        Active,
        Defeated,
        Passed,
        Executed
    }

    /// @notice One proposal. Everything a vote is counted against is fixed at creation.
    /// @dev An Autolaunch proposal's payload is not here: it is a whole envelope, kept in its own
    /// mapping so the record every proposal shares stays one fixed-size read. A Pay proposal's three
    /// fields are here, and are zero on every other kind.
    /// @param kind Decision, Autolaunch or Pay.
    /// @param proposer The address that created it.
    /// @param createdAt Block timestamp of creation.
    /// @param closesAt Last moment plus one: voting is open strictly before this, execution from it.
    /// @param snapshotMinted Keys minted when it was created; the eligible ids are `1..snapshotMinted`
    /// and each is one vote.
    /// @param yesVotes Keys voted in favour.
    /// @param noVotes Keys voted against.
    /// @param executed Whether it has already executed.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param asset Pay only: the asset to pay from shared money.
    /// @param amount Pay only: atomic units to pay.
    /// @param recipient Pay only: who receives them.
    struct Proposal {
        Kind kind;
        address proposer;
        uint64 createdAt;
        uint64 closesAt;
        uint256 snapshotMinted;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
        bytes32 digest;
        address asset;
        uint256 amount;
        address recipient;
    }

    /// @notice The fleet address supplied at construction, or a Pay proposal's asset, was zero.
    error ZeroAddress();
    /// @notice A Pay proposal must name a nonzero amount.
    error ZeroAmount();
    /// @notice A Pay recipient may not be zero, the fleet, this controller or the fleet's ledger:
    /// paid to any of them the money is stuck for good.
    error RecipientNotAllowed(address recipient);
    /// @notice The voting window is outside `MIN_VOTING_WINDOW..MAX_VOTING_WINDOW`.
    error VotingWindowOutOfBounds(uint64 window);
    /// @notice No proposal carries this id.
    error UnknownProposal(uint256 proposalId);
    /// @notice The fleet has not sold the keys its preset requires before it may propose a launch.
    error LaunchNotYetEligible(uint256 minted, uint256 required);
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
    /// @notice YES did not exceed half of the keys in the proposal's snapshot.
    error NotPassed(uint256 yesVotes, uint256 snapshotMinted);
    /// @notice One of the launch envelope's five metadata strings was empty. Fields are numbered
    /// `0..4` in the order name, symbol, description, website, image, as the factory numbers them.
    error EmptyMetadataField(uint256 field);
    /// @notice One of the launch envelope's five metadata strings was over its byte cap.
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    /// @notice The required raise was zero or above the largest raise the strategy says an auction
    /// can reach.
    error RaiseOutOfBounds(uint128 requiredRegentRaised);
    /// @notice The launch envelope would expire at or before the vote on it closes, so it could
    /// never execute.
    error ExpiryNotAfterClose(uint64 executionExpiry, uint64 closesAt);
    /// @notice This proposal is not an Autolaunch, so it carries no launch envelope.
    error NotAnAutolaunch(uint256 proposalId);

    /// @notice A proposal was created. `text` is carried here and stored nowhere.
    /// @param proposalId The new proposal.
    /// @param kind Decision, Autolaunch or Pay.
    /// @param proposer The address that created it.
    /// @param closesAt When voting closes and execution becomes possible.
    /// @param snapshotMinted Keys minted at creation; the eligible ids are `1..snapshotMinted`, one
    /// vote each.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param text The proposal text, for readers; the contract never reads it back.
    event ProposalCreated(
        uint256 indexed proposalId,
        Kind indexed kind,
        address indexed proposer,
        uint64 closesAt,
        uint256 snapshotMinted,
        bytes32 digest,
        string text
    );

    /// @notice The payload of an Autolaunch proposal, emitted beside its `ProposalCreated`.
    /// @param envelopeHash `keccak256(abi.encode(envelope))`, which fixes exactly what was approved.
    /// The envelope itself is stored and readable with `launchEnvelope`.
    event AutolaunchProposed(uint256 indexed proposalId, bytes32 envelopeHash, uint64 executionExpiry);

    /// @notice The payload of a Pay proposal, emitted beside its `ProposalCreated`.
    /// @param executionExpiry Last block timestamp at which the passed payment may execute:
    /// `closesAt + PAY_EXECUTION_WINDOW`.
    event PayProposed(
        uint256 indexed proposalId,
        address indexed asset,
        uint256 amount,
        address indexed recipient,
        uint64 executionExpiry
    );

    /// @notice An owner set or cleared the address that may vote their keys for them.
    event VotingDelegateSet(address indexed owner, address indexed delegate);

    /// @notice Keys were voted, one vote each. Each id is counted exactly once for the life of the
    /// proposal.
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);

    /// @notice A passed Decision was recorded. Nothing else happens on chain.
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);

    /// @notice A proposal executed. It can never execute again.
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    /// @notice Shortest voting window a fleet may be deployed with. Anything briefer could close
    /// before holders in other time zones had a chance to see the proposal at all.
    uint64 public constant MIN_VOTING_WINDOW = 1 hours;
    /// @notice Longest voting window a fleet may be deployed with. Anything longer would leave a
    /// passed proposal executing against a fleet nobody recognizes any more.
    uint64 public constant MAX_VOTING_WINDOW = 30 days;
    /// @notice How long after its vote closes a passed Pay may execute, the last second included.
    /// After that it never can, so a payment a past majority approved cannot wait for shared money to
    /// grow and be taken long after those keys have changed hands. Equal to the pay period, so a
    /// payment over what is left of one period's cap can still fit once the next period begins.
    uint64 public constant PAY_EXECUTION_WINDOW = 30 days;

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
    mapping(uint256 proposalId => Keyfleet.LaunchEnvelope envelope) private _envelopes;

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

    /// @notice The whole proposal record.
    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _require(proposalId);
    }

    /// @notice The exact launch envelope an Autolaunch proposal approves.
    /// @dev Fixed at creation and never edited: changing anything in it means a new proposal.
    function launchEnvelope(uint256 proposalId) external view returns (Keyfleet.LaunchEnvelope memory) {
        if (_require(proposalId).kind != Kind.Autolaunch) revert NotAnAutolaunch(proposalId);
        return _envelopes[proposalId];
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

    /// @notice Proposes the exact launch the fleet would create through the pinned Autolaunch
    /// factory, with itself as launcher and treasury.
    /// @dev A fleet may propose a launch only once it has sold the keys its preset requires: a
    /// Fibonacci fleet the last key of level 7, `FIBONACCI_AUTOLAUNCH_MIN_KEYS`, and a Classic or
    /// Accelerant fleet `FLEET_TECH_AUTOLAUNCH_MIN_KEYS`. Anything earlier is refused with
    /// `LaunchNotYetEligible`, before the factory is asked anything.
    ///
    /// Everything that could make the approved call impossible on its own terms is checked
    /// here, so the keys are never asked to vote on a launch that could never happen: the five
    /// metadata strings against the byte caps, the raise against the largest one an auction can
    /// reach, an expiry that would fall at or before the vote closes, and a fleet that has already
    /// created its launch.
    ///
    /// The caps and the raise ceiling are not copied into this repository. They are read from the
    /// pinned factory and from the strategy it is bound to, in this call, so the figures a proposal
    /// is judged by are always the ones the target itself publishes and this controller can never
    /// hold a stale opinion of what the target will accept. The factory and the strategy check
    /// their own rules again on the call itself and remain the authority on both of theirs.
    ///
    /// Nothing about the factory's own state is checked here, because it is not this fleet's to
    /// predict: a factory that is paused when the proposal is made may well be open when it
    /// executes, and the execution reverts harmlessly if it is not.
    ///
    /// The envelope's narrative digest becomes the proposal's digest, which is what pins the launch
    /// to the content-addressed narrative the keys read. The envelope itself is stored whole and
    /// never edited; any change to it is a new proposal.
    /// @param tokenId An eligible key the caller owns or is the registered delegate of.
    /// @param envelope The exact launch to approve.
    /// @return proposalId The new proposal.
    function proposeAutolaunch(uint256 tokenId, Keyfleet.LaunchEnvelope calldata envelope)
        external
        returns (uint256 proposalId)
    {
        uint256 minted = FLEET.totalMinted();
        uint256 required = _isFibonacci()
            ? KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS
            : KeyfleetPresets.FLEET_TECH_AUTOLAUNCH_MIN_KEYS;
        if (minted < required) revert LaunchNotYetEligible(minted, required);

        IRegentsAutolaunchFactoryV1 factory = FLEET.FACTORY();
        _requireBytes(0, bytes(envelope.name).length, factory.MAX_NAME_BYTES());
        _requireBytes(1, bytes(envelope.symbol).length, factory.MAX_SYMBOL_BYTES());
        _requireBytes(2, bytes(envelope.description).length, factory.MAX_DESCRIPTION_BYTES());
        _requireBytes(3, bytes(envelope.website).length, factory.MAX_WEBSITE_BYTES());
        _requireBytes(4, bytes(envelope.image).length, factory.MAX_IMAGE_BYTES());
        if (
            envelope.requiredRegentRaised == 0
                || envelope.requiredRegentRaised > factory.strategy().MAX_REACHABLE_RAISE()
        ) {
            revert RaiseOutOfBounds(envelope.requiredRegentRaised);
        }
        if (FLEET.launchState() != Keyfleet.LaunchState.NotCreated) revert Keyfleet.LaunchAlreadyCreated();

        proposalId = _propose(tokenId, Kind.Autolaunch, "", envelope.narrativeDigest);
        uint64 closesAt = _proposals[proposalId].closesAt;
        if (envelope.executionExpiry <= closesAt) revert ExpiryNotAfterClose(envelope.executionExpiry, closesAt);

        _envelopes[proposalId] = envelope;
        emit AutolaunchProposed(proposalId, keccak256(abi.encode(envelope)), envelope.executionExpiry);
    }

    /// @notice Proposes paying an amount of one asset from the fleet's shared money to a recipient.
    /// @dev Refused with the fleet's `LaunchNotSettled` until the launch has graduated or failed,
    /// because before then shared money is not the keys' to spend. The recipient may not be zero, the
    /// fleet, this controller or the fleet's ledger. What shared money and the period cap allow is not
    /// checked here: both move with every receipt and every other payment, so the fleet
    /// checks them at execution, and a payment over what is left of the cap reverts there and stays
    /// executable in a later period until `PAY_EXECUTION_WINDOW` after the vote closes. The text is
    /// emitted and never stored, exactly as a Decision's is.
    /// @param tokenId An eligible key the caller owns or is the registered delegate of.
    /// @param asset The asset to pay.
    /// @param amount Atomic units to pay.
    /// @param recipient Who receives them.
    /// @param text The reason for the payment, for readers.
    /// @param digest Optional exact artifact or commit digest, such as the invoice or the work paid for.
    /// @return proposalId The new proposal.
    function proposePay(
        uint256 tokenId,
        address asset,
        uint256 amount,
        address recipient,
        string calldata text,
        bytes32 digest
    ) external returns (uint256 proposalId) {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (
            recipient == address(0) || recipient == address(FLEET) || recipient == address(this)
                || recipient == address(FLEET.REWARDS())
        ) revert RecipientNotAllowed(recipient);
        if (!FLEET.launchSettled()) revert Keyfleet.LaunchNotSettled();

        proposalId = _propose(tokenId, Kind.Pay, text, digest);
        Proposal storage stored = _proposals[proposalId];
        stored.asset = asset;
        stored.amount = amount;
        stored.recipient = recipient;
        emit PayProposed(proposalId, asset, amount, recipient, stored.closesAt + PAY_EXECUTION_WINDOW);
    }

    // --- voting ----------------------------------------------------------

    /// @notice Votes a set of keys for or against a proposal, while its window is open.
    /// @dev Every id must be inside the proposal's snapshot, must not have voted on it before, and
    /// must be owned by the caller or by an owner who has registered the caller as their delegate.
    /// A key that has voted is spent for that proposal: transferring it cannot produce a second
    /// vote, and a key that has not voted yet votes with whoever owns it at the time.
    ///
    /// The whole call reverts if any one id fails, so a caller never half-votes a set by accident.
    /// Each key adds one vote.
    /// @param proposalId The proposal being voted on.
    /// @param tokenIds The keys to vote, each at most once.
    /// @param support True for YES, false for NO.
    function vote(uint256 proposalId, uint256[] calldata tokenIds, bool support) external {
        Proposal storage stored = _require(proposalId);
        if (block.timestamp >= stored.closesAt) revert VotingClosed(stored.closesAt);
        if (tokenIds.length == 0) revert NoKeys();

        uint256 snapshotMinted = stored.snapshotMinted;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (tokenId == 0 || tokenId > snapshotMinted) revert KeyNotEligible(tokenId);
            if (hasVoted[proposalId][tokenId]) revert AlreadyVoted(tokenId);
            _requireCaster(tokenId);
            hasVoted[proposalId][tokenId] = true;
        }

        if (support) stored.yesVotes += tokenIds.length;
        else stored.noVotes += tokenIds.length;
        emit VoteCast(proposalId, msg.sender, support, tokenIds);
    }

    // --- execution -------------------------------------------------------

    /// @notice Executes a proposal that passed, once its window has closed.
    /// @dev Permissionless: the result is the vote's, not the caller's. The pass rule is
    /// `yesVotes * 2 > snapshotMinted`, so YES must exceed half of *all* the keys in the snapshot
    /// and every key that stayed silent counts against it.
    ///
    /// The proposal is marked executed before the fleet is called, so a launch artifact or a paid
    /// asset that calls back can never execute it twice. Any revert inside the fleet or the
    /// factory — a paused factory, a raise the strategy refuses, a launch that already exists, a
    /// payment over what is left of the period cap — undoes the mark with everything else, so the
    /// attempt consumes nothing. An Autolaunch then stays executable until its envelope expires or
    /// the fleet's launch state moves on; a Pay stays executable until `PAY_EXECUTION_WINDOW` after
    /// its vote closes, the last second included, and is refused with the fleet's `ProposalExpired`
    /// from the second after.
    /// @param proposalId The proposal to execute.
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage stored = _require(proposalId);
        if (block.timestamp < stored.closesAt) revert VotingOpen(stored.closesAt);
        if (stored.executed) revert AlreadyExecuted();
        if (!_passed(stored)) revert NotPassed(stored.yesVotes, stored.snapshotMinted);

        stored.executed = true;
        emit ProposalExecuted(proposalId, msg.sender);

        if (stored.kind == Kind.Decision) {
            emit DecisionRecorded(proposalId, stored.digest);
        } else if (stored.kind == Kind.Autolaunch) {
            FLEET.executeAutolaunch(proposalId, _envelopes[proposalId]);
        } else {
            uint64 executionExpiry = stored.closesAt + PAY_EXECUTION_WINDOW;
            if (block.timestamp > executionExpiry) revert Keyfleet.ProposalExpired(executionExpiry);
            FLEET.payFromBudget(stored.asset, stored.amount, stored.recipient);
        }
    }

    // --- internals -------------------------------------------------------

    /// @dev Records a proposal and freezes its eligible set in the same call. The
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
        stored.digest = digest;

        emit ProposalCreated(proposalId, kind, msg.sender, stored.closesAt, snapshotMinted, digest, text);
    }

    /// @dev One metadata field against the factory's own rule: nonempty and within the byte cap the
    /// factory published. Solidity strings are bytes, and the caps are byte caps, so a field of
    /// multi-byte characters holds fewer of them than the number suggests. Nothing is normalized,
    /// shortened or checked for content here; the factory does not do any of that either.
    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    /// @dev The caster of a key is its current owner or that owner's registered delegate.
    function _requireCaster(uint256 tokenId) private view {
        address owner = FLEET.ownerOf(tokenId);
        if (msg.sender != owner && votingDelegate[owner] != msg.sender) revert NotAuthorizedForKey(tokenId, owner);
    }

    /// @dev YES must exceed half of the keys in the snapshot, so an abstention counts against.
    function _passed(Proposal storage stored) private view returns (bool) {
        return stored.yesVotes * 2 > stored.snapshotMinted;
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
