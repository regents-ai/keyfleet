// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetSystem} from "../script/KeyfleetSystem.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "../src/vendor/chainlink/libraries/VRFV2PlusClient.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Asks for its own key's reveal from inside `onERC721Received`, which would add a second
/// request to the mint that sends it the key.
contract RetryingReceiver is IERC721Receiver {
    KeyfleetKeys private immutable KEYS;

    constructor(KeyfleetKeys keys) {
        KEYS = keys;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        KEYS.requestReveal(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev The shared Keyfleet fixture with the reveal suites' own steps: reading the collection's
/// request ids from the coordinator, the seed a word gives, and an open fleet whose deck the keeper
/// has recorded.
abstract contract RevealFixture is KeyfleetFixture {
    /// @dev The gas lane and trait table the fixture deploys the collection with.
    bytes32 internal constant KEY_HASH = keccak256("key hash");
    bytes32 internal constant TRAIT_TABLE = keccak256("trait table");
    /// @dev An open fleet's starting price: 10 USDC.
    uint256 internal constant OPEN_START = 10_000_000;

    function _setUpReveal() internal {
        _setUpFixture();
        vm.warp(1_000_000);
    }

    /// @dev Lets `buyer` spend without limit on `fleet`, for purchases made at a fixed gas limit.
    function _fund(KeyfleetManager fleet) internal {
        usdc.mint(buyer, 1e30);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);
    }

    /// @dev The founding Classic fleet, with `buyer` able to spend on it.
    function _classic() internal returns (KeyfleetManager fleet) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _fund(fleet);
    }

    /// @dev A new open Classic fleet without a deck, with `buyer` able to spend on it.
    function _open() internal returns (KeyfleetManager fleet) {
        fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, OPEN_START);
        _fund(fleet);
    }

    /// @dev A new open Classic fleet whose deck the keeper has recorded.
    function _openWithDeck() internal returns (KeyfleetManager fleet) {
        fleet = _open();
        uint256 fleetId = fleet.FLEET_ID();
        vm.prank(keeper);
        keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);
    }

    /// @dev Buys the next key of a funded `fleet` for `to`; the purchase is the only call made, so
    /// an expected event can be checked against it.
    function _purchase(KeyfleetManager fleet, address to) internal returns (uint256 tokenId) {
        vm.prank(buyer);
        tokenId = fleet.purchase(to, type(uint256).max, block.timestamp, new bytes32[](0));
    }

    /// @dev Buys the next key of a funded `fleet` for `buyer`.
    function _buyKey(KeyfleetManager fleet) internal returns (uint256 tokenId) {
        return _purchase(fleet, buyer);
    }

    /// @dev The collection's request count on the coordinator.
    function _nonce() internal view returns (uint64 nonce) {
        (, nonce) = vrf.consumerConfig(address(keys), vrfSubscription);
    }

    /// @dev The id of the collection's latest accepted request.
    function _lastRequestId() internal view returns (uint256 requestId) {
        (requestId,) = vrf.computeRequestId(KEY_HASH, address(keys), vrfSubscription, _nonce());
    }

    /// @dev The id the collection's next accepted request will get.
    function _nextRequestId() internal view returns (uint256 requestId) {
        (requestId,) = vrf.computeRequestId(KEY_HASH, address(keys), vrfSubscription, _nonce() + 1);
    }

    function _words(uint256 word) internal pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = word;
    }

    function _seed(uint256 tokenId, uint256 word) internal view returns (bytes32) {
        return keccak256(abi.encode(keys.TRAIT_SEED_TAG(), block.chainid, address(keys), tokenId, word));
    }
}

contract KeyfleetRevealTest is RevealFixture {
    event RandomWordsRequested(
        bytes32 indexed keyHash,
        uint256 requestId,
        uint256 preSeed,
        uint256 indexed subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs,
        address indexed sender
    );
    event RevealRequested(uint256 indexed tokenId, uint256 indexed requestId);
    event RevealRequestFailed(uint256 indexed tokenId);
    event KeyRevealed(
        uint256 indexed tokenId, uint256 indexed fleetId, uint256 keyNumber, uint256 indexed requestId, bytes32 seed
    );
    event DeckSet(uint256 indexed fleetId, bytes32 deckHash, uint256 deckSize);
    event MetadataUpdate(uint256 _tokenId);

    function setUp() public {
        _setUpReveal();
    }

    // --- 1. construction -------------------------------------------------

    function test_constructorFixesTheRandomnessAndTheTraitTable() public view {
        assertEq(address(keys.VRF_COORDINATOR()), address(vrf), "coordinator");
        assertEq(keys.VRF_SUBSCRIPTION_ID(), vrfSubscription, "subscription");
        assertEq(keys.VRF_KEY_HASH(), KEY_HASH, "gas lane");
        assertEq(keys.TRAIT_TABLE_HASH(), TRAIT_TABLE, "trait table");
        assertEq(keys.REVEAL_CONFIRMATIONS(), 3, "confirmations");
        assertEq(keys.REVEAL_CALLBACK_GAS_LIMIT(), 100_000, "callback gas");
        assertEq(keys.REVEAL_WORDS(), 1, "one word");
        assertEq(keys.TRAIT_SEED_TAG(), keccak256("keyfleet.trait-seed"), "seed tag");
    }

    /// @dev Invariant: the trait table is named before the first sale, so it can never be chosen
    /// after the seeds are known.
    function test_constructorRefusesAZeroTraitTableHash() public {
        vm.expectRevert(KeyfleetKeys.TraitTableHashZero.selector);
        new KeyfleetKeys(safe, keeper, _bindings().collection, _bindings().randomness, bytes32(0));
    }

    /// @dev Invariant: the coordinator holds code, because a call to an address without code would
    /// revert past the mint's `catch` and stop every sale of every fleet.
    function test_constructorRefusesACoordinatorWithoutCode() public {
        KeyfleetKeys.Randomness memory randomness = _bindings().randomness;
        randomness.coordinator = IVRFCoordinatorV2Plus(address(0xC0DE));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.CoordinatorMissing.selector, address(0xC0DE)));
        new KeyfleetKeys(safe, keeper, _bindings().collection, randomness, TRAIT_TABLE);

        randomness.coordinator = IVRFCoordinatorV2Plus(address(0));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.CoordinatorMissing.selector, address(0)));
        new KeyfleetKeys(safe, keeper, _bindings().collection, randomness, TRAIT_TABLE);
    }

    function test_supportsInterfaceReportsErc4906() public view {
        assertTrue(keys.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(keys.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(keys.supportsInterface(0x5b5e139f), "ERC-721 metadata");
        assertTrue(keys.supportsInterface(0x2a55205a), "ERC-2981");
        assertTrue(keys.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(keys.supportsInterface(0xffffffff), "not the ERC-165 null id");
    }

    // --- 2. decks --------------------------------------------------------

    /// @dev Invariant: each founding fleet is registered with its deck, so every key it mints asks
    /// for its word in the same purchase.
    function test_foundingFleetsHaveTheirDeckAndEveryMintAsksForAWord() public {
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        for (uint256 fleetId = 1; fleetId <= keys.FOUNDING_FLEETS(); ++fleetId) {
            (bytes32 deckHash, uint256 deckSize) = keys.deckOf(fleetId);
            assertEq(deckHash, _deckHash(fleetId), "the deck fingerprint");
            assertEq(deckSize, DECK_SIZE, "the deck size");

            KeyfleetManager fleet = KeyfleetManager(keys.managerOf(fleetId));
            _fund(fleet);
            for (uint256 n = 1; n <= 3; ++n) {
                uint256 nonceBefore = _nonce();
                vm.expectEmit(true, true, false, true, address(keys));
                emit RevealRequested(keys.tokenIdOf(fleetId, n), _nextRequestId());
                uint256 tokenId = _purchase(fleet, _wallet(fleetId * 100 + n));
                assertEq(tokenId, keys.tokenIdOf(fleetId, n), "the key number");
                assertEq(_nonce(), nonceBefore + 1, "one request per mint");
                assertEq(keys.revealRequestedAt(tokenId), block.timestamp, "asked at mint");
            }
        }
    }

    /// @dev Invariant: a fleet anyone creates has no deck, and until it has one none of its mints,
    /// key 1 at creation included, asks the coordinator for anything.
    function test_anOpenFleetHasNoDeckAndItsMintsAskForNothing() public {
        uint256 nonceBefore = _nonce();
        vm.recordLogs();
        KeyfleetManager fleet = _open();
        uint256 fleetId = fleet.FLEET_ID();
        _buyKey(fleet);
        _buyKey(fleet);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(keys)) continue;
            assertTrue(logs[i].topics[0] != RevealRequested.selector, "no request");
            assertTrue(logs[i].topics[0] != RevealRequestFailed.selector, "no failed request either");
        }
        assertEq(_nonce(), nonceBefore, "the coordinator was never asked");
        (bytes32 deckHash, uint256 deckSize) = keys.deckOf(fleetId);
        assertEq(deckHash, bytes32(0), "no deck fingerprint");
        assertEq(deckSize, 0, "no deck size");
        for (uint256 n = 1; n <= 3; ++n) {
            assertEq(keys.revealRequestedAt(_key(fleet, n)), 0, "never asked");
            assertEq(keys.revealSeed(_key(fleet, n)), bytes32(0), "no seed");
        }
    }

    /// @dev Invariant: no key of a fleet without a deck can be drawn, so no seed of it can exist
    /// before its deck is fixed.
    function test_requestRevealRefusesAKeyOfAFleetWithoutADeck() public {
        KeyfleetManager fleet = _open();
        uint256 fleetId = fleet.FLEET_ID();
        uint256 k1 = _key(fleet, 1);

        address[3] memory askers = [creator, keeper, address(0xBAD)];
        for (uint256 i = 0; i < askers.length; ++i) {
            vm.prank(askers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.DeckNotSet.selector, fleetId));
            keys.requestReveal(k1);
        }
    }

    /// @dev Invariant: only the keeper records a deck. Not the Safe, the creator, the fleet's own
    /// manager or anyone else, and a keeper the Safe has replaced no longer can.
    function test_onlyTheKeeperRecordsADeck() public {
        KeyfleetManager fleet = _open();
        uint256 fleetId = fleet.FLEET_ID();

        address[4] memory others = [safe, creator, address(fleet), address(0xBAD)];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyKeeper.selector, others[i]));
            keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);
        }

        address nextKeeper = makeAddr("next keeper");
        vm.prank(safe);
        keys.setKeeper(nextKeeper);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyKeeper.selector, keeper));
        keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);

        vm.expectEmit(true, false, false, true, address(keys));
        emit DeckSet(fleetId, _deckHash(fleetId), DECK_SIZE);
        vm.prank(nextKeeper);
        keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);
    }

    /// @dev Invariant: a deck is recorded once and never changes, so nobody can swap it after
    /// seeing the seeds. A founding fleet's deck is already fixed.
    function test_aDeckIsRecordedOnlyOnce() public {
        KeyfleetManager fleet = _openWithDeck();
        uint256 fleetId = fleet.FLEET_ID();

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.DeckAlreadySet.selector, fleetId));
        keys.setDeck(fleetId, keccak256("another deck"), DECK_SIZE + 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.DeckAlreadySet.selector, fleetId));
        keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);
        for (uint256 founding = 1; founding <= keys.FOUNDING_FLEETS(); ++founding) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.DeckAlreadySet.selector, founding));
            keys.setDeck(founding, keccak256("another deck"), DECK_SIZE);
        }
        vm.stopPrank();

        (bytes32 deckHash, uint256 deckSize) = keys.deckOf(fleetId);
        assertEq(deckHash, _deckHash(fleetId), "the first fingerprint stands");
        assertEq(deckSize, DECK_SIZE, "the first size stands");
    }

    /// @dev Invariant: a deck needs a fingerprint and a size from 1 to the highest key number, and
    /// only a registered fleet takes one.
    function test_aDeckNeedsAFingerprintAndASizeWithinBounds() public {
        KeyfleetManager fleet = _open();
        uint256 fleetId = fleet.FLEET_ID();
        uint256 tooBig = uint256(type(uint32).max) + 1;

        vm.startPrank(keeper);
        vm.expectRevert(KeyfleetKeys.DeckInvalid.selector);
        keys.setDeck(fleetId, bytes32(0), DECK_SIZE);
        vm.expectRevert(KeyfleetKeys.DeckInvalid.selector);
        keys.setDeck(fleetId, _deckHash(fleetId), 0);
        vm.expectRevert(KeyfleetKeys.DeckInvalid.selector);
        keys.setDeck(fleetId, bytes32(0), 0);
        vm.expectRevert(KeyfleetKeys.DeckInvalid.selector);
        keys.setDeck(fleetId, _deckHash(fleetId), tooBig);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.UnknownFleet.selector, fleetId + 1));
        keys.setDeck(fleetId + 1, _deckHash(fleetId), DECK_SIZE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.UnknownFleet.selector, 0));
        keys.setDeck(0, _deckHash(fleetId), DECK_SIZE);

        keys.setDeck(fleetId, _deckHash(fleetId), type(uint32).max);
        vm.stopPrank();
        (, uint256 deckSize) = keys.deckOf(fleetId);
        assertEq(deckSize, type(uint32).max, "the largest deck fits");
    }

    /// @dev Invariant: once the deck is recorded, anyone can ask for each earlier key, each once,
    /// and every later mint asks by itself.
    function test_afterTheDeckAnyoneRequestsEarlierKeysAndLaterMintsAskAutomatically() public {
        KeyfleetManager fleet = _open();
        uint256 fleetId = fleet.FLEET_ID();
        _buyKey(fleet);
        uint256 k1 = _key(fleet, 1);
        uint256 k2 = _key(fleet, 2);

        vm.warp(block.timestamp + 3 days);
        vm.prank(keeper);
        keys.setDeck(fleetId, _deckHash(fleetId), DECK_SIZE);
        assertEq(keys.revealRequestedAt(k1), 0, "recording the deck asks for nothing");

        uint256 firstRequest = _nextRequestId();
        vm.expectEmit(true, true, false, true, address(keys));
        emit RevealRequested(k1, firstRequest);
        vm.prank(address(0x5712A26E2));
        keys.requestReveal(k1);
        assertEq(keys.revealRequestedAt(k1), block.timestamp, "asked when requested");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.RevealAlreadyRequested.selector, k1));
        keys.requestReveal(k1);

        uint256 secondRequest = _nextRequestId();
        keys.requestReveal(k2);

        vm.expectEmit(true, true, false, true, address(keys));
        emit RevealRequested(_key(fleet, 3), _nextRequestId());
        uint256 k3 = _buyKey(fleet);
        uint256 thirdRequest = _lastRequestId();
        assertEq(keys.revealRequestedAt(k3), block.timestamp, "a later mint asks by itself");

        vrf.fulfill(firstRequest, _words(11));
        vrf.fulfill(secondRequest, _words(12));
        vrf.fulfill(thirdRequest, _words(13));
        assertEq(keys.revealSeed(k1), _seed(k1, 11), "key 1");
        assertEq(keys.revealSeed(k2), _seed(k2, 12), "key 2");
        assertEq(keys.revealSeed(k3), _seed(k3, 13), "key 3");
    }

    // --- 3. the request --------------------------------------------------

    /// @dev Invariant: every purchase asks for exactly one word, three blocks deep, with 100,000
    /// callback gas, paid in ETH from the collection's subscription on its gas lane.
    function test_purchaseRequestsOneWordOnTheExactTerms() public {
        KeyfleetManager fleet = _classic();
        uint256 k1 = _key(fleet, 1);
        (uint256 requestId, uint256 preSeed) = vrf.computeRequestId(KEY_HASH, address(keys), vrfSubscription, 1);
        bytes memory extraArgs = abi.encodeWithSelector(VRFV2PlusClient.EXTRA_ARGS_V1_TAG, true);
        assertEq(
            extraArgs, VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true})), "paid in ETH"
        );

        vm.expectEmit(true, true, true, true, address(vrf));
        emit RandomWordsRequested(
            KEY_HASH, requestId, preSeed, vrfSubscription, 3, 100_000, 1, extraArgs, address(keys)
        );
        vm.expectEmit(true, true, false, false, address(keys));
        emit RevealRequested(k1, requestId);
        uint256 tokenId = _buyKey(fleet);

        assertEq(tokenId, k1);
        assertEq(keys.revealRequestedAt(k1), block.timestamp, "request time recorded");
        assertEq(keys.revealSeed(k1), bytes32(0), "no seed before the answer");
        (address sender, uint32 callbackGasLimit) = vrf.pending(requestId);
        assertEq(sender, address(keys), "the collection is the requester");
        assertEq(callbackGasLimit, 100_000, "the callback gas the coordinator will give");
    }

    /// @dev Invariant: a coordinator that refuses a request never stops a purchase.
    function test_purchaseSucceedsWhenTheCoordinatorRefuses() public {
        KeyfleetManager fleet = _classic();
        vrf.setRevertAll(true);

        vm.expectEmit(true, false, false, false, address(keys));
        emit RevealRequestFailed(_key(fleet, 1));
        uint256 tokenId = _buyKey(fleet);

        assertEq(keys.ownerOf(tokenId), buyer, "the key is sold");
        assertEq(keys.revealRequestedAt(tokenId), 0, "no accepted request");
    }

    /// @dev Invariant: a collection the Safe has not yet added to the subscription still sells.
    function test_purchaseSucceedsBeforeTheCollectionIsAConsumer() public {
        vrfSubscription = vrf.createSubscription();
        factory = KeyfleetSystem.deploy(_bindings());
        keys = factory.KEYS();
        shards = factory.SHARDS();
        regentBuyer = factory.REGENT_BUYER();
        KeyfleetManager fleet = _classic();
        uint256 k1 = _key(fleet, 1);

        vm.expectEmit(true, false, false, false, address(keys));
        emit RevealRequestFailed(k1);
        _buyKey(fleet);

        assertEq(keys.ownerOf(k1), buyer, "the key is sold");
        vrf.addConsumer(vrfSubscription, address(keys));
        vm.expectEmit(true, true, false, true, address(keys));
        emit RevealRequested(k1, _nextRequestId());
        keys.requestReveal(k1);
    }

    /// @dev Invariant: a buyer who sends too little gas for the request still gets the key, and
    /// the key only waits for a retry. The coordinator is made to spend a million gas on the
    /// request so the gas left after it runs out is enough to finish the purchase.
    function test_aBuyerWhoStarvesTheRequestStillGetsTheKeyAndItCanBeRetried() public {
        KeyfleetManager fleet = _classic();
        uint256 k1 = _key(fleet, 1);
        _fund(fleet);
        vrf.setRequestGasBurn(1_000_000);

        uint256 used;
        for (uint256 gasLimit = 150_000; gasLimit < 3_000_000; gasLimit += 2000) {
            uint256 snapshot = vm.snapshotState();
            (bool ok, uint8 outcome) = _purchaseWithGas(fleet, gasLimit);
            if (ok && outcome == 2) {
                used = gasLimit;
                break;
            }
            vm.revertToState(snapshot);
        }

        assertGt(used, 0, "some gas limit completes the purchase while the request fails");
        assertEq(keys.ownerOf(k1), buyer, "the key is sold");
        assertEq(keys.revealRequestedAt(k1), 0, "no accepted request");

        vrf.setRequestGasBurn(0);
        vm.expectEmit(true, true, false, true, address(keys));
        emit RevealRequested(k1, _nextRequestId());
        keys.requestReveal(k1);
    }

    /// @dev Invariant: against a coordinator that costs what the real one costs, no gas limit
    /// completes a purchase silently: every completed purchase either made its request or said it
    /// failed. The search finds the least gas that completes a purchase, then every fourth limit in
    /// the four thousand gas above it is tried, which is where a starved request would show. A finer
    /// step would not fit the whole walk in one test's gas.
    function test_everyCompletedPurchaseEitherRequestedOrSaidItFailed() public {
        KeyfleetManager fleet = _classic();
        _fund(fleet);
        uint256 low = 100_000;
        uint256 high = 3_000_000;
        while (low < high) {
            uint256 middle = (low + high) / 2;
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = _purchaseWithGas(fleet, middle);
            vm.revertToState(snapshot);
            if (ok) high = middle;
            else low = middle + 1;
        }
        console2.log("least gas that completes a purchase:", low);

        for (uint256 gasLimit = low; gasLimit < low + 4000; gasLimit += 4) {
            uint256 snapshot = vm.snapshotState();
            (bool ok, uint8 outcome) = _purchaseWithGas(fleet, gasLimit);
            vm.revertToState(snapshot);
            assertTrue(ok, "more gas still completes");
            assertTrue(outcome != 0, "a completed purchase always accounts for its request");
        }
    }

    // --- 4. the answer ---------------------------------------------------

    /// @dev Invariant: the seed is the tagged hash of the chain, the collection, the key and the
    /// word; writing it names the key's fleet and key number and tells marketplaces to refresh it.
    function test_answerWritesTheSeedAndAnnouncesIt() public {
        KeyfleetManager fleet = _classic();
        uint256 tokenId = _buyKey(fleet);
        uint256 requestId = _lastRequestId();
        bytes32 expected = keccak256(
            abi.encode(keccak256("keyfleet.trait-seed"), block.chainid, address(keys), tokenId, uint256(424242))
        );

        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyRevealed(tokenId, fleet.FLEET_ID(), 1, requestId, expected);
        vm.expectEmit(false, false, false, true, address(keys));
        emit MetadataUpdate(tokenId);
        vrf.fulfill(requestId, _words(424242));

        assertTrue(vrf.lastCallbackSuccess(), "the callback succeeded");
        assertEq(keys.revealSeed(tokenId), expected, "the seed");
    }

    /// @dev The same word gives two keys of one fleet, and the same key number in two fleets of the
    /// same type, different seeds; each answer names its own fleet and key number.
    function test_seedsOfTheSameKeyNumberInTwoFleetsDiffer() public {
        KeyfleetManager first = _classic();
        _buyKey(first);
        uint256 firstRequest = _lastRequestId();
        _buyKey(first);
        uint256 secondKeyRequest = _lastRequestId();
        KeyfleetManager second = _openWithDeck();
        keys.requestReveal(_key(second, 1));
        uint256 otherFleetRequest = _lastRequestId();
        assertEq(uint8(second.PRESET()), uint8(first.PRESET()), "two fleets of one type");

        vrf.fulfill(firstRequest, _words(7));
        vrf.fulfill(secondKeyRequest, _words(7));
        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyRevealed(_key(second, 1), second.FLEET_ID(), 1, otherFleetRequest, _seed(_key(second, 1), 7));
        vrf.fulfill(otherFleetRequest, _words(7));

        assertTrue(keys.revealSeed(_key(first, 1)) != keys.revealSeed(_key(first, 2)), "two keys");
        assertTrue(keys.revealSeed(_key(first, 1)) != keys.revealSeed(_key(second, 1)), "two fleets");
        assertEq(keys.revealSeed(_key(second, 1)), _seed(_key(second, 1), 7));
    }

    /// @dev Invariant: only the pinned coordinator can deliver an answer.
    function test_onlyTheCoordinatorMayAnswer() public {
        KeyfleetManager fleet = _classic();
        uint256 tokenId = _buyKey(fleet);
        uint256 requestId = _lastRequestId();

        address[3] memory others = [buyer, keeper, address(fleet)];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.OnlyCoordinator.selector, others[i]));
            keys.rawFulfillRandomWords(requestId, _words(1));
        }

        assertEq(keys.revealSeed(tokenId), bytes32(0), "nothing written");
    }

    /// @dev Invariant: the callback never reverts for the coordinator, because a reverted callback
    /// is final and charged: unknown ids, empty answers and a second answer for a revealed key are
    /// ignored without a word.
    function test_unknownEmptyAndDuplicateAnswersAreIgnoredWithoutReverting() public {
        KeyfleetManager fleet = _classic();
        uint256 tokenId = _buyKey(fleet);
        uint256 requestId = _lastRequestId();

        _expectSilentAnswer(tokenId, 12_345, _words(1));
        _expectSilentAnswer(tokenId, requestId, new uint256[](0));
        assertEq(keys.revealSeed(tokenId), bytes32(0), "an empty answer writes nothing");

        vrf.fulfill(requestId, _words(2));
        bytes32 seed = keys.revealSeed(tokenId);
        assertEq(seed, _seed(tokenId, 2), "the answer writes the seed");

        _expectSilentAnswer(tokenId, requestId, _words(3));
        assertEq(keys.revealSeed(tokenId), seed, "a duplicate answer does not change the seed");
    }

    /// @dev Invariant: a key has at most one accepted request, so there is only ever one answer
    /// its seed can come from and nobody who orders the answers can choose between two. Once the
    /// coordinator accepts a request nobody, the holder included, can ask for the key again, however
    /// long the answer takes, and no stack of waiting requests can build up behind it.
    function test_anAcceptedRequestIsTheOnlyOneAKeyEverGets() public {
        KeyfleetManager fleet = _classic();
        uint256 tokenId = _buyKey(fleet);
        uint256 requestId = _lastRequestId();
        uint64 nonceBefore = _nonce();

        address[3] memory askers = [buyer, keeper, address(0xBAD)];
        uint256[3] memory waits = [uint256(0), 1 hours, 365 days];
        for (uint256 i = 0; i < waits.length; ++i) {
            vm.warp(block.timestamp + waits[i]);
            for (uint256 j = 0; j < askers.length; ++j) {
                vm.prank(askers[j]);
                vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.RevealAlreadyRequested.selector, tokenId));
                keys.requestReveal(tokenId);
            }
        }
        assertEq(_nonce(), nonceBefore, "no second request reached the coordinator");

        vrf.fulfill(requestId, _words(7));
        assertEq(keys.revealSeed(tokenId), _seed(tokenId, 7), "the one request's answer is the seed");
    }

    /// @dev Invariant: an answer is cheap enough for the 100,000 callback gas with room to spare,
    /// with every slot it touches cold, as it is in the coordinator's own transaction.
    function test_callbackUsesUnderSixtyThousandGasWithColdStorage() public {
        KeyfleetManager fleet = _classic();
        _buyKey(fleet);
        uint256 requestId = _lastRequestId();

        vm.cool(address(keys));
        vrf.fulfill(requestId, _words(type(uint256).max));

        console2.log("reveal callback gas, cold:", vrf.lastCallbackGasUsed());
        assertTrue(vrf.lastCallbackSuccess(), "the callback succeeded");
        assertLt(vrf.lastCallbackGasUsed(), 60_000, "under 60% of the callback gas limit");
    }

    // --- 5. retries ------------------------------------------------------

    function test_requestRevealRefusesAKeyThatDoesNotExist() public {
        KeyfleetManager fleet = _classic();
        _buyKey(fleet);

        uint256[3] memory missing = [uint256(0), _key(fleet, 2), keys.tokenIdOf(99, 1)];
        for (uint256 i = 0; i < missing.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, missing[i]));
            keys.requestReveal(missing[i]);
        }
    }

    function test_requestRevealRefusesARevealedKey() public {
        KeyfleetManager fleet = _classic();
        uint256 tokenId = _buyKey(fleet);
        vrf.fulfill(_lastRequestId(), _words(5));
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.AlreadyRevealed.selector, tokenId));
        keys.requestReveal(tokenId);
    }

    /// @dev Invariant: a key whose request was refused can be retried at once, by anyone, as often as
    /// the coordinator keeps refusing, and a refused retry says so without reverting. The first
    /// retry the coordinator accepts is the last one.
    function test_aFailedRequestCanBeRetriedAtOnceByAnyone() public {
        KeyfleetManager fleet = _classic();
        vrf.setRevertAll(true);
        uint256 tokenId = _buyKey(fleet);

        vm.expectEmit(true, false, false, false, address(keys));
        emit RevealRequestFailed(tokenId);
        vm.prank(address(0x5712A26E2));
        keys.requestReveal(tokenId);

        vrf.setRevertAll(false);
        vm.prank(address(0x5712A26E2));
        keys.requestReveal(tokenId);
        assertEq(keys.revealRequestedAt(tokenId), block.timestamp, "accepted");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.RevealAlreadyRequested.selector, tokenId));
        keys.requestReveal(tokenId);
        vrf.fulfill(_lastRequestId(), _words(9));
        assertEq(keys.revealSeed(tokenId), _seed(tokenId, 9));
    }

    /// @dev Invariant: a receiver cannot add a second request to the mint that sends it its key.
    function test_aReceiverCannotRetryFromInsideItsOwnPurchase() public {
        KeyfleetManager fleet = _classic();
        _fund(fleet);
        RetryingReceiver receiver = new RetryingReceiver(keys);

        vm.prank(buyer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        fleet.purchase(address(receiver), type(uint256).max, block.timestamp, new bytes32[](0));
    }

    // --- 6. metadata -----------------------------------------------------

    /// @dev Invariant: `tokenURI` answers only for a minted key, so nobody can read a key's metadata
    /// address ahead of its mint, in its own fleet or any other.
    function test_tokenURIRevertsForAnUnmintedKey() public {
        KeyfleetManager fleet = _classic();
        uint256 k1 = _buyKey(fleet);
        assertEq(keys.tokenURI(k1), string.concat("https://keyfleet.ai/keys/", vm.toString(k1)), "a minted key");

        uint256[4] memory unminted =
            [_key(fleet, 2), keys.tokenIdOf(2, 1), keys.tokenIdOf(fleet.FLEET_ID() + 99, 1), uint256(0)];
        for (uint256 i = 0; i < unminted.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted[i]));
            keys.tokenURI(unminted[i]);
        }
    }

    // --- 7. fuzz ---------------------------------------------------------

    /// @dev Invariant: whatever the coordinator sends — any id, any number of words — the callback
    /// returns within the callback gas limit.
    function testFuzz_callbackNeverRevertsForTheCoordinator(
        uint256 requestId,
        uint256 wordCount,
        uint256 word,
        bool known,
        bool revealFirst
    ) public {
        KeyfleetManager fleet = _classic();
        _buyKey(fleet);
        if (known) requestId = _lastRequestId();
        if (revealFirst) vrf.fulfill(_lastRequestId(), _words(word ^ 1));

        uint256[] memory words = new uint256[](bound(wordCount, 0, 500));
        for (uint256 i = 0; i < words.length; ++i) {
            words[i] = uint256(keccak256(abi.encode(word, i)));
        }

        vm.prank(address(vrf));
        (bool ok,) =
            address(keys).call{gas: 100_000}(abi.encodeCall(KeyfleetKeys.rawFulfillRandomWords, (requestId, words)));
        assertTrue(ok, "the callback never reverts for the coordinator");
    }

    /// @dev Invariant: a seed is written once. However many answers arrive for a key, the seed is
    /// the first one's and never changes.
    function testFuzz_aSeedIsWrittenOnce(uint256 firstWord, uint256 secondWord) public {
        KeyfleetManager fleet = _classic();
        uint256 tokenId = _buyKey(fleet);
        uint256 requestId = _lastRequestId();

        vrf.fulfill(requestId, _words(firstWord));
        bytes32 seed = keys.revealSeed(tokenId);
        vm.prank(address(vrf));
        keys.rawFulfillRandomWords(requestId, _words(secondWord));

        assertEq(seed, _seed(tokenId, firstWord), "the first answer's seed");
        assertEq(keys.revealSeed(tokenId), seed, "never rewritten");
    }

    /// @dev Invariant: no key of a fleet without a deck has a seed or a pending draw, however many
    /// keys it sells, whatever the coordinator answers, and while other fleets' keys are drawn.
    function testFuzz_noKeyOfAFleetWithoutADeckHasASeedOrAPendingDraw(uint8 extraKeys, uint256 requestId, uint256 word)
        public
    {
        KeyfleetManager founding = _classic();
        KeyfleetManager open = _open();
        uint256 count = 1 + bound(extraKeys, 0, 12);
        for (uint256 i = 1; i < count; ++i) {
            _buyKey(founding);
            vrf.fulfill(_lastRequestId(), _words(uint256(keccak256(abi.encode(word, i)))));
            _buyKey(open);
        }

        vm.prank(address(vrf));
        keys.rawFulfillRandomWords(requestId, _words(word));

        for (uint256 n = 1; n <= count; ++n) {
            uint256 tokenId = _key(open, n);
            assertEq(keys.revealRequestedAt(tokenId), 0, "no pending draw");
            assertEq(keys.revealSeed(tokenId), bytes32(0), "no seed");
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.DeckNotSet.selector, open.FLEET_ID()));
            keys.requestReveal(tokenId);
        }
    }

    // --- helpers ---------------------------------------------------------

    /// @dev Buys with a fixed gas limit and reports whether the purchase completed and what the
    /// collection said about its request: 0 nothing, 1 `RevealRequested`, 2 `RevealRequestFailed`.
    /// Measured in a call of its own, so the recorded logs of hundreds of tries do not pile up in
    /// one call's memory.
    function _purchaseWithGas(KeyfleetManager fleet, uint256 gasLimit) private returns (bool ok, uint8 outcome) {
        return this.purchaseWithGas(fleet, gasLimit);
    }

    /// @dev Only for `_purchaseWithGas`.
    function purchaseWithGas(KeyfleetManager fleet, uint256 gasLimit) external returns (bool ok, uint8 outcome) {
        vm.recordLogs();
        vm.prank(buyer);
        (ok,) = address(fleet).call{gas: gasLimit}(
            abi.encodeCall(KeyfleetManager.purchase, (buyer, type(uint256).max, block.timestamp, new bytes32[](0)))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(keys)) continue;
            if (logs[i].topics[0] == RevealRequested.selector) outcome = 1;
            if (logs[i].topics[0] == RevealRequestFailed.selector) outcome = 2;
        }
    }

    /// @dev Delivers an answer as the coordinator and checks it changed nothing and said nothing.
    function _expectSilentAnswer(uint256 tokenId, uint256 requestId, uint256[] memory words) private {
        bytes32 before = keys.revealSeed(tokenId);
        vm.recordLogs();
        vm.prank(address(vrf));
        keys.rawFulfillRandomWords(requestId, words);
        assertEq(vm.getRecordedLogs().length, 0, "an ignored answer emits nothing");
        assertEq(keys.revealSeed(tokenId), before, "an ignored answer writes nothing");
    }
}

/// @dev Drives purchases, retries, answers and the keeper's deck in any order against three fleets
/// of the one collection: two founding fleets with their decks and an open fleet that starts
/// without one. It remembers the first seed each key was given. Purchases stop at forty keys a fleet
/// so each check stays cheap.
contract RevealHandler is Test {
    uint256 private constant KEYS_PER_FLEET = 40;

    KeyfleetKeys private immutable KEYS;
    MockVRFCoordinatorV2Plus private immutable VRF;
    address private immutable BUYER;
    address private immutable KEEPER;
    KeyfleetManager private immutable OPEN;

    KeyfleetManager[] public fleets;
    uint256[] private _open;
    mapping(uint256 requestId => uint256 tokenId) private _tokenOf;
    mapping(uint256 tokenId => bytes32 seed) public firstSeed;

    constructor(
        KeyfleetKeys keys,
        MockVRFCoordinatorV2Plus vrf,
        address buyer,
        address keeper,
        KeyfleetManager[] memory fleets_,
        KeyfleetManager open
    ) {
        KEYS = keys;
        VRF = vrf;
        BUYER = buyer;
        KEEPER = keeper;
        OPEN = open;
        fleets = fleets_;
    }

    function fleetCount() external view returns (uint256) {
        return fleets.length;
    }

    function buy(uint256 fleetIndex, bool refuse) external {
        KeyfleetManager fleet = fleets[bound(fleetIndex, 0, fleets.length - 1)];
        if (fleet.totalMinted() >= KEYS_PER_FLEET) return;
        VRF.setRevertAll(refuse);
        uint64 nonce = _nonce();
        vm.prank(BUYER);
        uint256 tokenId = fleet.purchase(BUYER, type(uint256).max, block.timestamp, new bytes32[](0));
        VRF.setRevertAll(false);
        _track(tokenId, nonce);
    }

    function retry(uint256 fleetIndex, uint256 keySeed, uint256 wait) external {
        KeyfleetManager fleet = fleets[bound(fleetIndex, 0, fleets.length - 1)];
        uint256 minted = fleet.totalMinted();
        if (minted == 0) return;
        vm.warp(block.timestamp + bound(wait, 0, 2 hours));
        uint256 tokenId = KEYS.tokenIdOf(fleet.FLEET_ID(), bound(keySeed, 1, minted));
        uint64 nonce = _nonce();
        try KEYS.requestReveal(tokenId) {
            _track(tokenId, nonce);
        } catch {}
    }

    function answer(uint256 index, uint256 word) external {
        if (_open.length == 0) return;
        index = bound(index, 0, _open.length - 1);
        uint256 requestId = _open[index];
        _open[index] = _open[_open.length - 1];
        _open.pop();

        VRF.fulfill(requestId, _words(word));
        uint256 tokenId = _tokenOf[requestId];
        if (firstSeed[tokenId] == bytes32(0)) firstSeed[tokenId] = KEYS.revealSeed(tokenId);
    }

    /// @dev The keeper records the open fleet's deck, once.
    function setDeck(uint256 deckSize) external {
        uint256 fleetId = OPEN.FLEET_ID();
        (bytes32 deckHash,) = KEYS.deckOf(fleetId);
        if (deckHash != bytes32(0)) return;
        vm.prank(KEEPER);
        KEYS.setDeck(fleetId, keccak256("open deck"), bound(deckSize, 1, type(uint32).max));
    }

    /// @dev Records the request the last call made, if the coordinator accepted one.
    function _track(uint256 tokenId, uint64 nonceBefore) private {
        uint64 nonce = _nonce();
        if (nonce == nonceBefore) return;
        (uint256 requestId,) =
            VRF.computeRequestId(KEYS.VRF_KEY_HASH(), address(KEYS), KEYS.VRF_SUBSCRIPTION_ID(), nonce);
        _tokenOf[requestId] = tokenId;
        _open.push(requestId);
    }

    function _nonce() private view returns (uint64 nonce) {
        (, nonce) = VRF.consumerConfig(address(KEYS), KEYS.VRF_SUBSCRIPTION_ID());
    }

    function _words(uint256 word) private pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = word;
    }
}

contract KeyfleetRevealInvariantTest is RevealFixture {
    RevealHandler private handler;

    function setUp() public {
        _setUpReveal();
        KeyfleetManager[] memory fleets = new KeyfleetManager[](3);
        fleets[0] = _classic();
        fleets[1] = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        _fund(fleets[1]);
        fleets[2] = _open();
        handler = new RevealHandler(keys, vrf, buyer, keeper, fleets, fleets[2]);
        targetContract(address(handler));
    }

    /// @dev Invariant: a key's seed, once written, is never rewritten, and a key without a seed
    /// never had one. A key with a seed was asked for, and no key of a fleet without a deck has a
    /// seed or a pending draw.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_aSeedIsWrittenOnceAndOnlyForAFleetWithADeck() public view {
        for (uint256 i = 0; i < handler.fleetCount(); ++i) {
            KeyfleetManager fleet = handler.fleets(i);
            (bytes32 deckHash,) = keys.deckOf(fleet.FLEET_ID());
            for (uint256 n = 1; n <= fleet.totalMinted(); ++n) {
                uint256 tokenId = _key(fleet, n);
                bytes32 seed = keys.revealSeed(tokenId);
                assertEq(seed, handler.firstSeed(tokenId), "the first seed stands");
                if (seed != bytes32(0)) assertGt(keys.revealRequestedAt(tokenId), 0, "a seed was asked for");
                if (deckHash == bytes32(0)) {
                    assertEq(seed, bytes32(0), "no seed without a deck");
                    assertEq(keys.revealRequestedAt(tokenId), 0, "no draw without a deck");
                }
            }
        }
    }
}
