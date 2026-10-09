// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

/// @dev The fleet reader in platform/lib/keyfleet/chain/ matches logs by these topics, reads ballots
/// and a proposal's status by these numbers and calls these functions, all written out there by
/// hand. Key events come from the shared key collection, sale and money events from each fleet's
/// manager. If an event's signature, a function's signature or the numbers change, this fails until both
/// sides agree again.
contract KeyfleetVotesTopicsTest is Test {
    function test_ownershipEpochTopic() public pure {
        assertEq(
            KeyfleetKeys.OwnershipEpoch.selector, 0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1
        );
    }

    function test_keyRevealedTopic() public pure {
        assertEq(KeyfleetKeys.KeyRevealed.selector, 0x2641319733d9075c8fb8c0e9c0738513e76e459cba32ba76efd9a29096dc8a24);
    }

    function test_proposalCreatedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalCreated.selector, 0x959c9f8f330ac28b7f4719d751c7fa2d25e7be768c2642037e274c468a0ac796
        );
    }

    function test_ballotCastTopic() public pure {
        assertEq(KeyfleetVotes.BallotCast.selector, 0x8fade46d07f3bc5ab9b6f059a9582a5d1c0c1aea60978623e207da414bb1ee45);
    }

    function test_proposalCancelledTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalCancelled.selector, 0x74c34a008ce735d9fcf0bd03a9b238d212ad4c441c020661f4ffbb6442645b85
        );
    }

    function test_choiceAndStatusNumbers() public pure {
        assertEq(uint8(KeyfleetVotes.Choice.None), 0);
        assertEq(uint8(KeyfleetVotes.Choice.Yes), 1);
        assertEq(uint8(KeyfleetVotes.Choice.No), 2);
        assertEq(uint8(KeyfleetVotes.Choice.Abstain), 3);
        assertEq(uint8(type(KeyfleetVotes.Choice).max), 3);
        assertEq(uint8(KeyfleetVotes.Status.Open), 0);
        assertEq(uint8(KeyfleetVotes.Status.Waiting), 1);
        assertEq(uint8(KeyfleetVotes.Status.Approved), 2);
        assertEq(uint8(KeyfleetVotes.Status.Rejected), 3);
        assertEq(uint8(KeyfleetVotes.Status.Cancelled), 4);
        assertEq(uint8(KeyfleetVotes.Status.Executed), 5);
        assertEq(uint8(KeyfleetVotes.Status.ExecutionExpired), 6);
        assertEq(uint8(type(KeyfleetVotes.Status).max), 6);
    }

    function test_forwardedToTreasuryTopic() public pure {
        assertEq(
            KeyfleetManager.ForwardedToTreasury.selector,
            0x8926b565a570cae7e82c2dcc861e6aeea283665a938a403f59ee2a13bcc83d81
        );
    }

    /// @dev The treasury reader's balance reads, one call each at the same block. The fleet's
    /// capital is the token balance of the address the manager's `TREASURY` returns. A public
    /// mapping or variable's getter is only reachable through an instance, so those are named
    /// through one at address zero, which is never called.
    function test_treasuryViewSelectors() public view {
        assertEq(KeyfleetRewards.rewardAssets.selector, bytes4(0x880ec04e));
        assertEq(KeyfleetRewards(address(0)).backed.selector, bytes4(0x595b7f21));
        assertEq(KeyfleetManager(address(0)).TREASURY.selector, bytes4(0x2d2c5565));
        assertEq(KeyfleetManager(address(0)).cascadeReserve.selector, bytes4(0xfc4e8964));
        assertEq(KeyfleetManager(address(0)).protocolShareOwed.selector, bytes4(0xc490b9c7));
    }

    function test_proposalExecutedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalExecuted.selector, 0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24
        );
    }

    function test_editsRestrictionSetTopic() public pure {
        assertEq(
            KeyfleetVotes.EditsRestrictionSet.selector,
            0x908aa6b1a2d33ab8aaa026fccd64bd2d84297a4e0e9c496d53edbb67e5165cdc
        );
    }

    function test_protocolShareSentTopic() public pure {
        assertEq(
            KeyfleetManager.ProtocolShareSent.selector,
            0x406fe989f03a57e5eb52c9fc293be7940d07567bd9425fb5fe3d0eafd20be3f3
        );
    }

    function test_shardIssuedTopic() public pure {
        assertEq(
            KeyfleetShards.ShardIssued.selector, 0x3b2824f462424cb01c09746900aff2810947c0577d310c08082c75fe40c2312a
        );
    }

    function test_shardEndedTopic() public pure {
        assertEq(KeyfleetShards.ShardEnded.selector, 0x22773ac65ded0957ecf7109dad0076e1968f3db974ccda1df370bfa4505092f4);
    }

    function test_agentVotingSetTopic() public pure {
        assertEq(
            KeyfleetShards.AgentVotingSet.selector, 0xfdf7ebb0624288d5705c5fa214a210cf974c5a5598f8f65a6d616f0c420acabd
        );
    }

    /// @dev The calls the platform builds for proposing, casting ballots, cancelling and carrying
    /// out, restricting edits through a proposal's call, issuing and ending shards, switching agent
    /// voting, signed renewals and ballots, and sending the protocol share, and the views it reads
    /// them back through. The one shared shards contract is read from the factory or from a fleet's
    /// voting controller.
    function test_proposalAndShardSelectors() public view {
        assertEq(KeyfleetVotes.propose.selector, bytes4(0x4d51a20c));
        assertEq(KeyfleetVotes.executableAt.selector, bytes4(0x20d0adcb));
        assertEq(KeyfleetVotes.castBallot.selector, bytes4(0xb6e564ef));
        assertEq(KeyfleetVotes.castBallotBySig.selector, bytes4(0xd56f0ce6));
        assertEq(KeyfleetVotes.cancel.selector, bytes4(0x40e58ee5));
        assertEq(KeyfleetVotes.execute.selector, bytes4(0x2b40c480));
        assertEq(KeyfleetVotes.setEditsRestricted.selector, bytes4(0xa2fea1f9));
        assertEq(KeyfleetTreasury.executeBatch.selector, bytes4(0x34fcd5be));
        assertEq(KeyfleetVotes.status.selector, bytes4(0x42d21ef7));
        assertEq(KeyfleetVotes.proposal.selector, bytes4(0x30326c17));
        assertEq(KeyfleetVotes(address(0)).ballotOf.selector, bytes4(0xc06ecc07));
        assertEq(KeyfleetVotes(address(0)).editsRestricted.selector, bytes4(0x547676ac));
        assertEq(KeyfleetVotes.presentBySig.selector, bytes4(0xea783601));
        assertEq(KeyfleetShards.issue.selector, bytes4(0x0423d500));
        assertEq(KeyfleetShards.end.selector, bytes4(0x8dbf85b7));
        assertEq(KeyfleetShards.shardOf.selector, bytes4(0xd6617c02));
        assertEq(KeyfleetShards.setAgentVoting.selector, bytes4(0xbef65f32));
        assertEq(KeyfleetFactory(address(0)).SHARDS.selector, bytes4(0x48db3888));
        assertEq(KeyfleetVotes(address(0)).SHARDS.selector, bytes4(0x48db3888));
        assertEq(KeyfleetManager.sendProtocolShare.selector, bytes4(0xcb097587));
    }

    /// @dev The treasury's payments and advances, which a proposal's calls name, and the events the
    /// treasury reader matches them by.
    function test_treasuryPaymentAndAdvanceSelectorsAndTopics() public view {
        assertEq(KeyfleetTreasury.pay.selector, bytes4(0x5bc0a2ae));
        assertEq(KeyfleetTreasury.advance.selector, bytes4(0x18b18d1a));
        assertEq(KeyfleetTreasury.returnAdvance.selector, bytes4(0xf6dd8fda));
        assertEq(KeyfleetTreasury(payable(address(0))).advances.selector, bytes4(0x435cee31));
        assertEq(KeyfleetTreasury.Paid.selector, 0xadcbed09c0c3a96dbd120d51398fcb6c403f4bfad9a29f7e23e7f5707968220d);
        assertEq(KeyfleetTreasury.Advanced.selector, 0x48ac236609298a1c7957fb52a75e13423f9df416523ebeec6db95db52d813159);
        assertEq(
            KeyfleetTreasury.AdvanceReturned.selector,
            0x2034cebd1ee980ae5db64594c0a5e13ca3153fb318294274500210fc58592e80
        );
    }

    /// @dev The claim the site builds for a key's holder or agent, the reads that show what waits,
    /// and the event a payout is matched by.
    function test_rewardsClaimSelectorsAndTopic() public view {
        assertEq(KeyfleetRewards.claim.selector, bytes4(0x2b14c842));
        assertEq(KeyfleetRewards.accrued.selector, bytes4(0xbfe87f4d));
        assertEq(KeyfleetRewards(address(0)).credits.selector, bytes4(0x637cd7f0));
        assertEq(KeyfleetRewards.Claimed.selector, 0x913c992353dc81b7a8ba31496c484e9b6306bd2f6c509a649a38fdf5e1c953b2);
    }

    /// @dev The daily split the site offers anyone to run, the calls a proposal makes to run it
    /// early, change its rate or admit OUSD, the reads that show when it next opens, and its events.
    function test_dailySplitSelectorsAndTopics() public view {
        assertEq(KeyfleetTreasury.runDailySplit.selector, bytes4(0x8802523d));
        assertEq(KeyfleetTreasury.runVotedSplit.selector, bytes4(0x2bc1d9c2));
        assertEq(KeyfleetTreasury.setDailySplitBps.selector, bytes4(0x32ce8862));
        assertEq(KeyfleetTreasury.admitOusd.selector, bytes4(0x7fea0985));
        assertEq(KeyfleetTreasury.splitAssets.selector, bytes4(0x930fcaef));
        assertEq(KeyfleetTreasury.nextRunAt.selector, bytes4(0x8e3b5ea7));
        assertEq(KeyfleetTreasury(payable(address(0))).lastRunAt.selector, bytes4(0x1767e5cc));
        assertEq(KeyfleetTreasury(payable(address(0))).dailySplitBps.selector, bytes4(0x8b0e4bdd));
        assertEq(
            KeyfleetTreasury.DailySplitRun.selector, 0x589c845daa4d6c172f7b015018e21cf71a9651115b4cb58d0bde2b1bf57f50ec
        );
        assertEq(
            KeyfleetTreasury.SplitAllocated.selector, 0x9074e50b5000d1a14458055f7b5489e63374e5de93050bc4c71be60cc3fe43a7
        );
        assertEq(
            KeyfleetTreasury.SplitSkipped.selector, 0xea328f671ee6ff84eeaff6f40f943c3204abf2f8546aa6d059b505d73ebceb19
        );
        assertEq(
            KeyfleetTreasury.SplitTransferFailed.selector,
            0xce002d041f89b0045ad3cfc1b0ae1f7aeca252711b611ca0181d3f40c24aa625
        );
        assertEq(
            KeyfleetTreasury.DailySplitRateSet.selector,
            0x5b373159cf1aa560402780ad3be14b33d21f72e79ae0dae5688d4c232b953d81
        );
        assertEq(
            KeyfleetTreasury.OusdAdmitted.selector, 0xebcf2752fcd8a14f6710aaeea4dff961f9fe5e076a8a719afc5b286405520d78
        );
    }

    /// @dev A key marked present, and its mark cleared when the key changes hands or its presence
    /// runs out, which the presence card reads.
    function test_presenceTopics() public pure {
        assertEq(KeyfleetVotes.Present.selector, 0x65494834b9ecadf1a0a1aa43098094d1784705df5b74020daae186d31b9d5d19);
        assertEq(
            KeyfleetVotes.PresenceCleared.selector, 0x3a7956ae06b201a0d818ed191ba804d3cbe825deec03291fae84299fc9b2ae8f
        );
    }

    /// @dev A key's rewards settled to its holder, recorded beside each claim.
    function test_settledTopic() public pure {
        assertEq(KeyfleetRewards.Settled.selector, 0xbfed4c9aef0cc82058a0d9ecf93fff780a20d63bb650b7fcde95bf639097b402);
    }

    /// @dev The fleet's launch token bound to its treasury, and the Lit `CreateWallet` requests a
    /// proposal approves or revokes.
    function test_launchAndSignatureTopics() public pure {
        assertEq(
            KeyfleetTreasury.LaunchTokenBound.selector,
            0x8d7b7447fbb1198714566de25638e562cbbad2f5d24d09970b1793414994acf4
        );
        assertEq(
            KeyfleetTreasury.LitCreateWalletApproved.selector,
            0x55466410721fef34fe9a5642b5f6ad4a536d32b4dd13f85ffc1629fc8839046e
        );
        assertEq(
            KeyfleetTreasury.LitCreateWalletRevoked.selector,
            0x3777c7cd3a982e67c2f22eb607a5ac633d7463082b7819be343158ac9859bfe1
        );
    }
}
