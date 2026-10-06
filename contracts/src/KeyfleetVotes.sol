// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresence} from "./KeyfleetPresence.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";

/// @notice The one fixed vote of a fleet: a proposal that stays open until it is carried out, and a
/// fixed approval rule for each kind.
/// @dev One instance is permanently bound to one fleet. It is deployed straight after the fleet, at
/// the address the fleet was given for it, and refuses to deploy for a fleet that names another
/// controller. There are no councils, no moderators, no rule amendments and no configurable
/// presets, and no windows, delays, expiries, periods or caps. A Decision is approved at any moment its
/// YES votes are more than half of all the keys sold so far, `yesVotes * 2 > FLEET.totalMinted()`;
/// a RestrictEdits is approved at any moment its YES votes are at least three fifths of them,
/// `yesVotes * 5 >= FLEET.totalMinted() * 3`. Either way a key that stays silent counts against
/// it. Anyone may carry out an approved proposal, and until someone does it stays open.
///
/// Every key is one vote on every kind of proposal, whatever the preset, and every key sold counts
/// toward "all the keys". The key's current owner may vote it or change its vote until the
/// proposal is carried out, whenever the key was bought or last moved: a key has one vote per
/// proposal, and moving it hands that one vote to its new holder. So may any wallet holding an
/// active shard of the key (`KeyfleetShards`) while the key's agent voting is on, which it is unless
/// the owner turned it off. Whoever may vote a key may withdraw its vote with `withdrawVote` until
/// the proposal is carried out. A withdrawn key has no vote and counts against the proposal,
/// exactly as a silent one does.
///
/// This controller also records which keys are present (`KeyfleetPresence`): a key is present for
/// 48 hours after its owner or any wallet holding an active shard of it renews it with `present`,
/// or it is voted or proposed with, and stops being present the moment it changes hands. Opening a
/// proposal requires every expired presence to have been swept, renews the proposer's key, and
/// records the opening revision, time and exact count of present keys.
///
/// There are two kinds. A `Decision` records agreement and has no external side effect; its
/// text is carried in the creation event only and an optional digest pins the exact artifact or
/// commit. A `RestrictEdits` names a key and whether its edits are to be restricted or
/// unrestricted, and, once carried out, records that in `editsRestricted`, which is read off chain
/// to decide whether the key and its shards may write the fleet's workspace.
///
/// No vote moves money here. The fleet's capital is held by its `KeyfleetTreasury`.
///
/// Renewing and voting may also be signed and handed to anyone to submit (`presentBySig`,
/// `voteBySig`). A signed message names its keys in ascending order and binds each key's ownership
/// epoch and delegation revision and the signer's nonce, so a change of hands, any change to the
/// key's shards or agent voting, or a submission of the same message twice voids it. Signatures are
/// checked with OpenZeppelin `SignatureChecker`, which accepts ordinary wallets and contract wallets
/// (ERC-1271). The signer must be allowed to act for every key when the message is submitted, exactly
/// as if they had sent it themselves; the submitter needs no standing.
///
/// There is no administrator, no upgrade path, no pause, no cancellation and no quorum tuning. A
/// majority of keys can approve a decision the rest of the fleet did not want, and no hidden signer
/// is introduced to prevent that.
contract KeyfleetVotes is EIP712, Nonces {
    using KeyfleetPresence for KeyfleetPresence.Queue;

    /// @notice What a proposal does once it is carried out.
    enum Kind {
        Decision,
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
    /// @dev A RestrictEdits proposal's two fields are zero on a Decision.
    /// @param kind Decision or RestrictEdits.
    /// @param proposer The address that created it.
    /// @param openRevision The presence revision recorded at opening.
    /// @param openedAt The time it opened.
    /// @param e0 How many keys were present when it opened, counted after every due expiry was
    /// swept. Never zero: the proposer's key is renewed first.
    /// @param yesVotes Keys whose current vote is YES.
    /// @param noVotes Keys whose current vote is NO.
    /// @param executed Whether it has been carried out.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param targetTokenId RestrictEdits only: the key whose edits it restricts or unrestricts.
    /// @param restricted RestrictEdits only: true to restrict, false to unrestrict.
    struct Proposal {
        Kind kind;
        address proposer;
        uint48 openRevision;
        uint64 openedAt;
        uint32 e0;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
        bytes32 digest;
        uint256 targetTokenId;
        bool restricted;
    }

    /// @notice The fleet does not name this contract as its voting controller.
    error WrongFleet(address fleet);
    /// @notice No proposal carries this id.
    error UnknownProposal(uint256 proposalId);
    /// @notice No key with this id has been sold.
    error KeyNotMinted(uint256 tokenId);
    /// @notice Only the fleet reports a key changing hands.
    error OnlyFleet();
    /// @notice Expired presences are still queued after this call's sweep, so the count of present
    /// keys is not exact; `sweepExpired` must run before a proposal can open.
    error MaintenanceRequired();
    /// @notice The account may not act for this key: it neither owns the key nor holds an active
    /// shard of it, or, to vote or propose, the key's agent voting is off.
    error NotAuthorizedForKey(uint256 tokenId, address account);
    /// @notice A signed message's deadline has passed.
    error SignatureExpired(uint256 deadline);
    /// @notice The signature is not the signer's over this exact message.
    error InvalidSignature(address signer);
    /// @notice A signed message's keys are not in strictly ascending order.
    error KeysNotAscending();
    /// @notice The key's current vote on this proposal is already the one asked for.
    error AlreadyVoted(uint256 tokenId);
    /// @notice A vote must name at least one key.
    error NoKeys();
    /// @notice The proposal has already been carried out. Every proposal is carried out at most once.
    error AlreadyExecuted();
    /// @notice YES is not enough of all the keys sold so far for this kind of proposal.
    error NotApproved(uint256 yesVotes, uint256 totalMinted);
    /// @notice The key has no vote on this proposal to withdraw.
    error NoVote(uint256 tokenId);

    /// @notice A proposal was created. `text` is carried here and stored nowhere.
    /// @param proposalId The new proposal.
    /// @param kind Decision or RestrictEdits.
    /// @param proposer The address that created it.
    /// @param openRevision The presence revision recorded at opening.
    /// @param openedAt The time it opened.
    /// @param e0 How many keys were present when it opened.
    /// @param digest Optional exact artifact or commit digest; zero means none.
    /// @param text The proposal text, for readers; the contract never reads it back.
    event ProposalCreated(
        uint256 indexed proposalId,
        Kind indexed kind,
        address indexed proposer,
        uint48 openRevision,
        uint64 openedAt,
        uint32 e0,
        bytes32 digest,
        string text
    );

    /// @notice A key stopped being present because it changed hands.
    event PresenceCleared(uint256 indexed tokenId);

    /// @notice Expired presences were removed from the queue.
    /// @param removed How many were removed.
    /// @param due Whether expired presences are still queued.
    event Swept(uint256 removed, bool due);

    /// @notice A key was renewed: it is present until `at` plus 48 hours, unless it changes hands
    /// first.
    /// @param tokenId The key.
    /// @param at The time of the renewal.
    /// @param blockNumber The block of the renewal, for audit.
    /// @param epoch The key's ownership epoch the renewal belongs to.
    event Present(uint256 indexed tokenId, uint64 at, uint64 blockNumber, uint64 epoch);

    /// @notice The payload of a RestrictEdits proposal, emitted beside its `ProposalCreated`.
    event RestrictEditsProposed(uint256 indexed proposalId, uint256 indexed targetTokenId, bool restricted);

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

    /// @notice How many expired presences opening a proposal sweeps before it gives up with
    /// `MaintenanceRequired`.
    uint256 public constant SWEEP_IN_PROPOSE = 256;

    /// @notice How long a renewal keeps a key present: 48 hours, in seconds.
    uint64 public constant PRESENCE_WINDOW = KeyfleetPresence.WINDOW;

    /// @notice The EIP-712 type of a signed renewal. The key ids, epochs and delegation revisions
    /// are each hashed as EIP-712 arrays.
    bytes32 public constant PRESENT_TYPEHASH = keccak256(
        "Present(address fleet,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)"
    );
    /// @notice The EIP-712 type of a signed vote, a different type from a renewal. `choice` is 1 for
    /// YES and 2 for NO.
    bytes32 public constant BALLOT_TYPEHASH = keccak256(
        "Ballot(uint256 proposalId,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)"
    );

    /// @notice The fleet that deployed this controller and holds the keys that vote.
    Keyfleet public immutable FLEET;
    /// @notice The fleet's shard record, which says which wallets may act for a key.
    KeyfleetShards public immutable SHARDS;

    /// @notice Proposals created so far. Proposal ids are `1..proposalCount`.
    uint256 public proposalCount;
    /// @notice A key's current vote on a proposal.
    mapping(uint256 proposalId => mapping(uint256 tokenId => Choice choice)) public voteOf;
    /// @notice Whether the keys voted to restrict a key's edits, as the latest carried-out
    /// RestrictEdits for that key left it.
    mapping(uint256 tokenId => bool restricted) public editsRestricted;

    mapping(uint256 proposalId => Proposal proposal) private _proposals;
    KeyfleetPresence.Queue private _presence;

    /// @notice Binds this controller to its fleet.
    /// @param fleet The fleet whose keys vote here, which must name this contract's address as its
    /// voting controller.
    constructor(Keyfleet fleet) EIP712("KeyfleetVotes", "1") {
        if (address(fleet.VOTES()) != address(this)) revert WrongFleet(address(fleet));
        FLEET = fleet;
        SHARDS = fleet.SHARDS();
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

    /// @notice Whether a key is present now: renewed under its current owner less than 48 hours ago.
    function isActive(uint256 tokenId) external view returns (bool) {
        return _presence.isActive(tokenId);
    }

    /// @notice When a key was last renewed under its current owner; zero if it changed hands since
    /// or was never renewed.
    function lastActiveAt(uint256 tokenId) external view returns (uint64) {
        return _presence.lastActiveAt(tokenId);
    }

    /// @notice Whether a key was present when a proposal opened, as recorded at its opening
    /// revision, so a renewal or a change of hands in the same block falls on the right side.
    function wasActiveAtOpening(uint256 proposalId, uint256 tokenId) external view returns (bool) {
        Proposal storage stored = _require(proposalId);
        return _presence.wasActive(tokenId, stored.openRevision, stored.openedAt);
    }

    /// @notice The presence queue's ends and its entry count. `queued` includes expired entries
    /// no sweep has removed yet, so it is the exact count of present keys only when nothing is due.
    function presenceQueue() external view returns (uint32 head, uint32 tail, uint32 queued) {
        return (_presence.head, _presence.tail, _presence.queued);
    }

    /// @notice A key's queue entry: its neighbours and when it expires, all zero when not queued.
    function presenceEntry(uint256 tokenId) external view returns (uint32 prev, uint32 next, uint64 expiresAt) {
        KeyfleetPresence.Node storage node = _presence.node[tokenId];
        return (node.prev, node.next, node.expiresAt);
    }

    /// @notice The latest presence revision.
    function presenceRevision() external view returns (uint48) {
        return _presence.revision;
    }

    // --- presence --------------------------------------------------------

    /// @notice Renews keys: each is present for the next 48 hours unless it changes hands first.
    /// @dev The caller must own every key named or hold an active shard of it; agent voting does
    /// not matter here. A key renewed again moves to the back of the queue; it is never counted
    /// twice. Renewing keys changes no open proposal.
    /// @param tokenIds The keys to renew, each at most once.
    function present(uint256[] calldata tokenIds) external {
        _present(msg.sender, tokenIds);
    }

    /// @notice Renews keys on a signed message, which anyone may submit.
    /// @dev The signer must be allowed to renew every key now, exactly as for `present`.
    /// @param tokenIds The keys, in strictly ascending order.
    /// @param signer The account that signed.
    /// @param deadline The last timestamp the message may be submitted at.
    /// @param signature The signer's signature over the EIP-712 `Present` message.
    function presentBySig(uint256[] calldata tokenIds, address signer, uint256 deadline, bytes calldata signature)
        external
    {
        (bytes32 ids, bytes32 epochs, bytes32 revisions) = _keyState(tokenIds);
        bytes32 structHash = keccak256(
            abi.encode(PRESENT_TYPEHASH, address(FLEET), ids, epochs, revisions, signer, _useNonce(signer), deadline)
        );
        _requireSigned(structHash, signer, deadline, signature);
        _present(signer, tokenIds);
    }

    /// @notice Ends a key's presence because it changed hands. Only the fleet calls this, from every
    /// transfer.
    function onKeyMoved(uint256 tokenId) external {
        if (msg.sender != address(FLEET)) revert OnlyFleet();
        _presence.clear(tokenId);
        emit PresenceCleared(tokenId);
    }

    /// @notice Removes up to `limit` expired presences from the queue. Anyone may call it; it
    /// renews nothing and changes no proposal.
    /// @return removed How many were removed.
    /// @return due Whether expired presences are still queued.
    function sweepExpired(uint256 limit) external returns (uint256 removed, bool due) {
        return _sweep(limit);
    }

    // --- proposals -------------------------------------------------------

    /// @notice Proposes a Decision: text that records agreement, with no automatic side effect.
    /// @dev The text is emitted and never stored, because nothing on chain reads it back. The digest
    /// is stored so an approved decision can be pinned to an exact artifact or commit; zero means none.
    /// @param tokenId A key the caller may vote. It is the caller's standing to propose and nothing
    /// else: it is not a vote.
    /// @param text The proposal text, for readers.
    /// @param digest Optional exact artifact or commit digest.
    /// @return proposalId The new proposal.
    function proposeDecision(uint256 tokenId, string calldata text, bytes32 digest)
        external
        returns (uint256 proposalId)
    {
        return _propose(tokenId, Kind.Decision, text, digest);
    }

    /// @notice Proposes restricting or unrestricting a key's edits.
    /// @dev Approved only when at least three fifths of all the keys sold vote YES. The key named
    /// must have been sold; it may be the proposer's own. The text is emitted and never stored,
    /// exactly as a Decision's is.
    /// @param tokenId A key the caller may vote.
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
    /// carried out, and renews each key.
    /// @dev The caller must own every key named, or hold an active shard of it while its agent
    /// voting is on. A key with no vote adds one to the chosen side; a key with the other vote
    /// moves from that side to this one; a key that already has this vote is refused with
    /// `AlreadyVoted`. A key that moved keeps the vote it had, and its new holder may change it.
    ///
    /// The whole call reverts if any one id fails, so a caller never half-votes a set by accident.
    /// @param proposalId The proposal being voted on.
    /// @param tokenIds The keys to vote, each at most once.
    /// @param support True for YES, false for NO.
    function vote(uint256 proposalId, uint256[] calldata tokenIds, bool support) external {
        _vote(msg.sender, proposalId, tokenIds, support);
    }

    /// @notice Votes keys on a signed message, which anyone may submit.
    /// @dev The signer must be allowed to vote every key now, exactly as for `vote`, and is the
    /// voter the vote is recorded under.
    /// @param proposalId The proposal being voted on.
    /// @param tokenIds The keys, in strictly ascending order.
    /// @param support True for YES, false for NO.
    /// @param signer The account that signed.
    /// @param deadline The last timestamp the message may be submitted at.
    /// @param signature The signer's signature over the EIP-712 `Ballot` message.
    function voteBySig(
        uint256 proposalId,
        uint256[] calldata tokenIds,
        bool support,
        address signer,
        uint256 deadline,
        bytes calldata signature
    ) external {
        (bytes32 ids, bytes32 epochs, bytes32 revisions) = _keyState(tokenIds);
        bytes32 structHash = keccak256(
            abi.encode(
                BALLOT_TYPEHASH,
                proposalId,
                ids,
                epochs,
                revisions,
                support ? Choice.Yes : Choice.No,
                signer,
                _useNonce(signer),
                deadline
            )
        );
        _requireSigned(structHash, signer, deadline, signature);
        _vote(signer, proposalId, tokenIds, support);
    }

    /// @dev Votes keys for `voter`, who has been authenticated as the caller or a signer.
    function _vote(address voter, uint256 proposalId, uint256[] calldata tokenIds, bool support) private {
        Proposal storage stored = _require(proposalId);
        if (stored.executed) revert AlreadyExecuted();
        if (tokenIds.length == 0) revert NoKeys();

        Choice choice = support ? Choice.Yes : Choice.No;
        uint256 changed;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireGovernor(tokenId, voter);
            _touch(tokenId);
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
        emit VoteCast(proposalId, voter, support, tokenIds);
    }

    /// @notice Withdraws a set of keys' votes on a proposal, until it is carried out.
    /// @dev The caller must be allowed to vote every key named, as for `vote`, and each must have a
    /// vote on the proposal, whoever cast it: a key that moved after voting can have that vote
    /// withdrawn by whoever may vote it now. A withdrawn key has no vote, so it counts against the
    /// proposal until it votes again.
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
            _requireGovernor(tokenId, msg.sender);
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
    /// Decision and at least three fifths of them for a RestrictEdits, and every key that stayed
    /// silent counts against it. A RestrictEdits sets `editsRestricted` for its key.
    /// @param proposalId The proposal to carry out.
    function execute(uint256 proposalId) external {
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
        } else {
            uint256 target = stored.targetTokenId;
            bool restricted = stored.restricted;
            editsRestricted[target] = restricted;
            emit EditsRestrictionSet(target, restricted, proposalId);
        }
    }

    // --- internals -------------------------------------------------------

    /// @dev Records a proposal and its opening. The standing check is the one `vote` applies: the
    /// caller owns the named key, or holds an active shard of it while its agent voting is on. Up to
    /// `SWEEP_IN_PROPOSE` expired presences are swept first, and if any are still due the call
    /// reverts with `MaintenanceRequired` rather than record a count that includes expired keys.
    /// The proposer's key is renewed, and then the opening revision, time and the exact count of
    /// present keys are recorded.
    function _propose(uint256 tokenId, Kind kind, string memory text, bytes32 digest)
        private
        returns (uint256 proposalId)
    {
        _requireGovernor(tokenId, msg.sender);
        (, bool due) = _sweep(SWEEP_IN_PROPOSE);
        if (due) revert MaintenanceRequired();
        _touch(tokenId);

        proposalId = proposalCount + 1;
        proposalCount = proposalId;

        Proposal storage stored = _proposals[proposalId];
        stored.kind = kind;
        stored.proposer = msg.sender;
        uint48 openRevision = _presence.mark();
        uint32 e0 = _presence.queued;
        stored.openRevision = openRevision;
        stored.openedAt = uint64(block.timestamp);
        stored.e0 = e0;
        stored.digest = digest;

        emit ProposalCreated(proposalId, kind, msg.sender, openRevision, uint64(block.timestamp), e0, digest, text);
    }

    /// @dev Sweeps up to `limit` expired presences, announcing any it removes.
    function _sweep(uint256 limit) private returns (uint256 removed, bool due) {
        (removed, due) = _presence.sweep(limit);
        if (removed != 0) emit Swept(removed, due);
    }

    /// @dev Renews a key the caller has been authorised for.
    function _touch(uint256 tokenId) private {
        _presence.touch(tokenId);
        emit Present(tokenId, uint64(block.timestamp), uint64(block.number), FLEET.ownershipEpoch(tokenId));
    }

    /// @dev Renews keys for `account`, who has been authenticated as the caller or a signer.
    function _present(address account, uint256[] calldata tokenIds) private {
        if (tokenIds.length == 0) revert NoKeys();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (account != FLEET.ownerOf(tokenId) && !SHARDS.isActive(tokenId, account)) {
                revert NotAuthorizedForKey(tokenId, account);
            }
            _touch(tokenId);
        }
    }

    /// @dev Who may vote a key and propose with it: its current owner, or a wallet holding an
    /// active shard of it while the key's agent voting is on. A token id that is not a minted key
    /// reverts in `ownerOf`.
    function _requireGovernor(uint256 tokenId, address account) private view {
        if (account != FLEET.ownerOf(tokenId) && !SHARDS.mayGovern(tokenId, account)) {
            revert NotAuthorizedForKey(tokenId, account);
        }
    }

    /// @dev The EIP-712 encoding of a signed message's keys: the ids, then each key's ownership
    /// epoch and delegation revision now, each array hashed as EIP-712 hashes an array. The ids
    /// must be strictly ascending, so one set of keys has exactly one encoding.
    function _keyState(uint256[] calldata tokenIds) private view returns (bytes32, bytes32, bytes32) {
        if (tokenIds.length == 0) revert NoKeys();
        uint64[] memory epochs = new uint64[](tokenIds.length);
        uint64[] memory revisions = new uint64[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            if (i != 0 && tokenIds[i] <= tokenIds[i - 1]) revert KeysNotAscending();
            epochs[i] = FLEET.ownershipEpoch(tokenIds[i]);
            revisions[i] = SHARDS.delegationRevision(tokenIds[i]);
        }
        return (
            keccak256(abi.encodePacked(tokenIds)),
            keccak256(abi.encodePacked(epochs)),
            keccak256(abi.encodePacked(revisions))
        );
    }

    /// @dev Checks a signed message: within its deadline, and signed by `signer` over this
    /// contract's EIP-712 domain.
    function _requireSigned(bytes32 structHash, address signer, uint256 deadline, bytes calldata signature)
        private
        view
    {
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        if (!SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSignature(signer);
        }
    }

    /// @dev A RestrictEdits needs YES from at least three fifths of all the keys sold so far; a
    /// Decision needs YES from more than half of them. An abstention counts against either way.
    function _approved(Kind kind, uint256 yesVotes, uint256 keysSold) private pure returns (bool) {
        if (kind == Kind.RestrictEdits) return yesVotes * 5 >= keysSold * 3;
        return yesVotes * 2 > keysSold;
    }

    function _require(uint256 proposalId) private view returns (Proposal storage stored) {
        if (proposalId == 0 || proposalId > proposalCount) revert UnknownProposal(proposalId);
        return _proposals[proposalId];
    }
}
