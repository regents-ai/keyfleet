// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTradingFactory} from "../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../src/KeyfleetTradingTreasury.sol";
import {KeyfleetTradingFixture} from "./helpers/KeyfleetTradingFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Receives a Key and tries to buy another from inside its `onERC721Received`.
contract ReenteringBuyer {
    KeyfleetTradingManager private immutable _fleet;

    constructor(KeyfleetTradingManager fleet) {
        _fleet = fleet;
        MockToken(address(fleet.USDC())).approve(address(fleet), type(uint256).max);
    }

    function buy() external {
        _fleet.purchase(address(0), type(uint256).max, block.timestamp, new bytes32[](0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _fleet.purchase(address(0), type(uint256).max, block.timestamp, new bytes32[](0));
        return this.onERC721Received.selector;
    }
}

/// @dev Answers every call, `balanceOf` included, with 31 bytes of 0xff: one byte short of a whole
/// word.
contract ShortAnswerToken {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, not(0))
            return(0, 31)
        }
    }
}

contract KeyfleetTradingManagerTest is KeyfleetTradingFixture {
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _setUpTrading();
        _createTrading();
    }

    // --- purchase -------------------------------------------------------------

    function test_purchasePaysTheWholePriceToTheTreasury() public {
        uint256 price = fleet.price();
        uint256 before = usdc.balanceOf(address(treasury));
        uint256 tokenId = _tbuy(stranger);
        assertEq(usdc.balanceOf(address(treasury)), before + price);
        assertEq(usdc.balanceOf(address(fleet)), 0);
        assertEq(usdc.balanceOf(address(rewards)), 0);
        assertEq(usdc.balanceOf(buyer), 0);
        assertEq(keys.ownerOf(tokenId), stranger);
        assertEq(tokenId, _tkey(2));
        assertEq(fleet.totalMinted(), 2);
    }

    function test_purchaseRaisesThePriceByTheStep() public {
        uint256 price = fleet.price();
        _tbuy(stranger);
        assertEq(fleet.price(), price + price * STEP_BPS / 10_000);
    }

    function test_purchaseAnnouncesTheSale() public {
        uint256 price = fleet.price();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectEmit(address(fleet));
        emit KeyfleetTradingManager.Purchased(_tkey(2), buyer, stranger, price);
        fleet.purchase(stranger, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
    }

    function test_purchaseWithNoReceiverMintsToTheBuyer() public {
        uint256 tokenId = _tbuy(address(0));
        assertEq(keys.ownerOf(tokenId), buyer);
    }

    function test_purchaseEnrolsTheKeyInTheLedger() public {
        uint256 tokenId = _tbuy(stranger);
        assertEq(rewards.keyCohort(tokenId), 0);
        assertEq(rewards.cohortSize(0), 2);
    }

    function test_purchaseRefusedAfterItsDeadline() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.Expired.selector, block.timestamp - 1));
        fleet.purchase(stranger, type(uint256).max, block.timestamp - 1, new bytes32[](0));
    }

    function test_purchaseRefusedAboveTheBuyersMaximum() public {
        uint256 price = fleet.price();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.PriceAboveMax.selector, price, price - 1));
        fleet.purchase(stranger, price - 1, block.timestamp, new bytes32[](0));
    }

    function test_purchaseRefusedWithoutTheUsdc() public {
        uint256 price = fleet.price();
        usdc.mint(buyer, price - 1);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert();
        fleet.purchase(stranger, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
        assertEq(fleet.totalMinted(), 1);
        assertEq(fleet.price(), price);
    }

    function test_purchaseRefusedOnceTheFleetIsClosed() public {
        vm.prank(creator);
        treasury.close();
        vm.prank(buyer);
        vm.expectRevert(KeyfleetTradingManager.SalesEnded.selector);
        fleet.purchase(stranger, type(uint256).max, block.timestamp, new bytes32[](0));
    }

    function test_purchaseRefusedPastTheKeyCap() public {
        _createTrading(_tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 3));
        assertEq(fleet.maxKeys(), 3);
        _tbuy(stranger);
        _tbuy(stranger);
        uint256 price = fleet.price();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(KeyfleetTradingManager.SoldOut.selector);
        fleet.purchase(stranger, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
    }

    function test_noCapMeansTheCollectionLimit() public view {
        assertEq(fleet.KEY_CAP(), 0);
        assertEq(fleet.maxKeys(), keys.MAX_KEY_NUMBER());
    }

    function test_receiverCannotBuyAgainFromInsideItsMint() public {
        ReenteringBuyer reenterer = new ReenteringBuyer(fleet);
        usdc.mint(address(reenterer), 1_000e6);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        reenterer.buy();
    }

    // --- joining requirements ---------------------------------------------------

    function test_addressListAdmitsOnlyListedReceivers() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.merkleRoot = _leaf(stranger);
        _createTrading(terms);

        assertTrue(fleet.meetsRequirements(stranger, new bytes32[](0)));
        _tbuy(stranger);

        address outsider = makeAddr("outsider");
        uint256 price = fleet.price();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.RequirementNotMet.selector, outsider));
        fleet.purchase(outsider, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
    }

    function test_nftRequirementAdmitsHolders() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.nft = address(keys);
        _createTrading(terms);
        assertTrue(fleet.meetsRequirements(creator, new bytes32[](0)));
        assertFalse(fleet.meetsRequirements(stranger, new bytes32[](0)));
        _tbuy(creator);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.RequirementNotMet.selector, stranger));
        fleet.purchase(stranger, type(uint256).max, block.timestamp, new bytes32[](0));
    }

    function test_tokenRequirementAdmitsHoldersOfTheMinimum() public {
        MockToken token = new MockToken("Token", "TKN");
        token.mint(stranger, 5e18);
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.token = address(token);
        terms.requirements.tokenMin = 5e18;
        _createTrading(terms);
        assertTrue(fleet.meetsRequirements(stranger, new bytes32[](0)));
        assertFalse(fleet.meetsRequirements(buyer, new bytes32[](0)));
        _tbuy(stranger);
    }

    /// @dev An NFT or token requirement whose `balanceOf` answers with less than a whole word is
    /// not met, however large the bytes it does answer.
    function test_aRequirementAnsweringTooLittleDataIsNotMet() public {
        address short = address(new ShortAnswerToken());
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.nft = short;
        _createTrading(terms);
        assertFalse(fleet.meetsRequirements(stranger, new bytes32[](0)));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.RequirementNotMet.selector, stranger));
        fleet.purchase(stranger, type(uint256).max, block.timestamp, new bytes32[](0));

        terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.token = short;
        terms.requirements.tokenMin = 1;
        _createTrading(terms);
        assertFalse(fleet.meetsRequirements(stranger, new bytes32[](0)));
    }

    function test_requirementsAreSetOnceAndKept() public {
        KeyfleetTradingFactory.TradingTerms memory terms = _tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0);
        terms.requirements.merkleRoot = keccak256("list");
        _createTrading(terms);
        assertEq(fleet.requirements().merkleRoot, keccak256("list"));
    }

    // --- the creator ------------------------------------------------------------

    function test_creatorSetsPriceAndStep() public {
        vm.startPrank(creator);
        vm.expectEmit(address(fleet));
        emit KeyfleetTradingManager.PriceSet(MIN_PRICE);
        fleet.setPrice(MIN_PRICE);
        vm.expectEmit(address(fleet));
        emit KeyfleetTradingManager.StepSet(10_000);
        fleet.setStep(10_000);
        vm.stopPrank();
        assertEq(fleet.price(), MIN_PRICE);
        assertEq(fleet.stepBps(), 10_000);
        _tbuy(stranger);
        assertEq(fleet.price(), 2 * MIN_PRICE);
    }

    function test_priceAndStepRefusedOutOfRange() public {
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.PriceInvalid.selector, MIN_PRICE - 1));
        fleet.setPrice(MIN_PRICE - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.PriceInvalid.selector, MAX_PRICE + 1));
        fleet.setPrice(MAX_PRICE + 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.StepInvalid.selector, 10_001));
        fleet.setStep(10_001);
        vm.stopPrank();
    }

    function test_onlyTheCreatorChangesPriceStepOrProfile() public {
        KeyfleetManager.Profile memory profile = _profile("Renamed");
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.OnlyCreator.selector, stranger));
        fleet.setPrice(MIN_PRICE);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.OnlyCreator.selector, stranger));
        fleet.setStep(0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.OnlyCreator.selector, stranger));
        fleet.setProfile(profile);
        vm.stopPrank();
    }

    function test_creatorChangesTheProfileAndRefreshesTheCollection() public {
        KeyfleetManager.Profile memory profile = _profile("Renamed");
        vm.expectEmit(address(fleet));
        emit KeyfleetTradingManager.ProfileChanged(profile.name, profile.description, profile.imageLink);
        vm.expectEmit(address(keys));
        emit IERC4906.BatchMetadataUpdate(_tkey(1), keys.tokenIdOf(fleet.FLEET_ID(), keys.MAX_KEY_NUMBER()));
        vm.prank(creator);
        fleet.setProfile(profile);
        assertEq(fleet.profile().name, "Renamed");
    }

    function test_profileRefusedOutOfLimits() public {
        KeyfleetManager.Profile memory profile = _profile("");
        vm.startPrank(creator);
        vm.expectRevert(KeyfleetTradingManager.ProfileInvalid.selector);
        fleet.setProfile(profile);
        profile = _profile(string(new bytes(101)));
        vm.expectRevert(KeyfleetTradingManager.ProfileInvalid.selector);
        fleet.setProfile(profile);
        profile = _profile("Fine");
        profile.description = string(new bytes(2001));
        vm.expectRevert(KeyfleetTradingManager.ProfileInvalid.selector);
        fleet.setProfile(profile);
        profile = _profile("Fine");
        profile.imageLink = string(new bytes(513));
        vm.expectRevert(KeyfleetTradingManager.ProfileInvalid.selector);
        fleet.setProfile(profile);
        vm.stopPrank();
    }

    function test_creatorIsWhoeverHoldsKeyOne() public {
        uint256 first = _tkey(1);
        vm.prank(creator);
        keys.transferFrom(creator, stranger, first);
        assertEq(fleet.creator(), stranger);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.OnlyCreator.selector, creator));
        fleet.setPrice(MIN_PRICE);
        vm.prank(stranger);
        fleet.setPrice(MIN_PRICE);
        assertEq(fleet.price(), MIN_PRICE);
    }

    function testFuzz_authorityFollowsKeyOne(address holder) public {
        assumeNotPrecompile(holder);
        assumeNotForgeAddress(holder);
        vm.assume(holder != address(0) && holder.code.length == 0 && holder != creator);
        uint256 first = _tkey(1);
        vm.prank(creator);
        keys.transferFrom(creator, holder, first);

        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.OnlyCreator.selector, creator));
        fleet.setStep(0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingTreasury.OnlyCreator.selector, creator));
        treasury.setTradingWallet(wallet);
        vm.stopPrank();

        vm.startPrank(holder);
        fleet.setStep(0);
        treasury.setTradingWallet(wallet);
        treasury.sendToTrading(1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(wallet), 1);
    }

    // --- factory and collection only -----------------------------------------------

    function test_initializeAndFirstKeyAreTheFactorysAlone() public {
        KeyfleetManager.Profile memory profile = _profile("Again");
        KeyfleetManager.Requirements memory anyone;
        vm.expectRevert(KeyfleetTradingManager.OnlyFactory.selector);
        fleet.initialize(profile, anyone);
        vm.expectRevert(KeyfleetTradingManager.OnlyFactory.selector);
        fleet.sellFirstKey(stranger);

        vm.startPrank(address(trading));
        vm.expectRevert(KeyfleetTradingManager.AlreadyInitialized.selector);
        fleet.initialize(profile, anyone);
        vm.expectRevert(KeyfleetTradingManager.FirstKeySold.selector);
        fleet.sellFirstKey(stranger);
        vm.stopPrank();
    }

    function test_onlyTheCollectionReportsMovesOfThisFleetsKeys() public {
        uint256 first = _tkey(1);
        vm.expectRevert(KeyfleetTradingManager.OnlyKeys.selector);
        fleet.onKeyMoved(first, creator);

        uint256 foreign = keys.tokenIdOf(1, 1);
        vm.prank(address(keys));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTradingManager.ForeignKey.selector, foreign));
        fleet.onKeyMoved(foreign, creator);
    }

    function test_keyMovesSettleToTheOutgoingHolder() public {
        uint256 first = _tkey(1);
        vm.expectCall(address(rewards), abi.encodeCall(KeyfleetRewards.settleKey, (first, creator)));
        vm.prank(creator);
        keys.transferFrom(creator, stranger, first);
    }

    // --- maturity ---------------------------------------------------------------------

    function test_keysCountTwoDaysAfterMintInMintOrder() public {
        assertEq(fleet.matureKeys(), 0);
        vm.warp(block.timestamp + 1 days);
        _tbuy(stranger);
        _tbuy(stranger);
        assertEq(fleet.matureKeys(), 0);
        vm.warp(keys.mintedAt(_tkey(1)) + 2 days - 1);
        assertEq(fleet.matureKeys(), 0);
        vm.warp(keys.mintedAt(_tkey(1)) + 2 days);
        assertEq(fleet.matureKeys(), 1);
        vm.warp(keys.mintedAt(_tkey(3)) + 2 days);
        assertEq(fleet.matureKeys(), 3);
    }

    /// @dev Keys bought with a gap of their own before each, a quarter of them in the same second as
    /// the one before: at a random later time and at each Key's own edge, the second before and the
    /// second it counts, the search agrees with a plain count over the mint times this test saw.
    function testFuzz_matureKeysMatchesEveryKeysMintTime(uint8 count, uint256 seed, uint32 later) public {
        count = uint8(bound(count, 1, 40));
        uint256[] memory mintedAt = new uint256[](uint256(count) + 2);
        mintedAt[1] = block.timestamp;
        for (uint256 n = 2; n <= uint256(count) + 1; ++n) {
            uint256 r = uint256(keccak256(abi.encode(seed, n)));
            vm.warp(block.timestamp + (r % 4 == 0 ? 0 : (r >> 8) % 3 days));
            _tbuy(stranger);
            mintedAt[n] = block.timestamp;
        }
        uint256 end = block.timestamp + bound(later, 0, 3 days);
        vm.warp(end);
        assertEq(fleet.matureKeys(), _plainCount(mintedAt));
        for (uint256 n = 1; n < mintedAt.length; ++n) {
            for (uint256 d = 0; d < 2; ++d) {
                vm.warp(mintedAt[n] + 2 days - 1 + d);
                assertEq(fleet.matureKeys(), _plainCount(mintedAt));
            }
        }
    }

    // --- price ------------------------------------------------------------------------

    /// @dev The step's rise is rounded down: 33.33% of 1,000,003 units is 333,300.9999, so the next
    /// price is 1,333,303, on paper and after a real sale.
    function test_theStepRoundsDown() public {
        assertEq(fleet.raised(1_000_003, 3_333), 1_333_303);
        assertEq(fleet.raised(1_000_001, 1), 1_000_101);
        vm.startPrank(creator);
        fleet.setPrice(1_000_003);
        fleet.setStep(3_333);
        vm.stopPrank();
        _tbuy(stranger);
        assertEq(fleet.price(), 1_333_303);
    }

    function test_priceStopsAtTheCeiling() public view {
        assertEq(fleet.raised(MAX_PRICE, 10_000), MAX_PRICE);
        assertEq(fleet.raised(MAX_PRICE - 1, 10_000), MAX_PRICE);
        assertEq(fleet.raised(MAX_PRICE, 0), MAX_PRICE);
    }

    /// @dev Over a long run of sales from any starting price and step in range, the price never
    /// leaves its range, never overflows, never rounds down to no rise and never falls.
    function testFuzz_priceRunNeverOverflowsStallsOrLeavesItsRange(uint256 start, uint256 step, uint16 sales)
        public
        view
    {
        uint256 price = bound(start, MIN_PRICE, MAX_PRICE);
        step = bound(step, 0, 10_000);
        uint256 runs = bound(sales, 1, 5_000);
        for (uint256 i = 0; i < runs; ++i) {
            uint256 next = fleet.raised(price, step);
            assertGe(next, MIN_PRICE);
            assertLe(next, MAX_PRICE);
            if (step == 0 || price == MAX_PRICE) {
                assertEq(next, price);
            } else {
                assertGt(next, price);
                assertGe(next - price, price < MAX_PRICE - 100 ? 100 : MAX_PRICE - price);
            }
            price = next;
        }
    }

    /// @dev Real sales, with the creator changing price and step between them, always pay exactly
    /// the price shown and leave the next price raised by the step.
    function testFuzz_salesPayThePriceShown(uint256 start, uint256 step, uint8 sales) public {
        uint256 runs = bound(sales, 1, 30);
        vm.startPrank(creator);
        fleet.setPrice(bound(start, MIN_PRICE, MAX_PRICE));
        fleet.setStep(bound(step, 0, 10_000));
        vm.stopPrank();
        for (uint256 i = 0; i < runs; ++i) {
            uint256 price = fleet.price();
            uint256 before = usdc.balanceOf(address(treasury));
            _tbuy(stranger);
            assertEq(usdc.balanceOf(address(treasury)), before + price);
            assertEq(fleet.price(), fleet.raised(price, fleet.stepBps()));
        }
    }

    /// @dev The Keys counting now by a plain count: the last whose mint was two days ago or more.
    function _plainCount(uint256[] memory mintedAt) private view returns (uint256 counting) {
        for (uint256 n = 1; n < mintedAt.length; ++n) {
            if (mintedAt[n] + 2 days <= block.timestamp) counting = n;
        }
    }

    function _leaf(address account) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }
}
