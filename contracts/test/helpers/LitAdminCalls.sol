// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";

/// @notice The administrative writes and reads of Lit's `AccountConfig` diamond on Base that a
/// fleet's treasury uses, with the signatures of Lit's `WritesFacet` and `ViewsFacet`
/// (LIT-Protocol/chipotle, `lit-api-server/blockchain/lit_node_express`).
interface ILitAccountConfig {
    function newChainSecuredAccount(string calldata accountName, string calldata accountDescription) external;
    function transferChainSecuredAccountOwnership(uint256 apiKeyHash, address newAdminWalletAddress) external;
    function addAction(uint256 accountApiKeyHash, string calldata name, string calldata description, uint256 actionHash)
        external;
    function addGroup(
        uint256 apiKeyHash,
        string calldata name,
        string calldata description,
        uint256[] calldata cidHashes,
        address[] calldata pkpIds
    ) external returns (uint256);
    function setUsageApiKey(
        uint256 accountApiKeyHash,
        uint256 usageApiKeyHash,
        uint256 expiration,
        uint256 balance,
        string calldata name,
        string calldata description,
        bool createGroups,
        bool deleteGroups,
        bool createPKPs,
        uint256[] calldata manageIPFSIdsInGroups,
        uint256[] calldata addPkpToGroups,
        uint256[] calldata removePkpFromGroups,
        uint256[] calldata executeInGroups
    ) external;
    function removeUsageApiKey(uint256 accountApiKeyHash, uint256 usageApiKeyHash) external;
    function getAccountWalletAddress(uint256 apiKeyHash) external view returns (address);
    function canExecuteAction(uint256 apiKeyHash, uint256 cidHash) external view returns (bool);
}

/// @dev The exact calls a proposal carries to set up and look after the fleet's Lit ChainSecured
/// account, owned by its treasury: create the account, register the inbox action, make one inbox
/// group with it, mint one execute-only usage key for the operator, then replace or revoke that
/// key, and transfer the account. Each call is sent by the treasury, so Lit sees the treasury as
/// the admin wallet. Also the EIP-712 digest Lit's server asks a ChainSecured owner to sign before
/// it makes a wallet, which the treasury answers for once a proposal approves it.
library LitAdminCalls {
    /// @notice Lit's EIP-712 domain for every ChainSecured message: name and version only, no
    /// verifying contract (Lit's `lit-api-server/src/core/eip712.rs`).
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId)");
    /// @notice The message Lit's server checks before it makes a wallet for an account.
    bytes32 internal constant CREATE_WALLET_TYPEHASH = keccak256("CreateWallet(address address,uint256 issuedAt)");
    /// @notice The inbox group of a new account: Lit numbers an account's groups from 1.
    uint256 internal constant INBOX_GROUP = 1;

    /// @notice The account's id in Lit: `keccak256` of the admin wallet that created it.
    function accountHash(address treasury) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(treasury)));
    }

    function createAccount(ILitAccountConfig config) internal pure returns (KeyfleetTreasury.Call memory) {
        return _call(
            config, abi.encodeCall(ILitAccountConfig.newChainSecuredAccount, ("Keyfleet Alpha", "The fleet's inbox"))
        );
    }

    function addInboxAction(ILitAccountConfig config, address treasury, uint256 actionHash)
        internal
        pure
        returns (KeyfleetTreasury.Call memory)
    {
        return _call(
            config,
            abi.encodeCall(
                ILitAccountConfig.addAction, (accountHash(treasury), "inbox", "Sends approved messages", actionHash)
            )
        );
    }

    function addInboxGroup(ILitAccountConfig config, address treasury, uint256 actionHash)
        internal
        pure
        returns (KeyfleetTreasury.Call memory)
    {
        uint256[] memory actions = new uint256[](1);
        actions[0] = actionHash;
        return _call(
            config,
            abi.encodeCall(
                ILitAccountConfig.addGroup,
                (accountHash(treasury), "inbox", "The inbox action", actions, new address[](0))
            )
        );
    }

    /// @notice A usage key that may run the inbox group's actions and nothing else: it can make,
    /// delete or change no group, wallet or action, and never expires until it is removed.
    function mintExecuteOnlyKey(ILitAccountConfig config, address treasury, uint256 usageKeyHash)
        internal
        pure
        returns (KeyfleetTreasury.Call memory)
    {
        uint256[] memory none = new uint256[](0);
        uint256[] memory inbox = new uint256[](1);
        inbox[0] = INBOX_GROUP;
        return _call(
            config,
            abi.encodeCall(
                ILitAccountConfig.setUsageApiKey,
                (
                    accountHash(treasury),
                    usageKeyHash,
                    0,
                    0,
                    "operator",
                    "Runs the inbox action",
                    false,
                    false,
                    false,
                    none,
                    none,
                    none,
                    inbox
                )
            )
        );
    }

    function removeKey(ILitAccountConfig config, address treasury, uint256 usageKeyHash)
        internal
        pure
        returns (KeyfleetTreasury.Call memory)
    {
        return _call(config, abi.encodeCall(ILitAccountConfig.removeUsageApiKey, (accountHash(treasury), usageKeyHash)));
    }

    function transferAccount(ILitAccountConfig config, address treasury, address newAdmin)
        internal
        pure
        returns (KeyfleetTreasury.Call memory)
    {
        return _call(
            config,
            abi.encodeCall(ILitAccountConfig.transferChainSecuredAccountOwnership, (accountHash(treasury), newAdmin))
        );
    }

    /// @notice The digest of Lit's `CreateWallet` message for `owner` at `issuedAt`, on `chainId`.
    /// Lit's server accepts it only within 300 seconds either side of `issuedAt`.
    function createWalletDigest(address owner, uint256 issuedAt, uint256 chainId) internal pure returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Lit ChainSecured"), keccak256("1"), chainId));
        bytes32 message = keccak256(abi.encode(CREATE_WALLET_TYPEHASH, owner, issuedAt));
        return keccak256(abi.encodePacked("\x19\x01", domain, message));
    }

    function _call(ILitAccountConfig config, bytes memory data) private pure returns (KeyfleetTreasury.Call memory) {
        return KeyfleetTreasury.Call(address(config), 0, data);
    }
}
