// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetPresence} from "./KeyfleetPresence.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";
import {KeyfleetTreasury} from "./KeyfleetTreasury.sol";

/// @notice The one fixed vote of a fleet: exact proposals decided by a growing electorate of keys.
/// @dev One instance is permanently bound to one fleet. It is deployed straight after the fleet, at
/// the address the fleet was given for it, and refuses to deploy for a fleet that names another
/// controller. There are no councils, no moderators, no rule amendments, no quorum classes and no
/// configurable presets.
///
/// A proposal names an author key, a content hash for its narrative, a closing time at most 48 hours
/// away and an exact ordered batch of calls for the fleet's treasury to make. Its execution expiry
/// is fixed at 48 hours after closing, and a proposal hash binds the chain, this controller, the
/// treasury, the proposal id, the author key and its ownership epoch, the content, the calls and
/// both times. A batch with no calls records agreement and moves nothing.
///
/// The electorate grows and never shrinks. When a proposal opens, every expired presence must
/// have been swept, the author key is renewed, and the exact count of present keys is recorded as
/// `e0` (never zero). A key outside that count that casts its first ballot before closing joins
/// late and adds one to the denominator `D = e0 + late`. Each key holds one ballot per proposal,
/// Yes, No or Abstain, which whoever may vote it now may replace until closing; replacing moves
/// the key's one contribution and repeating it changes nothing. No expiry, change of hands,
/// abstention or ballot replacement lowers `D`. After closing, a proposal is approved exactly when
/// `yes > floor(D / 2)`, and anyone may carry it out until its execution expiry. It is never
/// approved before closing. Its status is worked out from these stored facts; nothing finalises it.
///
/// A key's current owner may vote it, propose with it and cancel what it authored, and so may a
/// wallet holding an active shard of it (`KeyfleetShards`) while the key's agent voting is on, which
/// it is unless the owner turned it off. Keys are renewed (`KeyfleetPresence`) for 48 hours by
/// `present`, by every ballot, by proposing and by cancelling; renewing changes no open proposal.
/// Renewals and ballots may also be signed and submitted by anyone (`presentBySig`,
/// `castBallotBySig`): a signed message names its keys in ascending order and binds each key's
/// ownership epoch and delegation revision and the signer's nonce, and a ballot also binds the
/// proposal hash, so a change of hands, any change to the key's shards or agent voting, or a
/// second submission voids it. Signatures are checked with OpenZeppelin `SignatureChecker`, which
/// accepts ordinary wallets and contract wallets (ERC-1271).
///
/// Carrying out a proposal checks the calls against its hash, marks it executed and has the
/// treasury make them in order; a reverting call reverts everything, so the proposal stays approved
/// and may be retried until it expires. The controller holds nothing. The one thing it records for
/// the fleet is whether a key's edits are restricted, which only the treasury may set, so only a
/// carried-out proposal can. There is no administrator, no upgrade path and no pause.
contract KeyfleetVotes is EIP712, Nonces, ReentrancyGuardTransient {
    using KeyfleetPresence for KeyfleetPresence.Queue;

    /// @notice One key's ballot on one proposal.
    enum Choice {
        None,
        Yes,
        No,
        Abstain
    }

    /// @notice Where a proposal stands, worked out from its stored facts and the time.
    enum Status {
        Open,
        Approved,
        Rejected,
        Cancelled,
        Executed,
        ExecutionExpired
    }

    /// @notice One proposal. Its payload and opening are fixed at creation; only the tallies and
    /// the two flags move.
    /// @param contentHash The hash of the proposal's narrative, kept off chain.
    /// @param actionsHash `keccak256(abi.encode(calls))` of the exact batch to carry out.
    /// @param proposalHash The hash binding the whole proposal; signed ballots carry it.
    /// @param authorKey The key it was proposed with.
    /// @param openRevision The presence revision recorded at opening.
    /// @param openedAt The time it opened.
    /// @param closesAt The time ballots stop: the first second it is closed.
    /// @param executionExpiry The first second it can no longer be carried out.
    /// @param e0 How many keys were present when it opened. Never zero.
    /// @param late How many keys outside `e0` joined by casting a ballot.
    /// @param yes Keys whose ballot is Yes.
    /// @param no Keys whose ballot is No.
    /// @param abstain Keys whose ballot is Abstain.
    /// @param cancelled Whether its author key cancelled it.
    /// @param executed Whether it has been carried out.
    struct Proposal {
        bytes32 contentHash;
        bytes32 actionsHash;
        bytes32 proposalHash;
        uint32 authorKey;
        uint48 openRevision;
        uint64 openedAt;
        uint64 closesAt;
        uint64 executionExpiry;
        uint32 e0;
        uint32 late;
        uint32 yes;
        uint32 no;
        uint32 abstain;
        bool cancelled;
        bool executed;
    }

    /// @notice The fleet does not name this contract as its voting controller.
    error WrongFleet(address fleet);
    /// @notice No proposal carries this id.
    error UnknownProposal(uint256 proposalId);
    /// @notice No key with this id has been sold.
    error KeyNotMinted(uint256 tokenId);
    /// @notice Only the fleet reports a key changing hands.
    error OnlyFleet();
    /// @notice Only the fleet's treasury, carrying out a proposal, may do this.
    error OnlyTreasury();
    /// @notice Expired presences are still queued after this call's sweep, so the count of present
    /// keys is not exact; `sweepExpired` must run before a proposal can open.
    error MaintenanceRequired();
    /// @notice The account may not act for this key: it neither owns the key nor holds an active
    /// shard of it, or, to vote, propose or cancel, the key's agent voting is off.
    error NotAuthorizedForKey(uint256 tokenId, address account);
    /// @notice A signed message's deadline has passed.
    error SignatureExpired(uint256 deadline);
    /// @notice The signature is not the signer's over this exact message.
    error InvalidSignature(address signer);
    /// @notice A signed message's keys are not in strictly ascending order.
    error KeysNotAscending();
    /// @notice A call must name at least one key.
    error NoKeys();
    /// @notice A proposal closes after now and at most 48 hours from now.
    error ClosingOutOfRange(uint64 closesAt);
    /// @notice A ballot is Yes, No or Abstain.
    error InvalidChoice();
    /// @notice The proposal takes no more ballots: it has closed or was cancelled.
    error BallotsClosed(uint256 proposalId);
    /// @notice Only an open or approved proposal can be cancelled.
    error NotCancellable(Status status);
    /// @notice Only an approved proposal can be carried out.
    error NotApproved(Status status);
    /// @notice The calls are not the exact batch the proposal was made with.
    error ActionsMismatch();

    /// @notice A proposal was created. The calls are carried here, in full, for indexers.
    /// @param proposalId The new proposal.
    /// @param authorKey The key it was proposed with.
    /// @param proposer The address that created it: the key's owner or its agent.
    /// @param proposalHash The hash binding the whole proposal.
    /// @param contentHash The hash of its narrative.
    /// @param closesAt The time ballots stop.
    /// @param executionExpiry The first second it can no longer be carried out.
    /// @param e0 How many keys were present when it opened.
    /// @param openRevision The presence revision recorded at opening.
    /// @param calls The exact batch the treasury makes if it is carried out.
    event ProposalCreated(
        uint256 indexed proposalId,
        uint256 indexed authorKey,
        address indexed proposer,
        bytes32 proposalHash,
        bytes32 contentHash,
        uint64 closesAt,
        uint64 executionExpiry,
        uint32 e0,
        uint48 openRevision,
        KeyfleetTreasury.Call[] calls
    );

    /// @notice Keys cast or replaced their ballots on a proposal, all with one choice.
    event BallotCast(uint256 indexed proposalId, address indexed voter, Choice choice, uint256[] tokenIds);

    /// @notice A proposal was cancelled by whoever may act for its author key.
    event ProposalCancelled(uint256 indexed proposalId, address indexed by);

    /// @notice A proposal was carried out. It can never be carried out again.
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    /// @notice A carried-out proposal set whether a key's edits are restricted.
    event EditsRestrictionSet(uint256 indexed tokenId, bool restricted);

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

    /// @notice How many expired presences opening a proposal sweeps before it gives up with
    /// `MaintenanceRequired`.
    uint256 public constant SWEEP_IN_PROPOSE = 256;

    /// @notice How long a renewal keeps a key present: 48 hours, in seconds.
    uint64 public constant PRESENCE_WINDOW = KeyfleetPresence.WINDOW;

    /// @notice The longest a proposal may stay open: 48 hours, in seconds.
    uint64 public constant MAX_VOTING_PERIOD = 48 hours;

    /// @notice How long an approved proposal may be carried out after closing: 48 hours.
    uint64 public constant EXECUTION_WINDOW = 48 hours;

    /// @notice The EIP-712 type of a signed renewal. The key ids, epochs and delegation revisions
    /// are each hashed as EIP-712 arrays.
    bytes32 public constant PRESENT_TYPEHASH = keccak256(
        "Present(address fleet,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)"
    );
    /// @notice The EIP-712 type of a signed ballot, a different type from a renewal. `choice` is 1
    /// for Yes, 2 for No and 3 for Abstain.
    bytes32 public constant BALLOT_TYPEHASH = keccak256(
        "Ballot(uint256 proposalId,bytes32 proposalHash,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)"
    );

    /// @notice The fleet that deployed this controller and holds the keys that vote.
    Keyfleet public immutable FLEET;
    /// @notice The fleet's shard record, which says which wallets may act for a key.
    KeyfleetShards public immutable SHARDS;
    /// @notice The fleet's treasury, which makes an approved proposal's calls.
    KeyfleetTreasury public immutable TREASURY;

    /// @notice Proposals created so far. Proposal ids are `1..proposalCount`.
    uint256 public proposalCount;
    /// @notice A key's ballot on a proposal.
    mapping(uint256 proposalId => mapping(uint256 tokenId => Choice choice)) public ballotOf;
    /// @notice Whether the keys voted to restrict a key's edits, as the latest carried-out proposal
    /// on it left it. Read off chain to decide whether the key and its shards may write the fleet's
    /// workspace.
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
        TREASURY = fleet.TREASURY();
    }

    // --- views -----------------------------------------------------------

    /// @notice The whole proposal record.
    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _require(proposalId);
    }

    /// @notice Where a proposal stands now.
    /// @dev Cancelled or Executed once that happened; Open until closing; then Rejected unless
    /// `yes > floor((e0 + late) / 2)`, else Approved until its execution expiry and
    /// ExecutionExpired from then on. Tallies cannot change after closing, so this is final.
    function status(uint256 proposalId) external view returns (Status) {
        return _status(_require(proposalId));
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
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(PRESENT_TYPEHASH, address(FLEET)),
                _keyState(tokenIds),
                abi.encode(signer, _useNonce(signer), deadline)
            )
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

    /// @notice Proposes an exact batch of treasury calls, or none to record agreement only.
    /// @dev The caller must be allowed to vote `authorKey`. Up to `SWEEP_IN_PROPOSE` expired
    /// presences are swept first, and if any are still due the call reverts with
    /// `MaintenanceRequired` rather than record a count that includes expired keys. The author key
    /// is renewed and then the opening is recorded. Proposing casts no ballot and reserves nothing,
    /// and an identical proposal made again is a new proposal with its own id and electorate.
    /// @param authorKey The key proposed with. It is the caller's standing and nothing else.
    /// @param contentHash The hash of the narrative, kept off chain.
    /// @param closesAt When ballots stop: after now, and at most 48 hours from now.
    /// @param calls The exact ordered calls the treasury makes if it is carried out.
    /// @return proposalId The new proposal.
    function propose(uint256 authorKey, bytes32 contentHash, uint64 closesAt, KeyfleetTreasury.Call[] calldata calls)
        external
        returns (uint256 proposalId)
    {
        if (closesAt <= block.timestamp || closesAt > block.timestamp + MAX_VOTING_PERIOD) {
            revert ClosingOutOfRange(closesAt);
        }
        _requireGovernor(authorKey, msg.sender);
        (, bool due) = _sweep(SWEEP_IN_PROPOSE);
        if (due) revert MaintenanceRequired();
        _touch(authorKey);

        proposalId = proposalCount + 1;
        proposalCount = proposalId;
        Proposal storage stored = _proposals[proposalId];
        stored.contentHash = contentHash;
        stored.actionsHash = keccak256(abi.encode(calls));
        stored.authorKey = uint32(authorKey);
        stored.openRevision = _presence.mark();
        stored.openedAt = uint64(block.timestamp);
        stored.closesAt = closesAt;
        stored.executionExpiry = closesAt + EXECUTION_WINDOW;
        stored.e0 = _presence.queued;
        stored.proposalHash = _proposalHash(proposalId, stored);
        emit ProposalCreated(
            proposalId,
            authorKey,
            msg.sender,
            stored.proposalHash,
            contentHash,
            closesAt,
            stored.executionExpiry,
            stored.e0,
            stored.openRevision,
            calls
        );
    }

    /// @notice Casts or replaces ballots for a set of keys, all with one choice, and renews each key.
    /// @dev The caller must own every key named, or hold an active shard of it while its agent
    /// voting is on, and the proposal must be open. A key's first ballot adds it to the electorate
    /// if it was not present at opening; a later one replaces its contribution. The whole call
    /// reverts if any one key is refused.
    /// @param proposalId The proposal.
    /// @param tokenIds The keys.
    /// @param choice Yes, No or Abstain.
    function castBallot(uint256 proposalId, uint256[] calldata tokenIds, Choice choice) external {
        _castBallot(msg.sender, proposalId, tokenIds, choice);
    }

    /// @notice Casts ballots on a signed message, which anyone may submit.
    /// @dev The signer must be allowed to vote every key now, exactly as for `castBallot`, and is
    /// the voter the ballots are recorded under. The message binds the proposal hash, so it cannot
    /// be used on any other proposal.
    /// @param proposalId The proposal.
    /// @param tokenIds The keys, in strictly ascending order.
    /// @param choice Yes, No or Abstain.
    /// @param signer The account that signed.
    /// @param deadline The last timestamp the message may be submitted at.
    /// @param signature The signer's signature over the EIP-712 `Ballot` message.
    function castBallotBySig(
        uint256 proposalId,
        uint256[] calldata tokenIds,
        Choice choice,
        address signer,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(BALLOT_TYPEHASH, proposalId, _require(proposalId).proposalHash),
                _keyState(tokenIds),
                abi.encode(choice, signer, _useNonce(signer), deadline)
            )
        );
        _requireSigned(structHash, signer, deadline, signature);
        _castBallot(signer, proposalId, tokenIds, choice);
    }

    /// @notice Cancels an open or approved proposal, and renews its author key.
    /// @dev Whoever may vote the author key now may cancel: its current owner, or a wallet holding
    /// an active shard of it while its agent voting is on.
    /// @param proposalId The proposal.
    function cancel(uint256 proposalId) external {
        Proposal storage stored = _require(proposalId);
        Status current = _status(stored);
        if (current != Status.Open && current != Status.Approved) revert NotCancellable(current);
        uint256 authorKey = stored.authorKey;
        _requireGovernor(authorKey, msg.sender);
        stored.cancelled = true;
        _touch(authorKey);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // --- execution -------------------------------------------------------

    /// @notice Carries out an approved proposal: the treasury makes its exact calls, in order.
    /// @dev Permissionless, and it renews no key. The calls must be exactly the batch the proposal
    /// was made with. The proposal is marked executed before the treasury is called; if any call
    /// reverts, everything reverts and the proposal stays approved until its execution expiry.
    /// Locked against reentry, so an approved call cannot carry out another proposal.
    /// @param proposalId The proposal.
    /// @param calls The proposal's exact calls.
    function execute(uint256 proposalId, KeyfleetTreasury.Call[] calldata calls) external nonReentrant {
        Proposal storage stored = _require(proposalId);
        Status current = _status(stored);
        if (current != Status.Approved) revert NotApproved(current);
        if (keccak256(abi.encode(calls)) != stored.actionsHash) revert ActionsMismatch();
        stored.executed = true;
        TREASURY.executeBatch(calls);
        emit ProposalExecuted(proposalId, msg.sender);
    }

    /// @notice Sets whether a key's edits are restricted. Only the treasury may, so only an approved
    /// proposal's call can.
    /// @param tokenId A key already sold.
    /// @param restricted True to restrict, false to lift it.
    function setEditsRestricted(uint256 tokenId, bool restricted) external {
        if (msg.sender != address(TREASURY)) revert OnlyTreasury();
        if (tokenId == 0 || tokenId > FLEET.totalMinted()) revert KeyNotMinted(tokenId);
        editsRestricted[tokenId] = restricted;
        emit EditsRestrictionSet(tokenId, restricted);
    }

    // --- internals -------------------------------------------------------

    /// @dev Casts ballots for `voter`, who has been authenticated as the caller or a signer. A key
    /// with no ballot yet joins late unless it was present at opening; ballots never return to
    /// None, so that test counts each key at most once.
    function _castBallot(address voter, uint256 proposalId, uint256[] calldata tokenIds, Choice choice) private {
        if (choice == Choice.None) revert InvalidChoice();
        if (tokenIds.length == 0) revert NoKeys();
        Proposal storage stored = _require(proposalId);
        if (stored.cancelled || block.timestamp >= stored.closesAt) revert BallotsClosed(proposalId);

        uint256[4] memory tally = [0, uint256(stored.yes), uint256(stored.no), uint256(stored.abstain)];
        uint256 late = stored.late;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireGovernor(tokenId, voter);
            Choice previous = ballotOf[proposalId][tokenId];
            if (previous == Choice.None) {
                if (!_presence.wasActive(tokenId, stored.openRevision, stored.openedAt)) ++late;
            } else {
                --tally[uint256(previous)];
            }
            ++tally[uint256(choice)];
            ballotOf[proposalId][tokenId] = choice;
            _touch(tokenId);
        }
        stored.yes = uint32(tally[1]);
        stored.no = uint32(tally[2]);
        stored.abstain = uint32(tally[3]);
        stored.late = uint32(late);
        emit BallotCast(proposalId, voter, choice, tokenIds);
    }

    /// @dev The hash binding a proposal: the chain, this controller, the treasury, the id, the
    /// author key and its ownership epoch now, the content, the calls and both times.
    function _proposalHash(uint256 proposalId, Proposal storage stored) private view returns (bytes32) {
        uint256 authorKey = stored.authorKey;
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                address(TREASURY),
                proposalId,
                authorKey,
                FLEET.ownershipEpoch(authorKey),
                stored.contentHash,
                stored.actionsHash,
                stored.closesAt,
                stored.executionExpiry
            )
        );
    }

    function _status(Proposal storage stored) private view returns (Status) {
        if (stored.cancelled) return Status.Cancelled;
        if (stored.executed) return Status.Executed;
        if (block.timestamp < stored.closesAt) return Status.Open;
        if (stored.yes <= (uint256(stored.e0) + stored.late) / 2) return Status.Rejected;
        if (block.timestamp >= stored.executionExpiry) return Status.ExecutionExpired;
        return Status.Approved;
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

    /// @dev Who may vote a key, propose with it and cancel what it authored: its current owner, or
    /// a wallet holding an active shard of it while the key's agent voting is on. A token id that is
    /// not a minted key reverts in `ownerOf`.
    function _requireGovernor(uint256 tokenId, address account) private view {
        if (account != FLEET.ownerOf(tokenId) && !SHARDS.mayGovern(tokenId, account)) {
            revert NotAuthorizedForKey(tokenId, account);
        }
    }

    /// @dev The EIP-712 encoding of a signed message's three key fields, in place in the struct
    /// encoding: the ids, then each key's ownership epoch and delegation revision now, each array
    /// hashed as EIP-712 hashes an array. The ids must be strictly ascending, so one set of keys has
    /// exactly one encoding.
    function _keyState(uint256[] calldata tokenIds) private view returns (bytes memory) {
        if (tokenIds.length == 0) revert NoKeys();
        uint64[] memory epochs = new uint64[](tokenIds.length);
        uint64[] memory revisions = new uint64[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            if (i != 0 && tokenIds[i] <= tokenIds[i - 1]) revert KeysNotAscending();
            epochs[i] = FLEET.ownershipEpoch(tokenIds[i]);
            revisions[i] = SHARDS.delegationRevision(tokenIds[i]);
        }
        return abi.encode(
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

    function _require(uint256 proposalId) private view returns (Proposal storage stored) {
        if (proposalId == 0 || proposalId > proposalCount) revert UnknownProposal(proposalId);
        return _proposals[proposalId];
    }
}
