// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";
import {KeyfleetVotes} from "./KeyfleetVotes.sol";
import {FleetWiring, IKeyfleetFactory, KeyfleetWiring} from "./KeyfleetWiring.sol";
import {IRegentLBPStrategyV2} from "./interfaces/IRegentLBPStrategyV2.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "./interfaces/IRegentsAutolaunchFactoryV2.sol";

/// @notice The treasury of one fleet: the fleet's one payment address, the only place its free
/// capital is held, and the only account of the fleet that approves a token.
/// @dev One instance is permanently bound to one fleet, deployed by the factory with the fleet's
/// three other contracts. Anyone paying the fleet pays this address, in USDC or any other token.
/// The capital part of every purchase and a completed Cascade level's released reserve arrive here
/// as REGENT, bought at the market price by the shared `KeyfleetRegentBuyer` one piece at a time
/// after the purchase, while the USDC waits in the manager; anything sent to the fleet's manager
/// outside a purchase is sent here as it was paid.
///
/// The treasury holds native ETH as well as tokens. It spends only by making the exact calls of a
/// proposal the keys approved, which the fleet's `KeyfleetVotes` hands it when the proposal is
/// carried out. Some of its own functions can only be reached that way, because they accept only
/// the treasury itself as caller: `pay` sends a payment, and `advance` sends one and records it as
/// an advance to an operator, which anyone may return with `returnAdvance` up to what is still
/// outstanding. Each names one asset and a share of the treasury's balance of it in parts per
/// million, which the voting controller holds between 0.0001% and 99% when the proposal is made;
/// the amount is that share of the balance when the call is made, rounded down, and a share that
/// rounds down to nothing is refused. The fleet's owed protocol share passes through here inside one call and never
/// stays: the manager sends it as USDC and immediately asks for it to be deposited into REGENT
/// revenue staking.
///
/// The fleet launches its own token through Autolaunch Revstake v2 by an approved proposal's call
/// to the pinned factory, naming this treasury as the launch's treasury. Once that launch has
/// succeeded, anyone may bind its token with `bindLaunchToken`, once, and it is split from the next
/// run. Only what the treasury itself holds is split: the launch's vesting tokens stay in its escrow
/// until released here, its liquidity in Autolaunch's locker, and staked tokens in its splitter.
///
/// The daily split shares a fixed part of the treasury's balance of each bound asset (ETH, REGENT,
/// USDC, OUSD once a proposal admits it, and the fleet's launch token once bound) equally across
/// every mature key, one minted at least `KEY_MATURITY` (2 days) ago, through the fleet's ledger.
/// Anyone may run it once a day has passed since the last run, or since the first mint before any
/// run; an approved proposal may also run it at any time. Its rate, 0.5% by default, is between
/// 0.1% and 2% and changes only by an approved proposal. Carrying out calls, the deposit, returning
/// an advance, binding the launch token and the public split run under one reentrancy lock; a voted
/// split runs inside the calls it is carried out with.
///
/// The treasury signs nothing by itself. It answers ERC-1271 `isValidSignature` with yes only for
/// a hash an approved proposal approved with `approveSignatureHash`, until one revokes it with
/// `revokeSignatureHash`. That is how the fleet owns a Lit ChainSecured account on Base: every
/// administrative write to Lit's `AccountConfig` is an exact call of an approved proposal, and
/// every message Lit asks the owner to sign is a hash an approved proposal approved first.
/// There is no administrator, no upgrade path and no pause.
contract KeyfleetTreasury is ReentrancyGuardTransient, IERC1271 {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @notice One call an approved proposal makes from the treasury.
    /// @param target The account called.
    /// @param value Wei sent with the call, from the treasury's balance.
    /// @param data The exact calldata.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice One advance to an operator, recorded when an approved proposal makes it.
    /// @param operator Who received it.
    /// @param asset What was sent: a token, or `NATIVE` for ETH.
    /// @param outstanding How much of it has not been returned yet.
    /// @param purposeHash The hash of what it is for, kept off chain.
    struct Advance {
        address operator;
        address asset;
        uint256 outstanding;
        bytes32 purposeHash;
    }

    /// @notice How the treasury names native ETH wherever it names an asset.
    address public constant NATIVE = address(0);

    /// @notice What a share of a balance is counted in: parts per million.
    uint256 public constant SHARE_DENOMINATOR = 1_000_000;

    /// @notice The lowest daily split rate, in basis points: 0.1%.
    uint16 public constant MIN_SPLIT_BPS = 10;
    /// @notice The highest daily split rate, in basis points: 2%.
    uint16 public constant MAX_SPLIT_BPS = 200;
    /// @notice How long after the last run anyone may run the daily split again.
    uint256 public constant SPLIT_INTERVAL = 1 days;
    /// @notice The least ETH the treasury must hold for ETH to be split.
    uint256 public constant ETH_THRESHOLD = 0.05 ether;

    /// @notice The source tag every protocol share deposit carries:
    /// `keccak256("keyfleet.protocol_share")`. The source reference is the fleet's manager address.
    bytes32 public constant PROTOCOL_SHARE_TAG = keccak256("keyfleet.protocol_share");

    /// @dev The transient slot of the split-in-progress flag:
    /// `keccak256(abi.encode(uint256(keccak256("keyfleet.treasury.split_in_progress")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant SPLIT_IN_PROGRESS = 0xd9aca5cd3a42e97768814a58347bfab1c7bcba20bf1fb9c47c8b9d767310a900;

    /// @notice The manager of the fleet this treasury holds the capital of.
    KeyfleetManager public immutable MANAGER;
    /// @notice The fleet's voting controller, the only account that hands the treasury calls to make.
    KeyfleetVotes public immutable VOTES;
    /// @notice The fleet's USDC.
    IERC20 public immutable USDC;
    /// @notice Where the protocol share is deposited, as the factory names it. On Base the
    /// deployment scripts require REGENT revenue staking, `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.
    IRegentRevenueStaking public immutable REGENT_STAKING;

    /// @notice The fleet's reward ledger, which the daily split funds.
    KeyfleetRewards public immutable REWARDS;
    /// @notice REGENT, a bound asset of the daily split. On Base the deployment scripts require
    /// `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`.
    IERC20 public immutable REGENT;
    /// @notice The least USDC the treasury must hold for USDC to be split: 100 USDC.
    uint256 public immutable USDC_THRESHOLD;
    /// @notice The least REGENT the treasury must hold for REGENT to be split: 100 REGENT.
    uint256 public immutable REGENT_THRESHOLD;
    /// @notice The Autolaunch Revstake v2 factory whose launches this treasury may bind. On Base the
    /// deployment scripts require `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E`.
    IRegentsAutolaunchFactoryV2 public immutable AUTOLAUNCH;

    /// @notice OUSD once an approved proposal admits it, and zero until then.
    IERC20 public ousd;
    /// @notice The daily split rate in basis points of each bound asset's balance.
    uint16 public dailySplitBps = 50;
    /// @notice When the daily split last ran, publicly or by vote; zero before its first run.
    uint64 public lastRunAt;
    /// @notice The least OUSD the treasury must hold for OUSD to be split: 100 OUSD.
    uint256 public ousdThreshold;
    /// @notice The fleet's own launched token once bound, and zero until then.
    IERC20 public launchToken;
    /// @notice The least of the launch token the treasury must hold for it to be split: 100 tokens.
    uint256 public launchTokenThreshold;
    /// @notice The Autolaunch launch the launch token was bound from, and zero until then.
    uint256 public launchId;

    /// @notice Every advance an approved proposal has made, by the id the proposal gave it.
    mapping(uint256 advanceId => Advance advance) public advances;

    /// @notice The hashes the treasury answers for as its own signature, each approved by an
    /// approved proposal and not since revoked.
    mapping(bytes32 hash => bool approved) public approvedHash;

    /// @notice Only the fleet's manager may ask for the protocol share to be deposited.
    error OnlyManager();
    /// @notice Only the fleet's voting controller hands the treasury calls to make.
    error OnlyVotes();
    /// @notice Staking did not take exactly the amount approved for it.
    error StakingDepositFailed(uint256 amount, uint256 received);
    /// @notice Only the treasury itself may call this, so only an approved proposal's call reaches it.
    error OnlySelf();
    /// @notice The share of the treasury's balance of the asset rounds down to nothing.
    error ShareRoundsToZero(address asset, uint32 sharePpm, uint256 balance);
    /// @notice An advance already has this id.
    error AdvanceIdTaken(uint256 advanceId);
    /// @notice More was returned than the advance has outstanding.
    error ReturnAboveOutstanding(uint256 advanceId, uint256 amount, uint256 outstanding);
    /// @notice The ETH sent with a return does not match the amount: all of it for an ETH advance,
    /// none for a token advance.
    error WrongValue(uint256 value);
    /// @notice The daily split may not run publicly yet: no key has been minted (`opensAt` zero),
    /// or a day has not passed since the last run or the first mint.
    error SplitNotDue(uint256 opensAt);
    /// @notice A daily split rate outside 10 to 200 basis points.
    error SplitRateOutOfRange(uint256 bps);
    /// @notice A bound token's transfer to the ledger ran out of gas; retry with more gas.
    error SplitOutOfGas();
    /// @notice OUSD has already been admitted.
    error OusdAlreadyAdmitted();
    /// @notice OUSD cannot be the zero address, USDC, REGENT or the launch token.
    error OusdInvalid(address token);
    /// @notice A launch token has already been bound.
    error LaunchTokenAlreadyBound();
    /// @notice The launch was not made by this treasury, or does not name it as its treasury.
    error NotOwnLaunch(uint256 launchId);
    /// @notice The launch has not succeeded: its auction is still running, unsettled or failed.
    error LaunchNotGraduated(uint256 launchId);
    /// @notice The launch's token is already split as OUSD.
    error LaunchTokenIsOusd(address token);

    /// @notice An approved proposal paid `sharePpm` parts per million of the treasury's balance of
    /// an asset, `amount`, out of the treasury.
    event Paid(address indexed asset, address indexed to, uint32 sharePpm, uint256 amount);
    /// @notice An approved proposal advanced `sharePpm` parts per million of the treasury's balance
    /// of an asset, `amount`, to an operator.
    event Advanced(
        uint256 indexed advanceId,
        address indexed operator,
        address indexed asset,
        uint32 sharePpm,
        uint256 amount,
        bytes32 purposeHash
    );
    /// @notice Part or all of an advance came back.
    /// @param from Whoever returned it; anyone may.
    /// @param outstanding What is still outstanding afterwards.
    event AdvanceReturned(uint256 indexed advanceId, address indexed from, uint256 amount, uint256 outstanding);
    /// @notice The daily split ran for `keys` mature keys at `bps`, publicly or, when `voted`, by an
    /// approved proposal.
    event DailySplitRun(bool indexed voted, uint256 keys, uint256 bps);
    /// @notice One bound asset was split: `perKey` to each key from a balance of `balance`; the
    /// treasury keeps the rest, rounding dust included.
    event SplitAllocated(address indexed asset, uint256 balance, uint256 perKey, uint256 keys);
    /// @notice One bound asset was not split this run: no keys, a balance under its threshold, or
    /// too little to give every key a whole unit.
    event SplitSkipped(address indexed asset, uint256 balance);
    /// @notice One bound token refused to move to the ledger, so it was not split this run; the
    /// others were.
    event SplitTransferFailed(address indexed asset, uint256 amount);
    /// @notice An approved proposal changed the daily split rate, from the next run.
    event DailySplitRateSet(uint256 bps);
    /// @notice An approved proposal admitted OUSD as a bound asset of the daily split.
    event OusdAdmitted(address indexed token, uint256 threshold);
    /// @notice The fleet's launched token is now a bound asset of the daily split.
    event LaunchTokenBound(uint256 indexed launchId, address indexed token, uint256 threshold);
    /// @notice An approved proposal approved a hash: the treasury now answers ERC-1271 for it.
    event SignatureHashApproved(bytes32 indexed hash);
    /// @notice An approved proposal revoked a hash: the treasury no longer answers for it.
    event SignatureHashRevoked(bytes32 indexed hash);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @notice Binds this treasury to its fleet's manager, voting controller and ledger, and to the
    /// staking contract, REGENT and the Autolaunch factory the factory names, from the wiring the
    /// factory holds while deploying it. REGENT's decimals are read once here for its threshold.
    constructor() {
        (IKeyfleetFactory factory, FleetWiring memory wiring) = KeyfleetWiring.read();
        KeyfleetWiring.requireSelf(wiring.treasury);
        MANAGER = KeyfleetManager(wiring.manager);
        VOTES = KeyfleetVotes(wiring.votes);
        REWARDS = KeyfleetRewards(wiring.rewards);
        USDC = factory.USDC();
        REGENT_STAKING = factory.REGENT_STAKING();
        REGENT = factory.REGENT();
        AUTOLAUNCH = factory.AUTOLAUNCH();
        USDC_THRESHOLD = _hundred(USDC);
        REGENT_THRESHOLD = _hundred(REGENT);
    }

    /// @notice Whether the treasury is inside its split routine right now. The fleet's ledger
    /// accepts split funding only while this is true, so no approved proposal's call can fund it.
    function splitInProgress() external view returns (bool) {
        return SPLIT_IN_PROGRESS.asBoolean().tload();
    }

    /// @notice Takes native ETH from anyone. It is free capital like any token the treasury holds.
    receive() external payable {}

    /// @notice Deposits `amount` USDC, which the fleet's manager has just sent here, into REGENT
    /// revenue staking as the fleet's protocol share.
    /// @dev Only the manager calls this, in the same call that sends the amount. The approval is
    /// exact and is used up in the deposit; staking must report receiving exactly `amount` and
    /// leave no allowance, or the whole call reverts and the share stays owed in the manager. A
    /// paused staking contract reverts the same way.
    function depositProtocolShare(uint256 amount) external nonReentrant {
        if (msg.sender != address(MANAGER)) revert OnlyManager();
        USDC.forceApprove(address(REGENT_STAKING), amount);
        uint256 received =
            REGENT_STAKING.depositUSDC(amount, PROTOCOL_SHARE_TAG, bytes32(uint256(uint160(address(MANAGER)))));
        if (received != amount || USDC.allowance(address(this), address(REGENT_STAKING)) != 0) {
            revert StakingDepositFailed(amount, received);
        }
    }

    /// @notice Makes an approved proposal's calls, in order.
    /// @dev Only the voting controller calls this, when a proposal is carried out, after checking
    /// the calls against the proposal. Each is a plain call with its value; the first that reverts
    /// reverts the whole batch with its reason, so a batch never half succeeds.
    /// @param calls The proposal's exact calls.
    function executeBatch(Call[] calldata calls) external nonReentrant {
        if (msg.sender != address(VOTES)) revert OnlyVotes();
        for (uint256 i = 0; i < calls.length; ++i) {
            Call calldata call = calls[i];
            (bool success, bytes memory returndata) = call.target.call{value: call.value}(call.data);
            Address.verifyCallResult(success, returndata);
        }
    }

    /// @notice Pays `sharePpm` parts per million of the treasury's balance of an asset to `to`.
    /// Only an approved proposal's call reaches it.
    /// @dev A token is sent with `SafeERC20`, so a token that returns false instead of reverting
    /// still fails the batch; ETH (`NATIVE`) is sent with `Address.sendValue`.
    /// @param asset A token, or `NATIVE` for ETH.
    /// @param to Who receives it.
    /// @param sharePpm The share of the balance, held between 1 and 990,000 when proposed.
    function pay(address asset, address to, uint32 sharePpm) external onlySelf {
        uint256 amount = _shareOf(asset, sharePpm);
        emit Paid(asset, to, sharePpm, amount);
        _send(asset, to, amount);
    }

    /// @notice Advances `sharePpm` parts per million of the treasury's balance of an asset to an
    /// operator and records the amount under `advanceId` as outstanding. Only an approved
    /// proposal's call reaches it.
    /// @param advanceId A new id, chosen in the proposal.
    /// @param operator Who receives it.
    /// @param asset A token, or `NATIVE` for ETH.
    /// @param sharePpm The share of the balance, held between 1 and 990,000 when proposed.
    /// @param purposeHash The hash of what it is for, kept off chain.
    function advance(uint256 advanceId, address operator, address asset, uint32 sharePpm, bytes32 purposeHash)
        external
        onlySelf
    {
        if (advances[advanceId].operator != address(0)) revert AdvanceIdTaken(advanceId);
        uint256 amount = _shareOf(asset, sharePpm);
        advances[advanceId] = Advance({operator: operator, asset: asset, outstanding: amount, purposeHash: purposeHash});
        emit Advanced(advanceId, operator, asset, sharePpm, amount, purposeHash);
        _send(asset, operator, amount);
    }

    /// @notice Returns part or all of an advance to the treasury. Anyone may return it.
    /// @dev Capped at what is still outstanding, so a return can never be labelled against more
    /// than was advanced. An ETH advance is returned by sending exactly `amount` with the call; a
    /// token advance is pulled from the caller, who approves the treasury first, and takes no ETH.
    function returnAdvance(uint256 advanceId, uint256 amount) external payable nonReentrant {
        Advance storage stored = advances[advanceId];
        uint256 outstanding = stored.outstanding;
        if (amount > outstanding) revert ReturnAboveOutstanding(advanceId, amount, outstanding);
        address asset = stored.asset;
        if (msg.value != (asset == NATIVE ? amount : 0)) revert WrongValue(msg.value);
        stored.outstanding = outstanding - amount;
        emit AdvanceReturned(advanceId, msg.sender, amount, outstanding - amount);
        if (asset != NATIVE) IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Runs the daily split for every bound asset. Anyone may call it once a day has passed
    /// since the last run, or since the first mint before any run. A day nobody runs it is not
    /// made up later.
    function runDailySplit() external nonReentrant {
        uint256 opensAt = nextRunAt();
        if (opensAt == 0 || block.timestamp < opensAt) revert SplitNotDue(opensAt);
        _split(false);
    }

    /// @notice Runs the daily split now, whenever the last run was. Only an approved proposal's
    /// call reaches it, already under the lock of the calls it is carried out with.
    function runVotedSplit() external onlySelf {
        _split(true);
    }

    /// @notice Sets the daily split rate from the next run. Only an approved proposal's call
    /// reaches it.
    /// @param bps Between 10 and 200 basis points.
    function setDailySplitBps(uint256 bps) external onlySelf {
        if (bps < MIN_SPLIT_BPS || bps > MAX_SPLIT_BPS) revert SplitRateOutOfRange(bps);
        dailySplitBps = uint16(bps);
        emit DailySplitRateSet(bps);
    }

    /// @notice Admits OUSD as a bound asset of the daily split, once. Only an approved proposal's
    /// call reaches it. Its decimals are read here, once, for its threshold.
    /// @dev The token must deliver exactly what the treasury sends: the ledger checks its balance
    /// covers each split in full, so a token that delivers even one unit less reverts every later
    /// run, for every asset, and admission cannot be undone. Prove the exact token's transfers on a
    /// Base fork before proposing it.
    function admitOusd(IERC20 token) external onlySelf {
        if (address(ousd) != address(0)) revert OusdAlreadyAdmitted();
        if (address(token) == address(0) || token == USDC || token == REGENT || token == launchToken) {
            revert OusdInvalid(address(token));
        }
        uint256 threshold = _hundred(token);
        ousd = token;
        ousdThreshold = threshold;
        emit OusdAdmitted(address(token), threshold);
    }

    /// @notice Binds the fleet's launched token as a bound asset of the daily split, once, from the
    /// next run. Anyone may call it.
    /// @dev The launch must have been made by this treasury, which only an approved proposal's call
    /// can do, and name it as its treasury; and the pinned strategy must record it as graduated,
    /// which it does only when the auction sold and the pool, splitter and receiver were made. Its
    /// token's decimals are read here, once, for its threshold. The first successful launch bound is
    /// the one: there is no replacement.
    /// @param id The launch's id at the pinned factory.
    function bindLaunchToken(uint256 id) external nonReentrant {
        if (address(launchToken) != address(0)) revert LaunchTokenAlreadyBound();
        IRegentsAutolaunchFactoryV2.Launch memory launched = AUTOLAUNCH.launches(id);
        if (launched.launcher != address(this) || launched.treasury != address(this)) revert NotOwnLaunch(id);
        if (AUTOLAUNCH.strategy().distribution(launched.auction).lifecycle != IRegentLBPStrategyV2.Lifecycle.Graduated)
        {
            revert LaunchNotGraduated(id);
        }
        IERC20 token = IERC20(launched.subject);
        if (token == ousd) revert LaunchTokenIsOusd(address(token));
        uint256 threshold = _hundred(token);
        launchToken = token;
        launchTokenThreshold = threshold;
        launchId = id;
        emit LaunchTokenBound(id, address(token), threshold);
    }

    /// @notice Approves a hash as the treasury's signature, so `isValidSignature` answers yes for
    /// it. Only an approved proposal's call reaches it.
    /// @dev Approve only a digest that names its own domain, such as an EIP-712 digest, so the
    /// approval means one message to one verifier.
    function approveSignatureHash(bytes32 hash) external onlySelf {
        approvedHash[hash] = true;
        emit SignatureHashApproved(hash);
    }

    /// @notice Revokes a hash, so `isValidSignature` answers no for it again. Only an approved
    /// proposal's call reaches it.
    function revokeSignatureHash(bytes32 hash) external onlySelf {
        approvedHash[hash] = false;
        emit SignatureHashRevoked(hash);
    }

    /// @notice ERC-1271: the magic value `0x1626ba7e` exactly when an approved proposal approved
    /// `hash` and none has revoked it since, and `0xffffffff` otherwise. The signature bytes are
    /// not read: the approval is the signature.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approvedHash[hash] ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    /// @notice The assets the daily split shares, in the order it splits them: ETH (`NATIVE`),
    /// REGENT, USDC, then OUSD once admitted, then the launch token once bound.
    function splitAssets() external view returns (address[] memory assets) {
        (IERC20 admitted, IERC20 launched) = (ousd, launchToken);
        uint256 count = 3;
        if (address(admitted) != address(0)) ++count;
        if (address(launched) != address(0)) ++count;
        assets = new address[](count);
        (assets[0], assets[1], assets[2]) = (NATIVE, address(REGENT), address(USDC));
        if (address(admitted) != address(0)) assets[3] = address(admitted);
        if (address(launched) != address(0)) assets[count - 1] = address(launched);
    }

    /// @notice When anyone may next run the daily split: a day after the last run, or a day after
    /// the first mint before any run. Zero while no key has been minted.
    function nextRunAt() public view returns (uint256) {
        uint256 firstMintAt = MANAGER.firstMintAt();
        if (firstMintAt == 0) return 0;
        return Math.max(lastRunAt, firstMintAt) + SPLIT_INTERVAL;
    }

    /// @dev Splits every bound asset at the current rate across the keys mature now, with the
    /// ledger's funding flag set throughout so that only this routine can fund the ledger.
    function _split(bool voted) private {
        TransientSlot.BooleanSlot flag = SPLIT_IN_PROGRESS.asBoolean();
        flag.tstore(true);
        lastRunAt = uint64(block.timestamp);
        uint256 keys = MANAGER.matureKeys();
        uint256 bps = dailySplitBps;
        emit DailySplitRun(voted, keys, bps);
        _splitAsset(NATIVE, address(this).balance, ETH_THRESHOLD, keys, bps);
        _splitAsset(address(REGENT), REGENT.balanceOf(address(this)), REGENT_THRESHOLD, keys, bps);
        _splitAsset(address(USDC), USDC.balanceOf(address(this)), USDC_THRESHOLD, keys, bps);
        IERC20 admitted = ousd;
        if (address(admitted) != address(0)) {
            _splitAsset(address(admitted), admitted.balanceOf(address(this)), ousdThreshold, keys, bps);
        }
        IERC20 launched = launchToken;
        if (address(launched) != address(0)) {
            _splitAsset(address(launched), launched.balanceOf(address(this)), launchTokenThreshold, keys, bps);
        }
        flag.tstore(false);
    }

    /// @dev `balance` is the treasury's whole balance of the asset, all of it free capital, read
    /// before anything is cut from it. A token that refuses the transfer is skipped and the run goes
    /// on; one that ran the transfer out of gas reverts the run instead, so a caller cannot starve
    /// one asset on purpose. Once the tokens are in the ledger, its funding must succeed or the
    /// whole run reverts, so the ledger only ever adds a split for exactly the keys mature now.
    function _splitAsset(address asset, uint256 balance, uint256 threshold, uint256 keys, uint256 bps) private {
        uint256 perKey = keys == 0 || balance < threshold ? 0 : Math.mulDiv(balance, bps, 10_000) / keys;
        if (perKey == 0) {
            emit SplitSkipped(asset, balance);
            return;
        }
        uint256 allocated = perKey * keys;
        if (asset == NATIVE) {
            REWARDS.fundSplitNative{value: allocated}(perKey, keys);
        } else {
            uint256 gasBefore = gasleft();
            if (!IERC20(asset).trySafeTransfer(address(REWARDS), allocated)) {
                if (gasleft() < gasBefore / 63) revert SplitOutOfGas();
                emit SplitTransferFailed(asset, allocated);
                return;
            }
            REWARDS.fundSplit(asset, perKey, keys);
        }
        emit SplitAllocated(asset, balance, perKey, keys);
    }

    /// @dev 100 whole units of a token, by the decimals it reports.
    function _hundred(IERC20 token) private view returns (uint256) {
        return 100 * 10 ** IERC20Metadata(address(token)).decimals();
    }

    /// @dev `sharePpm` parts per million of the treasury's balance of `asset` now, rounded down;
    /// refused when that is nothing.
    function _shareOf(address asset, uint32 sharePpm) private view returns (uint256 amount) {
        uint256 balance = asset == NATIVE ? address(this).balance : IERC20(asset).balanceOf(address(this));
        amount = Math.mulDiv(balance, sharePpm, SHARE_DENOMINATOR);
        if (amount == 0) revert ShareRoundsToZero(asset, sharePpm, balance);
    }

    function _send(address asset, address to, uint256 amount) private {
        if (asset == NATIVE) Address.sendValue(payable(to), amount);
        else IERC20(asset).safeTransfer(to, amount);
    }
}
