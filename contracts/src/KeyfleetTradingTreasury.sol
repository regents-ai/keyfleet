// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";
import {KeyfleetTradingManager} from "./KeyfleetTradingManager.sol";
import {IKeyfleetTradingFactory, KeyfleetTradingWiring, TradingWiring} from "./KeyfleetTradingWiring.sol";
import {KeyfleetWiring} from "./KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";

/// @notice The treasury of one Trading Fleet: it holds the fleet's USDC, sends it to the creator's
/// trading wallet when the creator says so, and pays it back to the fleet's Keys.
/// @dev One instance is permanently bound to one fleet, deployed by the trading factory with the
/// fleet's manager and ledger. Every purchase pays its whole price here. It holds USDC only: it takes
/// no ETH, and any other token sent here stays here for ever, as nothing can move it.
///
/// The creator, whoever holds the fleet's Key 1 at the moment of the call, alone may name the trading
/// wallet, send any amount of the USDC here to it, start a payback of any amount of it, and close
/// the fleet. USDC comes back by a plain transfer to this address from anyone; no function is
/// needed. Nothing else moves USDC out of here except a payback.
///
/// Every payback runs one routine. 1% of its amount, rounded up, is deposited into REGENT revenue
/// staking through `depositUSDC`, with an exact approval that the deposit uses up. The rest is
/// shared equally among the Keys that count: the same whole amount per Key, sent to the fleet's
/// ledger and added there with `fundSplit`, while `splitInProgress` is true for the length of that
/// call only. What does not divide evenly stays here. With no Key that counts, or too little to give
/// each one a whole unit, the payback reverts and nothing moves.
///
/// Anyone may run the guaranteed daily payback, `DAILY_PAYBACK_BPS` hundredths of a percent of the
/// USDC here at that moment, once a day has passed since the last run, or since Key 1's mint before
/// any run; a day nobody runs it is not made up, and a run that reverts uses up nothing. Once the
/// creator closes the fleet, no Key is sold and nothing goes to the trading wallet again, and anyone
/// may pay back everything here, again and again as USDC comes back. From the close on, every
/// payback waits until every minted Key counts, so a Key bought just before the close shares in it.
/// There is no administrator, no upgrade path and no pause.
contract KeyfleetTradingTreasury is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @notice Who started a payback: the creator, anyone's daily run, or anyone after the close.
    enum Payback {
        Creator,
        Daily,
        Closed
    }

    /// @notice Hundredths of a percent in a whole.
    uint256 public constant BPS = 10_000;
    /// @notice The part of every payback deposited into REGENT revenue staking, in hundredths of a
    /// percent: 1%, rounded up.
    uint256 public constant STAKING_BPS = 100;
    /// @notice How long after the last run anyone may run the daily payback again.
    uint256 public constant DAILY_INTERVAL = 1 days;
    /// @notice The lowest daily payback a creator may choose, in hundredths of a percent: 0.1%.
    uint256 public constant MIN_DAILY_PAYBACK_BPS = 10;
    /// @notice The highest daily payback a creator may choose, in hundredths of a percent: 2%.
    uint256 public constant MAX_DAILY_PAYBACK_BPS = 200;
    /// @notice The source tag every staking deposit carries: `keccak256("keyfleet.trading_payback")`.
    /// The source reference is the fleet's manager address.
    bytes32 public constant STAKING_SOURCE_TAG = keccak256("keyfleet.trading_payback");

    /// @dev The transient slot of the split-in-progress flag:
    /// `keccak256(abi.encode(uint256(keccak256("keyfleet.trading_treasury.split_in_progress")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant SPLIT_IN_PROGRESS = 0x2294ad271c648e4005f433bfaf5deeddd088203de667c2f7dab617b6e8d67500;

    /// @notice The fleet's manager, which knows the creator and the Keys that count.
    KeyfleetTradingManager public immutable MANAGER;
    /// @notice The fleet's reward ledger, which every payback funds.
    KeyfleetRewards public immutable REWARDS;
    /// @notice The fleet's USDC.
    IERC20 public immutable USDC;
    /// @notice REGENT revenue staking, read from the trading factory.
    IRegentRevenueStaking public immutable REGENT_STAKING;
    /// @notice The guaranteed daily payback, in hundredths of a percent of the USDC here at the run,
    /// from 10 to 200. It never changes.
    uint256 public immutable DAILY_PAYBACK_BPS;

    /// @notice Where the creator sends USDC to trade; zero until the creator names one.
    address public tradingWallet;
    /// @notice When the daily payback last ran; zero before its first run.
    uint64 public lastDailyAt;
    /// @notice When the creator closed the fleet; zero while it is open.
    uint64 public closedAt;

    /// @notice Only the holder of the fleet's Key 1 may do this.
    error OnlyCreator(address caller);
    /// @notice A daily payback outside `MIN_DAILY_PAYBACK_BPS` to `MAX_DAILY_PAYBACK_BPS`.
    error DailyPaybackInvalid(uint256 dailyPaybackBps);
    /// @notice A zero address.
    error ZeroAddress();
    /// @notice A zero amount.
    error ZeroAmount();
    /// @notice No trading wallet has been named.
    error NoTradingWallet();
    /// @notice The fleet is closed.
    error FleetClosed();
    /// @notice The fleet is not closed.
    error FleetOpen();
    /// @notice The amount is more than the treasury holds.
    error AboveBalance(uint256 amount, uint256 balance);
    /// @notice The daily payback is not due: a day has not passed since the last run or Key 1's mint.
    error DailyNotDue(uint256 dueAt);
    /// @notice No Key counts yet.
    error NoKeysCount();
    /// @notice After the close, some minted Keys do not count yet.
    error KeysMaturing(uint256 counting, uint256 minted);
    /// @notice The amount, less the staking part, does not give every counting Key a whole unit.
    error PaybackTooSmall(uint256 amount, uint256 keys);
    /// @notice Staking did not take exactly the amount approved for it.
    error StakingDepositFailed(uint256 amount, uint256 received);

    /// @notice The creator named the trading wallet.
    event TradingWalletNamed(address indexed wallet);
    /// @notice The creator sent `amount` USDC to the trading wallet `wallet`.
    event SentToTrading(address indexed wallet, uint256 amount);
    /// @notice A payback ran: `staked` went to REGENT revenue staking and `perKey` to each of the
    /// `keys` Keys that count; the rest of `amount` stays here.
    /// @param by Who started it.
    event PaidBack(
        address indexed by, Payback indexed kind, uint256 amount, uint256 staked, uint256 perKey, uint256 keys
    );
    /// @notice The creator closed the fleet.
    event Closed(address indexed by);

    /// @notice Binds this treasury to its fleet's manager and ledger, and to USDC and REGENT revenue
    /// staking as the trading factory names them, from the wiring the factory holds while deploying
    /// it. A daily payback out of range stops the deploy, and with it the fleet's creation.
    constructor() {
        (IKeyfleetTradingFactory factory, TradingWiring memory wiring) = KeyfleetTradingWiring.read();
        KeyfleetWiring.requireSelf(wiring.treasury);
        uint256 dailyBps = wiring.dailyPaybackBps;
        if (dailyBps < MIN_DAILY_PAYBACK_BPS || dailyBps > MAX_DAILY_PAYBACK_BPS) {
            revert DailyPaybackInvalid(dailyBps);
        }
        MANAGER = KeyfleetTradingManager(wiring.manager);
        REWARDS = KeyfleetRewards(wiring.rewards);
        USDC = factory.USDC();
        REGENT_STAKING = factory.REGENT_STAKING();
        DAILY_PAYBACK_BPS = dailyBps;
    }

    modifier onlyCreator() {
        if (msg.sender != MANAGER.creator()) revert OnlyCreator(msg.sender);
        _;
    }

    // --- views -----------------------------------------------------------

    /// @notice Whether the treasury is inside its payback's call to the ledger right now. The ledger
    /// accepts funding only while this is true.
    function splitInProgress() external view returns (bool) {
        return SPLIT_IN_PROGRESS.asBoolean().tload();
    }

    /// @notice When anyone may next run the daily payback: a day after the last run, or a day after
    /// Key 1's mint before any run. Zero while no Key has been minted.
    function nextDailyAt() public view returns (uint256) {
        uint256 firstMintAt = MANAGER.firstMintAt();
        if (firstMintAt == 0) return 0;
        return Math.max(lastDailyAt, firstMintAt) + DAILY_INTERVAL;
    }

    // --- the creator -----------------------------------------------------

    /// @notice Names the wallet the creator trades from. Only the creator.
    function setTradingWallet(address wallet) external onlyCreator {
        if (wallet == address(0)) revert ZeroAddress();
        tradingWallet = wallet;
        emit TradingWalletNamed(wallet);
    }

    /// @notice Sends `amount` of the USDC here to the trading wallet. Only the creator, only while
    /// the fleet is open and a trading wallet is named.
    function sendToTrading(uint256 amount) external nonReentrant onlyCreator {
        if (closedAt != 0) revert FleetClosed();
        address wallet = tradingWallet;
        if (wallet == address(0)) revert NoTradingWallet();
        if (amount == 0) revert ZeroAmount();
        emit SentToTrading(wallet, amount);
        USDC.safeTransfer(wallet, amount);
    }

    /// @notice Pays back `amount` of the USDC here: 1% to REGENT revenue staking and the rest
    /// shared equally among the Keys that count. Only the creator.
    function payback(uint256 amount) external nonReentrant onlyCreator {
        _payback(amount, Payback.Creator);
    }

    /// @notice Closes the fleet, once: no Key is sold and nothing goes to the trading wallet again.
    /// Only the creator.
    function close() external onlyCreator {
        if (closedAt != 0) revert FleetClosed();
        closedAt = uint64(block.timestamp);
        emit Closed(msg.sender);
    }

    // --- anyone ----------------------------------------------------------

    /// @notice Runs the guaranteed daily payback: `DAILY_PAYBACK_BPS` hundredths of a percent of the
    /// USDC here now, rounded down. Anyone may run it once it is due.
    function runDailyPayback() external nonReentrant {
        uint256 dueAt = nextDailyAt();
        if (dueAt == 0 || block.timestamp < dueAt) revert DailyNotDue(dueAt);
        lastDailyAt = uint64(block.timestamp);
        _payback(Math.mulDiv(USDC.balanceOf(address(this)), DAILY_PAYBACK_BPS, BPS), Payback.Daily);
    }

    /// @notice Pays back everything here. Anyone may, once the fleet is closed.
    function paybackAll() external nonReentrant {
        if (closedAt == 0) revert FleetOpen();
        _payback(USDC.balanceOf(address(this)), Payback.Closed);
    }

    // --- internals -------------------------------------------------------

    /// @dev The one payback routine. Every check comes first; then the staking part is deposited,
    /// the Keys' part sent to the ledger, and the ledger funded with the flag up for that call only.
    function _payback(uint256 amount, Payback kind) private {
        uint256 balance = USDC.balanceOf(address(this));
        if (amount > balance) revert AboveBalance(amount, balance);
        uint256 keys = MANAGER.matureKeys();
        if (keys == 0) revert NoKeysCount();
        if (closedAt != 0) {
            uint256 minted = MANAGER.totalMinted();
            if (keys != minted) revert KeysMaturing(keys, minted);
        }
        uint256 staked = Math.mulDiv(amount, STAKING_BPS, BPS, Math.Rounding.Ceil);
        uint256 perKey = (amount - staked) / keys;
        if (perKey == 0) revert PaybackTooSmall(amount, keys);
        emit PaidBack(msg.sender, kind, amount, staked, perKey, keys);

        USDC.forceApprove(address(REGENT_STAKING), staked);
        uint256 received =
            REGENT_STAKING.depositUSDC(staked, STAKING_SOURCE_TAG, bytes32(uint256(uint160(address(MANAGER)))));
        if (received != staked || USDC.allowance(address(this), address(REGENT_STAKING)) != 0) {
            revert StakingDepositFailed(staked, received);
        }

        USDC.safeTransfer(address(REWARDS), perKey * keys);
        TransientSlot.BooleanSlot flag = SPLIT_IN_PROGRESS.asBoolean();
        flag.tstore(true);
        REWARDS.fundSplit(address(USDC), perKey, keys);
        flag.tstore(false);
    }
}
