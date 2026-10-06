// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";

contract KeyfleetShardsTest is Test {
    uint64 private constant START = 1_000_000;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    Keyfleet private fleet;
    KeyfleetShards private shards;

    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);
    address private mallory = address(0x4A11);

    event ShardIssued(uint256 indexed tokenId, address indexed wallet, uint64 expiresAt, uint64 epoch);
    event ShardEnded(uint256 indexed tokenId, address indexed wallet, address indexed by);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(START);
        vm.roll(1_000);
        fleet = _deploy();
        shards = fleet.SHARDS();
        _buy(fleet, alice); // key 1
        _buy(fleet, bob); // key 2
    }

    // --- helpers ---------------------------------------------------------

    function _deploy() private returns (Keyfleet deployed) {
        deployed = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            new MockRegentRevenueStaking(usdc),
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(deployed));
    }

    function _buy(Keyfleet target, address receiver) private returns (uint256 tokenId) {
        uint256 price = target.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(target), price);
        tokenId = target.purchase(receiver, price, block.timestamp);
        vm.stopPrank();
    }

    function _issue(uint256 tokenId, address wallet, uint16 days_) private {
        vm.prank(fleet.ownerOf(tokenId));
        shards.issue(tokenId, wallet, days_);
    }

    function _active(address wallet) private view returns (bool active) {
        (,,, active) = shards.shardOf(wallet);
    }

    // --- 1. wiring -------------------------------------------------------

    /// @dev Invariant: a fleet and its shard record are born together and bound for good.
    function test_theFleetDeploysItsOwnShardRecord() public view {
        assertEq(address(shards.FLEET()), address(fleet), "The record is the fleet's own");
        assertEq(shards.MIN_DAYS(), 1);
        assertEq(shards.MAX_DAYS(), 365);
    }

    function test_aRecordWithoutAFleetIsRefused() public {
        vm.expectRevert(KeyfleetShards.ZeroAddress.selector);
        new KeyfleetShards(Keyfleet(address(0)));
    }

    // --- 2. issuing ------------------------------------------------------

    /// @dev Invariant: a key's owner issues a shard to a wallet for a whole number of days, under
    /// the key's current ownership, and the record says so.
    function test_anOwnerIssuesAShard() public {
        uint64 expiresAt = START + 30 days;
        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardIssued(1, carol, expiresAt, 1);
        vm.prank(alice);
        shards.issue(1, carol, 30);

        (uint256 tokenId, uint64 recordedExpiry, uint64 epoch, bool active) = shards.shardOf(carol);
        assertEq(tokenId, 1, "The key that issued it");
        assertEq(recordedExpiry, expiresAt, "Thirty days from now");
        assertEq(epoch, fleet.ownershipEpoch(1), "The key's current ownership");
        assertEq(epoch, 1, "A key's first ownership is its mint");
        assertTrue(active);
    }

    function test_aWalletThatNeverHeldAShardReadsAllZero() public view {
        (uint256 tokenId, uint64 expiresAt, uint64 epoch, bool active) = shards.shardOf(dave);
        assertEq(tokenId, 0);
        assertEq(expiresAt, 0);
        assertEq(epoch, 0);
        assertFalse(active);
    }

    /// @dev Invariant: a shard lasts from one day to a year, both ends included.
    function test_aShardLastsOneToThreeHundredSixtyFiveDays() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, 0));
        shards.issue(1, carol, 0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, 366));
        shards.issue(1, carol, 366);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, type(uint16).max));
        shards.issue(1, carol, type(uint16).max);

        shards.issue(1, carol, 1);
        shards.issue(1, dave, 365);
        vm.stopPrank();

        (, uint64 shortest,,) = shards.shardOf(carol);
        (, uint64 longest,,) = shards.shardOf(dave);
        assertEq(shortest, START + 1 days, "One day");
        assertEq(longest, START + 365 days, "A year");
    }

    function testFuzz_aShardExpiresExactlyItsDaysLater(uint16 days_, uint32 startOffset) public {
        days_ = uint16(bound(days_, 1, 365));
        vm.warp(START + startOffset);

        _issue(1, carol, days_);

        (, uint64 expiresAt,,) = shards.shardOf(carol);
        assertEq(expiresAt, START + uint256(startOffset) + uint256(days_) * 1 days);
        vm.warp(uint256(expiresAt) - 1);
        assertTrue(_active(carol), "Active until its last second");
        vm.warp(expiresAt);
        assertFalse(_active(carol), "And not at its expiry");
    }

    /// @dev Invariant: only the key's current owner issues its shards. An approved operator, a
    /// holder of another key and a stranger may not, and a key not yet sold has no owner to.
    function test_onlyTheKeysOwnerIssuesItsShards() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(1, carol, 30);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(1, carol, 30);

        vm.prank(alice);
        fleet.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(1, carol, 30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 3));
        shards.issue(3, carol, 30);

        assertFalse(_active(carol), "Nothing was issued");
    }

    function test_aShardGoesToAnotherWallet() public {
        vm.startPrank(alice);
        vm.expectRevert(KeyfleetShards.ZeroAddress.selector);
        shards.issue(1, address(0), 30);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.WalletIsOwner.selector, alice));
        shards.issue(1, alice, 30);
        vm.stopPrank();
    }

    /// @dev Invariant: a wallet answers for one key at a time in a fleet. While its shard is
    /// active no other key can issue it one; a key may have many.
    function test_aWalletHoldsOneActiveShardPerFleet() public {
        _issue(1, carol, 30);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardAlreadyActive.selector, carol, 1));
        shards.issue(2, carol, 60);

        _issue(1, dave, 30);
        _issue(1, mallory, 30);
        assertTrue(_active(carol) && _active(dave) && _active(mallory), "One key, three shards");
        (uint256 tokenId,,,) = shards.shardOf(carol);
        assertEq(tokenId, 1, "The first shard stands");
    }

    /// @dev Invariant: the key's owner renews an active shard by issuing it again, which counts its
    /// days from now and keeps the key's ownership.
    function test_theOwnerRenewsAnActiveShard() public {
        _issue(1, carol, 30);
        vm.warp(block.timestamp + 20 days);

        uint64 expiresAt = uint64(block.timestamp + 60 days);
        vm.expectEmit(address(shards));
        emit ShardIssued(1, carol, expiresAt, 1);
        _issue(1, carol, 60);

        (uint256 tokenId, uint64 renewedUntil, uint64 epoch, bool active) = shards.shardOf(carol);
        assertEq(tokenId, 1, "Same key");
        assertEq(renewedUntil, expiresAt, "Counted from the renewal");
        assertEq(epoch, 1, "Same ownership");
        assertTrue(active, "Still active");
    }

    /// @dev Invariant: the one-shard rule is per fleet; another fleet's record is its own.
    function test_aWalletMayHoldAShardInEachFleet() public {
        Keyfleet second = _deploy();
        KeyfleetShards secondShards = second.SHARDS();
        _buy(second, alice);
        _issue(1, carol, 30);

        vm.prank(alice);
        secondShards.issue(1, carol, 30);

        (,,, bool active) = secondShards.shardOf(carol);
        assertTrue(active && _active(carol), "Active in both fleets");
    }

    /// @dev Invariant: once a shard expires or ends, the wallet may be issued a fresh one, by any
    /// key, which replaces the old record.
    function test_aWalletIsIssuedAFreshShardOnceItsLastIsInactive() public {
        _issue(1, carol, 1);
        vm.warp(START + 1 days);
        assertFalse(_active(carol), "Expired");

        _issue(2, carol, 7);
        (uint256 tokenId, uint64 expiresAt,,) = shards.shardOf(carol);
        assertEq(tokenId, 2, "Now answers for key 2");
        assertEq(expiresAt, START + 8 days);

        vm.prank(carol);
        shards.end(2, carol);
        _issue(1, carol, 3);
        (tokenId,,,) = shards.shardOf(carol);
        assertEq(tokenId, 1, "And after ending, for key 1 again");
        assertTrue(_active(carol));
    }

    // --- 3. ending -------------------------------------------------------

    function test_theOwnerEndsAShard() public {
        _issue(1, carol, 30);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardEnded(1, carol, alice);
        vm.prank(alice);
        shards.end(1, carol);

        (uint256 tokenId, uint64 expiresAt, uint64 epoch, bool active) = shards.shardOf(carol);
        assertFalse(active, "Ended");
        assertEq(tokenId, 1, "The record stays readable");
        assertEq(expiresAt, START + 30 days);
        assertEq(epoch, 1);
    }

    function test_theWalletStepsDown() public {
        _issue(1, carol, 30);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardEnded(1, carol, carol);
        vm.prank(carol);
        shards.end(1, carol);

        assertFalse(_active(carol));
    }

    /// @dev Invariant: nobody but the key's owner and the shard's wallet ends a shard: not another
    /// key's owner, not an approved operator and not another shard holder of the same key.
    function test_nobodyElseEndsAShard() public {
        _issue(1, carol, 30);
        _issue(1, dave, 30);
        vm.prank(alice);
        fleet.setApprovalForAll(mallory, true);

        address[3] memory others = [bob, mallory, dave];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotAllowedToEnd.selector, 1, carol, others[i]));
            shards.end(1, carol);
        }
        assertTrue(_active(carol), "Still active");
    }

    /// @dev Invariant: only an active shard of the named key can be ended: not one of another
    /// key, not one already ended or expired, and not one never issued.
    function test_onlyAnActiveShardOfTheNamedKeyEnds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, carol));
        shards.end(1, carol);

        _issue(1, carol, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 2, carol));
        shards.end(2, carol);

        vm.prank(carol);
        shards.end(1, carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, carol));
        shards.end(1, carol);

        _issue(1, dave, 1);
        vm.warp(START + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, dave));
        shards.end(1, dave);
    }

    // --- 4. a sale ends every shard ----------------------------------------

    /// @dev Invariant: when a key changes hands every shard it issued stops at once, with no call
    /// to the record. The old owner can no longer issue or end them, the new owner issues their
    /// own, and moving the key back does not revive the old ones.
    function test_aSaleEndsEveryShardOfTheKey() public {
        _issue(1, carol, 30);
        _issue(1, dave, 30);
        _issue(2, mallory, 30);

        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);

        assertFalse(_active(carol), "Carol's shard ended with the sale");
        assertFalse(_active(dave), "And Dave's");
        assertTrue(_active(mallory), "Another key's shard is untouched");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, bob));
        shards.issue(1, carol, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, carol));
        shards.end(1, carol);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardIssued(1, carol, START + 10 days, 2);
        vm.prank(bob);
        shards.issue(1, carol, 10);
        (,, uint64 epoch, bool active) = shards.shardOf(carol);
        assertEq(epoch, 2, "Issued under the new ownership");
        assertTrue(active);

        vm.prank(bob);
        fleet.transferFrom(bob, alice, 1);
        assertFalse(_active(carol), "Bob's shard ends when he sells");
        assertFalse(_active(dave), "And Alice's old one stays ended");
    }

    /// @dev Invariant: the former owner of a key may hold a shard of it from the new owner.
    function test_aFormerOwnerMayHoldAShardOfTheKey() public {
        vm.prank(alice);
        fleet.transferFrom(alice, carol, 1);

        _issue(1, alice, 30);
        assertTrue(_active(alice));
    }

    // --- 5. a shard carries no authority on chain ------------------------

    /// @dev Invariant: a shard is a record only: its wallet cannot vote the key, move it, or
    /// issue shards of it.
    function test_aShardCarriesNoVoteAndNoControlOfTheKey() public {
        _issue(1, carol, 30);
        KeyfleetVotes votes = fleet.VOTES();
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 proposalId = votes.proposeDecision(1, "record it", bytes32(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, alice));
        votes.vote(proposalId, ids, true);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, carol, 1));
        fleet.transferFrom(alice, carol, 1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(1, dave, 30);
    }
}
