// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRegentsAutolaunchFactoryV1} from "./interfaces/IRegentsAutolaunchFactoryV1.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";

/// @notice The one fixed vote of a fleet: a proposal that stays open until it is carried out, and a
/// single approval rule.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// There are no councils, no moderators, no rule amendments and no configurable presets, and no
/// windows, delays, expiries, periods or caps. A proposal is approved at any moment its YES votes
/// are more than half of all the keys sold so far, `yesVotes * 2 > FLEET.totalMinted()`, so a key
/// that stays silent counts against it. Anyone may carry out an approved proposal, and until
/// someone does it stays open.
///
/// Every key is one vote on every kind of proposal, whatever the preset. A key may vote on a
/// proposal only if it last moved — its mint or its latest transfer — in a block before the one
/// the proposal opened in, so buying or moving a key after a proposal opens can never add a vote
/// to it, while every key sold still counts toward "all the keys". The key's owner, or that owner's
/// registered voting delegate, may change the key's vote until the proposal is carried out. A vote
/// a key cast stays counted after the key moves on, and whoever holds the key then, or their
/// delegate, may withdraw it with `withdrawVote` until the proposal is carried out. A withdrawn key
/// has no vote and counts against the proposal, exactly as a silent one does.
///
/// There are three kinds. A `Decision` records agreement and has no external side effect; its
/// text is carried in the creation event only and an optional digest pins the exact artifact or
/// commit. An `Autolaunch` carries the exact launch envelope the keys approve and, once carried
/// out, has the fleet call the pinned Autolaunch factory with itself as launcher and treasury; a
/// fleet may propose one only once it has sold the keys its preset requires. The first one carried
/// out wins; another can be carried out only if that launch's auction fails, and none once a launch
/// has graduated. A `Pay` carries an asset, an amount and a recipient, with its reason in the
/// creation event, and, once carried out, has the fleet pay that amount of its shared money.
///
/// Every payment is matched. When it is carried out, every key sold that did not vote YES — it
/// voted NO, stayed silent, withdrew its vote, or could not vote — is matched with the payment
/// divided by the YES votes, rounded up, and the payment and every match together must fit in the
/// asset's shared money. The fleet sends the matches to this controller, which holds them until
/// `collect` pays each key's match to whoever holds the key when it is collected. The YES keys pay
/// for what they want out of their own share, and everyone else takes theirs out.
///
/// Payments and matches assume an asset that moves exactly the amount asked and whose balances
/// change only by transfers. A token that takes a fee when it moves, or rebases, is not supported:
/// the recipient or the matches can receive less than recorded, and nothing here corrects for it.
///
/// There are no arbitrary calls here. The three kinds are the whole surface, every payload is fixed
/// at creation, and any change to a payload is a new proposal rather than an edit.
///
/// There is no administrator, no upgrade path, no pause, no cancellation, no quorum tuning and no
/// delegation by signature. A majority of keys can approve a launch, a decision or a payment the
/// rest of the fleet did not want, and no hidden signer is introduced to prevent that; matching
/// means a payment only ever spends the majority's own share. The only tokens a vote can move are
/// the fleet's shared money, so claim and reserve solvency hold regardless of any vote.
contract KeyfleetVotes is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice What a proposal does once it is carried out.
    enum Kind {
        Decision,
        Autolaunch,
        Pay
    }

    /// @notice Where a proposal stands right now.
    /// @dev `Open` and `Approved` are both open to votes; `Approved` means it may be carried out now.
    enum State {
        Open,
        Approved,
        Executed
    }

    /// @notice How one key has voted on one proposal.
    enum Choice {
        None,
        Yes,
        No
    }

    /// @notice One proposal. Its payload is fixed at creation; only the tallies move.
    /// @dev An Autolaunch proposal's payload is not here: it is a whole envelope, kept in its own
    /// mapping so the record every proposal shares stays one fixed-size read. A Pay proposal's three
    /// fields are here, and are zero on every other kind.
    /// @param kind Decision, Autolaunch or Pay.
    /// @param proposer The address that created it.
    /// @param openedBlock Block of creation. Keys that last moved before it may vote.
    /// @param yesVotes Keys whose current vote is YES.
    /// @param noVotes Keys whose current vote is NO.
    /// @param executed Whether it has been carried out.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param asset Pay only: the asset to pay from shared money.
    /// @param amount Pay only: atomic units to pay.
    /// @param recipient Pay only: who receives them.
    /// @param share Pay only, once carried out: what each key that did not vote YES may collect.
    /// @param keysSold Pay only, once carried out: the keys sold at that moment. Keys `1..keysSold`
    /// that did not vote YES may collect.
    struct Proposal {
        Kind kind;
        address proposer;
        uint64 openedBlock;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
        bytes32 digest;
        address asset;
        uint256 amount;
        address recipient;
        uint256 share;
        uint256 keysSold;
    }

    /// @notice The fleet address supplied at construction, or a Pay proposal's asset, was zero.
    error ZeroAddress();
    /// @notice A Pay proposal must name a nonzero amount.
    error ZeroAmount();
    /// @notice A Pay recipient may not be zero, the fleet, this controller or the fleet's ledger:
    /// paid to any of them the money is stuck for good.
    error RecipientNotAllowed(address recipient);
    /// @notice No proposal carries this id.
    error UnknownProposal(uint256 proposalId);
    /// @notice The fleet has not sold the keys its preset requires before it may propose a launch.
    error LaunchNotYetEligible(uint256 minted, uint256 required);
    /// @notice The key moved in or after the block this proposal opened in, so it cannot vote on it;
    /// or it was sold after the payment was carried out, so it has no match to collect.
    error KeyNotEligible(uint256 tokenId);
    /// @notice The caller is neither the key's owner nor that owner's registered voting delegate.
    error NotAuthorizedForKey(uint256 tokenId, address owner);
    /// @notice The key's current vote on this proposal is already the one asked for.
    error AlreadyVoted(uint256 tokenId);
    /// @notice A vote must name at least one key.
    error NoKeys();
    /// @notice The proposal has already been carried out. Every proposal is carried out at most once.
    error AlreadyExecuted();
    /// @notice YES is not more than half of all the keys sold so far.
    error NotApproved(uint256 yesVotes, uint256 totalMinted);
    /// @notice One of the launch envelope's five metadata strings was empty. Fields are numbered
    /// `0..4` in the order name, symbol, description, website, image, as the factory numbers them.
    error EmptyMetadataField(uint256 field);
    /// @notice One of the launch envelope's five metadata strings was over its byte cap.
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    /// @notice The required raise was zero or above the largest raise the strategy says an auction
    /// can reach.
    error RaiseOutOfBounds(uint128 requiredRegentRaised);
    /// @notice This proposal is not an Autolaunch, so it carries no launch envelope.
    error NotAnAutolaunch(uint256 proposalId);
    /// @notice Nothing can be collected from this proposal: it is not a carried-out payment.
    error NothingToCollect(uint256 proposalId);
    /// @notice The key has no vote on this proposal to withdraw.
    error NoVote(uint256 tokenId);
    /// @notice The key voted YES on this payment, so it paid its share and has no match.
    error VotedYes(uint256 tokenId);
    /// @notice The key's match of this payment has already been collected.
    error AlreadyCollected(uint256 tokenId);

    /// @notice A proposal was created. `text` is carried here and stored nowhere.
    /// @param proposalId The new proposal.
    /// @param kind Decision, Autolaunch or Pay.
    /// @param proposer The address that created it.
    /// @param openedBlock Block of creation; keys that last moved before it may vote.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param text The proposal text, for readers; the contract never reads it back.
    event ProposalCreated(
        uint256 indexed proposalId,
        Kind indexed kind,
        address indexed proposer,
        uint64 openedBlock,
        bytes32 digest,
        string text
    );

    /// @notice The payload of an Autolaunch proposal, emitted beside its `ProposalCreated`.
    /// @param envelopeHash `keccak256(abi.encode(envelope))`, which fixes exactly what was approved.
    /// The envelope itself is stored and readable with `launchEnvelope`.
    event AutolaunchProposed(uint256 indexed proposalId, bytes32 envelopeHash);

    /// @notice The payload of a Pay proposal, emitted beside its `ProposalCreated`.
    event PayProposed(uint256 indexed proposalId, address indexed asset, uint256 amount, address indexed recipient);

    /// @notice An owner set or cleared the address that may vote their keys for them.
    event VotingDelegateSet(address indexed owner, address indexed delegate);

    /// @notice Keys were voted, one vote each, or had their vote changed to this one. A key counts
    /// once in the tallies whatever its history.
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);

    /// @notice Keys' votes on a proposal were withdrawn, so they have no vote on it now.
    event VoteWithdrawn(uint256 indexed proposalId, address indexed caller, uint256[] tokenIds);

    /// @notice An approved Decision was recorded. Nothing else happens on chain.
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);

    /// @notice A proposal was carried out. It can never be carried out again.
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    /// @notice Keys' matches of a carried-out payment were paid to their owners, `share` each.
    event Collected(uint256 indexed proposalId, uint256 share, uint256[] tokenIds);

    /// @notice The fleet that deployed this controller and holds the keys that vote.
    Keyfleet public immutable FLEET;

    /// @notice Proposals created so far. Proposal ids are `1..proposalCount`.
    uint256 public proposalCount;
    /// @notice The address an owner has authorized to vote their keys. Zero means nobody.
    /// @dev An attached chat agent gets nothing from this; financial authority is registered here
    /// and only here.
    mapping(address owner => address delegate) public votingDelegate;
    /// @notice A key's current vote on a proposal.
    mapping(uint256 proposalId => mapping(uint256 tokenId => Choice choice)) public voteOf;
    /// @notice Whether a key's match of a carried-out payment has been collected.
    mapping(uint256 proposalId => mapping(uint256 tokenId => bool paid)) public collected;

    mapping(uint256 proposalId => Proposal proposal) private _proposals;
    mapping(uint256 proposalId => Keyfleet.LaunchEnvelope envelope) private _envelopes;

    /// @notice Binds this controller to the fleet that deploys it.
    /// @param fleet The fleet whose keys vote here.
    constructor(Keyfleet fleet) {
        if (address(fleet) == address(0)) revert ZeroAddress();
        FLEET = fleet;
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

    /// @notice Where a proposal stands: open, approved and ready to be carried out, or carried out.
    /// @dev `Approved` is the whole test for a Decision's approval as well as the test `execute`
    /// applies, and it is read at this moment: a later sale can take a proposal back to `Open`.
    function state(uint256 proposalId) external view returns (State) {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) return State.Executed;
        return _approved(stored.yesVotes, FLEET.totalMinted()) ? State.Approved : State.Open;
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
    /// is stored so an approved decision can be pinned to an exact artifact or commit; zero means none.
    /// @param tokenId A key the caller owns or is the registered delegate of. It is the caller's
    /// standing to propose and nothing else: it is not a vote.
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
    /// reach, and a fleet whose launch has graduated, which can never launch again. A launch may be
    /// proposed while another is running, because it can be carried out if that one fails.
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
    /// @param tokenId A key the caller owns or is the registered delegate of.
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
        if (FLEET.launchState() == Keyfleet.LaunchState.Graduated) revert Keyfleet.LaunchAlreadyCreated();

        proposalId = _propose(tokenId, Kind.Autolaunch, "", envelope.narrativeDigest);
        _envelopes[proposalId] = envelope;
        emit AutolaunchProposed(proposalId, keccak256(abi.encode(envelope)));
    }

    /// @notice Proposes paying an amount of one asset from the fleet's shared money to a recipient.
    /// @dev The recipient may not be zero, the fleet, this controller or the fleet's ledger. What
    /// the payment may be is not checked here: the payment and its matches must fit in the shared
    /// money when the proposal is carried out, and the YES votes, the keys sold and the shared money
    /// all move until then, so the fleet checks it at that moment and a payment that does not fit
    /// reverts there and stays open for later. The text is emitted and never stored, exactly as a
    /// Decision's is.
    /// @param tokenId A key the caller owns or is the registered delegate of.
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

        proposalId = _propose(tokenId, Kind.Pay, text, digest);
        Proposal storage stored = _proposals[proposalId];
        stored.asset = asset;
        stored.amount = amount;
        stored.recipient = recipient;
        emit PayProposed(proposalId, asset, amount, recipient);
    }

    // --- voting ----------------------------------------------------------

    /// @notice Votes a set of keys for or against a proposal, or changes their votes, until it is
    /// carried out.
    /// @dev Every id must have last moved in a block before the one the proposal opened in, and
    /// must be owned by the caller or by an owner who has registered the caller as their delegate.
    /// A key with no vote adds one to the chosen side; a key with the other vote moves from that
    /// side to this one; a key that already has this vote is refused with `AlreadyVoted`. A key that
    /// moves after the proposal opens can no longer vote or change its vote on it, and the vote it
    /// cast before it moved stays counted until its holder withdraws it with `withdrawVote`.
    ///
    /// The whole call reverts if any one id fails, so a caller never half-votes a set by accident.
    /// @param proposalId The proposal being voted on.
    /// @param tokenIds The keys to vote, each at most once.
    /// @param support True for YES, false for NO.
    function vote(uint256 proposalId, uint256[] calldata tokenIds, bool support) external {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) revert AlreadyExecuted();
        if (tokenIds.length == 0) revert NoKeys();

        Choice choice = support ? Choice.Yes : Choice.No;
        uint64 openedBlock = stored.openedBlock;
        uint256 changed;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireCaster(tokenId);
            if (FLEET.lastMovedBlock(tokenId) >= openedBlock) revert KeyNotEligible(tokenId);
            Choice previous = voteOf[proposalId][tokenId];
            if (previous == choice) revert AlreadyVoted(tokenId);
            if (previous != Choice.None) ++changed;
            voteOf[proposalId][tokenId] = choice;
        }

        if (support) {
            stored.yesVotes += tokenIds.length;
            stored.noVotes -= changed;
        } else {
            stored.noVotes += tokenIds.length;
            stored.yesVotes -= changed;
        }
        emit VoteCast(proposalId, msg.sender, support, tokenIds);
    }

    /// @notice Withdraws a set of keys' votes on a proposal, until it is carried out.
    /// @dev Every id must be owned by the caller or by an owner who has registered the caller as
    /// their delegate, and must have a vote on the proposal, whoever cast it: a key that moved after
    /// voting can have that vote withdrawn by whoever holds it now. When the key last moved does not
    /// matter here, because withdrawing only ever takes a vote away. A withdrawn key has no vote,
    /// so it counts against the proposal and, on a payment, is matched like any key that did not
    /// vote YES; it can vote again only if it could vote at all.
    ///
    /// The whole call reverts if any one id fails, so a caller never half-withdraws a set by accident.
    /// @param proposalId The proposal the votes were cast on.
    /// @param tokenIds The keys whose votes to withdraw, each at most once.
    function withdrawVote(uint256 proposalId, uint256[] calldata tokenIds) external {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) revert AlreadyExecuted();
        if (tokenIds.length == 0) revert NoKeys();

        uint256 yes;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireCaster(tokenId);
            Choice previous = voteOf[proposalId][tokenId];
            if (previous == Choice.None) revert NoVote(tokenId);
            if (previous == Choice.Yes) ++yes;
            delete voteOf[proposalId][tokenId];
        }

        stored.yesVotes -= yes;
        stored.noVotes -= tokenIds.length - yes;
        emit VoteWithdrawn(proposalId, msg.sender, tokenIds);
    }

    // --- execution -------------------------------------------------------

    /// @notice Carries out an approved proposal.
    /// @dev Permissionless: the result is the vote's, not the caller's. The approval rule is
    /// `yesVotes * 2 > FLEET.totalMinted()` at this moment, so YES must be more than half of all
    /// the keys sold so far and every key that stayed silent counts against it.
    ///
    /// A Pay has the fleet pay the recipient and match every key sold that did not vote YES, and
    /// records the match per key and the keys sold, which is what `collect` pays out against.
    ///
    /// The proposal is marked carried out before the fleet is called, so a launch artifact or a
    /// paid asset that calls back can never carry it out twice. Any revert inside the fleet or the
    /// factory — a paused factory, a raise the strategy refuses, a running or graduated launch, a
    /// launch proposal that opened in or before the block a failed launch was created in, a payment
    /// whose matches do not fit — undoes the mark with everything else, so the attempt consumes
    /// nothing and the proposal stays open.
    /// @param proposalId The proposal to carry out.
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) revert AlreadyExecuted();
        uint256 keys = FLEET.totalMinted();
        uint256 yesVotes = stored.yesVotes;
        if (!_approved(yesVotes, keys)) revert NotApproved(yesVotes, keys);

        stored.executed = true;
        emit ProposalExecuted(proposalId, msg.sender);

        if (stored.kind == Kind.Decision) {
            emit DecisionRecorded(proposalId, stored.digest);
        } else if (stored.kind == Kind.Autolaunch) {
            FLEET.executeAutolaunch(proposalId, stored.openedBlock, _envelopes[proposalId]);
        } else {
            stored.keysSold = keys;
            stored.share = FLEET.payFromBudget(stored.asset, stored.amount, stored.recipient, yesVotes);
        }
    }

    // --- matching --------------------------------------------------------

    /// @notice Pays keys their match of a carried-out payment, each to the key's current owner.
    /// @dev Permissionless, because the money only ever goes to whoever owns each key now, never to
    /// the caller. Each key must be one of the keys sold when the payment was carried out, must not
    /// have voted YES on it, and is paid once: a key that voted NO, stayed silent, withdrew its vote,
    /// or moved after the proposal opened and so could not vote is matched alike. A key that voted
    /// YES and then moved keeps its YES, so its new owner has no match, unless they withdrew that
    /// vote before the payment was carried out. The match belongs to the key, not to whoever held
    /// it when the payment was carried out: it is paid to whoever holds the key when it is
    /// collected.
    ///
    /// The whole call reverts if any one id fails. Keys next to each other in `tokenIds` with the
    /// same owner are paid in one transfer, and a token that refuses a transfer can only block its
    /// own payment's matches. Guarded, so a paid asset that calls back cannot collect again or carry
    /// out anything while this call is half done.
    ///
    /// Matches are not shared money. The fleet sent exactly `share` for every key sold that did not
    /// vote YES to this controller when the payment was carried out, so every key that may collect
    /// is covered, and nothing else ever spends it. That holds only for an asset that moves exactly
    /// the amount asked; a token that takes a fee when it moves, or rebases, is not supported.
    /// @param proposalId The carried-out payment.
    /// @param tokenIds The keys to pay, each at most once.
    function collect(uint256 proposalId, uint256[] calldata tokenIds) external nonReentrant {
        Proposal storage stored = _require(proposalId);
        uint256 share = stored.share;
        if (share == 0) revert NothingToCollect(proposalId);
        if (tokenIds.length == 0) revert NoKeys();

        uint256 keysSold = stored.keysSold;
        IERC20 asset = IERC20(stored.asset);
        address owner;
        uint256 owed;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (tokenId > keysSold) revert KeyNotEligible(tokenId);
            if (voteOf[proposalId][tokenId] == Choice.Yes) revert VotedYes(tokenId);
            if (collected[proposalId][tokenId]) revert AlreadyCollected(tokenId);
            collected[proposalId][tokenId] = true;

            address holder = FLEET.ownerOf(tokenId);
            if (holder != owner) {
                if (owed != 0) asset.safeTransfer(owner, owed);
                owner = holder;
                owed = 0;
            }
            owed += share;
        }

        emit Collected(proposalId, share, tokenIds);
        asset.safeTransfer(owner, owed);
    }

    // --- internals -------------------------------------------------------

    /// @dev Records a proposal and the block it opened in. The standing check is the caster check
    /// `vote` applies: the caller owns the named key or is the registered delegate of whoever does.
    function _propose(uint256 tokenId, Kind kind, string memory text, bytes32 digest)
        private
        returns (uint256 proposalId)
    {
        _requireCaster(tokenId);

        proposalId = proposalCount + 1;
        proposalCount = proposalId;

        Proposal storage stored = _proposals[proposalId];
        stored.kind = kind;
        stored.proposer = msg.sender;
        stored.openedBlock = uint64(block.number);
        stored.digest = digest;

        emit ProposalCreated(proposalId, kind, msg.sender, uint64(block.number), digest, text);
    }

    /// @dev One metadata field against the factory's own rule: nonempty and within the byte cap the
    /// factory published. Solidity strings are bytes, and the caps are byte caps, so a field of
    /// multi-byte characters holds fewer of them than the number suggests. Nothing is normalized,
    /// shortened or checked for content here; the factory does not do any of that either.
    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    /// @dev The caster of a key is its current owner or that owner's registered delegate. A token id
    /// that is not a minted key reverts in `ownerOf`.
    function _requireCaster(uint256 tokenId) private view {
        address owner = FLEET.ownerOf(tokenId);
        if (msg.sender != owner && votingDelegate[owner] != msg.sender) revert NotAuthorizedForKey(tokenId, owner);
    }

    /// @dev YES must be more than half of all the keys sold so far, so an abstention counts against.
    function _approved(uint256 yesVotes, uint256 keysSold) private pure returns (bool) {
        return yesVotes * 2 > keysSold;
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
