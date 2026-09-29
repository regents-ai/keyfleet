// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "./Keyfleet.sol";

/// @notice The one fixed vote of a fleet: a proposal that stays open until it is carried out, and a
/// fixed approval rule for each kind.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// There are no councils, no moderators, no rule amendments and no configurable presets, and no
/// windows, delays, expiries, periods or caps. A Decision or a Pay is approved at any moment its
/// YES votes are more than half of all the keys sold so far, `yesVotes * 2 > FLEET.totalMinted()`;
/// a RestrictEdits is approved at any moment its YES votes are at least three fifths of them,
/// `yesVotes * 5 >= FLEET.totalMinted() * 3`. Either way a key that stays silent counts against
/// it. Anyone may carry out an approved proposal, and until someone does it stays open.
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
/// commit. A `Pay` carries an asset, an amount and a recipient, with its reason in the creation
/// event, and, once carried out, has the fleet pay that amount of its shared money. A
/// `RestrictEdits` names a key and whether its edits are to be restricted or unrestricted, and,
/// once carried out, records that in `editsRestricted`, which is read off chain to decide whether
/// the key and its shards may write the fleet's workspace.
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
/// delegation by signature. A majority of keys can approve a decision or a payment the rest of
/// the fleet did not want, and no hidden signer is introduced to prevent that; matching
/// means a payment only ever spends the majority's own share. The only tokens a vote can move are
/// the fleet's shared money, so claim and reserve solvency hold regardless of any vote.
contract KeyfleetVotes is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice What a proposal does once it is carried out.
    enum Kind {
        Decision,
        Pay,
        RestrictEdits
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
    /// @dev A Pay proposal's fields and a RestrictEdits proposal's two fields are zero on every
    /// other kind.
    /// @param kind Decision, Pay or RestrictEdits.
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
    /// @param targetTokenId RestrictEdits only: the key whose edits it restricts or unrestricts.
    /// @param restricted RestrictEdits only: true to restrict, false to unrestrict.
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
        uint256 targetTokenId;
        bool restricted;
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
    /// @notice No key with this id has been sold.
    error KeyNotMinted(uint256 tokenId);
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
    /// @notice YES is not enough of all the keys sold so far for this kind of proposal.
    error NotApproved(uint256 yesVotes, uint256 totalMinted);
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
    /// @param kind Decision, Pay or RestrictEdits.
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

    /// @notice The payload of a Pay proposal, emitted beside its `ProposalCreated`.
    event PayProposed(uint256 indexed proposalId, address indexed asset, uint256 amount, address indexed recipient);

    /// @notice The payload of a RestrictEdits proposal, emitted beside its `ProposalCreated`.
    event RestrictEditsProposed(uint256 indexed proposalId, uint256 indexed targetTokenId, bool restricted);

    /// @notice An owner set or cleared the address that may vote their keys for them.
    event VotingDelegateSet(address indexed owner, address indexed delegate);

    /// @notice Keys were voted, one vote each, or had their vote changed to this one. A key counts
    /// once in the tallies whatever its history.
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);

    /// @notice Keys' votes on a proposal were withdrawn, so they have no vote on it now.
    event VoteWithdrawn(uint256 indexed proposalId, address indexed caller, uint256[] tokenIds);

    /// @notice An approved Decision was recorded. Nothing else happens on chain.
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);

    /// @notice An approved RestrictEdits set whether a key's edits are restricted.
    event EditsRestrictionSet(uint256 indexed targetTokenId, bool restricted, uint256 indexed proposalId);

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
    /// @notice Whether the keys voted to restrict a key's edits, as the latest carried-out
    /// RestrictEdits for that key left it.
    mapping(uint256 tokenId => bool restricted) public editsRestricted;

    mapping(uint256 proposalId => Proposal proposal) private _proposals;

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

    /// @notice Where a proposal stands: open, approved and ready to be carried out, or carried out.
    /// @dev `Approved` is the whole test for a Decision's approval as well as the test `execute`
    /// applies, and it is read at this moment: a later sale can take a proposal back to `Open`.
    function state(uint256 proposalId) external view returns (State) {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) return State.Executed;
        return _approved(stored.kind, stored.yesVotes, FLEET.totalMinted()) ? State.Approved : State.Open;
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

    /// @notice Proposes restricting or unrestricting a key's edits.
    /// @dev Approved only when at least three fifths of all the keys sold vote YES. The key named
    /// must have been sold; it may be the proposer's own. The text is emitted and never stored,
    /// exactly as a Decision's is.
    /// @param tokenId A key the caller owns or is the registered delegate of.
    /// @param targetTokenId The key whose edits to restrict or unrestrict.
    /// @param restricted True to restrict, false to unrestrict.
    /// @param text The reason, for readers.
    /// @param digest Optional exact artifact or commit digest.
    /// @return proposalId The new proposal.
    function proposeRestrictEdits(
        uint256 tokenId,
        uint256 targetTokenId,
        bool restricted,
        string calldata text,
        bytes32 digest
    ) external returns (uint256 proposalId) {
        if (targetTokenId == 0 || targetTokenId > FLEET.totalMinted()) {
            revert KeyNotMinted(targetTokenId);
        }

        proposalId = _propose(tokenId, Kind.RestrictEdits, text, digest);
        Proposal storage stored = _proposals[proposalId];
        stored.targetTokenId = targetTokenId;
        stored.restricted = restricted;
        emit RestrictEditsProposed(proposalId, targetTokenId, restricted);
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
    /// @dev Permissionless: the result is the vote's, not the caller's. The approval rule is read
    /// at this moment against all the keys sold so far: YES must be more than half of them for a
    /// Decision or a Pay and at least three fifths of them for a RestrictEdits, and every key that
    /// stayed silent counts against it.
    ///
    /// A Pay has the fleet pay the recipient and match every key sold that did not vote YES, and
    /// records the match per key and the keys sold, which is what `collect` pays out against. A
    /// RestrictEdits sets `editsRestricted` for its key.
    ///
    /// The proposal is marked carried out before the fleet is called, so a paid asset that calls
    /// back can never carry it out twice. A revert inside the fleet, such as a payment whose matches
    /// do not fit, undoes the mark with everything else, so the attempt consumes nothing and the
    /// proposal stays open.
    /// @param proposalId The proposal to carry out.
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) revert AlreadyExecuted();
        uint256 keys = FLEET.totalMinted();
        uint256 yesVotes = stored.yesVotes;
        Kind kind = stored.kind;
        if (!_approved(kind, yesVotes, keys)) revert NotApproved(yesVotes, keys);

        stored.executed = true;
        emit ProposalExecuted(proposalId, msg.sender);

        if (kind == Kind.Decision) {
            emit DecisionRecorded(proposalId, stored.digest);
        } else if (kind == Kind.Pay) {
            stored.keysSold = keys;
            stored.share = FLEET.payFromBudget(stored.asset, stored.amount, stored.recipient, yesVotes);
        } else {
            uint256 target = stored.targetTokenId;
            bool restricted = stored.restricted;
            editsRestricted[target] = restricted;
            emit EditsRestrictionSet(target, restricted, proposalId);
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

    /// @dev The caster of a key is its current owner or that owner's registered delegate. A token id
    /// that is not a minted key reverts in `ownerOf`.
    function _requireCaster(uint256 tokenId) private view {
        address owner = FLEET.ownerOf(tokenId);
        if (msg.sender != owner && votingDelegate[owner] != msg.sender) revert NotAuthorizedForKey(tokenId, owner);
    }

    /// @dev A RestrictEdits needs YES from at least three fifths of all the keys sold so far; every
    /// other kind needs YES from more than half of them. An abstention counts against either way.
    function _approved(Kind kind, uint256 yesVotes, uint256 keysSold) private pure returns (bool) {
        if (kind == Kind.RestrictEdits) return yesVotes * 5 >= keysSold * 3;
        return yesVotes * 2 > keysSold;
    }

    function _require(uint256 proposalId) private view returns (Proposal storage stored) {
        if (proposalId == 0 || proposalId > proposalCount) revert UnknownProposal(proposalId);
        return _proposals[proposalId];
    }
}
