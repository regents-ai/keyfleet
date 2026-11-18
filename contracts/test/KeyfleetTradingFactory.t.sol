// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetDeployer} from "../src/KeyfleetDeployers.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTradingFactory} from "../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../src/KeyfleetTradingTreasury.sol";
import {TradingWiring} from "../src/KeyfleetTradingWiring.sol";
import {FleetWiring, IKeyfleetFactory, KeyfleetWiring} from "../src/KeyfleetWiring.sol";
import {KeyfleetTradingFixture} from "./helpers/KeyfleetTradingFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Creates a Trading Fleet as its own creator, and tries to create another from inside the
/// mint of its Key 1.
contract ReenteringTradingCreator {
    KeyfleetTradingFactory private immutable _factory;
    KeyfleetTradingFactory.TradingTerms private _terms;
    bool private _reenter;

    constructor(KeyfleetTradingFactory factory) {
        _factory = factory;
    }

    function create(KeyfleetTradingFactory.TradingTerms calldata terms, bool reenter) external {
        _terms = terms;
        _reenter = reenter;
        MockToken(address(_factory.USDC())).approve(address(_factory), type(uint256).max);
        _factory.create(terms);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (_reenter) _factory.create(_terms);
        return this.onERC721Received.selector;
    }
}

/// @dev A deployer of anyone's that names the real trading factory as its own, as the real
/// deployers do, and builds a fleet's contracts directly.
contract SpoofTradingDeployer {
    address private immutable _factory;

    constructor(address factory) {
        _factory = factory;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function FACTORY() external view returns (address) {
        return _factory;
    }

    function deployManager() external returns (address) {
        return address(new KeyfleetTradingManager());
    }

    function deployTreasury() external returns (address) {
        return address(new KeyfleetTradingTreasury());
    }

    function deployRewards() external returns (address) {
        return address(new KeyfleetRewards());
    }
}

contract KeyfleetTradingFactoryTest is KeyfleetTradingFixture {
    function setUp() public {
        _setUpTrading();
    }

    // --- construction -------------------------------------------------------

    function test_constructorReadsEveryBindingFromTheExistingFactory() public view {
        assertEq(address(trading.KEYS()), address(factory.KEYS()));
        assertEq(address(trading.SHARDS()), address(factory.SHARDS()));
        assertEq(address(trading.USDC()), address(factory.USDC()));
        assertEq(address(trading.REGENT_STAKING()), address(factory.REGENT_STAKING()));
        assertEq(address(trading.MANAGER_DEPLOYER().FACTORY()), address(trading));
        assertEq(address(trading.TREASURY_DEPLOYER().FACTORY()), address(trading));
        assertEq(address(trading.REWARDS_DEPLOYER().FACTORY()), address(trading));
    }

    function test_deployersRefuseAnyoneButTheFactory() public {
        KeyfleetDeployer[3] memory deployers =
            [trading.MANAGER_DEPLOYER(), trading.TREASURY_DEPLOYER(), trading.REWARDS_DEPLOYER()];
        for (uint256 i = 0; i < deployers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetDeployer.OnlyFactory.selector, address(this)));
            deployers[i].deploy(99);
        }
    }

    function test_wiringIsEmptyOutsideACreation() public {
        _createTrading();
        TradingWiring memory t = trading.tradingWiring();
        assertEq(t.fleetId, 0);
        assertEq(t.manager, address(0));
        assertEq(t.treasury, address(0));
        assertEq(t.rewards, address(0));
        assertEq(t.firstPrice + t.stepBps + t.dailyPaybackBps + t.keyCap, 0);
        FleetWiring memory w = trading.wiring();
        assertEq(w.fleetId, 0);
        assertEq(uint256(w.preset), 0);
        assertEq(w.manager, address(0));
    }

    // --- create ---------------------------------------------------------------

    function test_createRegistersDeploysAndSellsKeyOne() public {
        uint256 accelerants = keys.typeCount(KeyfleetPresets.Preset.FleetTechAccelerant);
        uint256 fleetId = keys.nextFleetId(KeyfleetPresets.Preset.FleetTechAccelerant);
        (address manager, address treasury_, address rewards_) = trading.predict(fleetId);

        _createTrading();

        assertEq(fleet.FLEET_ID(), fleetId);
        assertEq(address(fleet), manager);
        assertEq(address(treasury), treasury_);
        assertEq(address(rewards), rewards_);
        assertEq(keys.managerOf(fleetId), manager);
        assertEq(uint256(keys.fleet(fleetId).preset), uint256(KeyfleetPresets.Preset.FleetTechAccelerant));
        assertEq(keys.fleet(fleetId).deckHash, bytes32(0));
        assertEq(keys.typeCount(KeyfleetPresets.Preset.FleetTechAccelerant), accelerants + 1);
        assertTrue(keys.salesOpen(fleetId));

        // Bound to each other and to the shared contracts.
        assertEq(fleet.FACTORY(), address(trading));
        assertEq(address(fleet.KEYS()), address(keys));
        assertEq(address(fleet.USDC()), address(usdc));
        assertEq(address(treasury.MANAGER()), manager);
        assertEq(address(treasury.REWARDS()), rewards_);
        assertEq(address(treasury.USDC()), address(usdc));
        assertEq(address(treasury.REGENT_STAKING()), address(staking));
        assertEq(treasury.DAILY_PAYBACK_BPS(), DAILY_BPS);
        assertEq(rewards.FLEET_ID(), fleetId);
        assertEq(address(rewards.MANAGER()), manager);
        assertEq(address(rewards.TREASURY()), treasury_);
        assertEq(address(rewards.KEYS()), address(keys));
        assertEq(rewards.USDC(), address(usdc));
        assertEq(address(rewards.SHARDS()), address(shards));

        // Key 1 belongs to the creator, paid at the first price straight into the treasury.
        assertEq(keys.ownerOf(_tkey(1)), creator);
        assertEq(fleet.creator(), creator);
        assertEq(fleet.totalMinted(), 1);
        assertEq(usdc.balanceOf(address(treasury)), FIRST_PRICE);
        assertEq(usdc.balanceOf(creator), 0);
        assertEq(usdc.balanceOf(address(trading)), 0);
        assertEq(usdc.balanceOf(address(fleet)), 0);
        assertEq(fleet.FIRST_PRICE(), FIRST_PRICE);
        assertEq(fleet.price(), FIRST_PRICE + FIRST_PRICE * STEP_BPS / 10_000);
        assertEq(fleet.stepBps(), STEP_BPS);
        assertEq(rewards.cohortSize(0), 1);
        assertEq(rewards.keyCohort(_tkey(1)), 0);
        assertEq(fleet.profile().name, "Trading fleet");
        assertTrue(fleet.initialized());
    }

    function test_createAnnouncesEverythingTheSiteNeeds() public {
        uint256 fleetId = keys.nextFleetId(KeyfleetPresets.Preset.FleetTechAccelerant);
        uint256 typeNumber = keys.typeCount(KeyfleetPresets.Preset.FleetTechAccelerant) + 1;
        (address manager, address treasury_, address rewards_) = trading.predict(fleetId);
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 50);
        terms.requirements.merkleRoot = keccak256("list");
        usdc.mint(creator, FIRST_PRICE);
        vm.startPrank(creator);
        usdc.approve(address(trading), FIRST_PRICE);

        vm.expectEmit(address(keys));
        emit KeyfleetKeys.FleetRegistered(
            fleetId, KeyfleetPresets.Preset.FleetTechAccelerant, typeNumber, manager, address(trading)
        );
        vm.expectEmit(address(trading));
        emit KeyfleetTradingFactory.TradingFleetCreated(
            fleetId,
            creator,
            typeNumber,
            manager,
            treasury_,
            rewards_,
            FIRST_PRICE,
            STEP_BPS,
            DAILY_BPS,
            50,
            terms.profile,
            terms.requirements
        );
        trading.create(terms);
        vm.stopPrank();
    }

    function test_creatorsKeyOneSkipsTheJoiningRequirements() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.merkleRoot = keccak256("a list without the creator");
        _createTrading(terms);
        assertEq(keys.ownerOf(_tkey(1)), creator);
        assertFalse(fleet.meetsRequirements(creator, new bytes32[](0)));
    }

    function test_eachCreationIsANewFleet() public {
        KeyfleetTradingManager first = _createTrading();
        KeyfleetTradingManager second = _createTrading();
        assertEq(second.FLEET_ID(), first.FLEET_ID() + 1);
        assertTrue(address(second.TREASURY()) != address(first.TREASURY()));
        assertTrue(address(second.REWARDS()) != address(first.REWARDS()));
    }

    function test_createRefusedBeforeTheLastPhase() public {
        _setUpFixture();
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        trading = new KeyfleetTradingFactory(IKeyfleetFactory(address(factory)));
        vm.prank(safe);
        keys.addFactory(address(trading));
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingFactory.CreationClosed.selector, uint8(3)));
        trading.create(terms);
    }

    function test_createRefusedUntilTheSafeAddsTheFactory() public {
        KeyfleetTradingFactory unlisted = new KeyfleetTradingFactory(IKeyfleetFactory(address(factory)));
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        usdc.mint(creator, FIRST_PRICE);
        vm.startPrank(creator);
        usdc.approve(address(unlisted), FIRST_PRICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyFactory.selector, address(unlisted)));
        unlisted.create(terms);
        vm.stopPrank();
    }

    function test_createRefusedAfterItsDeadline() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingFactory.Expired.selector, terms.deadline));
        trading.create(terms);
    }

    function test_createRefusedWithoutTheFirstPrice() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        usdc.mint(creator, FIRST_PRICE - 1);
        vm.startPrank(creator);
        usdc.approve(address(trading), FIRST_PRICE);
        vm.expectRevert();
        trading.create(terms);
        vm.stopPrank();
        assertEq(usdc.balanceOf(creator), FIRST_PRICE - 1);
    }

    function test_firstPriceOutOfRangeStopsTheCreation() public {
        uint256[2] memory bad = [MIN_PRICE - 1, MAX_PRICE + 1];
        for (uint256 i = 0; i < bad.length; ++i) {
            KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(bad[i], STEP_BPS, DAILY_BPS, 0);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.PriceInvalid.selector, bad[i]));
            vm.prank(creator);
            trading.create(terms);
        }
    }

    function test_stepAboveOneHundredPercentStopsTheCreation() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, 10_001, DAILY_BPS, 0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.StepInvalid.selector, 10_001));
        vm.prank(creator);
        trading.create(terms);
    }

    function test_dailyPaybackOutOfRangeStopsTheCreation() public {
        uint256[2] memory bad = [uint256(9), 201];
        for (uint256 i = 0; i < bad.length; ++i) {
            KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, bad[i], 0);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.DailyPaybackInvalid.selector, bad[i]));
            vm.prank(creator);
            trading.create(terms);
        }
    }

    function test_keyCapAboveTheCollectionLimitStopsTheCreation() public {
        uint256 cap = keys.MAX_KEY_NUMBER() + 1;
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, cap);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.KeyCapInvalid.selector, cap));
        vm.prank(creator);
        trading.create(terms);
    }

    function test_badProfileOrRequirementsStopTheCreation() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.profile.name = "";
        vm.expectRevert(KeyfleetTradingManager.ProfileInvalid.selector);
        vm.prank(creator);
        trading.create(terms);

        terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.nft = makeAddr("no code");
        vm.expectRevert(KeyfleetTradingManager.RequirementsInvalid.selector);
        vm.prank(creator);
        trading.create(terms);
    }

    function test_creatorCannotCreateAgainFromInsideTheMintOfKeyOne() public {
        ReenteringTradingCreator reenterer = new ReenteringTradingCreator(trading);
        usdc.mint(address(reenterer), 2 * FIRST_PRICE);
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        reenterer.create(terms, true);

        reenterer.create(terms, false);
        assertEq(usdc.balanceOf(address(reenterer)), FIRST_PRICE);
    }

    /// @dev Outside a creation the factory holds no wiring, so each of a fleet's three contracts
    /// refuses to be built, whether by the factory's own deployer at the next fleet's address or by
    /// a deployer of anyone's that names the real factory.
    function test_managerTreasuryAndLedgerCannotBeDeployedOutsideACreation() public {
        uint256 next = keys.nextFleetId(trading.PRESET());
        (address manager, address treasury_, address rewards_) = trading.predict(next);
        KeyfleetDeployer[3] memory deployers =
            [trading.MANAGER_DEPLOYER(), trading.TREASURY_DEPLOYER(), trading.REWARDS_DEPLOYER()];
        address[3] memory predicted = [manager, treasury_, rewards_];
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(address(trading));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetWiring.NotWired.selector, predicted[i]));
            deployers[i].deploy(next);
        }

        SpoofTradingDeployer spoof = new SpoofTradingDeployer(address(trading));
        address at = vm.computeCreateAddress(address(spoof), vm.getNonce(address(spoof)));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetWiring.NotWired.selector, at));
        spoof.deployManager();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetWiring.NotWired.selector, at));
        spoof.deployTreasury();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetWiring.NotWired.selector, at));
        spoof.deployRewards();
    }

    function testFuzz_createAcceptsEveryTermInRange(uint256 firstPrice, uint256 stepBps, uint256 dailyBps, uint256 cap)
        public
    {
        firstPrice = bound(firstPrice, MIN_PRICE, MAX_PRICE);
        stepBps = bound(stepBps, 0, 10_000);
        dailyBps = bound(dailyBps, 10, 200);
        cap = bound(cap, 0, keys.MAX_KEY_NUMBER());
        _createTrading(_tradingTerms(firstPrice, stepBps, dailyBps, cap));
        assertEq(usdc.balanceOf(address(treasury)), firstPrice);
        assertEq(fleet.FIRST_PRICE(), firstPrice);
        assertEq(fleet.KEY_CAP(), cap);
        assertEq(treasury.DAILY_PAYBACK_BPS(), dailyBps);
        assertEq(fleet.price(), fleet.raised(firstPrice, stepBps));
    }
}
