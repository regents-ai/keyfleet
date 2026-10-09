// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetForkFixture} from "../fork/KeyfleetBaseFork.t.sol";

/// @notice The parts of Circle's FiatTokenV2_2 (Base USDC) the proofs use.
interface IFiatTokenV2_2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function version() external view returns (string memory);
    function nonces(address owner) external view returns (uint256);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
    function permit(address owner, address spender, uint256 value, uint256 deadline, bytes memory signature) external;
}

/// @notice Uniswap's Permit2, as deployed on Base.
interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev Audit proofs against the real Base contracts on a local fork, pinned to `FORK_BLOCK`.
/// Nothing is sent to Base. Re-check at e05deae: each fixed finding's PoC repeats the original
/// attack steps and asserts the safe outcome. These tests fail (they do not skip) when
/// `BASE_RPC_URL` is unset. Run with:
///   BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/audit/KeyfleetAuditFork.t.sol' -vv
contract KeyfleetAuditForkTest is KeyfleetForkFixture {
    /// @dev The Base block every proof here runs at.
    uint256 internal constant FORK_BLOCK = 52_366_000;

    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant PERMIT2_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 private constant PERMIT2_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Where FiatTokenProxy keeps its implementation (the zeppelinos slot).
    bytes32 private constant USDC_IMPLEMENTATION_SLOT =
        0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3;
    bytes4 private constant ERC1271_NO = 0xffffffff;

    address private constant HONEST = address(0xB0B0B0);
    address private constant MALLORY = address(0x4A11);

    KeyfleetRegentBuyer private buyer;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        require(bytes(rpc).length != 0, "BASE_RPC_URL is not set: the audit fork tests must run against a Base fork");
        assertTrue(_setUpFork(FORK_BLOCK), "forked");
        assertEq(block.number, FORK_BLOCK, "pinned block");
        _found(5);
        while (keys.phase() < keys.FINAL_PHASE()) {
            _advancePhase();
        }
        buyer = factory.REGENT_BUYER();
    }

    function _waitForPiece() private {
        uint256 opensAt = buyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
    }

    function _skipped(Vm.Log[] memory logs, address manager) private view returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(buyer) && logs[i].topics[0] == KeyfleetRegentBuyer.PieceSkipped.selector
                    && address(uint160(uint256(logs[i].topics[1]))) == manager
            ) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ KF-A-02 (FIXED) on real USDC

    function _transferAuthorizationDigest(IFiatTokenV2_2 fiat, address from, uint256 value, bytes32 nonce)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                fiat.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, MALLORY, value, uint256(0), type(uint256).max, nonce
                    )
                )
            )
        );
    }

    /// @dev KF-A-02 against real Base USDC, original steps: a passed proposal approves a digest,
    /// then anyone moves the treasury's whole USDC with an empty signature. At e05deae the old
    /// approval cannot be carried out, and after the only approval left (Lit's CreateWallet) USDC
    /// still refuses `transferWithAuthorization` and `permit` from the treasury, and the treasury
    /// answers no for USDC, EIP-2612 and Permit2 digests.
    function test_KFA02_fork_fixed_realUsdcRefusesTheTreasuryAfterTheOnlyApprovalLeft() public {
        KeyfleetManager classic = _fleet(1);
        KeyfleetTreasury treasury = classic.TREASURY();
        KeyfleetVotes votes = classic.VOTES();
        _buy(classic, HONEST);
        _openTreasury(classic);

        IFiatTokenV2_2 fiat = IFiatTokenV2_2(address(usdc));
        deal(address(usdc), address(treasury), 50_000e6);
        uint256 balance = usdc.balanceOf(address(treasury));
        bytes32 nonce = keccak256("drain");
        bytes32 digest = _transferAuthorizationDigest(fiat, address(treasury), balance, nonce);

        // The original approval call cannot be carried out any more.
        KeyfleetTreasury.Call[] memory old = _one(
            KeyfleetTreasury.Call(
                address(treasury), 0, abi.encodeWithSignature("approveSignatureHash(bytes32)", digest)
            )
        );
        uint256 proposalId = _approve(classic, old);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert();
        votes.execute(proposalId, old);

        // The approval that is left.
        uint256 issuedAt = block.timestamp;
        _execute(
            classic,
            _one(
                KeyfleetTreasury.Call(
                    address(treasury), 0, abi.encodeCall(KeyfleetTreasury.approveLitCreateWallet, (issuedAt))
                )
            )
        );
        assertEq(treasury.isValidSignature(treasury.litCreateWalletDigest(issuedAt), ""), bytes4(0x1626ba7e));
        assertEq(treasury.isValidSignature(digest, ""), ERC1271_NO, "no for the USDC transfer authorization");

        // The drain step now fails on real USDC.
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("FiatTokenV2: invalid signature"));
        fiat.transferWithAuthorization(address(treasury), MALLORY, balance, 0, type(uint256).max, nonce, "");

        _assertPermitsRefused(treasury, balance);

        assertEq(usdc.balanceOf(address(treasury)), balance, "the treasury keeps its USDC");
        assertEq(usdc.balanceOf(MALLORY), 0);
    }

    /// @dev An EIP-2612 permit from the treasury with an empty signature fails on real USDC, and the
    /// treasury answers no for the USDC permit digest and for a Permit2 allowance digest.
    function _assertPermitsRefused(KeyfleetTreasury treasury, uint256 balance) private {
        IFiatTokenV2_2 fiat = IFiatTokenV2_2(address(usdc));
        // An EIP-2612 permit from the treasury with an empty signature.
        bytes32 permitDigest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                fiat.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        address(treasury),
                        MALLORY,
                        balance,
                        fiat.nonces(address(treasury)),
                        type(uint256).max
                    )
                )
            )
        );
        assertEq(treasury.isValidSignature(permitDigest, ""), ERC1271_NO, "no for a USDC permit");
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("EIP2612: invalid signature"));
        fiat.permit(address(treasury), MALLORY, balance, type(uint256).max, "");

        // And a Permit2 allowance for USDC from the treasury gets no yes either.
        bytes32 details = keccak256(
            abi.encode(PERMIT2_DETAILS_TYPEHASH, address(usdc), type(uint160).max, type(uint48).max, uint48(0))
        );
        bytes32 permit2Digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT2_SINGLE_TYPEHASH, details, MALLORY, type(uint256).max))
            )
        );
        assertEq(treasury.isValidSignature(permit2Digest, ""), ERC1271_NO, "no for a Permit2 allowance");
    }

    // ------------------------------------------------------------------ KF-A-01 (FIXED) on the real route

    /// @dev The terms of an open Classic fleet at 10 USDC that only `member` may join.
    function _gatedTerms(address member) private view returns (KeyfleetFactory.FleetTerms memory terms) {
        terms.preset = KeyfleetPresets.Preset.FleetTechClassic;
        terms.startPrice = 10e6;
        terms.profile = KeyfleetManager.Profile({name: "Gate", description: "x", imageLink: "https://example.com/x"});
        // A one-leaf tree: the root is the leaf and the proof is empty.
        terms.requirements.merkleRoot = keccak256(bytes.concat(keccak256(abi.encode(member))));
        terms.deadline = block.timestamp;
    }

    /// @dev KF-A-01 on the real Base route, original steps: Mallory opens a fleet only Mallory may
    /// join and converts all but one atomic USDC of its booking, to leave a 1-unit piece at the head
    /// that the real 0.05% pool can never fill. At e05deae the piece takes the whole booking, the
    /// gated fleet leaves the queue, and the honest fleet's later pieces all convert.
    function test_KFA01_fork_fixed_aOneUnitRemainderCanNoLongerBeLeft() public {
        deal(address(usdc), MALLORY, 10e6);
        vm.startPrank(MALLORY);
        usdc.approve(address(factory), 10e6);
        (uint256 gatedId,) = factory.createFleet(_gatedTerms(MALLORY));
        vm.stopPrank();
        KeyfleetManager gated = _fleet(gatedId);
        uint256 booked = gated.pendingConversion();
        assertEq(booked, 9e6, "90% booked for the treasury");

        KeyfleetManager classic = _fleet(1);
        _buy(classic, HONEST);
        assertEq(buyer.nextInQueue(), address(gated));

        // Mallory asks for all but one atomic USDC: the whole booking goes.
        _waitForPiece();
        vm.prank(MALLORY);
        uint256 out = buyer.convert(booked - 1);
        assertGt(out, 0, "the piece bought REGENT on the real route");
        assertEq(gated.pendingConversion(), 0, "nothing left booked");
        assertFalse(buyer.isQueued(address(gated)), "the gated fleet left the queue");
        assertGt(regent.balanceOf(address(gated.TREASURY())), 0);

        // The honest fleet converts now and keeps converting.
        for (uint256 round = 0; round < 3; ++round) {
            _waitForPiece();
            assertEq(buyer.nextInQueue(), address(classic));
            assertGt(buyer.convert(type(uint256).max), 0);
            assertEq(classic.pendingConversion(), 0);
            _buy(classic, HONEST);
        }
        assertGt(regent.balanceOf(address(classic.TREASURY())), 0, "the honest treasury holds REGENT");
    }

    // ------------------------------------------------------------------ KF-A-06 (FIXED) on real USDC

    /// @dev KF-A-06 on real Base USDC: USDC's blacklister freezes one fleet's manager (on the fork
    /// only). Before e05deae that fleet blocked every fleet; now it is skipped with its booking
    /// whole, the next fleet converts at once, and once it is freed it converts too, so a skipped
    /// fleet is not skipped for ever.
    function test_KFA06_fork_fixed_aBlacklistedFleetIsSkippedAndConvertsOnceFreed() public {
        IFiatTokenV2_2 fiat = IFiatTokenV2_2(address(usdc));
        KeyfleetManager frozen = _fleet(1);
        KeyfleetManager next = _fleet(2);
        _buy(frozen, HONEST);
        _buy(next, HONEST);
        uint256 frozenBooked = frozen.pendingConversion();
        uint256 frozenHeld = usdc.balanceOf(address(frozen));
        assertEq(buyer.nextInQueue(), address(frozen));

        vm.prank(fiat.blacklister());
        fiat.blacklist(address(frozen));

        _waitForPiece();
        uint256 opensAt = buyer.nextPieceAt();
        vm.expectEmit(address(buyer));
        emit KeyfleetRegentBuyer.PieceSkipped(address(frozen));
        assertEq(buyer.convert(type(uint256).max), 0);
        assertEq(frozen.pendingConversion(), frozenBooked, "booking whole");
        assertEq(usdc.balanceOf(address(frozen)), frozenHeld, "every unit still in the manager");
        assertEq(buyer.nextPieceAt(), opensAt, "the clock did not move");
        assertEq(buyer.nextInQueue(), address(next));

        assertGt(buyer.convert(type(uint256).max), 0, "the next fleet converts at once");
        assertEq(next.pendingConversion(), 0);

        vm.prank(fiat.blacklister());
        fiat.unBlacklist(address(frozen));
        _waitForPiece();
        assertEq(buyer.nextInQueue(), address(frozen));
        assertGt(buyer.convert(type(uint256).max), 0, "freed, it converts");
        assertEq(frozen.pendingConversion(), 0);
    }

    /// @dev Cools every account the hand-over touches, so the measured gas is what a real
    /// transaction pays.
    function _coolHandOver(KeyfleetManager manager) private {
        vm.cool(address(usdc));
        vm.cool(address(uint160(uint256(vm.load(address(usdc), USDC_IMPLEMENTATION_SLOT)))));
        vm.cool(address(manager));
        vm.cool(address(buyer));
    }

    /// @dev KF-A-06, gas griefing on real USDC: the hand-over, with every account cold, uses well
    /// under its 300,000 stipend, and no outer gas limit, from below the floor to well above it,
    /// makes a healthy fleet be skipped: each call converts it or reverts with its booking and
    /// place untouched.
    function test_KFA06_fork_fixed_noGasLimitSkipsAHealthyFleetOnRealUsdc() public {
        KeyfleetManager fleet = _fleet(1);
        _buy(fleet, HONEST);
        uint256 booked = fleet.pendingConversion();
        _waitForPiece();

        uint256 piece = buyer.PIECE_USDC();
        uint256 stipend = buyer.COLLECT_GAS();
        uint256 snapshot = vm.snapshotState();
        _coolHandOver(fleet);
        vm.prank(address(buyer));
        uint256 before = gasleft();
        buyer.collectPiece(fleet, piece);
        uint256 used = before - gasleft();
        console2.log("hand-over gas, cold, real USDC:", used);
        assertLt(used, stipend / 2, "at least half the stipend to spare");
        vm.revertToState(snapshot);

        uint256 converted;
        uint256 refused;
        for (uint256 gasLimit = 280_000; gasLimit <= 1_500_000; gasLimit += 10_000) {
            snapshot = vm.snapshotState();
            _coolHandOver(fleet);
            vm.recordLogs();
            (bool ok,) =
                address(buyer).call{gas: gasLimit}(abi.encodeCall(KeyfleetRegentBuyer.convert, (type(uint256).max)));
            assertFalse(_skipped(vm.getRecordedLogs(), address(fleet)), "never skipped");
            if (ok) {
                assertEq(fleet.pendingConversion(), 0);
                ++converted;
            } else {
                assertEq(fleet.pendingConversion(), booked);
                assertEq(buyer.nextInQueue(), address(fleet));
                ++refused;
            }
            vm.revertToState(snapshot);
        }
        console2.log("gas limits that converted:", converted, "that reverted untouched:", refused);
        assertGt(converted, 0);
        assertGt(refused, 0);
    }
}
