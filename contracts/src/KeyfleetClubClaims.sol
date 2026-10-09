// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";

/// @notice Holds Regents Club keys for Passes whose holders cannot take one yet, such as a Pass
/// waiting in a contract that refuses NFTs, until whoever holds Pass N claims key N.
/// @dev Deployed by the factory with the collection, bound to the collection and the Pass for ever.
/// It accepts only Regents Club keys as they are minted, and gives key N only to the wallet that
/// holds Pass N when it claims, with no deadline; one claim takes the keys of every Pass named.
/// Rewards a held key earns while it waits are paid out with it: the claim first collects the keys'
/// rewards here, then moves the keys, then sends the claimer exactly what was collected. Nobody votes or presents a held key. There is no
/// administrator, no upgrade path and no other way out.
contract KeyfleetClubClaims is IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The Regents Club's fleet number: the fifth founding fleet.
    uint256 public constant CLUB_FLEET = 5;

    /// @notice The one Keyfleet collection.
    KeyfleetKeys public immutable KEYS;
    /// @notice The Regents Club Pass collection.
    IERC721 public immutable PASS;

    /// @notice Only Regents Club keys, as they are minted, may arrive here.
    error OnlyClubMints();
    /// @notice The caller does not hold the Pass of that number.
    error NotPassHolder(uint256 passId, address caller);
    /// @notice ETH arrives here only from the Regents Club's reward ledger.
    error OnlyRewards(address sender);

    /// @notice The holder of Passes `passIds` claimed their keys and what they earned while held.
    /// @param paid What was paid out with the keys, in the order of `assets`.
    event KeysClaimed(address indexed holder, uint256[] passIds, address[] assets, uint256[] paid);

    constructor(KeyfleetKeys keys, IERC721 pass) {
        KEYS = keys;
        PASS = pass;
    }

    /// @notice Gives the caller key N of the Regents Club for each Pass N in `passIds` the caller
    /// holds, with what those keys earned while held here, in one transaction.
    /// @dev Reverts whole when the caller does not hold one of the Passes, or one of the keys is
    /// no longer here.
    /// @return assets The assets the keys' rewards were checked in; ETH is `address(0)`.
    /// @return paid What was paid out in each.
    function claim(uint256[] calldata passIds)
        external
        nonReentrant
        returns (address[] memory assets, uint256[] memory paid)
    {
        uint256[] memory tokenIds = new uint256[](passIds.length);
        for (uint256 i = 0; i < passIds.length; ++i) {
            uint256 passId = passIds[i];
            if (PASS.ownerOf(passId) != msg.sender) revert NotPassHolder(passId, msg.sender);
            tokenIds[i] = KEYS.tokenIdOf(CLUB_FLEET, passId);
        }
        KeyfleetRewards rewards = _rewards();
        assets = rewards.rewardAssets();
        paid = new uint256[](assets.length);
        if (_hasAccrued(rewards, assets, tokenIds)) paid = rewards.claim(tokenIds, assets);

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            KEYS.safeTransferFrom(address(this), msg.sender, tokenIds[i]);
        }
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 amount = paid[i];
            if (amount == 0) continue;
            if (assets[i] == address(0)) Address.sendValue(payable(msg.sender), amount);
            else IERC20(assets[i]).safeTransfer(msg.sender, amount);
        }
        emit KeysClaimed(msg.sender, passIds, assets, paid);
    }

    /// @notice Of `passIds`, the Passes `holder` holds whose keys are held here now: what `claim`
    /// takes for `holder` at this block. A Pass burned or never minted, and a key not given yet or
    /// already claimed, are left out.
    function claimable(address holder, uint256[] calldata passIds) external view returns (uint256[] memory ids) {
        bool[] memory takes = new bool[](passIds.length);
        uint256 count;
        for (uint256 i = 0; i < passIds.length; ++i) {
            if (_held(passIds[i]) && _holdsPass(holder, passIds[i])) {
                takes[i] = true;
                ++count;
            }
        }
        ids = new uint256[](count);
        count = 0;
        for (uint256 i = 0; i < passIds.length; ++i) {
            if (takes[i]) ids[count++] = passIds[i];
        }
    }

    /// @notice Accepts a Regents Club key as it is minted here.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(KEYS) || from != address(0) || KEYS.fleetOf(tokenId) != CLUB_FLEET) {
            revert OnlyClubMints();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice ETH a held key earned, paid here by the Regents Club's reward ledger during a claim.
    receive() external payable {
        if (msg.sender != address(_rewards())) revert OnlyRewards(msg.sender);
    }

    function _rewards() private view returns (KeyfleetRewards) {
        return KeyfleetManager(KEYS.managerOf(CLUB_FLEET)).REWARDS();
    }

    function _hasAccrued(KeyfleetRewards rewards, address[] memory assets, uint256[] memory tokenIds)
        private
        view
        returns (bool)
    {
        for (uint256 k = 0; k < tokenIds.length; ++k) {
            for (uint256 i = 0; i < assets.length; ++i) {
                if (rewards.accrued(assets[i], tokenIds[k]) != 0) return true;
            }
        }
        return false;
    }

    /// @dev Whether key `passId` of the Regents Club is held here; a key not minted yet is not.
    function _held(uint256 passId) private view returns (bool) {
        try KEYS.ownerOf(KEYS.tokenIdOf(CLUB_FLEET, passId)) returns (address owner) {
            return owner == address(this);
        } catch {
            return false;
        }
    }

    /// @dev Whether `holder` holds Pass `passId`; nobody holds one burned or never minted.
    function _holdsPass(address holder, uint256 passId) private view returns (bool) {
        try PASS.ownerOf(passId) returns (address owner) {
            return owner == holder;
        } catch {
            return false;
        }
    }
}
