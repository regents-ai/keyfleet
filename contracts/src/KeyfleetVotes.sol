// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetPresence} from "./KeyfleetPresence.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";
import {KeyfleetTreasury} from "./KeyfleetTreasury.sol";
import {FleetWiring, IKeyfleetFactory, KeyfleetWiring} from "./KeyfleetWiring.sol";

/// @notice The one fixed vote of a fleet: exact proposals decided by a growing electorate of keys.
/// @dev One instance is permanently bound to one fleet, deployed by the factory with the fleet's three
/// other contracts. Keys are named by their token ids in the shared collection, and every function
/// that takes a key refuses a key of another fleet before anything else. There are no councils, no moderators, no rule amendments, no quorum classes and no
/// configurable presets.
///
/// A proposal names an author key, a content hash for its narrative, a closing time at most 48 hours
/// away and an exact ordered batch of calls for the fleet's treasury to make. Its execution expiry
/// is fixed at 48 hours after closing, and a proposal hash binds the chain, this controller, the
/// treasury, the proposal id, the author key and its ownership epoch, the content, the calls and
/// both times. A batch with no calls records agreement and moves nothing.
///
/// The electorate grows and never shrinks. When a proposal opens, every due presence entry must
/// have been swept, the author key is renewed, and the exact count of present keys is recorded as
/// `e0` (never zero). A key outside that count that casts its first ballot before closing joins
/// late and adds one to the denominator `D = e0 + late`. Each key holds one ballot per proposal,
/// Yes, No or Abstain, which whoever may vote it now may replace until closing; replacing moves
/// the key's one contribution and repeating it changes nothing. No expiry, change of hands,
/// abstention or ballot replacement lowers `D`. Because any ballot may still change until closing,
/// the outcome is decided only at closing: a proposal is then approved exactly when Yes reaches
/// `approvalsNeeded(D)`, `APPROVAL_PERCENT` (60%) of `D` rounded up, so one present key alone may
/// approve anything, and anyone may carry it out from closing until its execution expiry, 48 hours
/// later. It is never approved before closing, however many Yes ballots it has. Its status is
/// worked out from these stored facts; nothing finalises it.
///
/// A key takes part only once `KEY_MATURITY` (2 days) has passed since it was minted, counted in
/// block timestamps; a transfer does not start the wait again. Until then it cannot be renewed,
/// vote, propose or cancel, so it is never among the keys present at an opening and never joins
/// late. At that moment it becomes present on its own for `PRESENCE_WINDOW`, exactly as if it had
/// been renewed then; after that it stays present only by being renewed. A change of hands before
/// that moment leaves it as it is; one after it ends the presence, as it ends any presence.
///
/// For `TREASURY_OPENING` (7 days) from the moment the fleet's sales open, a proposal may carry
/// only calls that move no money: setting the fleet's profile, the daily split rate and whether a
/// key's edits are restricted, each without value. A proposal with no calls is always allowed, and
/// the daily split runs as usual.
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
        uint64 authorKey;
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

    /// @notice The key belongs to another fleet.
    error ForeignKey(uint256 tokenId);
    /// @notice No proposal carries this id.
    error UnknownProposal(uint256 proposalId);
    /// @notice No key with this id has been sold.
    error KeyNotMinted(uint256 tokenId);
    /// @notice Only the fleet's manager reports a key being sold or changing hands.
    error OnlyManager();
    /// @notice Only the fleet's treasury, carrying out a proposal, may do this.
    error OnlyTreasury();
    /// @notice Due presence entries are still listed after this call's sweep, so the count of
    /// present keys is not exact; `sweepExpired` must run before a proposal can open.
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
    /// @notice `KEY_MATURITY` has not yet passed since the key was minted.
    /// @param maturesAt The first second it may take part.
    error KeyTooNew(uint256 tokenId, uint64 maturesAt);
    /// @notice A call must name at least one key.
    error NoKeys();
    /// @notice A proposal closes after now and at most 48 hours from now.
    error ClosingOutOfRange(uint64 closesAt);
    /// @notice The fleet is in its opening, during which a proposal may carry only calls that move
    /// no money.
    /// @param opensAt The first second any calls may be proposed.
    error TreasuryOpening(uint64 opensAt);
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

    /// @notice A key was sold: it is present from `startsAt` for 48 hours without being renewed,
    /// unless it changes hands after that start.
    event PresenceScheduled(uint256 indexed tokenId, uint64 startsAt);

    /// @notice Due presence entries were moved: started keys became present, ended presences left.
    /// @param moved How many were moved.
    /// @param due Whether due entries are still listed.
    event Swept(uint256 moved, bool due);

    /// @notice A key was renewed: it is present until `at` plus 48 hours, unless it changes hands
    /// first.
    /// @param tokenId The key.
    /// @param at The time of the renewal.
    /// @param blockNumber The block of the renewal, for audit.
    /// @param epoch The key's ownership epoch the renewal belongs to.
    event Present(uint256 indexed tokenId, uint64 at, uint64 blockNumber, uint64 epoch);

    /// @notice How many due presence entries opening a proposal sweeps before it gives up with
    /// `MaintenanceRequired`.
    uint256 public constant SWEEP_IN_PROPOSE = 256;

    /// @notice How long a renewal keeps a key present: 48 hours, in seconds.
    uint64 public constant PRESENCE_WINDOW = KeyfleetPresence.WINDOW;

    /// @notice How long after its mint a key may first be renewed, vote, propose or cancel, and
    /// becomes present on its own: 2 days, in seconds.
    uint64 public constant KEY_MATURITY = 2 days;

    /// @notice How long after the fleet's sales open a proposal may carry only calls that move no
    /// money: 7 days, in seconds.
    uint64 public constant TREASURY_OPENING = 7 days;

    /// @notice The share of a proposal's electorate `D`, in percent, whose Yes ballots approve it,
    /// rounded up (`approvalsNeeded`).
    uint256 public constant APPROVAL_PERCENT = 60;

    /// @notice The longest a proposal may stay open: 48 hours, in seconds.
    uint64 public constant MAX_VOTING_PERIOD = 48 hours;

    /// @notice How long an approved proposal may be carried out after closing: 48 hours.
    uint64 public constant EXECUTION_WINDOW = 48 hours;

    /// @notice The EIP-712 type of a signed renewal. The key ids, epochs and delegation revisions
    /// are each hashed as EIP-712 arrays.
    bytes32 public constant PRESENT_TYPEHASH = keccak256(
        "Present(address manager,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)"
    );
    /// @notice The EIP-712 type of a signed ballot, a different type from a renewal. `choice` is 1
    /// for Yes, 2 for No and 3 for Abstain.
    bytes32 public constant BALLOT_TYPEHASH = keccak256(
        "Ballot(uint256 proposalId,bytes32 proposalHash,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)"
    );

    /// @notice This fleet's number in the collection; only its keys vote here.
    uint256 public immutable FLEET_ID;
    /// @notice The fleet's manager, which reports its keys moving.
    KeyfleetManager public immutable MANAGER;
    /// @notice The shared key collection.
    KeyfleetKeys public immutable KEYS;
    /// @notice The shared shard record, which says which wallets may act for a key.
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

    /// @notice Binds this controller to its fleet, from the wiring the factory holds while deploying it.
    constructor() EIP712("KeyfleetVotes", "1") {
        (IKeyfleetFactory factory, FleetWiring memory wiring) = KeyfleetWiring.read();
        KeyfleetWiring.requireSelf(wiring.votes);
        FLEET_ID = wiring.fleetId;
        MANAGER = KeyfleetManager(wiring.manager);
        KEYS = factory.KEYS();
        SHARDS = factory.SHARDS();
        TREASURY = KeyfleetTreasury(payable(wiring.treasury));
    }

    // --- views -----------------------------------------------------------

    /// @notice The whole proposal record.
    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _require(proposalId);
    }

    /// @notice Where a proposal stands now.
    /// @dev Cancelled or Executed once that happened; Open until closing; then Rejected unless
    /// `yes >= approvalsNeeded(e0 + late)`, else Approved until its execution expiry and
    /// ExecutionExpired from then on. Tallies cannot change after closing, so this is final.
    function status(uint256 proposalId) external view returns (Status) {
        return _status(_require(proposalId));
    }

    /// @notice How many Yes ballots approve a proposal whose electorate is `voters` keys:
    /// `APPROVAL_PERCENT` of them, rounded up.
    function approvalsNeeded(uint256 voters) public pure returns (uint256) {
        return (voters * APPROVAL_PERCENT + 99) / 100;
    }

    /// @notice The first second a proposal may carry calls that move money: `TREASURY_OPENING`
    /// after the fleet's sales opened. Zero while they have not opened.
    function treasuryOpensAt() public view returns (uint64) {
        uint64 salesOpenedAt = KEYS.salesOpenedAt(FLEET_ID);
        return salesOpenedAt == 0 ? 0 : salesOpenedAt + TREASURY_OPENING;
    }

    /// @notice Whether a key is present now: less than 48 hours since its latest renewal under its
    /// current owner, or since its automatic start if it was not renewed or moved after that.
    function isActive(uint256 tokenId) external view returns (bool) {
        return _presence.isActive(tokenId);
    }

    /// @notice When a key's latest presence starts: its latest renewal or, for a key not renewed
    /// since it was sold, its automatic start, which is still to come while it waits. Zero once it
    /// changed hands after that start.
    function presentFrom(uint256 tokenId) external view returns (uint64) {
        return _presence.presentFrom(tokenId);
    }

    /// @notice Whether a key was present when a proposal opened, as recorded at its opening
    /// revision, so a renewal or a change of hands in the same block falls on the right side.
    function wasActiveAtOpening(uint256 proposalId, uint256 tokenId) external view returns (bool) {
        Proposal storage stored = _require(proposalId);
        return _presence.wasActive(tokenId, stored.openRevision, stored.openedAt);
    }

    /// @notice One presence list's ends and entry count: `waiting`, `automatic` or `renewed`.
    /// Entries no sweep has moved yet are still counted where they were, so `automatic` plus
    /// `renewed` is the exact count of present keys only when nothing is due.
    function presenceList(KeyfleetPresence.Place place) external view returns (uint64 head, uint64 tail, uint32 count) {
        KeyfleetPresence.List storage list = place == KeyfleetPresence.Place.Waiting
            ? _presence.waiting
            : place == KeyfleetPresence.Place.Automatic ? _presence.automatic : _presence.renewed;
        return (list.head, list.tail, list.count);
    }

    /// @notice A key's presence entry: the list it is in, its neighbours there and when it falls
    /// due, all zero when it is in none.
    function presenceEntry(uint256 tokenId)
        external
        view
        returns (KeyfleetPresence.Place place, uint64 prev, uint64 next, uint64 dueAt)
    {
        KeyfleetPresence.Node storage node = _presence.node[tokenId];
        return (node.place, node.prev, node.next, node.dueAt);
    }

    /// @notice The first second a key may take part: `KEY_MATURITY` after its mint. Reverts for a
    /// token id that is not a key of this fleet that exists.
    function maturesAt(uint256 tokenId) external view returns (uint64) {
        _requireOwnKey(tokenId);
        uint64 minted = KEYS.mintedAt(tokenId);
        if (minted == 0) revert KeyNotMinted(tokenId);
        return minted + KEY_MATURITY;
    }

    /// @notice The latest presence revision.
    function presenceRevision() external view returns (uint48) {
        return _presence.revision;
    }

    // --- presence --------------------------------------------------------

    /// @notice Renews keys: each is present for the next 48 hours unless it changes hands first.
    /// @dev The caller must own every key named or hold an active shard of it; agent voting does
    /// not matter here. Every key must be mature (`KEY_MATURITY`). A key renewed again moves to the
    /// back of the queue; it is never counted twice. Renewing keys changes no open proposal.
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
                abi.encode(PRESENT_TYPEHASH, address(MANAGER)),
                _keyState(tokenIds),
                abi.encode(signer, _useNonce(signer), deadline)
            )
        );
        _requireSigned(structHash, signer, deadline, signature);
        _present(signer, tokenIds);
    }

    /// @notice Schedules a newly sold key's automatic presence. Only the fleet's manager calls
    /// this, from every sale, before the key is minted.
    /// @dev The one place a key becomes present without being renewed: `KEY_MATURITY` after its
    /// sale, which is its mint, for `PRESENCE_WINDOW`.
    function enrollKey(uint256 tokenId) external {
        if (msg.sender != address(MANAGER)) revert OnlyManager();
        uint64 startsAt = uint64(block.timestamp) + KEY_MATURITY;
        _presence.enroll(tokenId, startsAt);
        emit PresenceScheduled(tokenId, startsAt);
    }

    /// @notice Ends a key's presence because it changed hands. Only the fleet's manager calls this,
    /// from every transfer. A key still waiting for its automatic start keeps it.
    function onKeyMoved(uint256 tokenId) external {
        if (msg.sender != address(MANAGER)) revert OnlyManager();
        if (_presence.clear(tokenId)) emit PresenceCleared(tokenId);
    }

    /// @notice Moves up to `limit` due presence entries. Anyone may call it; it renews nothing and
    /// changes no proposal.
    /// @return moved How many were moved.
    /// @return due Whether due entries are still listed.
    function sweepExpired(uint256 limit) external returns (uint256 moved, bool due) {
        return _sweep(limit);
    }

    // --- proposals -------------------------------------------------------

    /// @notice Proposes an exact batch of treasury calls, or none to record agreement only.
    /// @dev The caller must be allowed to vote `authorKey`, which must be mature (`KEY_MATURITY`).
    /// Before `treasuryOpensAt` every call must be one that moves no money. Up to
    /// `SWEEP_IN_PROPOSE` due presence entries are swept first, and if any are still due the call
    /// reverts with `MaintenanceRequired` rather than record an inexact count. The author key
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
        uint64 opensAt = treasuryOpensAt();
        if (block.timestamp < opensAt && !_movesNoMoney(calls)) revert TreasuryOpening(opensAt);
        (, bool due) = _sweep(SWEEP_IN_PROPOSE);
        if (due) revert MaintenanceRequired();
        _touch(authorKey);

        proposalId = proposalCount + 1;
        proposalCount = proposalId;
        Proposal storage stored = _proposals[proposalId];
        stored.contentHash = contentHash;
        stored.actionsHash = keccak256(abi.encode(calls));
        stored.authorKey = uint64(authorKey);
        stored.openRevision = _presence.mark();
        stored.openedAt = uint64(block.timestamp);
        stored.closesAt = closesAt;
        stored.executionExpiry = closesAt + EXECUTION_WINDOW;
        stored.e0 = _presence.presentCount();
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
    /// voting is on, every key must be mature (`KEY_MATURITY`), and the proposal must be open. A
    /// key's first ballot adds it to the electorate
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
    /// @param tokenId A key of this fleet already sold.
    /// @param restricted True to restrict, false to lift it.
    function setEditsRestricted(uint256 tokenId, bool restricted) external {
        if (msg.sender != address(TREASURY)) revert OnlyTreasury();
        _requireOwnKey(tokenId);
        uint256 keyNumber = KEYS.keyNumberOf(tokenId);
        if (keyNumber == 0 || keyNumber > MANAGER.totalMinted()) revert KeyNotMinted(tokenId);
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
                KEYS.ownershipEpoch(authorKey),
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
        if (stored.yes < approvalsNeeded(uint256(stored.e0) + stored.late)) return Status.Rejected;
        if (block.timestamp >= stored.executionExpiry) return Status.ExecutionExpired;
        return Status.Approved;
    }

    /// @dev Whether every call is one a proposal may carry during the fleet's opening: no value,
    /// and the treasury's `setDailySplitBps`, the manager's `setProfile` or this controller's
    /// `setEditsRestricted`. None of them moves money.
    function _movesNoMoney(KeyfleetTreasury.Call[] calldata calls) private view returns (bool) {
        for (uint256 i = 0; i < calls.length; ++i) {
            KeyfleetTreasury.Call calldata call = calls[i];
            if (call.value != 0 || call.data.length < 4) return false;
            bytes4 selector = bytes4(call.data[:4]);
            if (
                !(call.target == address(TREASURY) && selector == KeyfleetTreasury.setDailySplitBps.selector)
                    && !(call.target == address(MANAGER) && selector == KeyfleetManager.setProfile.selector)
                    && !(call.target == address(this) && selector == this.setEditsRestricted.selector)
            ) return false;
        }
        return true;
    }

    /// @dev Sweeps up to `limit` due presence entries, announcing any it moves.
    function _sweep(uint256 limit) private returns (uint256 moved, bool due) {
        (moved, due) = _presence.sweep(limit);
        if (moved != 0) emit Swept(moved, due);
    }

    /// @dev Renews a key the caller has been authorised for, refusing one that is not mature yet.
    /// Every renewal comes through here, and every automatic start falls at maturity, so every
    /// present key is mature.
    function _touch(uint256 tokenId) private {
        uint64 maturity = KEYS.mintedAt(tokenId) + KEY_MATURITY;
        if (block.timestamp < maturity) revert KeyTooNew(tokenId, maturity);
        _presence.touch(tokenId);
        emit Present(tokenId, uint64(block.timestamp), uint64(block.number), KEYS.ownershipEpoch(tokenId));
    }

    /// @dev Renews keys for `account`, who has been authenticated as the caller or a signer.
    function _present(address account, uint256[] calldata tokenIds) private {
        if (tokenIds.length == 0) revert NoKeys();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireOwnKey(tokenId);
            if (account != KEYS.ownerOf(tokenId) && !SHARDS.isActive(tokenId, account)) {
                revert NotAuthorizedForKey(tokenId, account);
            }
            _touch(tokenId);
        }
    }

    /// @dev Who may vote a key, propose with it and cancel what it authored: its current owner, or
    /// a wallet holding an active shard of it while the key's agent voting is on. A key of another
    /// fleet is refused first; a token id that is not a minted key reverts in `ownerOf`.
    function _requireGovernor(uint256 tokenId, address account) private view {
        _requireOwnKey(tokenId);
        if (account != KEYS.ownerOf(tokenId) && !SHARDS.mayGovern(tokenId, account)) {
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
            epochs[i] = KEYS.ownershipEpoch(tokenIds[i]);
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

    /// @dev Refuses a key of another fleet.
    function _requireOwnKey(uint256 tokenId) private view {
        if (KEYS.fleetOf(tokenId) != FLEET_ID) revert ForeignKey(tokenId);
    }

    function _require(uint256 proposalId) private view returns (Proposal storage stored) {
        if (proposalId == 0 || proposalId > proposalCount) revert UnknownProposal(proposalId);
        return _proposals[proposalId];
    }
}
