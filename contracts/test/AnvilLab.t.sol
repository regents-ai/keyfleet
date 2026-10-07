// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AnvilLab} from "../script/AnvilLab.s.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";

/// @notice The fleet-bound view each of a fleet's four other contracts shares.
interface IFleetBound {
    function FLEET() external view returns (address);
}

/// @dev The anvil lab the site's anvil tests and the local lab start from, run as they run it: it
/// returns where all five of the fleet's contracts and its stand-ins are, each bound to the fleet,
/// with two keys sold, their protocol share owed and the treasury funded for the daily split.
contract AnvilLabTest is Test {
    function test_theLabReturnsTheFleetsFiveContracts() public {
        address sender = tx.origin;
        vm.deal(sender, 3 ether);

        (
            address fleet,
            address rewards,
            address shards,
            address votes,
            address treasury,
            address staking,
            address usdc,
            address regent,
            address autolaunch
        ) = new AnvilLab().run();

        Keyfleet classic = Keyfleet(fleet);
        assertTrue(classic.PRESET() == KeyfleetPresets.Preset.FleetTechClassic, "A Classic fleet");
        assertEq(address(classic.REWARDS()), rewards, "Ledger");
        assertEq(address(classic.SHARDS()), shards, "Shard record");
        assertEq(address(classic.VOTES()), votes, "Controller");
        assertEq(address(classic.TREASURY()), treasury, "Treasury");
        assertEq(address(classic.TREASURY().REGENT_STAKING()), staking, "Stand-in staking");
        assertEq(address(classic.USDC()), usdc, "Stand-in USDC");
        assertEq(address(classic.TREASURY().REGENT()), regent, "Stand-in REGENT");
        assertEq(address(classic.TREASURY().AUTOLAUNCH()), autolaunch, "Stand-in Autolaunch");
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
        assertEq(treasury.balance, 1 ether, "The treasury holds ETH");
        assertEq(IERC20(regent).balanceOf(treasury), 500 ether, "And REGENT");
        assertGe(IERC20(usdc).balanceOf(treasury), 500e6, "And USDC beside what the sales forwarded");
    }
}
