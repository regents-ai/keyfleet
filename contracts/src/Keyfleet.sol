// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";
import {KeyfleetAssetRegistry} from "./KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";

/// @notice One fleet: the keys, the primary purchases, and the REGENT accounting behind them.
/// @dev The keys are an ordinary OpenZeppelin ERC721 with 1-based, contiguous token ids. Every
/// price, supply bound, holding limit and purchase split comes from `KeyfleetPresets`; this
/// contract never repeats that arithmetic. Every reward obligation is recorded in the
/// `KeyfleetRewards` ledger this contract deploys for itself in its constructor, and the tokens
/// backing an obligation are moved into that ledger in the same transaction that records it.
///
/// It also takes the two non-key deposit paths and the surplus reconciliation. Every new external
/// receipt pays one 2% fee: in USDC to the Regents staking contract as registered revenue, in any
/// other admitted asset to the Regents treasury in that asset. Internal movements into the ledger
/// and claims out of it are not receipts and are never charged again.
///
/// Votes, capital transfers, Autolaunch and the deploying factory are later slices, and nothing
/// speculative is prepared for them here.
///
/// There is no administrator, no upgrade path, no pause, no burn and no withdrawal: the only ways
/// REGENT leaves this contract are the protocol share on a purchase, the referral and Accelerant
/// rebate paid into the ledger, the Cascade reimbursement paid into the ledger, and the deposit fee
/// and revenue backing of a REGENT deposit.
contract Keyfleet is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

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
    /// @notice The supplied USDC is not the canonical Base USDC the shared registry is bound to.
    error UsdcNotCanonical(address supplied, address canonical);
    /// @notice The asset is not currently admitted for deposits into this fleet.
    error AssetNotAdmitted(address asset);
    /// @notice A deposit or a recognized surplus of zero is rejected.
    error ZeroAmount();
    /// @notice The staking contract did not register the whole USDC fee, so the deposit is refused.
    error FeeRegistrationFailed(uint256 fee, uint256 received);
    /// @notice No cohort can receive revenue yet: no key is minted, or no Fibonacci level is complete.
    error NoEligibleKeys();
    /// @notice This fleet's balance of the asset is fully accounted for, so there is nothing to recognize.
    error NoSurplus();

    /// @notice A primary key was bought. The five split parts always sum to `gross`.
    /// @param tokenId The key that was minted.
    /// @param buyer The caller, who paid the REGENT.
    /// @param receiver The address the key was minted to.
    /// @param referrer The supplied referrer, or the zero address when none was supplied.
    /// @param gross The REGENT price paid.
    /// @param protocol REGENT sent to the Regents treasury.
    /// @param referral REGENT credited to the referrer in the ledger.
    /// @param capital REGENT added to this fleet's free capital.
    /// @param reserve REGENT added to the Cascade completion reserve.
    /// @param rebate REGENT credited to the holder of the preceding key in the ledger.
    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed receiver,
        address referrer,
        uint256 gross,
        uint256 protocol,
        uint256 referral,
        uint256 capital,
        uint256 reserve,
        uint256 rebate
    );

    /// @notice A key changed hands. The mint is epoch 1 and every transfer adds one, so a key that
    /// returns to an earlier owner carries a strictly higher epoch than it did before.
    event OwnershipEpoch(uint256 indexed tokenId, uint64 epoch, address indexed from, address indexed to);

    /// @notice A Cascade level was fully minted and its reserve was released.
    /// @param level The level that completed.
    /// @param reimbursement REGENT allocated to the holders of the preceding level.
    /// @param surplus REGENT released to free capital.
    event LevelCompleted(uint256 indexed level, uint256 reimbursement, uint256 surplus);

    /// @notice The 2% external-receipt fee was routed. A fee of zero is still reported.
    /// @param asset The asset received.
    /// @param amount The gross receipt the fee was taken from.
    /// @param fee The fee, floored, so `amount - fee` is what the fleet kept.
    /// @param destination The staking contract for USDC, the Regents treasury for everything else.
    event FeeCharged(address indexed asset, uint256 amount, uint256 fee, address indexed destination);

    /// @notice A non-key receipt became free working capital.
    event CapitalDeposited(address indexed asset, address indexed depositor, uint256 amount, uint256 net);

    /// @notice A non-key receipt became member reward backing in the ledger.
    /// @param paymentRef The payer's own payment reference, also the staking source reference for USDC.
    event RevenueDeposited(
        address indexed asset, address indexed depositor, uint256 amount, uint256 net, bytes32 paymentRef
    );

    /// @notice An unaccounted balance was reconciled into free working capital.
    event SurplusRecognized(address indexed asset, address indexed caller, uint256 amount, uint256 net);

    /// @notice External-receipt fee, in basis points of the gross receipt.
    uint256 public constant DEPOSIT_FEE_BPS = 200;
    /// @notice Revenue source label every fleet reports to the staking contract.
    bytes32 public constant SOURCE_TAG = keccak256("keyfleet");

    /// @notice The preset this fleet was deployed with. It can never change.
    KeyfleetPresets.Preset public immutable PRESET;
    /// @notice Reference price in atomic REGENT units, within `1 <= Q <= KeyfleetPresets.MAX_Q`.
    uint256 public immutable Q;
    /// @notice The REGENT token. Every primary purchase is paid in it and nothing else.
    IERC20 public immutable REGENT;
    /// @notice The one USDC address whose deposit fee is registered as staking revenue. It is the
    /// canonical Base USDC the shared registry is bound to, checked at construction, because symbol
    /// equality proves nothing about token identity.
    IERC20 public immutable USDC;
    /// @notice The Regents treasury multisig, paid its share of every purchase immediately.
    address public immutable TREASURY;
    /// @notice The reward ledger this fleet deployed for itself and is the sole writer of.
    KeyfleetRewards public immutable REWARDS;
    /// @notice The shared deposit-admission registry, consulted on every new external receipt.
    KeyfleetAssetRegistry public immutable ASSET_REGISTRY;
    /// @notice The Regents revenue staking contract that registers this fleet's USDC fees.
    IRegentRevenueStaking public immutable STAKING;

    /// @notice Primary keys minted so far. Token ids are `1..totalMinted`.
    uint256 public totalMinted;
    /// @notice Accelerant only: the REGENT price of the next primary mint, stepped by 105/100 after
    /// every primary mint. Zero on the other three presets, which quote from `KeyfleetPresets`.
    uint256 public currentPrice;
    /// @notice Free working capital held by this fleet, per asset. Purchases write the REGENT
    /// entry; `depositCapital` and `recognizeSurplus` write the entry of any admitted asset.
    mapping(address asset => uint256 amount) public freeCapital;
    /// @notice Cascade only: REGENT held back for the next level completion. Never spendable capital.
    uint256 public cascadeReserve;
    /// @notice Ownership epoch of a key: 1 at mint, plus one on every transfer.
    mapping(uint256 tokenId => uint64 epoch) public ownershipEpoch;
    /// @notice Fibonacci only: keys of one level an address currently holds, against `holdingLimit`.
    mapping(address account => mapping(uint256 level => uint256 held)) public heldPerLevel;
    /// @notice Cascade only: gross REGENT paid for all primary keys of a level.
    mapping(uint256 level => uint256 gross) public levelGrossPaid;
    /// @notice Cascade only: whether a level has been fully minted and its reserve released. A level
    /// completes once; resales never reset it.
    mapping(uint256 level => bool completed) public levelCompleted;

    string private _baseTokenURI;

    /// @notice Deploys a fleet and, atomically, the reward ledger bound to it.
    /// @dev The ledger is constructed here rather than passed in, so there is no window in which a
    /// fleet points at a ledger bound to someone else. REGENT is registered as the ledger's first
    /// reward asset immediately, because referrals, Accelerant rebates and Cascade reimbursements
    /// are all denominated in it.
    /// @param preset The preset whose prices, supply and split this fleet follows.
    /// @param q Reference price in atomic REGENT units.
    /// @param regent The REGENT token.
    /// @param usdc The canonical Base USDC recorded by the shared registry, and the only asset whose
    /// deposit fee takes the staking route.
    /// @param treasury The Regents treasury multisig.
    /// @param assetRegistry The shared deposit-admission registry.
    /// @param staking The Regents revenue staking contract that registers USDC fees.
    /// @param name_ ERC721 collection name.
    /// @param symbol_ ERC721 collection symbol.
    /// @param baseTokenURI_ Fixed metadata base, returned by `_baseURI` for the life of the fleet.
    constructor(
        KeyfleetPresets.Preset preset,
        uint256 q,
        IERC20 regent,
        IERC20 usdc,
        address treasury,
        KeyfleetAssetRegistry assetRegistry,
        IRegentRevenueStaking staking,
        string memory name_,
        string memory symbol_,
        string memory baseTokenURI_
    ) ERC721(name_, symbol_) {
        if (q == 0 || q > KeyfleetPresets.MAX_Q) revert KeyfleetPresets.QOutOfBounds();
        if (
            address(regent) == address(0) || address(usdc) == address(0) || treasury == address(0)
                || address(assetRegistry) == address(0) || address(staking) == address(0)
        ) {
            revert ZeroAddress();
        }
        address canonicalUsdc = assetRegistry.BASE_USDC();
        if (address(usdc) != canonicalUsdc) revert UsdcNotCanonical(address(usdc), canonicalUsdc);
        PRESET = preset;
        Q = q;
        REGENT = regent;
        USDC = usdc;
        TREASURY = treasury;
        ASSET_REGISTRY = assetRegistry;
        STAKING = staking;
        _baseTokenURI = baseTokenURI_;
        if (preset == KeyfleetPresets.Preset.FleetTechAccelerant) currentPrice = q;

        KeyfleetRewards rewards = new KeyfleetRewards(address(this));
        rewards.registerAsset(address(regent));
        REWARDS = rewards;
    }

    // --- views -----------------------------------------------------------

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

    /// @notice REGENT price of the next primary key. Reverts once the fleet is sold out.
    /// @dev The displayed next slot is not reserved: another purchase in an earlier block can move
    /// the Fibonacci level or step the Accelerant price, which is what `maxPrice` guards against.
    function nextPrice() public view returns (uint256) {
        uint256 minted = totalMinted;
        if (minted >= maxSupply()) revert SoldOut();
        if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) return currentPrice;
        if (PRESET == KeyfleetPresets.Preset.FleetTechClassic) return KeyfleetPresets.classicPrice(Q);
        return KeyfleetPresets.fibonacciLevelPrice(Q, KeyfleetPresets.fibonacciLevelOf(minted + 1));
    }

    /// @notice How the next purchase would be divided, with or without a referrer.
    function quote(bool hasReferrer) external view returns (KeyfleetPresets.PurchaseSplit memory) {
        return KeyfleetPresets.splitPurchase(PRESET, nextPrice(), hasReferrer, _hasPredecessor(totalMinted));
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
    /// @dev Reward backing is not counted: it lives in the ledger, not in this balance.
    function accountedBalance(address asset) public view returns (uint256) {
        uint256 accounted = freeCapital[asset];
        if (asset == address(REGENT)) accounted += cascadeReserve;
        return accounted;
    }

    /// @notice Balance of an asset that arrived without being deposited, and so backs nothing.
    function surplus(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) - accountedBalance(asset);
    }

    // --- purchase --------------------------------------------------------

    /// @notice Buys the next primary key with REGENT.
    /// @dev The caller must have approved this contract for the gross price. No balance-delta check
    /// is taken around the pull: REGENT is one fixed, known, non-rebasing, fee-free token chosen at
    /// deployment, so the transferred amount is the credited amount by construction. This fleet
    /// would misprice a fee-on-transfer token, which is why REGENT is immutable.
    ///
    /// A referral is credited in the ledger, never pushed, and the ledger rejects a zero credit, so
    /// a referred purchase needs a gross of at least ten atomic units for the 10% share to exist.
    /// Every preset price is at least `q`, so this only binds at absurdly small reference prices.
    ///
    /// The key is enrolled in the ledger before it is minted, so a receiver contract may forward it
    /// straight on from inside `onERC721Received`: that transfer settles a freshly enrolled key,
    /// which owes nothing, and simply moves the key. Anything the purchase does after the mint,
    /// including a Cascade level completion, therefore sees the forwarded holder.
    ///
    /// Reentrancy: guarded, so a receiver contract cannot buy again from inside `onERC721Received`.
    /// @param receiver Address to mint to; zero mints to the caller.
    /// @param referrer Any address, including the caller; zero means no referral deduction.
    /// @param maxPrice Highest gross REGENT price the caller authorizes.
    /// @param deadline Last block timestamp at which this purchase may execute.
    /// @return tokenId The minted key.
    function purchase(address receiver, address referrer, uint256 maxPrice, uint256 deadline)
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

        REGENT.safeTransferFrom(msg.sender, address(this), gross);

        bool hasPredecessor = _hasPredecessor(minted);
        KeyfleetPresets.PurchaseSplit memory split =
            KeyfleetPresets.splitPurchase(PRESET, gross, referrer != address(0), hasPredecessor);

        REGENT.safeTransfer(TREASURY, split.protocol);
        if (referrer != address(0)) {
            REGENT.safeTransfer(address(REWARDS), split.referral);
            REWARDS.credit(address(REGENT), referrer, split.referral);
        }

        uint256 level;
        if (_isFibonacci()) {
            level = KeyfleetPresets.fibonacciLevelOf(tokenId);
            if (PRESET == KeyfleetPresets.Preset.FibonacciCascade) {
                cascadeReserve += split.reserve;
                levelGrossPaid[level] += gross;
            } else {
                freeCapital[address(REGENT)] += split.capital;
            }
        } else {
            freeCapital[address(REGENT)] += split.capital;
            if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) {
                if (hasPredecessor) {
                    address predecessor = ownerOf(tokenId - 1);
                    REGENT.safeTransfer(address(REWARDS), split.rebate);
                    REWARDS.credit(address(REGENT), predecessor, split.rebate);
                }
                currentPrice = KeyfleetPresets.accelerantNextPrice(gross);
            }
        }

        REWARDS.enrollKey(tokenId, level);
        _safeMint(to, tokenId);

        emit Purchased(
            tokenId,
            msg.sender,
            to,
            referrer,
            gross,
            split.protocol,
            split.referral,
            split.capital,
            split.reserve,
            split.rebate
        );

        if (PRESET == KeyfleetPresets.Preset.FibonacciCascade && tokenId == KeyfleetPresets.fibonacciLevelEnd(level)) {
            _completeLevel(level);
        }
    }

    // --- deposits --------------------------------------------------------

    /// @notice Pays an admitted asset in as free working capital, after the 2% receipt fee.
    /// @dev The caller must have approved this contract for `amount`. Admission is checked before
    /// anything moves. No balance-delta check is taken around the pull: admission to the registry
    /// is where fee-on-transfer and rebasing behaviour is rejected, exactly as REGENT's fixed
    /// address is what makes a purchase safe to price.
    /// @param asset The admitted asset being paid in.
    /// @param amount Atomic units to pull from the caller.
    function depositCapital(address asset, uint256 amount) external nonReentrant {
        _requireAdmitted(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 net = _chargeFee(asset, amount, bytes32(0));
        freeCapital[asset] += net;
        emit CapitalDeposited(asset, msg.sender, amount, net);
    }

    /// @notice Pays an admitted asset in as member reward backing, after the 2% receipt fee.
    /// @dev The whole net amount is moved into the ledger and allocated in the same transaction, so
    /// an obligation is never recorded without the tokens behind it. Allocation writes one index per
    /// eligible cohort and never iterates over keys or holders.
    ///
    /// Classic and Accelerant have one cohort, so the net amount is shared equally by every key
    /// minted at this moment. The two Fibonacci presets share it equally across the fully minted
    /// levels and then equally per key within each level; an unfinished level receives nothing, and
    /// keys minted later start at the index this deposit left behind. The remainder of the equal
    /// split is added to the last completed level, so the whole net amount is backed and nothing is
    /// stranded in the fleet. At most twenty levels can be eligible.
    ///
    /// The first deposit of an asset registers it in the ledger. The ledger's lifetime bound of
    /// eight reward assets is counted from REGENT, so the ninth distinct asset reverts with the
    /// ledger's `AssetBoundReached` and this fleet can never take revenue in it.
    ///
    /// A net amount smaller than the number of eligible Fibonacci levels cannot be split equally and
    /// reverts with the ledger's `ZeroAmount`; that bites below twenty atomic units of the asset.
    /// @param asset The admitted asset being paid in.
    /// @param amount Atomic units to pull from the caller.
    /// @param paymentRef The payer's payment reference, recorded in the event and, for USDC, passed
    /// to the staking contract as the fee's source reference.
    function depositRevenue(address asset, uint256 amount, bytes32 paymentRef) external nonReentrant {
        _requireAdmitted(asset);
        uint256 levels;
        if (_isFibonacci()) {
            levels = completedLevels();
            if (levels == 0) revert NoEligibleKeys();
        } else if (totalMinted == 0) {
            revert NoEligibleKeys();
        }

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 net = _chargeFee(asset, amount, paymentRef);
        if (!REWARDS.isRewardAsset(asset)) REWARDS.registerAsset(asset);
        IERC20(asset).safeTransfer(address(REWARDS), net);

        if (_isFibonacci()) {
            uint256 share = net / levels;
            for (uint256 level = 1; level <= levels; ++level) {
                REWARDS.allocateToCohort(asset, level, level == levels ? net - share * (levels - 1) : share);
            }
        } else {
            REWARDS.allocateToCohort(asset, 0, net);
        }
        emit RevenueDeposited(asset, msg.sender, amount, net, paymentRef);
    }

    /// @notice Books an admitted asset that arrived by bare transfer as free working capital, after
    /// the 2% receipt fee.
    /// @dev Permissionless, because it can only ever recognize what nobody has a claim on: it works
    /// from `balanceOf(this)` minus what this fleet has already recorded a purpose for, which is
    /// free capital plus, for REGENT, the Cascade completion reserve. Reward backing sits in the
    /// ledger and is not part of this balance at all, so no recorded liability can be reclassified,
    /// and an incomplete level's reserve can never be drawn on.
    /// @param asset The admitted asset to reconcile.
    /// @return net Atomic units added to free working capital.
    function recognizeSurplus(address asset) external nonReentrant returns (uint256 net) {
        _requireAdmitted(asset);
        uint256 amount = surplus(asset);
        if (amount == 0) revert NoSurplus();
        net = _chargeFee(asset, amount, bytes32(0));
        freeCapital[asset] += net;
        emit SurplusRecognized(asset, msg.sender, amount, net);
    }

    /// @dev Admission is checked on every new external receipt and nowhere else. Disablement stops
    /// new receipts only: booked capital, recorded reward indexes and pending claims are untouched
    /// by it, because none of them passes through here.
    function _requireAdmitted(address asset) private view {
        if (!ASSET_REGISTRY.isTokenAllowed(address(this), asset)) revert AssetNotAdmitted(asset);
    }

    /// @dev Takes the one external-receipt fee and returns what the fleet keeps. The fee is floored,
    /// so a receipt below fifty atomic units pays nothing and is kept whole. USDC is registered as
    /// staking revenue, which requires both a received amount equal to the fee and the approval it
    /// was given to be spent down to nothing. A paused, under-reporting or non-pulling staking
    /// contract therefore reverts the whole deposit rather than letting a plain transfer pass as
    /// registered revenue or leaving an unspent approval and an unpulled fee behind, which a later
    /// call would otherwise recognize as surplus.
    /// Every other asset pays the treasury in that same asset.
    function _chargeFee(address asset, uint256 amount, bytes32 paymentRef) private returns (uint256 net) {
        if (amount == 0) revert ZeroAmount();
        uint256 fee = (amount * DEPOSIT_FEE_BPS) / KeyfleetPresets.BPS_DENOMINATOR;
        net = amount - fee;

        address destination;
        if (asset == address(USDC)) {
            destination = address(STAKING);
            if (fee != 0) {
                USDC.forceApprove(destination, fee);
                uint256 received = STAKING.depositUSDC(fee, SOURCE_TAG, paymentRef);
                if (received != fee || USDC.allowance(address(this), destination) != 0) {
                    revert FeeRegistrationFailed(fee, received);
                }
            }
        } else {
            destination = TREASURY;
            if (fee != 0) IERC20(asset).safeTransfer(destination, fee);
        }
        emit FeeCharged(asset, amount, fee, destination);
    }

    // --- internals -------------------------------------------------------

    /// @dev Releases a completed Cascade level's reserve. Level 1 has no predecessor, so its whole
    /// reserve becomes capital. Above that, the reserve first repays the preceding level's original
    /// gross mint cost, as far as it stretches, to whoever holds those keys at this moment; the rest
    /// becomes capital. The reserve is always emptied, and a level completes exactly once.
    function _completeLevel(uint256 level) private {
        levelCompleted[level] = true;
        uint256 reserve = cascadeReserve;
        cascadeReserve = 0;

        uint256 reimbursement;
        if (level > 1) {
            uint256 owed = levelGrossPaid[level - 1];
            reimbursement = owed < reserve ? owed : reserve;
            REGENT.safeTransfer(address(REWARDS), reimbursement);
            REWARDS.allocateToCohort(address(REGENT), level - 1, reimbursement);
        }
        uint256 released = reserve - reimbursement;
        freeCapital[address(REGENT)] += released;
        emit LevelCompleted(level, reimbursement, released);
    }

    /// @dev Settles the outgoing owner, enforces the Fibonacci holding limit on the incoming owner
    /// and bumps the ownership epoch, all before ownership actually changes. Settlement first is
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
