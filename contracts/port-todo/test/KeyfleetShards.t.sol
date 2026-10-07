// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockRegent} from "./mocks/MockRegent.sol";
import {MockAutolaunchFactory} from "./mocks/MockAutolaunchFactory.sol";
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
    event AgentVotingSet(uint256 indexed tokenId, bool on, uint64 epoch);

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
            new MockRegent(),
            new MockAutolaunchFactory(),
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

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _issue(uint256 tokenId, address wallet, uint16 days_) private {
        vm.prank(fleet.ownerOf(tokenId));
        shards.issue(_ids(tokenId), wallet, days_);
    }

    function _active(uint256 tokenId, address wallet) private view returns (bool) {
        return shards.isActive(tokenId, wallet);
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
    /// the key's current ownership; the record says so and the key's delegation revision rises.
    function test_anOwnerIssuesAShard() public {
        uint64 expiresAt = START + 30 days;
        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardIssued(1, carol, expiresAt, 1);
        vm.prank(alice);
        shards.issue(_ids(1), carol, 30);

        (uint64 recordedExpiry, uint64 epoch, bool active) = shards.shardOf(1, carol);
        assertEq(recordedExpiry, expiresAt, "Thirty days from now");
        assertEq(epoch, fleet.ownershipEpoch(1), "The key's current ownership");
        assertEq(epoch, 1, "A key's first ownership is its mint");
        assertTrue(active);
        assertEq(shards.delegationRevision(1), 1, "The key's revision rose");
        assertEq(shards.delegationRevision(2), 0, "Another key's did not");
    }

    function test_aWalletThatNeverHeldAShardReadsAllZero() public view {
        (uint64 expiresAt, uint64 epoch, bool active) = shards.shardOf(1, dave);
        assertEq(expiresAt, 0);
        assertEq(epoch, 0);
        assertFalse(active);
    }

    /// @dev Invariant: a shard lasts from one day to a year, both ends included.
    function test_aShardLastsOneToThreeHundredSixtyFiveDays() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, 0));
        shards.issue(_ids(1), carol, 0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, 366));
        shards.issue(_ids(1), carol, 366);

        shards.issue(_ids(1), carol, 1);
        shards.issue(_ids(1), dave, 365);
        vm.stopPrank();

        (uint64 shortest,,) = shards.shardOf(1, carol);
        (uint64 longest,,) = shards.shardOf(1, dave);
        assertEq(shortest, START + 1 days, "One day");
        assertEq(longest, START + 365 days, "A year");
    }

    function testFuzz_aShardExpiresExactlyItsDaysLater(uint16 days_, uint32 startOffset) public {
        days_ = uint16(bound(days_, 1, 365));
        vm.warp(START + startOffset);

        _issue(1, carol, days_);

        (uint64 expiresAt,,) = shards.shardOf(1, carol);
        assertEq(expiresAt, START + uint256(startOffset) + uint256(days_) * 1 days);
        vm.warp(uint256(expiresAt) - 1);
        assertTrue(_active(1, carol), "Active until its last second");
        vm.warp(expiresAt);
        assertFalse(_active(1, carol), "And not at its expiry");
    }

    /// @dev Invariant: only the key's current owner issues its shards. An approved operator, a
    /// holder of another key and a stranger may not, a key not yet sold has no owner to, and a batch
    /// with one such key issues none.
    function test_onlyTheKeysOwnerIssuesItsShards() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(_ids(1), carol, 30);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(_pair(2, 1), carol, 30);

        vm.prank(alice);
        fleet.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(_ids(1), carol, 30);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 3));
        shards.issue(_pair(1, 3), carol, 30);

        vm.prank(alice);
        vm.expectRevert(KeyfleetShards.NoKeys.selector);
        shards.issue(new uint256[](0), carol, 30);

        assertFalse(_active(1, carol) || _active(2, carol), "Nothing was issued");
    }

    function test_aShardGoesToAnotherWallet() public {
        vm.startPrank(alice);
        vm.expectRevert(KeyfleetShards.ZeroAddress.selector);
        shards.issue(_ids(1), address(0), 30);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.WalletIsOwner.selector, alice));
        shards.issue(_ids(1), alice, 30);
        vm.stopPrank();
    }

    /// @dev Invariant: shards stack. One wallet holds active shards of many keys, from one owner in
    /// one call or from several owners, a key may have shards in many wallets, and each shard is
    /// read for its own key.
    function test_oneWalletHoldsShardsOfManyKeys() public {
        _buy(fleet, alice); // key 3
        vm.prank(alice);
        shards.issue(_pair(1, 3), carol, 30);
        _issue(2, carol, 60);
        _issue(1, dave, 10);

        assertTrue(_active(1, carol) && _active(2, carol) && _active(3, carol), "Carol holds three keys' shards");
        assertTrue(_active(1, dave), "Key 1 has two");
        assertFalse(_active(2, dave), "Dave holds nothing of key 2");
        (uint64 fromBob,,) = shards.shardOf(2, carol);
        assertEq(fromBob, START + 60 days, "Each shard keeps its own time");
        assertEq(shards.delegationRevision(1), 2, "Two issues of key 1");
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

        (uint64 renewedUntil, uint64 epoch, bool active) = shards.shardOf(1, carol);
        assertEq(renewedUntil, expiresAt, "Counted from the renewal");
        assertEq(epoch, 1, "Same ownership");
        assertTrue(active, "Still active");
        assertEq(shards.delegationRevision(1), 2);
    }

    // --- 3. ending -------------------------------------------------------

    function test_theOwnerEndsShards() public {
        _buy(fleet, alice); // key 3
        vm.prank(alice);
        shards.issue(_pair(1, 3), carol, 30);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardEnded(1, carol, alice);
        vm.prank(alice);
        shards.end(_pair(1, 3), carol);

        (uint64 expiresAt, uint64 epoch, bool active) = shards.shardOf(1, carol);
        assertFalse(active || _active(3, carol), "Both ended");
        assertEq(expiresAt, START + 30 days, "The record stays readable");
        assertEq(epoch, 1);
        assertEq(shards.delegationRevision(1), 2, "Ending raises the revision");
    }

    function test_theWalletStepsDown() public {
        _issue(1, carol, 30);
        _issue(2, carol, 30);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardEnded(2, carol, carol);
        vm.prank(carol);
        shards.end(_pair(1, 2), carol);

        assertFalse(_active(1, carol) || _active(2, carol));
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
            shards.end(_ids(1), carol);
        }
        assertTrue(_active(1, carol), "Still active");
    }

    /// @dev Invariant: only an active shard can be ended: not one of a key the wallet holds none
    /// of, not one already ended or expired, and not one never issued.
    function test_onlyAnActiveShardEnds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, carol));
        shards.end(_ids(1), carol);

        _issue(1, carol, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 2, carol));
        shards.end(_ids(2), carol);

        vm.prank(carol);
        shards.end(_ids(1), carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, carol));
        shards.end(_ids(1), carol);

        _issue(1, dave, 1);
        vm.warp(START + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, dave));
        shards.end(_ids(1), dave);
    }

    // --- 4. a sale ends every shard ----------------------------------------

    /// @dev Invariant: when a key changes hands every shard it issued stops at once, with no call
    /// to the record. The old owner can no longer issue or end them, the new owner issues their
    /// own, and moving the key back does not revive the old ones.
    function test_aSaleEndsEveryShardOfTheKey() public {
        _issue(1, carol, 30);
        _issue(1, dave, 30);
        _issue(2, carol, 30);

        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);

        assertFalse(_active(1, carol), "Carol's shard of key 1 ended with the sale");
        assertFalse(_active(1, dave), "And Dave's");
        assertTrue(_active(2, carol), "Carol's shard of another key is untouched");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, bob));
        shards.issue(_ids(1), carol, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, 1, carol));
        shards.end(_ids(1), carol);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardIssued(1, carol, START + 10 days, 2);
        vm.prank(bob);
        shards.issue(_ids(1), carol, 10);
        (, uint64 epoch, bool active) = shards.shardOf(1, carol);
        assertEq(epoch, 2, "Issued under the new ownership");
        assertTrue(active);

        vm.prank(bob);
        fleet.transferFrom(bob, alice, 1);
        assertFalse(_active(1, carol), "Bob's shard ends when he sells");
        assertFalse(_active(1, dave), "And Alice's old one stays ended");
    }

    /// @dev Invariant: the former owner of a key may hold a shard of it from the new owner.
    function test_aFormerOwnerMayHoldAShardOfTheKey() public {
        vm.prank(alice);
        fleet.transferFrom(alice, carol, 1);

        _issue(1, alice, 30);
        assertTrue(_active(1, alice));
    }

    // --- 5. agent voting ---------------------------------------------------

    /// @dev Invariant: agent voting is on for every key until its owner turns it off, which only
    /// the owner may do, for many keys in one call. A shard governs its key exactly while it is
    /// active and the key's agent voting is on, and each switch raises the key's revision.
    function test_agentVotingIsOnUntilTheOwnerTurnsItOff() public {
        _buy(fleet, alice); // key 3
        vm.prank(alice);
        shards.issue(_pair(1, 3), carol, 30);
        assertTrue(shards.agentVoting(1) && shards.agentVoting(2), "On by default");
        assertTrue(shards.mayGovern(1, carol));
        assertFalse(shards.mayGovern(2, carol), "No shard, no say");

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.setAgentVoting(_ids(1), false);
        vm.prank(alice);
        fleet.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.setAgentVoting(_ids(1), false);
        vm.prank(alice);
        vm.expectRevert(KeyfleetShards.NoKeys.selector);
        shards.setAgentVoting(new uint256[](0), false);

        vm.expectEmit(true, true, true, true, address(shards));
        emit AgentVotingSet(3, false, 1);
        vm.prank(alice);
        shards.setAgentVoting(_pair(1, 3), false);
        assertFalse(shards.agentVoting(1) || shards.agentVoting(3), "Off for both");
        assertFalse(shards.mayGovern(1, carol), "The shard no longer governs");
        assertTrue(_active(1, carol), "But it is still active");
        assertEq(shards.delegationRevision(1), 2, "Issue, then off");

        vm.prank(alice);
        shards.setAgentVoting(_ids(1), true);
        assertTrue(shards.mayGovern(1, carol), "On again");
        assertFalse(shards.mayGovern(3, carol), "Key 3 stays off");
        assertEq(shards.delegationRevision(1), 3);
    }

    /// @dev Invariant: a new owner always starts with agent voting on, whatever the last owner
    /// chose, and moving the key back does not bring the old choice back.
    function test_aNewOwnerStartsWithAgentVotingOn() public {
        vm.prank(alice);
        shards.setAgentVoting(_ids(1), false);
        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);
        assertTrue(shards.agentVoting(1), "On for Bob");

        vm.prank(bob);
        shards.issue(_ids(1), carol, 30);
        assertTrue(shards.mayGovern(1, carol), "Bob's shard governs without a switch");

        vm.prank(bob);
        fleet.transferFrom(bob, alice, 1);
        assertTrue(shards.agentVoting(1), "Alice's old choice does not come back");
    }

    // --- 6. a shard never controls the key itself -------------------------

    /// @dev Invariant: a shard is a record only: its wallet cannot move the key, issue shards of it
    /// or switch its agent voting.
    function test_aShardCarriesNoControlOfTheKey() public {
        _issue(1, carol, 30);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, carol, 1));
        fleet.transferFrom(alice, carol, 1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.issue(_ids(1), dave, 30);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, 1, alice));
        shards.setAgentVoting(_ids(1), true);
    }
}
