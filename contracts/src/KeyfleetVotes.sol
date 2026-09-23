// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRegentsAutolaunchFactoryV1} from "./interfaces/IRegentsAutolaunchFactoryV1.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";

/// @notice The one fixed vote of a fleet: a proposal, a fixed window, and a single pass rule.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// There are no councils, no moderators, no rule amendments and no configurable presets. A proposal
/// runs for exactly `VOTING_WINDOW` seconds and passes only if YES exceeds half of the *total*
/// eligible snapshot weight, so an abstention counts against it. Execution happens after the window
/// closes and never before.
///
/// Weight is fixed by the kind and the preset, not by anything anyone can set here. On an
/// `Autolaunch` every key is worth `WEIGHT_SCALE`, whatever the preset. On a `Decision` a Fleet.Tech
/// key is worth `WEIGHT_SCALE` and a Fibonacci key is worth `WEIGHT_SCALE /
/// fibonacciLevelSupply(level)`, floored, which is the fixed-precision approximation of one vote per
/// level. A proposal's eligible set is the token ids `1..snapshotMinted` recorded when it was
/// created, so later mints are ineligible for it and a transfer can never produce a second vote for
/// the same key.
///
/// There are two kinds. A `Decision` records agreement and has no external side effect; its text
/// is carried in the creation event only and an optional digest pins the exact artifact or commit.
/// An `Autolaunch` carries the exact launch envelope the keys approve and, when it passes, has the
/// fleet call the pinned Autolaunch factory once with itself as launcher and treasury. A fleet may
/// propose one only once it has sold the keys its preset requires.
///
/// There are no arbitrary calls here. The two kinds are the whole surface, every payload is fixed
/// at creation, and any change to a payload is a new proposal rather than an edit.
///
/// There is no administrator, no upgrade path, no pause, no cancellation, no quorum tuning and no
/// delegation by signature. This deliberately does not solve a majority takeover: a majority of
/// keys can approve a launch the rest of the fleet did not want, and no hidden signer is introduced
/// to disguise that. No vote moves any of the fleet's tokens, so claim and reserve solvency hold
/// regardless of any vote.
contract KeyfleetVotes is ReentrancyGuard {
    /// @notice What a proposal does when it passes.
    enum Kind {
        Decision,
        Autolaunch
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
    /// mapping so the record every proposal shares stays one fixed-size read.
    /// @param kind Decision or Autolaunch.
    /// @param proposer The address that created it.
    /// @param createdAt Block timestamp of creation.
    /// @param closesAt Last moment plus one: voting is open strictly before this, execution from it.
    /// @param snapshotMinted Keys minted when it was created; the eligible ids are `1..snapshotMinted`.
    /// @param totalWeight Total weight of that eligible set, computed once at creation.
    /// @param yesWeight Weight voted in favour.
    /// @param noWeight Weight voted against.
    /// @param executed Whether it has already executed.
    /// @param digest Optional exact artifact or commit digest; zero means none.
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
    }

    /// @notice The fleet address supplied at construction was zero.
    error ZeroAddress();
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
    /// @notice YES did not exceed half of the total eligible snapshot weight.
    error NotPassed(uint256 yesWeight, uint256 totalWeight);
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
    /// @param kind Decision or Autolaunch.
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

    /// @notice The payload of an Autolaunch proposal, emitted beside its `ProposalCreated`.
    /// @param envelopeHash `keccak256(abi.encode(envelope))`, which fixes exactly what was approved.
    /// The envelope itself is stored and readable with `launchEnvelope`.
    event AutolaunchProposed(uint256 indexed proposalId, bytes32 envelopeHash, uint64 executionExpiry);

    /// @notice An owner set or cleared the address that may vote their keys for them.
    event VotingDelegateSet(address indexed owner, address indexed delegate);

    /// @notice Keys were voted. Each id is counted exactly once for the life of the proposal, and
    /// `weight` is the weight this vote added.
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight, uint256[] tokenIds);

    /// @notice A passed Decision was recorded. Nothing else happens on chain.
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);

    /// @notice A proposal executed. It can never execute again.
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    /// @notice Weight of every key on an Autolaunch and of a Fleet.Tech key on a Decision, and the
    /// numerator of a Fibonacci key's weight on a Decision.
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

    /// @notice Weight of one key on a Decision, from the preset alone. On an Autolaunch every key
    /// weighs `WEIGHT_SCALE` instead.
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

    // --- voting ----------------------------------------------------------

    /// @notice Votes a set of keys for or against a proposal, while its window is open.
    /// @dev Every id must be inside the proposal's snapshot, must not have voted on it before, and
    /// must be owned by the caller or by an owner who has registered the caller as their delegate.
    /// A key that has voted is spent for that proposal: transferring it cannot produce a second
    /// vote, and a key that has not voted yet votes with whoever owns it at the time.
    ///
    /// The whole call reverts if any one id fails, so a caller never half-votes a set by accident.
    /// Each key adds `WEIGHT_SCALE` on an Autolaunch and its `weightOf` on a Decision.
    /// @param proposalId The proposal being voted on.
    /// @param tokenIds The keys to vote, each at most once.
    /// @param support True for YES, false for NO.
    /// @return weight The weight this call added.
    function vote(uint256 proposalId, uint256[] calldata tokenIds, bool support) external returns (uint256 weight) {
        Proposal storage stored = _require(proposalId);
        if (block.timestamp >= stored.closesAt) revert VotingClosed(stored.closesAt);
        if (tokenIds.length == 0) revert NoKeys();

        uint256 snapshotMinted = stored.snapshotMinted;
        bool byLevel = _weighsByLevel(stored.kind);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (tokenId == 0 || tokenId > snapshotMinted) revert KeyNotEligible(tokenId);
            if (hasVoted[proposalId][tokenId]) revert AlreadyVoted(tokenId);
            _requireCaster(tokenId);
            hasVoted[proposalId][tokenId] = true;
            weight += _weightOf(tokenId, byLevel);
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
    /// The proposal is marked executed before the fleet is called, so a launch artifact that calls
    /// back can never execute it twice. Any revert inside the fleet or the factory — a paused
    /// factory, a raise the strategy refuses, a launch that already exists — undoes the mark with
    /// everything else, so the attempt consumes nothing and the proposal stays executable until its
    /// envelope expires or the fleet's launch state moves on.
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
            FLEET.executeAutolaunch(proposalId, _envelopes[proposalId]);
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
        stored.totalWeight = _snapshotWeight(snapshotMinted, _weighsByLevel(kind));
        stored.digest = digest;

        emit ProposalCreated(
            proposalId, kind, msg.sender, stored.closesAt, snapshotMinted, stored.totalWeight, digest, text
        );
    }

    /// @dev One metadata field against the factory's own rule: nonempty and within the byte cap the
    /// factory published. Solidity strings are bytes, and the caps are byte caps, so a field of
    /// multi-byte characters holds fewer of them than the number suggests. Nothing is normalized,
    /// shortened or checked for content here; the factory does not do any of that either.
    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    /// @dev Total weight of the token ids `1..minted`, computed by walking at most twenty levels and
    /// never a single key, so the cost is bounded by the preset rather than by the fleet: creating a
    /// Decision on a Fibonacci fleet holding two keys in one level measured about 146,000 gas, and
    /// on one at the level-20 ceiling about 186,000, with nothing in between depending on how many
    /// keys exist. A proposal weighed one vote per key needs no walk at all.
    function _snapshotWeight(uint256 minted, bool byLevel) private pure returns (uint256 total) {
        if (!byLevel) return minted * WEIGHT_SCALE;

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

    /// @dev Whether keys weigh by level is read once per call and passed in, because it cannot
    /// change and a vote may name many keys.
    function _weightOf(uint256 tokenId, bool byLevel) private pure returns (uint256) {
        if (!byLevel) return WEIGHT_SCALE;
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

    /// @dev Only a Decision on a Fibonacci fleet weighs keys by level. An Autolaunch counts one vote
    /// per key on every preset, and the preset is not read at all.
    function _weighsByLevel(Kind kind) private view returns (bool) {
        return kind == Kind.Decision && _isFibonacci();
    }

    function _isFibonacci() private view returns (bool) {
        KeyfleetPresets.Preset preset = FLEET.PRESET();
        return preset == KeyfleetPresets.Preset.FibonacciSyndicate || preset == KeyfleetPresets.Preset.FibonacciCascade;
    }
}
