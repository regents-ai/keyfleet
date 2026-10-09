// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetDeployer, KeyfleetManagerDeployer} from "../src/KeyfleetDeployers.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {FleetWiring, IKeyfleetFactory} from "../src/KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {KeyfleetSystem} from "../script/KeyfleetSystem.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockWeth} from "./mocks/MockWeth.sol";

/// @dev Names a factory and deploys a manager, as a deployer would, to show a manager deploys only
/// at the address the factory's own creation gives it.
contract RogueDeployer {
    IKeyfleetFactory public immutable FACTORY;

    constructor(IKeyfleetFactory factory) {
        FACTORY = factory;
    }

    function deployManager(bytes32 salt) external returns (address) {
        return address(new KeyfleetManager{salt: salt}());
    }
}

/// @dev Calls the factory back from inside a creation: as the creator's `onERC721Received` or as
/// the REGENT pool's hook.
contract ReenteringCreator {
    KeyfleetFactory private immutable _factory;
    bytes private _call;

    constructor(KeyfleetFactory factory) {
        _factory = factory;
    }

    function arm(bytes calldata call) external {
        _call = call;
    }

    function create(KeyfleetFactory.FleetTerms calldata terms) external returns (uint256 fleetId) {
        (fleetId,) = _factory.createFleet(terms);
    }

    function approve(MockToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (_call.length != 0) {
            (bool ok, bytes memory reason) = address(_factory).call(_call);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
        return this.onERC721Received.selector;
    }
}

contract KeyfleetFactoryTest is KeyfleetFixture {
    uint256 private constant GAS_CAP = 16_777_216;

    function setUp() public {
        _setUpFixture();
    }

    // --- deployment ----------------------------------------------------------

    function test_DeploymentBindsTheSharedContracts() public view {
        assertEq(factory.SAFE(), safe);
        assertEq(address(factory.KEYS()), address(keys));
        assertEq(address(shards.KEYS()), address(keys));
        assertEq(address(factory.USDC()), address(usdc));
        assertEq(address(factory.REGENT()), address(regent));
        assertEq(address(factory.REGENT_STAKING()), address(staking));
        assertEq(address(factory.AUTOLAUNCH()), address(autolaunch));
        assertEq(address(regentBuyer.USDC()), address(usdc));
        assertEq(address(regentBuyer.REGENT()), address(regent));
        assertTrue(keys.isFactory(address(factory)));
        assertEq(keys.SAFE(), safe);
        assertEq(keys.keeper(), keeper);
        assertEq(keys.name(), "Keyfleet");
        assertEq(keys.symbol(), "KEYFLEET");
        assertEq(keys.phase(), 0);
        assertEq(keys.fleetCount(), 0);
        assertEq(address(factory.MANAGER_DEPLOYER().FACTORY()), address(factory));
        assertEq(address(factory.VOTES_DEPLOYER().FACTORY()), address(factory));
        assertEq(address(factory.TREASURY_DEPLOYER().FACTORY()), address(factory));
        assertEq(address(factory.REWARDS_DEPLOYER().FACTORY()), address(factory));
    }

    function test_WiringIsEmptyOutsideACreation() public {
        _assertWiringEmpty();
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _assertWiringEmpty();
    }

    function test_FactoryRefusesADeployerOfAnotherFactory() public {
        KeyfleetSystem.Bindings memory bindings = _bindings();
        KeyfleetDeployer stray = new KeyfleetManagerDeployer(IKeyfleetFactory(address(0xdead)));
        KeyfleetDeployer good = new KeyfleetManagerDeployer(IKeyfleetFactory(address(0xbeef)));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.DeployerMismatch.selector, address(stray)));
        new KeyfleetFactory(_config(bindings, stray, good, good, good));
    }

    function test_FactoryRefusesStakingOrAutolaunchWithoutCode() public {
        KeyfleetSystem.Bindings memory bindings = _bindings();
        bindings.staking = IRegentRevenueStaking(address(0x1234));
        KeyfleetDeployer any = new KeyfleetManagerDeployer(IKeyfleetFactory(address(0xbeef)));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.BindingMissing.selector, address(0x1234)));
        new KeyfleetFactory(_config(bindings, any, any, any, any));
    }

    function test_FactoryRefusesAUsdcWithoutSixDecimals() public {
        KeyfleetSystem.Bindings memory bindings = _bindings();
        MockWeth eighteen = new MockWeth();
        bindings.route.usdc = address(eighteen);
        KeyfleetDeployer any = new KeyfleetManagerDeployer(IKeyfleetFactory(address(0xbeef)));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.UsdcDecimalsWrong.selector, uint8(18)));
        new KeyfleetFactory(_config(bindings, any, any, any, any));
    }

    function test_DeployersDeployOnlyForTheirFactory() public {
        KeyfleetDeployer deployer = factory.MANAGER_DEPLOYER();
        vm.expectRevert(abi.encodeWithSelector(KeyfleetDeployer.OnlyFactory.selector, address(this)));
        deployer.deploy(1);
    }

    function test_AManagerDeploysOnlyAtTheAddressACreationGivesIt() public {
        RogueDeployer rogue = new RogueDeployer(factory);
        vm.expectRevert();
        rogue.deployManager(bytes32(uint256(1)));
    }

    function test_AManagerCannotBeDeployedOutsideTheFactory() public {
        vm.expectRevert();
        new KeyfleetManager();
    }

    // --- founding fleets -------------------------------------------------------

    function test_SafeCreatesTheFoundingFleetsInOrder() public {
        KeyfleetPresets.Preset[4] memory order = [
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FleetTechAccelerant,
            KeyfleetPresets.Preset.FibonacciCascade
        ];
        for (uint256 i = 0; i < 4; ++i) {
            uint256 id = i + 1;
            (address manager, address votes, address treasury, address rewards) = factory.predict(id);
            vm.expectEmit(address(factory));
            uint256 step = order[i] == KeyfleetPresets.Preset.FleetTechAccelerant
                ? KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT
                : 0;
            emit KeyfleetFactory.FleetCreated(
                id, order[i], 1, safe, KeyfleetPresets.Q_USDC, step, manager, votes, treasury, rewards
            );
            KeyfleetManager fleet = _createFounding(order[i]);
            assertEq(address(fleet), manager);
            _assertBound(fleet, id, order[i]);
            assertEq(fleet.START_PRICE(), KeyfleetPresets.Q_USDC);
            assertEq(fleet.ACCELERANT_STEP_PERCENT(), step);
            (bytes32 deckHash, uint256 deckSize) = keys.deckOf(id);
            assertEq(deckHash, _deckHash(id));
            assertEq(deckSize, DECK_SIZE);
            assertFalse(keys.salesOpen(id));
            assertEq(fleet.totalMinted(), 0);
        }
        assertEq(KeyfleetManager(keys.managerOf(1)).nextPrice(), 10e6);
        assertEq(KeyfleetManager(keys.managerOf(2)).nextPrice(), 10e6);
        assertEq(KeyfleetManager(keys.managerOf(3)).nextPrice(), 10e6);
        assertEq(KeyfleetManager(keys.managerOf(4)).nextPrice(), 10e6);
    }

    function test_FoundingFleetHasTheSafesProfileAndNoRequirements() public {
        KeyfleetManager fleet = _createFounding(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager.Profile memory profile = fleet.profile();
        assertEq(profile.name, "Founding fleet");
        assertEq(profile.imageLink, "https://media.regents.sh/ipfs/fleet");
        KeyfleetManager.Requirements memory req = fleet.requirements();
        assertEq(req.merkleRoot, bytes32(0));
        assertEq(req.nft, address(0));
        assertEq(req.token, address(0));
        assertTrue(fleet.meetsRequirements(address(0xABCD), new bytes32[](0)));
        assertTrue(fleet.initialized());
    }

    function test_OnlyTheSafeCreatesFoundingFleets() public {
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.OnlySafe.selector, address(this)));
        factory.createFoundingFleet(
            KeyfleetPresets.Preset.FleetTechClassic, _deckHash(1), DECK_SIZE, _profile("Founding fleet")
        );
    }

    function test_ClubCanBeCreatedFirstAndClassicLaterWithoutReplacingItsSlot() public {
        KeyfleetManager club = _createFounding(KeyfleetPresets.Preset.RegentsClub);
        assertEq(club.FLEET_ID(), 5);
        assertEq(keys.fleetCount(), 5);
        assertFalse(keys.fleetExists(1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.UnknownFleet.selector, 1));
        keys.managerOf(1);
        _advancePhase();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.FleetsMissing.selector, 2, 1));
        keys.advancePhase(uint64(block.timestamp + 1));
        KeyfleetManager classic = _createFounding(KeyfleetPresets.Preset.FleetTechClassic);
        assertEq(classic.FLEET_ID(), 1);
        assertEq(keys.fleetCount(), 5);
        assertEq(keys.managerOf(5), address(club));
        _advancePhase();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.FleetsMissing.selector, 5, 2));
        keys.advancePhase(uint64(block.timestamp + 1));
    }

    function test_FoundingFleetsNeedADeck() public {
        vm.startPrank(safe);
        vm.expectRevert(KeyfleetKeys.DeckInvalid.selector);
        factory.createFoundingFleet(KeyfleetPresets.Preset.FleetTechClassic, bytes32(0), DECK_SIZE, _profile("F"));
        vm.expectRevert(KeyfleetKeys.DeckInvalid.selector);
        factory.createFoundingFleet(KeyfleetPresets.Preset.FleetTechClassic, _deckHash(1), 0, _profile("F"));
        vm.stopPrank();
    }

    function test_ASixthFoundingFleetIsRefused() public {
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        address manager = keys.managerOf(1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.ManagerTaken.selector, manager));
        factory.createFoundingFleet(KeyfleetPresets.Preset.FleetTechClassic, _deckHash(6), DECK_SIZE, _profile("F"));
    }

    function test_FoundingFleetsCannotBeCreatedInPhaseFour() public {
        _openCreation();
        vm.prank(safe);
        vm.expectRevert(KeyfleetKeys.DeckGivenAtCreation.selector);
        factory.createFoundingFleet(KeyfleetPresets.Preset.FleetTechClassic, _deckHash(5), DECK_SIZE, _profile("F"));
    }

    function test_FoundingFleetRefusesAnInvalidProfile() public {
        vm.prank(safe);
        vm.expectRevert(KeyfleetManager.ProfileInvalid.selector);
        factory.createFoundingFleet(KeyfleetPresets.Preset.FleetTechClassic, _deckHash(1), DECK_SIZE, _profile(""));
    }

    // --- open fleets -----------------------------------------------------------

    function test_OpenCreationIsClosedBeforePhaseFour() public {
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager.Requirements memory anyone;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.CreationClosed.selector, uint8(3)));
        factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone));
    }

    /// @dev Invariant: in phase 4, open creation waits for the moment the Safe chose, to the second.
    function test_OpenCreationWaitsForPhaseFourToOpen() public {
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint64 opensAt = uint64(block.timestamp + 2 days);
        vm.prank(safe);
        keys.advancePhase(opensAt);
        assertEq(keys.phase(), keys.FINAL_PHASE());

        KeyfleetManager.Requirements memory anyone;
        usdc.mint(creator, 10e6);
        vm.startPrank(creator);
        usdc.approve(address(factory), 10e6);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.CreationClosed.selector, uint8(4)));
        factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone));
        vm.warp(opensAt);
        (uint256 fleetId,) = factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone));
        vm.stopPrank();
        assertTrue(keys.salesOpen(fleetId), "and the new fleet sells at once");
    }

    function test_CreatorBuysKeyOneOfTheirFleet() public {
        _openCreation();
        uint256 price = 25e6;
        usdc.mint(creator, price);
        KeyfleetManager.Requirements memory anyone;
        uint256 id = keys.fleetCount() + 1;
        (address manager,, address treasury,) = factory.predict(id);

        vm.startPrank(creator);
        usdc.approve(address(factory), price);
        (uint256 fleetId, uint256 tokenId) =
            factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, price, anyone));
        vm.stopPrank();

        assertEq(fleetId, id);
        assertEq(tokenId, keys.tokenIdOf(id, 1));
        assertEq(keys.ownerOf(tokenId), creator);
        assertEq(keys.managerOf(id), manager);
        assertTrue(keys.salesOpen(id));
        KeyfleetManager fleet = KeyfleetManager(manager);
        _assertBound(fleet, id, KeyfleetPresets.Preset.FibonacciSyndicate);
        assertEq(fleet.START_PRICE(), price);
        assertEq(fleet.totalMinted(), 1);
        assertEq(fleet.protocolShareOwed(), price / 10);
        assertEq(fleet.pendingConversion(), price - price / 10, "the treasury's part is booked");
        assertEq(usdc.balanceOf(manager), price, "and both parts stay in the manager");
        assertEq(regent.balanceOf(treasury), 0, "nothing is swapped in the creation");
        assertEq(regentBuyer.nextInQueue(), manager, "the fleet is queued");
        assertEq(usdc.balanceOf(creator), 0);
        assertEq(usdc.balanceOf(address(factory)), 0);
        assertEq(usdc.allowance(creator, address(factory)), 0);
        (bytes32 deckHash, uint256 deckSize) = keys.deckOf(id);
        assertEq(deckHash, bytes32(0));
        assertEq(deckSize, 0);
        assertEq(keys.revealRequestedAt(tokenId), 0);
        assertEq(keys.fleet(id).typeNumber, 2);
        _assertWiringEmpty();
    }

    function test_OpenFleetPricesScaleFromTheStartPrice() public {
        KeyfleetManager classic = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 16e6);
        assertEq(classic.nextPrice(), KeyfleetPresets.classicPrice(2, 16e6));
        KeyfleetManager accelerant = _createOpen(KeyfleetPresets.Preset.FleetTechAccelerant, 20e6);
        assertEq(accelerant.nextPrice(), 21e6);
        KeyfleetManager cascade = _createOpen(KeyfleetPresets.Preset.FibonacciCascade, 100e6);
        assertEq(cascade.nextPrice(), 100e6);
    }

    function test_OpenFleetRefusesAStartPriceOutOfBoundsOrNotInCents() public {
        _openCreation();
        KeyfleetManager.Requirements memory anyone;
        uint256[4] memory bad = [uint256(9_990_000), 1_000_000_010_000, 10_000_001, 12_345_678];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.StartPriceInvalid.selector, bad[i]));
            factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, bad[i], anyone));
        }
    }

    function test_OpenFleetAcceptsTheBoundStartPrices() public {
        KeyfleetManager low = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6);
        assertEq(low.START_PRICE(), 10e6);
        KeyfleetManager high = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 1_000_000e6);
        assertEq(high.START_PRICE(), 1_000_000e6);
        assertEq(KeyfleetPresets.MAX_START_USDC, 1_000_000e6);
    }

    function test_OpenFleetRefusesAPassedDeadline() public {
        _openCreation();
        KeyfleetManager.Requirements memory anyone;
        KeyfleetFactory.FleetTerms memory terms = _terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetFactory.Expired.selector, terms.deadline));
        factory.createFleet(terms);
    }

    function test_OpenFleetNeedsTheCreatorsUsdc() public {
        _openCreation();
        KeyfleetManager.Requirements memory anyone;
        usdc.mint(creator, 10e6);
        vm.prank(creator);
        vm.expectRevert();
        factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone));
        assertEq(keys.fleetCount(), 5);
    }

    function test_OpenFleetStoresItsRequirements() public {
        MockToken pass = new MockToken("Pass", "PASS");
        KeyfleetManager.Requirements memory req = KeyfleetManager.Requirements({
            merkleRoot: keccak256("root"), nft: address(0), token: address(pass), tokenMin: 5
        });
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, req);
        KeyfleetManager.Requirements memory stored = fleet.requirements();
        assertEq(stored.merkleRoot, req.merkleRoot);
        assertEq(stored.token, address(pass));
        assertEq(stored.tokenMin, 5);
        assertEq(keys.ownerOf(_key(fleet, 1)), creator);
    }

    function test_OpenFleetRefusesInvalidRequirements() public {
        _openCreation();
        KeyfleetManager.Requirements[3] memory bad = [
            KeyfleetManager.Requirements({merkleRoot: 0, nft: address(0x1234), token: address(0), tokenMin: 0}),
            KeyfleetManager.Requirements({merkleRoot: 0, nft: address(0), token: address(usdc), tokenMin: 0}),
            KeyfleetManager.Requirements({merkleRoot: 0, nft: address(0), token: address(0), tokenMin: 1})
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(KeyfleetManager.RequirementsInvalid.selector);
            factory.createFleet(_terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, bad[i]));
        }
    }

    function test_OpenFleetRefusesAnInvalidProfile() public {
        _openCreation();
        KeyfleetManager.Requirements memory anyone;
        KeyfleetFactory.FleetTerms memory terms = _terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone);
        terms.profile.name = string(new bytes(101));
        vm.expectRevert(KeyfleetManager.ProfileInvalid.selector);
        factory.createFleet(terms);
        terms.profile.name = "ok";
        terms.profile.description = string(new bytes(2001));
        vm.expectRevert(KeyfleetManager.ProfileInvalid.selector);
        factory.createFleet(terms);
        terms.profile.description = "";
        terms.profile.imageLink = string(new bytes(513));
        vm.expectRevert(KeyfleetManager.ProfileInvalid.selector);
        factory.createFleet(terms);
    }

    function test_FleetNumbersAreGlobalAndTypeNumbersPerType() public {
        _createOpen(KeyfleetPresets.Preset.FibonacciCascade, 10e6);
        _createOpen(KeyfleetPresets.Preset.FibonacciCascade, 10e6);
        _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        assertEq(keys.fleetCount(), 8);
        assertEq(keys.fleet(6).typeNumber, 2);
        assertEq(keys.fleet(7).typeNumber, 3);
        assertEq(keys.fleet(8).typeNumber, 2);
    }

    function test_CreatorCannotCreateAnotherFleetFromInsideTheirOwn() public {
        _openCreation();
        ReenteringCreator wallet = new ReenteringCreator(factory);
        KeyfleetManager.Requirements memory anyone;
        KeyfleetFactory.FleetTerms memory terms = _terms(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, anyone);
        wallet.arm(abi.encodeCall(KeyfleetFactory.createFleet, (terms)));
        usdc.mint(address(wallet), 10e6);
        wallet.approve(usdc, address(factory), 10e6);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        wallet.create(terms);
    }

    // --- gas -------------------------------------------------------------------

    function test_GasOfCreatingEachTypeOfOpenFleetFitsOneTransaction() public {
        _openCreation();
        KeyfleetPresets.Preset[4] memory all = [
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FleetTechAccelerant,
            KeyfleetPresets.Preset.FibonacciCascade
        ];
        KeyfleetManager.Requirements memory anyone;
        for (uint256 i = 0; i < all.length; ++i) {
            KeyfleetFactory.FleetTerms memory terms = _terms(all[i], 10e6, anyone);
            terms.profile.description = string(new bytes(2000));
            terms.profile.imageLink = string(new bytes(512));
            usdc.mint(creator, 10e6);
            vm.startPrank(creator);
            usdc.approve(address(factory), 10e6);
            uint256 before = gasleft();
            factory.createFleet(terms);
            uint256 used = before - gasleft();
            vm.stopPrank();
            emit log_named_uint("open fleet creation gas", used);
            assertLt(used, GAS_CAP);
        }
    }

    function test_GasOfCreatingAFoundingFleet() public {
        uint256 before = gasleft();
        _createFounding(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 used = before - gasleft();
        emit log_named_uint("founding fleet creation gas", used);
        assertLt(used, GAS_CAP);
    }

    // --- helpers ---------------------------------------------------------------

    function _assertBound(KeyfleetManager fleet, uint256 id, KeyfleetPresets.Preset preset) private view {
        (address manager, address votesAt, address treasuryAt, address rewardsAt) = factory.predict(id);
        assertEq(address(fleet), manager);
        assertEq(fleet.FLEET_ID(), id);
        assertEq(uint8(fleet.PRESET()), uint8(preset));
        assertEq(fleet.FACTORY(), address(factory));
        assertEq(address(fleet.KEYS()), address(keys));
        assertEq(address(fleet.USDC()), address(usdc));
        assertEq(address(fleet.REGENT_BUYER()), address(regentBuyer));
        assertEq(address(fleet.VOTES()), votesAt);
        assertEq(address(fleet.TREASURY()), treasuryAt);
        assertEq(address(fleet.REWARDS()), rewardsAt);
        assertEq(keys.fleetOfManager(manager), id);
        assertEq(uint8(keys.fleet(id).preset), uint8(preset));

        KeyfleetVotes votes = KeyfleetVotes(votesAt);
        assertEq(votes.FLEET_ID(), id);
        assertEq(address(votes.MANAGER()), manager);
        assertEq(address(votes.KEYS()), address(keys));
        assertEq(address(votes.SHARDS()), address(shards));
        assertEq(address(votes.TREASURY()), treasuryAt);

        KeyfleetTreasury treasury = KeyfleetTreasury(payable(treasuryAt));
        assertEq(address(treasury.MANAGER()), manager);
        assertEq(address(treasury.VOTES()), votesAt);
        assertEq(address(treasury.REWARDS()), rewardsAt);
        assertEq(address(treasury.USDC()), address(usdc));
        assertEq(address(treasury.REGENT()), address(regent));
        assertEq(address(treasury.REGENT_STAKING()), address(staking));
        assertEq(address(treasury.AUTOLAUNCH()), address(autolaunch));

        KeyfleetRewards rewards = KeyfleetRewards(payable(rewardsAt));
        assertEq(rewards.FLEET_ID(), id);
        assertEq(address(rewards.MANAGER()), manager);
        assertEq(address(rewards.KEYS()), address(keys));
        assertEq(rewards.USDC(), address(usdc));
        assertEq(address(rewards.TREASURY()), treasuryAt);
        assertEq(address(rewards.SHARDS()), address(shards));
    }

    function _assertWiringEmpty() private view {
        FleetWiring memory w = factory.wiring();
        assertEq(w.fleetId, 0);
        assertEq(uint8(w.preset), 0);
        assertEq(w.startPrice, 0);
        assertEq(w.accelerantStepPercent, 0);
        assertEq(w.manager, address(0));
        assertEq(w.votes, address(0));
        assertEq(w.treasury, address(0));
        assertEq(w.rewards, address(0));
    }

    function _config(
        KeyfleetSystem.Bindings memory b,
        KeyfleetDeployer manager,
        KeyfleetDeployer votes,
        KeyfleetDeployer treasury,
        KeyfleetDeployer rewards
    ) private pure returns (KeyfleetFactory.Config memory) {
        return KeyfleetFactory.Config({
            safe: b.safe,
            keeper: b.keeper,
            staking: b.staking,
            autolaunch: b.autolaunch,
            clubPass: b.clubPass,
            collection: b.collection,
            randomness: b.randomness,
            traitTableHash: b.traitTableHash,
            route: b.route,
            managerDeployer: manager,
            votesDeployer: votes,
            treasuryDeployer: treasury,
            rewardsDeployer: rewards
        });
    }
}
