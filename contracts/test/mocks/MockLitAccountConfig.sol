// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILitAccountConfig} from "../helpers/LitAdminCalls.sol";

/// @dev A stand-in for Lit's `AccountConfig` holding just what the treasury's tests read: one
/// ChainSecured account per admin wallet, its actions, its groups and its execute-only usage keys.
/// It keeps Lit's one rule that matters here: every write to an account comes from that account's
/// admin wallet, or reverts with Lit's `NoAccountAccess`.
contract MockLitAccountConfig {
    struct UsageKey {
        bool exists;
        uint256[] executeInGroups;
    }

    mapping(uint256 apiKeyHash => address admin) public adminOf;
    mapping(uint256 apiKeyHash => uint256 groups) public groupCount;
    mapping(uint256 apiKeyHash => mapping(uint256 groupId => mapping(uint256 actionHash => bool))) public
        groupHasAction;
    mapping(uint256 apiKeyHash => mapping(uint256 actionHash => bool)) public hasAction;
    mapping(uint256 usageApiKeyHash => uint256 apiKeyHash) public usageKeyAccount;
    mapping(uint256 usageApiKeyHash => UsageKey) private _usageKeys;

    error AccountAlreadyExists(uint256 apiKeyHash);
    error AccountDoesNotExist(uint256 apiKeyHash);
    error NoAccountAccess(uint256 apiKeyHash, address sender);

    function newChainSecuredAccount(string calldata, string calldata) external {
        uint256 apiKeyHash = uint256(keccak256(abi.encodePacked(msg.sender)));
        if (adminOf[apiKeyHash] != address(0)) revert AccountAlreadyExists(apiKeyHash);
        adminOf[apiKeyHash] = msg.sender;
    }

    function transferChainSecuredAccountOwnership(uint256 apiKeyHash, address newAdminWalletAddress) external {
        _requireAdmin(apiKeyHash);
        adminOf[apiKeyHash] = newAdminWalletAddress;
    }

    function addAction(uint256 accountApiKeyHash, string calldata, string calldata, uint256 actionHash) external {
        _requireAdmin(accountApiKeyHash);
        hasAction[accountApiKeyHash][actionHash] = true;
    }

    function addGroup(
        uint256 apiKeyHash,
        string calldata,
        string calldata,
        uint256[] calldata cidHashes,
        address[] calldata
    ) external returns (uint256 groupId) {
        _requireAdmin(apiKeyHash);
        groupId = ++groupCount[apiKeyHash];
        for (uint256 i = 0; i < cidHashes.length; ++i) {
            groupHasAction[apiKeyHash][groupId][cidHashes[i]] = true;
        }
    }

    /// @dev Lit's `setUsageApiKey` takes thirteen arguments, more than the plain compiler can decode,
    /// so the mock answers it here and reads the three it keeps straight from the call data: the
    /// account, the usage key and the groups the key may execute in (the thirteenth argument).
    fallback() external {
        if (msg.sig != ILitAccountConfig.setUsageApiKey.selector) revert();
        (uint256 accountApiKeyHash, uint256 usageApiKeyHash) = abi.decode(msg.data[4:68], (uint256, uint256));
        _requireAdmin(accountApiKeyHash);
        uint256 at = 4 + _word(4 + 12 * 32);
        uint256[] memory executeInGroups = new uint256[](_word(at));
        for (uint256 i = 0; i < executeInGroups.length; ++i) {
            executeInGroups[i] = _word(at + 32 * (i + 1));
        }
        usageKeyAccount[usageApiKeyHash] = accountApiKeyHash;
        _usageKeys[usageApiKeyHash] = UsageKey({exists: true, executeInGroups: executeInGroups});
    }

    function removeUsageApiKey(uint256 accountApiKeyHash, uint256 usageApiKeyHash) external {
        _requireAdmin(accountApiKeyHash);
        delete usageKeyAccount[usageApiKeyHash];
        delete _usageKeys[usageApiKeyHash];
    }

    function getAccountWalletAddress(uint256 apiKeyHash) external view returns (address admin) {
        admin = adminOf[apiKeyHash];
        if (admin == address(0)) revert AccountDoesNotExist(apiKeyHash);
    }

    /// @dev Whether a usage key may run an action: one of the groups it may execute in holds it.
    function canExecuteAction(uint256 apiKeyHash, uint256 cidHash) external view returns (bool) {
        UsageKey storage key = _usageKeys[apiKeyHash];
        if (!key.exists) revert AccountDoesNotExist(apiKeyHash);
        uint256 account = usageKeyAccount[apiKeyHash];
        for (uint256 i = 0; i < key.executeInGroups.length; ++i) {
            if (groupHasAction[account][key.executeInGroups[i]][cidHash]) return true;
        }
        return false;
    }

    function _word(uint256 at) private pure returns (uint256) {
        return uint256(bytes32(msg.data[at:at + 32]));
    }

    function _requireAdmin(uint256 apiKeyHash) private view {
        if (adminOf[apiKeyHash] != msg.sender) revert NoAccountAccess(apiKeyHash, msg.sender);
    }
}
