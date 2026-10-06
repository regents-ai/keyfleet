// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";
import {MockContractWallet} from "./mocks/MockContractWallet.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Signed renewals and ballots: anyone submits them, the signer must be allowed to act for every
/// key named, and a signature is void after one use, after its deadline, after a key it names
/// changes hands, and after any change to who may act for such a key.
contract KeyfleetSignaturesTest is Test {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 private constant ALICE_KEY = 0xA11CE;
    uint256 private constant AGENT_KEY = 0xA6E27;
    uint256 private constant MALLORY_KEY = 0x4A11;
    uint256 private constant SAFE_SIGNER_KEY = 0x5AFE;
    KeyfleetVotes.Choice private constant YES = KeyfleetVotes.Choice.Yes;
    KeyfleetVotes.Choice private constant NO = KeyfleetVotes.Choice.No;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    Keyfleet private fleet;
    KeyfleetVotes private votes;
    KeyfleetShards private shards;

    address private alice = vm.addr(ALICE_KEY);
    address private agent = vm.addr(AGENT_KEY);
    address private mallory = vm.addr(MALLORY_KEY);
    address private bob = address(0xB0B);
    address private keeper = address(0x7EE9E2);
    address private buyer = address(0xB0B0B0);

    event Present(uint256 indexed tokenId, uint64 at, uint64 blockNumber, uint64 epoch);
    event BallotCast(
        uint256 indexed proposalId, address indexed voter, KeyfleetVotes.Choice choice, uint256[] tokenIds
    );

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        vrf = new MockVRFCoordinatorV2Plus();
        uint256 subscription = vrf.createSubscription();
        vm.warp(1_000_000);
        vm.roll(1_000);
        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            new MockRegentRevenueStaking(usdc),
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: subscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(subscription, address(fleet));
        votes = fleet.VOTES();
        shards = fleet.SHARDS();
        _buy(alice); // key 1
        _buy(alice); // key 2
        _buy(bob); // key 3
    }

    // --- helpers ---------------------------------------------------------

    function _buy(address receiver) private returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, price, block.timestamp);
        vm.stopPrank();
    }

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _deadline() private view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// @dev The EIP-712 encoding of the keys, written out independently of the contract.
    function _keyState(uint256[] memory ids) private view returns (bytes32, bytes32, bytes32) {
        uint64[] memory epochs = new uint64[](ids.length);
        uint64[] memory revisions = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            epochs[i] = fleet.ownershipEpoch(ids[i]);
            revisions[i] = shards.delegationRevision(ids[i]);
        }
        return
            (
                keccak256(abi.encodePacked(ids)),
                keccak256(abi.encodePacked(epochs)),
                keccak256(abi.encodePacked(revisions))
            );
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("KeyfleetVotes"), keccak256("1"), block.chainid, address(votes))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _presentHash(uint256[] memory ids, address signer, uint256 deadline) private view returns (bytes32) {
        (bytes32 idHash, bytes32 epochs, bytes32 revisions) = _keyState(ids);
        return keccak256(
            abi.encode(
                votes.PRESENT_TYPEHASH(),
                address(fleet),
                idHash,
                epochs,
                revisions,
                signer,
                votes.nonces(signer),
                deadline
            )
        );
    }

    function _ballotHash(
        uint256 proposalId,
        uint256[] memory ids,
        KeyfleetVotes.Choice choice,
        address signer,
        uint256 deadline
    ) private view returns (bytes32) {
        (bytes32 idHash, bytes32 epochs, bytes32 revisions) = _keyState(ids);
        return keccak256(
            abi.encode(
                votes.BALLOT_TYPEHASH(),
                proposalId,
                votes.proposal(proposalId).proposalHash,
                idHash,
                epochs,
                revisions,
                choice,
                signer,
                votes.nonces(signer),
                deadline
            )
        );
    }

    function _signPresent(uint256 privateKey, uint256[] memory ids, uint256 deadline)
        private
        view
        returns (bytes memory)
    {
        return _sign(privateKey, _presentHash(ids, vm.addr(privateKey), deadline));
    }

    function _signBallot(
        uint256 privateKey,
        uint256 proposalId,
        uint256[] memory ids,
        KeyfleetVotes.Choice choice,
        uint256 deadline
    ) private view returns (bytes memory) {
        return _sign(privateKey, _ballotHash(proposalId, ids, choice, vm.addr(privateKey), deadline));
    }

    function _propose() private returns (uint256 proposalId) {
        vm.prank(bob);
        proposalId =
            votes.propose(3, keccak256("record it"), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
    }

    // --- 1. the signed path ------------------------------------------------

    /// @dev Invariant: the contract accepts a renewal signed by an independent EIP-712 library
    /// (Python `eth_account`, `encode_typed_data`) from the published type string, so a site or CLI
    /// building the message from the README gets the same digest. The signature was made off line
    /// with this suite's throwaway key for Alice, over keys 1 and 2 at epochs 1 and 1 and delegation
    /// revisions 0 and 1, nonce 0 and deadline 2,000,000, on chain 31337 at this suite's addresses.
    function test_aSignatureFromAnIndependentEncoderIsAccepted() public {
        assertEq(address(votes), 0xc7183455a4C133Ae270771860664b6B7ec320bB1, "the address the vector was signed for");
        assertEq(address(fleet), 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9);
        assertEq(block.chainid, 31337);
        vm.prank(alice);
        shards.issue(_ids(2), bob, 30);

        votes.presentBySig(
            _pair(1, 2),
            alice,
            2_000_000,
            hex"0dc9818ee53ccbf71380113b427ebbd971e25c5e1f6661b875c988c553d5884b38d00510d36c089e32d000b2777931b3e6c0dcaa54a508a27775f40081a8b9b81c"
        );
        assertTrue(votes.isActive(1) && votes.isActive(2));
    }

    /// @dev Invariant: the contract accepts a ballot signed by the same independent encoder, over a
    /// proposal hash the encoder worked out itself from the published formula, so a site or CLI
    /// building either from the README gets the same bytes. Bob proposes with key 3 and no calls,
    /// content `keccak256("record it")`, closing a day after time 1,000,000, at this suite's treasury
    /// address; Alice signs Yes for keys 1 and 2 at epochs 1 and 1 and delegation revisions 0 and 0,
    /// nonce 0 and deadline 2,000,000.
    function test_aBallotFromAnIndependentEncoderIsAccepted() public {
        assertEq(address(fleet.TREASURY()), 0xa0Cb889707d426A7A386870A03bc70d1b0697598);
        uint256 proposalId = _propose();
        assertEq(
            votes.proposal(proposalId).actionsHash,
            0x569e75fc77c1a856f6daaf9e69d8a9566ca34aa47f9133711ce065a571af0cfd,
            "the hash of no calls"
        );
        assertEq(
            votes.proposal(proposalId).proposalHash,
            0xf7b7d0c0a22b5c5ada4ae30e3b02dcf260902a1709242a52806cd8b6327514ed,
            "the proposal hash the encoder worked out"
        );

        votes.castBallotBySig(
            proposalId,
            _pair(1, 2),
            YES,
            alice,
            2_000_000,
            hex"e3754659b1d36aa390f89ff4b4e7470b8fb35b91b6c6e8b3c512145270f07e7a4eb971ffad8c0702f9b91f53e9d7894595a8abd0c69211e5fbfb4515ca267ad91b"
        );
        assertEq(votes.proposal(proposalId).yes, 2);
    }

    /// @dev Invariant: the two message types are pinned, so an off-chain signer builds exactly what
    /// the contract checks.
    function test_theMessageTypesArePinned() public view {
        assertEq(
            votes.PRESENT_TYPEHASH(),
            keccak256(
                "Present(address fleet,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)"
            )
        );
        assertEq(
            votes.BALLOT_TYPEHASH(),
            keccak256(
                "Ballot(uint256 proposalId,bytes32 proposalHash,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)"
            )
        );
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            votes.eip712Domain();
        assertEq(name, "KeyfleetVotes");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(votes));
    }

    /// @dev Invariant: an owner's signed renewal is submitted by anyone, renews every key it names,
    /// and uses the owner's nonce.
    function test_anyoneSubmitsAnOwnersSignedRenewal() public {
        uint256[] memory ids = _pair(1, 2);
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, ids, deadline);

        vm.expectEmit(true, true, true, true, address(votes));
        emit Present(2, uint64(block.timestamp), uint64(block.number), 1);
        vm.prank(keeper);
        votes.presentBySig(ids, alice, deadline, signature);

        assertTrue(votes.isActive(1) && votes.isActive(2), "both keys renewed");
        assertEq(votes.nonces(alice), 1, "the nonce was used");
    }

    /// @dev Invariant: a signed ballot is recorded under its signer, not its submitter, and nobody
    /// can change the choice, the proposal or the keys it signed.
    function test_aSignedBallotBindsItsChoiceProposalAndKeys() public {
        uint256 first = _propose();
        uint256 second = _propose();
        uint256[] memory ids = _pair(1, 2);
        uint256 deadline = _deadline();
        bytes memory signature = _signBallot(ALICE_KEY, first, ids, YES, deadline);

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(first, ids, NO, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(second, ids, YES, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(first, _ids(1), YES, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(ids, alice, deadline, signature);

        vm.expectEmit(true, true, true, true, address(votes));
        emit BallotCast(first, alice, YES, ids);
        votes.castBallotBySig(first, ids, YES, alice, deadline, signature);
        vm.stopPrank();

        assertEq(votes.proposal(first).yes, 2);
        assertEq(votes.proposal(second).yes, 0);
        assertTrue(votes.isActive(1) && votes.isActive(2), "a ballot renews the keys");
    }

    /// @dev Invariant: a signed message is used once. Submitting it again finds the nonce moved on.
    function test_aSignedMessageIsUsedOnce() public {
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, _ids(1), deadline);
        votes.presentBySig(_ids(1), alice, deadline, signature);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(_ids(1), alice, deadline, signature);

        uint256 proposalId = _propose();
        signature = _signBallot(ALICE_KEY, proposalId, _ids(1), YES, deadline);
        votes.castBallotBySig(proposalId, _ids(1), YES, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(proposalId, _ids(1), YES, alice, deadline, signature);
        assertEq(votes.nonces(alice), 2);
    }

    /// @dev Invariant: a signed message is good up to and including its deadline, and not after.
    function test_anExpiredSignatureIsRefused() public {
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, _ids(1), deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.SignatureExpired.selector, deadline));
        votes.presentBySig(_ids(1), alice, deadline, signature);

        vm.warp(deadline);
        votes.presentBySig(_ids(1), alice, deadline, signature);
        assertTrue(votes.isActive(1));
    }

    /// @dev Invariant: a signed message names its keys strictly ascending, so a set of keys has one
    /// encoding; a repeat, a descending pair and an empty list are refused.
    function test_signedKeysMustAscend() public {
        uint256 deadline = _deadline();
        uint256[] memory twice = _pair(1, 1);
        uint256[] memory descending = _pair(2, 1);

        vm.expectRevert(KeyfleetVotes.KeysNotAscending.selector);
        votes.presentBySig(twice, alice, deadline, "");
        vm.expectRevert(KeyfleetVotes.KeysNotAscending.selector);
        votes.presentBySig(descending, alice, deadline, "");
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.presentBySig(new uint256[](0), alice, deadline, "");

        uint256 proposalId = _propose();
        vm.expectRevert(KeyfleetVotes.KeysNotAscending.selector);
        votes.castBallotBySig(proposalId, descending, YES, alice, deadline, "");
    }

    // --- 2. old signatures ---------------------------------------------------

    /// @dev Invariant: a key changing hands voids every signature naming it, even one its signer
    /// would still be allowed to make after the key comes back.
    function test_anOldSignatureFailsAfterTheKeyMoves() public {
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, _ids(1), deadline);
        uint256 proposalId = _propose();
        bytes memory ballot = _signBallot(ALICE_KEY, proposalId, _ids(1), YES, deadline);

        vm.startPrank(alice);
        fleet.transferFrom(alice, bob, 1);
        vm.stopPrank();
        vm.prank(bob);
        fleet.transferFrom(bob, alice, 1);
        assertEq(fleet.ownerOf(1), alice, "Alice holds the key again");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(_ids(1), alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(proposalId, _ids(1), YES, alice, deadline, ballot);
    }

    /// @dev Invariant: ending a shard voids the agent's signatures for that key, and so does any
    /// other change to who may act for it, a reissue or the agent-voting switch, even where the
    /// agent would still be allowed to sign the same message again.
    function test_anOldSignatureFailsAfterTheKeysShardsChange() public {
        vm.prank(alice);
        shards.issue(_pair(1, 2), agent, 30);
        uint256 deadline = _deadline();

        bytes memory signature = _signPresent(AGENT_KEY, _ids(1), deadline);
        vm.prank(alice);
        shards.end(_ids(1), agent);
        vm.prank(alice);
        shards.issue(_ids(1), agent, 30);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, agent));
        votes.presentBySig(_ids(1), agent, deadline, signature);

        uint256 proposalId = _propose();
        bytes memory ballot = _signBallot(AGENT_KEY, proposalId, _ids(2), YES, deadline);
        vm.startPrank(alice);
        shards.setAgentVoting(_ids(2), false);
        shards.setAgentVoting(_ids(2), true);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, agent));
        votes.castBallotBySig(proposalId, _ids(2), YES, agent, deadline, ballot);

        ballot = _signBallot(AGENT_KEY, proposalId, _ids(2), YES, deadline);
        votes.castBallotBySig(proposalId, _ids(2), YES, agent, deadline, ballot);
        assertEq(votes.proposal(proposalId).yes, 1, "a fresh signature works");
    }

    // --- 3. who may sign ---------------------------------------------------

    /// @dev Invariant: a keeper submits signatures but gains nothing by signing its own: a valid
    /// signature from somebody who may not act for the key is refused, as are a marketplace
    /// operator's.
    function test_aKeeperCannotMarkSomeoneElsePresentBySignature() public {
        uint256 deadline = _deadline();
        address keeperSigner = vm.addr(0x7EE9);
        bytes memory signature = _signPresent(0x7EE9, _ids(1), deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, keeperSigner));
        votes.presentBySig(_ids(1), keeperSigner, deadline, signature);

        vm.prank(alice);
        fleet.setApprovalForAll(mallory, true);
        signature = _signPresent(MALLORY_KEY, _ids(1), deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.presentBySig(_ids(1), mallory, deadline, signature);

        uint256 proposalId = _propose();
        signature = _signBallot(MALLORY_KEY, proposalId, _ids(1), YES, deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, mallory));
        votes.castBallotBySig(proposalId, _ids(1), YES, mallory, deadline, signature);

        signature = _signPresent(MALLORY_KEY, _ids(1), deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(_ids(1), alice, deadline, signature);
        assertFalse(votes.isActive(1), "nobody renewed key 1");
    }

    /// @dev Invariant: an agent holding shards of keys from several owners renews them all with one
    /// signature, and votes them with one while their agent voting is on; with it off for a key the
    /// agent may still renew it but not vote it.
    function test_anAgentSignsForTheKeysOfManyOwners() public {
        vm.prank(alice);
        shards.issue(_pair(1, 2), agent, 30);
        vm.prank(bob);
        shards.issue(_ids(3), agent, 30);
        uint256[] memory all = new uint256[](3);
        (all[0], all[1], all[2]) = (1, 2, 3);
        uint256 deadline = _deadline();

        votes.presentBySig(all, agent, deadline, _signPresent(AGENT_KEY, all, deadline));
        assertTrue(votes.isActive(1) && votes.isActive(2) && votes.isActive(3));

        uint256 proposalId = _propose();
        votes.castBallotBySig(
            proposalId, all, NO, agent, deadline, _signBallot(AGENT_KEY, proposalId, all, NO, deadline)
        );
        assertEq(votes.proposal(proposalId).no, 3, "three keys, two owners, one signature");

        vm.prank(bob);
        shards.setAgentVoting(_ids(3), false);
        bytes memory ballot = _signBallot(AGENT_KEY, proposalId, all, YES, deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 3, agent));
        votes.castBallotBySig(proposalId, all, YES, agent, deadline, ballot);
        votes.presentBySig(all, agent, deadline, _signPresent(AGENT_KEY, all, deadline));
    }

    /// @dev Invariant: a contract wallet that owns keys signs through ERC-1271, for renewing and
    /// voting alike, and a signature its owner did not make is refused.
    function test_aContractWalletSignsThroughErc1271() public {
        MockContractWallet safe = new MockContractWallet(vm.addr(SAFE_SIGNER_KEY));
        uint256 tokenId = _buy(address(safe));
        uint256 deadline = _deadline();
        uint256[] memory ids = _ids(tokenId);

        bytes memory forged = _sign(MALLORY_KEY, _presentHash(ids, address(safe), deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, address(safe)));
        votes.presentBySig(ids, address(safe), deadline, forged);

        votes.presentBySig(
            ids, address(safe), deadline, _sign(SAFE_SIGNER_KEY, _presentHash(ids, address(safe), deadline))
        );
        assertTrue(votes.isActive(tokenId), "the wallet's key is present");

        uint256 proposalId = _propose();
        bytes memory ballot = _sign(SAFE_SIGNER_KEY, _ballotHash(proposalId, ids, YES, address(safe), deadline));
        votes.castBallotBySig(proposalId, ids, YES, address(safe), deadline, ballot);
        assertEq(uint256(votes.ballotOf(proposalId, tokenId)), uint256(KeyfleetVotes.Choice.Yes));
    }
}
