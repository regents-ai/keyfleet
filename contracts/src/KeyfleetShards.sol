// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Keyfleet} from "./Keyfleet.sol";

/// @notice The shards of one fleet's keys: time-limited grants a key's owner gives to wallets.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// A key's owner issues a shard to a wallet for 1 to 365 days, one transaction per shard. A shard
/// is active while it has not been ended, its time has not run out, and the key's
/// `ownershipEpoch` is still the one it was issued under, so every shard of a key ends the moment
/// the key changes hands and the new owner issues their own. The owner may end a shard early, and
/// the shard's wallet may step down.
///
/// A wallet holds at most one active shard in a fleet, under whichever key issued it, so a wallet
/// answers for exactly one key at a time. A key may have any number of shards.
///
/// A shard is a record, not a token: it cannot be moved, sold or approved. It carries no vote, no
/// money and no authority on chain; what a shard's wallet may do is decided off chain from this
/// record. There is no administrator, no upgrade path and no pause.
contract KeyfleetShards {
    /// @notice One wallet's latest shard in this fleet.
    /// @param tokenId The key that issued it.
    /// @param expiresAt The time it stops being active, in seconds.
    /// @param epoch The key's `ownershipEpoch` when it was issued.
    /// @param ended Whether the key's owner or the wallet ended it early.
    struct Shard {
        uint256 tokenId;
        uint64 expiresAt;
        uint64 epoch;
        bool ended;
    }

    /// @notice The fewest days a shard may be issued for.
    uint16 public constant MIN_DAYS = 1;
    /// @notice The most days a shard may be issued for.
    uint16 public constant MAX_DAYS = 365;

    /// @notice The fleet whose keys issue shards here.
    Keyfleet public immutable FLEET;

    mapping(address wallet => Shard shard) private _shards;

    /// @notice The fleet address supplied at construction was zero.
    error ZeroAddress();
    /// @notice Only the key's current owner may issue its shards.
    error NotKeyOwner(uint256 tokenId, address owner);
    /// @notice A shard lasts 1 to 365 days.
    error DaysOutOfRange(uint16 days_);
    /// @notice A key's owner cannot issue a shard of it to themselves.
    error WalletIsOwner(address wallet);
    /// @notice The wallet already holds an active shard in this fleet.
    error ShardAlreadyActive(address wallet, uint256 tokenId);
    /// @notice The wallet holds no active shard of this key.
    error ShardNotActive(uint256 tokenId, address wallet);
    /// @notice Only the key's current owner or the shard's wallet may end a shard.
    error NotAllowedToEnd(uint256 tokenId, address wallet, address caller);

    /// @notice A key's owner issued a shard to a wallet.
    /// @param expiresAt The time it stops being active, in seconds.
    /// @param epoch The key's `ownershipEpoch` it lasts for.
    event ShardIssued(uint256 indexed tokenId, address indexed wallet, uint64 expiresAt, uint64 epoch);

    /// @notice A shard was ended early.
    /// @param by The key's owner or the wallet itself.
    event ShardEnded(uint256 indexed tokenId, address indexed wallet, address indexed by);

    /// @notice Binds this record to the fleet that deploys it.
    /// @param fleet The fleet whose keys issue shards here.
    constructor(Keyfleet fleet) {
        if (address(fleet) == address(0)) revert ZeroAddress();
        FLEET = fleet;
    }

    /// @notice A wallet's latest shard in this fleet and whether it is active now.
    /// @dev All zero for a wallet that has never held one. An ended, expired or superseded shard is
    /// returned with `active` false until the wallet is issued another.
    /// @return tokenId The key that issued it.
    /// @return expiresAt The time it stops being active, in seconds.
    /// @return epoch The key's `ownershipEpoch` when it was issued.
    /// @return active Whether it is active now.
    function shardOf(address wallet)
        external
        view
        returns (uint256 tokenId, uint64 expiresAt, uint64 epoch, bool active)
    {
        Shard storage shard = _shards[wallet];
        return (shard.tokenId, shard.expiresAt, shard.epoch, _active(shard));
    }

    /// @notice Issues a shard of a key to a wallet for a number of days.
    /// @dev Only the key's current owner may call. The wallet may not be zero or the owner, and may
    /// not already hold an active shard in this fleet under any key. The shard replaces whatever
    /// inactive shard the wallet held before.
    /// @param tokenId The key.
    /// @param wallet The wallet that receives the shard.
    /// @param days_ How long it lasts, 1 to 365 days.
    function issue(uint256 tokenId, address wallet, uint16 days_) external {
        address owner = FLEET.ownerOf(tokenId);
        if (msg.sender != owner) revert NotKeyOwner(tokenId, owner);
        if (days_ < MIN_DAYS || days_ > MAX_DAYS) revert DaysOutOfRange(days_);
        if (wallet == address(0)) revert ZeroAddress();
        if (wallet == owner) revert WalletIsOwner(wallet);
        Shard storage current = _shards[wallet];
        if (_active(current)) revert ShardAlreadyActive(wallet, current.tokenId);

        uint64 expiresAt = uint64(block.timestamp + uint256(days_) * 1 days);
        uint64 epoch = FLEET.ownershipEpoch(tokenId);
        _shards[wallet] = Shard({tokenId: tokenId, expiresAt: expiresAt, epoch: epoch, ended: false});
        emit ShardIssued(tokenId, wallet, expiresAt, epoch);
    }

    /// @notice Ends a wallet's active shard of a key before its time runs out.
    /// @dev The key's current owner or the shard's wallet may call.
    /// @param tokenId The key.
    /// @param wallet The shard's wallet.
    function end(uint256 tokenId, address wallet) external {
        Shard storage shard = _shards[wallet];
        if (shard.tokenId != tokenId || !_active(shard)) revert ShardNotActive(tokenId, wallet);
        if (msg.sender != wallet && msg.sender != FLEET.ownerOf(tokenId)) {
            revert NotAllowedToEnd(tokenId, wallet, msg.sender);
        }

        shard.ended = true;
        emit ShardEnded(tokenId, wallet, msg.sender);
    }

    /// @dev Not ended, not expired, and issued under the key's current ownership. A wallet that
    /// never held a shard has token id zero, which is never a key.
    function _active(Shard storage shard) private view returns (bool) {
        return shard.tokenId != 0 && !shard.ended && block.timestamp < shard.expiresAt
            && FLEET.ownershipEpoch(shard.tokenId) == shard.epoch;
    }
}
