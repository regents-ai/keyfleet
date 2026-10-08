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
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";
import {FULL_PIECE} from "../helpers/KeyfleetFixture.sol";

/// @dev The Base-fork lab as the site uses it: on a fork of Base run as chain 31337, Classic #1
/// sells for 10 USDC through Base's own route, its record has the release's shape, and a key's draw
/// is answered by the stand-in coordinator. The fork test runs only when `BASE_RPC_URL` is set and
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

    /// @dev Invariant: on a fork of Base, the lab leaves Classic #1 selling in phase 1 against Base's
    /// own USDC and route, records it in the release's shape, and a bought key's draw can be
    /// answered.
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
        assertEq(keys.phase(), 1, "Phase 1");
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
        uint256 requestId = _requestId(keys);
        assertEq(classic.pendingConversion(), 9e6, "Its treasury part is booked");
        classic.REGENT_BUYER().convert(FULL_PIECE);
        assertGt(IERC20(lab.BASE_REGENT()).balanceOf(address(classic.TREASURY())), 0, "REGENT in the treasury");

        uint256[] memory words = new uint256[](1);
        words[0] = 7;
        (IVRFCoordinatorV2Plus coordinator,,) = keys.randomness();
        MockVRFCoordinatorV2Plus(address(coordinator)).fulfill(requestId, words);
        assertTrue(keys.revealSeed(tokenId) != bytes32(0), "Key 1 is revealed");
    }

    function _requestId(KeyfleetKeys keys) private returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index = 0; index < logs.length; ++index) {
            Vm.Log memory log = logs[index];
            if (log.emitter == address(keys) && log.topics[0] == KeyfleetKeys.RevealRequested.selector) {
                return uint256(log.topics[2]);
            }
        }
        revert("no RevealRequested from the collection");
    }
}
