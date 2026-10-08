// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

contract KeyfleetKeysTest is KeyfleetFixture {
    using stdStorage for StdStorage;

    string private constant BASE_URI = "https://keyfleet.ai/keys/";
    string private constant CONTRACT_URI = "https://keyfleet.ai/collection.json";

    StdStorage private keysStore;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);

    function setUp() public {
        _setUpFixture();
    }

    // --- helpers ---------------------------------------------------------

    /// @dev Funds and approves `fleet`'s next price for the buyer and expects the purchase to be
    /// refused because the fleet's sales are not open yet.
    function _expectSalesClosed(KeyfleetManager fleet) private {
        uint256 fleetId = fleet.FLEET_ID();
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.SalesClosed.selector, fleetId));
        fleet.purchase(alice, price, block.timestamp, new bytes32[](0));
        usdc.approve(address(fleet), 0);
        vm.stopPrank();
    }

    /// @dev Moves to the next phase as the Safe and waits for its opening.
    function _advance() private {
        _advancePhase();
    }

    /// @dev A second from now: the soonest a phase may open.
    function _soon() private view returns (uint64) {
        return uint64(block.timestamp + 1);
    }

    /// @dev Makes this test contract a factory, so it can register fleets directly.
    function _becomeFactory() private {
        vm.prank(safe);
        keys.addFactory(address(this));
    }

    // --- 1. the collection --------------------------------------------------

    /// @dev Invariant: every fleet's keys are one collection named Keyfleet, and a key's metadata
    /// is the fixed base plus its token id, with no setter and no per-key storage; an unminted id has
    /// no metadata.
    function test_tokenUriIsTheFixedBasePlusTheTokenId() public {
        KeyfleetManager classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager cascade = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        uint256 first = _buy(classic, alice);
        uint256 other = _buy(cascade, alice);

        assertEq(keys.name(), "Keyfleet");
        assertEq(keys.symbol(), "KEYFLEET");
        assertEq(keys.baseTokenURI(), BASE_URI);
        assertEq(first, 10_000_000_001, "fleet 1, key 1");
        assertEq(other, 40_000_000_001, "fleet 4, key 1");
        assertEq(keys.tokenURI(first), string.concat(BASE_URI, "10000000001"));
        assertEq(keys.tokenURI(other), string.concat(BASE_URI, "40000000001"));

        uint256 unminted = _key(classic, 2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        keys.tokenURI(unminted);
    }

    /// @dev Invariant: the collection reports ERC-165, ERC-721 with metadata, ERC-4906 and ERC-2981,
    /// and nothing it does not implement.
    function test_supportsInterfaceCoversErc721Erc4906AndErc2981() public view {
        assertTrue(keys.supportsInterface(type(IERC165).interfaceId));
        assertTrue(keys.supportsInterface(type(IERC721).interfaceId));
        assertTrue(keys.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(keys.supportsInterface(bytes4(0x49064906)), "ERC-4906 metadata updates");
        assertTrue(keys.supportsInterface(type(IERC2981).interfaceId), "ERC-2981 royalties");
        assertFalse(keys.supportsInterface(0xffffffff));
        assertFalse(keys.supportsInterface(0x12345678));
    }

    /// @dev Invariant: every key of every fleet, founding or open, pays 2.5% of its sale price to the
    /// Regents Safe, and the collection's own metadata is at a fixed address.
    function test_everyKeyPaysTwoAndAHalfPercentRoyaltyToTheSafe() public {
        KeyfleetManager founding = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetManager open = _createOpen(KeyfleetPresets.Preset.FleetTechAccelerant, 20e6);
        uint256[3] memory tokenIds = [_buy(founding, alice), _key(open, 1), uint256(0)];

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            (address receiver, uint256 amount) = keys.royaltyInfo(tokenIds[i], 10_000e6);
            assertEq(receiver, safe, "the Safe is paid");
            assertEq(amount, 250e6, "2.5%");
        }
        (, uint256 small) = keys.royaltyInfo(tokenIds[0], 39);
        assertEq(small, 0, "rounds down");
        assertEq(keys.ROYALTY_BPS(), 250);
        assertEq(keys.contractURI(), CONTRACT_URI);
    }

    /// @dev Invariant: the royalty is exactly a fortieth of any sale price, rounded down, for any key.
    function testFuzz_royaltyIsAFortiethOfAnyPrice(uint256 tokenId, uint256 salePrice) public view {
        salePrice = bound(salePrice, 0, type(uint256).max / 250);
        (address receiver, uint256 amount) = keys.royaltyInfo(tokenId, salePrice);
        assertEq(receiver, safe);
        assertEq(amount, salePrice * 250 / 10_000);
    }

    // --- 2. token ids ---------------------------------------------------------

    /// @dev Invariant: a token id is the fleet times ten billion plus the key number, and every key
    /// number a fleet can mint fits below the stride, so two fleets' keys never share an id.
    function test_tokenIdMathAndTheFleetBound() public view {
        assertEq(keys.TOKEN_ID_STRIDE(), 10_000_000_000);
        assertEq(keys.MAX_KEY_NUMBER(), type(uint32).max);
        assertLt(keys.MAX_KEY_NUMBER(), keys.TOKEN_ID_STRIDE(), "a key number never reaches the next fleet");
        assertEq(keys.MAX_FLEETS(), 999_999_999);

        assertEq(keys.tokenIdOf(1, 1), 10_000_000_001);
        assertEq(keys.tokenIdOf(4, 46_365), 40_000_046_365);
        uint256 last = keys.tokenIdOf(keys.MAX_FLEETS(), keys.MAX_KEY_NUMBER());
        assertEq(last, 9_999_999_994_294_967_295, "the highest id there can be");
        assertEq(keys.fleetOf(last), keys.MAX_FLEETS());
        assertEq(keys.keyNumberOf(last), keys.MAX_KEY_NUMBER());
        assertEq(keys.tokenIdOf(2, keys.MAX_KEY_NUMBER()) + 1 < keys.tokenIdOf(3, 1), true, "fleets never overlap");
    }

    /// @dev Invariant: the id helpers round-trip for every fleet and key number a fleet can mint.
    function testFuzz_tokenIdsRoundTrip(uint256 fleetId, uint256 keyNumber) public view {
        fleetId = bound(fleetId, 1, keys.MAX_FLEETS());
        keyNumber = bound(keyNumber, 1, keys.MAX_KEY_NUMBER());
        uint256 tokenId = keys.tokenIdOf(fleetId, keyNumber);
        assertEq(keys.fleetOf(tokenId), fleetId);
        assertEq(keys.keyNumberOf(tokenId), keyNumber);
    }

    /// @dev Invariant: no more than `MAX_FLEETS` fleets are ever registered. The count is written
    /// directly to just below the bound, since registering almost a billion fleets is not practical.
    function test_registryStopsAtTheMaximumNumberOfFleets() public {
        _openCreation();
        _becomeFactory();
        uint256 max = keys.MAX_FLEETS();
        keysStore.target(address(keys)).sig("fleetCount()").checked_write(max - 1);

        (uint256 fleetId,) = keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, address(0xF1), 0, 0);
        assertEq(fleetId, max, "the last fleet there can be");
        assertTrue(keys.salesOpen(max));

        vm.expectRevert(KeyfleetKeys.TooManyFleets.selector);
        keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, address(0xF2), 0, 0);
        assertEq(keys.fleetCount(), max);
    }

    // --- 3. phases --------------------------------------------------------------

    /// @dev Invariant: only the Safe moves the phase, one step at a time and only forwards: phase 1
    /// needs fleet 1, phase 2 needs all four founding fleets, and there is nothing after phase 3.
    function test_phasesMoveOneStepAtATimeOnlyForwardAndOnlyByTheSafe() public {
        assertEq(keys.phase(), 0);
        address[4] memory strangers = [alice, keeper, address(factory), creator];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlySafe.selector, strangers[i]));
            keys.advancePhase(_soon());
        }

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.FleetsMissing.selector, 1, 0));
        keys.advancePhase(_soon());

        _createFounding(KeyfleetPresets.Preset.FleetTechClassic);
        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.PhaseAdvanced(1, _soon());
        _advance();
        assertEq(keys.phase(), 1);

        _createFounding(KeyfleetPresets.Preset.FibonacciSyndicate);
        _createFounding(KeyfleetPresets.Preset.FleetTechAccelerant);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.FleetsMissing.selector, 4, 3));
        keys.advancePhase(_soon());
        assertEq(keys.phase(), 1, "a refused step changes nothing");

        _createFounding(KeyfleetPresets.Preset.FibonacciCascade);
        _advance();
        assertEq(keys.phase(), 2, "one step, never two");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlySafe.selector, alice));
        keys.advancePhase(_soon());

        _advance();
        assertEq(keys.phase(), keys.FINAL_PHASE());
        vm.prank(safe);
        vm.expectRevert(KeyfleetKeys.NoNextPhase.selector);
        keys.advancePhase(_soon());
        assertEq(keys.phase(), 3, "and it never goes back");
    }

    /// @dev Invariant: sales open per fleet with the phase: fleet 1 from phase 1, fleets 2 to 4 from
    /// phase 2, and an open fleet as soon as it exists. A purchase before its fleet's phase is
    /// refused, with no USDC taken; a fleet that does not exist is never open.
    function test_salesOpenPerFleetWithThePhase() public {
        KeyfleetManager classic = _createFounding(KeyfleetPresets.Preset.FleetTechClassic);
        assertFalse(keys.salesOpen(0), "there is no fleet 0");
        assertFalse(keys.salesOpen(1), "phase 0 sells nothing");
        assertFalse(keys.salesOpen(2), "an unregistered fleet is never open");
        _expectSalesClosed(classic);

        _advance();
        assertTrue(keys.salesOpen(1), "fleet 1 opens in phase 1");
        _buy(classic, alice);

        KeyfleetManager syndicate = _createFounding(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetManager accelerant = _createFounding(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetManager cascade = _createFounding(KeyfleetPresets.Preset.FibonacciCascade);
        for (uint256 id = 2; id <= 4; ++id) {
            assertFalse(keys.salesOpen(id), "fleets 2 to 4 wait for phase 2");
        }
        _expectSalesClosed(syndicate);
        _expectSalesClosed(accelerant);
        _expectSalesClosed(cascade);
        assertEq(usdc.balanceOf(address(syndicate)), 0, "a refused purchase took nothing");

        _advance();
        for (uint256 id = 1; id <= 4; ++id) {
            assertTrue(keys.salesOpen(id), "every founding fleet sells in phase 2");
        }
        _buy(syndicate, alice);
        _buy(accelerant, alice);
        _buy(cascade, alice);
        assertFalse(keys.salesOpen(5));

        KeyfleetManager open = _createOpen(KeyfleetPresets.Preset.FibonacciCascade, 10e6);
        assertEq(open.FLEET_ID(), 5);
        assertTrue(keys.salesOpen(5), "an open fleet sells from its creation");
        _buy(open, alice);
        assertFalse(keys.salesOpen(6));
    }

    /// @dev Invariant: the Safe names when each phase opens, always in the future, at most 30 days
    /// ahead, and never before the phase before it opened. A fleet's sales stay closed until that moment, to the second,
    /// and open at it without anyone acting.
    function test_aPhaseOpensAtItsChosenTimeAndNotBefore() public {
        KeyfleetManager classic = _createFounding(KeyfleetPresets.Preset.FleetTechClassic);
        uint64[2] memory notFuture = [uint64(block.timestamp), uint64(block.timestamp - 1)];
        for (uint256 i = 0; i < notFuture.length; ++i) {
            vm.prank(safe);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OpensAtInvalid.selector, notFuture[i]));
            keys.advancePhase(notFuture[i]);
        }

        assertEq(keys.MAX_OPENING_LEAD(), 30 days);
        uint64 tooFar = uint64(block.timestamp + 30 days + 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OpensAtInvalid.selector, tooFar));
        keys.advancePhase(tooFar);
        uint256 fresh = vm.snapshotState();
        vm.prank(safe);
        keys.advancePhase(tooFar - 1);
        assertEq(keys.phaseOpensAt(), tooFar - 1, "exactly 30 days ahead is allowed");
        vm.revertToState(fresh);

        uint64 opensAt = uint64(block.timestamp + 3 days);
        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.PhaseAdvanced(1, opensAt);
        vm.prank(safe);
        keys.advancePhase(opensAt);
        assertEq(keys.phase(), 1, "the phase moves at once");
        assertEq(keys.phaseOpensAt(), opensAt, "and records when it opens");
        assertEq(keys.salesOpenAt(1), opensAt, "fleet 1 opens then");
        assertFalse(keys.salesOpen(1), "but not before");
        _expectSalesClosed(classic);
        vm.warp(opensAt - 1);
        assertFalse(keys.salesOpen(1), "not even a second before");
        _expectSalesClosed(classic);
        vm.warp(opensAt);
        assertTrue(keys.salesOpen(1), "and at that second, by itself");
        _buy(classic, alice);

        _createFounding(KeyfleetPresets.Preset.FibonacciSyndicate);
        _createFounding(KeyfleetPresets.Preset.FleetTechAccelerant);
        _createFounding(KeyfleetPresets.Preset.FibonacciCascade);
        uint64 later = uint64(block.timestamp + 10 days);
        vm.prank(safe);
        keys.advancePhase(later);
        uint64 earlier = later - 1;
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OpensAtInvalid.selector, earlier));
        keys.advancePhase(earlier);
        assertEq(keys.phase(), 2, "a refused step changes nothing");
        for (uint256 id = 2; id <= 4; ++id) {
            assertEq(keys.salesOpenAt(id), later, "fleets 2 to 4 open together");
            assertFalse(keys.salesOpen(id));
        }
        vm.prank(safe);
        keys.advancePhase(later);
        assertEq(keys.phase(), 3, "the next phase may open at the same moment");
        vm.warp(later);
        for (uint256 id = 1; id <= 4; ++id) {
            assertTrue(keys.salesOpen(id), "every founding fleet sells once phase 2 opens");
        }
    }

    // --- 4. the Safe's settings ------------------------------------------------

    /// @dev Invariant: only the Safe names the keeper, never the zero address, and the old keeper
    /// loses its rights with the change.
    function test_onlyTheSafeNamesTheKeeper() public {
        address next = makeAddr("next keeper");
        address[4] memory strangers = [alice, keeper, address(factory), creator];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlySafe.selector, strangers[i]));
            keys.setKeeper(next);
        }
        vm.prank(safe);
        vm.expectRevert(KeyfleetKeys.ZeroAddress.selector);
        keys.setKeeper(address(0));

        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.KeeperSet(next);
        vm.prank(safe);
        keys.setKeeper(next);
        assertEq(keys.keeper(), next);

        uint256 tokenId = _buy(_deploy(KeyfleetPresets.Preset.FleetTechClassic), alice);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.NotOwnerOrKeeper.selector, tokenId, keeper));
        keys.refreshMetadata(tokenId);
        vm.prank(next);
        keys.refreshMetadata(tokenId);
    }

    /// @dev Invariant: only the Safe adds a factory, and only a contract; an added factory may
    /// register fleets and existing fleets do not change.
    function test_onlyTheSafeAddsAFactoryAndOnlyAContract() public {
        KeyfleetManager classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        address[4] memory strangers = [alice, keeper, address(factory), creator];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlySafe.selector, strangers[i]));
            keys.addFactory(address(this));
        }
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.FactoryMissing.selector, alice));
        keys.addFactory(alice);
        assertFalse(keys.isFactory(alice));
        assertFalse(keys.isFactory(address(this)));

        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.FactoryAdded(address(this));
        _becomeFactory();
        assertTrue(keys.isFactory(address(this)));
        assertTrue(keys.isFactory(address(factory)), "the first factory stays");
        assertEq(keys.managerOf(1), address(classic), "existing fleets do not change");
    }

    // --- 5. the registry ------------------------------------------------------

    /// @dev Invariant: only a factory registers a fleet, never for the zero address, and a manager
    /// is registered to one fleet only.
    function test_onlyAFactoryRegistersAFleetAndAManagerOnlyOnce() public {
        _openCreation();
        address manager = address(0xF1);
        address[4] memory strangers = [alice, safe, keeper, address(_deploy(KeyfleetPresets.Preset.FleetTechClassic))];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyFactory.selector, strangers[i]));
            keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, manager, 0, 0);
        }

        _becomeFactory();
        vm.expectRevert(KeyfleetKeys.ZeroAddress.selector);
        keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, address(0), 0, 0);

        uint256 before = keys.fleetCount();
        (uint256 fleetId, uint256 typeNumber) =
            keys.registerFleet(KeyfleetPresets.Preset.FibonacciCascade, manager, 0, 0);
        assertEq(fleetId, before + 1);
        assertEq(typeNumber, keys.typeCount(KeyfleetPresets.Preset.FibonacciCascade));
        assertEq(keys.fleetOfManager(manager), fleetId);
        assertEq(keys.managerOf(fleetId), manager);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.ManagerTaken.selector, manager));
        keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, manager, 0, 0);
        address founding = keys.managerOf(1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.ManagerTaken.selector, founding));
        keys.registerFleet(KeyfleetPresets.Preset.FleetTechClassic, founding, 0, 0);
        assertEq(keys.fleetCount(), fleetId, "a refused registration adds nothing");
    }

    // --- 6. minting -----------------------------------------------------------

    /// @dev Invariant: only a registered manager mints, and only into its own fleet: the mint takes
    /// no fleet, so a manager cannot place a key in another fleet's range. Key numbers run from 1 to
    /// `MAX_KEY_NUMBER`.
    function test_aManagerMintsOnlyIntoItsOwnFleet() public {
        KeyfleetManager classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);

        address[5] memory strangers = [alice, safe, keeper, address(factory), address(classic.TREASURY())];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyManager.selector, strangers[i]));
            keys.mint(alice, 1);
        }

        vm.prank(address(accelerant));
        uint256 tokenId = keys.mint(alice, 7);
        assertEq(tokenId, keys.tokenIdOf(3, 7), "the key is in the minting manager's own fleet");
        assertEq(keys.ownerOf(tokenId), alice);
        uint256 sameNumberInFleetOne = keys.tokenIdOf(1, 7);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, sameNumberInFleetOne));
        keys.ownerOf(sameNumberInFleetOne);

        uint256 tooHigh = keys.MAX_KEY_NUMBER() + 1;
        vm.startPrank(address(classic));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.KeyNumberOutOfRange.selector, 0));
        keys.mint(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.KeyNumberOutOfRange.selector, tooHigh));
        keys.mint(alice, tooHigh);
        uint256 highest = keys.mint(alice, tooHigh - 1);
        vm.stopPrank();
        assertEq(highest, keys.tokenIdOf(1, keys.MAX_KEY_NUMBER()));
        assertEq(keys.fleetOf(highest), 1, "the highest key number stays in its fleet");
    }

    // --- 7. metadata refreshes ---------------------------------------------------

    /// @dev Invariant: only a fleet's manager asks for every key of that fleet to be refreshed, and
    /// the refresh covers exactly that fleet's id range.
    function test_onlyAManagerRefreshesItsOwnFleet() public {
        KeyfleetManager syndicate = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        address[5] memory strangers = [alice, safe, keeper, address(factory), address(syndicate.TREASURY())];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyManager.selector, strangers[i]));
            keys.refreshFleet();
        }

        uint256 first = keys.tokenIdOf(2, 1);
        uint256 last = keys.tokenIdOf(2, keys.MAX_KEY_NUMBER());
        vm.expectEmit(true, true, true, true, address(keys));
        emit IERC4906.BatchMetadataUpdate(first, last);
        vm.prank(address(syndicate));
        keys.refreshFleet();
        assertLt(last, keys.tokenIdOf(3, 1), "and never reaches the next fleet");
    }

    /// @dev Invariant: a key's metadata is refreshed by its current owner or the keeper only, and
    /// only for a key that exists.
    function test_aKeysOwnerOrTheKeeperRefreshesItsMetadata() public {
        KeyfleetManager classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 tokenId = _buy(classic, alice);

        vm.expectEmit(true, true, true, true, address(keys));
        emit IERC4906.MetadataUpdate(tokenId);
        vm.prank(alice);
        keys.refreshMetadata(tokenId);
        vm.prank(keeper);
        keys.refreshMetadata(tokenId);

        address[4] memory strangers = [bob, safe, address(classic), address(factory)];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.NotOwnerOrKeeper.selector, tokenId, strangers[i]));
            keys.refreshMetadata(tokenId);
        }

        vm.prank(alice);
        keys.transferFrom(alice, bob, tokenId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.NotOwnerOrKeeper.selector, tokenId, alice));
        keys.refreshMetadata(tokenId);
        vm.prank(bob);
        keys.refreshMetadata(tokenId);

        uint256 unminted = tokenId + 1;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        keys.refreshMetadata(unminted);
    }

    // --- 8. ownership epochs and the transfer hook --------------------------------

    /// @dev Invariant: the epoch counts ownership changes, so a key returning to a previous owner
    /// carries a strictly higher epoch than it did the first time, and each key counts its own. The
    /// mint time is written at the mint and no transfer moves it.
    function test_epochIncrementsOnMintAndOnEveryTransferIncludingAReturn() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 k1 = _key(fleet, 1);
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.prank(buyer);
        usdc.approve(address(fleet), price);

        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.OwnershipEpoch(k1, 1, address(0), alice);
        vm.prank(buyer);
        fleet.purchase(alice, price, block.timestamp, new bytes32[](0));
        assertEq(keys.ownershipEpoch(k1), 1, "the mint is epoch 1");
        assertEq(keys.mintedAt(k1), block.timestamp, "the mint time is recorded");
        uint256 mintedAt = block.timestamp;

        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.OwnershipEpoch(k1, 2, alice, bob);
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        assertEq(keys.ownershipEpoch(k1), 2);
        assertEq(keys.mintedAt(k1), mintedAt, "a transfer keeps the mint time");

        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.OwnershipEpoch(k1, 3, bob, alice);
        vm.prank(bob);
        keys.transferFrom(bob, alice, k1);
        assertEq(keys.ownershipEpoch(k1), 3, "returning to Alice is a third epoch");
        assertEq(keys.mintedAt(k1), mintedAt, "and so does a return");
        assertEq(keys.mintedAt(_key(fleet, 2)), 0, "a key not minted has no time");

        uint256 k2 = _buy(fleet, carol);
        assertEq(keys.ownershipEpoch(k2), 1, "each key counts its own epochs");
        uint256 otherFleetKey = _buy(_deploy(KeyfleetPresets.Preset.FleetTechAccelerant), alice);
        assertEq(keys.ownershipEpoch(otherFleetKey), 1, "and so does each fleet's key 1");
    }

    /// @dev Invariant: on a transfer the key's own manager hears first, settling what the key earned
    /// to the seller, then the epoch moves, then ownership changes.
    function test_aTransferSettlesThenBumpsTheEpochThenMovesTheKey() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        uint256 k1 = _buy(fleet, alice);
        for (uint256 i = 0; i < 4; ++i) {
            _buy(fleet, _wallet(i));
        }
        assertTrue(fleet.levelCompleted(2));
        uint256 owed = rewards.accrued(address(usdc), k1);
        assertGt(owed, 0, "key 1 has a repayment to settle");

        vm.recordLogs();
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 settledAt = type(uint256).max;
        uint256 epochAt = type(uint256).max;
        uint256 transferAt = type(uint256).max;
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(rewards) && topic == KeyfleetRewards.Settled.selector) {
                settledAt = i;
                assertEq(uint256(logs[i].topics[1]), k1);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), alice, "settled to the seller");
            } else if (logs[i].emitter == address(keys) && topic == KeyfleetKeys.OwnershipEpoch.selector) {
                epochAt = i;
            } else if (logs[i].emitter == address(keys) && topic == IERC721.Transfer.selector) {
                transferAt = i;
            }
        }
        assertLt(settledAt, epochAt, "the manager settles before the epoch moves");
        assertLt(epochAt, transferAt, "and the epoch moves before ownership changes");
        assertLt(transferAt, logs.length);
        assertEq(rewards.credits(address(usdc), alice), owed);
    }

    /// @dev Invariant: a caller who may not move a key is refused with ERC-721's approval error
    /// before the key's manager hears anything; an approved operator then moves it through the
    /// manager as the owner would.
    function test_anUnapprovedTransferIsRefusedBeforeTheManagerHears() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);

        vm.expectCall(address(fleet), abi.encodeCall(KeyfleetManager.onKeyMoved, (k1, alice)), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, k1));
        keys.transferFrom(alice, bob, k1);
        assertEq(keys.ownershipEpoch(k1), 1, "nothing moved");

        vm.prank(bob);
        keys.approve(carol, k2);
        vm.expectCall(address(fleet), abi.encodeCall(KeyfleetManager.onKeyMoved, (k2, bob)), 1);
        vm.prank(carol);
        keys.transferFrom(bob, carol, k2);
        assertEq(keys.ownerOf(k2), carol, "the approved operator moves it");
    }
}
