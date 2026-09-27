// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

/// @dev The fleet reader in platform/lib/keyfleet/chain/ matches logs by these topics, reads a
/// proposal's kind by these numbers and calls these functions, all written out there by hand. If an event's signature or the
/// kinds change, this fails until both sides agree again.
contract KeyfleetVotesTopicsTest is Test {
    function test_ownershipEpochTopic() public pure {
        assertEq(Keyfleet.OwnershipEpoch.selector, 0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1);
    }

    function test_keyRevealedTopic() public pure {
        assertEq(Keyfleet.KeyRevealed.selector, 0x6d40ad718cfc10342a32c87c9bc44d44a37c6e9a218a67e550d1631035b05f0e);
    }

    function test_proposalCreatedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalCreated.selector, 0x29ea7482e80123243d4237b155637f07d8868001408424ed3934ec29e65ab647
        );
    }

    function test_autolaunchProposedTopic() public pure {
        assertEq(
            KeyfleetVotes.AutolaunchProposed.selector,
            0x5814e7293d336521e3e8dbd0b0a4480cca203df470b8637a8fa51b2cced3f513
        );
    }

    function test_payProposedTopic() public pure {
        assertEq(KeyfleetVotes.PayProposed.selector, 0x1da5b725f356ce5da6ebeddfa1d1b808edc6cc42c21738f9023ad8a0d59f96be);
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
        assertEq(uint8(KeyfleetVotes.Kind.Autolaunch), 1);
        assertEq(uint8(KeyfleetVotes.Kind.Pay), 2);
        assertEq(uint8(type(KeyfleetVotes.Kind).max), 2);
    }

    function test_incomeRecognizedTopic() public pure {
        assertEq(Keyfleet.IncomeRecognized.selector, 0x0cd4e99e415e30cc448d0a20beb2e3d8e1476362e9da4a494959dc6817a3fb13);
    }

    function test_sharedMoneyRecognizedTopic() public pure {
        assertEq(
            Keyfleet.SharedMoneyRecognized.selector, 0x499f2f2f2d8bb29705b19416e4ed4b160f0dfbfbe5a2bf3bc0f73d6b73e12fa7
        );
    }

    function test_graduationHoldingsBookedTopic() public pure {
        assertEq(
            Keyfleet.GraduationHoldingsBooked.selector,
            0xd8c9a3e20faa52b5fa537458d4e055db2d5d91ef401d3120ec549f8724b42355
        );
    }

    function test_vestingBookedTopic() public pure {
        assertEq(Keyfleet.VestingBooked.selector, 0xee00fd5e75d11a67d01f1e2c820557fb28f1e211c8119f94759d4f5b470eeee2);
    }

    function test_budgetPaidTopic() public pure {
        assertEq(Keyfleet.BudgetPaid.selector, 0x49fd68af19bac5da72e7e1622c38c15d88d83df2eb98a0c9b2a03b81b9a74e9e);
    }

    function test_collectedTopic() public pure {
        assertEq(KeyfleetVotes.Collected.selector, 0xb0204fab5c5aa6ce90e169a2f115973605e0a5bd6acfa463f8550ebaf458c9b4);
    }

    function test_launchEnvelopeSelector() public pure {
        assertEq(KeyfleetVotes.launchEnvelope.selector, bytes4(0xb3bceadb));
    }

    /// @dev The treasury reader's balance reads, one call each at the same block. A public
    /// mapping or variable's getter is only reachable through an instance, so those are named
    /// through one at address zero, which is never called.
    function test_treasuryViewSelectors() public view {
        assertEq(KeyfleetRewards.rewardAssets.selector, bytes4(0x880ec04e));
        assertEq(KeyfleetRewards(address(0)).backed.selector, bytes4(0x595b7f21));
        assertEq(Keyfleet(address(0)).freeCapital.selector, bytes4(0x2b84308e));
        assertEq(Keyfleet(address(0)).cascadeReserve.selector, bytes4(0xfc4e8964));
        assertEq(Keyfleet(address(0)).protocolShareOwed.selector, bytes4(0xc490b9c7));
    }

    function test_proposalExecutedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalExecuted.selector, 0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24
        );
    }
}
