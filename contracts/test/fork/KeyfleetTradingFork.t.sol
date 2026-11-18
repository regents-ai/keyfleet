// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetTradingFactory} from "../../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../../src/KeyfleetTradingTreasury.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {DeployTradingFactory} from "../../script/DeployTradingFactory.s.sol";
import {KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {RecordKeyfleets} from "../../script/RecordKeyfleets.s.sol";
import {IRegentRevenueStakingViews} from "./KeyfleetBaseFork.t.sol";

/// @dev A Trading Fleet on the live Keyfleet collection, on a fork of Base at its latest block: the
/// real collection and its factory as deployed, real USDC and real REGENT revenue staking. On the
/// fork only, the Regents Safe's address creates the founding fleets still missing and steps the
/// phases with the release's own Safe steps; the trading factory is deployed by
/// `DeployTradingFactory` and the Safe's address makes the call that script prints. Nothing is
/// signed or sent to Base.
///
/// It runs only when `BASE_RPC_URL` is set in the environment and skips itself otherwise; the URL is
/// never printed:
///
///     forge test --match-contract KeyfleetTradingForkTest -vv
///
/// It logs the gas of a purchase, a creator's payback and a daily payback. Those are whole
/// transactions, the 21,000 base and the call data included and every account cold, only when Forge
/// runs each call as a transaction of its own; add `--isolate` for the figures to quote.
contract KeyfleetTradingForkTest is Test {
    /// @dev The live collection and the factory that deployed it, read from Base on 18 November 2026.
    KeyfleetKeys private constant COLLECTION = KeyfleetKeys(0xaBC959B463542497639adA57388c65D05AB34A30);
    KeyfleetFactory private constant FLEETS = KeyfleetFactory(0x82F62aE092DcF99fFa7fF15a9ac63488D5b4F5C7);
    address private constant SAFE = 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e;
    address private constant STAKING = 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address private constant CREATOR = address(0xC4EA70);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant DESK = address(0xDE5C);

    bytes32 private constant USDC_REVENUE_DEPOSITED =
        keccak256("USDCRevenueDeposited(uint256,uint256,uint256,uint8,address,bytes32,bytes32)");

    IERC20 private usdc;
    IRegentRevenueStakingViews private staking;
    KeyfleetTradingFactory private trading;
    uint256 private fleetsBefore;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        KeyfleetSafeSteps steps = new KeyfleetSafeSteps();
        KeyfleetManifest.Manifest memory manifest = steps.readManifest("base");
        usdc = IERC20(BASE_USDC);
        staking = IRegentRevenueStakingViews(STAKING);
        fleetsBefore = COLLECTION.fleetCount();

        // The release's Safe steps, from the Safe's address on the fork: the founding fleets each
        // phase needs, then the next phase, until the last is open.
        while (COLLECTION.phase() < COLLECTION.FINAL_PHASE()) {
            KeyfleetSafeSteps.SafeCall[] memory founding = steps.foundingFleetCalls(manifest, FLEETS);
            for (uint256 i = 0; i < founding.length; ++i) {
                _asSafe(founding[i]);
            }
            _asSafe(steps.advancePhaseCalls(manifest, FLEETS, uint64(block.timestamp + 1))[0]);
            vm.warp(block.timestamp + 1);
        }

        DeployTradingFactory deployer = new DeployTradingFactory();
        trading = deployer.deploy(manifest, FLEETS);
        _asSafe(deployer.addFactoryCall(trading));
    }

    /// @dev The live system is what the trading factory is built for, and it reads every binding
    /// from the live factory.
    function test_theTradingFactoryReadsTheLiveSystem() public view {
        assertEq(address(FLEETS.KEYS()), address(COLLECTION), "the live factory's collection");
        assertEq(COLLECTION.SAFE(), SAFE, "run by the Regents Safe");
        assertEq(address(trading.KEYS()), address(COLLECTION), "the same collection");
        assertEq(address(trading.SHARDS()), address(FLEETS.SHARDS()), "the same shard record");
        assertEq(address(trading.USDC()), BASE_USDC, "real USDC");
        assertEq(address(trading.REGENT_STAKING()), STAKING, "real REGENT revenue staking");
        assertTrue(COLLECTION.isFactory(address(trading)), "added by the Safe");
        assertTrue(COLLECTION.isFactory(address(FLEETS)), "beside the existing factory");
        assertEq(COLLECTION.phase(), COLLECTION.FINAL_PHASE(), "the last phase is open");
        assertGe(COLLECTION.fleetCount(), COLLECTION.FOUNDING_FLEETS(), "every founding fleet exists");
    }

    /// @dev A Trading Fleet's whole life on real USDC and real staking: creation, sales, a trade
    /// out and back with a profit, a creator's payback and a daily payback into real staking, a
    /// claim, the authority passing with Key 1, the close, and paying back everything.
    function test_aTradingFleetOnTheLiveCollection() public {
        KeyfleetTradingManager fleet = _create();
        uint256 fleetId = fleet.FLEET_ID();
        assertEq(fleetId, COLLECTION.fleetCount(), "the newest fleet");
        assertEq(COLLECTION.fleetCount(), _max(fleetsBefore, COLLECTION.FOUNDING_FLEETS()) + 1, "one more fleet");
        assertEq(uint256(COLLECTION.fleet(fleetId).preset), uint256(KeyfleetPresets.Preset.FleetTechAccelerant));
        assertEq(COLLECTION.ownerOf(_key(fleet, 1)), CREATOR, "Key 1 to the creator");
        assertEq(usdc.balanceOf(address(fleet.TREASURY())), 25e6, "paid into the treasury");

        _sell(fleet);
        _tradeOutAndBack(fleet.TREASURY());
        vm.warp(block.timestamp + 2 days);
        uint256 owed = _creatorsPayback(fleet);
        owed += _dailyPayback(fleet);
        _claim(fleet, owed);
        _passKeyOne(fleet);
        _closeAndPayBackAll(fleet);
    }

    /// @dev Alice and Bob buy Keys 2 to 4.
    function _sell(KeyfleetTradingManager fleet) private {
        _buy(fleet, ALICE);
        _buy(fleet, BOB);
        _logGas("purchase, Key 3");
        _buy(fleet, BOB);
        assertEq(fleet.totalMinted(), 4);
        assertEq(COLLECTION.revealRequestedAt(_key(fleet, 2)), 0, "no deck yet, so no draw is asked for");
    }

    /// @dev Everything out to the trading desk and back with 40 USDC more.
    function _tradeOutAndBack(KeyfleetTradingTreasury treasury) private {
        uint256 raised = usdc.balanceOf(address(treasury));
        vm.startPrank(CREATOR);
        treasury.setTradingWallet(DESK);
        treasury.sendToTrading(raised);
        vm.stopPrank();
        assertEq(usdc.balanceOf(DESK), raised, "the whole pot traded");
        deal(BASE_USDC, DESK, raised + 40e6);
        vm.prank(DESK);
        usdc.transfer(address(treasury), raised + 40e6);
    }

    /// @dev The creator pays back 50 USDC into real staking and the ledger; returns each Key's part.
    function _creatorsPayback(KeyfleetTradingManager fleet) private returns (uint256 perKey) {
        KeyfleetTradingTreasury treasury = fleet.TREASURY();
        uint256 receivedBefore = staking.totalUsdcReceived();
        uint256 amount = 50e6;
        uint256 staked = Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil);
        perKey = (amount - staked) / 4;
        vm.recordLogs();
        vm.prank(CREATOR);
        treasury.payback(amount);
        _logGas("payback by the creator, the fleet's first, four Keys");
        assertEq(staking.totalUsdcReceived() - receivedBefore, staked, "1% counted as revenue by staking");
        _assertDeposit(treasury, fleet, staked);
        assertEq(usdc.allowance(address(treasury), STAKING), 0, "no approval left");
        assertEq(fleet.REWARDS().accrued(BASE_USDC, _key(fleet, 3)), perKey, "each Key its share");
    }

    /// @dev Alice runs the daily payback; returns each Key's part.
    function _dailyPayback(KeyfleetTradingManager fleet) private returns (uint256 perKey) {
        KeyfleetTradingTreasury treasury = fleet.TREASURY();
        uint256 receivedBefore = staking.totalUsdcReceived();
        uint256 daily = usdc.balanceOf(address(treasury)) * treasury.DAILY_PAYBACK_BPS() / 10_000;
        uint256 staked = Math.mulDiv(daily, 100, 10_000, Math.Rounding.Ceil);
        perKey = (daily - staked) / 4;
        vm.prank(ALICE);
        treasury.runDailyPayback();
        _logGas("runDailyPayback, a later payback, four Keys");
        assertEq(staking.totalUsdcReceived() - receivedBefore, staked, "the daily 1% too");
        assertEq(usdc.allowance(address(treasury), STAKING), 0, "no approval left");
    }

    /// @dev Alice claims both paybacks for Key 2 in real USDC.
    function _claim(KeyfleetTradingManager fleet, uint256 owed) private {
        uint256 aliceBefore = usdc.balanceOf(ALICE);
        address[] memory assets = new address[](1);
        assets[0] = BASE_USDC;
        uint256[] memory ids = new uint256[](1);
        ids[0] = _key(fleet, 2);
        KeyfleetRewards rewards = fleet.REWARDS();
        vm.prank(ALICE);
        rewards.claim(ids, assets);
        assertEq(usdc.balanceOf(ALICE) - aliceBefore, owed, "both paybacks claimed");
    }

    /// @dev Key 1 passes to Bob, and the fleet's authority with it.
    function _passKeyOne(KeyfleetTradingManager fleet) private {
        uint256 first = _key(fleet, 1);
        vm.prank(CREATOR);
        COLLECTION.transferFrom(CREATOR, BOB, first);
        assertEq(fleet.creator(), BOB);
        KeyfleetTradingTreasury treasury = fleet.TREASURY();
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, CREATOR));
        treasury.sendToTrading(1);
    }

    /// @dev Bob closes; sales end; anyone pays back everything.
    function _closeAndPayBackAll(KeyfleetTradingManager fleet) private {
        KeyfleetTradingTreasury treasury = fleet.TREASURY();
        vm.prank(BOB);
        treasury.close();
        deal(BASE_USDC, ALICE, 1_000e6);
        vm.prank(ALICE);
        usdc.approve(address(fleet), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(KeyfleetTradingManager.SalesEnded.selector);
        fleet.purchase(ALICE, type(uint256).max, block.timestamp, new bytes32[](0));
        treasury.paybackAll();
        assertLt(usdc.balanceOf(address(treasury)), 4, "less than a unit per Key stays");
        KeyfleetRewards rewards = fleet.REWARDS();
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(BASE_USDC), "the ledger holds what it owes");
    }

    /// @dev The gas of the call just made, which is the whole transaction's under `--isolate`.
    function _logGas(string memory call) private view {
        console2.log(string.concat("gas on the fork, real USDC and staking: ", call), vm.lastCallGas().gasTotalUsed);
    }

    /// @dev The record of the live system lists the Trading Fleet as one beside the live fleets.
    /// A fleet past the founding ones is recorded only while the Regents Safe owns the VRF
    /// subscription and the collection is on it, so on the fork the subscription's owner hands it to
    /// the Safe and the Safe lists the collection first.
    function test_theRecordListsTheTradingFleetBesideTheLiveFleets() public {
        KeyfleetTradingManager fleet = _create();
        _subscriptionToTheSafe();
        RecordKeyfleets recorder = new RecordKeyfleets();

        string memory json = recorder.record(
            recorder.readManifest("base"), KeyfleetManifest.BroadcastSummary({factory: FLEETS, deploymentBlock: 1})
        );

        string memory entry = string.concat(".fleets.", vm.toString(fleet.FLEET_ID()));
        assertEq(vm.parseJsonString(json, string.concat(entry, ".type")), "trading", "Marked as a Trading Fleet");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".tradingFactory")), address(trading), "Factory");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".manager")), address(fleet), "Manager");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".treasury")), address(fleet.TREASURY()), "Treasury");
        assertEq(vm.parseJsonAddress(json, string.concat(entry, ".rewards")), address(fleet.REWARDS()), "Ledger");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".firstPrice")), 25e6, "First price");
        assertEq(vm.parseJsonUint(json, string.concat(entry, ".dailyPaybackBps")), 50, "Daily payback");
        string[5] memory types = ["classic", "syndicate", "accelerant", "cascade", "regentsClub"];
        for (uint256 fleetId = 1; fleetId <= 5; ++fleetId) {
            assertEq(
                vm.parseJsonString(json, string.concat(".fleets.", vm.toString(fleetId), ".type")),
                types[fleetId - 1],
                "Founding fleet as before"
            );
        }
    }

    /// @dev On the fork only: the subscription's owner hands it to the Regents Safe, which accepts
    /// it and lists the collection.
    function _subscriptionToTheSafe() private {
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId,) = COLLECTION.randomness();
        (,,, address owner,) = coordinator.getSubscription(subscriptionId);
        if (owner != SAFE) {
            vm.prank(owner);
            coordinator.requestSubscriptionOwnerTransfer(subscriptionId, SAFE);
            vm.prank(SAFE);
            coordinator.acceptSubscriptionOwnerTransfer(subscriptionId);
        }
        vm.prank(SAFE);
        coordinator.addConsumer(subscriptionId, address(COLLECTION));
    }

    /// @dev While its owner, the Regents Safe, has staking paused, every payback reverts and nothing
    /// moves; once unpaused it goes through.
    function test_aPausedStakingHoldsEveryPayback() public {
        KeyfleetTradingManager fleet = _create();
        KeyfleetTradingTreasury treasury = fleet.TREASURY();
        vm.warp(block.timestamp + 2 days);
        assertEq(staking.owner(), SAFE, "the Regents Safe owns staking");

        vm.prank(SAFE);
        staking.setPaused(true);
        vm.prank(CREATOR);
        vm.expectRevert();
        treasury.payback(10e6);
        vm.expectRevert();
        treasury.runDailyPayback();
        assertEq(usdc.balanceOf(address(treasury)), 25e6, "nothing moved");

        vm.prank(SAFE);
        staking.setPaused(false);
        vm.prank(CREATOR);
        treasury.payback(10e6);
    }

    function _create() private returns (KeyfleetTradingManager fleet) {
        KeyfleetTradingFactory.TradingTerms memory terms;
        terms.profile = KeyfleetManager.Profile("A trading fleet", "Trades its pot.", "");
        terms.firstPrice = 25e6;
        terms.stepBps = 250;
        terms.dailyPaybackBps = 50;
        terms.deadline = block.timestamp;
        deal(BASE_USDC, CREATOR, terms.firstPrice);
        vm.prank(CREATOR);
        usdc.approve(address(trading), terms.firstPrice);
        vm.prank(CREATOR);
        (uint256 fleetId,) = trading.create(terms);
        _logGas("create, with Key 1");
        fleet = KeyfleetTradingManager(COLLECTION.managerOf(fleetId));
    }

    function _buy(KeyfleetTradingManager fleet, address buyer) private {
        uint256 price = fleet.price();
        deal(BASE_USDC, buyer, price);
        vm.prank(buyer);
        usdc.approve(address(fleet), price);
        vm.prank(buyer);
        fleet.purchase(buyer, price, block.timestamp, new bytes32[](0));
    }

    function _key(KeyfleetTradingManager fleet, uint256 keyNumber) private view returns (uint256) {
        return COLLECTION.tokenIdOf(fleet.FLEET_ID(), keyNumber);
    }

    function _asSafe(KeyfleetSafeSteps.SafeCall memory call) private {
        vm.prank(SAFE);
        Address.functionCall(call.to, call.data);
    }

    /// @dev Staking's own revenue event names the treasury as depositor, the fleet's manager as the
    /// source and the trading payback tag.
    function _assertDeposit(KeyfleetTradingTreasury treasury, KeyfleetTradingManager fleet, uint256 amount) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != STAKING || log.topics[0] != USDC_REVENUE_DEPOSITED) continue;
            assertEq(address(uint160(uint256(log.topics[2]))), address(treasury), "the treasury deposited");
            assertEq(log.topics[3], bytes32(uint256(uint160(address(fleet)))), "for this fleet's manager");
            (uint256 deposited,,, bytes32 tag) = abi.decode(log.data, (uint256, uint256, uint256, bytes32));
            assertEq(deposited, amount, "the 1%");
            assertEq(tag, treasury.STAKING_SOURCE_TAG(), "tagged as a trading payback");
            return;
        }
        revert("no USDCRevenueDeposited from staking");
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}
