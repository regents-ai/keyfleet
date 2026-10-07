// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockContractWallet} from "./mocks/MockContractWallet.sol";

/// @dev Signed renewals and ballots: anyone submits them, the signer must be allowed to act for every
/// key named, and a signature is void after one use, after its deadline, after a key it names
/// changes hands, after any change to who may act for such a key, and in every fleet but the one
/// it was signed for.
contract KeyfleetSignaturesTest is KeyfleetFixture {
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 private constant ALICE_KEY = 0xA11CE;
    uint256 private constant AGENT_KEY = 0xA6E27;
    uint256 private constant MALLORY_KEY = 0x4A11;
    uint256 private constant WALLET_SIGNER_KEY = 0x5AFE;
    /// @dev The starting price of the open fleets these tests create: 10 USDC.
    uint256 private constant OPEN_START = 10_000_000;
    KeyfleetVotes.Choice private constant YES = KeyfleetVotes.Choice.Yes;
    KeyfleetVotes.Choice private constant NO = KeyfleetVotes.Choice.No;

    /// @dev The founding Classic fleet, fleet 1, and its voting controller.
    KeyfleetManager private fleet;
    KeyfleetVotes private votes;
    /// @dev Keys 1 and 2 of the founding Classic fleet are Alice's, key 3 is Bob's.
    uint256 private k1;
    uint256 private k2;
    uint256 private k3;

    address private alice = vm.addr(ALICE_KEY);
    address private agent = vm.addr(AGENT_KEY);
    address private mallory = vm.addr(MALLORY_KEY);
    address private bob = address(0xB0B);

    event Present(uint256 indexed tokenId, uint64 at, uint64 blockNumber, uint64 epoch);
    event BallotCast(
        uint256 indexed proposalId, address indexed voter, KeyfleetVotes.Choice choice, uint256[] tokenIds
    );

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(1_000);
        _setUpFixture();
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        votes = fleet.VOTES();
        k1 = _buy(fleet, alice);
        k2 = _buy(fleet, alice);
        k3 = _buy(fleet, bob);
    }

    // --- helpers ---------------------------------------------------------

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _deadline() private view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// @dev The EIP-712 encoding of the keys, their ownership epochs and their delegation
    /// revisions: three words, written out independently of the contract.
    function _keyState(uint256[] memory ids) private view returns (bytes memory) {
        uint64[] memory epochs = new uint64[](ids.length);
        uint64[] memory revisions = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            epochs[i] = keys.ownershipEpoch(ids[i]);
            revisions[i] = shards.delegationRevision(ids[i]);
        }
        return abi.encode(
            keccak256(abi.encodePacked(ids)),
            keccak256(abi.encodePacked(epochs)),
            keccak256(abi.encodePacked(revisions))
        );
    }

    /// @dev The digest a signer signs for the controller at `verifier`.
    function _digest(KeyfleetVotes verifier, bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("KeyfleetVotes"), keccak256("1"), block.chainid, address(verifier))
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 privateKey, KeyfleetVotes verifier, bytes32 structHash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _digest(verifier, structHash));
        return abi.encodePacked(r, s, v);
    }

    function _sign(uint256 privateKey, bytes32 structHash) private view returns (bytes memory) {
        return _sign(privateKey, votes, structHash);
    }

    /// @dev A `Present` message naming `manager`, at `nonceFrom`'s current nonce for the signer.
    function _presentHash(
        KeyfleetVotes nonceFrom,
        address manager,
        uint256[] memory ids,
        address signer,
        uint256 deadline
    ) private view returns (bytes32) {
        // Every field is one static word, so the parts joined are the whole encoding.
        return keccak256(
            bytes.concat(
                abi.encode(votes.PRESENT_TYPEHASH(), manager),
                _keyState(ids),
                abi.encode(signer, nonceFrom.nonces(signer), deadline)
            )
        );
    }

    function _presentHash(uint256[] memory ids, address signer, uint256 deadline) private view returns (bytes32) {
        return _presentHash(votes, address(fleet), ids, signer, deadline);
    }

    /// @dev A `Ballot` message on `proposalId` with `proposalHash`, at `nonceFrom`'s current nonce
    /// for the signer.
    function _ballotHash(
        KeyfleetVotes nonceFrom,
        uint256 proposalId,
        bytes32 proposalHash,
        uint256[] memory ids,
        KeyfleetVotes.Choice choice,
        address signer,
        uint256 deadline
    ) private view returns (bytes32) {
        // Every field is one static word, so the parts joined are the whole encoding.
        return keccak256(
            bytes.concat(
                abi.encode(votes.BALLOT_TYPEHASH(), proposalId, proposalHash),
                _keyState(ids),
                abi.encode(choice, signer, nonceFrom.nonces(signer), deadline)
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
        return _ballotHash(votes, proposalId, votes.proposal(proposalId).proposalHash, ids, choice, signer, deadline);
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
            votes.propose(k3, keccak256("record it"), uint64(block.timestamp + 1 days), new KeyfleetTreasury.Call[](0));
    }

    // --- 1. the signed path ------------------------------------------------

    /// @dev Invariant: the contract accepts a renewal signed by an independent EIP-712 encoder from
    /// the published type string, so a site or CLI building the message from the README gets the
    /// same digest. The signature was made off line with Foundry's `cast wallet sign --data` (Rust,
    /// alloy) and this suite's throwaway key for Alice, over keys 1 and 2 of fleet 1 at epochs 1
    /// and 1 and delegation revisions 0 and 1, nonce 0 and deadline 2,000,000, on chain 31337 at
    /// this suite's addresses. The fleet contracts are deployed with CREATE2, so a change to their
    /// code moves these addresses, and then both vectors must be worked out and signed again.
    function test_aSignatureFromAnIndependentEncoderIsAccepted() public {
        assertEq(address(votes), 0x95a5Db62f5ebD444856f256CB693539f1c6691d8, "the address the vector was signed for");
        assertEq(address(fleet), 0x0BBfE3Ce86688D0E45F6956c198afE3F67cbb69f, "the manager the vector names");
        assertEq(block.chainid, 31337);
        assertEq(k1, 10_000_000_001);
        assertEq(k2, 10_000_000_002);
        vm.prank(alice);
        shards.issue(_ids(k2), bob, 30);

        votes.presentBySig(
            _pair(k1, k2),
            alice,
            2_000_000,
            hex"58bdbda72638be5fe90025f8c254f891a8b3341085d342c9cd410df3501389d049d1b084662506f7af97feb2f15696e5cd3a18a4d5ea3b551ca3e807c13b1d291b"
        );
        assertTrue(votes.isActive(k1) && votes.isActive(k2));
    }

    /// @dev Invariant: the contract accepts a ballot signed by the same independent encoder, over a
    /// proposal hash worked out with `cast` from the published formula, so a site or CLI building
    /// either from the README gets the same bytes. Bob proposes with key 3 of fleet 1 and no calls,
    /// content `keccak256("record it")`, closing a day after time 1,000,000, at this suite's
    /// treasury address; Alice signs Yes for keys 1 and 2 at epochs 1 and 1 and delegation
    /// revisions 0 and 0, nonce 0 and deadline 2,000,000.
    function test_aBallotFromAnIndependentEncoderIsAccepted() public {
        assertEq(address(fleet.TREASURY()), 0xCEA6B0151812958b290C6a45bb5B3b8746B6D482, "the treasury the encoder used");
        uint256 proposalId = _propose();
        assertEq(
            votes.proposal(proposalId).actionsHash,
            0x569e75fc77c1a856f6daaf9e69d8a9566ca34aa47f9133711ce065a571af0cfd,
            "the hash of no calls"
        );
        assertEq(
            votes.proposal(proposalId).proposalHash,
            0x78cedfa57ac3982084dcf841f9423d6b4a7c286725c28c2deb1fc325addae748,
            "the proposal hash the encoder worked out"
        );

        votes.castBallotBySig(
            proposalId,
            _pair(k1, k2),
            YES,
            alice,
            2_000_000,
            hex"8b8bf80ab997a91e8374243513269c1fbbd8ad5b875111de8a80840b9f4430e54e999b59ee0b08a94bf1b7e172635e2d909a3f7cd3e46aacc8b56f72df62c3321c"
        );
        assertEq(votes.proposal(proposalId).yes, 2);
    }

    /// @dev Invariant: the two message types are pinned, so an off-chain signer builds exactly what
    /// the contract checks. A renewal names the fleet's manager.
    function test_theMessageTypesArePinned() public view {
        assertEq(
            votes.PRESENT_TYPEHASH(),
            keccak256(
                "Present(address manager,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)"
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
        uint256[] memory ids = _pair(k1, k2);
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, ids, deadline);

        vm.expectEmit(true, true, true, true, address(votes));
        emit Present(k2, uint64(block.timestamp), uint64(block.number), 1);
        vm.prank(keeper);
        votes.presentBySig(ids, alice, deadline, signature);

        assertTrue(votes.isActive(k1) && votes.isActive(k2), "both keys renewed");
        assertEq(votes.nonces(alice), 1, "the nonce was used");
    }

    /// @dev Invariant: a signed ballot is recorded under its signer, not its submitter, and nobody
    /// can change the choice, the proposal or the keys it signed.
    function test_aSignedBallotBindsItsChoiceProposalAndKeys() public {
        uint256 first = _propose();
        uint256 second = _propose();
        uint256[] memory ids = _pair(k1, k2);
        uint256 deadline = _deadline();
        bytes memory signature = _signBallot(ALICE_KEY, first, ids, YES, deadline);

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(first, ids, NO, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(second, ids, YES, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(first, _ids(k1), YES, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(ids, alice, deadline, signature);

        vm.expectEmit(true, true, true, true, address(votes));
        emit BallotCast(first, alice, YES, ids);
        votes.castBallotBySig(first, ids, YES, alice, deadline, signature);
        vm.stopPrank();

        assertEq(votes.proposal(first).yes, 2);
        assertEq(votes.proposal(second).yes, 0);
        assertTrue(votes.isActive(k1) && votes.isActive(k2), "a ballot renews the keys");
    }

    /// @dev Invariant: a signed message is used once. Submitting it again finds the nonce moved on.
    function test_aSignedMessageIsUsedOnce() public {
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, _ids(k1), deadline);
        votes.presentBySig(_ids(k1), alice, deadline, signature);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(_ids(k1), alice, deadline, signature);

        uint256 proposalId = _propose();
        signature = _signBallot(ALICE_KEY, proposalId, _ids(k1), YES, deadline);
        votes.castBallotBySig(proposalId, _ids(k1), YES, alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(proposalId, _ids(k1), YES, alice, deadline, signature);
        assertEq(votes.nonces(alice), 2);
    }

    /// @dev Invariant: a signed message is good up to and including its deadline, and not after.
    function test_anExpiredSignatureIsRefused() public {
        uint256 deadline = _deadline();
        bytes memory signature = _signPresent(ALICE_KEY, _ids(k1), deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.SignatureExpired.selector, deadline));
        votes.presentBySig(_ids(k1), alice, deadline, signature);

        vm.warp(deadline);
        votes.presentBySig(_ids(k1), alice, deadline, signature);
        assertTrue(votes.isActive(k1));
    }

    /// @dev Invariant: a signed message names its keys strictly ascending, so a set of keys has one
    /// encoding; a repeat, a descending pair and an empty list are refused.
    function test_signedKeysMustAscend() public {
        uint256 deadline = _deadline();
        uint256[] memory twice = _pair(k1, k1);
        uint256[] memory descending = _pair(k2, k1);

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
        bytes memory signature = _signPresent(ALICE_KEY, _ids(k1), deadline);
        uint256 proposalId = _propose();
        bytes memory ballot = _signBallot(ALICE_KEY, proposalId, _ids(k1), YES, deadline);

        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        vm.prank(bob);
        keys.transferFrom(bob, alice, k1);
        assertEq(keys.ownerOf(k1), alice, "Alice holds the key again");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(_ids(k1), alice, deadline, signature);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.castBallotBySig(proposalId, _ids(k1), YES, alice, deadline, ballot);
    }

    /// @dev Invariant: ending a shard voids the agent's signatures for that key, and so does any
    /// other change to who may act for it, a reissue or the agent-voting switch, even where the
    /// agent would still be allowed to sign the same message again.
    function test_anOldSignatureFailsAfterTheKeysShardsChange() public {
        vm.prank(alice);
        shards.issue(_pair(k1, k2), agent, 30);
        uint256 deadline = _deadline();

        bytes memory signature = _signPresent(AGENT_KEY, _ids(k1), deadline);
        vm.prank(alice);
        shards.end(_ids(k1), agent);
        vm.prank(alice);
        shards.issue(_ids(k1), agent, 30);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, agent));
        votes.presentBySig(_ids(k1), agent, deadline, signature);

        uint256 proposalId = _propose();
        bytes memory ballot = _signBallot(AGENT_KEY, proposalId, _ids(k2), YES, deadline);
        vm.startPrank(alice);
        shards.setAgentVoting(_ids(k2), false);
        shards.setAgentVoting(_ids(k2), true);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, agent));
        votes.castBallotBySig(proposalId, _ids(k2), YES, agent, deadline, ballot);

        ballot = _signBallot(AGENT_KEY, proposalId, _ids(k2), YES, deadline);
        votes.castBallotBySig(proposalId, _ids(k2), YES, agent, deadline, ballot);
        assertEq(votes.proposal(proposalId).yes, 1, "a fresh signature works");
    }

    // --- 3. who may sign ---------------------------------------------------

    /// @dev Invariant: a keeper submits signatures but gains nothing by signing its own: a valid
    /// signature from somebody who may not act for the key is refused, as are a marketplace
    /// operator's.
    function test_aKeeperCannotMarkSomeoneElsePresentBySignature() public {
        uint256 deadline = _deadline();
        address keeperSigner = vm.addr(0x7EE9);
        bytes memory signature = _signPresent(0x7EE9, _ids(k1), deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, keeperSigner));
        votes.presentBySig(_ids(k1), keeperSigner, deadline, signature);

        vm.prank(alice);
        keys.setApprovalForAll(mallory, true);
        signature = _signPresent(MALLORY_KEY, _ids(k1), deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.presentBySig(_ids(k1), mallory, deadline, signature);

        uint256 proposalId = _propose();
        signature = _signBallot(MALLORY_KEY, proposalId, _ids(k1), YES, deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, mallory));
        votes.castBallotBySig(proposalId, _ids(k1), YES, mallory, deadline, signature);

        signature = _signPresent(MALLORY_KEY, _ids(k1), deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votes.presentBySig(_ids(k1), alice, deadline, signature);
        assertFalse(votes.isActive(k1), "nobody renewed key 1");
    }

    /// @dev Invariant: an agent holding shards of keys from several owners renews them all with one
    /// signature, and votes them with one while their agent voting is on; with it off for a key the
    /// agent may still renew it but not vote it.
    function test_anAgentSignsForTheKeysOfManyOwners() public {
        vm.prank(alice);
        shards.issue(_pair(k1, k2), agent, 30);
        vm.prank(bob);
        shards.issue(_ids(k3), agent, 30);
        uint256[] memory all = _range(k1, 3);
        uint256 deadline = _deadline();

        votes.presentBySig(all, agent, deadline, _signPresent(AGENT_KEY, all, deadline));
        assertTrue(votes.isActive(k1) && votes.isActive(k2) && votes.isActive(k3));

        uint256 proposalId = _propose();
        votes.castBallotBySig(
            proposalId, all, NO, agent, deadline, _signBallot(AGENT_KEY, proposalId, all, NO, deadline)
        );
        assertEq(votes.proposal(proposalId).no, 3, "three keys, two owners, one signature");

        vm.prank(bob);
        shards.setAgentVoting(_ids(k3), false);
        bytes memory ballot = _signBallot(AGENT_KEY, proposalId, all, YES, deadline);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k3, agent));
        votes.castBallotBySig(proposalId, all, YES, agent, deadline, ballot);
        votes.presentBySig(all, agent, deadline, _signPresent(AGENT_KEY, all, deadline));
    }

    /// @dev Invariant: a contract wallet that owns keys signs through ERC-1271, for renewing and
    /// voting alike, and a signature its owner did not make is refused.
    function test_aContractWalletSignsThroughErc1271() public {
        MockContractWallet wallet = new MockContractWallet(vm.addr(WALLET_SIGNER_KEY));
        uint256 tokenId = _buy(fleet, address(wallet));
        uint256 deadline = _deadline();
        uint256[] memory ids = _ids(tokenId);

        bytes memory forged = _sign(MALLORY_KEY, _presentHash(ids, address(wallet), deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, address(wallet)));
        votes.presentBySig(ids, address(wallet), deadline, forged);

        votes.presentBySig(
            ids, address(wallet), deadline, _sign(WALLET_SIGNER_KEY, _presentHash(ids, address(wallet), deadline))
        );
        assertTrue(votes.isActive(tokenId), "the wallet's key is present");

        uint256 proposalId = _propose();
        bytes memory ballot = _sign(WALLET_SIGNER_KEY, _ballotHash(proposalId, ids, YES, address(wallet), deadline));
        votes.castBallotBySig(proposalId, ids, YES, address(wallet), deadline, ballot);
        assertEq(uint256(votes.ballotOf(proposalId, tokenId)), uint256(KeyfleetVotes.Choice.Yes));
    }

    // --- 4. other fleets -----------------------------------------------------

    /// @dev Two Classic fleets of the same type and starting price, each created by `creator`, who
    /// holds its key 1, with its key 2 sold to Alice; each has proposal 1, made by `creator` with
    /// key 1 on identical terms.
    function _twoFleets() private returns (KeyfleetManager a, KeyfleetManager b) {
        a = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, OPEN_START);
        b = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, OPEN_START);
        _buy(a, alice);
        _buy(b, alice);
        uint256 a1 = _key(a, 1);
        uint256 b1 = _key(b, 1);
        uint64 closesAt = uint64(block.timestamp + 1 days);
        KeyfleetVotes votesA = a.VOTES();
        KeyfleetVotes votesB = b.VOTES();
        vm.startPrank(creator);
        votesA.propose(a1, keccak256("record it"), closesAt, new KeyfleetTreasury.Call[](0));
        votesB.propose(b1, keccak256("record it"), closesAt, new KeyfleetTreasury.Call[](0));
        vm.stopPrank();
    }

    /// @dev Invariant: a signed renewal works only in the fleet it was signed for. Replayed in a
    /// fleet of the same type it is refused, and so is one signed for the other controller or
    /// naming the other fleet's manager: each binding alone voids it.
    function test_aSignedRenewalForOneFleetIsVoidInAnother() public {
        (KeyfleetManager a, KeyfleetManager b) = _twoFleets();
        KeyfleetVotes votesA = a.VOTES();
        KeyfleetVotes votesB = b.VOTES();
        uint256[] memory keyA = _ids(_key(a, 2));
        uint256[] memory keyB = _ids(_key(b, 2));
        uint256 deadline = _deadline();

        bytes memory forA = _sign(ALICE_KEY, votesA, _presentHash(votesA, address(a), keyA, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votesB.presentBySig(keyA, alice, deadline, forA);

        bytes memory otherController = _sign(ALICE_KEY, votesA, _presentHash(votesB, address(b), keyB, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votesB.presentBySig(keyB, alice, deadline, otherController);

        bytes memory otherManager = _sign(ALICE_KEY, votesB, _presentHash(votesB, address(a), keyB, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votesB.presentBySig(keyB, alice, deadline, otherManager);
        assertFalse(votesB.isActive(keyB[0]), "nothing renewed in fleet B");
        assertEq(votesB.nonces(alice), 0);

        votesA.presentBySig(keyA, alice, deadline, forA);
        assertTrue(votesA.isActive(keyA[0]), "it works in the fleet it was signed for");
        bytes memory forB = _sign(ALICE_KEY, votesB, _presentHash(votesB, address(b), keyB, alice, deadline));
        votesB.presentBySig(keyB, alice, deadline, forB);
        assertTrue(votesB.isActive(keyB[0]), "and fleet B's own works there");
        assertEq(votesA.nonces(alice), 1);
        assertEq(votesB.nonces(alice), 1, "each controller keeps its own nonces");
    }

    /// @dev Invariant: a signed ballot works only in the fleet it was signed for. The two fleets'
    /// proposals 1 have identical terms but different proposal hashes, and a ballot replayed in the
    /// other fleet, signed for the other controller, or naming the other fleet's proposal hash is
    /// refused.
    function test_aSignedBallotForOneFleetIsVoidInAnother() public {
        (KeyfleetManager a, KeyfleetManager b) = _twoFleets();
        KeyfleetVotes votesA = a.VOTES();
        KeyfleetVotes votesB = b.VOTES();
        uint256[] memory keyA = _ids(_key(a, 2));
        uint256[] memory keyB = _ids(_key(b, 2));
        bytes32 hashA = votesA.proposal(1).proposalHash;
        bytes32 hashB = votesB.proposal(1).proposalHash;
        assertTrue(hashA != hashB, "the same terms, a different proposal");
        uint256 deadline = _deadline();

        bytes memory forA = _sign(ALICE_KEY, votesA, _ballotHash(votesA, 1, hashA, keyA, YES, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votesB.castBallotBySig(1, keyA, YES, alice, deadline, forA);

        bytes memory otherController =
            _sign(ALICE_KEY, votesA, _ballotHash(votesB, 1, hashB, keyB, YES, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votesB.castBallotBySig(1, keyB, YES, alice, deadline, otherController);

        bytes memory otherProposal = _sign(ALICE_KEY, votesB, _ballotHash(votesB, 1, hashA, keyB, YES, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.InvalidSignature.selector, alice));
        votesB.castBallotBySig(1, keyB, YES, alice, deadline, otherProposal);
        assertEq(votesB.proposal(1).yes, 0, "no ballot in fleet B");

        votesA.castBallotBySig(1, keyA, YES, alice, deadline, forA);
        bytes memory forB = _sign(ALICE_KEY, votesB, _ballotHash(votesB, 1, hashB, keyB, NO, alice, deadline));
        votesB.castBallotBySig(1, keyB, NO, alice, deadline, forB);
        assertEq(votesA.proposal(1).yes, 1, "fleet A's ballot counts in fleet A");
        assertEq(votesA.proposal(1).no, 0);
        assertEq(votesB.proposal(1).no, 1, "fleet B's in fleet B");
        assertEq(votesB.proposal(1).yes, 0);
    }

    /// @dev Invariant: a signed renewal or ballot naming a key of another fleet is refused with
    /// `ForeignKey` even when its signature is valid for this controller and its signer owns the
    /// key; a batch with one foreign key renews and counts nothing.
    function test_aSignedMessageRefusesAKeyOfAnotherFleet() public {
        (KeyfleetManager a, KeyfleetManager b) = _twoFleets();
        KeyfleetVotes votesA = a.VOTES();
        uint256 ownKey = _key(a, 2);
        uint256 foreign = _key(b, 2);
        uint256[] memory both = _pair(ownKey, foreign);
        uint256 deadline = _deadline();

        bytes memory present = _sign(ALICE_KEY, votesA, _presentHash(votesA, address(a), both, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votesA.presentBySig(both, alice, deadline, present);
        present = _sign(ALICE_KEY, votesA, _presentHash(votesA, address(a), _ids(foreign), alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votesA.presentBySig(_ids(foreign), alice, deadline, present);
        assertFalse(votesA.isActive(ownKey), "nothing renewed");

        bytes32 hashA = votesA.proposal(1).proposalHash;
        bytes memory ballot = _sign(ALICE_KEY, votesA, _ballotHash(votesA, 1, hashA, both, YES, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votesA.castBallotBySig(1, both, YES, alice, deadline, ballot);
        ballot = _sign(ALICE_KEY, votesA, _ballotHash(votesA, 1, hashA, _ids(foreign), YES, alice, deadline));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, foreign));
        votesA.castBallotBySig(1, _ids(foreign), YES, alice, deadline, ballot);
        assertEq(votesA.proposal(1).yes + votesA.proposal(1).late, 0, "nothing counted");
        assertEq(votesA.nonces(alice), 0, "no nonce used");
    }
}
