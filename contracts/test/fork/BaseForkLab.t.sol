// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {BaseForkLab} from "../../script/BaseForkLab.s.sol";
import {KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {FULL_PIECE} from "../helpers/KeyfleetFixture.sol";

/// @dev The Base-fork lab as the site uses it: on a fork of Base run as chain 31337, Classic #1
/// sells for 10 USDC through Base's own route, its record has the release's shape, and a key within
/// its deck holds its card by number with no draw. The fork test runs only when `BASE_RPC_URL` is set and
/// skips itself otherwise; everything runs in the local EVM only.
contract BaseForkLabTest is Test {
    address private constant KEEPER = address(0x4EE9E4);

    /// @dev Invariant: the lab refuses every chain but 31337, so it never deploys on Base itself.
    function test_theLabRefusesAnyChainButTheLabs() public {
        BaseForkLab lab = new BaseForkLab();
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManifest.WrongChain.selector, 31_337, 8453));
        lab.deploy(KEEPER);
    }

    /// @dev Invariant: on a fork of Base, the lab leaves Classic #1 selling in phase 2 against Base's
    /// own USDC and route, records it in the release's shape, and a bought key within the deck asks
    /// the coordinator for nothing.
    function test_theLabSellsClassicOneOnAForkOfBase() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        vm.chainId(31_337);
        BaseForkLab lab = new BaseForkLab();
        vm.deal(tx.origin, 1 ether);

        KeyfleetFactory factory = lab.deploy(KEEPER);
        KeyfleetKeys keys = factory.KEYS();
        string memory json = lab.recordOf(
            lab.readManifest("base"),
            KeyfleetManifest.BroadcastSummary({factory: factory, deploymentBlock: block.number})
        );
        assertEq(vm.parseJsonUint(json, ".chainId"), 31_337, "The lab chain");
        assertEq(vm.parseJsonAddress(json, ".usdc"), lab.BASE_USDC(), "Base's own USDC");
        assertEq(vm.parseJsonAddress(json, ".regentStaking"), lab.BASE_REGENT_REVENUE_STAKING(), "and staking");
        assertEq(vm.parseJsonAddress(json, ".collection.safe"), tx.origin, "The sender is the Safe");
        assertEq(vm.parseJsonAddress(json, ".collection.keeper"), KEEPER, "The keeper");
        assertEq(vm.parseJsonString(json, ".fleets.1.name"), "Classic #1", "Fleet 1");
        assertEq(keys.phase(), 2, "Phase 2");
        assertFalse(keys.salesOpen(1), "Classic #1 opens later");
        vm.warp(block.timestamp + lab.LAB_OPENING());
        assertTrue(keys.salesOpen(1), "Classic #1 sells");

        KeyfleetManager classic = KeyfleetManager(vm.parseJsonAddress(json, ".fleets.1.manager"));
        IERC20 usdc = IERC20(lab.BASE_USDC());
        address buyer = makeAddr("buyer");
        deal(address(usdc), buyer, 10e6);
        vm.startPrank(buyer);
        usdc.approve(address(classic), 10e6);
        vm.recordLogs();
        classic.purchase(buyer, 10e6, block.timestamp + 1 hours, new bytes32[](0));
        vm.stopPrank();
        uint256 tokenId = keys.tokenIdOf(1, 1);
        assertEq(keys.ownerOf(tokenId), buyer, "Key 1 is the buyer's");
        assertTrue(keys.dealtByNumber(tokenId), "Key 1 holds card 1");
        _assertNoRequest(keys);
        assertEq(classic.pendingConversion(), 9e6, "Its treasury part is booked");
        classic.REGENT_BUYER().convert(FULL_PIECE);
        assertGt(IERC20(lab.BASE_REGENT()).balanceOf(address(classic.TREASURY())), 0, "REGENT in the treasury");
    }

    function _assertNoRequest(KeyfleetKeys keys) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index = 0; index < logs.length; ++index) {
            Vm.Log memory log = logs[index];
            if (log.emitter != address(keys)) continue;
            assertTrue(log.topics[0] != KeyfleetKeys.RevealRequested.selector, "no draw requested");
            assertTrue(log.topics[0] != KeyfleetKeys.RevealRequestFailed.selector, "no draw attempted");
        }
    }
}
