// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";
import {KeyfleetTreasury} from "./KeyfleetTreasury.sol";

/// @notice Per-fleet reward ledger. One instance is permanently bound to one fleet contract.
/// @dev There is no admin, no upgrade path, and no exit other than `claim`. Two things fill it.
///
/// The fleet writes its USDC obligations: the Accelerant rebate, credited straight to the holder
/// of the preceding key, and the Cascade repayment, allocated to the preceding level's cohort
/// through a per-cohort cumulative index scaled by `PRECISION`. Cohort membership is the fleet's
/// decision: cohort 0 on Classic and Accelerant, and the key's level on the two Fibonacci presets.
///
/// The treasury funds the daily split: the same whole amount per key for every minted key, in
/// native ETH or a token, added to that asset's split index, which counts whole atomic units per
/// key. It may only do so from inside its own split routine, never through an approved proposal's
/// call, and only for exactly as many keys as have been minted.
///
/// Neither lane ever iterates over recipients. Accrued rewards belong permanently to the address
/// that held the key while they accrued: the fleet settles a key to its outgoing owner, for every
/// asset, before every ownership change, and the incoming owner continues from the current index.
contract KeyfleetRewards is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error OnlyFleet();
    /// @notice Only the fleet's treasury funds the split.
    error OnlyTreasury();
    /// @notice The treasury was not inside its split routine, so the call came from somewhere else
    /// in it, such as an approved proposal's call.
    error NotSplitting();
    error UnknownAsset();
    error KeyAlreadyEnrolled();
    error KeyNotEnrolled();
    error NoEligibleKeys();
    error ZeroAmount();
    error InsufficientBacking();
    /// @notice The split was worked out for a different number of keys than have been minted.
    error KeyCountChanged(uint256 keys, uint256 minted);
    /// @notice The ETH sent with a split funding is not exactly the amount per key times the keys.
    error WrongValue(uint256 value);
    /// @notice The caller neither holds the key nor holds an active shard of it.
    error NotKeyHolderOrAgent(uint256 tokenId);
    error NothingToClaim();

    /// @notice Fixed-point scale of every cohort index.
    uint256 public constant PRECISION = 1e27;
    /// @notice How the ledger names native ETH wherever it names an asset.
    address public constant NATIVE = address(0);

    /// @notice The fleet contract that owns this ledger and holds the keys.
    Keyfleet public immutable FLEET;
    /// @notice The fleet's USDC, the one token of the cohort lane and of direct credits.
    address public immutable USDC;
    /// @notice The fleet's treasury, the only account that funds the split.
    KeyfleetTreasury public immutable TREASURY;
    /// @notice The fleet's shard record, which says which wallets may claim for a key as its agent.
    KeyfleetShards public immutable SHARDS;

    /// @notice Assets reserved for credits, unsettled accruals, and retained rounding dust.
    mapping(address asset => uint256 amount) public backed;
    /// @notice Pull credits already settled to an address, in atomic units.
    mapping(address asset => mapping(address account => uint256 amount)) public credits;
    /// @notice Number of enrolled keys in a cohort. Keys are never unenrolled.
    mapping(uint256 cohortId => uint256 size) public cohortSize;
    /// @notice Cumulative USDC per key for a cohort, scaled by PRECISION.
    mapping(address asset => mapping(uint256 cohortId => uint256 index)) public cohortIndex;
    /// @notice Cumulative split per key for an asset, in whole atomic units.
    mapping(address asset => uint256 perKey) public splitIndex;
    /// @notice The split index a key has been settled up to, per asset.
    mapping(uint256 tokenId => mapping(address asset => uint256 perKey)) public keySplitIndex;

    /// @dev Every asset the split has funded, in the order first funded. Only the treasury's split
    /// routine appends to it, and only with the treasury's bound assets.
    address[] private _splitAssets;
    /// @dev Cohort id of an enrolled key, stored offset by one so that zero means "not enrolled".
    mapping(uint256 tokenId => uint256 cohortIdPlusOne) private _keyCohortPlusOne;
    /// @dev Per-key watermark into `cohortIndex`. Settlement advances it by the whole units paid
    /// rather than to the full index, so the sub-unit remainder is carried forward instead of
    /// being dropped on every settlement.
    mapping(uint256 tokenId => mapping(address asset => uint256 index)) private _keyIndex;

    event KeyEnrolled(uint256 indexed tokenId, uint256 indexed cohortId);
    event Allocated(address indexed asset, uint256 indexed cohortId, uint256 amount, uint256 newIndex);
    event Credited(address indexed asset, address indexed account, uint256 amount);
    /// @notice The treasury's split added `perKey` of `asset` to every one of `keys` minted keys.
    event SplitFunded(address indexed asset, uint256 perKey, uint256 keys, uint256 newIndex);
    event Settled(uint256 indexed tokenId, address indexed asset, address indexed owner, uint256 amount);
    /// @notice `account` was paid its credit; `by` pressed claim, as the account itself or as the
    /// agent of one of its keys.
    event Claimed(address indexed asset, address indexed account, address indexed by, uint256 amount);

    constructor(Keyfleet fleet, address usdc, KeyfleetTreasury treasury, KeyfleetShards shards) {
        if (
            address(fleet) == address(0) || usdc == address(0) || address(treasury) == address(0)
                || address(shards) == address(0)
        ) revert ZeroAddress();
        FLEET = fleet;
        USDC = usdc;
        TREASURY = treasury;
        SHARDS = shards;
    }

    modifier onlyFleet() {
        if (msg.sender != address(FLEET)) revert OnlyFleet();
        _;
    }

    /// @dev The treasury, and only from inside its split routine.
    modifier onlySplit() {
        if (msg.sender != address(TREASURY)) revert OnlyTreasury();
        if (!TREASURY.splitInProgress()) revert NotSplitting();
        _;
    }

    /// @notice Every asset the ledger pays: USDC first, then each asset the split has funded, in
    /// the order first funded. ETH is `NATIVE`.
    function rewardAssets() external view returns (address[] memory assets) {
        address[] memory split = _splitAssets;
        bool usdcSplit = splitIndex[USDC] != 0;
        assets = new address[](usdcSplit ? split.length : split.length + 1);
        assets[0] = USDC;
        uint256 count = 1;
        for (uint256 i = 0; i < split.length; ++i) {
            if (split[i] != USDC) assets[count++] = split[i];
        }
    }

    /// @notice Cohort id of an enrolled key.
    function keyCohort(uint256 tokenId) external view returns (uint256) {
        return _cohortOf(tokenId);
    }

    /// @notice Enrolls a key into a cohort at that cohort's current index and at every split
    /// index, so it earns nothing from earlier allocations. Enrollment is permanent and happens at
    /// most once per key. An asset first split later starts from zero, which every key shares.
    function enrollKey(uint256 tokenId, uint256 cohortId) external onlyFleet {
        if (_keyCohortPlusOne[tokenId] != 0) revert KeyAlreadyEnrolled();
        _keyCohortPlusOne[tokenId] = cohortId + 1;
        cohortSize[cohortId] += 1;
        _keyIndex[tokenId][USDC] = cohortIndex[USDC][cohortId];
        address[] memory split = _splitAssets;
        for (uint256 i = 0; i < split.length; ++i) {
            keySplitIndex[tokenId][split[i]] = splitIndex[split[i]];
        }
        emit KeyEnrolled(tokenId, cohortId);
    }

    /// @notice Distributes `amount` of USDC across the cohort's current members by advancing one
    /// index.
    /// @dev The full amount is reserved here, never at withdrawal. The tokens must already sit in
    /// this contract. The sub-unit remainder of the division stays behind as retained dust and is
    /// still counted as backed, so the reserve is never optimistic.
    function allocateToCohort(address asset, uint256 cohortId, uint256 amount) external onlyFleet {
        if (asset != USDC) revert UnknownAsset();
        if (amount == 0) revert ZeroAmount();
        uint256 size = cohortSize[cohortId];
        if (size == 0) revert NoEligibleKeys();
        uint256 reserved = backed[asset] + amount;
        if (IERC20(asset).balanceOf(address(this)) < reserved) revert InsufficientBacking();
        uint256 newIndex = cohortIndex[asset][cohortId] + (amount * PRECISION) / size;
        cohortIndex[asset][cohortId] = newIndex;
        backed[asset] = reserved;
        emit Allocated(asset, cohortId, amount, newIndex);
    }

    /// @notice Credits one address directly with USDC, outside any index.
    function credit(address asset, address account, uint256 amount) external onlyFleet {
        if (asset != USDC) revert UnknownAsset();
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 reserved = backed[asset] + amount;
        if (IERC20(asset).balanceOf(address(this)) < reserved) revert InsufficientBacking();
        credits[asset][account] += amount;
        backed[asset] = reserved;
        emit Credited(asset, account, amount);
    }

    /// @notice Adds `perKey` of a token to every one of the `keys` minted keys. The treasury has
    /// already sent `perKey * keys` here.
    function fundSplit(address asset, uint256 perKey, uint256 keys) external onlySplit {
        if (asset == NATIVE) revert UnknownAsset();
        _fundSplit(asset, perKey, keys, IERC20(asset).balanceOf(address(this)));
    }

    /// @notice Adds `perKey` of ETH to every one of the `keys` minted keys, sent with the call.
    function fundSplitNative(uint256 perKey, uint256 keys) external payable onlySplit {
        if (msg.value != perKey * keys) revert WrongValue(msg.value);
        _fundSplit(NATIVE, perKey, keys, address(this).balance);
    }

    /// @notice Converts a key's accruals, in every asset, into pull credits for `owner`. The fleet
    /// calls this before every ownership change so the outgoing owner keeps what the key earned
    /// under them.
    function settleKey(uint256 tokenId, address owner) external onlyFleet {
        if (owner == address(0)) revert ZeroAddress();
        _settleAll(tokenId, owner);
    }

    /// @notice Whole units of `asset` a key has accrued and not yet had settled.
    function accrued(address asset, uint256 tokenId) external view returns (uint256) {
        uint256 cohortId = _cohortOf(tokenId);
        return (cohortIndex[asset][cohortId] - _keyIndex[tokenId][asset]) / PRECISION + splitIndex[asset]
            - keySplitIndex[tokenId][asset];
    }

    /// @notice Settles `tokenIds` to their holders and pays out, for each of `assets`, the caller's
    /// own credit and the credit of every holder of those keys.
    /// @dev The caller must hold each key or hold an active shard of it. Money for a key always
    /// goes to the wallet holding it, never to an agent that pressed claim; the caller is paid only
    /// its own credit, which with no keys named is how a former holder collects. Each payment is
    /// one asset to one wallet, ETH by `Address.sendValue`, so a wallet that refuses ETH only stops
    /// a claim that includes ETH for it, and the same claim without ETH goes through.
    /// @return paid The total paid in each of `assets`, in the same order.
    function claim(uint256[] calldata tokenIds, address[] calldata assets)
        external
        nonReentrant
        returns (uint256[] memory paid)
    {
        address[] memory payees = new address[](tokenIds.length + 1);
        payees[0] = msg.sender;
        uint256 count = 1;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            address holder = FLEET.ownerOf(tokenId);
            if (msg.sender != holder && !SHARDS.isActive(tokenId, msg.sender)) revert NotKeyHolderOrAgent(tokenId);
            _settleAll(tokenId, holder);
            if (!_listed(payees, count, holder)) payees[count++] = holder;
        }

        paid = new uint256[](assets.length);
        bool any;
        for (uint256 a = 0; a < assets.length; ++a) {
            address asset = assets[a];
            for (uint256 p = 0; p < count; ++p) {
                address payee = payees[p];
                uint256 amount = credits[asset][payee];
                if (amount == 0) continue;
                credits[asset][payee] = 0;
                backed[asset] -= amount;
                paid[a] += amount;
                any = true;
                emit Claimed(asset, payee, msg.sender, amount);
                if (asset == NATIVE) Address.sendValue(payable(payee), amount);
                else IERC20(asset).safeTransfer(payee, amount);
            }
        }
        if (!any) revert NothingToClaim();
    }

    function _fundSplit(address asset, uint256 perKey, uint256 keys, uint256 balance) private {
        if (perKey == 0) revert ZeroAmount();
        uint256 minted = FLEET.totalMinted();
        if (keys != minted) revert KeyCountChanged(keys, minted);
        uint256 reserved = backed[asset] + perKey * keys;
        if (balance < reserved) revert InsufficientBacking();
        uint256 index = splitIndex[asset];
        if (index == 0) _splitAssets.push(asset);
        index += perKey;
        splitIndex[asset] = index;
        backed[asset] = reserved;
        emit SplitFunded(asset, perKey, keys, index);
    }

    function _cohortOf(uint256 tokenId) private view returns (uint256) {
        uint256 cohortIdPlusOne = _keyCohortPlusOne[tokenId];
        if (cohortIdPlusOne == 0) revert KeyNotEnrolled();
        return cohortIdPlusOne - 1;
    }

    /// @dev Settles the key's USDC cohort accrual and its split accrual in every split asset.
    function _settleAll(uint256 tokenId, address owner) private {
        _settleCohort(tokenId, _cohortOf(tokenId), owner);
        address[] memory split = _splitAssets;
        for (uint256 i = 0; i < split.length; ++i) {
            address asset = split[i];
            uint256 index = splitIndex[asset];
            uint256 amount = index - keySplitIndex[tokenId][asset];
            if (amount == 0) continue;
            keySplitIndex[tokenId][asset] = index;
            credits[asset][owner] += amount;
            emit Settled(tokenId, asset, owner, amount);
        }
    }

    /// @dev Advances the key's watermark by exactly the whole units credited, carrying the
    /// sub-unit remainder into the next settlement. Total dust per key therefore stays below one
    /// atomic unit for the lifetime of the key instead of growing per settlement.
    function _settleCohort(uint256 tokenId, uint256 cohortId, address owner) private {
        uint256 snapshot = _keyIndex[tokenId][USDC];
        uint256 amount = (cohortIndex[USDC][cohortId] - snapshot) / PRECISION;
        if (amount == 0) return;
        _keyIndex[tokenId][USDC] = snapshot + amount * PRECISION;
        credits[USDC][owner] += amount;
        emit Settled(tokenId, USDC, owner, amount);
    }

    function _listed(address[] memory accounts, uint256 count, address account) private pure returns (bool) {
        for (uint256 i = 0; i < count; ++i) {
            if (accounts[i] == account) return true;
        }
        return false;
    }
}
