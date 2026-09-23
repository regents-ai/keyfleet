// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";

/// @dev Reports six decimals, as Base USDC does, because a fleet refuses a USDC with any other.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Buys a key and tries to buy another from inside `onERC721Received`. It holds allowance and
/// balance, so a successful second purchase would mean the guard is missing.
/// @dev A USDC look-alike with ERC-20's default eighteen decimals, against which every ten-USDC
/// price would be ten million wei.
contract EighteenDecimalToken is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
}

contract ReenteringReceiver is IERC721Receiver {
    Keyfleet private immutable FLEET;
    bool private _entered;

    constructor(Keyfleet fleet) {
        FLEET = fleet;
    }

    function approveFleet(IERC20 token) external {
        token.approve(address(FLEET), type(uint256).max);
    }

    function buy() external returns (uint256) {
        return FLEET.purchase(address(this), address(0), type(uint256).max, block.timestamp);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!_entered) {
            _entered = true;
            FLEET.purchase(address(this), address(0), type(uint256).max, block.timestamp);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A router-style receiver: it forwards a key on from inside `onERC721Received`, either the key
/// it was just handed or another key it already holds.
contract ForwardingReceiver is IERC721Receiver {
    Keyfleet private immutable FLEET;
    address private _destination;
    uint256 private _tokenId;
    uint256 private _observedLevel;

    /// @notice What the fleet reported about the new key while the hook was running.
    uint64 public observedEpoch;
    uint256 public observedHeld;

    constructor(Keyfleet fleet) {
        FLEET = fleet;
    }

    /// @dev A level of zero skips the holding-count read, which has no answer on Fleet.Tech presets.
    function observeLevel(uint256 level) external {
        _observedLevel = level;
    }

    function approveFleet(IERC20 token) external {
        token.approve(address(FLEET), type(uint256).max);
    }

    /// @dev A `tokenId` of zero forwards whichever key the hook is handed.
    function setForward(address destination, uint256 tokenId) external {
        _destination = destination;
        _tokenId = tokenId;
    }

    function disableForward() external {
        _destination = address(0);
    }

    function buy() external returns (uint256) {
        return FLEET.purchase(address(this), address(0), type(uint256).max, block.timestamp);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        observedEpoch = FLEET.ownershipEpoch(tokenId);
        if (_observedLevel != 0) observedHeld = FLEET.heldPerLevel(address(this), _observedLevel);
        if (_destination != address(0)) {
            FLEET.transferFrom(address(this), _destination, _tokenId == 0 ? tokenId : _tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract KeyfleetTest is Test {
    using stdStorage for StdStorage;

    /// @dev The reference price, 10 USDC in atomic units.
    uint256 private constant Q = KeyfleetPresets.Q_USDC;
    uint64 private constant VOTING_WINDOW = 24 hours;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    StdStorage private fleetStore;

    MockERC20 private usdc;
    MockERC20 private other;
    KeyfleetAssetRegistry private registry;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    address private buyer = address(0xB0B0B0);
    address private treasury = address(0x7EA5);
    IRegentRevenueStaking private staking = IRegentRevenueStaking(address(0x57A1));
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV1 private factory = IRegentsAutolaunchFactoryV1(address(0xFAC7));
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);

    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed receiver,
        address referrer,
        uint256 gross,
        uint256 protocol,
        uint256 referral,
        uint256 capital,
        uint256 reserve,
        uint256 rebate
    );
    event OwnershipEpoch(uint256 indexed tokenId, uint64 epoch, address indexed from, address indexed to);
    event LevelCompleted(uint256 indexed level, uint256 reimbursement, uint256 surplus);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        other = new MockERC20("Other", "OTH");
        registry = new KeyfleetAssetRegistry(address(0x5AFE), address(usdc));
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    /// @dev A fleet's randomness: the mock coordinator and the suite's subscription.
    function _randomness() private view returns (Keyfleet.Randomness memory) {
        return Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)),
            subscriptionId: vrfSubscription,
            keyHash: keccak256("key hash")
        });
    }

    /// @dev Mints the buyer exactly the next price, so the buyer's balance is zero between buys, and
    /// authorizes twice that, so a purchase that charged more than it quoted would be caught by the
    /// buyer running out of USDC rather than hidden behind an exact cap.
    function _buy(Keyfleet fleet, address receiver, address referrer) private returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, referrer, 2 * price, block.timestamp);
        vm.stopPrank();
    }

    function _buy(Keyfleet fleet, address receiver) private returns (uint256 tokenId) {
        return _buy(fleet, receiver, address(0));
    }

    /// @dev Funds and approves the next price without buying, so an event expectation can be set
    /// immediately before the purchase call itself.
    function _fundNext(Keyfleet fleet) private returns (uint256 price) {
        price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.prank(buyer);
        usdc.approve(address(fleet), price);
    }

    function _wallet(uint256 index) private pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    function _none() private pure returns (uint256[] memory ids) {
        ids = new uint256[](0);
    }

    function _assertBalanceInvariant(Keyfleet fleet) private view {
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.freeCapital(address(usdc)) + fleet.cascadeReserve() + fleet.protocolShareOwed(),
            "fleet USDC balance equals capital plus reserve plus the owed protocol share"
        );
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet and its ledger are born together and correctly bound, so no
    /// deployment step can leave a fleet writing into someone else's ledger.
    function test_constructorDeploysAndBindsItsOwnRewardLedger() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();

        assertEq(rewards.FLEET(), address(fleet), "ledger bound to this fleet");
        assertTrue(rewards.isRewardAsset(address(usdc)), "USDC registered");
        address[] memory assets = rewards.rewardAssets();
        assertEq(assets.length, 1, "only USDC registered");
        assertEq(assets[0], address(usdc), "USDC is the first reward asset");
        assertEq(address(fleet.USDC()), address(usdc));
        assertEq(fleet.TREASURY(), treasury);
        assertEq(address(fleet.ASSET_REGISTRY()), address(registry));
        assertEq(address(fleet.STAKING()), address(staking));
        assertEq(uint256(fleet.PRESET()), uint256(KeyfleetPresets.Preset.FibonacciSyndicate));
        assertEq(fleet.totalMinted(), 0);
        assertEq(fleet.currentPrice(), 0, "only Accelerant persists a price");
    }

    /// @dev Invariant: every bound address is validated once, at construction, because none of them
    /// can be changed afterwards.
    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            IERC20(address(0)),
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );

        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            address(0),
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );

        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            treasury,
            KeyfleetAssetRegistry(address(0)),
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );

        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            treasury,
            registry,
            IRegentRevenueStaking(address(0)),
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );

        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            treasury,
            registry,
            staking,
            IRegentsAutolaunchFactoryV1(address(0)),
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
    }

    /// @dev Invariant: a fleet's USDC is the USDC the shared registry is bound to.
    /// A look-alike token cannot be wired in at deployment and so can never take the staking fee
    /// route, whatever its symbol says.
    function test_constructorRejectsAUsdcThatIsNotTheRegistrysCanonicalOne() public {
        MockERC20 lookalike = new MockERC20("USD Coin", "USDC");

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.UsdcNotCanonical.selector, address(lookalike), address(usdc)));
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            lookalike,
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
    }

    /// @dev Invariant: every price is written in six-decimal atomic USDC, so a fleet refuses a USDC
    /// reporting any other decimals, even one its own registry is bound to.
    function test_constructorRejectsAUsdcThatDoesNotReportSixDecimals() public {
        EighteenDecimalToken eighteen = new EighteenDecimalToken();
        KeyfleetAssetRegistry boundToIt = new KeyfleetAssetRegistry(address(0x5AFE), address(eighteen));

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.UsdcDecimalsWrong.selector, uint8(18)));
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            IERC20(address(eighteen)),
            treasury,
            boundToIt,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
    }

    /// @dev Invariant: only the fleet may write to the ledger it deployed.
    function test_onlyTheFleetCanWriteToItsLedger() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.enrollKey(1, 0);

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.registerAsset(address(other));
    }

    // --- 2. purchase authorization ---------------------------------------

    /// @dev Invariant: the four purchase authorizations are the buyer's only protection against a
    /// slot that moved, so each one is checked before any token moves.
    function test_purchaseHonoursDeadlineMaximumPriceAndDefaultReceiver() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        usdc.mint(buyer, 10 * Q);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);

        vm.warp(1000);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.Expired.selector, 999));
        fleet.purchase(alice, address(0), Q, 999);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PriceAboveMax.selector, Q, Q - 1));
        fleet.purchase(alice, address(0), Q - 1, block.timestamp);

        vm.prank(buyer);
        uint256 tokenId = fleet.purchase(address(0), address(0), 2 * Q, block.timestamp);
        assertEq(fleet.ownerOf(tokenId), buyer, "zero receiver mints to the caller");
        assertEq(tokenId, 1, "token ids start at one");
    }

    /// @dev Invariant: a zero receiver means the caller, whoever the referrer is: the key goes to the
    /// buyer and the referrer receives only its 10% credit.
    function test_zeroReceiverWithAReferrerMintsToTheCallerNotTheReferrer() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 tokenId = _buy(fleet, address(0), carol);

        assertEq(fleet.ownerOf(tokenId), buyer, "the caller holds the key");
        assertEq(fleet.balanceOf(carol), 0, "the referrer holds no key");
        assertEq(fleet.REWARDS().credits(address(usdc), carol), Q / 10, "the referrer is credited its share");
    }

    /// @dev Invariant: Classic stops at 144 seats and the price never moves.
    function test_classicSellsExactlyOneHundredAndFortyFourSeatsAtTheReferencePrice() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        assertEq(fleet.maxSupply(), 144);

        for (uint256 i = 0; i < KeyfleetPresets.CLASSIC_SUPPLY; ++i) {
            assertEq(fleet.nextPrice(), Q, "Classic price is constant");
            assertEq(fleet.remainingSupply(), 144 - i);
            _buy(fleet, _wallet(i));
        }

        assertEq(fleet.remainingSupply(), 0);
        vm.expectRevert(Keyfleet.SoldOut.selector);
        fleet.nextPrice();

        usdc.mint(buyer, Q);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), Q);
        vm.expectRevert(Keyfleet.SoldOut.selector);
        fleet.purchase(alice, address(0), Q, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Invariant: Accelerant stops at 2000 keys, and the last key costs the compounded price.
    function test_accelerantSellsExactlyTwoThousandKeysAndThenStops() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        assertEq(fleet.maxSupply(), 2000);

        usdc.mint(buyer, 1e60);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);

        for (uint256 i = 0; i < KeyfleetPresets.MAX_ACCELERANT_KEYS; ++i) {
            vm.prank(buyer);
            fleet.purchase(alice, address(0), type(uint256).max, block.timestamp);
        }

        assertEq(fleet.totalMinted(), 2000);
        assertEq(fleet.remainingSupply(), 0);
        assertEq(
            fleet.currentPrice(),
            KeyfleetPresets.accelerantNextPrice(KeyfleetPresets.accelerantPrice(1999)),
            "the price stepped once per primary mint"
        );
        vm.expectRevert(Keyfleet.SoldOut.selector);
        fleet.nextPrice();
        vm.prank(buyer);
        vm.expectRevert(Keyfleet.SoldOut.selector);
        fleet.purchase(alice, address(0), type(uint256).max, block.timestamp);
    }

    /// @dev Invariant: the Fibonacci bound is the cumulative supply through level 20. Reaching it by
    /// minting is not practical, so the counter is written directly and the bound checked there.
    function test_fibonacciStopsAtTheCumulativeLevelTwentySupply() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        assertEq(fleet.maxSupply(), KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);

        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);
        assertEq(fleet.totalMinted(), KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);
        assertEq(fleet.remainingSupply(), 0);

        vm.expectRevert(Keyfleet.SoldOut.selector);
        fleet.nextPrice();

        usdc.mint(buyer, type(uint128).max);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), type(uint256).max);
        vm.expectRevert(Keyfleet.SoldOut.selector);
        fleet.purchase(alice, address(0), type(uint256).max, block.timestamp);
        vm.stopPrank();
    }

    // --- 3. Syndicate and Classic ledgers ---------------------------------

    /// @dev Invariant: without a referrer 5% is owed to REGENT stakers and every remaining unit is
    /// free capital; the fleet's USDC balance is exactly those two figures.
    function test_syndicatePurchaseWithoutReferrerOwesStakersAndBooksCapital() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);

        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit Purchased(1, buyer, alice, address(0), Q, Q / 20, 0, Q - Q / 20, 0, 0);
        vm.prank(buyer);
        fleet.purchase(alice, address(0), 2 * price, block.timestamp);

        assertEq(fleet.protocolShareOwed(), Q / 20, "5% owed to stakers");
        assertEq(fleet.freeCapital(address(usdc)), Q - Q / 20, "95% to capital");
        assertEq(fleet.cascadeReserve(), 0, "Syndicate holds no reserve");
        assertEq(usdc.balanceOf(address(fleet.REWARDS())), 0, "no reward backing without a referral");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: a referrer is paid as a pull credit backed by tokens already sitting in the
    /// ledger, never as a push transfer, and capital drops by exactly the referral.
    function test_syndicatePurchaseWithReferrerCreditsTheReferrerInTheLedger() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice, carol);

        assertEq(fleet.protocolShareOwed(), Q / 20, "5% owed to stakers");
        assertEq(rewards.credits(address(usdc), carol), Q / 10, "10% credited to the referrer");
        assertEq(rewards.backed(address(usdc)), Q / 10, "the credit is fully backed");
        assertEq(usdc.balanceOf(address(rewards)), Q / 10, "the backing tokens are in the ledger");
        assertEq(fleet.freeCapital(address(usdc)), Q - Q / 20 - Q / 10, "85% to capital");
        _assertBalanceInvariant(fleet);

        vm.prank(carol);
        uint256 paid = rewards.claim(address(usdc), _none(), address(0));
        assertEq(paid, Q / 10);
        assertEq(usdc.balanceOf(carol), Q / 10, "the referrer pulls the credit");
    }

    /// @dev Invariant: a referrer may be any address including the buyer; nothing rejects a
    /// self-referral, exactly as the spec requires.
    function test_selfReferralIsAcceptedAndCreditedToTheBuyer() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        fleet.purchase(buyer, buyer, 2 * price, block.timestamp);
        vm.stopPrank();

        assertEq(fleet.REWARDS().credits(address(usdc), buyer), price / 10, "the buyer referred itself");
    }

    /// @dev Invariant: across many purchases with and without referrers, every USDC unit paid ends
    /// up in exactly one of the four places that can hold it, and none of it leaves the fleet and
    /// its ledger.
    function test_everyPaidUnitLandsInCapitalReserveOwedShareOrRewardBacking() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 totalPaid;
        for (uint256 i = 0; i < 20; ++i) {
            uint256 price = fleet.nextPrice();
            totalPaid += price;
            _buy(fleet, _wallet(i), i % 2 == 0 ? carol : address(0));
            _assertBalanceInvariant(fleet);
        }

        assertEq(
            fleet.freeCapital(address(usdc)) + fleet.cascadeReserve() + fleet.protocolShareOwed()
                + usdc.balanceOf(address(fleet.REWARDS())),
            totalPaid,
            "buckets, owed share and reward backing account for every unit"
        );
        assertEq(
            usdc.balanceOf(address(fleet)) + usdc.balanceOf(address(fleet.REWARDS())),
            totalPaid,
            "and all of it is still held by the fleet or its ledger"
        );
    }

    /// @dev Invariant: a primary purchase touches the USDC bucket only. Other assets stay at zero
    /// until the deposit slice introduces them.
    function test_purchasesNeverTouchANonUsdcBucket() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        other.mint(address(fleet), 500e18);

        _buy(fleet, alice);
        _buy(fleet, bob);

        assertEq(fleet.freeCapital(address(other)), 0, "a stray token is not capital");
        assertEq(other.balanceOf(address(fleet)), 500e18, "and it is not moved either");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: on every preset, with and without a referrer, each purchase adds exactly 5%
    /// of its gross, floored, to the protocol share owed to stakers, and the fleet and its ledger
    /// together still hold every unit paid: the fleet's balance is capital plus reserve plus the
    /// owed share, and the ledger's balance is exactly what it has backed.
    function test_everyPresetOwesStakersFivePercentOfEachPurchase() public {
        for (uint256 p = 0; p < 4; ++p) {
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset(p));
            KeyfleetRewards rewards = fleet.REWARDS();
            uint256 owed;
            for (uint256 i = 0; i < 12; ++i) {
                uint256 price = fleet.nextPrice();
                _buy(fleet, _wallet(i), i % 3 == 0 ? carol : address(0));
                owed += (price * 500) / 10_000;
                assertEq(fleet.protocolShareOwed(), owed, "each purchase adds its floored 5%");
                _assertBalanceInvariant(fleet);
                assertEq(
                    usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds its backing"
                );
            }
        }
    }

    // --- 4. Accelerant ----------------------------------------------------

    /// @dev Invariant: the first Accelerant mint has no predecessor, so all post-fee proceeds are
    /// capital and nobody is credited a rebate.
    function test_firstAccelerantMintSendsEveryPostFeeUnitToCapital() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        assertEq(fleet.currentPrice(), Q, "the first key costs the reference price");

        _buy(fleet, alice);

        assertEq(fleet.freeCapital(address(usdc)), Q - Q / 20, "95% to capital");
        assertEq(usdc.balanceOf(address(fleet.REWARDS())), 0, "no rebate on the first mint");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: only primary mints advance the Accelerant price, and each one advances it by
    /// exactly 105/100 rounded up. The first three USDC prices are pinned because the platform
    /// mirrors them.
    function test_accelerantPriceStepsFivePercentPerPrimaryMintOnly() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        uint256[3] memory pinned = [uint256(10_000_000), 10_500_000, 11_025_000];

        uint256 expected = Q;
        for (uint256 i = 0; i < 6; ++i) {
            if (i < 3) assertEq(fleet.nextPrice(), pinned[i], "pinned USDC price");
            assertEq(fleet.nextPrice(), expected, "quoted price follows the ladder");
            assertEq(fleet.nextPrice(), KeyfleetPresets.accelerantPrice(i), "and matches the library");
            _buy(fleet, _wallet(i));
            expected = KeyfleetPresets.accelerantNextPrice(expected);
        }

        uint256 beforeTransfer = fleet.nextPrice();
        vm.prank(_wallet(0));
        fleet.transferFrom(_wallet(0), bob, 1);
        assertEq(fleet.nextPrice(), beforeTransfer, "a secondary sale does not advance the price");
    }

    /// @dev Invariant: the rebate is fixed at the moment of the mint and goes to whoever holds the
    /// preceding key then, not to whoever minted it.
    function test_accelerantRebateGoesToTheCurrentHolderOfThePrecedingKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);

        uint256 price = fleet.nextPrice();
        uint256 protocol = price / 20;
        uint256 capital = price / 10;
        uint256 rebate = price - protocol - capital;
        _buy(fleet, carol);

        assertEq(rewards.credits(address(usdc), bob), rebate, "the current holder is rebated");
        assertEq(rewards.credits(address(usdc), alice), 0, "the original minter is not");
        assertEq(usdc.balanceOf(address(rewards)), rebate, "the rebate is backed in the ledger");
        assertEq(fleet.freeCapital(address(usdc)), (Q - Q / 20) + capital, "capital takes its 10%");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: each Accelerant rebate goes to the holder of the key immediately before the
    /// new one, never to the holder of the first key. The third mint costs 11,025,000 and rebates
    /// 9,371,250 to the holder of key 2.
    function test_accelerantThirdMintRebatesTheHolderOfKeyTwoNotKeyOne() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 aliceAfterTwo = rewards.credits(address(usdc), alice);
        assertEq(fleet.nextPrice(), 11_025_000, "third mint price");
        _buy(fleet, carol);

        assertEq(rewards.credits(address(usdc), bob), 9_371_250, "the holder of key 2 is rebated");
        assertEq(rewards.credits(address(usdc), alice), aliceAfterTwo, "the holder of key 1 gains nothing");
        assertEq(rewards.credits(address(usdc), carol), 0, "the new holder rebates no one");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: the rebate is bound to the holder of the preceding key as it stood before the
    /// mint, so a receiver cannot sell that key from inside its own mint hook and redirect the rebate
    /// it is about to be paid.
    function test_accelerantRebateIsBoundBeforeTheMintHookRuns() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();
        ForwardingReceiver receiver = new ForwardingReceiver(fleet);
        usdc.mint(address(receiver), 100 * Q);
        receiver.approveFleet(usdc);

        receiver.disableForward();
        assertEq(receiver.buy(), 1);

        uint256 price = fleet.nextPrice();
        uint256 rebate = price - price / 20 - price / 10;
        receiver.setForward(alice, 1);
        assertEq(receiver.buy(), 2);

        assertEq(fleet.ownerOf(1), alice, "the preceding key left inside the same purchase");
        assertEq(rewards.credits(address(usdc), address(receiver)), rebate, "the rebate was already bound");
        assertEq(rewards.credits(address(usdc), alice), 0, "the new holder gets no part of it");
        assertEq(fleet.ownerOf(2), address(receiver));
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: with a referrer the Accelerant split is 5/10/10/75 and still sums to gross.
    function test_accelerantWithReferrerSplitsFiveTenTenAndSeventyFive() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        uint256 price = fleet.nextPrice();
        _buy(fleet, bob, dave);

        assertEq(rewards.credits(address(usdc), dave), price / 10, "referrer takes 10%");
        assertEq(rewards.credits(address(usdc), alice), price - price / 20 - price / 10 - price / 10, "75% rebate");
        assertEq(fleet.protocolShareOwed(), Q / 20 + price / 20, "5% of each purchase is owed to stakers");
        _assertBalanceInvariant(fleet);
    }

    // --- 5. Cascade -------------------------------------------------------

    /// @dev Invariant: Cascade proceeds are held in the reserve, never in capital, until a level
    /// completes. Level 1 has no predecessor, so its whole reserve becomes capital.
    function test_cascadeLevelOneReleasesItsWholeReserveToCapital() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);

        _buy(fleet, alice);
        assertEq(fleet.freeCapital(address(usdc)), 0, "nothing is capital before completion");
        assertEq(fleet.cascadeReserve(), Q - Q / 20, "the post-fee amount is reserved");
        assertFalse(fleet.levelCompleted(1));

        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit LevelCompleted(1, 0, 2 * (Q - Q / 20));
        vm.prank(buyer);
        fleet.purchase(bob, address(0), 2 * price, block.timestamp);

        assertTrue(fleet.levelCompleted(1), "level 1 completed on its last key");
        assertEq(fleet.cascadeReserve(), 0, "the reserve is emptied");
        assertEq(fleet.freeCapital(address(usdc)), 2 * (Q - Q / 20), "and released to capital");
        assertEq(fleet.levelGrossPaid(1), 2 * Q, "gross paid for level 1 is recorded");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: completing level 2 repays level 1's original gross exactly once, allocates it
    /// to the level-1 cohort, and releases only the surplus to capital.
    function test_cascadeLevelTwoReimbursesLevelOneGrossAndReleasesTheSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 capitalAfterLevelOne = fleet.freeCapital(address(usdc));

        uint256 levelTwoPrice = fleet.nextPrice();
        assertEq(levelTwoPrice, (Q * 120) / 100, "level 2 costs 20% more");
        uint256 levelTwoReserve = 3 * (levelTwoPrice - levelTwoPrice / 20);
        uint256 reimbursement = 2 * Q;
        uint256 surplus = levelTwoReserve - reimbursement;

        _buy(fleet, carol);
        _buy(fleet, dave);
        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit LevelCompleted(2, reimbursement, surplus);
        vm.prank(buyer);
        fleet.purchase(_wallet(9), address(0), 2 * price, block.timestamp);

        assertTrue(fleet.levelCompleted(2));
        assertEq(fleet.cascadeReserve(), 0, "the reserve is emptied again");
        assertEq(fleet.freeCapital(address(usdc)), capitalAfterLevelOne + surplus, "only the surplus is capital");
        assertEq(usdc.balanceOf(address(rewards)), reimbursement, "the repayment is backed in the ledger");
        assertEq(rewards.accrued(address(usdc), 1), Q, "each level-1 key earns its own gross back");
        assertEq(rewards.accrued(address(usdc), 2), Q);
        assertEq(rewards.accrued(address(usdc), 3), 0, "level-2 keys are not repaid by their own level");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: a repayment belongs to whoever holds the key when the level completes, and a
    /// repayment already accrued stays with the address that held the key then.
    function test_cascadeRepaymentFollowsTheHolderAtCompletionAndNeverTravelsAfterwards() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        _buy(fleet, bob);

        // Alice sells key 1 before level 2 completes, so the future repayment goes with the key.
        vm.prank(alice);
        fleet.transferFrom(alice, carol, 1);

        _buy(fleet, _wallet(1));
        _buy(fleet, _wallet(2));
        _buy(fleet, _wallet(3));

        assertEq(rewards.accrued(address(usdc), 1), Q, "key 1 accrued the repayment");
        vm.prank(carol);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), Q, "the holder at completion is repaid");
        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(address(usdc), _none(), address(0));

        // Bob keeps his accrual when he sells key 2 afterwards.
        vm.prank(bob);
        fleet.transferFrom(bob, dave, 2);
        assertEq(rewards.credits(address(usdc), bob), Q, "settlement kept the repayment with Bob");
        assertEq(rewards.accrued(address(usdc), 2), 0, "and the key carries nothing to Dave");
        vm.prank(dave);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(address(usdc), _ids(2), address(0));
        vm.prank(bob);
        assertEq(rewards.claim(address(usdc), _none(), address(0)), Q, "Bob claims after selling every key");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: a level completes exactly once; later resales of its keys cannot re-run the
    /// repayment or reopen the level.
    function test_aCompletedCascadeLevelIsNeverCompletedAgain() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 capital = fleet.freeCapital(address(usdc));

        vm.prank(alice);
        fleet.transferFrom(alice, carol, 1);
        vm.prank(bob);
        fleet.transferFrom(bob, dave, 2);

        assertTrue(fleet.levelCompleted(1));
        assertEq(fleet.freeCapital(address(usdc)), capital, "resales change no bucket");
        assertEq(fleet.cascadeReserve(), 0);
        _assertBalanceInvariant(fleet);
    }

    // --- 6. Fibonacci holding limits --------------------------------------

    /// @dev Invariant: the per-wallet limit is applied on a mint as well as on an incoming transfer,
    /// and a wallet that sells frees the slot again.
    function test_holdingLimitAppliesOnMintAndOnIncomingTransfer() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        assertEq(fleet.holdingLimit(1), 1, "one key per wallet at level 1");

        _buy(fleet, alice);
        assertEq(fleet.heldPerLevel(alice, 1), 1);

        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.HoldingLimitExceeded.selector, alice, 1, 1));
        fleet.purchase(alice, address(0), 2 * price, block.timestamp);
        vm.stopPrank();

        _buy(fleet, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.HoldingLimitExceeded.selector, alice, 1, 1));
        fleet.transferFrom(bob, alice, 2);

        vm.prank(alice);
        fleet.transferFrom(alice, carol, 1);
        assertEq(fleet.heldPerLevel(alice, 1), 0, "selling frees the slot");
        vm.prank(bob);
        fleet.transferFrom(bob, alice, 2);
        assertEq(fleet.heldPerLevel(alice, 1), 1);
    }

    /// @dev Invariant: from level 8 the limit is a tenth of the level supply, so a wallet may hold
    /// five of level 8's fifty-five keys and no more.
    function test_levelEightAllowsFiveKeysPerWalletAndRejectsTheSixth() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        assertEq(fleet.holdingLimit(8), 5, "a tenth of fifty-five keys");

        // Fill levels 1 through 7 with one key per wallet per level.
        uint256 filled = KeyfleetPresets.fibonacciTotalSupplyThrough(7);
        for (uint256 level = 1; level <= 7; ++level) {
            uint256 supply = KeyfleetPresets.fibonacciLevelSupply(level);
            for (uint256 i = 0; i < supply; ++i) {
                _buy(fleet, _wallet(i));
            }
        }
        assertEq(fleet.totalMinted(), filled);
        assertEq(fleet.levelOf(filled + 1), 8, "the next key opens level 8");

        for (uint256 i = 0; i < 5; ++i) {
            _buy(fleet, alice);
        }
        assertEq(fleet.heldPerLevel(alice, 8), 5);

        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.HoldingLimitExceeded.selector, alice, 8, 5));
        fleet.purchase(alice, address(0), 2 * price, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Invariant: the two Fleet.Tech presets have no levels and no per-wallet cap, so one wallet
    /// may accumulate keys freely.
    function test_fleetTechPresetsHaveNoLevelsAndNoWalletCap() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);

        _buy(fleet, alice);
        _buy(fleet, alice);
        _buy(fleet, alice);
        assertEq(fleet.balanceOf(alice), 3, "no cap on Classic");

        vm.expectRevert(Keyfleet.NotFibonacciPreset.selector);
        fleet.levelOf(1);
        vm.expectRevert(Keyfleet.NotFibonacciPreset.selector);
        fleet.holdingLimit(1);
    }

    // --- 7. ownership epochs ----------------------------------------------

    /// @dev Invariant: the epoch counts ownership changes, so a key returning to a previous owner
    /// carries a strictly higher epoch than it did the first time.
    function test_epochIncrementsOnMintAndOnEveryTransferIncludingAReturn() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);

        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit OwnershipEpoch(1, 1, address(0), alice);
        vm.prank(buyer);
        fleet.purchase(alice, address(0), 2 * price, block.timestamp);
        assertEq(fleet.ownershipEpoch(1), 1, "the mint is epoch 1");

        vm.expectEmit(true, true, true, true, address(fleet));
        emit OwnershipEpoch(1, 2, alice, bob);
        vm.prank(alice);
        fleet.transferFrom(alice, bob, 1);
        assertEq(fleet.ownershipEpoch(1), 2);

        vm.expectEmit(true, true, true, true, address(fleet));
        emit OwnershipEpoch(1, 3, bob, alice);
        vm.prank(bob);
        fleet.transferFrom(bob, alice, 1);
        assertEq(fleet.ownershipEpoch(1), 3, "returning to Alice is a third epoch");

        _buy(fleet, carol);
        assertEq(fleet.ownershipEpoch(2), 1, "each key counts its own epochs");
    }

    // --- 8. reentrancy and receiver hooks ---------------------------------

    /// @dev Invariant: a receiver cannot buy again from inside the mint hook, where the fleet's
    /// counters and buckets are mid-update.
    function test_reenteringPurchaseFromTheReceiverHookIsRejected() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        ReenteringReceiver receiver = new ReenteringReceiver(fleet);
        usdc.mint(address(receiver), 10 * Q);
        receiver.approveFleet(usdc);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        receiver.buy();

        assertEq(fleet.totalMinted(), 0, "nothing was minted");
        assertEq(usdc.balanceOf(address(fleet)), 0, "and nothing was taken");
    }

    /// @dev Invariant: because a key is enrolled before it is minted, a router-style receiver may
    /// forward a key on from inside the mint hook. The forwarded key settles nothing, lands on the
    /// destination with its second epoch and correct holding counts, and anything the purchase does
    /// after the mint, including a Cascade level completion, sees the forwarded holder.
    function test_aReceiverMayForwardAKeyFromItsMintHook() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        ForwardingReceiver receiver = new ForwardingReceiver(fleet);
        usdc.mint(address(receiver), 100 * Q);
        receiver.approveFleet(usdc);

        // The key it is handed goes straight on to Alice.
        receiver.setForward(alice, 0);
        receiver.observeLevel(1);
        assertEq(receiver.buy(), 1);
        assertEq(receiver.observedEpoch(), 1, "the hook already sees the mint epoch");
        assertEq(receiver.observedHeld(), 1, "and already sees itself holding the key");
        assertEq(fleet.ownerOf(1), alice, "the hook forwarded the key it was handed");
        assertEq(fleet.ownershipEpoch(1), 2, "mint then forward is the second epoch");
        assertEq(fleet.heldPerLevel(address(receiver), 1), 0, "the router holds nothing");
        assertEq(fleet.heldPerLevel(alice, 1), 1, "and the destination holds one");

        // Keep the next key, which completes level 1.
        receiver.disableForward();
        assertEq(receiver.buy(), 2);
        assertTrue(fleet.levelCompleted(1));

        _buy(fleet, carol);
        _buy(fleet, _wallet(1));

        // The key that completes level 2 is minted to the router, whose hook passes its level-1 key
        // to Dave before the completion runs.
        receiver.setForward(dave, 2);
        assertEq(receiver.buy(), 5);
        assertTrue(fleet.levelCompleted(2));

        assertEq(fleet.ownerOf(2), dave, "the level-1 key moved inside the completing purchase");
        assertEq(fleet.ownershipEpoch(2), 2);
        assertEq(rewards.accrued(address(usdc), 2), Q, "the repayment followed the key to Dave");
        assertEq(rewards.credits(address(usdc), address(receiver)), 0, "the router earned nothing");
        assertEq(rewards.accrued(address(usdc), 1), Q, "Alice's level-1 key was repaid too");
        assertEq(fleet.ownerOf(5), address(receiver), "the router kept the key it bought");
        assertEq(fleet.ownershipEpoch(5), 1);
        assertEq(fleet.heldPerLevel(address(receiver), 1), 0);
        assertEq(fleet.heldPerLevel(address(receiver), 2), 1);
        assertEq(fleet.heldPerLevel(dave, 1), 1);
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: minting uses the safe path, so a contract that cannot hold ERC721s is not
    /// handed a key.
    function test_mintingToAContractWithoutTheReceiverHookReverts() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        usdc.mint(buyer, Q);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), Q);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(registry)));
        fleet.purchase(address(registry), address(0), 2 * Q, block.timestamp);
        vm.stopPrank();
    }

    // --- 9. views and metadata --------------------------------------------

    /// @dev Invariant: the quote a buyer is shown is the split the purchase actually performs.
    function test_quoteMatchesTheSplitTheNextPurchasePerforms() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);

        // On a fresh Accelerant fleet there is no predecessor, so both quotes rebate nothing and
        // hand the whole post-fee remainder to capital, and the first purchase does exactly that.
        KeyfleetPresets.PurchaseSplit memory firstPlain = fleet.quote(false);
        KeyfleetPresets.PurchaseSplit memory firstReferred = fleet.quote(true);
        assertEq(firstPlain.rebate, 0, "nothing to rebate before the first key exists");
        assertEq(firstPlain.capital, Q - Q / 20, "the whole post-fee remainder is capital");
        assertEq(firstReferred.rebate, 0, "a referrer does not create a predecessor");
        assertEq(firstReferred.capital, Q - Q / 20 - Q / 10, "and capital takes the rest");

        uint256 firstPrice = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit Purchased(1, buyer, alice, address(0), Q, firstPlain.protocol, 0, firstPlain.capital, 0, 0);
        vm.prank(buyer);
        fleet.purchase(alice, address(0), 2 * firstPrice, block.timestamp);

        KeyfleetPresets.PurchaseSplit memory plain = fleet.quote(false);
        KeyfleetPresets.PurchaseSplit memory referred = fleet.quote(true);
        uint256 price = _fundNext(fleet);

        assertEq(plain.protocol + plain.referral + plain.capital + plain.reserve + plain.rebate, price, "sums to gross");
        assertEq(plain.referral, 0, "no referrer, no deduction");
        assertEq(referred.referral, price / 10);
        assertEq(referred.rebate, price - price / 20 - price / 10 - price / 10);

        vm.expectEmit(true, true, true, true, address(fleet));
        emit Purchased(
            2, buyer, bob, carol, price, referred.protocol, referred.referral, referred.capital, 0, referred.rebate
        );
        vm.prank(buyer);
        fleet.purchase(bob, carol, 2 * price, block.timestamp);
    }

    /// @dev Invariant: metadata is a fixed base plus the token id, with no setter and no per-token
    /// storage, and an unminted id has no URI.
    function test_tokenUriIsTheFixedBasePlusTheTokenId() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);

        assertEq(fleet.tokenURI(1), string.concat(BASE_URI, "1"));
        assertEq(fleet.name(), "Keyfleet Alpha");
        assertEq(fleet.symbol(), "KFA");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        fleet.tokenURI(2);
    }

    /// @dev Invariant: level boundaries the fleet reports are the library's, so app, contract and
    /// tests quote one ladder.
    function test_levelViewsAgreeWithThePresetLibrary() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);

        assertEq(fleet.levelOf(1), 1);
        assertEq(fleet.levelOf(2), 1);
        assertEq(fleet.levelOf(3), 2);
        assertEq(fleet.levelOf(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID), 20);
        assertEq(fleet.holdingLimit(7), 1);
        assertEq(fleet.holdingLimit(20), KeyfleetPresets.fibonacciLevelSupply(20) / 10);

        vm.expectRevert(KeyfleetPresets.TokenIdOutOfBounds.selector);
        fleet.levelOf(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        fleet.holdingLimit(21);
    }

    // --- 10. gas ----------------------------------------------------------

    /// @dev Makes every account and slot a purchase reads cold again, as it is at the start of the
    /// buyer's own transaction, so a measurement is not flattered by the test's earlier reads.
    function _coolPurchasePath(Keyfleet fleet, address receiver) private {
        vm.cool(address(fleet));
        vm.cool(address(fleet.REWARDS()));
        vm.cool(address(usdc));
        vm.cool(address(vrf));
        vm.cool(receiver);
    }

    /// @dev Measures the first referred purchase on a fresh fleet, which is the most expensive
    /// primary purchase in this slice: every accounting slot it touches, the owed protocol share
    /// included, is written from zero, and every account the purchase touches starts cold.
    function _measureFirstReferredPurchase(KeyfleetPresets.Preset preset) private returns (uint256 used) {
        Keyfleet fleet = _deploy(preset);

        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        _coolPurchasePath(fleet, alice);
        uint256 before = gasleft();
        fleet.purchase(alice, carol, 2 * price, block.timestamp);
        used = before - gasleft();
        vm.stopPrank();
    }

    /// @dev The published execution-gas ceiling covers the worst primary purchase: the first referred
    /// one on a fresh Cascade fleet, with every account it touches starting cold. It is measured
    /// against the plain ERC-20 mock standing in for USDC and the mock VRF coordinator, whose request
    /// writes what the real coordinator's writes: 445,417 gas in execution, and the ceiling is that
    /// plus twenty percent, rounded up to the nearest thousand. The first purchase after each
    /// `sendProtocolShare` pays the write of the owed share from zero again. That makes it a
    /// regression bound on the fleet's own work, not the figure to publish: real Base USDC is a
    /// proxy and costs more per transfer, and the fork-measured totals in the contracts README are
    /// the published ones.
    /// The level-completing Cascade purchase is measured alongside it for information; it is cheaper,
    /// because by then the buckets it writes are warm.
    function test_firstReferredPurchaseOnAFreshFleetIsTheWorstCase() public {
        uint256 cascade = _measureFirstReferredPurchase(KeyfleetPresets.Preset.FibonacciCascade);
        uint256 syndicate = _measureFirstReferredPurchase(KeyfleetPresets.Preset.FibonacciSyndicate);
        uint256 accelerant = _measureFirstReferredPurchase(KeyfleetPresets.Preset.FleetTechAccelerant);
        uint256 classic = _measureFirstReferredPurchase(KeyfleetPresets.Preset.FleetTechClassic);

        console2.log("first referred purchase gas, Cascade:", cascade);
        console2.log("first referred purchase gas, Syndicate:", syndicate);
        console2.log("first referred purchase gas, Accelerant:", accelerant);
        console2.log("first referred purchase gas, Classic:", classic);

        assertLt(cascade, 535_000, "the worst primary purchase stays under the published ceiling");
        assertGt(cascade, syndicate, "Cascade is the most expensive preset");
        assertGt(cascade, accelerant);
        assertGt(cascade, classic);

        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, carol);
        _buy(fleet, dave);
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        _coolPurchasePath(fleet, _wallet(9));
        uint256 before = gasleft();
        fleet.purchase(_wallet(9), _wallet(8), 2 * price, block.timestamp);
        uint256 completing = before - gasleft();
        vm.stopPrank();

        console2.log("Cascade level-completing purchase gas:", completing);
        assertTrue(fleet.levelCompleted(2));
    }

    // --- 11. fuzz invariant -----------------------------------------------

    /// @dev Invariant: across random purchase and transfer sequences on any preset, the fleet's
    /// USDC balance is always exactly its free capital plus its Cascade reserve plus the protocol
    /// share owed to stakers. Reward backing sits in the ledger, so nothing else can hide here.
    function testFuzz_usdcBalanceAlwaysEqualsCapitalPlusReservePlusOwedShare(uint256 seed) public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset(seed % 4));
        usdc.mint(buyer, 1e30);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);

        for (uint256 i = 0; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address wallet = _wallet(seed % 8);
            uint256 minted = fleet.totalMinted();

            if (minted == 0 || seed % 3 != 0) {
                address referrer = seed % 5 == 0 ? _wallet((seed >> 8) % 8) : address(0);
                vm.prank(buyer);
                try fleet.purchase(wallet, referrer, type(uint256).max, block.timestamp) returns (uint256) {} catch {}
            } else {
                uint256 tokenId = ((seed >> 16) % minted) + 1;
                address owner = fleet.ownerOf(tokenId);
                vm.prank(owner);
                try fleet.transferFrom(owner, wallet, tokenId) {} catch {}
            }

            _assertBalanceInvariant(fleet);
        }

        assertGt(fleet.totalMinted(), 0, "the sequence bought at least one key");
    }

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }
}
