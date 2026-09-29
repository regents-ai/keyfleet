// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "../src/vendor/chainlink/libraries/VRFV2PlusClient.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev Reports six decimals, as Ethereum USDC does, because a fleet refuses a USDC with any other.
contract RevealUsdc is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Asks for its own key's reveal from inside `onERC721Received`, which would add a second
/// request to the purchase minting to it.
contract RetryingReceiver is IERC721Receiver {
    Keyfleet private immutable FLEET;

    constructor(Keyfleet fleet) {
        FLEET = fleet;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        FLEET.requestReveal(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Shared set-up for the reveal suites: a fleet on the mock coordinator, added to the
/// suite's subscription, and a buyer with USDC to spend.
abstract contract RevealFixture is Test {
    bytes32 internal constant KEY_HASH = keccak256("key hash");
    bytes32 internal constant TRAIT_TABLE = keccak256("trait table");
    address internal constant BUYER = address(0xB0B0B0);

    RevealUsdc internal usdc;
    MockVRFCoordinatorV2Plus internal vrf;
    uint256 internal subscriptionId;

    function _setUpFixture() internal {
        usdc = new RevealUsdc();
        vrf = new MockVRFCoordinatorV2Plus();
        subscriptionId = vrf.createSubscription();
        vm.warp(1_000_000);
    }

    function _randomness() internal view returns (Keyfleet.Randomness memory) {
        return Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
        });
    }

    function _deployWith(Keyfleet.Randomness memory randomness) internal returns (Keyfleet) {
        return _deployWith(randomness, TRAIT_TABLE);
    }

    function _deployWith(Keyfleet.Randomness memory randomness, bytes32 traitTableHash) internal returns (Keyfleet) {
        return new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            address(0x7EA5),
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            randomness,
            traitTableHash
        );
    }

    /// @dev A Classic fleet the subscription already pays for.
    function _deploy() internal returns (Keyfleet fleet) {
        fleet = _deployWith(_randomness());
        vrf.addConsumer(subscriptionId, address(fleet));
        usdc.mint(BUYER, 1e30);
        vm.prank(BUYER);
        usdc.approve(address(fleet), type(uint256).max);
    }

    function _buy(Keyfleet fleet) internal returns (uint256 tokenId) {
        vm.prank(BUYER);
        tokenId = fleet.purchase(BUYER, type(uint256).max, block.timestamp);
    }

    /// @dev The id of the fleet's latest accepted request.
    function _lastRequestId(Keyfleet fleet) internal view returns (uint256 requestId) {
        (, uint64 nonce) = vrf.consumerConfig(address(fleet), subscriptionId);
        (requestId,) = vrf.computeRequestId(KEY_HASH, address(fleet), subscriptionId, nonce);
    }

    /// @dev The id the fleet's next accepted request will get.
    function _nextRequestId(Keyfleet fleet) internal view returns (uint256 requestId) {
        (, uint64 nonce) = vrf.consumerConfig(address(fleet), subscriptionId);
        (requestId,) = vrf.computeRequestId(KEY_HASH, address(fleet), subscriptionId, nonce + 1);
    }

    function _words(uint256 word) internal pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = word;
    }

    function _seed(Keyfleet fleet, uint256 tokenId, uint256 word) internal view returns (bytes32) {
        return keccak256(abi.encode(fleet.TRAIT_SEED_TAG(), block.chainid, address(fleet), tokenId, word));
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
    event KeyRevealed(uint256 indexed tokenId, uint256 indexed requestId, bytes32 seed);
    event MetadataUpdate(uint256 _tokenId);

    function setUp() public {
        _setUpFixture();
    }

    // --- 1. construction -------------------------------------------------

    function test_constructorFixesTheRandomnessAndTheTraitTable() public {
        Keyfleet fleet = _deploy();

        assertEq(address(fleet.VRF_COORDINATOR()), address(vrf), "coordinator");
        assertEq(fleet.VRF_SUBSCRIPTION_ID(), subscriptionId, "subscription");
        assertEq(fleet.VRF_KEY_HASH(), KEY_HASH, "gas lane");
        assertEq(fleet.TRAIT_TABLE_HASH(), TRAIT_TABLE, "trait table");
        assertEq(fleet.REVEAL_CONFIRMATIONS(), 3, "confirmations");
        assertEq(fleet.REVEAL_CALLBACK_GAS_LIMIT(), 100_000, "callback gas");
        assertEq(fleet.REVEAL_WORDS(), 1, "one word");
        assertEq(fleet.TRAIT_SEED_TAG(), keccak256("keyfleet.trait-seed"), "seed tag");
    }

    /// @dev Invariant: the trait table is named before the first sale, so it can never be chosen
    /// after the seeds are known.
    function test_constructorRefusesAZeroTraitTableHash() public {
        vm.expectRevert(Keyfleet.TraitTableHashZero.selector);
        _deployWith(_randomness(), bytes32(0));
    }

    /// @dev Invariant: the coordinator holds code, because a call to an address without code would
    /// revert past the purchase's `catch` and stop every sale.
    function test_constructorRefusesACoordinatorWithoutCode() public {
        Keyfleet.Randomness memory randomness = _randomness();
        randomness.coordinator = IVRFCoordinatorV2Plus(address(0xC0DE));
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.CoordinatorMissing.selector, address(0xC0DE)));
        _deployWith(randomness);

        randomness.coordinator = IVRFCoordinatorV2Plus(address(0));
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.CoordinatorMissing.selector, address(0)));
        _deployWith(randomness);
    }

    function test_supportsInterfaceReportsErc4906() public {
        Keyfleet fleet = _deploy();

        assertTrue(fleet.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(fleet.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(fleet.supportsInterface(0x5b5e139f), "ERC-721 metadata");
        assertTrue(fleet.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(fleet.supportsInterface(0xffffffff), "not the ERC-165 null id");
    }

    // --- 2. the request --------------------------------------------------

    /// @dev Invariant: every purchase asks for exactly one word, three blocks deep, with 100,000
    /// callback gas, paid in ETH from the fleet's own subscription on its own gas lane.
    function test_purchaseRequestsOneWordOnTheExactTerms() public {
        Keyfleet fleet = _deploy();
        (uint256 requestId, uint256 preSeed) = vrf.computeRequestId(KEY_HASH, address(fleet), subscriptionId, 1);
        bytes memory extraArgs = abi.encodeWithSelector(VRFV2PlusClient.EXTRA_ARGS_V1_TAG, true);
        assertEq(
            extraArgs, VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true})), "paid in ETH"
        );

        vm.expectEmit(true, true, true, true, address(vrf));
        emit RandomWordsRequested(
            KEY_HASH, requestId, preSeed, subscriptionId, 3, 100_000, 1, extraArgs, address(fleet)
        );
        vm.expectEmit(true, true, false, false, address(fleet));
        emit RevealRequested(1, requestId);
        uint256 tokenId = _buy(fleet);

        assertEq(tokenId, 1);
        assertEq(fleet.revealRequestedAt(1), block.timestamp, "request time recorded");
        assertEq(fleet.revealSeed(1), bytes32(0), "no seed before the answer");
        (address sender, uint32 callbackGasLimit) = vrf.pending(requestId);
        assertEq(sender, address(fleet), "the fleet is the requester");
        assertEq(callbackGasLimit, 100_000, "the callback gas the coordinator will give");
    }

    /// @dev Invariant: a coordinator that refuses a request never stops a purchase.
    function test_purchaseSucceedsWhenTheCoordinatorRefuses() public {
        Keyfleet fleet = _deploy();
        vrf.setRevertAll(true);

        vm.expectEmit(true, false, false, false, address(fleet));
        emit RevealRequestFailed(1);
        uint256 tokenId = _buy(fleet);

        assertEq(fleet.ownerOf(tokenId), BUYER, "the key is sold");
        assertEq(fleet.revealRequestedAt(tokenId), 0, "no accepted request");
    }

    /// @dev Invariant: a fleet the Safe has not yet added to the subscription still sells.
    function test_purchaseSucceedsBeforeTheFleetIsAConsumer() public {
        Keyfleet fleet = _deployWith(_randomness());
        usdc.mint(BUYER, 1e30);
        vm.prank(BUYER);
        usdc.approve(address(fleet), type(uint256).max);

        vm.expectEmit(true, false, false, false, address(fleet));
        emit RevealRequestFailed(1);
        _buy(fleet);

        assertEq(fleet.ownerOf(1), BUYER, "the key is sold");
        vrf.addConsumer(subscriptionId, address(fleet));
        vm.expectEmit(true, true, false, true, address(fleet));
        emit RevealRequested(1, _nextRequestId(fleet));
        fleet.requestReveal(1);
    }

    /// @dev Invariant: a buyer who sends too little gas for the request still gets the key, and
    /// the key only waits for a retry. The coordinator is made to spend a million gas on the
    /// request so the gas left after it runs out is enough to finish the purchase.
    function test_aBuyerWhoStarvesTheRequestStillGetsTheKeyAndItCanBeRetried() public {
        Keyfleet fleet = _deploy();
        vrf.setRequestGasBurn(1_000_000);

        uint256 used;
        for (uint256 gasLimit = 150_000; gasLimit < 1_200_000; gasLimit += 2000) {
            uint256 snapshot = vm.snapshotState();
            (bool ok, uint8 outcome) = _purchaseWithGas(fleet, gasLimit);
            if (ok && outcome == 2) {
                used = gasLimit;
                break;
            }
            vm.revertToState(snapshot);
        }

        assertGt(used, 0, "some gas limit completes the purchase while the request fails");
        assertEq(fleet.ownerOf(1), BUYER, "the key is sold");
        assertEq(fleet.revealRequestedAt(1), 0, "no accepted request");

        vrf.setRequestGasBurn(0);
        vm.expectEmit(true, true, false, true, address(fleet));
        emit RevealRequested(1, _nextRequestId(fleet));
        fleet.requestReveal(1);
    }

    /// @dev Invariant: against a coordinator that costs what the real one costs, no gas limit
    /// completes a purchase silently: every completed purchase either made its request or said it
    /// failed. The search finds the least gas that completes a purchase, then every limit in the
    /// few thousand gas above it is tried, which is where a starved request would show.
    function test_everyCompletedPurchaseEitherRequestedOrSaidItFailed() public {
        Keyfleet fleet = _deploy();
        uint256 low = 100_000;
        uint256 high = 2_000_000;
        while (low < high) {
            uint256 middle = (low + high) / 2;
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = _purchaseWithGas(fleet, middle);
            vm.revertToState(snapshot);
            if (ok) high = middle;
            else low = middle + 1;
        }
        console2.log("least gas that completes a purchase:", low);

        for (uint256 gasLimit = low; gasLimit < low + 4000; gasLimit += 3) {
            uint256 snapshot = vm.snapshotState();
            (bool ok, uint8 outcome) = _purchaseWithGas(fleet, gasLimit);
            vm.revertToState(snapshot);
            assertTrue(ok, "more gas still completes");
            assertTrue(outcome != 0, "a completed purchase always accounts for its request");
        }
    }

    // --- 3. the answer ---------------------------------------------------

    /// @dev Invariant: the seed is the tagged hash of the chain, the fleet, the key and the word,
    /// and writing it tells marketplaces to refresh the key.
    function test_answerWritesTheSeedAndAnnouncesIt() public {
        Keyfleet fleet = _deploy();
        uint256 tokenId = _buy(fleet);
        uint256 requestId = _lastRequestId(fleet);
        bytes32 expected = keccak256(
            abi.encode(keccak256("keyfleet.trait-seed"), block.chainid, address(fleet), tokenId, uint256(424242))
        );

        vm.expectEmit(true, true, false, true, address(fleet));
        emit KeyRevealed(tokenId, requestId, expected);
        vm.expectEmit(false, false, false, true, address(fleet));
        emit MetadataUpdate(tokenId);
        vrf.fulfill(requestId, _words(424242));

        assertTrue(vrf.lastCallbackSuccess(), "the callback succeeded");
        assertEq(fleet.revealSeed(tokenId), expected, "the seed");
    }

    /// @dev The same word gives two fleets, or two keys, different seeds.
    function test_seedsAreBoundToTheFleetAndTheKey() public {
        Keyfleet first = _deploy();
        Keyfleet second = _deploy();
        _buy(first);
        uint256 firstRequest = _lastRequestId(first);
        _buy(first);
        uint256 secondKeyRequest = _lastRequestId(first);
        _buy(second);
        uint256 otherFleetRequest = _lastRequestId(second);

        vrf.fulfill(firstRequest, _words(7));
        vrf.fulfill(secondKeyRequest, _words(7));
        vrf.fulfill(otherFleetRequest, _words(7));

        assertTrue(first.revealSeed(1) != first.revealSeed(2), "two keys");
        assertTrue(first.revealSeed(1) != second.revealSeed(1), "two fleets");
        assertEq(second.revealSeed(1), _seed(second, 1, 7));
    }

    /// @dev Invariant: only the pinned coordinator can deliver an answer.
    function test_onlyTheCoordinatorMayAnswer() public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        uint256 requestId = _lastRequestId(fleet);

        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.OnlyCoordinator.selector, BUYER));
        fleet.rawFulfillRandomWords(requestId, _words(1));

        assertEq(fleet.revealSeed(1), bytes32(0), "nothing written");
    }

    /// @dev Invariant: the callback never reverts for the coordinator, because a reverted callback
    /// is final and charged: unknown ids, empty answers and a second answer for a revealed key are
    /// ignored without a word.
    function test_unknownEmptyAndDuplicateAnswersAreIgnoredWithoutReverting() public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        uint256 requestId = _lastRequestId(fleet);

        _expectSilentAnswer(fleet, 12_345, _words(1));
        _expectSilentAnswer(fleet, requestId, new uint256[](0));
        assertEq(fleet.revealSeed(1), bytes32(0), "an empty answer writes nothing");

        vrf.fulfill(requestId, _words(2));
        bytes32 seed = fleet.revealSeed(1);
        assertEq(seed, _seed(fleet, 1, 2), "the answer writes the seed");

        _expectSilentAnswer(fleet, requestId, _words(3));
        assertEq(fleet.revealSeed(1), seed, "a duplicate answer does not change the seed");
    }

    /// @dev Invariant: a key has at most one accepted request, so there is only ever one answer
    /// its seed can come from and nobody who orders the answers can choose between two. Once the
    /// coordinator accepts a request nobody, the holder included, can ask for the key again, however
    /// long the answer takes, and no stack of waiting requests can build up behind it.
    function test_anAcceptedRequestIsTheOnlyOneAKeyEverGets() public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        uint256 requestId = _lastRequestId(fleet);
        (, uint64 nonceBefore) = vrf.consumerConfig(address(fleet), subscriptionId);

        address[2] memory askers = [BUYER, address(0xBAD)];
        uint256[3] memory waits = [uint256(0), 1 hours, 365 days];
        for (uint256 i = 0; i < waits.length; ++i) {
            vm.warp(block.timestamp + waits[i]);
            for (uint256 j = 0; j < askers.length; ++j) {
                vm.prank(askers[j]);
                vm.expectRevert(abi.encodeWithSelector(Keyfleet.RevealAlreadyRequested.selector, 1));
                fleet.requestReveal(1);
            }
        }
        (, uint64 nonceAfter) = vrf.consumerConfig(address(fleet), subscriptionId);
        assertEq(nonceAfter, nonceBefore, "no second request reached the coordinator");

        vrf.fulfill(requestId, _words(7));
        assertEq(fleet.revealSeed(1), _seed(fleet, 1, 7), "the one request's answer is the seed");
    }

    /// @dev Invariant: an answer is cheap enough for the 100,000 callback gas with room to spare,
    /// with every slot it touches cold, as it is in the coordinator's own transaction.
    function test_callbackUsesUnderSixtyThousandGasWithColdStorage() public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        uint256 requestId = _lastRequestId(fleet);

        vm.cool(address(fleet));
        vrf.fulfill(requestId, _words(type(uint256).max));

        console2.log("reveal callback gas, cold:", vrf.lastCallbackGasUsed());
        assertTrue(vrf.lastCallbackSuccess(), "the callback succeeded");
        assertLt(vrf.lastCallbackGasUsed(), 60_000, "under 60% of the callback gas limit");
    }

    // --- 4. retries ------------------------------------------------------

    function test_requestRevealRefusesAKeyThatDoesNotExist() public {
        Keyfleet fleet = _deploy();
        _buy(fleet);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        fleet.requestReveal(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        fleet.requestReveal(2);
    }

    function test_requestRevealRefusesARevealedKey() public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        vrf.fulfill(_lastRequestId(fleet), _words(5));
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AlreadyRevealed.selector, 1));
        fleet.requestReveal(1);
    }

    /// @dev Invariant: a key whose request was refused can be retried at once, by anyone, as often as
    /// the coordinator keeps refusing, and a refused retry says so without reverting. The first
    /// retry the coordinator accepts is the last one.
    function test_aFailedRequestCanBeRetriedAtOnceByAnyone() public {
        Keyfleet fleet = _deploy();
        vrf.setRevertAll(true);
        _buy(fleet);

        vm.expectEmit(true, false, false, false, address(fleet));
        emit RevealRequestFailed(1);
        vm.prank(address(0x5712A26E2));
        fleet.requestReveal(1);

        vrf.setRevertAll(false);
        vm.prank(address(0x5712A26E2));
        fleet.requestReveal(1);
        assertEq(fleet.revealRequestedAt(1), block.timestamp, "accepted");
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.RevealAlreadyRequested.selector, 1));
        fleet.requestReveal(1);
        vrf.fulfill(_lastRequestId(fleet), _words(9));
        assertEq(fleet.revealSeed(1), _seed(fleet, 1, 9));
    }

    /// @dev Invariant: a receiver cannot add a second request to the purchase that mints to it.
    function test_aReceiverCannotRetryFromInsideItsOwnPurchase() public {
        Keyfleet fleet = _deploy();
        RetryingReceiver receiver = new RetryingReceiver(fleet);

        vm.prank(BUYER);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        fleet.purchase(address(receiver), type(uint256).max, block.timestamp);
    }

    // --- 5. fuzz ---------------------------------------------------------

    /// @dev Invariant: whatever the coordinator sends — any id, any number of words — the callback
    /// returns within the callback gas limit.
    function testFuzz_callbackNeverRevertsForTheCoordinator(
        uint256 requestId,
        uint256 wordCount,
        uint256 word,
        bool known,
        bool revealFirst
    ) public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        if (known) requestId = _lastRequestId(fleet);
        if (revealFirst) vrf.fulfill(_lastRequestId(fleet), _words(word ^ 1));

        uint256[] memory words = new uint256[](bound(wordCount, 0, 500));
        for (uint256 i = 0; i < words.length; ++i) {
            words[i] = uint256(keccak256(abi.encode(word, i)));
        }

        vm.prank(address(vrf));
        (bool ok,) =
            address(fleet).call{gas: 100_000}(abi.encodeCall(Keyfleet.rawFulfillRandomWords, (requestId, words)));
        assertTrue(ok, "the callback never reverts for the coordinator");
    }

    /// @dev Invariant: a seed is written once. However many answers arrive for a key, the seed is
    /// the first one's and never changes.
    function testFuzz_aSeedIsWrittenOnce(uint256 firstWord, uint256 secondWord) public {
        Keyfleet fleet = _deploy();
        _buy(fleet);
        uint256 requestId = _lastRequestId(fleet);

        vrf.fulfill(requestId, _words(firstWord));
        bytes32 seed = fleet.revealSeed(1);
        vm.prank(address(vrf));
        fleet.rawFulfillRandomWords(requestId, _words(secondWord));

        assertEq(seed, _seed(fleet, 1, firstWord), "the first answer's seed");
        assertEq(fleet.revealSeed(1), seed, "never rewritten");
    }

    // --- helpers ---------------------------------------------------------

    /// @dev Buys with a fixed gas limit and reports whether the purchase completed and what it said
    /// about its request: 0 nothing, 1 `RevealRequested`, 2 `RevealRequestFailed`.
    function _purchaseWithGas(Keyfleet fleet, uint256 gasLimit) private returns (bool ok, uint8 outcome) {
        vm.recordLogs();
        vm.prank(BUYER);
        (ok,) = address(fleet).call{gas: gasLimit}(
            abi.encodeCall(Keyfleet.purchase, (BUYER, type(uint256).max, block.timestamp))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(fleet)) continue;
            if (logs[i].topics[0] == RevealRequested.selector) outcome = 1;
            if (logs[i].topics[0] == RevealRequestFailed.selector) outcome = 2;
        }
    }

    /// @dev Delivers an answer as the coordinator and checks it changed nothing and said nothing.
    function _expectSilentAnswer(Keyfleet fleet, uint256 requestId, uint256[] memory words) private {
        bytes32 before = fleet.revealSeed(1);
        vm.recordLogs();
        vm.prank(address(vrf));
        fleet.rawFulfillRandomWords(requestId, words);
        assertEq(vm.getRecordedLogs().length, 0, "an ignored answer emits nothing");
        assertEq(fleet.revealSeed(1), before, "an ignored answer writes nothing");
    }
}

/// @dev Drives purchases, retries and answers in any order against one fleet, remembering the
/// first seed each key was given. Purchases stop at forty keys so each check stays cheap.
contract RevealHandler is Test {
    uint256 private constant KEYS = 40;

    Keyfleet private immutable FLEET;
    MockVRFCoordinatorV2Plus private immutable VRF;
    address private immutable BUYER;

    uint256[] private _open;
    mapping(uint256 requestId => uint256 tokenId) private _tokenOf;
    mapping(uint256 tokenId => bytes32 seed) public firstSeed;

    constructor(Keyfleet fleet, MockVRFCoordinatorV2Plus vrf, address buyer) {
        FLEET = fleet;
        VRF = vrf;
        BUYER = buyer;
    }

    function buy(bool refuse) external {
        if (FLEET.totalMinted() >= KEYS) return;
        VRF.setRevertAll(refuse);
        uint64 nonce = _nonce();
        vm.prank(BUYER);
        uint256 tokenId = FLEET.purchase(BUYER, type(uint256).max, block.timestamp);
        VRF.setRevertAll(false);
        _track(tokenId, nonce);
    }

    function retry(uint256 tokenSeed, uint256 wait) external {
        uint256 minted = FLEET.totalMinted();
        if (minted == 0) return;
        vm.warp(block.timestamp + bound(wait, 0, 2 hours));
        uint256 tokenId = bound(tokenSeed, 1, minted);
        uint64 nonce = _nonce();
        try FLEET.requestReveal(tokenId) {
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
        if (firstSeed[tokenId] == bytes32(0)) firstSeed[tokenId] = FLEET.revealSeed(tokenId);
    }

    /// @dev Records the request the last call made, if the coordinator accepted one.
    function _track(uint256 tokenId, uint64 nonceBefore) private {
        uint64 nonce = _nonce();
        if (nonce == nonceBefore) return;
        (uint256 requestId,) =
            VRF.computeRequestId(FLEET.VRF_KEY_HASH(), address(FLEET), FLEET.VRF_SUBSCRIPTION_ID(), nonce);
        _tokenOf[requestId] = tokenId;
        _open.push(requestId);
    }

    function _nonce() private view returns (uint64 nonce) {
        (, nonce) = VRF.consumerConfig(address(FLEET), FLEET.VRF_SUBSCRIPTION_ID());
    }

    function _words(uint256 word) private pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = word;
    }
}

contract KeyfleetRevealInvariantTest is RevealFixture {
    Keyfleet private fleet;
    RevealHandler private handler;

    function setUp() public {
        _setUpFixture();
        fleet = _deploy();
        handler = new RevealHandler(fleet, vrf, BUYER);
        targetContract(address(handler));
    }

    /// @dev Invariant: a key's seed, once written, is never rewritten, and a key without a seed
    /// never had one.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_aSeedIsWrittenOnce() public view {
        for (uint256 tokenId = 1; tokenId <= fleet.totalMinted(); ++tokenId) {
            assertEq(fleet.revealSeed(tokenId), handler.firstSeed(tokenId), "the first seed stands");
        }
    }
}
