// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

contract KeyfleetShardsTest is KeyfleetFixture {
    uint64 private constant START = 1_000_000;

    KeyfleetManager private fleet;
    /// @dev Keys 1 and 2 of the founding Classic fleet, held by Alice and Bob.
    uint256 private k1;
    uint256 private k2;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);
    address private mallory = address(0x4A11);

    event ShardIssued(uint256 indexed tokenId, address indexed wallet, uint64 expiresAt, uint64 epoch);
    event ShardEnded(uint256 indexed tokenId, address indexed wallet, address indexed by);
    event AgentVotingSet(uint256 indexed tokenId, bool on, uint64 epoch);

    function setUp() public {
        vm.warp(START);
        vm.roll(1_000);
        _setUpFixture();
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        k1 = _buy(fleet, alice);
        k2 = _buy(fleet, bob);
    }

    // --- helpers ---------------------------------------------------------

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _issue(uint256 tokenId, address wallet, uint16 days_) private {
        vm.prank(keys.ownerOf(tokenId));
        shards.issue(_ids(tokenId), wallet, days_);
    }

    function _active(uint256 tokenId, address wallet) private view returns (bool) {
        return shards.isActive(tokenId, wallet);
    }

    // --- 1. wiring -------------------------------------------------------

    /// @dev Invariant: one shard record serves every fleet, bound for good to the one collection,
    /// and every fleet's voting controller and ledger read it.
    function test_everyFleetSharesOneShardRecordBoundToTheCollection() public {
        assertEq(address(shards.KEYS()), address(keys), "The record is the collection's");
        assertEq(address(factory.SHARDS()), address(shards), "The factory names it");
        assertEq(shards.MIN_DAYS(), 1);
        assertEq(shards.MAX_DAYS(), 365);

        KeyfleetManager open = _createOpen(KeyfleetPresets.Preset.FibonacciCascade, 10e6);
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            KeyfleetManager manager = KeyfleetManager(keys.managerOf(id));
            assertEq(address(manager.VOTES().SHARDS()), address(shards), "Every fleet's votes read it");
            assertEq(address(manager.REWARDS().SHARDS()), address(shards), "Every fleet's ledger reads it");
        }
        assertEq(keys.managerOf(keys.fleetCount()), address(open), "An open fleet included");
    }

    function test_aRecordWithoutACollectionIsRefused() public {
        vm.expectRevert(KeyfleetShards.ZeroAddress.selector);
        new KeyfleetShards(KeyfleetKeys(address(0)));
    }

    // --- 2. issuing ------------------------------------------------------

    /// @dev Invariant: a key's owner issues a shard to a wallet for a whole number of days, under
    /// the key's current ownership; the record says so and the key's delegation revision rises.
    function test_anOwnerIssuesAShard() public {
        uint64 expiresAt = START + 30 days;
        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardIssued(k1, carol, expiresAt, 1);
        vm.prank(alice);
        shards.issue(_ids(k1), carol, 30);

        (uint64 recordedExpiry, uint64 epoch, bool active) = shards.shardOf(k1, carol);
        assertEq(recordedExpiry, expiresAt, "Thirty days from now");
        assertEq(epoch, keys.ownershipEpoch(k1), "The key's current ownership");
        assertEq(epoch, 1, "A key's first ownership is its mint");
        assertTrue(active);
        assertEq(shards.delegationRevision(k1), 1, "The key's revision rose");
        assertEq(shards.delegationRevision(k2), 0, "Another key's did not");
    }

    function test_aWalletThatNeverHeldAShardReadsAllZero() public view {
        (uint64 expiresAt, uint64 epoch, bool active) = shards.shardOf(k1, dave);
        assertEq(expiresAt, 0);
        assertEq(epoch, 0);
        assertFalse(active);
    }

    /// @dev Invariant: a shard lasts from one day to a year, both ends included.
    function test_aShardLastsOneToThreeHundredSixtyFiveDays() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, 0));
        shards.issue(_ids(k1), carol, 0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.DaysOutOfRange.selector, 366));
        shards.issue(_ids(k1), carol, 366);

        shards.issue(_ids(k1), carol, 1);
        shards.issue(_ids(k1), dave, 365);
        vm.stopPrank();

        (uint64 shortest,,) = shards.shardOf(k1, carol);
        (uint64 longest,,) = shards.shardOf(k1, dave);
        assertEq(shortest, START + 1 days, "One day");
        assertEq(longest, START + 365 days, "A year");
    }

    function testFuzz_aShardExpiresExactlyItsDaysLater(uint16 days_, uint32 startOffset) public {
        days_ = uint16(bound(days_, 1, 365));
        vm.warp(START + startOffset);

        _issue(k1, carol, days_);

        (uint64 expiresAt,,) = shards.shardOf(k1, carol);
        assertEq(expiresAt, START + uint256(startOffset) + uint256(days_) * 1 days);
        vm.warp(uint256(expiresAt) - 1);
        assertTrue(_active(k1, carol), "Active until its last second");
        vm.warp(expiresAt);
        assertFalse(_active(k1, carol), "And not at its expiry");
    }

    /// @dev Invariant: only the key's current owner issues its shards. An approved operator, a
    /// holder of another key and a stranger may not, a key not yet sold has no owner to, and a batch
    /// with one such key issues none.
    function test_onlyTheKeysOwnerIssuesItsShards() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.issue(_ids(k1), carol, 30);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.issue(_pair(k2, k1), carol, 30);

        vm.prank(alice);
        keys.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.issue(_ids(k1), carol, 30);

        uint256 k3 = _key(fleet, 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, k3));
        shards.issue(_pair(k1, k3), carol, 30);

        vm.prank(alice);
        vm.expectRevert(KeyfleetShards.NoKeys.selector);
        shards.issue(new uint256[](0), carol, 30);

        assertFalse(_active(k1, carol) || _active(k2, carol), "Nothing was issued");
    }

    function test_aShardGoesToAnotherWallet() public {
        vm.startPrank(alice);
        vm.expectRevert(KeyfleetShards.ZeroAddress.selector);
        shards.issue(_ids(k1), address(0), 30);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.WalletIsOwner.selector, alice));
        shards.issue(_ids(k1), alice, 30);
        vm.stopPrank();
    }

    /// @dev Invariant: shards stack. One wallet holds active shards of many keys, from one owner in
    /// one call or from several owners, a key may have shards in many wallets, and each shard is
    /// read for its own key.
    function test_oneWalletHoldsShardsOfManyKeys() public {
        uint256 k3 = _buy(fleet, alice);
        vm.prank(alice);
        shards.issue(_pair(k1, k3), carol, 30);
        _issue(k2, carol, 60);
        _issue(k1, dave, 10);

        assertTrue(_active(k1, carol) && _active(k2, carol) && _active(k3, carol), "Carol holds three keys' shards");
        assertTrue(_active(k1, dave), "Key 1 has two");
        assertFalse(_active(k2, dave), "Dave holds nothing of key 2");
        (uint64 fromBob,,) = shards.shardOf(k2, carol);
        assertEq(fromBob, START + 60 days, "Each shard keeps its own time");
        assertEq(shards.delegationRevision(k1), 2, "Two issues of key 1");
    }

    /// @dev Invariant: the key's owner renews an active shard by issuing it again, which counts its
    /// days from now and keeps the key's ownership.
    function test_theOwnerRenewsAnActiveShard() public {
        _issue(k1, carol, 30);
        vm.warp(block.timestamp + 20 days);

        uint64 expiresAt = uint64(block.timestamp + 60 days);
        vm.expectEmit(address(shards));
        emit ShardIssued(k1, carol, expiresAt, 1);
        _issue(k1, carol, 60);

        (uint64 renewedUntil, uint64 epoch, bool active) = shards.shardOf(k1, carol);
        assertEq(renewedUntil, expiresAt, "Counted from the renewal");
        assertEq(epoch, 1, "Same ownership");
        assertTrue(active, "Still active");
        assertEq(shards.delegationRevision(k1), 2);
    }

    // --- 3. ending -------------------------------------------------------

    function test_theOwnerEndsShards() public {
        uint256 k3 = _buy(fleet, alice);
        vm.prank(alice);
        shards.issue(_pair(k1, k3), carol, 30);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardEnded(k1, carol, alice);
        vm.prank(alice);
        shards.end(_pair(k1, k3), carol);

        (uint64 expiresAt, uint64 epoch, bool active) = shards.shardOf(k1, carol);
        assertFalse(active || _active(k3, carol), "Both ended");
        assertEq(expiresAt, START + 30 days, "The record stays readable");
        assertEq(epoch, 1);
        assertEq(shards.delegationRevision(k1), 2, "Ending raises the revision");
    }

    function test_theWalletStepsDown() public {
        _issue(k1, carol, 30);
        _issue(k2, carol, 30);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardEnded(k2, carol, carol);
        vm.prank(carol);
        shards.end(_pair(k1, k2), carol);

        assertFalse(_active(k1, carol) || _active(k2, carol));
    }

    /// @dev Invariant: nobody but the key's owner and the shard's wallet ends a shard: not another
    /// key's owner, not an approved operator and not another shard holder of the same key.
    function test_nobodyElseEndsAShard() public {
        _issue(k1, carol, 30);
        _issue(k1, dave, 30);
        vm.prank(alice);
        keys.setApprovalForAll(mallory, true);

        address[3] memory others = [bob, mallory, dave];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotAllowedToEnd.selector, k1, carol, others[i]));
            shards.end(_ids(k1), carol);
        }
        assertTrue(_active(k1, carol), "Still active");
    }

    /// @dev Invariant: only an active shard can be ended: not one of a key the wallet holds none
    /// of, not one already ended or expired, and not one never issued.
    function test_onlyAnActiveShardEnds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, k1, carol));
        shards.end(_ids(k1), carol);

        _issue(k1, carol, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, k2, carol));
        shards.end(_ids(k2), carol);

        vm.prank(carol);
        shards.end(_ids(k1), carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, k1, carol));
        shards.end(_ids(k1), carol);

        _issue(k1, dave, 1);
        vm.warp(START + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, k1, dave));
        shards.end(_ids(k1), dave);
    }

    // --- 4. a sale ends every shard ----------------------------------------

    /// @dev Invariant: when a key changes hands every shard it issued stops at once, with no call
    /// to the record. The old owner can no longer issue or end them, the new owner issues their
    /// own, and moving the key back does not revive the old ones.
    function test_aSaleEndsEveryShardOfTheKey() public {
        _issue(k1, carol, 30);
        _issue(k1, dave, 30);
        _issue(k2, carol, 30);

        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);

        assertFalse(_active(k1, carol), "Carol's shard of key 1 ended with the sale");
        assertFalse(_active(k1, dave), "And Dave's");
        assertTrue(_active(k2, carol), "Carol's shard of another key is untouched");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, bob));
        shards.issue(_ids(k1), carol, 30);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.ShardNotActive.selector, k1, carol));
        shards.end(_ids(k1), carol);

        vm.expectEmit(true, true, true, true, address(shards));
        emit ShardIssued(k1, carol, START + 10 days, 2);
        vm.prank(bob);
        shards.issue(_ids(k1), carol, 10);
        (, uint64 epoch, bool active) = shards.shardOf(k1, carol);
        assertEq(epoch, 2, "Issued under the new ownership");
        assertTrue(active);

        vm.prank(bob);
        keys.transferFrom(bob, alice, k1);
        assertFalse(_active(k1, carol), "Bob's shard ends when he sells");
        assertFalse(_active(k1, dave), "And Alice's old one stays ended");
    }

    /// @dev Invariant: the former owner of a key may hold a shard of it from the new owner.
    function test_aFormerOwnerMayHoldAShardOfTheKey() public {
        vm.prank(alice);
        keys.transferFrom(alice, carol, k1);

        _issue(k1, alice, 30);
        assertTrue(_active(k1, alice));
    }

    // --- 5. agent voting ---------------------------------------------------

    /// @dev Invariant: agent voting is on for every key until its owner turns it off, which only
    /// the owner may do, for many keys in one call. A shard governs its key exactly while it is
    /// active and the key's agent voting is on, and each switch raises the key's revision.
    function test_agentVotingIsOnUntilTheOwnerTurnsItOff() public {
        uint256 k3 = _buy(fleet, alice);
        vm.prank(alice);
        shards.issue(_pair(k1, k3), carol, 30);
        assertTrue(shards.agentVoting(k1) && shards.agentVoting(k2), "On by default");
        assertTrue(shards.mayGovern(k1, carol));
        assertFalse(shards.mayGovern(k2, carol), "No shard, no say");

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.setAgentVoting(_ids(k1), false);
        vm.prank(alice);
        keys.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.setAgentVoting(_ids(k1), false);
        vm.prank(alice);
        vm.expectRevert(KeyfleetShards.NoKeys.selector);
        shards.setAgentVoting(new uint256[](0), false);

        vm.expectEmit(true, true, true, true, address(shards));
        emit AgentVotingSet(k3, false, 1);
        vm.prank(alice);
        shards.setAgentVoting(_pair(k1, k3), false);
        assertFalse(shards.agentVoting(k1) || shards.agentVoting(k3), "Off for both");
        assertFalse(shards.mayGovern(k1, carol), "The shard no longer governs");
        assertTrue(_active(k1, carol), "But it is still active");
        assertEq(shards.delegationRevision(k1), 2, "Issue, then off");

        vm.prank(alice);
        shards.setAgentVoting(_ids(k1), true);
        assertTrue(shards.mayGovern(k1, carol), "On again");
        assertFalse(shards.mayGovern(k3, carol), "Key 3 stays off");
        assertEq(shards.delegationRevision(k1), 3);
    }

    /// @dev Invariant: a new owner always starts with agent voting on, whatever the last owner
    /// chose, and moving the key back does not bring the old choice back.
    function test_aNewOwnerStartsWithAgentVotingOn() public {
        vm.prank(alice);
        shards.setAgentVoting(_ids(k1), false);
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        assertTrue(shards.agentVoting(k1), "On for Bob");

        vm.prank(bob);
        shards.issue(_ids(k1), carol, 30);
        assertTrue(shards.mayGovern(k1, carol), "Bob's shard governs without a switch");

        vm.prank(bob);
        keys.transferFrom(bob, alice, k1);
        assertTrue(shards.agentVoting(k1), "Alice's old choice does not come back");
    }

    // --- 6. a shard never controls the key itself -------------------------

    /// @dev Invariant: a shard is a record only: its wallet cannot move the key, issue shards of it
    /// or switch its agent voting.
    function test_aShardCarriesNoControlOfTheKey() public {
        _issue(k1, carol, 30);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, carol, k1));
        keys.transferFrom(alice, carol, k1);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.issue(_ids(k1), dave, 30);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetShards.NotKeyOwner.selector, k1, alice));
        shards.setAgentVoting(_ids(k1), true);
    }

    // --- 7. one record, many fleets: a shard reaches only its key's fleet ----

    /// @dev Invariant: a shard of a fleet-A key authorises its wallet in fleet A only. In fleet B,
    /// here an open fleet of the same type whose key 1 shares the key number, the same wallet can
    /// neither mark keys present, propose, vote nor claim, whether it names the fleet-A key or the
    /// fleet-B key of the same number. The shard ends when its key moves, and the wallet's shard of
    /// a fleet-B key does not.
    function test_aShardOfOneFleetsKeyAuthorisesNothingInAnotherFleet() public {
        KeyfleetManager fleetB = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        _mature();
        uint256 b1 = _key(fleetB, 1);
        assertEq(keys.keyNumberOf(b1), keys.keyNumberOf(k1), "The two keys share their number");
        KeyfleetVotes votesA = fleet.VOTES();
        KeyfleetVotes votesB = fleetB.VOTES();
        KeyfleetRewards rewardsA = fleet.REWARDS();
        KeyfleetRewards rewardsB = fleetB.REWARDS();
        KeyfleetTreasury.Call[] memory none = new KeyfleetTreasury.Call[](0);
        address[] memory usdcOnly = new address[](1);
        usdcOnly[0] = address(usdc);

        _issue(k1, carol, 30);
        assertTrue(shards.mayGovern(k1, carol), "Carol may govern fleet A's key 1");
        vm.prank(creator);
        uint256 proposalB = votesB.propose(b1, keccak256("fleet B"), none);

        bytes memory foreignA = abi.encodeWithSelector(KeyfleetVotes.ForeignKey.selector, k1);
        bytes memory notCarolsB = abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, b1, carol);
        vm.startPrank(carol);
        vm.expectRevert(foreignA);
        votesB.present(_ids(k1));
        vm.expectRevert(notCarolsB);
        votesB.present(_ids(b1));
        vm.expectRevert(foreignA);
        votesB.propose(k1, keccak256("fleet A key in fleet B"), none);
        vm.expectRevert(notCarolsB);
        votesB.propose(b1, keccak256("fleet B key"), none);
        vm.expectRevert(foreignA);
        votesB.castBallot(proposalB, _ids(k1), KeyfleetVotes.Choice.Yes);
        vm.expectRevert(notCarolsB);
        votesB.castBallot(proposalB, _ids(b1), KeyfleetVotes.Choice.Yes);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.ForeignKey.selector, k1));
        rewardsB.claim(_ids(k1), usdcOnly);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, b1));
        rewardsB.claim(_ids(b1), usdcOnly);

        // In fleet A the same shard works.
        votesA.present(_ids(k1));
        uint256 proposalA = votesA.propose(k1, keccak256("fleet A"), none);
        votesA.castBallot(proposalA, _ids(k1), KeyfleetVotes.Choice.Yes);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewardsA.claim(_ids(k1), usdcOnly);
        vm.stopPrank();
        assertEq(
            uint256(votesB.ballotOf(proposalB, b1)), uint256(KeyfleetVotes.Choice.None), "Nothing was cast in fleet B"
        );
        assertEq(
            uint256(votesA.ballotOf(proposalA, k1)), uint256(KeyfleetVotes.Choice.Yes), "Carol voted fleet A's key"
        );

        // Carol also holds a shard of fleet B's key 1. Fleet A's key 1 moves: only its shard ends.
        _issue(b1, carol, 30);
        vm.prank(alice);
        keys.transferFrom(alice, dave, k1);
        assertFalse(_active(k1, carol), "The fleet-A shard ended with the move");
        assertTrue(_active(b1, carol), "The fleet-B shard of the same number did not");

        bytes memory notCarolsA = abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, k1, carol);
        vm.startPrank(carol);
        vm.expectRevert(notCarolsA);
        votesA.present(_ids(k1));
        vm.expectRevert(notCarolsA);
        votesA.castBallot(proposalA, _ids(k1), KeyfleetVotes.Choice.No);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, k1));
        rewardsA.claim(_ids(k1), usdcOnly);
        votesB.present(_ids(b1));
        vm.stopPrank();
    }
}
