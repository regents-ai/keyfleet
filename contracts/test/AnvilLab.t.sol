// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {AnvilLab} from "../script/AnvilLab.s.sol";

/// @dev The anvil lab the site's anvil tests start from, run as they run it, in its two steps with
/// the clock moved past the opening between them: the system with its five founding fleets and
/// Classic #1 selling in phase 2,
/// two keys sold to the sender with their protocol share owed and their REGENT in the treasury, no
/// reveal accepted, and USDC approved for a third key.
contract AnvilLabTest is Test {
    function test_theLabBuildsTheFoundingFleetsWithTwoClassicKeysSold() public {
        address sender = tx.origin;
        vm.deal(sender, 1 ether);

        AnvilLab script = new AnvilLab();
        AnvilLab.Lab memory lab = script.run();
        KeyfleetKeys keys = KeyfleetKeys(lab.keys);
        KeyfleetManager classic = KeyfleetManager(lab.manager);
        assertFalse(keys.salesOpen(1), "Classic #1 opens later");
        vm.warp(block.timestamp + script.OPENING());
        script.sell(classic);

        KeyfleetFactory factory = KeyfleetFactory(lab.factory);
        assertEq(address(factory.KEYS()), lab.keys, "The factory's collection");
        assertEq(keys.managerOf(1), lab.manager, "Fleet 1");
        assertTrue(classic.PRESET() == KeyfleetPresets.Preset.FleetTechClassic, "Classic");
        assertEq(address(classic.REWARDS()), lab.rewards, "Ledger");
        assertEq(address(factory.SHARDS()), lab.shards, "Shard record");
        assertEq(address(classic.VOTES()), lab.votes, "Controller");
        assertEq(address(classic.TREASURY()), lab.treasury, "Treasury");
        assertEq(address(classic.TREASURY().REGENT_STAKING()), lab.staking, "Stand-in staking");
        assertEq(address(classic.USDC()), lab.usdc, "Stand-in USDC");
        assertEq(address(classic.TREASURY().REGENT()), lab.regent, "Stand-in REGENT");
        assertEq(address(factory.CLUB_CLAIMS()), lab.clubClaims, "Regents Club claims");
        assertEq(keys.fleetCount(), keys.FOUNDING_FLEETS(), "Every founding fleet");
        assertEq(keys.phase(), 2, "Phase 2");
        assertTrue(keys.salesOpen(1), "Classic #1 sells");
        assertTrue(keys.salesOpen(5), "the Regents Club is already open");
        assertEq(keys.SAFE(), sender, "The sender is the Safe");
        assertEq(keys.keeper(), sender, "and the keeper");

        uint256 start = classic.START_PRICE();
        uint256 first = KeyfleetPresets.classicPrice(1, start);
        uint256 second = KeyfleetPresets.classicPrice(2, start);
        assertEq(classic.totalMinted(), 2, "Two keys sold");
        assertEq(keys.ownerOf(keys.tokenIdOf(1, 1)), sender, "To the sender");
        assertEq(keys.ownerOf(keys.tokenIdOf(1, 2)), sender, "Both");
        assertEq(keys.revealRequestedAt(keys.tokenIdOf(1, 1)), 0, "No reveal accepted");
        assertEq(keys.revealRequestedAt(keys.tokenIdOf(1, 2)), 0, "for either key");
        assertEq(classic.protocolShareOwed(), first / 10 + second / 10, "Both sales' share owed");
        assertEq(classic.pendingConversion(), 0, "One piece converted both sales' booked USDC");
        assertEq(
            IERC20(lab.regent).balanceOf(lab.treasury), (first + second - first / 10 - second / 10) * 1e12, "REGENT"
        );
        uint256 third = KeyfleetPresets.classicPrice(3, start);
        assertEq(IERC20(lab.usdc).balanceOf(sender), third, "USDC for a third key");
        assertEq(IERC20(lab.usdc).allowance(sender, lab.manager), third, "Approved");
    }
}
