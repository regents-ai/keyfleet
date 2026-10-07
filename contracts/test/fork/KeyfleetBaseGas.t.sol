// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeployKeyfleets} from "../../script/DeployKeyfleets.s.sol";
import {KeyfleetStack} from "../../script/KeyfleetStack.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {IRegentRevenueStaking} from "../../src/interfaces/IRegentRevenueStaking.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";

/// @dev The gas a Classic fleet's everyday calls cost against the real Base contracts on a fork of
/// Base: native USDC (a proxy), REGENT, REGENT revenue staking and the Chainlink VRF coordinator,
/// with the fleet a consumer of a funded subscription so each purchase makes its real request.
/// Each figure is the whole transaction's gas, the 21,000 base and the calldata included, so it
/// runs only when `BASE_RPC_URL` is set and Forge runs each call as a transaction of its own
/// (`--isolate`), and skips itself otherwise; the URL is never printed:
///
///     BASE_RPC_URL=https://mainnet.base.org forge test --mc KeyfleetBaseGasTest --isolate -vv
contract KeyfleetBaseGasTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    address private constant OPERATOR = address(0x0E0E);

    IERC20Metadata private usdc;
    IERC20Metadata private regent;
    address private staking;
    IVRFCoordinatorV2Plus private coordinator;
    Keyfleet private fleet;
    KeyfleetRewards private rewards;
    KeyfleetVotes private votes;
    KeyfleetTreasury private treasury;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        DeployKeyfleets script = new DeployKeyfleets();
        usdc = IERC20Metadata(script.BASE_USDC());
        regent = IERC20Metadata(script.BASE_REGENT());
        staking = script.BASE_REGENT_REVENUE_STAKING();
        coordinator = IVRFCoordinatorV2Plus(script.BASE_VRF_COORDINATOR());
        uint256 subscriptionId = coordinator.createSubscription();
        vm.deal(address(this), 1 ether);
        coordinator.fundSubscriptionWithNative{value: 1 ether}(subscriptionId);

        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            IRegentRevenueStaking(staking),
            regent,
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            Keyfleet.Randomness({
                coordinator: coordinator, subscriptionId: subscriptionId, keyHash: script.BASE_VRF_KEY_HASH_2_GWEI()
            }),
            keccak256("trait table")
        );
        coordinator.addConsumer(subscriptionId, address(fleet));
        rewards = fleet.REWARDS();
        votes = fleet.VOTES();
        treasury = fleet.TREASURY();

        address[2] memory buyers = [ALICE, BOB];
        for (uint256 i = 0; i < buyers.length; ++i) {
            deal(address(usdc), buyers[i], 1_000e6);
            vm.prank(buyers[i]);
            usdc.approve(address(fleet), type(uint256).max);
        }
    }

    function test_gasOfEverydayCallsOnBase() public {
        // Only a call made as a transaction of its own costs the 21,000 base.
        usdc.approve(OPERATOR, 0);
        if (vm.lastCallGas().gasTotalUsed < 21_000) {
            vm.skip(true);
            return;
        }

        // Purchases: the fleet's first sale, then a later one, each with its real VRF request.
        vm.prank(ALICE);
        fleet.purchase(ALICE, type(uint256).max, block.timestamp);
        _log("purchase, the fleet's first key");
        vm.prank(BOB);
        fleet.purchase(BOB, type(uint256).max, block.timestamp);
        _log("purchase, a later key");

        // Presence: a key's first renewal.
        uint256[] memory key1 = new uint256[](1);
        key1[0] = 1;
        vm.prank(ALICE);
        votes.present(key1);
        _log("present, one key");

        // A proposal paying 1 USDC, and a first ballot on it.
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(
            address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (address(usdc), OPERATOR, 1e6))
        );
        vm.prank(ALICE);
        uint256 proposalId = votes.propose(1, keccak256("narrative"), uint64(block.timestamp + 1), calls);
        _log("propose, one payment");
        vm.prank(ALICE);
        votes.castBallot(proposalId, key1, KeyfleetVotes.Choice.Yes);
        _log("castBallot, one key");

        // The daily split, a day after the first sale, of ETH, REGENT and USDC.
        vm.warp(treasury.nextRunAt());
        vm.deal(address(treasury), 1 ether);
        deal(address(regent), address(treasury), 10_000e18);
        deal(address(usdc), address(treasury), 10_000e6);
        treasury.runDailySplit();
        _log("runDailySplit, ETH, REGENT and USDC");

        // A claim of one key in every asset the split paid.
        address[] memory assets = rewards.rewardAssets();
        vm.prank(ALICE);
        uint256[] memory paid = rewards.claim(key1, assets);
        _log("claim, one key, three assets");
        assertEq(paid.length, 3, "USDC, ETH and REGENT");
        for (uint256 i = 0; i < paid.length; ++i) {
            assertGt(paid[i], 0, "every split asset paid");
        }

        // Moving a key with a day's split waiting in three assets.
        vm.prank(BOB);
        fleet.transferFrom(BOB, CAROL, 2);
        _log("transferFrom, a key with three assets waiting");

        // Carrying out the one-payment proposal, and the treasury's batch on its own.
        votes.execute(proposalId, calls);
        _log("execute, a one-payment proposal");
        assertEq(usdc.balanceOf(OPERATOR), 1e6, "paid");
        vm.prank(address(votes));
        treasury.executeBatch(calls);
        _log("executeBatch, one payment");
        assertEq(usdc.balanceOf(OPERATOR), 2e6, "paid again");
    }

    /// @dev The gas of the call just made.
    function _log(string memory call) private view {
        console2.log(call, vm.lastCallGas().gasTotalUsed);
    }
}
