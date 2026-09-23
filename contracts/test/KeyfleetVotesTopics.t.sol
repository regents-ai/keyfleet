// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

/// @dev The fleet reader in platform/lib/keyfleet/chain/ matches logs by these topics and reads a
/// proposal's kind by these numbers, both written out there by hand. If an event's signature or the
/// kinds change, this fails until both sides agree again.
contract KeyfleetVotesTopicsTest is Test {
    function test_ownershipEpochTopic() public pure {
        assertEq(Keyfleet.OwnershipEpoch.selector, 0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1);
    }

    function test_proposalCreatedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalCreated.selector, 0xf8482fe2c54826b69ae2eac425c7ee38d217afb99600f7a8732276535a2f300b
        );
    }

    function test_autolaunchProposedTopic() public pure {
        assertEq(
            KeyfleetVotes.AutolaunchProposed.selector,
            0xa395caec5e719dd09aa72025608546598e2f07d131ae8ca46b82bbaacfbe2846
        );
    }

    function test_voteCastTopic() public pure {
        assertEq(KeyfleetVotes.VoteCast.selector, 0x75a715a3d9aeed50070699874aee33f077ea55144e4a72c43ed49f31cfcab424);
    }

    function test_proposalKindNumbers() public pure {
        assertEq(uint8(KeyfleetVotes.Kind.Decision), 0);
        assertEq(uint8(KeyfleetVotes.Kind.Autolaunch), 1);
        assertEq(uint8(type(KeyfleetVotes.Kind).max), 1);
    }

    function test_proposalExecutedTopic() public pure {
        assertEq(
            KeyfleetVotes.ProposalExecuted.selector, 0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24
        );
    }
}
