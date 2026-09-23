// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
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
            KeyfleetVotes.ProposalCreated.selector, 0x3981631dc33adabae5ab9de3f23bf01207ffc383d894a4f777ee115e75dee3a9
        );
    }

    function test_autolaunchProposedTopic() public pure {
        assertEq(
            KeyfleetVotes.AutolaunchProposed.selector,
            0xa395caec5e719dd09aa72025608546598e2f07d131ae8ca46b82bbaacfbe2846
        );
    }

    function test_payProposedTopic() public pure {
        assertEq(KeyfleetVotes.PayProposed.selector, 0xdf6e4791f55c0c086cb1d3527b5f4f92e4b3d3142e3899a7b5a4af3e75b7cd85);
    }

    function test_voteCastTopic() public pure {
        assertEq(KeyfleetVotes.VoteCast.selector, 0x707650471b3fbad25e3f07d77bd835851846b71eb8c47598be05f07de77aed53);
    }

    function test_proposalKindNumbers() public pure {
        assertEq(uint8(KeyfleetVotes.Kind.Decision), 0);
        assertEq(uint8(KeyfleetVotes.Kind.Autolaunch), 1);
        assertEq(uint8(KeyfleetVotes.Kind.Pay), 2);
        assertEq(uint8(type(KeyfleetVotes.Kind).max), 2);
    }

    function test_launchIncomeSplitTopic() public pure {
        assertEq(
            Keyfleet.LaunchIncomeSplit.selector, 0xd1de1f4a371f15e76fb100d279a26e729da58dcb604fa97058f7e3857fca911e
        );
    }

    function test_budgetPaidTopic() public pure {
        assertEq(Keyfleet.BudgetPaid.selector, 0x49fd68af19bac5da72e7e1622c38c15d88d83df2eb98a0c9b2a03b81b9a74e9e);
    }

    function test_launchEnvelopeSelector() public pure {
        assertEq(KeyfleetVotes.launchEnvelope.selector, bytes4(0xb3bceadb));
    }

    function test_proposalExecutedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalExecuted.selector, 0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24
        );
    }
}
