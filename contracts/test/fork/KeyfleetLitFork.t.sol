// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {ILitAccountConfig, LitAdminCalls} from "../helpers/LitAdminCalls.sol";
import {KeyfleetForkFixture} from "./KeyfleetBaseFork.t.sol";

/// @notice The listing views of Lit's AccountConfig this test reads (Lit's `ViewsFacet`).
interface ILitAccountViews {
    struct Metadata {
        uint256 id;
        string name;
        string description;
    }

    function listGroups(uint256 accountApiKeyHash, uint256 pageNumber, uint256 pageSize)
        external
        view
        returns (Metadata[] memory);
    function listActions(uint256 accountApiKeyHash, uint256 pageNumber, uint256 pageSize)
        external
        view
        returns (Metadata[] memory);
}

/// @dev Lit's own errors (Lit's `AppStorage`), for matching its refusals exactly.
interface ILitErrors {
    error AccountDoesNotExist(uint256 apiKeyHash);
    error NoAccountAccess(uint256 apiKeyHash, address sender);
}

/// @dev A fleet treasury's admin writes against Lit's real AccountConfig diamond on a fork of Base,
/// by Classic #1 of the system deployed from the committed Base manifest. It runs only when
/// `BASE_RPC_URL` is set in the environment, and skips itself otherwise; the URL is never printed.
/// Every write is a call an approved proposal carries, sent by the treasury, and Lit's real access
/// rules decide it: the treasury creates the fleet's ChainSecured account and is its admin wallet,
/// sets up the inbox action, group and operator key, replaces the key, and hands the account on,
/// after which Lit refuses it. Lit's server-side checks (the signed `CreateWallet` request, its
/// five-minute window and its one-use rule) cannot run here.
contract KeyfleetLitForkTest is KeyfleetForkFixture {
    /// @dev Lit's AccountConfig on Base. Lit's node configuration
    /// (`https://api.chipotle.litprotocol.com/core/v1/get_node_chain_config`) names it, with chain
    /// 8453; this test also checks there is code at it.
    ILitAccountConfig private constant LIT = ILitAccountConfig(0xaAaAA9120fE271F653cfDb6bf400dB93D2DEa7Aa);
    address private constant BUYER = address(0xB0B0B0);
    address private constant MALLORY = address(0x4A11);
    uint256 private constant INBOX_ACTION = uint256(keccak256("ipfs://inbox-action"));
    uint256 private constant OPERATOR_KEY = uint256(keccak256("lk_operator-one"));
    uint256 private constant NEXT_OPERATOR_KEY = uint256(keccak256("lk_operator-two"));

    KeyfleetManager private classic;
    KeyfleetTreasury private treasury;
    KeyfleetVotes private votes;
    uint256 private account;

    function setUp() public {
        if (!_setUpFork(0)) return;
        _found(1);
        _advancePhase();
        classic = _fleet(1);
        treasury = classic.TREASURY();
        votes = classic.VOTES();
        account = LitAdminCalls.accountHash(address(treasury));
        _buy(classic, BUYER);
    }

    function test_litsAccountConfigIsLiveOnBase() public view {
        assertEq(block.chainid, 8453, "a fork of Base");
        assertGt(address(LIT).code.length, 0, "Lit's AccountConfig is deployed");
    }

    function test_theTreasuryRunsItsLitAccountThroughProposals() public {
        _execute(classic, _setUpAccount());

        assertEq(LIT.getAccountWalletAddress(account), address(treasury), "Lit sees the treasury as the admin");
        ILitAccountViews.Metadata[] memory groups = ILitAccountViews(address(LIT)).listGroups(account, 0, 10);
        assertEq(groups.length, 1, "one group");
        assertEq(groups[0].id, LitAdminCalls.INBOX_GROUP, "numbered 1, as the key's calls assume");
        ILitAccountViews.Metadata[] memory actions = ILitAccountViews(address(LIT)).listActions(account, 0, 10);
        assertEq(actions.length, 1, "one action");
        assertEq(actions[0].id, INBOX_ACTION);
        assertTrue(LIT.canExecuteAction(OPERATOR_KEY, INBOX_ACTION), "the operator runs the inbox action");
        assertFalse(LIT.canExecuteAction(OPERATOR_KEY, uint256(keccak256("ipfs://other"))), "and nothing else");

        // Nobody else writes to it: Lit refuses a write that is not the treasury's.
        vm.prank(MALLORY);
        (bool ok, bytes memory reason) = address(LIT)
            .call(LitAdminCalls.mintExecuteOnlyKey(LIT, address(treasury), uint256(keccak256("lk_mallory"))).data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(ILitErrors.NoAccountAccess.selector, account, MALLORY));

        // Replacing the operator's key.
        KeyfleetTreasury.Call[] memory replace = new KeyfleetTreasury.Call[](2);
        replace[0] = LitAdminCalls.removeKey(LIT, address(treasury), OPERATOR_KEY);
        replace[1] = LitAdminCalls.mintExecuteOnlyKey(LIT, address(treasury), NEXT_OPERATOR_KEY);
        _execute(classic, replace);
        vm.expectRevert(abi.encodeWithSelector(ILitErrors.AccountDoesNotExist.selector, OPERATOR_KEY));
        LIT.canExecuteAction(OPERATOR_KEY, INBOX_ACTION);
        assertTrue(LIT.canExecuteAction(NEXT_OPERATOR_KEY, INBOX_ACTION));

        // Handing the account on: after that, Lit refuses even an approved proposal's write.
        address safe = address(0x5AFE);
        _execute(classic, _one(LitAdminCalls.transferAccount(LIT, address(treasury), safe)));
        assertEq(LIT.getAccountWalletAddress(account), safe);
        KeyfleetTreasury.Call[] memory late = _one(LitAdminCalls.removeKey(LIT, address(treasury), NEXT_OPERATOR_KEY));
        uint256 proposalId = _approve(classic, late);
        vm.warp(votes.proposal(proposalId).closesAt);
        vm.expectRevert(abi.encodeWithSelector(ILitErrors.NoAccountAccess.selector, account, address(treasury)));
        votes.execute(proposalId, late);
        assertTrue(LIT.canExecuteAction(NEXT_OPERATOR_KEY, INBOX_ACTION), "the key stands");
    }

    /// @dev The treasury answers Lit's `CreateWallet` request for itself once a proposal approves
    /// its digest, on Base's chain id. Lit's server takes it only within 300 seconds of `issuedAt`,
    /// once, so a real proposal sets `issuedAt` to when it will be carried out.
    function test_theTreasuryAnswersAnApprovedCreateWalletRequest() public {
        _execute(classic, _setUpAccount());
        uint256 issuedAt = block.timestamp + 1;
        bytes32 digest = LitAdminCalls.createWalletDigest(address(treasury), issuedAt, block.chainid);
        assertEq(treasury.isValidSignature(digest, ""), bytes4(0xffffffff), "nothing signed by itself");

        _execute(
            classic,
            _one(KeyfleetTreasury.Call(address(treasury), 0, abi.encodeCall(treasury.approveSignatureHash, (digest))))
        );
        assertEq(treasury.isValidSignature(digest, ""), IERC1271.isValidSignature.selector);
        assertTrue(SignatureChecker.isValidERC1271SignatureNow(address(treasury), digest, ""));
    }

    /// @dev The four calls that set up the fleet's Lit account.
    function _setUpAccount() private view returns (KeyfleetTreasury.Call[] memory calls) {
        calls = new KeyfleetTreasury.Call[](4);
        calls[0] = LitAdminCalls.createAccount(LIT);
        calls[1] = LitAdminCalls.addInboxAction(LIT, address(treasury), INBOX_ACTION);
        calls[2] = LitAdminCalls.addInboxGroup(LIT, address(treasury), INBOX_ACTION);
        calls[3] = LitAdminCalls.mintExecuteOnlyKey(LIT, address(treasury), OPERATOR_KEY);
    }
}
