// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {KeyfleetForkFixture} from "./KeyfleetBaseFork.t.sol";
import {FULL_PIECE} from "../helpers/KeyfleetFixture.sol";

/// @dev The gas of the system's everyday calls against the real Base contracts on a fork of Base:
/// native USDC (a proxy), REGENT and its v4 pool and hook, the USDC/WETH v3 pool, REGENT revenue
/// staking and the Chainlink VRF coordinator, with the collection a consumer of a funded
/// subscription so a key that draws makes its real request. Each figure is the whole
/// transaction's gas, the 21,000 base and the calldata included, so it runs only when
/// `BASE_RPC_URL` is set and Forge runs each call as a transaction of its own (`--isolate`), and
/// skips itself otherwise; the URL is never printed:
///
///     forge test --match-contract KeyfleetBaseGasTest --isolate -vv
///
/// run with `BASE_RPC_URL` set to a Base RPC endpoint in the environment.
contract KeyfleetBaseGasTest is KeyfleetForkFixture {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    address private constant CREATOR = address(0xC4EA70);
    address private constant OPERATOR = address(0x0E0E);

    function setUp() public {
        if (!_setUpFork(0)) return;
        coordinator.addConsumer(subscriptionId, address(keys));
    }

    function test_gasOfEverydayCallsOnBase() public {
        // Only a call made as a transaction of its own costs the 21,000 base.
        usdc.approve(OPERATOR, 0);
        if (vm.lastCallGas().gasTotalUsed < 21_000) {
            vm.skip(true);
            return;
        }

        // The Safe's calls: the five founding fleets, each its own transaction, and phases 1 and 2.
        KeyfleetSafeSteps.SafeCall[] memory founding = safeSteps.foundingFleetCalls(_manifest(), factory);
        for (uint256 i = 0; i < founding.length; ++i) {
            _asSafe(founding[i]);
            _log(string.concat("createFoundingFleet, ", founding[i].name));
        }
        _advancePhase();
        _log("advancePhase, to phase 1");
        _advancePhase();
        _log("advancePhase, to phase 2");

        // Purchases on Classic #1: its first sale, then a later one, each booking the treasury's
        // part. Both keys hold their deck's card of the same number and ask for no random word.
        KeyfleetManager classic = _fleet(1);
        uint256 price = _fund(classic, ALICE);
        vm.prank(ALICE);
        uint256 first = classic.purchase(ALICE, price, block.timestamp, new bytes32[](0));
        _log("purchase, the fleet's first key");
        price = _fund(classic, BOB);
        vm.prank(BOB);
        uint256 second = classic.purchase(BOB, price, block.timestamp, new bytes32[](0));
        _log("purchase, a later key");

        // One piece of the booked USDC through the real pools into REGENT for the treasury.
        factory.REGENT_BUYER().convert(FULL_PIECE);
        _log("convert, one piece through both pools");

        // A creator's own fleet, once the collection reaches its last phase.
        _advancePhase();
        _advancePhase();
        _log("advancePhase, to phase 4");
        KeyfleetManager created = _createFleet();

        // A key that draws: the keeper records the new fleet's deck, then its key 2 is bought and
        // makes its real VRF request.
        uint256 createdId = created.FLEET_ID();
        vm.prank(KEEPER);
        keys.setDeck(createdId, keccak256("a creator's deck"), 1000);
        price = _fund(created, CAROL);
        vm.prank(CAROL);
        uint256 drawing = created.purchase(CAROL, price, block.timestamp, new bytes32[](0));
        _log("purchase, a key that draws, with its request");
        assertGt(keys.revealRequestedAt(drawing), 0, "the coordinator accepted its request");

        // The Safe's first batch of Regents Club keys, each to the holder of its real Pass.
        _asSafe(safeSteps.clubGiftCalls(_manifest(), factory, new uint256[](0))[0]);
        _log("give, the Regents Club's first batch");

        // Presence: a key's first renewal, once the fleet's opening has passed, so both keys are
        // mature and their automatic presence has ended.
        KeyfleetVotes votes = classic.VOTES();
        KeyfleetTreasury treasury = classic.TREASURY();
        KeyfleetRewards rewards = classic.REWARDS();
        vm.warp(votes.treasuryOpensAt());
        uint256[] memory key1 = _ids(first);
        vm.prank(ALICE);
        votes.present(key1);
        _log("present, one key");

        // A proposal paying 0.01% of the treasury's USDC, and a first ballot on it.
        KeyfleetTreasury.Call[] memory calls = _one(
            KeyfleetTreasury.Call(
                address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (address(usdc), OPERATOR, uint32(100)))
            )
        );
        vm.prank(ALICE);
        uint256 proposalId = votes.propose(first, keccak256("narrative"), calls);
        _log("propose, one payment");
        vm.prank(ALICE);
        votes.castBallot(proposalId, key1, KeyfleetVotes.Choice.Yes);
        _log("castBallot, one key");

        // The protocol share of both sales, into REGENT staking.
        classic.sendProtocolShare();
        _log("sendProtocolShare, two sales");

        // The daily split, due since a day after the first sale, of ETH, REGENT and USDC.
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
        keys.transferFrom(BOB, CAROL, second);
        _log("transferFrom, a key with three assets waiting");

        // Carrying out the one-payment proposal once it closes, and the treasury's batch on its own.
        vm.warp(votes.executableAt(proposalId));
        uint256 firstPay = usdc.balanceOf(address(treasury)) * 100 / 1e6;
        votes.execute(proposalId, calls);
        _log("execute, a one-payment proposal");
        assertEq(usdc.balanceOf(OPERATOR), firstPay, "paid its share");
        uint256 secondPay = usdc.balanceOf(address(treasury)) * 100 / 1e6;
        vm.prank(address(votes));
        treasury.executeBatch(calls);
        _log("executeBatch, one payment");
        assertEq(usdc.balanceOf(OPERATOR), firstPay + secondPay, "paid its share again");
    }

    /// @dev A creator makes a Classic fleet at the lowest start price and buys its key 1.
    function _createFleet() private returns (KeyfleetManager created) {
        uint256 startPrice = KeyfleetPresets.MIN_START_USDC;
        KeyfleetFactory.FleetTerms memory terms = KeyfleetFactory.FleetTerms({
            preset: KeyfleetPresets.Preset.FleetTechClassic,
            startPrice: startPrice,
            accelerantStepPercent: 0,
            profile: KeyfleetManager.Profile("A creator's fleet", "", ""),
            requirements: KeyfleetManager.Requirements(bytes32(0), address(0), address(0), 0),
            deadline: block.timestamp
        });
        deal(address(usdc), CREATOR, startPrice);
        vm.prank(CREATOR);
        usdc.approve(address(factory), startPrice);
        vm.prank(CREATOR);
        (uint256 fleetId, uint256 tokenId) = factory.createFleet(terms);
        _log("createFleet, a Classic fleet at 10 USDC with its key 1");
        assertEq(keys.ownerOf(tokenId), CREATOR, "the creator holds key 1");
        created = _fleet(fleetId);
        assertEq(created.totalMinted(), 1, "of the new fleet");
    }

    /// @dev The gas of the call just made.
    function _log(string memory call) private view {
        console2.log(call, vm.lastCallGas().gasTotalUsed);
    }
}
