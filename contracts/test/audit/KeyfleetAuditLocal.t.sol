// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Vm} from "forge-std/Vm.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {FULL_PIECE, KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";

/// @dev AUDIT PoC helper. A token with EIP-3009 `transferWithAuthorization` taking `bytes`
/// signatures checked with ERC-1271 for contract signers, exactly as Circle's FiatTokenV2_2 (Base
/// USDC) does. The fork PoC in `KeyfleetAuditFork.t.sol` repeats the check against real Base USDC.
contract Mock3009Token is ERC20, EIP712 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") EIP712("USD Coin", "2") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function digest(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce))
        );
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        require(block.timestamp > validAfter && block.timestamp < validBefore, "time");
        require(!authorizationState[from][nonce], "used");
        require(
            SignatureChecker.isValidSignatureNow(
                from, digest(from, to, value, validAfter, validBefore, nonce), signature
            ),
            "invalid signature"
        );
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }
}

/// @dev AUDIT PoC helper. A Pass-holding contract that accepts NFTs in any simulation run before the
/// Safe signs, then refuses once its owner flips it, which nobody outside can see coming.
contract TurncoatReceiver is IERC721Receiver {
    bool public hostile;

    function turn() external {
        hostile = true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(!hostile, "refused");
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev AUDIT PoC helper for KF-R-01. A worthless token anyone can deploy. A manager reads a
/// surplus of 1 of it, and when `recognizeSurplus` sends that 1 on, the token runs the shared
/// buyer's `convert` from inside the manager's call.
contract SkipperToken {
    KeyfleetRegentBuyer public immutable BUYER;

    constructor(KeyfleetRegentBuyer buyer) {
        BUYER = buyer;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function transfer(address, uint256) external returns (bool) {
        BUYER.convert(FULL_PIECE);
        return true;
    }
}

/// @dev AUDIT PoC helper for KF-R-01 (purchase variant). A key receiver that runs `convert` from
/// its `onERC721Received`, inside the manager's `purchase`.
contract SkipperReceiver is IERC721Receiver {
    KeyfleetRegentBuyer public immutable BUYER;

    constructor(KeyfleetRegentBuyer buyer) {
        BUYER = buyer;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        BUYER.convert(FULL_PIECE);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Audit proofs that run on the local stand-ins (no fork). Re-check at e05deae, KF-R-01 at
/// 02b3ad2: each fixed finding's PoC repeats the original attack steps and asserts the attack now
/// fails; the open findings (KF-A-04, KF-A-05) assert the behaviour that is still there.
///   forge test --match-path 'test/audit/KeyfleetAuditLocal.t.sol' -vv
contract KeyfleetAuditLocalTest is KeyfleetFixture {
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_NO = 0xffffffff;
    uint256 private constant ALICE_KEY = 0xA11CE;

    address private mallory = address(0x4A11);

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
    }

    /// @dev The founding Classic fleet with `count` keys sold, mature, after its treasury opening.
    function _classic(uint256 count) private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, count);
        _mature();
        _openTreasury(fleet);
    }

    function _waitForPiece() private {
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
    }

    function _skipped(Vm.Log[] memory logs, address manager) private view returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(regentBuyer)
                    && logs[i].topics[0] == KeyfleetRegentBuyer.PieceSkipped.selector
                    && address(uint160(uint256(logs[i].topics[1]))) == manager
            ) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ KF-A-02 (FIXED)

    /// @dev KF-A-02, original attack: one proposal carries a 99% `pay` and a hash approval of a
    /// `transferWithAuthorization` digest for the rest, then anyone spends the "signature". At
    /// e05deae the general hash approval is gone: the batch with it cannot be carried out, and the
    /// only approval left (`approveLitCreateWallet`) never makes the treasury answer yes for the
    /// token's digest, so the remaining 1% stays.
    function test_KFA02_fixed_noProposalCanApproveATransferAuthorizationDigest() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(3);
        Mock3009Token token = new Mock3009Token();
        token.mint(address(treasury), 1_000_000e6);
        uint256 balance = token.balanceOf(address(treasury));
        uint256 rest = balance - (balance * 990_000) / 1_000_000;
        bytes32 nonce = keccak256("drain");
        bytes32 hash = token.digest(address(treasury), mallory, rest, 0, type(uint256).max, nonce);

        // 1. The old general approval no longer exists, even when the treasury calls itself.
        vm.prank(address(treasury));
        (bool ok,) = address(treasury).call(abi.encodeWithSignature("approveSignatureHash(bytes32)", hash));
        assertFalse(ok, "approveSignatureHash is gone");

        // 2. The original attack batch passes the vote but cannot be carried out.
        KeyfleetTreasury.Call[] memory attack = new KeyfleetTreasury.Call[](2);
        attack[0] = KeyfleetTreasury.Call(
            address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (address(token), mallory, 990_000))
        );
        attack[1] =
            KeyfleetTreasury.Call(address(treasury), 0, abi.encodeWithSignature("approveSignatureHash(bytes32)", hash));
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, attack);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert();
        votes.execute(proposalId, attack);
        assertEq(token.balanceOf(address(treasury)), balance, "nothing moved");

        // 3. The approval that is left, carried out next to a 99% pay, says yes only for the
        //    treasury's own Lit CreateWallet request.
        uint256 issuedAt = block.timestamp;
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = attack[0];
        calls[1] = KeyfleetTreasury.Call(
            address(treasury), 0, abi.encodeCall(KeyfleetTreasury.approveLitCreateWallet, (issuedAt))
        );
        _execute(fleet, calls);
        assertEq(token.balanceOf(mallory), balance - rest, "the visible 99% share was paid");
        assertEq(treasury.isValidSignature(treasury.litCreateWalletDigest(issuedAt), ""), ERC1271_MAGIC);
        assertEq(treasury.isValidSignature(hash, ""), ERC1271_NO, "no yes for the token's digest");

        // 4. The drain step of the original attack now fails; the last 1% stays.
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("invalid signature"));
        token.transferWithAuthorization(address(treasury), mallory, rest, 0, type(uint256).max, nonce, "");
        assertEq(token.balanceOf(address(treasury)), rest, "the treasury keeps what the rules keep");
    }

    /// @dev KF-A-02: the approved digest is exactly Lit's `CreateWallet(treasury, issuedAt)` under
    /// Lit's domain (name, version, chain id; no verifying contract), worked out here independently.
    function test_KFA02_fixed_theDigestIsLitsCreateWalletForThisTreasury() public {
        (, KeyfleetTreasury treasury) = _classic(1);
        uint256 issuedAt = 1_234_567;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
                keccak256("Lit ChainSecured"),
                keccak256("1"),
                block.chainid
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(keccak256("CreateWallet(address address,uint256 issuedAt)"), address(treasury), issuedAt)
        );
        assertEq(treasury.litCreateWalletDigest(issuedAt), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    /// @dev KF-A-02: whatever `issuedAt` a proposal approves, the treasury still answers no for any
    /// token transfer authorization from it.
    function testFuzz_KFA02_fixed_anApprovedLitRequestNeverAnswersForATokenDigest(
        uint256 issuedAt,
        address to,
        uint256 value,
        bytes32 nonce
    ) public {
        (, KeyfleetTreasury treasury) = _classic(1);
        Mock3009Token token = new Mock3009Token();
        vm.prank(address(treasury)); // what an approved proposal's call is
        treasury.approveLitCreateWallet(issuedAt);
        bytes32 hash = token.digest(address(treasury), to, value, 0, type(uint256).max, nonce);
        assertEq(treasury.isValidSignature(hash, ""), ERC1271_NO);
        assertEq(treasury.isValidSignature(treasury.litCreateWalletDigest(issuedAt), ""), ERC1271_MAGIC);
    }

    // ------------------------------------------------------------------ KF-A-06 (FIXED)

    /// @dev KF-A-06, original attack: one fleet whose USDC cannot be handed over sits at the head
    /// and every fleet's conversion reverts behind it. At e05deae the frozen fleet is skipped with
    /// its booking whole, the clock does not move, and every other fleet converts.
    function test_KFA06_fixed_aFrozenHeadNoLongerBlocksAnyOtherFleet() public {
        KeyfleetManager frozen = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        KeyfleetManager a = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        KeyfleetManager b = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 frozenBooked = frozen.pendingConversion();
        uint256 frozenHeld = usdc.balanceOf(address(frozen));
        usdc.freeze(address(frozen));
        assertEq(regentBuyer.nextInQueue(), address(frozen), "the frozen fleet heads the queue");

        for (uint256 round = 0; round < 6; ++round) {
            _waitForPiece();
            regentBuyer.convert(FULL_PIECE);
        }
        assertEq(a.pendingConversion(), 0, "a converted");
        assertEq(b.pendingConversion(), 0, "b converted");
        assertGt(regent.balanceOf(address(a.TREASURY())), 0);
        assertGt(regent.balanceOf(address(b.TREASURY())), 0);
        assertEq(frozen.pendingConversion(), frozenBooked, "the frozen fleet keeps its whole booking");
        assertEq(usdc.balanceOf(address(frozen)), frozenHeld, "and every unit of its USDC");
        assertEq(usdc.allowance(address(frozen), address(regentBuyer)), 0, "with nothing left approved");
        assertEq(regentBuyer.queueLength(), 1, "it waits in the queue for when its USDC can move");
    }

    /// @dev KF-A-06: the hand-over is a call only the buyer makes to itself; nobody can run it.
    function test_KFA06_fixed_nobodyElseCanRunTheHandOver() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, mallory));
        regentBuyer.collectPiece(fleet, FULL_PIECE);
        vm.prank(address(fleet));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(fleet)));
        regentBuyer.collectPiece(fleet, FULL_PIECE);
    }

    /// @dev KF-A-06: the v3 payment now comes from the buyer's own balance. USDC donated to the buyer
    /// cannot be taken through the callback outside a piece, and a pool that calls back twice in a
    /// piece is refused, with the fleet's booking and place untouched.
    function test_KFA06_fixed_theCallbackPaysOnceAndOnlyInsideAPiece() public {
        usdc.mint(address(regentBuyer), 1_000e6);
        vm.prank(address(v3Pool));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(v3Pool)));
        regentBuyer.uniswapV3SwapCallback(int256(1_000e6), int256(1_000e6), "");
        assertEq(usdc.balanceOf(address(regentBuyer)), 1_000e6);

        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 booked = fleet.pendingConversion();
        _waitForPiece();
        v3Pool.setCallbackTwice(true);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, address(v3Pool)));
        regentBuyer.convert(FULL_PIECE);
        assertEq(fleet.pendingConversion(), booked);
        assertEq(regentBuyer.nextInQueue(), address(fleet));
        assertEq(usdc.balanceOf(address(regentBuyer)), 1_000e6, "the donation was never spent");
    }

    /// @dev KF-A-06, gas griefing: every gas limit from well under to well over the floor either
    /// converts the healthy head fleet or reverts with its booking and place untouched; none skips it.
    function test_KFA06_fixed_noGasLimitSkipsAHealthyFleet() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 booked = fleet.pendingConversion();
        _waitForPiece();
        uint256 converted;
        uint256 refused;
        for (uint256 gasLimit = 250_000; gasLimit <= 1_200_000; gasLimit += 2_500) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) =
                address(regentBuyer).call{gas: gasLimit}(abi.encodeCall(KeyfleetRegentBuyer.convert, (FULL_PIECE)));
            assertFalse(_skipped(vm.getRecordedLogs(), address(fleet)), "never skipped");
            if (ok) {
                assertEq(fleet.pendingConversion(), 0);
                ++converted;
            } else {
                assertEq(fleet.pendingConversion(), booked);
                assertEq(regentBuyer.nextInQueue(), address(fleet));
                ++refused;
            }
            vm.revertToState(snapshot);
        }
        assertGt(converted, 0);
        assertGt(refused, 0);
    }

    // ------------------------------------------------------------------ KF-R-01 (FIXED)

    /// @dev KF-R-01, original attack (new at e05deae, fixed in 02b3ad2): anyone called a healthy
    /// fleet's permissionless `recognizeSurplus` with a token that runs `convert` from its
    /// `transfer`; the manager's lock made its `takePiece` revert inside the buyer's try/catch, so
    /// the fleet was skipped every time it reached the head. `takePiece` now takes no lock, so the
    /// same steps convert the fleet's piece and the REGENT reaches its treasury.
    function test_KFR01_fixed_aJunkTokenNoLongerSkipsAHealthyFleet() public {
        KeyfleetManager victim = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        KeyfleetManager other = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        uint256 victimBooked = victim.pendingConversion();
        SkipperToken skipper = new SkipperToken(regentBuyer);

        _waitForPiece();
        assertEq(regentBuyer.nextInQueue(), address(victim), "the victim reaches the head");
        uint256 opensAt = regentBuyer.nextPieceAt();

        vm.recordLogs();
        vm.prank(mallory);
        victim.recognizeSurplus(address(skipper));

        assertFalse(_skipped(vm.getRecordedLogs(), address(victim)), "the victim was not skipped");
        assertEq(victim.pendingConversion(), 0, "its whole booking converted");
        assertEq(regent.balanceOf(address(victim.TREASURY())), _regentFor(victimBooked), "into its treasury");
        assertGt(regentBuyer.nextPieceAt(), opensAt, "the clock moved for its piece");
        assertEq(regentBuyer.nextInQueue(), address(other), "the other fleet takes its turn");
    }

    /// @dev KF-R-01, purchase variant, fixed: a key receiver that runs `convert` from
    /// `onERC721Received` converts the fleet it is buying from, the new purchase's share included.
    function test_KFR01_fixed_aKeyReceiverConvertsTheFleetItBuysFrom() public {
        KeyfleetManager victim = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        KeyfleetManager other = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        _waitForPiece();
        assertEq(regentBuyer.nextInQueue(), address(victim));
        SkipperReceiver receiver = new SkipperReceiver(regentBuyer);

        vm.recordLogs();
        _buy(victim, address(receiver));
        assertFalse(_skipped(vm.getRecordedLogs(), address(victim)), "the victim was not skipped");
        assertEq(victim.pendingConversion(), 0, "its whole booking converted");
        assertGt(regent.balanceOf(address(victim.TREASURY())), 0, "into its treasury");
        assertEq(regentBuyer.nextInQueue(), address(other), "the other fleet is now first");
    }

    // ------------------------------------------------------------------ KF-A-09 (FIXED)

    function _ballotDigest(
        KeyfleetVotes votes,
        uint256 proposalId,
        uint256 tokenId,
        KeyfleetVotes.Choice choice,
        address signer,
        uint256 deadline
    ) private view returns (bytes32) {
        uint256[] memory ids = _ids(tokenId);
        uint64[] memory epochs = new uint64[](1);
        uint64[] memory revisions = new uint64[](1);
        epochs[0] = keys.ownershipEpoch(tokenId);
        revisions[0] = shards.delegationRevision(tokenId);
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(votes.BALLOT_TYPEHASH(), proposalId, votes.proposal(proposalId).proposalHash),
                abi.encode(
                    keccak256(abi.encodePacked(ids)),
                    keccak256(abi.encodePacked(epochs)),
                    keccak256(abi.encodePacked(revisions))
                ),
                abi.encode(choice, signer, votes.nonces(signer), deadline)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KeyfleetVotes"),
                keccak256("1"),
                block.chainid,
                address(votes)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signYes(KeyfleetVotes votes, uint256 proposalId, uint256 tokenId, uint256 deadline)
        private
        view
        returns (bytes memory)
    {
        bytes32 digest =
            _ballotDigest(votes, proposalId, tokenId, KeyfleetVotes.Choice.Yes, vm.addr(ALICE_KEY), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ALICE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev KF-A-09, original attack: Alice signs a Yes ballot and gives it to a relayer, then
    /// changes her mind and votes No herself; the relayer submits the old Yes and overrides her.
    /// At e05deae the direct vote uses her nonce, so the old signed ballot is refused.
    function test_KFA09_fixed_aDirectVoteVoidsAnEarlierSignedBallot() public {
        address alice = vm.addr(ALICE_KEY);
        address bob = address(0xB0B);
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);
        _mature();
        vm.prank(bob);
        uint256 proposalId = votes.propose(k2, keccak256("record it"), new KeyfleetTreasury.Call[](0));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signedYes = _signYes(votes, proposalId, k1, deadline);

        vm.prank(alice);
        votes.castBallot(proposalId, _ids(k1), KeyfleetVotes.Choice.No);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(proposalId, _ids(k1), KeyfleetVotes.Choice.Yes, alice, deadline, signedYes);
        assertEq(votes.proposal(proposalId).yes, 0);
        assertEq(votes.proposal(proposalId).no, 1, "Alice's direct No stands");
    }

    // ------------------------------------------------------------------ KF-A-11 (FIXED)

    /// @dev KF-A-11, original attack: a proposal carries a `pay` plus one or more `runVotedSplit`
    /// calls, more than one money move in one ballot. At e05deae each counts as a money move and
    /// the proposal is refused when it is made.
    function test_KFA11_fixed_runVotedSplitCountsAsTheOneMoneyMove() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(3);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 first = _key(fleet, 1);
        address author = keys.ownerOf(first);
        KeyfleetTreasury.Call memory split =
            KeyfleetTreasury.Call(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.runVotedSplit, ()));
        KeyfleetTreasury.Call memory pay = KeyfleetTreasury.Call(
            address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (address(usdc), mallory, 500_000))
        );

        KeyfleetTreasury.Call[][3] memory refused;
        refused[0] = new KeyfleetTreasury.Call[](2);
        (refused[0][0], refused[0][1]) = (split, split);
        refused[1] = new KeyfleetTreasury.Call[](2);
        (refused[1][0], refused[1][1]) = (pay, split);
        refused[2] = new KeyfleetTreasury.Call[](2);
        (refused[2][0], refused[2][1]) = (split, pay);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(author);
            vm.expectRevert(KeyfleetVotes.OneMoneyMovePerProposal.selector);
            votes.propose(first, keccak256("narrative"), refused[i]);
        }

        // One split on its own is still a proposal anyone may make.
        KeyfleetTreasury.Call[] memory alone = new KeyfleetTreasury.Call[](1);
        alone[0] = split;
        vm.prank(author);
        votes.propose(first, keccak256("narrative"), alone);
    }

    // ------------------------------------------------------------------ KF-A-04 (open, unchanged)

    /// @dev KF-A-04 (contract variant). A Pass held by a contract that accepted the script's probe
    /// turns hostile before the Safe's batch lands; the whole gift batch reverts and no key moves.
    function test_KFA04_turncoatPassHolderRevertsTheWholeGiftBatch() public {
        KeyfleetManager club = _deploy(KeyfleetPresets.Preset.RegentsClub);
        address alice = makeAddr("alice");
        address carol = makeAddr("carol");
        TurncoatReceiver turncoat = new TurncoatReceiver();
        clubPass.mint(alice, 1);
        clubPass.mint(address(turncoat), 2);
        clubPass.mint(carol, 3);

        // What the Safe step sees when it builds the batch: the contract takes the key.
        vm.prank(address(keys));
        assertEq(
            turncoat.onERC721Received(address(club), address(0), _key(club, 2), ""),
            IERC721Receiver.onERC721Received.selector,
            "the probe accepts"
        );

        address[] memory receivers = new address[](3);
        (receivers[0], receivers[1], receivers[2]) = (alice, address(turncoat), carol);

        // Between signing and execution the holder flips its contract.
        turncoat.turn();
        vm.prank(safe);
        vm.expectRevert(bytes("refused"));
        club.give(receivers);
        assertEq(club.totalMinted(), 0, "no key of the batch was given");
    }

    /// @dev KF-A-04 (EOA variant). Any Pass holder in the batch moves its Pass after the Safe
    /// transaction is queued; the whole batch reverts with `NotPassHolder`.
    function test_KFA04_passMovedBeforeExecutionRevertsTheWholeGiftBatch() public {
        KeyfleetManager club = _deploy(KeyfleetPresets.Preset.RegentsClub);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");
        clubPass.mint(alice, 1);
        clubPass.mint(bob, 2);
        clubPass.mint(carol, 3);

        address[] memory receivers = new address[](3);
        (receivers[0], receivers[1], receivers[2]) = (alice, bob, carol);

        vm.prank(bob);
        clubPass.transferFrom(bob, makeAddr("bob's other wallet"), 2);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.NotPassHolder.selector, 2, bob));
        club.give(receivers);
        assertEq(club.totalMinted(), 0, "no key of the batch was given");
    }

    // ------------------------------------------------------------------ KF-A-05 (open, unchanged)

    /// @dev KF-A-05. Once the coordinator accepts a key's request, nothing can ask again. If that
    /// request is never answered (here: the Safe moves to a new coordinator while it is pending),
    /// the key keeps no seed for ever.
    function test_KFA05_pendingRevealIsStrandedForeverAfterCoordinatorChange() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        uint256 fleetId = fleet.FLEET_ID();
        vm.prank(keeper);
        keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);
        uint256 tokenId = _key(fleet, 1);

        vm.recordLogs();
        keys.requestReveal(tokenId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 requestId;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == KeyfleetKeys.RevealRequested.selector) requestId = uint256(logs[i].topics[2]);
        }
        assertTrue(requestId != 0, "request accepted");

        MockVRFCoordinatorV2Plus next = new MockVRFCoordinatorV2Plus();
        uint256 sub = next.createSubscription();
        next.addConsumer(sub, address(keys));
        vm.prank(safe);
        keys.setRandomness(
            KeyfleetKeys.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(next)), subscriptionId: sub, keyHash: keccak256("key hash")
            })
        );

        // The old coordinator's answer is refused (recorded as a failed callback) ...
        vrf.fulfill(requestId, _oneWord(7));
        assertFalse(vrf.lastCallbackSuccess(), "old coordinator cannot answer");
        assertEq(keys.revealSeed(tokenId), bytes32(0), "no seed");

        // ... and nobody can ask the new one.
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.RevealAlreadyRequested.selector, tokenId));
        keys.requestReveal(tokenId);
    }

    function _oneWord(uint256 word) private pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = word;
    }
}
