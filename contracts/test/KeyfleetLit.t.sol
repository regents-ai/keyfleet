// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {ILitAccountConfig, LitAdminCalls} from "./helpers/LitAdminCalls.sol";
import {MockLitAccountConfig} from "./mocks/MockLitAccountConfig.sol";

/// @dev Plan §4.9, Lit: the treasury owns the fleet's Lit account. It answers ERC-1271 for exactly
/// the Lit requests an approved proposal approved, each under Lit's own domain, and every admin
/// write to Lit is a plain call an approved proposal carries. Nothing else in the fleet ever calls
/// Lit.
contract KeyfleetLitTest is KeyfleetFixture {
    /// @dev Lit's AccountConfig on Base (chain 8453), as Lit's own node configuration names it.
    address private constant LIT_ACCOUNT_CONFIG = 0xaAaAA9120fE271F653cfDb6bf400dB93D2DEa7Aa;
    bytes4 private constant NO = 0xffffffff;
    uint256 private constant INBOX_ACTION = uint256(keccak256("ipfs://inbox-action"));
    uint256 private constant OPERATOR_KEY = uint256(keccak256("lk_operator-one"));
    uint256 private constant NEXT_OPERATOR_KEY = uint256(keccak256("lk_operator-two"));

    address private mallory = address(0x4A11);

    event LitRequestApproved(bytes32 indexed structHash);
    event LitRequestRevoked(bytes32 indexed structHash);

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
    }

    /// @dev The founding Classic fleet with `count` keys sold, old enough to take part, after its
    /// treasury opening, by when only a renewed key is present.
    function _classic(uint256 count) private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, count);
        _mature();
        _openTreasury(fleet);
    }

    function _approveRequest(KeyfleetTreasury treasury, bytes32 structHash)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.approveLitRequest, (structHash)));
    }

    function _revokeRequest(KeyfleetTreasury treasury, bytes32 structHash)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.revokeLitRequest, (structHash)));
    }

    /// @dev The digest Lit checks for a request: its struct hash under Lit's domain on this chain.
    function _litDigest(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
                keccak256("Lit ChainSecured"),
                keccak256("1"),
                block.chainid
            )
        );
        return MessageHashUtils.toTypedDataHash(domain, structHash);
    }

    /// @dev The four calls that set up the fleet's Lit account: create it, register the inbox
    /// action, make the inbox group, and mint the operator's execute-only usage key.
    function _setUpAccount(ILitAccountConfig config, KeyfleetTreasury treasury)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory calls)
    {
        calls = new KeyfleetTreasury.Call[](4);
        calls[0] = LitAdminCalls.createAccount(config);
        calls[1] = LitAdminCalls.addInboxAction(config, address(treasury), INBOX_ACTION);
        calls[2] = LitAdminCalls.addInboxGroup(config, address(treasury), INBOX_ACTION);
        calls[3] = LitAdminCalls.mintExecuteOnlyKey(config, address(treasury), OPERATOR_KEY);
    }

    // ---------------------------------------------------------------- ERC-1271

    /// @dev Invariant: before any proposal, the treasury answers no to every hash, whatever the
    /// signature bytes, so it signs nothing by itself.
    function testFuzz_anUnapprovedHashIsAlwaysNo(bytes32 hash, bytes calldata signature) public {
        (, KeyfleetTreasury treasury) = _classic(1);
        assertEq(treasury.isValidSignature(hash, signature), NO);
        assertFalse(SignatureChecker.isValidERC1271SignatureNow(address(treasury), hash, signature));
    }

    function test_anApprovedRequestIsYesWhateverTheSignatureBytes() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        bytes32 request = keccak256("lit message");
        bytes32 hash = _litDigest(request);

        KeyfleetTreasury.Call[] memory calls = _approveRequest(treasury, request);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectEmit(true, true, true, true, address(treasury));
        emit LitRequestApproved(request);
        votes.execute(proposalId, calls);

        assertTrue(treasury.approvedHash(hash));
        assertEq(treasury.isValidSignature(request, ""), NO, "the bare struct hash is no");
        assertEq(treasury.isValidSignature(hash, ""), IERC1271.isValidSignature.selector);
        assertEq(treasury.isValidSignature(hash, hex"1234"), IERC1271.isValidSignature.selector);
        assertTrue(SignatureChecker.isValidERC1271SignatureNow(address(treasury), hash, ""));
        assertEq(treasury.isValidSignature(keccak256("another message"), ""), NO, "only that hash");
    }

    function test_aRevokedRequestIsRefused() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        bytes32 request = keccak256("lit message");
        bytes32 hash = _litDigest(request);
        _execute(fleet, _approveRequest(treasury, request));

        KeyfleetTreasury.Call[] memory calls = _revokeRequest(treasury, request);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectEmit(true, true, true, true, address(treasury));
        emit LitRequestRevoked(request);
        votes.execute(proposalId, calls);

        assertFalse(treasury.approvedHash(hash));
        assertEq(treasury.isValidSignature(hash, ""), NO);
        assertFalse(SignatureChecker.isValidERC1271SignatureNow(address(treasury), hash, ""));
    }

    /// @dev Invariant: only an approved proposal's call approves or revokes a hash; nobody else
    /// reaches either, the voting controller and the manager included.
    function test_onlyAnApprovedCallApprovesOrRevokes() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        bytes32 request = keccak256("lit message");

        address[3] memory callers = [mallory, address(fleet.VOTES()), address(fleet)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
            treasury.approveLitRequest(request);
            vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
            treasury.revokeLitRequest(request);
            vm.stopPrank();
        }

        KeyfleetTreasury.Call[] memory calls = _approveRequest(treasury, request);
        address[2] memory outsiders = [mallory, address(fleet)];
        for (uint256 i = 0; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(KeyfleetTreasury.OnlyVotes.selector);
            treasury.executeBatch(calls);
        }

        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(proposalId, calls);

        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(KeyfleetVotes.ActionsMismatch.selector);
        votes.execute(proposalId, _approveRequest(treasury, keccak256("another message")));

        assertFalse(treasury.approvedHash(_litDigest(request)), "nothing reached it");
        votes.execute(proposalId, calls);
        assertTrue(treasury.approvedHash(_litDigest(request)));
    }

    function test_aRejectedProposalApprovesNothing() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        bytes32 request = keccak256("lit message");
        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory calls = _approveRequest(treasury, request);

        uint256 first = _key(fleet, 1);
        vm.startPrank(keys.ownerOf(first));
        uint256 proposalId = votes.propose(first, keccak256("narrative"), calls);
        votes.castBallot(proposalId, _ids(first), KeyfleetVotes.Choice.No);
        vm.stopPrank();
        vm.warp(votes.executableAt(proposalId));

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Rejected));
        votes.execute(proposalId, calls);
        assertEq(treasury.isValidSignature(_litDigest(request), ""), NO);
    }

    /// @dev Invariant (audit KF-A-02): an approval is only ever a Lit request. Approving a USDC
    /// `TransferWithAuthorization` struct hash from the treasury gives no signature USDC accepts,
    /// because the treasury puts it under Lit's domain, never USDC's.
    function test_anApprovalIsNeverASignatureForAnotherVerifier() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        bytes32 transfer = keccak256(
            abi.encode(
                keccak256(
                    "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                address(treasury),
                mallory,
                type(uint256).max,
                0,
                type(uint256).max,
                bytes32(0)
            )
        );
        bytes32 usdcDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USD Coin"),
                keccak256("2"),
                block.chainid,
                address(usdc)
            )
        );
        _execute(fleet, _approveRequest(treasury, transfer));

        assertEq(treasury.isValidSignature(MessageHashUtils.toTypedDataHash(usdcDomain, transfer), ""), NO);
        assertEq(treasury.isValidSignature(transfer, ""), NO);
        assertEq(treasury.isValidSignature(_litDigest(transfer), ""), IERC1271.isValidSignature.selector);
    }

    /// @dev An approved `CreateWallet` request is yes for exactly the digest Lit checks.
    function test_anApprovedCreateWalletIsYesForLitsDigest() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        bytes32 request = keccak256(
            abi.encode(keccak256("CreateWallet(address address,uint256 issuedAt)"), address(treasury), 1_790_000_000)
        );
        _execute(fleet, _approveRequest(treasury, request));
        bytes32 litChecks = LitAdminCalls.createWalletDigest(address(treasury), 1_790_000_000, block.chainid);
        assertEq(treasury.isValidSignature(litChecks, ""), IERC1271.isValidSignature.selector);
    }

    /// @dev The `CreateWallet` digest matches one computed independently by `eth_account` from
    /// Lit's typed data: domain (name "Lit ChainSecured", version "1", chainId 8453) and message
    /// (address, issuedAt).
    function test_theCreateWalletDigestMatchesLitsTypedData() public pure {
        assertEq(
            LitAdminCalls.createWalletDigest(address(0xFee75), 1_790_000_000, 8453),
            0xd842eda955fa5359c54899e27635df083dd9727b1214248c1283acfdb9979229
        );
    }

    // ---------------------------------------------------------------- Lit admin writes

    /// @dev Setting up the account is four exact calls in one approved proposal; Lit sees the
    /// treasury as the account's admin wallet, and the operator's key may run the inbox action
    /// and nothing else.
    function test_anApprovedProposalSetsUpTheLitAccount() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        MockLitAccountConfig config = new MockLitAccountConfig();
        ILitAccountConfig lit = ILitAccountConfig(address(config));
        uint256 account = LitAdminCalls.accountHash(address(treasury));

        _execute(fleet, _setUpAccount(lit, treasury));

        assertEq(lit.getAccountWalletAddress(account), address(treasury), "the treasury is the admin wallet");
        assertEq(config.groupCount(account), LitAdminCalls.INBOX_GROUP, "one group, numbered 1");
        assertTrue(config.groupHasAction(account, LitAdminCalls.INBOX_GROUP, INBOX_ACTION));
        assertTrue(lit.canExecuteAction(OPERATOR_KEY, INBOX_ACTION), "the operator runs the inbox action");
        assertFalse(lit.canExecuteAction(OPERATOR_KEY, uint256(keccak256("ipfs://other"))), "and nothing else");
    }

    function test_anApprovedProposalReplacesTheOperatorKey() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        ILitAccountConfig lit = ILitAccountConfig(address(new MockLitAccountConfig()));
        _execute(fleet, _setUpAccount(lit, treasury));

        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = LitAdminCalls.removeKey(lit, address(treasury), OPERATOR_KEY);
        calls[1] = LitAdminCalls.mintExecuteOnlyKey(lit, address(treasury), NEXT_OPERATOR_KEY);
        _execute(fleet, calls);

        vm.expectRevert(abi.encodeWithSelector(MockLitAccountConfig.AccountDoesNotExist.selector, OPERATOR_KEY));
        lit.canExecuteAction(OPERATOR_KEY, INBOX_ACTION);
        assertTrue(lit.canExecuteAction(NEXT_OPERATOR_KEY, INBOX_ACTION));
    }

    /// @dev Once a proposal transfers the account, the treasury is no longer its admin, so even an
    /// approved proposal's write is refused by Lit and fails its whole batch.
    function test_anApprovedProposalTransfersTheAccount() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        ILitAccountConfig lit = ILitAccountConfig(address(new MockLitAccountConfig()));
        uint256 account = LitAdminCalls.accountHash(address(treasury));
        _execute(fleet, _setUpAccount(lit, treasury));

        _execute(fleet, _one(address(lit), 0, LitAdminCalls.transferAccount(lit, address(treasury), safe).data));
        assertEq(lit.getAccountWalletAddress(account), safe);

        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](1);
        calls[0] = LitAdminCalls.removeKey(lit, address(treasury), OPERATOR_KEY);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(
            abi.encodeWithSelector(MockLitAccountConfig.NoAccountAccess.selector, account, address(treasury))
        );
        votes.execute(proposalId, calls);
        assertTrue(lit.canExecuteAction(OPERATOR_KEY, INBOX_ACTION), "the key stands");
    }

    /// @dev Invariant: nobody but the treasury writes to the treasury's Lit account, and the
    /// treasury writes only through an approved proposal: a direct write is refused by Lit, and
    /// every path into the treasury short of an approved proposal's exact calls is refused by the
    /// fleet.
    function test_onlyAnApprovedCallWritesToTheLitAccount() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        ILitAccountConfig lit = ILitAccountConfig(address(new MockLitAccountConfig()));
        uint256 account = LitAdminCalls.accountHash(address(treasury));
        _execute(fleet, _setUpAccount(lit, treasury));

        KeyfleetTreasury.Call[] memory steal = new KeyfleetTreasury.Call[](1);
        steal[0] = LitAdminCalls.mintExecuteOnlyKey(lit, address(treasury), uint256(keccak256("lk_mallory")));

        vm.prank(mallory);
        (bool ok, bytes memory reason) = address(lit).call(steal[0].data);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(MockLitAccountConfig.NoAccountAccess.selector, account, mallory));
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MockLitAccountConfig.NoAccountAccess.selector, account, mallory));
        lit.transferChainSecuredAccountOwnership(account, mallory);

        vm.prank(mallory);
        vm.expectRevert(KeyfleetTreasury.OnlyVotes.selector);
        treasury.executeBatch(steal);

        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, steal);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Open));
        votes.execute(proposalId, steal);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(KeyfleetVotes.ActionsMismatch.selector);
        votes.execute(
            proposalId, _one(address(lit), 0, LitAdminCalls.transferAccount(lit, address(treasury), mallory).data)
        );

        vm.expectRevert(
            abi.encodeWithSelector(MockLitAccountConfig.AccountDoesNotExist.selector, uint256(keccak256("lk_mallory")))
        );
        lit.canExecuteAction(uint256(keccak256("lk_mallory")), INBOX_ACTION);
        assertEq(lit.getAccountWalletAddress(account), address(treasury));
    }

    // ---------------------------------------------------------------- Lit stays out of the fleet

    /// @dev Invariant: buying, moving, presence, proposals, ballots, carrying out a proposal
    /// (approving a Lit hash included), the daily split and claims never call Lit. Lit's real
    /// address is armed to revert on any call, and is expected to be called zero times.
    function test_votingAndClaimsNeverTouchLit() public {
        vm.etch(LIT_ACCOUNT_CONFIG, hex"fe");
        vm.expectCall(LIT_ACCOUNT_CONFIG, "", 0);

        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        uint256 first = _key(fleet, 1);
        uint256 second = _key(fleet, 2);
        address holder = keys.ownerOf(first);
        address seller = keys.ownerOf(second);
        vm.prank(seller);
        keys.transferFrom(seller, mallory, second);

        KeyfleetVotes votes = fleet.VOTES();
        vm.prank(holder);
        votes.present(_ids(first));
        _execute(fleet, _approveRequest(treasury, keccak256("lit message")));

        usdc.mint(address(treasury), 1_000e6);
        uint256 runAt = treasury.nextRunAt();
        if (block.timestamp < runAt) vm.warp(runAt);
        treasury.runDailySplit();
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        KeyfleetRewards rewards = fleet.REWARDS();
        vm.prank(holder);
        uint256 paid = rewards.claim(_ids(first), assets)[0];
        assertGt(paid, 0, "the split paid the key");
    }
}
