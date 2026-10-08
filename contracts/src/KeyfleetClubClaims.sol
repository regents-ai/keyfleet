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
/// holds Pass N when it claims, with no deadline. Rewards a held key earns while it waits are paid
/// out with it: the claim first collects the key's rewards here, then moves the key, then sends the
/// claimer exactly what was collected. Nobody votes or presents a held key. There is no
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

    /// @notice The holder of Pass `passId` claimed its key and the rewards it earned while held.
    /// @param paid What was paid out with the key, in the order of `assets`.
    event KeyClaimed(
        uint256 indexed passId, uint256 indexed tokenId, address indexed holder, address[] assets, uint256[] paid
    );

    constructor(KeyfleetKeys keys, IERC721 pass) {
        KEYS = keys;
        PASS = pass;
    }

    /// @notice Gives the caller key `passId` of the Regents Club, with what it earned while held
    /// here, when the caller holds Pass `passId`.
    /// @return assets The assets the key's rewards were checked in; ETH is `address(0)`.
    /// @return paid What was paid out in each.
    function claim(uint256 passId) external nonReentrant returns (address[] memory assets, uint256[] memory paid) {
        if (PASS.ownerOf(passId) != msg.sender) revert NotPassHolder(passId, msg.sender);
        uint256 tokenId = KEYS.tokenIdOf(CLUB_FLEET, passId);
        KeyfleetRewards rewards = _rewards();
        assets = rewards.rewardAssets();
        paid = new uint256[](assets.length);
        if (_hasAccrued(rewards, assets, tokenId)) {
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = tokenId;
            paid = rewards.claim(tokenIds, assets);
        }

        KEYS.safeTransferFrom(address(this), msg.sender, tokenId);
        for (uint256 i = 0; i < assets.length; ++i) {
            uint256 amount = paid[i];
            if (amount == 0) continue;
            if (assets[i] == address(0)) Address.sendValue(payable(msg.sender), amount);
            else IERC20(assets[i]).safeTransfer(msg.sender, amount);
        }
        emit KeyClaimed(passId, tokenId, msg.sender, assets, paid);
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

    function _hasAccrued(KeyfleetRewards rewards, address[] memory assets, uint256 tokenId)
        private
        view
        returns (bool)
    {
        for (uint256 i = 0; i < assets.length; ++i) {
            if (rewards.accrued(assets[i], tokenId) != 0) return true;
        }
        return false;
    }
}
