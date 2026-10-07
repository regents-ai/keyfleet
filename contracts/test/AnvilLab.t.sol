// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AnvilLab} from "../script/AnvilLab.s.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";

/// @notice The fleet-bound view each of a fleet's four other contracts shares.
interface IFleetBound {
    function FLEET() external view returns (address);
}

/// @dev The anvil lab the site's anvil tests start from, run as they run it: it returns where all
/// five of the fleet's contracts are, each bound to the fleet, with two keys sold and their
/// protocol share owed.
contract AnvilLabTest is Test {
    function test_theLabReturnsTheFleetsFiveContracts() public {
        address sender = tx.origin;
        vm.deal(sender, 1 ether);

        (address fleet, address rewards, address shards, address votes, address treasury, address staking) =
            new AnvilLab().run();

        Keyfleet classic = Keyfleet(fleet);
        assertTrue(classic.PRESET() == KeyfleetPresets.Preset.FleetTechClassic, "A Classic fleet");
        assertEq(address(classic.REWARDS()), rewards, "Ledger");
        assertEq(address(classic.SHARDS()), shards, "Shard record");
        assertEq(address(classic.VOTES()), votes, "Controller");
        assertEq(address(classic.TREASURY()), treasury, "Treasury");
        assertEq(address(classic.TREASURY().REGENT_STAKING()), staking, "Stand-in staking");
        address[4] memory companions = [rewards, shards, votes, treasury];
        for (uint256 i = 0; i < companions.length; ++i) {
            assertEq(IFleetBound(companions[i]).FLEET(), fleet, "Each is bound to the fleet");
        }
        assertEq(classic.totalMinted(), 2, "Two keys sold");
        assertEq(classic.ownerOf(1), sender, "To the sender");
        assertEq(
            classic.protocolShareOwed(),
            KeyfleetPresets.classicPrice(1) / 10 + KeyfleetPresets.classicPrice(2) / 10,
            "Both sales' share owed"
        );
    }
}
