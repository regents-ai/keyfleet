// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Per-fleet reward ledger. One instance is permanently bound to one fleet contract.
/// @dev The fleet is the sole writer. There is no admin, no upgrade path, and no exit other
/// than `claim`. The ledger pays exactly the fleet's income tokens: USDC, REGENT, and the
/// fleet's launched token once the fleet records its launch. Rewards are distributed through
/// per-cohort cumulative indexes, so allocation never iterates over recipients; settlement
/// iterates over at most those three tokens.
/// Accrued rewards belong permanently to the address that held the key while they accrued: the
/// fleet settles a key to its outgoing owner before every ownership change, and the incoming
/// owner continues from the cohort's current index.
contract KeyfleetRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error OnlyFleet();
    error LaunchedTokenAlreadySet();
    error UnknownAsset();
    error CohortOutOfBounds();
    error KeyAlreadyEnrolled();
    error KeyNotEnrolled();
    error NoEligibleKeys();
    error ZeroAmount();
    error InsufficientBacking();
    error NotKeyOwner();
    error NothingToClaim();

    /// @notice Cohort ids run 0..MAX_COHORTS-1. Cohort membership is the fleet's decision.
    uint256 public constant MAX_COHORTS = 32;
    /// @notice Fixed-point scale of every cumulative index.
    uint256 public constant PRECISION = 1e27;

    /// @notice The fleet contract that owns this ledger and holds the keys.
    address public immutable FLEET;
    /// @notice USDC, an income token from deployment.
    address public immutable USDC;
    /// @notice REGENT, an income token from deployment.
    address public immutable REGENT;
    /// @notice The fleet's launched token, an income token once the fleet records its launch; zero before.
    address public launchedToken;

    /// @notice Tokens reserved for credits, unsettled index accruals, and retained rounding dust.
    mapping(address asset => uint256 amount) public backed;
    /// @notice Pull credits already settled to an address, in atomic units.
    mapping(address asset => mapping(address account => uint256 amount)) public credits;
    /// @notice Number of enrolled keys in a cohort. Keys are never unenrolled.
    mapping(uint256 cohortId => uint256 size) public cohortSize;
    /// @notice Cumulative reward per key for a cohort, scaled by PRECISION.
    mapping(address asset => mapping(uint256 cohortId => uint256 index)) public cohortIndex;

    /// @dev Cohort id of an enrolled key, stored offset by one so that zero means "not enrolled".
    mapping(uint256 tokenId => uint256 cohortIdPlusOne) private _keyCohortPlusOne;
    /// @dev Per-key watermark into `cohortIndex`. Settlement advances it by the whole units paid
    /// rather than to the full index, so the sub-unit remainder is carried forward instead of
    /// being dropped on every settlement.
    mapping(uint256 tokenId => mapping(address asset => uint256 index)) private _keyIndex;

    event LaunchedTokenSet(address indexed asset);
    event KeyEnrolled(uint256 indexed tokenId, uint256 indexed cohortId);
    event Allocated(address indexed asset, uint256 indexed cohortId, uint256 amount, uint256 newIndex);
    event Credited(address indexed asset, address indexed account, uint256 amount);
    event Settled(uint256 indexed tokenId, address indexed asset, address indexed owner, uint256 amount);
    event Claimed(address indexed asset, address indexed account, address indexed to, uint256 amount);

    constructor(address fleet, address usdc, address regent) {
        if (fleet == address(0) || usdc == address(0) || regent == address(0)) revert ZeroAddress();
        FLEET = fleet;
        USDC = usdc;
        REGENT = regent;
    }

    modifier onlyFleet() {
        if (msg.sender != FLEET) revert OnlyFleet();
        _;
    }

    /// @notice Whether `asset` is one of the fleet's income tokens.
    function isRewardAsset(address asset) public view returns (bool) {
        return asset != address(0) && (asset == USDC || asset == REGENT || asset == launchedToken);
    }

    /// @notice The income tokens: USDC, REGENT, then the launched token once it is recorded.
    function rewardAssets() public view returns (address[] memory assets) {
        address launched = launchedToken;
        assets = new address[](launched == address(0) ? 2 : 3);
        assets[0] = USDC;
        assets[1] = REGENT;
        if (launched != address(0)) assets[2] = launched;
    }

    /// @notice Records the fleet's launched token as its third income token. Happens once.
    /// @dev No allocation in this token can exist before this call, so every key's watermark
    /// and every cohort index start together at zero.
    function setLaunchedToken(address asset) external onlyFleet {
        if (asset == address(0)) revert ZeroAddress();
        if (launchedToken != address(0)) revert LaunchedTokenAlreadySet();
        launchedToken = asset;
        emit LaunchedTokenSet(asset);
    }

    /// @notice Cohort id of an enrolled key.
    function keyCohort(uint256 tokenId) external view returns (uint256) {
        return _cohortOf(tokenId);
    }

    /// @notice Enrolls a key into a cohort at that cohort's current indexes, so it earns nothing
    /// from earlier allocations. Enrollment is permanent and happens at most once per key.
    function enrollKey(uint256 tokenId, uint256 cohortId) external onlyFleet {
        if (cohortId >= MAX_COHORTS) revert CohortOutOfBounds();
        if (_keyCohortPlusOne[tokenId] != 0) revert KeyAlreadyEnrolled();
        _keyCohortPlusOne[tokenId] = cohortId + 1;
        cohortSize[cohortId] += 1;
        address[] memory assets = rewardAssets();
        for (uint256 i = 0; i < assets.length; ++i) {
            address asset = assets[i];
            _keyIndex[tokenId][asset] = cohortIndex[asset][cohortId];
        }
        emit KeyEnrolled(tokenId, cohortId);
    }

    /// @notice Distributes `amount` across the cohort's current members by advancing one index.
    /// @dev The full amount is reserved here, never at withdrawal. The tokens must already sit in
    /// this contract. The sub-unit remainder of the division stays behind as retained dust and is
    /// still counted as backed, so the reserve is never optimistic.
    function allocateToCohort(address asset, uint256 cohortId, uint256 amount) external onlyFleet {
        if (!isRewardAsset(asset)) revert UnknownAsset();
        if (cohortId >= MAX_COHORTS) revert CohortOutOfBounds();
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

    /// @notice Credits one address directly, outside any cohort index.
    function credit(address asset, address account, uint256 amount) external onlyFleet {
        if (!isRewardAsset(asset)) revert UnknownAsset();
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 reserved = backed[asset] + amount;
        if (IERC20(asset).balanceOf(address(this)) < reserved) revert InsufficientBacking();
        credits[asset][account] += amount;
        backed[asset] = reserved;
        emit Credited(asset, account, amount);
    }

    /// @notice Converts a key's index accruals into pull credits for `owner`, for every income
    /// token. The fleet calls this before every ownership change so the outgoing owner keeps what
    /// the key earned under them.
    function settleKey(uint256 tokenId, address owner) external onlyFleet {
        if (owner == address(0)) revert ZeroAddress();
        uint256 cohortId = _cohortOf(tokenId);
        address[] memory assets = rewardAssets();
        for (uint256 i = 0; i < assets.length; ++i) {
            _settle(tokenId, assets[i], cohortId, owner);
        }
    }

    /// @notice Whole units a key has accrued for one asset and not yet had settled.
    function accrued(address asset, uint256 tokenId) external view returns (uint256) {
        if (!isRewardAsset(asset)) revert UnknownAsset();
        uint256 cohortId = _cohortOf(tokenId);
        return (cohortIndex[asset][cohortId] - _keyIndex[tokenId][asset]) / PRECISION;
    }

    /// @notice What `claim` would pay `account` for `asset` after settling `tokenIds`.
    /// @dev Agrees with `claim` for distinct token ids: it rejects unknown assets, keys the account does
    /// not own and unenrolled keys exactly as `claim` does, and returns zero where `claim` reverts with
    /// `NothingToClaim`. A repeated id is counted again here but settles once in `claim`, so callers
    /// pass each id at most once.
    function claimable(address asset, address account, uint256[] calldata tokenIds) external view returns (uint256) {
        if (!isRewardAsset(asset)) revert UnknownAsset();
        uint256 total = credits[asset][account];
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (IERC721(FLEET).ownerOf(tokenId) != account) revert NotKeyOwner();
            uint256 cohortId = _cohortOf(tokenId);
            total += (cohortIndex[asset][cohortId] - _keyIndex[tokenId][asset]) / PRECISION;
        }
        return total;
    }

    /// @notice Settles `tokenIds` for one asset and pays the caller's whole credit balance.
    /// @dev One asset and one outgoing transfer per call, so a token that reverts on transfer can
    /// only block itself. `to` of zero pays the caller.
    function claim(address asset, uint256[] calldata tokenIds, address to)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (!isRewardAsset(asset)) revert UnknownAsset();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (IERC721(FLEET).ownerOf(tokenId) != msg.sender) revert NotKeyOwner();
            _settle(tokenId, asset, _cohortOf(tokenId), msg.sender);
        }
        paid = credits[asset][msg.sender];
        if (paid == 0) revert NothingToClaim();
        credits[asset][msg.sender] = 0;
        backed[asset] -= paid;
        address recipient = to == address(0) ? msg.sender : to;
        emit Claimed(asset, msg.sender, recipient, paid);
        IERC20(asset).safeTransfer(recipient, paid);
    }

    function _cohortOf(uint256 tokenId) private view returns (uint256) {
        uint256 cohortIdPlusOne = _keyCohortPlusOne[tokenId];
        if (cohortIdPlusOne == 0) revert KeyNotEnrolled();
        return cohortIdPlusOne - 1;
    }

    /// @dev Advances the key's watermark by exactly the whole units credited, carrying the
    /// sub-unit remainder into the next settlement. Total dust per key and asset therefore stays
    /// below one atomic unit for the lifetime of the key instead of growing per settlement.
    function _settle(uint256 tokenId, address asset, uint256 cohortId, address owner) private {
        uint256 snapshot = _keyIndex[tokenId][asset];
        uint256 amount = (cohortIndex[asset][cohortId] - snapshot) / PRECISION;
        if (amount == 0) return;
        _keyIndex[tokenId][asset] = snapshot + amount * PRECISION;
        credits[asset][owner] += amount;
        emit Settled(tokenId, asset, owner, amount);
    }
}
