// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

/// @dev The fleet reader in platform/lib/keyfleet/chain/ matches logs by these topics, reads a
/// proposal's kind by these numbers and calls these functions, all written out there by hand. If an
/// event's signature, a function's signature or the kinds change, this fails until both sides agree
/// again.
contract KeyfleetVotesTopicsTest is Test {
    function test_ownershipEpochTopic() public pure {
        assertEq(Keyfleet.OwnershipEpoch.selector, 0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1);
    }

    function test_keyRevealedTopic() public pure {
        assertEq(Keyfleet.KeyRevealed.selector, 0x6d40ad718cfc10342a32c87c9bc44d44a37c6e9a218a67e550d1631035b05f0e);
    }

    function test_proposalCreatedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalCreated.selector, 0x0304fff099efa259236c475a8becd21961ea19ff1e91f791fb27c5e63a3d4848
        );
    }

    function test_voteCastTopic() public pure {
        assertEq(KeyfleetVotes.VoteCast.selector, 0x707650471b3fbad25e3f07d77bd835851846b71eb8c47598be05f07de77aed53);
    }

    function test_voteWithdrawnTopic() public pure {
        assertEq(
            KeyfleetVotes.VoteWithdrawn.selector, 0x72cf7f3b692fcac70eec735cf686ea37d566b98a1a37e8f13e755db5b4d0c2c4
        );
    }

    function test_proposalKindNumbers() public pure {
        assertEq(uint8(KeyfleetVotes.Kind.Decision), 0);
        assertEq(uint8(KeyfleetVotes.Kind.RestrictEdits), 1);
        assertEq(uint8(type(KeyfleetVotes.Kind).max), 1);
    }

    function test_incomeRecognizedTopic() public pure {
        assertEq(Keyfleet.IncomeRecognized.selector, 0x0cd4e99e415e30cc448d0a20beb2e3d8e1476362e9da4a494959dc6817a3fb13);
    }

    function test_forwardedToTreasuryTopic() public pure {
        assertEq(
            Keyfleet.ForwardedToTreasury.selector, 0x8926b565a570cae7e82c2dcc861e6aeea283665a938a403f59ee2a13bcc83d81
        );
    }

    /// @dev The treasury reader's balance reads, one call each at the same block. The fleet's
    /// capital is the token balance of the address `TREASURY` returns. A public
    /// mapping or variable's getter is only reachable through an instance, so those are named
    /// through one at address zero, which is never called.
    function test_treasuryViewSelectors() public view {
        assertEq(KeyfleetRewards.rewardAssets.selector, bytes4(0x880ec04e));
        assertEq(KeyfleetRewards(address(0)).backed.selector, bytes4(0x595b7f21));
        assertEq(Keyfleet(address(0)).TREASURY.selector, bytes4(0x2d2c5565));
        assertEq(Keyfleet(address(0)).cascadeReserve.selector, bytes4(0xfc4e8964));
        assertEq(Keyfleet(address(0)).protocolShareOwed.selector, bytes4(0xc490b9c7));
    }

    function test_proposalExecutedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalExecuted.selector, 0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24
        );
    }

    function test_restrictEditsProposedTopic() public pure {
        assertEq(
            KeyfleetVotes.RestrictEditsProposed.selector,
            0x051dcf97e7396a690509aaa36720e1aeaabeff0faca865092638a5b028e2fa8f
        );
    }

    function test_editsRestrictionSetTopic() public pure {
        assertEq(
            KeyfleetVotes.EditsRestrictionSet.selector,
            0x2e8b5462cfaf90ff39c1d520552d96015e77788b57b81d3bf8dd40a847037bad
        );
    }

    function test_protocolShareSentTopic() public pure {
        assertEq(
            Keyfleet.ProtocolShareSent.selector, 0x406fe989f03a57e5eb52c9fc293be7940d07567bd9425fb5fe3d0eafd20be3f3
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

    /// @dev The calls the platform builds for restricting edits, issuing and ending shards, and
    /// sending the protocol share, and the views it reads them back through.
    function test_restrictEditsAndShardSelectors() public view {
        assertEq(KeyfleetVotes.proposeRestrictEdits.selector, bytes4(0xe18b7f31));
        assertEq(KeyfleetVotes(address(0)).editsRestricted.selector, bytes4(0x547676ac));
        assertEq(KeyfleetShards.issue.selector, bytes4(0x18d1ffc8));
        assertEq(KeyfleetShards.end.selector, bytes4(0x96f0fa4d));
        assertEq(KeyfleetShards.shardOf.selector, bytes4(0xf01d24e8));
        assertEq(Keyfleet(address(0)).SHARDS.selector, bytes4(0x48db3888));
        assertEq(Keyfleet.sendProtocolShare.selector, bytes4(0xcb097587));
    }
}
