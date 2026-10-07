// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Keyfleet} from "./Keyfleet.sol";

/// @notice The shards of one fleet's keys: time-limited grants a key's owner gives to agent
/// wallets, and each key's agent voting switch.
/// @dev One instance is permanently bound to one fleet, which deploys it in its own constructor.
/// A key's owner issues shards of any number of their keys to a wallet in one call, for 1 to 365
/// days. A shard is active while it has not been ended, its time has not run out, and the key's
/// `ownershipEpoch` is still the one it was issued under, so every shard of a key ends the moment
/// the key changes hands and the new owner issues their own. The owner may end shards early, and
/// the shard's wallet may step down.
///
/// Shards are kept per key and wallet, so one wallet may hold active shards of many keys at once
/// and a key may have shards in many wallets. The owner renews a shard by issuing it again, which
/// replaces its time.
///
/// An active shard lets its wallet work in the key's workspace (decided off chain from this record)
/// and mark the key present in the fleet's `KeyfleetVotes`. It also lets the wallet vote the key and
/// propose with it while the key's agent voting is on, which it is for every key unless its owner
/// turned it off with `setAgentVoting`; a new owner always starts with it on. A shard is a record,
/// not a token: it cannot be moved, sold or approved, and it carries no money. There is no
/// administrator, no upgrade path and no pause.
contract KeyfleetShards {
    /// @notice One wallet's latest shard of one key.
    /// @param expiresAt The time it stops being active, in seconds.
    /// @param epoch The key's `ownershipEpoch` when it was issued.
    /// @param ended Whether the key's owner or the wallet ended it early.
    struct Shard {
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

    /// @notice Raised every time who may act for a key changes: a shard issued, renewed or ended,
    /// or its agent voting turned on or off. Signed messages carry it, so any such change voids
    /// every earlier signature for the key.
    mapping(uint256 tokenId => uint64 revision) public delegationRevision;

    mapping(uint256 tokenId => mapping(address wallet => Shard shard)) private _shards;
    /// @dev The ownership epoch in which the key's owner turned agent voting off. It is off exactly
    /// while this equals the key's current epoch, so a change of hands turns it back on.
    mapping(uint256 tokenId => uint64 epoch) private _agentVotingOffIn;

    /// @notice The fleet address supplied at construction was zero.
    error ZeroAddress();
    /// @notice A call named no keys.
    error NoKeys();
    /// @notice Only the key's current owner may do this.
    error NotKeyOwner(uint256 tokenId, address owner);
    /// @notice A shard lasts 1 to 365 days.
    error DaysOutOfRange(uint16 days_);
    /// @notice A key's owner cannot issue a shard of it to themselves.
    error WalletIsOwner(address wallet);
    /// @notice The wallet holds no active shard of this key.
    error ShardNotActive(uint256 tokenId, address wallet);
    /// @notice Only the key's current owner or the shard's wallet may end a shard.
    error NotAllowedToEnd(uint256 tokenId, address wallet, address caller);

    /// @notice A key's owner issued or renewed a shard of the key to a wallet.
    /// @param expiresAt The time it stops being active, in seconds.
    /// @param epoch The key's `ownershipEpoch` it lasts for.
    event ShardIssued(uint256 indexed tokenId, address indexed wallet, uint64 expiresAt, uint64 epoch);

    /// @notice A shard was ended early.
    /// @param by The key's owner or the wallet itself.
    event ShardEnded(uint256 indexed tokenId, address indexed wallet, address indexed by);

    /// @notice A key's owner turned the key's agent voting on or off.
    /// @param epoch The key's `ownershipEpoch` the setting belongs to.
    event AgentVotingSet(uint256 indexed tokenId, bool on, uint64 epoch);

    /// @notice Binds this record to the fleet that deploys it.
    /// @param fleet The fleet whose keys issue shards here.
    constructor(Keyfleet fleet) {
        if (address(fleet) == address(0)) revert ZeroAddress();
        FLEET = fleet;
    }

    /// @notice A wallet's latest shard of a key and whether it is active now.
    /// @dev All zero for a wallet that has never held a shard of the key. An ended, expired or
    /// superseded shard is returned with `active` false until the wallet is issued another.
    /// @return expiresAt The time it stops being active, in seconds.
    /// @return epoch The key's `ownershipEpoch` when it was issued.
    /// @return active Whether it is active now.
    function shardOf(uint256 tokenId, address wallet)
        external
        view
        returns (uint64 expiresAt, uint64 epoch, bool active)
    {
        Shard storage shard = _shards[tokenId][wallet];
        return (shard.expiresAt, shard.epoch, _active(tokenId, shard));
    }

    /// @notice Whether a wallet holds an active shard of a key.
    function isActive(uint256 tokenId, address wallet) public view returns (bool) {
        return _active(tokenId, _shards[tokenId][wallet]);
    }

    /// @notice Whether the key's shards may vote it and propose with it. On for every key unless its
    /// current owner turned it off.
    function agentVoting(uint256 tokenId) public view returns (bool) {
        return _agentVotingOffIn[tokenId] != FLEET.ownershipEpoch(tokenId);
    }

    /// @notice Whether a wallet may vote a key and propose with it as the key's agent: it holds an
    /// active shard of the key and the key's agent voting is on.
    function mayGovern(uint256 tokenId, address wallet) external view returns (bool) {
        return isActive(tokenId, wallet) && agentVoting(tokenId);
    }

    /// @notice Issues shards of keys to a wallet for a number of days, or renews them from now.
    /// @dev The caller must own every key named. The wallet may not be zero or the owner. A shard
    /// replaces whatever the wallet held of that key before.
    /// @param tokenIds The keys.
    /// @param wallet The wallet that receives the shards.
    /// @param days_ How long they last, 1 to 365 days.
    function issue(uint256[] calldata tokenIds, address wallet, uint16 days_) external {
        if (tokenIds.length == 0) revert NoKeys();
        if (days_ < MIN_DAYS || days_ > MAX_DAYS) revert DaysOutOfRange(days_);
        if (wallet == address(0)) revert ZeroAddress();
        if (wallet == msg.sender) revert WalletIsOwner(wallet);
        uint64 expiresAt = uint64(block.timestamp + uint256(days_) * 1 days);
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireOwner(tokenId);
            uint64 epoch = FLEET.ownershipEpoch(tokenId);
            _shards[tokenId][wallet] = Shard({expiresAt: expiresAt, epoch: epoch, ended: false});
            ++delegationRevision[tokenId];
            emit ShardIssued(tokenId, wallet, expiresAt, epoch);
        }
    }

    /// @notice Ends a wallet's active shards of keys before their time runs out.
    /// @dev For each key, the key's current owner or the shard's wallet may call.
    /// @param tokenIds The keys.
    /// @param wallet The shards' wallet.
    function end(uint256[] calldata tokenIds, address wallet) external {
        if (tokenIds.length == 0) revert NoKeys();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            Shard storage shard = _shards[tokenId][wallet];
            if (!_active(tokenId, shard)) revert ShardNotActive(tokenId, wallet);
            if (msg.sender != wallet && msg.sender != FLEET.ownerOf(tokenId)) {
                revert NotAllowedToEnd(tokenId, wallet, msg.sender);
            }
            shard.ended = true;
            ++delegationRevision[tokenId];
            emit ShardEnded(tokenId, wallet, msg.sender);
        }
    }

    /// @notice Turns agent voting on or off for keys: whether their shards may vote them and
    /// propose with them. Marking a key present stays open to its shards either way.
    /// @dev The caller must own every key named. The setting lasts until the key changes hands,
    /// when it is on again for the new owner.
    /// @param tokenIds The keys.
    /// @param on Whether their shards may vote and propose.
    function setAgentVoting(uint256[] calldata tokenIds, bool on) external {
        if (tokenIds.length == 0) revert NoKeys();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _requireOwner(tokenId);
            uint64 epoch = FLEET.ownershipEpoch(tokenId);
            _agentVotingOffIn[tokenId] = on ? 0 : epoch;
            ++delegationRevision[tokenId];
            emit AgentVotingSet(tokenId, on, epoch);
        }
    }

    function _requireOwner(uint256 tokenId) private view {
        address owner = FLEET.ownerOf(tokenId);
        if (msg.sender != owner) revert NotKeyOwner(tokenId, owner);
    }

    /// @dev Not ended, not expired, and issued under the key's current ownership. A shard never
    /// issued has epoch zero, which is never a key's epoch.
    function _active(uint256 tokenId, Shard storage shard) private view returns (bool) {
        return !shard.ended && block.timestamp < shard.expiresAt && FLEET.ownershipEpoch(tokenId) == shard.epoch;
    }
}
