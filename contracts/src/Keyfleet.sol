// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAutolaunchAuction} from "./interfaces/IAutolaunchAuction.sol";
import {IAutolaunchEscrow} from "./interfaces/IAutolaunchEscrow.sol";
import {IRegentLBPStrategy} from "./interfaces/IRegentLBPStrategy.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "./interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";
import {KeyfleetVotes} from "./KeyfleetVotes.sol";
import {IVRFCoordinatorV2Plus} from "./vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "./vendor/chainlink/libraries/VRFV2PlusClient.sol";

/// @notice One fleet: the keys, the primary purchases, and the money behind them.
/// @dev The keys are an ordinary OpenZeppelin ERC721 with 1-based, contiguous token ids. Every
/// price, supply bound, holding limit and purchase split comes from `KeyfleetPresets`; this
/// contract never repeats that arithmetic. Every key is priced and paid in atomic USDC. Every
/// reward obligation is recorded in the `KeyfleetRewards` ledger this contract deploys for itself
/// in its constructor, and the tokens backing an obligation are moved into that ledger in the same
/// transaction that records it.
///
/// The 2% protocol share of every purchase is set aside here in `protocolShareOwed`, and anyone may
/// send the whole of it with `sendProtocolShare` to be registered as revenue with the Regents
/// staking contract. A paused staking contract delays that send and never a purchase. It is the
/// only fee this fleet ever pays.
///
/// Money that reaches the fleet other than through a purchase is sorted by `recognizeSurplus`,
/// and the class it lands in depends only on the token, never on who sent it or when anyone called:
/// - income tokens — USDC, REGENT, and the fleet's launched token once its launch is recorded — go
///   to the keys in full, by the ledger's cohort formula;
/// - every other token becomes shared money;
/// - two receipts from the fleet's own launch are shared money although they arrive in income
///   tokens: the REGENT the strategy sends the fleet at graduation, and every SUBJECT the vesting
///   escrow releases. Both are booked from the strategy's and the escrow's own records before any
///   money is sorted or paid, so each is booked exactly once whatever the order of calls.
///
/// The one collective decision is taken in the `KeyfleetVotes` controller this contract deploys for
/// itself in its constructor. It is the only caller of `executeAutolaunch` and `payFromBudget`. The
/// only tokens a vote can move are shared money: the Cascade completion reserve, the owed protocol
/// share and the ledger's reward backing are all out of its reach. Every payment is matched: the
/// keys that voted YES can pay out at most their own share of an asset's shared money, and in the
/// same call the fleet moves the matches, the payment over the YES votes rounded up for every other
/// key sold, out of its shared money and into the voting controller, which pays each match to
/// whoever holds that key when it is collected. Payments assume an asset that moves exactly the
/// amount asked; a token that takes a fee when it moves, or rebases, is not supported.
///
/// An approved Autolaunch proposal calls the pinned `RegentsAutolaunchFactoryV1`, with this fleet as
/// both launcher and treasury, and records what the factory says it created. That call moves no
/// tokens and grants no allowance. A launch whose auction failed can be followed by another; a
/// graduated launch is the fleet's last.
///
/// Every key's traits come from one Chainlink VRF v2.5 answer. A purchase asks the pinned coordinator
/// for one random word and never waits for it or fails because of it; the coordinator answers a few
/// blocks later through `rawFulfillRandomWords`, and the key's seed is written once from that answer.
/// A key whose request the coordinator refused can be asked for again by anyone; a key whose request
/// was accepted waits for that answer. There is no other source of randomness and no way to choose
/// or replace a seed.
///
/// There is no administrator, no upgrade path, no pause and no burn. The only ways USDC leaves
/// this contract are the owed protocol share sent to the staking contract, the Accelerant rebate
/// paid into the ledger, the Cascade reimbursement paid into the ledger, income paid into the
/// ledger for the keys, and a payment of shared money the keys voted for with its matches, which
/// move to the voting controller.
contract Keyfleet is IERC4906, ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice How far this fleet's current Autolaunch has got.
    /// @dev `AuctionCreated` covers everything between the factory call and the strategy's terminal
    /// record, including an auction that has ended but has not been migrated yet. `Graduated` is
    /// final. `EconomicallyFailed` lasts until the keys carry out another launch, which starts again
    /// at `AuctionCreated`.
    enum LaunchState {
        NotCreated,
        AuctionCreated,
        Graduated,
        EconomicallyFailed
    }

    /// @notice The exact launch the keys approve, fixed when the proposal is created.
    /// @dev There is no treasury field: the fleet passes itself, so no proposal can name anyone
    /// else. The chain, the factory and the schedule are not here either — the factory and the
    /// strategy fix all three, and pretending they were per-launch choices would be a lie the vote
    /// could not enforce.
    /// The five metadata strings and the raise are bounded by the factory and the strategy, which
    /// publish those figures; the voting controller reads them from the target when a proposal is
    /// made rather than holding a copy of them.
    /// @param name SUBJECT name, nonempty and within the factory's `MAX_NAME_BYTES`.
    /// @param symbol SUBJECT symbol, nonempty and within the factory's `MAX_SYMBOL_BYTES`.
    /// @param description SUBJECT description, nonempty and within `MAX_DESCRIPTION_BYTES`.
    /// @param website SUBJECT website, nonempty and within the factory's `MAX_WEBSITE_BYTES`.
    /// @param image SUBJECT image reference, nonempty and within the factory's `MAX_IMAGE_BYTES`.
    /// @param requiredRegentRaised The REGENT raise the auction must reach to graduate, positive and
    /// within the strategy's `MAX_REACHABLE_RAISE`.
    /// @param narrativeDigest Digest of the content-addressed narrative behind the launch; it also
    /// becomes the proposal's digest, and zero means none.
    struct LaunchEnvelope {
        string name;
        string symbol;
        string description;
        string website;
        string image;
        uint128 requiredRegentRaised;
        bytes32 narrativeDigest;
    }

    /// @notice What the factory and the strategy say this fleet's launch is.
    /// @dev Every address here is read back from the pinned factory or the strategy it is bound to;
    /// none of them is ever taken from a proposal, a caller or an event. The four graduation fields
    /// stay zero until `syncLaunch` reads a graduated distribution.
    /// @param launchId The factory's id for this launch.
    /// @param proposalId The proposal that authorized it, so the authorising vote can be read back
    /// on chain without replaying an event.
    /// @param subject The SUBJECT token the factory created.
    /// @param createdAtBlock Block the launch was created in.
    /// @param auction The canonical auction, and the key every strategy read uses.
    /// @param escrow The escrow holding the pending allocation.
    /// @param splitter The revenue splitter, recorded at graduation.
    /// @param receiver The canonical payment receiver, recorded at graduation.
    /// @param envelopeHash `keccak256(abi.encode(envelope))` of the approved envelope.
    /// @param poolId The official pool, recorded at graduation.
    /// @param lpTokenId The locked LP position, recorded at graduation.
    struct LaunchRecord {
        uint256 launchId;
        uint256 proposalId;
        address subject;
        uint64 createdAtBlock;
        address auction;
        address escrow;
        address splitter;
        address receiver;
        bytes32 envelopeHash;
        bytes32 poolId;
        uint256 lpTokenId;
    }

    /// @notice The ERC721 identity a fleet is deployed with, fixed for its lifetime.
    /// @param name ERC721 collection name.
    /// @param symbol ERC721 collection symbol.
    /// @param baseTokenURI Metadata base, returned by `_baseURI` for the life of the fleet.
    struct Metadata {
        string name;
        string symbol;
        string baseTokenURI;
    }

    /// @notice Where a fleet's key traits come from, fixed for its lifetime.
    /// @param coordinator The Chainlink VRF v2.5 coordinator, the only address that can answer.
    /// @param subscriptionId The VRF subscription that pays for every request. Its owner adds the
    /// fleet as a consumer after deployment; until then every request fails and purchases go on.
    /// @param keyHash The VRF gas lane, which caps the gas price an answer is paid at.
    struct Randomness {
        IVRFCoordinatorV2Plus coordinator;
        uint256 subscriptionId;
        bytes32 keyHash;
    }

    /// @notice A constructor address argument was zero.
    error ZeroAddress();
    /// @notice The purchase deadline had already passed.
    error Expired(uint256 deadline);
    /// @notice The next price exceeded the maximum the buyer authorized.
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    /// @notice Every primary key of this fleet has been minted.
    error SoldOut();
    /// @notice The recipient already holds as many keys of this level as the preset allows.
    error HoldingLimitExceeded(address account, uint256 level, uint256 limit);
    /// @notice Levels exist only on the two Fibonacci presets.
    error NotFibonacciPreset();
    /// @notice The supplied USDC does not report the six decimals every price here is written in.
    error UsdcDecimalsWrong(uint8 decimals);
    /// @notice A protocol-share send with nothing owed is rejected.
    error ZeroAmount();
    /// @notice The staking contract did not register the whole USDC amount it was given, so the
    /// protocol-share send is refused.
    error StakingRegistrationFailed(uint256 amount, uint256 received);
    /// @notice No cohort can receive income yet: no key is minted, or no Fibonacci level is complete.
    error NoEligibleKeys();
    /// @notice Only this fleet's own voting controller may create its launch or spend shared money.
    error OnlyVotes();
    /// @notice This fleet's launch is still running or has graduated, so no other can be made.
    error LaunchAlreadyCreated();
    /// @notice This fleet has not created a launch, so there is nothing to sync or read.
    error LaunchNotCreated();
    /// @notice The payment is more than the YES keys' share of this asset's shared money: with every
    /// match, it does not fit in the shared money.
    /// @param amount The payment.
    /// @param matched The matches it would set aside for the keys that did not vote YES.
    /// @param available The asset's shared money.
    error AboveYesShare(address asset, uint256 amount, uint256 matched, uint256 available);
    /// @notice The launch proposal opened at or before the block this fleet's failed launch was
    /// created in, so it was approved before that launch failed and cannot follow it.
    error StaleLaunch(uint256 proposalId);
    /// @notice The factory does not record the launch it just said it created.
    error LaunchProvenanceMismatch();
    /// @notice The VRF coordinator address holds no code.
    error CoordinatorMissing(address coordinator);
    /// @notice No trait table was named.
    error TraitTableHashZero();
    /// @notice Only the VRF coordinator may deliver random words.
    error OnlyCoordinator(address caller);
    /// @notice The key already has its seed.
    error AlreadyRevealed(uint256 tokenId);
    /// @notice The coordinator has already accepted a request for this key; the key waits for its answer.
    error RevealAlreadyRequested(uint256 tokenId);

    /// @notice A primary key was bought. The four split parts always sum to `gross`.
    /// @param tokenId The key that was minted.
    /// @param buyer The caller, who paid the USDC.
    /// @param receiver The address the key was minted to.
    /// @param gross The USDC price paid.
    /// @param protocol USDC set aside for the staking contract in `protocolShareOwed`.
    /// @param capital USDC added to this fleet's shared money.
    /// @param reserve USDC added to the Cascade completion reserve.
    /// @param rebate USDC credited to the holder of the preceding key in the ledger.
    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed receiver,
        uint256 gross,
        uint256 protocol,
        uint256 capital,
        uint256 reserve,
        uint256 rebate
    );

    /// @notice A key changed hands. The mint is epoch 1 and every transfer adds one, so a key that
    /// returns to an earlier owner carries a strictly higher epoch than it did before.
    event OwnershipEpoch(uint256 indexed tokenId, uint64 epoch, address indexed from, address indexed to);

    /// @notice A Cascade level was fully minted and its reserve was released.
    /// @param level The level that completed.
    /// @param reimbursement USDC allocated to the holders of the preceding level: its whole gross cost.
    /// @param surplus USDC released to shared money.
    event LevelCompleted(uint256 indexed level, uint256 reimbursement, uint256 surplus);

    /// @notice The whole owed protocol share was registered with the staking contract.
    /// @param caller Whoever sent it; anyone may.
    /// @param amount The USDC the staking contract registered, which was the whole owed amount.
    event ProtocolShareSent(address indexed caller, uint256 amount);

    /// @notice An income token's unaccounted balance was paid to the keys through the ledger.
    event IncomeRecognized(address indexed asset, address indexed caller, uint256 amount);

    /// @notice Another token's unaccounted balance became shared money.
    event SharedMoneyRecognized(address indexed asset, address indexed caller, uint256 amount);

    /// @notice The REGENT the strategy sent this fleet at graduation was booked as shared money.
    /// @param amount The auction's raise less the REGENT the strategy put into the pool.
    event GraduationHoldingsBooked(address indexed asset, uint256 amount);

    /// @notice SUBJECT the vesting escrow released to this fleet was booked as shared money.
    /// @param amount SUBJECT released since the last booking.
    /// @param totalReleased Everything the escrow has released so far, all of it now booked.
    event VestingBooked(address indexed asset, uint256 amount, uint256 totalReleased);

    /// @notice An approved Pay proposal paid shared money out of this fleet, and set aside the
    /// match for every key that did not vote YES.
    /// @param amount Atomic units paid to the recipient.
    /// @param share What each key that did not vote YES may collect: `amount` over the YES votes,
    /// rounded up.
    /// @param matched `share` times the keys that did not vote YES, sent to the voting controller
    /// for them to collect. No longer shared money.
    event BudgetPaid(address indexed asset, address indexed recipient, uint256 amount, uint256 share, uint256 matched);

    /// @notice An approved Autolaunch proposal created this fleet's current launch. The four launch
    /// addresses are the factory's own, read back after the call and not the proposal's.
    event AutolaunchExecuted(
        uint256 indexed proposalId, uint256 indexed launchId, address indexed subject, address auction, address escrow
    );

    /// @notice A sync recorded a terminal launch state. An unsettled launch emits nothing.
    event LaunchSynced(LaunchState state);

    /// @notice The coordinator accepted a request for a key's random word.
    event RevealRequested(uint256 indexed tokenId, uint256 indexed requestId);

    /// @notice The coordinator refused a request for a key's random word, so the key waits for
    /// `requestReveal`. The purchase or request that tried still stands.
    event RevealRequestFailed(uint256 indexed tokenId);

    /// @notice A key's seed was written. It never changes afterwards.
    /// @param requestId The request whose answer produced the seed.
    /// @param seed `keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(this), tokenId, word))`.
    event KeyRevealed(uint256 indexed tokenId, uint256 indexed requestId, bytes32 seed);

    /// @notice Revenue source label every fleet reports to the staking contract.
    bytes32 public constant SOURCE_TAG = keccak256("keyfleet");
    /// @notice Source reference every protocol-share send reports to the staking contract.
    bytes32 public constant PROTOCOL_SHARE_REF = keccak256("keyfleet.protocol-share");
    /// @notice Domain tag of every key seed.
    bytes32 public constant TRAIT_SEED_TAG = keccak256("keyfleet.trait-seed");
    /// @notice Blocks the coordinator waits before answering, so a shallow reorg of the purchase
    /// lands before any seed exists.
    uint16 public constant REVEAL_CONFIRMATIONS = 3;
    /// @notice Gas the coordinator gives `rawFulfillRandomWords`. Only the gas used is charged.
    uint32 public constant REVEAL_CALLBACK_GAS_LIMIT = 100_000;
    /// @notice Random words asked for per key.
    uint32 public constant REVEAL_WORDS = 1;
    /// @dev ERC-4906, reported by `supportsInterface` so marketplaces refresh a key once revealed.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    /// @notice The preset this fleet was deployed with. It can never change.
    KeyfleetPresets.Preset public immutable PRESET;
    /// @notice The USDC every primary purchase is paid in, and an income token. The constructor
    /// requires it to report six decimals; the deployment scripts require it to be Base USDC
    /// `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` on Base.
    IERC20 public immutable USDC;
    /// @notice REGENT, an income token and the currency of the fleet's Autolaunch. The deployment
    /// scripts require it to be Base REGENT `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` on Base.
    IERC20 public immutable REGENT;
    /// @notice The reward ledger this fleet deployed for itself and is the sole writer of.
    KeyfleetRewards public immutable REWARDS;
    /// @notice The voting controller this fleet deployed for itself and the only caller of
    /// `executeAutolaunch` and `payFromBudget`.
    KeyfleetVotes public immutable VOTES;
    /// @notice The Regents revenue staking contract that registers this fleet's 2% protocol share
    /// of every purchase as revenue.
    IRegentRevenueStaking public immutable STAKING;
    /// @notice The one Autolaunch factory this fleet may ever launch through. The strategy is read
    /// from it on every call rather than stored, so a fleet can never disagree with its factory
    /// about which strategy is canonical.
    IRegentsAutolaunchFactoryV1 public immutable FACTORY;
    /// @notice The one Chainlink VRF v2.5 coordinator that answers this fleet's requests. On Base
    /// the deployment scripts require `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`.
    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;
    /// @notice The VRF subscription every request is paid from, in ETH.
    uint256 public immutable VRF_SUBSCRIPTION_ID;
    /// @notice The VRF gas lane every request names.
    bytes32 public immutable VRF_KEY_HASH;
    /// @notice `keccak256` of the published trait-table file, byte for byte, that every key's traits
    /// are drawn from with its seed. Fixed before the first sale, so the table can never be changed
    /// after the seeds are known.
    bytes32 public immutable TRAIT_TABLE_HASH;

    /// @notice Primary keys minted so far. Token ids are `1..totalMinted`.
    uint256 public totalMinted;
    /// @notice Accelerant only: the USDC price of the next primary mint, stepped by 105/100 after
    /// every primary mint. Zero on the other three presets, which quote from `KeyfleetPresets`.
    uint256 public currentPrice;
    /// @notice Shared money held by this fleet, per asset. Purchases and Cascade level completions
    /// write the USDC entry; `recognizeSurplus` writes the entry of every token that is not an income
    /// token; the launch bookings write the REGENT and SUBJECT entries. The only way out is
    /// `payFromBudget`, on an approved Pay proposal.
    mapping(address asset => uint256 amount) public freeCapital;
    /// @notice Cascade only: USDC held back for the next level completion. Never shared money.
    uint256 public cascadeReserve;
    /// @notice USDC set aside from purchases as staking revenue and not yet sent to the staking
    /// contract. Never shared money and never surplus.
    uint256 public protocolShareOwed;
    /// @notice Ownership epoch of a key: 1 at mint, plus one on every transfer.
    mapping(uint256 tokenId => uint64 epoch) public ownershipEpoch;
    /// @notice Block of a key's mint or latest transfer. A key votes on a proposal only if it last
    /// moved in a block before the one the proposal opened in.
    mapping(uint256 tokenId => uint64 blockNumber) public lastMovedBlock;
    /// @notice Fibonacci only: keys of one level an address currently holds, against `holdingLimit`.
    mapping(address account => mapping(uint256 level => uint256 held)) public heldPerLevel;
    /// @notice Cascade only: gross USDC paid for all primary keys of a level.
    mapping(uint256 level => uint256 gross) public levelGrossPaid;
    /// @notice Cascade only: whether a level has been fully minted and its reserve released. A level
    /// completes once; resales never reset it.
    mapping(uint256 level => bool completed) public levelCompleted;
    /// @notice How far this fleet's current Autolaunch has got.
    LaunchState public launchState;
    /// @notice SUBJECT released by the vesting escrow that is already booked as shared money.
    uint256 public vestingBooked;
    /// @notice A key's trait seed, zero until the coordinator answers. Written once.
    mapping(uint256 tokenId => bytes32 seed) public revealSeed;
    /// @notice When the coordinator accepted the request for a key, zero if it never has.
    mapping(uint256 tokenId => uint64 requestedAt) public revealRequestedAt;

    string private _baseTokenURI;
    LaunchRecord private _launch;
    mapping(uint256 requestId => uint256 tokenId) private _requestToken;

    /// @notice Deploys a fleet and, atomically, the reward ledger and voting controller bound to it.
    /// @dev Both satellites are constructed here rather than passed in, so there is no window in
    /// which a fleet points at a ledger or a controller bound to someone else. The ledger is bound
    /// to USDC and REGENT, the two income tokens a fleet has from its first block.
    /// @param preset The preset whose prices, supply and split this fleet follows.
    /// @param usdc The USDC every key is paid in, reporting six decimals.
    /// @param regent The REGENT token.
    /// @param staking The Regents revenue staking contract that registers the protocol share.
    /// @param factory The one Autolaunch factory this fleet may launch through.
    /// @param metadata The ERC721 name, symbol and metadata base.
    /// @param randomness The VRF coordinator, subscription and gas lane.
    /// @param traitTableHash `keccak256` of the published trait-table file, byte for byte. Not zero.
    constructor(
        KeyfleetPresets.Preset preset,
        IERC20 usdc,
        IERC20 regent,
        IRegentRevenueStaking staking,
        IRegentsAutolaunchFactoryV1 factory,
        Metadata memory metadata,
        Randomness memory randomness,
        bytes32 traitTableHash
    ) ERC721(metadata.name, metadata.symbol) {
        if (
            address(usdc) == address(0) || address(regent) == address(0) || address(staking) == address(0)
                || address(factory) == address(0)
        ) {
            revert ZeroAddress();
        }
        uint8 decimals = IERC20Metadata(address(usdc)).decimals();
        if (decimals != KeyfleetPresets.USDC_DECIMALS) revert UsdcDecimalsWrong(decimals);
        // A coordinator without code would make the request in `purchase` revert past its `catch`.
        if (address(randomness.coordinator).code.length == 0) {
            revert CoordinatorMissing(address(randomness.coordinator));
        }
        if (traitTableHash == bytes32(0)) revert TraitTableHashZero();
        PRESET = preset;
        USDC = usdc;
        REGENT = regent;
        STAKING = staking;
        FACTORY = factory;
        VRF_COORDINATOR = randomness.coordinator;
        VRF_SUBSCRIPTION_ID = randomness.subscriptionId;
        VRF_KEY_HASH = randomness.keyHash;
        TRAIT_TABLE_HASH = traitTableHash;
        _baseTokenURI = metadata.baseTokenURI;
        if (preset == KeyfleetPresets.Preset.FleetTechAccelerant) currentPrice = KeyfleetPresets.Q_USDC;

        REWARDS = new KeyfleetRewards(address(this), address(usdc), address(regent));
        VOTES = new KeyfleetVotes(this);
    }

    // --- views -----------------------------------------------------------

    /// @notice The metadata base every `tokenURI` of this fleet starts with, fixed at construction.
    function baseTokenURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /// @notice Primary keys this fleet will ever mint.
    function maxSupply() public view returns (uint256) {
        if (PRESET == KeyfleetPresets.Preset.FleetTechClassic) return KeyfleetPresets.CLASSIC_SUPPLY;
        if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) return KeyfleetPresets.MAX_ACCELERANT_KEYS;
        return KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID;
    }

    /// @notice Primary keys still available.
    function remainingSupply() external view returns (uint256) {
        return maxSupply() - totalMinted;
    }

    /// @notice USDC price of the next primary key. Reverts once the fleet is sold out.
    /// @dev The displayed next slot is not reserved: another purchase in an earlier block can move
    /// the Fibonacci level or step the Accelerant price, which is what `maxPrice` guards against.
    function nextPrice() public view returns (uint256) {
        uint256 minted = totalMinted;
        if (minted >= maxSupply()) revert SoldOut();
        if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) return currentPrice;
        if (PRESET == KeyfleetPresets.Preset.FleetTechClassic) return KeyfleetPresets.classicPrice();
        return KeyfleetPresets.fibonacciLevelPrice(KeyfleetPresets.fibonacciLevelOf(minted + 1));
    }

    /// @notice How the next purchase would be divided.
    function quote() external view returns (KeyfleetPresets.PurchaseSplit memory) {
        return KeyfleetPresets.splitPurchase(PRESET, nextPrice(), _hasPredecessor(totalMinted));
    }

    /// @notice Fibonacci level that owns a token id.
    /// @dev Reverts on the two Fleet.Tech presets, which have no levels, and outside
    /// `1..FIBONACCI_MAX_TOKEN_ID`. The level of an id is fixed by the id alone, so this answers for
    /// ids that have not been minted yet.
    function levelOf(uint256 tokenId) public view returns (uint256) {
        if (!_isFibonacci()) revert NotFibonacciPreset();
        return KeyfleetPresets.fibonacciLevelOf(tokenId);
    }

    /// @notice Keys of one level a single address may hold: one for levels 1 to 7, then a tenth of
    /// the level supply. Reverts on the two Fleet.Tech presets, which have no per-wallet cap.
    function holdingLimit(uint256 level) public view returns (uint256) {
        if (!_isFibonacci()) revert NotFibonacciPreset();
        return KeyfleetPresets.fibonacciHoldingLimit(level);
    }

    /// @notice Fibonacci levels that are fully minted and therefore eligible for revenue.
    /// @dev Derived from `totalMinted` alone, because token ids are contiguous and a level's last
    /// id is fixed by the preset. Reverts on the two Fleet.Tech presets, which have no levels.
    function completedLevels() public view returns (uint256) {
        if (!_isFibonacci()) revert NotFibonacciPreset();
        uint256 minted = totalMinted;
        if (minted == 0) return 0;
        uint256 level = KeyfleetPresets.fibonacciLevelOf(minted);
        return KeyfleetPresets.fibonacciLevelEnd(level) == minted ? level : level - 1;
    }

    /// @notice Balance of an asset this fleet has already recorded a purpose for.
    /// @dev Reward backing is not counted: it lives in the ledger, not in this balance. For USDC this
    /// is shared money plus the Cascade completion reserve plus the owed protocol share, three
    /// separate figures that purchases write to without ever reading each other.
    function accountedBalance(address asset) public view returns (uint256) {
        uint256 accounted = freeCapital[asset];
        if (asset == address(USDC)) accounted += cascadeReserve + protocolShareOwed;
        return accounted;
    }

    /// @notice Balance of an asset that has arrived and not yet been sorted by `recognizeSurplus`.
    /// @dev Until the next `recognizeSurplus`, `payFromBudget` or `syncLaunch` books them, the
    /// graduation REGENT and any SUBJECT the escrow has released are counted here too.
    function surplus(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) - accountedBalance(asset);
    }

    /// @notice ERC-165, ERC-721 and ERC-4906.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    // --- purchase --------------------------------------------------------

    /// @notice Buys the next primary key with USDC.
    /// @dev The caller must have approved this contract for the gross price. No balance-delta check
    /// is taken around the pull: `USDC` is fixed at construction, where it must report six
    /// decimals, and the deployment scripts pin it to Base USDC on Base, which is neither rebasing
    /// nor fee-charging, so the transferred amount is the credited amount by construction. A paused
    /// USDC, or one that blacklists the caller or this fleet, stops purchases until it lifts; that
    /// is accepted.
    ///
    /// The 2% protocol share is added to `protocolShareOwed` and nothing is sent: the staking
    /// contract is never called from a purchase, so a paused staking contract cannot stop one.
    ///
    /// The key is enrolled in the ledger before it is minted, so a receiver contract may forward it
    /// straight on from inside `onERC721Received`: that transfer settles a freshly enrolled key,
    /// which owes nothing, and simply moves the key. Anything the purchase does after the mint,
    /// including a Cascade level completion, therefore sees the forwarded holder.
    ///
    /// Reentrancy: guarded, so a receiver contract cannot buy again from inside `onERC721Received`.
    ///
    /// Last of all the key's random word is requested. A refused request emits
    /// `RevealRequestFailed` and the purchase stands; the key waits for `requestReveal`.
    /// @param receiver Address to mint to; zero mints to the caller.
    /// @param maxPrice Highest gross USDC price the caller authorizes.
    /// @param deadline Last block timestamp at which this purchase may execute.
    /// @return tokenId The minted key.
    function purchase(address receiver, uint256 maxPrice, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        uint256 minted = totalMinted;
        uint256 gross = nextPrice();
        if (gross > maxPrice) revert PriceAboveMax(gross, maxPrice);

        address to = receiver == address(0) ? msg.sender : receiver;
        tokenId = minted + 1;
        totalMinted = tokenId;

        USDC.safeTransferFrom(msg.sender, address(this), gross);

        bool hasPredecessor = _hasPredecessor(minted);
        KeyfleetPresets.PurchaseSplit memory split = KeyfleetPresets.splitPurchase(PRESET, gross, hasPredecessor);

        protocolShareOwed += split.protocol;

        uint256 level;
        if (_isFibonacci()) {
            level = KeyfleetPresets.fibonacciLevelOf(tokenId);
            if (PRESET == KeyfleetPresets.Preset.FibonacciCascade) {
                cascadeReserve += split.reserve;
                levelGrossPaid[level] += gross;
            } else {
                freeCapital[address(USDC)] += split.capital;
            }
        } else {
            freeCapital[address(USDC)] += split.capital;
            if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) {
                if (hasPredecessor) {
                    address predecessor = ownerOf(tokenId - 1);
                    USDC.safeTransfer(address(REWARDS), split.rebate);
                    REWARDS.credit(address(USDC), predecessor, split.rebate);
                }
                currentPrice = KeyfleetPresets.accelerantNextPrice(gross);
            }
        }

        REWARDS.enrollKey(tokenId, level);
        _safeMint(to, tokenId);

        emit Purchased(tokenId, msg.sender, to, gross, split.protocol, split.capital, split.reserve, split.rebate);

        if (PRESET == KeyfleetPresets.Preset.FibonacciCascade && tokenId == KeyfleetPresets.fibonacciLevelEnd(level)) {
            _completeLevel(level);
        }

        _requestReveal(tokenId);
    }

    // --- reveals ---------------------------------------------------------

    /// @notice Asks the coordinator again for a key's random word.
    /// @dev Open to anyone, for a minted key the coordinator has never accepted a request for: its
    /// request at purchase, and any since, were refused. Once a request is accepted the key waits
    /// for that answer and is never asked for again, so there is only ever one answer a seed can
    /// come from. A refused request emits `RevealRequestFailed` and does not revert. Guarded, so a
    /// receiver cannot add a second request to the purchase that is minting to it.
    function requestReveal(uint256 tokenId) external nonReentrant {
        _requireOwned(tokenId);
        if (revealSeed[tokenId] != bytes32(0)) revert AlreadyRevealed(tokenId);
        if (revealRequestedAt[tokenId] != 0) revert RevealAlreadyRequested(tokenId);
        _requestReveal(tokenId);
    }

    /// @notice The coordinator's answer to a request.
    /// @dev Only the pinned coordinator may call, and for it this never reverts: a reverted
    /// callback is final and the coordinator would charge for it and never answer again. An
    /// unknown request, an empty answer, or an answer for a key that already has its seed is
    /// ignored. Not guarded: a guard could only lose an answer.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(VRF_COORDINATOR)) revert OnlyCoordinator(msg.sender);
        uint256 tokenId = _requestToken[requestId];
        if (tokenId == 0 || randomWords.length == 0 || revealSeed[tokenId] != bytes32(0)) return;

        bytes32 seed = keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(this), tokenId, randomWords[0]));
        revealSeed[tokenId] = seed;
        emit KeyRevealed(tokenId, requestId, seed);
        emit MetadataUpdate(tokenId);
    }

    /// @dev Requests one random word, paid in ETH from the fleet's subscription. Never reverts: a
    /// refusal, including one caused by a caller who sent too little gas, only leaves the key
    /// waiting for `requestReveal`, and cannot choose its seed.
    function _requestReveal(uint256 tokenId) private {
        try VRF_COORDINATOR.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: VRF_KEY_HASH,
                subId: VRF_SUBSCRIPTION_ID,
                requestConfirmations: REVEAL_CONFIRMATIONS,
                callbackGasLimit: REVEAL_CALLBACK_GAS_LIMIT,
                numWords: REVEAL_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        ) returns (
            uint256 requestId
        ) {
            _requestToken[requestId] = tokenId;
            revealRequestedAt[tokenId] = uint64(block.timestamp);
            emit RevealRequested(tokenId, requestId);
        } catch {
            emit RevealRequestFailed(tokenId);
        }
    }

    // --- money ---------------------------------------------------------

    /// @notice Sorts an asset's unaccounted balance by the token it is in.
    /// @dev Permissionless, because it can only ever sort what nobody has a claim on: it works from
    /// `balanceOf(this)` minus what this fleet has already recorded a purpose for, which is shared
    /// money plus, for USDC, the Cascade completion reserve and the owed protocol share. Reward
    /// backing sits in the ledger and is not part of this balance at all, so no recorded liability
    /// can be reclassified, an incomplete level's reserve can never be drawn on, and the stakers'
    /// share can never be swept into shared money.
    ///
    /// The launch is booked first: a launch the strategy has settled is synced, the REGENT it sent
    /// at graduation is booked as shared money, and so is every SUBJECT the escrow has released since
    /// the last booking. What remains is then sorted by the token alone. An income token goes to the
    /// keys in full through `_allocateToKeys`, which follows the ledger's rules: while no key, or no
    /// Fibonacci level, can receive it the call reverts with `NoEligibleKeys`, and below one atomic
    /// unit per eligible Fibonacci level it cannot be divided and reverts with the ledger's
    /// `ZeroAmount`; either way the balance waits for a later call. Every other token becomes
    /// shared money. A balance of zero after the booking returns zero and keeps the booking.
    /// @param asset The asset to sort.
    /// @return amount What was sorted: paid to the keys for an income token, shared money otherwise.
    function recognizeSurplus(address asset) external nonReentrant returns (uint256 amount) {
        _bookLaunch();
        amount = surplus(asset);
        if (amount == 0) return 0;

        if (REWARDS.isRewardAsset(asset)) {
            _allocateToKeys(asset, amount);
            emit IncomeRecognized(asset, msg.sender, amount);
        } else {
            freeCapital[asset] += amount;
            emit SharedMoneyRecognized(asset, msg.sender, amount);
        }
    }

    /// @notice Pays shared money out of this fleet on the authority of an approved Pay proposal, and
    /// sets aside the same amount per key for every key that did not vote YES.
    /// @dev The voting controller this fleet deployed is the only caller. It passes the proposal's
    /// YES votes, which it has just checked are more than half of the keys sold. The launch is booked
    /// first, exactly as `recognizeSurplus` books it, so shared money the launch has already
    /// delivered counts.
    ///
    /// With `S` the asset's shared money, `N` the keys sold and `y` the YES votes, every key that
    /// did not vote YES is matched with `share = A / y`, rounded up, so a payment never rounds a
    /// match down to less than the YES keys paid per key, and never to zero. The payment `A` and
    /// its matches must fit together, `A + share * (N - y) <= S`, which is the YES keys' share of
    /// the shared money, `A * N <= S * y`, with the rounding taken from the YES side. The recipient
    /// receives exactly `A` and `share * (N - y)` goes to the voting controller, which pays each
    /// such key's match to whoever holds the key when it is collected. A payment that does not fit
    /// reverts with `AboveYesShare` and rolls back with the controller's execution, so the proposal
    /// stays open to be carried out later.
    ///
    /// The asset must move exactly the amount asked. A token that takes a fee when it moves, or
    /// rebases, is not supported: the recipient or the matches can receive less than recorded.
    ///
    /// Shared money is the only bucket reachable from here. The Cascade completion reserve and the
    /// owed protocol share are separate figures this function never reads, and reward backing does
    /// not sit in this contract at all.
    ///
    /// Guarded like every other entry point that moves tokens, so an asset that calls back from
    /// inside the transfer cannot sort a balance this call has already spent, and no key can be sold
    /// between the count and the payment.
    /// @param asset The asset to pay.
    /// @param amount Atomic units to pay.
    /// @param recipient Who receives them.
    /// @param yesVotes The proposal's YES votes.
    /// @return share What each key that did not vote YES may collect.
    function payFromBudget(address asset, uint256 amount, address recipient, uint256 yesVotes)
        external
        nonReentrant
        returns (uint256 share)
    {
        if (msg.sender != address(VOTES)) revert OnlyVotes();
        _bookLaunch();

        uint256 available = freeCapital[asset];
        share = Math.ceilDiv(amount, yesVotes);
        uint256 matched = share * (totalMinted - yesVotes);
        if (amount + matched > available) revert AboveYesShare(asset, amount, matched, available);
        freeCapital[asset] = available - amount - matched;

        emit BudgetPaid(asset, recipient, amount, share, matched);
        IERC20(asset).safeTransfer(recipient, amount);
        if (matched != 0) IERC20(asset).safeTransfer(address(VOTES), matched);
    }

    /// @notice Sends the whole owed protocol share to the Regents staking contract as registered
    /// revenue.
    /// @dev Permissionless and all-or-nothing: anyone may call it at any time, and it always sends
    /// exactly `protocolShareOwed`. The owed figure is zeroed before the staking call and restored
    /// by the revert if registration fails, so a paused, under-reporting or non-pulling staking
    /// contract leaves the whole amount owed for a later call, while purchases carry on adding to
    /// it. Guarded, so a staking contract that calls back cannot reach another entry point while
    /// this one is half done.
    /// @return amount The USDC registered with the staking contract.
    function sendProtocolShare() external nonReentrant returns (uint256 amount) {
        amount = protocolShareOwed;
        if (amount == 0) revert ZeroAmount();
        protocolShareOwed = 0;
        _registerWithStaking(amount, PROTOCOL_SHARE_REF);
        emit ProtocolShareSent(msg.sender, amount);
    }

    /// @dev Registers `amount` of this fleet's USDC with the staking contract under `SOURCE_TAG`.
    /// Registration requires both a received amount equal to `amount` and the approval it was given
    /// to be spent down to nothing. A paused, under-reporting or non-pulling staking contract
    /// therefore reverts the caller rather than letting a plain transfer pass as registered revenue
    /// or leaving an unspent approval and unpulled USDC behind, which a later call would otherwise
    /// recognize as surplus.
    function _registerWithStaking(uint256 amount, bytes32 sourceRef) private {
        USDC.forceApprove(address(STAKING), amount);
        uint256 received = STAKING.depositUSDC(amount, SOURCE_TAG, sourceRef);
        if (received != amount || USDC.allowance(address(this), address(STAKING)) != 0) {
            revert StakingRegistrationFailed(amount, received);
        }
    }

    // --- autolaunch ------------------------------------------------------

    /// @notice What the factory and the strategy say this fleet's current launch is.
    /// @dev All-zero until an Autolaunch executes, and replaced whole by a launch that follows a
    /// failed one; the four graduation fields stay zero until a sync reads a graduated distribution.
    function launchRecord() external view returns (LaunchRecord memory) {
        return _launch;
    }

    /// @notice The strategy's complete record of this fleet's auction, read live.
    /// @dev A pass-through for the app: this contract stores nothing from it except the four
    /// artifacts `syncLaunch` records at graduation. Reverts before a launch exists.
    function launchDistribution() external view returns (IRegentLBPStrategy.Distribution memory) {
        if (launchState == LaunchState.NotCreated) revert LaunchNotCreated();
        return FACTORY.strategy().distribution(_launch.auction);
    }

    /// @notice Creates this fleet's launch, on the authority of an approved vote.
    /// @dev The voting controller this fleet deployed is the only caller, and it passes the exact
    /// envelope the keys approved. `treasury` is `address(this)` and there is no field a proposal
    /// could put anything else in. Nothing is approved and no token moves: the factory charges the
    /// caller gas and nothing more.
    ///
    /// The current launch is synced first, so a failure the strategy has recorded counts whether or
    /// not anyone synced it. A fleet with no launch, or whose launch failed, may launch; while a
    /// launch is running, or once one has graduated, this reverts with `LaunchAlreadyCreated`. A new
    /// launch replaces the failed one's record, and its SUBJECT replaces the failed SUBJECT as the
    /// ledger's third income token. No key ever earned any of the failed SUBJECT: the strategy
    /// records a failure only once the escrow has proved it holds the whole supply and retired it.
    ///
    /// Every address recorded here is read back from the factory after the call, never taken from
    /// the return values alone and never from an event: the recorded launch must name this fleet as
    /// both launcher and treasury and must carry the same three addresses the call returned, and
    /// the factory must map the SUBJECT back to the same launch id. Anything else reverts the whole
    /// execution.
    ///
    /// Every revert here — a launch that already exists, a paused factory, a raise the strategy
    /// refuses — reverts the controller's execution with it, including the mark that the proposal
    /// was carried out. The proposal therefore stays open and consumes nothing, which is what lets a
    /// fleet wait for the factory to open and try again. The first approved Autolaunch carried out
    /// wins; another can follow only if that launch fails, and only a proposal that opened after
    /// the failed launch was created, in a later block, so an approval given before that launch
    /// failed cannot be carried out once it has; it reverts with `StaleLaunch`.
    ///
    /// Guarded, so a launch artifact that calls back cannot reach another entry point while this
    /// one is half done.
    /// @param proposalId The proposal being executed, recorded in the launch record and the event.
    /// @param openedBlock The block the proposal opened in.
    /// @param envelope The exact launch the keys approved.
    function executeAutolaunch(uint256 proposalId, uint64 openedBlock, LaunchEnvelope calldata envelope)
        external
        nonReentrant
    {
        if (msg.sender != address(VOTES)) revert OnlyVotes();
        _bookLaunch();
        LaunchState state = launchState;
        if (state == LaunchState.AuctionCreated || state == LaunchState.Graduated) revert LaunchAlreadyCreated();
        if (state == LaunchState.EconomicallyFailed && openedBlock <= _launch.createdAtBlock) {
            revert StaleLaunch(proposalId);
        }

        (uint256 launchId, address subject, address auction, address escrow) = FACTORY.launch(
            IRegentsAutolaunchFactoryV1.LaunchParams({
                name: envelope.name,
                symbol: envelope.symbol,
                description: envelope.description,
                website: envelope.website,
                image: envelope.image,
                treasury: address(this),
                requiredRegentRaised: envelope.requiredRegentRaised
            })
        );

        IRegentsAutolaunchFactoryV1.Launch memory recorded = FACTORY.launches(launchId);
        if (
            recorded.launcher != address(this) || recorded.treasury != address(this) || recorded.subject != subject
                || recorded.auction != auction || recorded.escrow != escrow
                || FACTORY.launchIdOfSubject(subject) != launchId
        ) {
            revert LaunchProvenanceMismatch();
        }

        _launch = LaunchRecord({
            launchId: launchId,
            proposalId: proposalId,
            subject: subject,
            createdAtBlock: uint64(block.number),
            auction: auction,
            escrow: escrow,
            splitter: address(0),
            receiver: address(0),
            envelopeHash: keccak256(abi.encode(envelope)),
            poolId: bytes32(0),
            lpTokenId: 0
        });
        launchState = LaunchState.AuctionCreated;
        REWARDS.setLaunchedToken(subject);

        emit AutolaunchExecuted(proposalId, launchId, subject, auction, escrow);
    }

    /// @notice Books this fleet's launch: records the strategy's verdict once it has one, and books
    /// the launch's receipts as shared money.
    /// @dev Permissionless, because it only ever copies what the strategy and the escrow already
    /// recorded. It cannot replace the recorded SUBJECT, auction or escrow, cannot redirect the
    /// treasury and cannot authorize another launch. `recognizeSurplus` and `payFromBudget` make
    /// the same booking first, so nobody has to call this for the money to be sorted right.
    ///
    /// An auction that has ended but has not been migrated is still `Active` on the strategy, which
    /// is deliberately not economic failure: the state stays `AuctionCreated` until the strategy
    /// settles. Graduation additionally records the splitter, the canonical receiver, the pool and
    /// the locked LP position, and books the REGENT the strategy sent this fleet. After graduation
    /// every call books the SUBJECT the escrow has released since the last one.
    /// @return state The state after this call.
    function syncLaunch() external nonReentrant returns (LaunchState state) {
        if (launchState == LaunchState.NotCreated) revert LaunchNotCreated();
        _bookLaunch();
        return launchState;
    }

    // --- internals -------------------------------------------------------

    /// @dev Books the launch's shared money, in an order no caller can change: first the
    /// strategy's verdict, and with graduation the REGENT sent at graduation; then, on a graduated
    /// launch, whatever the escrow's `totalReleased` has grown by since the last booking. Both
    /// figures come from the strategy's, the auction's and the escrow's own records, never from a
    /// balance, so each unit is booked exactly once however the release, the booking and every
    /// other receipt are ordered.
    function _bookLaunch() private {
        LaunchState state = launchState;
        if (state == LaunchState.AuctionCreated) state = _syncLaunch();
        if (state != LaunchState.Graduated) return;

        uint256 released = IAutolaunchEscrow(_launch.escrow).totalReleased();
        uint256 fresh = released - vestingBooked;
        if (fresh == 0) return;
        vestingBooked = released;
        freeCapital[_launch.subject] += fresh;
        emit VestingBooked(_launch.subject, fresh, released);
    }

    /// @dev Moves an `AuctionCreated` launch to the strategy's terminal verdict, when there is one,
    /// and returns the state after it. At graduation the strategy sweeps exactly the auction's
    /// `currencyRaised` of REGENT, puts `lpRegentUsed` of it into the pool and sends the rest to
    /// this fleet in the same transaction, so that difference is booked as shared money here. The
    /// strategy sends this fleet no SUBJECT at graduation: every unused unit goes to the escrow.
    function _syncLaunch() private returns (LaunchState state) {
        IRegentLBPStrategy.Distribution memory distribution = FACTORY.strategy().distribution(_launch.auction);
        if (distribution.lifecycle == IRegentLBPStrategy.Lifecycle.Graduated) {
            _launch.splitter = distribution.splitter;
            _launch.receiver = distribution.receiver;
            _launch.poolId = distribution.poolId;
            _launch.lpTokenId = distribution.lpTokenId;
            state = LaunchState.Graduated;

            uint256 raised = IAutolaunchAuction(_launch.auction).lbpInitializationParams().currencyRaised;
            uint256 held = raised - distribution.lpRegentUsed;
            freeCapital[address(REGENT)] += held;
            emit GraduationHoldingsBooked(address(REGENT), held);
        } else if (distribution.lifecycle == IRegentLBPStrategy.Lifecycle.Failed) {
            state = LaunchState.EconomicallyFailed;
        } else {
            return LaunchState.AuctionCreated;
        }

        launchState = state;
        emit LaunchSynced(state);
    }

    /// @dev Moves `amount` of an asset this fleet holds into the ledger and allocates all of it to
    /// the keys in the same transaction, so an obligation is never recorded without the tokens
    /// behind it. Allocation writes one index per eligible cohort and never iterates over keys or
    /// holders.
    ///
    /// Classic and Accelerant have one cohort, so the amount is shared equally by every key minted
    /// at this moment. The two Fibonacci presets share it equally across the fully minted levels
    /// and then equally per key within each level; an unfinished level receives nothing, and keys
    /// minted later start at the index this allocation left behind. The remainder of the equal
    /// split is added to the last completed level, and the ledger keeps its own division dust as
    /// backing, so the whole amount is backed and nothing is stranded in the fleet. At most twenty
    /// levels can be eligible. Refused with `NoEligibleKeys` while no key is minted or no Fibonacci
    /// level is complete.
    ///
    /// An amount smaller than the number of eligible Fibonacci levels cannot be split equally and
    /// reverts with the ledger's `ZeroAmount`; that bites below twenty atomic units of the asset.
    function _allocateToKeys(address asset, uint256 amount) private {
        bool fibonacci = _isFibonacci();
        uint256 levels;
        if (fibonacci) {
            levels = completedLevels();
            if (levels == 0) revert NoEligibleKeys();
        } else if (totalMinted == 0) {
            revert NoEligibleKeys();
        }

        IERC20(asset).safeTransfer(address(REWARDS), amount);

        if (fibonacci) {
            uint256 share = amount / levels;
            for (uint256 level = 1; level <= levels; ++level) {
                REWARDS.allocateToCohort(asset, level, level == levels ? amount - share * (levels - 1) : share);
            }
        } else {
            REWARDS.allocateToCohort(asset, 0, amount);
        }
    }

    /// @dev Releases a completed Cascade level's reserve. Level 1 has no predecessor, so its whole
    /// reserve becomes shared money. Above that, the reserve first repays the preceding level's
    /// whole original gross mint cost to whoever holds those keys at this moment, and the rest
    /// becomes shared money. The reserve always covers it: a level has at least 1.5 times the keys
    /// of the one before at 1.2 times the price, and 98% of every purchase is reserved, so the
    /// reserve is at least 1.76 times what the preceding level is owed. The reserve is always
    /// emptied, and a level completes exactly once.
    function _completeLevel(uint256 level) private {
        levelCompleted[level] = true;
        uint256 reserve = cascadeReserve;
        cascadeReserve = 0;

        uint256 reimbursement;
        if (level > 1) {
            reimbursement = levelGrossPaid[level - 1];
            USDC.safeTransfer(address(REWARDS), reimbursement);
            REWARDS.allocateToCohort(address(USDC), level - 1, reimbursement);
        }
        uint256 released = reserve - reimbursement;
        freeCapital[address(USDC)] += released;
        emit LevelCompleted(level, reimbursement, released);
    }

    /// @dev Settles the outgoing owner, enforces the Fibonacci holding limit on the incoming owner,
    /// bumps the ownership epoch and records the block the key moved in, all before ownership
    /// actually changes. Settlement first is
    /// what keeps accrued rewards with the address that earned them. Only this key is settled:
    /// the ledger's accruals are per key, so the recipient's other keys are unaffected by it.
    /// There is no burn path in this contract, so `to` is never the zero address.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0)) REWARDS.settleKey(tokenId, from);

        if (_isFibonacci()) {
            uint256 level = KeyfleetPresets.fibonacciLevelOf(tokenId);
            if (from != address(0)) heldPerLevel[from][level] -= 1;
            uint256 held = heldPerLevel[to][level] + 1;
            uint256 limit = KeyfleetPresets.fibonacciHoldingLimit(level);
            if (held > limit) revert HoldingLimitExceeded(to, level, limit);
            heldPerLevel[to][level] = held;
        }

        uint64 epoch = ownershipEpoch[tokenId] + 1;
        ownershipEpoch[tokenId] = epoch;
        lastMovedBlock[tokenId] = uint64(block.number);
        emit OwnershipEpoch(tokenId, epoch, from, to);

        return super._update(to, tokenId, auth);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _isFibonacci() private view returns (bool) {
        return PRESET == KeyfleetPresets.Preset.FibonacciSyndicate || PRESET == KeyfleetPresets.Preset.FibonacciCascade;
    }

    /// @dev Only an Accelerant purchase after the first one pays a rebate.
    function _hasPredecessor(uint256 minted) private view returns (bool) {
        return PRESET == KeyfleetPresets.Preset.FleetTechAccelerant && minted > 0;
    }
}
