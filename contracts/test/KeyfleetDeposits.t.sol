// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";

/// @dev Reports six decimals, as Base USDC does, because a fleet refuses a USDC with any other.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for the deployed Regents revenue staking contract. It reproduces the two
/// behaviours the fee adapter depends on: it pulls the USDC itself with `transferFrom` and it
/// reports how much it observed arriving. `setPaused` reproduces `whenNotPaused`, `setShortfall`
/// reproduces a contract that accepts the tokens but reports less than it took, `setCreditWithoutPulling`
/// reproduces one that reports the whole amount without ever pulling it, and `setCallback` reproduces
/// one that calls back into the fleet while the fleet is mid-deposit.
contract MockStaking is IRegentRevenueStaking {
    using SafeERC20 for IERC20;

    error StakingPaused();

    IERC20 private immutable USDC;

    bool public paused;
    bool public creditWithoutPulling;
    uint256 public shortfall;
    uint256 public registered;
    uint256 public lastAmount;
    bytes32 public lastTag;
    bytes32 public lastRef;
    address public lastPayer;
    uint256 public callCount;

    Keyfleet private _callbackFleet;

    constructor(IERC20 usdc) {
        USDC = usdc;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setShortfall(uint256 value) external {
        shortfall = value;
    }

    function setCreditWithoutPulling(bool value) external {
        creditWithoutPulling = value;
    }

    function setCallback(Keyfleet fleet) external {
        _callbackFleet = fleet;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received) {
        if (paused) revert StakingPaused();
        if (address(_callbackFleet) != address(0)) _callbackFleet.depositCapital(address(USDC), amount);

        if (creditWithoutPulling) {
            received = amount;
        } else {
            uint256 beforeBalance = USDC.balanceOf(address(this));
            USDC.safeTransferFrom(msg.sender, address(this), amount);
            received = USDC.balanceOf(address(this)) - beforeBalance - shortfall;
        }

        registered += received;
        lastAmount = amount;
        lastTag = sourceTag;
        lastRef = sourceRef;
        lastPayer = msg.sender;
        callCount += 1;
    }
}

/// @dev A deposit asset that calls back into a chosen fleet entry point the first time it moves,
/// from inside the transfer the fleet is in the middle of. Every entry point moves this token at
/// least once, and the target is a selector, so one token covers every ordered pair of them.
contract ReenteringToken is ERC20 {
    Keyfleet private _fleet;
    bytes4 private _target;
    bool private _entered;

    constructor() ERC20("Reenter", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev `target` is the selector of the fleet function to re-enter.
    function arm(Keyfleet fleet, bytes4 target) external {
        _fleet = fleet;
        _target = target;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (_target == bytes4(0) || _entered) return;
        _entered = true;
        if (_target == Keyfleet.depositCapital.selector) _fleet.depositCapital(address(this), 1_000);
        else if (_target == Keyfleet.depositRevenue.selector) _fleet.depositRevenue(address(this), 1_000, bytes32(0));
        else _fleet.recognizeSurplus(address(this));
    }
}

contract KeyfleetDepositsTest is Test {
    uint64 private constant VOTING_WINDOW = 24 hours;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private regent;
    MockToken private usdc;
    MockToken private other;
    KeyfleetAssetRegistry private registry;
    MockStaking private staking;
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV1 private factory = IRegentsAutolaunchFactoryV1(address(0xFAC7));

    address private safe = address(0x5AFE);
    address private treasury = address(0x7EA5);
    address private buyer = address(0xB0B0B0);
    address private payer = address(0xDEDE);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    event FeeCharged(address indexed asset, uint256 amount, uint256 fee, address indexed destination);
    event CapitalDeposited(address indexed asset, address indexed depositor, uint256 amount, uint256 net);
    event RevenueDeposited(
        address indexed asset, address indexed depositor, uint256 amount, uint256 net, bytes32 paymentRef
    );
    event SurplusRecognized(address indexed asset, address indexed caller, uint256 amount, uint256 net);

    function setUp() public {
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        registry = new KeyfleetAssetRegistry(safe, address(usdc));
        staking = new MockStaking(usdc);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet) {
        return new Keyfleet(
            preset,
            usdc,
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI)
        );
    }

    function _admit(Keyfleet fleet, address token) private {
        vm.startPrank(safe);
        registry.setFactoryTokenAllowed(token, true);
        registry.setFleetTokenAllowed(address(fleet), token, true);
        vm.stopPrank();
    }

    function _buy(Keyfleet fleet, address receiver) private returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, address(0), 2 * price, block.timestamp);
        vm.stopPrank();
    }

    /// @dev One key per wallet, because the Fibonacci holding limit is one key per level below
    /// level 8 and the identity of a holder never matters to a deposit.
    function _buyMany(Keyfleet fleet, uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
    }

    function _wallet(uint256 index) private pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    /// @dev Funds and approves without depositing, so an event expectation can be set immediately
    /// before the deposit call itself.
    function _fund(Keyfleet fleet, MockToken token, uint256 amount) private {
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(fleet), amount);
    }

    function _depositCapital(Keyfleet fleet, MockToken token, uint256 amount) private {
        _fund(fleet, token, amount);
        vm.prank(payer);
        fleet.depositCapital(address(token), amount);
    }

    function _depositRevenue(Keyfleet fleet, MockToken token, uint256 amount, bytes32 paymentRef) private {
        _fund(fleet, token, amount);
        vm.prank(payer);
        fleet.depositRevenue(address(token), amount, paymentRef);
    }

    // --- 1. the fee -------------------------------------------------------

    /// @dev Invariant: the fee is exactly two percent of the accepted receipt, rounded down, and
    /// the fleet keeps the rest, so the two parts always add back up to the gross amount.
    function test_feeIsTwoPercentOfGrossRoundedDown() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(other));

        uint256[6] memory amounts = [uint256(50), 99, 100, 1_000, 1_001, 1_000_000e18];
        uint256 expectedTreasury;
        uint256 expectedCapital;
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            uint256 fee = (amount * 200) / 10_000;
            _depositCapital(fleet, other, amount);
            expectedTreasury += fee;
            expectedCapital += amount - fee;
            assertEq(other.balanceOf(treasury), expectedTreasury, "treasury holds every fee taken so far");
            assertEq(fleet.freeCapital(address(other)), expectedCapital, "capital holds every net so far");
        }
        assertEq(
            other.balanceOf(address(fleet)) + other.balanceOf(treasury),
            expectedTreasury + expectedCapital,
            "fee plus net is the whole gross"
        );
    }

    /// @dev Invariant: the fee floors, so a receipt too small to carry two percent is kept whole
    /// rather than rounded up against the payer or silently skipped.
    function test_receiptBelowFiftyUnitsPaysNoFeeAndIsKeptWhole() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(other));

        _fund(fleet, other, 49);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit FeeCharged(address(other), 49, 0, treasury);
        vm.prank(payer);
        fleet.depositCapital(address(other), 49);

        assertEq(other.balanceOf(treasury), 0, "no fee was taken");
        assertEq(fleet.freeCapital(address(other)), 49, "the whole receipt became capital");
    }

    /// @dev Invariant: a deposit of nothing is refused, so no empty receipt can be recorded.
    function test_zeroAmountIsRejected() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(other));
        _buy(fleet, alice);

        vm.startPrank(payer);
        vm.expectRevert(Keyfleet.ZeroAmount.selector);
        fleet.depositCapital(address(other), 0);
        vm.expectRevert(Keyfleet.ZeroAmount.selector);
        fleet.depositRevenue(address(other), 0, bytes32(0));
        vm.stopPrank();
    }

    /// @dev Invariant: the USDC fee is registered revenue, not a bare transfer. It reaches the
    /// staking contract through its own entry point, carrying the fleet source tag and the payer's
    /// reference, and the approval it needed is fully consumed.
    function test_usdcFeeIsRegisteredWithTheStakingContract() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(usdc));
        _buy(fleet, alice);
        bytes32 paymentRef = keccak256("invoice-4711");
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _fund(fleet, usdc, 10_000e6);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit FeeCharged(address(usdc), 10_000e6, 200e6, address(staking));
        vm.prank(payer);
        fleet.depositRevenue(address(usdc), 10_000e6, paymentRef);

        assertEq(usdc.balanceOf(address(staking)), 200e6, "the staking contract holds the fee");
        assertEq(staking.registered(), 200e6, "and registered all of it as revenue");
        assertEq(staking.lastAmount(), 200e6, "the fee was the amount registered");
        assertEq(staking.lastTag(), keccak256("keyfleet"), "under the keyfleet source tag");
        assertEq(staking.lastRef(), paymentRef, "carrying the payer's reference");
        assertEq(staking.lastPayer(), address(fleet), "paid by the fleet itself");
        assertEq(usdc.allowance(address(fleet), address(staking)), 0, "no approval is left behind");
        assertEq(usdc.balanceOf(treasury), treasuryBefore, "the treasury takes no USDC deposit fee");
        assertEq(usdc.balanceOf(address(fleet.REWARDS())), 9_800e6, "the net backs member rewards");
    }

    /// @dev Invariant: a fee that cannot be registered kills the whole deposit. There is no deferred
    /// fee and no fallback to a plain transfer that would be mislabelled as registered revenue.
    function test_pausedStakingRevertsTheWholeDeposit() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(usdc));
        _buy(fleet, alice);
        staking.setPaused(true);
        uint256 balanceBefore = usdc.balanceOf(address(fleet));
        uint256 capitalBefore = fleet.freeCapital(address(usdc));

        usdc.mint(payer, 10_000e6);
        vm.startPrank(payer);
        usdc.approve(address(fleet), 10_000e6);
        vm.expectRevert(MockStaking.StakingPaused.selector);
        fleet.depositRevenue(address(usdc), 10_000e6, bytes32(0));
        vm.expectRevert(MockStaking.StakingPaused.selector);
        fleet.depositCapital(address(usdc), 10_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(payer), 10_000e6, "the payer keeps every unit");
        assertEq(usdc.balanceOf(address(fleet)), balanceBefore, "the fleet took nothing");
        assertEq(fleet.freeCapital(address(usdc)), capitalBefore, "and recorded nothing");
    }

    /// @dev Invariant: the fleet believes the amount the staking contract reports, not the amount it
    /// sent, so a contract that takes the fee but registers less than all of it is refused.
    function test_underReportingStakingRevertsFeeRegistrationFailed() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(usdc));
        staking.setShortfall(1);

        usdc.mint(payer, 10_000e6);
        vm.startPrank(payer);
        usdc.approve(address(fleet), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.FeeRegistrationFailed.selector, 200e6, 200e6 - 1));
        fleet.depositCapital(address(usdc), 10_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(payer), 10_000e6, "the payer keeps every unit");
        assertEq(staking.registered(), 0, "nothing was registered");
    }

    /// @dev Invariant: only the exact configured USDC address takes the staking route. Every other
    /// admitted asset pays its fee to the treasury in that same asset.
    function test_nonUsdcFeeGoesToTheTreasuryInThatAsset() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(other));
        _admit(fleet, address(regent));
        _buy(fleet, alice);

        _depositCapital(fleet, other, 10_000);
        _depositRevenue(fleet, regent, 10_000, bytes32(0));

        assertEq(other.balanceOf(treasury), 200, "the treasury was paid in the deposited asset");
        assertEq(staking.callCount(), 0, "the staking contract was never called");
        assertEq(fleet.freeCapital(address(other)), 9_800, "capital took the net");
    }

    // --- 2. admission -----------------------------------------------------

    /// @dev Invariant: admission is checked before anything moves, on all three entry points, so an
    /// unsupported token can never be pulled in, let alone turned into capital or claims.
    function test_unadmittedAssetIsRejectedBeforeAnythingMoves() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        other.mint(payer, 10_000);
        other.mint(address(fleet), 10_000);

        vm.startPrank(payer);
        other.approve(address(fleet), 10_000);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AssetNotAdmitted.selector, address(other)));
        fleet.depositCapital(address(other), 10_000);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AssetNotAdmitted.selector, address(other)));
        fleet.depositRevenue(address(other), 10_000, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AssetNotAdmitted.selector, address(other)));
        fleet.recognizeSurplus(address(other));
        vm.stopPrank();

        assertEq(other.balanceOf(payer), 10_000, "the payer kept every unit");
        assertEq(fleet.freeCapital(address(other)), 0, "the bare transfer stayed unrecognized");
    }

    /// @dev Invariant: admission governs new receipts only. Disabling an asset afterwards leaves
    /// booked capital, recorded reward backing and pending claims exactly as they were.
    function test_disablingAdmissionStopsNewReceiptsOnly() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        uint256 tokenId = _buy(fleet, alice);

        _depositCapital(fleet, other, 10_000);
        _depositRevenue(fleet, other, 10_000, bytes32(0));

        vm.prank(safe);
        registry.setFleetTokenAllowed(address(fleet), address(other), false);

        other.mint(payer, 10_000);
        vm.startPrank(payer);
        other.approve(address(fleet), 10_000);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AssetNotAdmitted.selector, address(other)));
        fleet.depositCapital(address(other), 10_000);
        vm.stopPrank();

        assertEq(fleet.freeCapital(address(other)), 9_800, "booked capital is untouched");
        assertEq(rewards.backed(address(other)), 9_800, "recorded backing is untouched");
        assertTrue(rewards.isRewardAsset(address(other)), "the asset stays on the historical list");

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.prank(alice);
        uint256 paid = rewards.claim(address(other), ids, address(0));
        assertEq(paid, 9_800, "the earned claim still settles and pays out");
        assertEq(other.balanceOf(alice), 9_800, "to the address that earned it");
    }

    // --- 3. capital deposits ---------------------------------------------

    /// @dev Invariant: a capital deposit becomes spendable working capital and nothing else. It
    /// touches no cohort, registers no reward asset and creates no claim.
    function test_depositCapitalBooksTheNetAsWorkingCapitalOnly() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        _buy(fleet, alice);

        _fund(fleet, other, 10_000);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit CapitalDeposited(address(other), payer, 10_000, 9_800);
        vm.prank(payer);
        fleet.depositCapital(address(other), 10_000);

        assertEq(fleet.freeCapital(address(other)), 9_800);
        assertEq(other.balanceOf(address(fleet)), 9_800, "the fleet holds exactly what it booked");
        assertEq(other.balanceOf(address(rewards)), 0, "nothing reached the ledger");
        assertFalse(rewards.isRewardAsset(address(other)), "capital never registers a reward asset");
        assertEq(fleet.accountedBalance(address(other)), 9_800);
        assertEq(fleet.surplus(address(other)), 0, "a booked deposit is not a surplus");
    }

    /// @dev Invariant: a capital deposit works on a fleet with no keys at all, which is what makes
    /// the revenue path safe to reject when nothing is eligible.
    function test_depositCapitalWorksBeforeAnyKeyIsMinted() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _admit(fleet, address(other));

        _depositCapital(fleet, other, 10_000);
        assertEq(fleet.freeCapital(address(other)), 9_800);
    }

    // --- 4. revenue deposits ---------------------------------------------

    /// @dev Invariant: revenue is refused when no cohort can receive it, so a deposit can never be
    /// stranded in the fleet with nobody eligible for it. The refusal is the fleet's own guard,
    /// taken before anything moves, not the ledger's identical one taken after the fee has already
    /// been paid. The two share a selector, so the proof is that no token moved and no fee was
    /// registered: USDC is the deposit asset here precisely because a late guard would have left
    /// its fee visible on the staking contract.
    function test_revenueIsRejectedBeforeAnythingMovesWhenNothingIsEligible() public {
        Keyfleet classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(classic, address(usdc));
        _fund(classic, usdc, 10_000e6);
        vm.prank(payer);
        vm.expectRevert(Keyfleet.NoEligibleKeys.selector);
        classic.depositRevenue(address(usdc), 10_000e6, bytes32(0));

        assertEq(usdc.balanceOf(payer), 10_000e6, "the payer keeps every unit");
        assertEq(usdc.balanceOf(address(classic)), 0, "the fleet pulled nothing");
        assertEq(staking.callCount(), 0, "and no fee was registered");

        Keyfleet fibonacci = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _admit(fibonacci, address(usdc));
        _buy(fibonacci, alice);
        assertEq(fibonacci.completedLevels(), 0, "level 1 is not complete with one of its two keys");
        uint256 balanceBefore = usdc.balanceOf(address(fibonacci));

        _fund(fibonacci, usdc, 10_000e6);
        vm.prank(payer);
        vm.expectRevert(Keyfleet.NoEligibleKeys.selector);
        fibonacci.depositRevenue(address(usdc), 10_000e6, bytes32(0));

        assertEq(usdc.balanceOf(payer), 20_000e6, "the payer keeps every unit of both attempts");
        assertEq(usdc.balanceOf(address(fibonacci)), balanceBefore, "the fleet pulled nothing");
        assertEq(staking.callCount(), 0, "and no fee was registered");
    }

    /// @dev Invariant: Classic revenue is equal per currently minted key, and the whole net amount
    /// is moved into the ledger and recorded as backed in the same transaction.
    function test_classicRevenueIsEqualPerKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        uint256 first = _buy(fleet, alice);
        uint256 second = _buy(fleet, bob);
        uint256 third = _buy(fleet, bob);

        _fund(fleet, other, 10_000);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit RevenueDeposited(address(other), payer, 10_000, 9_800, bytes32("svc"));
        vm.prank(payer);
        fleet.depositRevenue(address(other), 10_000, bytes32("svc"));

        assertEq(rewards.accrued(address(other), first), 3_266);
        assertEq(rewards.accrued(address(other), second), 3_266);
        assertEq(rewards.accrued(address(other), third), 3_266);
        assertEq(rewards.backed(address(other)), 9_800, "the whole net is backed, dust included");
        assertEq(other.balanceOf(address(rewards)), 9_800, "and the tokens are actually there");
        assertEq(other.balanceOf(address(fleet)), 0, "the fleet keeps none of it");
        assertEq(fleet.freeCapital(address(other)), 0, "revenue never becomes capital");
    }

    /// @dev Invariant: Fibonacci revenue is equal per completed level first and equal per key within
    /// a level second, so a small early level earns more per key than a large later one.
    function test_fibonacciRevenueIsEqualPerCompletedLevelThenPerKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        _buyMany(fleet, 5);
        assertEq(fleet.completedLevels(), 2, "levels 1 and 2 are fully minted");

        _depositRevenue(fleet, other, 10_000, bytes32(0));

        // net 9_800 splits 4_900 to level 1 across two keys and 4_900 to level 2 across three.
        assertEq(rewards.accrued(address(other), 1), 2_450);
        assertEq(rewards.accrued(address(other), 2), 2_450);
        assertEq(rewards.accrued(address(other), 3), 1_633);
        assertEq(rewards.accrued(address(other), 4), 1_633);
        assertEq(rewards.accrued(address(other), 5), 1_633);
        assertEq(rewards.backed(address(other)), 9_800, "the whole net is backed");
    }

    /// @dev Invariant: an unfinished level earns nothing, and the keys already minted into it start
    /// at the index the deposit left behind rather than picking up earlier rewards.
    function test_incompleteLevelEarnsNothingAndItsKeysStartAtTheCurrentIndex() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        _buyMany(fleet, 6); // key 6 opens level 3, which has five keys.
        assertEq(fleet.completedLevels(), 2, "level 3 is still open");

        _depositRevenue(fleet, other, 10_000, bytes32(0));
        assertEq(rewards.accrued(address(other), 6), 0, "the open level earned nothing");
        assertEq(rewards.cohortIndex(address(other), 3), 0, "its index never moved");

        _buyMany(fleet, 4); // completes level 3 with keys 7 to 10.
        assertEq(fleet.completedLevels(), 3);
        assertEq(rewards.accrued(address(other), 10), 0, "a key minted later starts from here");

        _depositRevenue(fleet, other, 10_000, bytes32(0));
        // net 9_800 over three levels: 3_266 each, and the last level absorbs the remainder.
        assertEq(rewards.accrued(address(other), 6), 653, "level 3 keys share only the second deposit");
        assertEq(rewards.accrued(address(other), 10), 653, "the late key earns the same as its level mates");
        assertEq(rewards.accrued(address(other), 1), 4_083, "level 1 keeps its first-deposit share");
    }

    /// @dev Invariant: the remainder of the equal split across levels is allocated to the last
    /// completed level, so the whole net amount is backed and nothing is stranded in the fleet.
    function test_splitRemainderGoesToTheLastCompletedLevel() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        _buyMany(fleet, 10);
        assertEq(fleet.completedLevels(), 3);

        _depositRevenue(fleet, other, 10_000, bytes32(0));

        uint256 precision = rewards.PRECISION();
        // net 9_800 over three levels is 3_266 each with 2 left over, which level 3 takes.
        assertEq(rewards.cohortIndex(address(other), 1), (3_266 * precision) / 2);
        assertEq(rewards.cohortIndex(address(other), 2), (3_266 * precision) / 3);
        assertEq(rewards.cohortIndex(address(other), 3), (3_268 * precision) / 5);
        assertEq(rewards.backed(address(other)), 9_800, "every unit of the net is backed");
        assertEq(other.balanceOf(address(fleet)), 0, "and none of it is left in the fleet");
    }

    /// @dev Invariant: a net amount too small to divide across the eligible levels is refused rather
    /// than quietly allocating zero to some of them.
    function test_netSmallerThanTheEligibleLevelCountIsRejected() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _admit(fleet, address(other));
        _buyMany(fleet, 10);

        other.mint(payer, 2);
        vm.startPrank(payer);
        other.approve(address(fleet), 2);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        fleet.depositRevenue(address(other), 2, bytes32(0));
        vm.stopPrank();
    }

    /// @dev Invariant: the ledger's lifetime bound of eight reward assets is counted from USDC, so
    /// seven further assets are accepted, the last of them being the eighth the ledger will ever
    /// hold, and the ninth distinct asset is refused outright.
    function test_theNinthRewardAssetIsRefused() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);

        for (uint256 i = 0; i < 7; ++i) {
            MockToken token = new MockToken("Rev", "REV");
            _admit(fleet, address(token));
            _depositRevenue(fleet, token, 10_000, bytes32(0));
        }
        assertEq(rewards.rewardAssets().length, rewards.MAX_REWARD_ASSETS(), "USDC plus seven deposit assets");

        MockToken ninth = new MockToken("Rev", "REV");
        _admit(fleet, address(ninth));
        ninth.mint(payer, 10_000);
        vm.startPrank(payer);
        ninth.approve(address(fleet), 10_000);
        vm.expectRevert(KeyfleetRewards.AssetBoundReached.selector);
        fleet.depositRevenue(address(ninth), 10_000, bytes32(0));
        vm.stopPrank();

        // Capital is unaffected: it never registers a reward asset.
        _depositCapital(fleet, ninth, 10_000);
        assertEq(fleet.freeCapital(address(ninth)), 9_800);
    }

    /// @dev Invariant: an asset already used for revenue is registered once and reused, so repeated
    /// deposits of the same asset never consume more of the ledger's bound.
    function test_repeatedRevenueInOneAssetRegistersItOnce() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        _buy(fleet, alice);

        _depositRevenue(fleet, other, 10_000, bytes32(0));
        _depositRevenue(fleet, other, 10_000, bytes32(0));
        _depositRevenue(fleet, other, 10_000, bytes32(0));

        assertEq(rewards.rewardAssets().length, 2, "USDC and this one asset");
        assertEq(rewards.backed(address(other)), 3 * 9_800);
    }

    // --- 5. surplus recognition -------------------------------------------

    /// @dev Invariant: recognition books only the part of the balance nothing else has a purpose
    /// for. The Cascade completion reserve is accounted for, so an incomplete level's reserve can
    /// never be turned into spendable capital by anyone.
    function test_recognizeSurplusBooksOnlyTheUnaccountedPartAndSparesTheCascadeReserve() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _admit(fleet, address(usdc));
        _buy(fleet, alice);
        uint256 reserve = fleet.cascadeReserve();
        assertGt(reserve, 0, "the first Cascade key funds the reserve");
        assertEq(fleet.surplus(address(usdc)), 0, "an accounted balance shows no surplus");

        usdc.mint(address(fleet), 10_000);
        assertEq(fleet.surplus(address(usdc)), 10_000, "a bare transfer is the whole surplus");

        vm.expectEmit(true, true, true, true, address(fleet));
        emit SurplusRecognized(address(usdc), bob, 10_000, 9_800);
        vm.prank(bob);
        uint256 net = fleet.recognizeSurplus(address(usdc));

        assertEq(net, 9_800);
        assertEq(fleet.freeCapital(address(usdc)), 9_800, "only the unaccounted part became capital");
        assertEq(fleet.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(fleet.surplus(address(usdc)), 0, "nothing is left unaccounted");

        vm.expectRevert(Keyfleet.NoSurplus.selector);
        fleet.recognizeSurplus(address(usdc));
    }

    /// @dev Invariant: recognition cannot reclassify a recorded liability, because reward backing
    /// sits in the ledger and is never part of the fleet's own balance.
    function test_recognizeSurplusCannotReachRewardBacking() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(other));
        _buy(fleet, alice);
        _depositRevenue(fleet, other, 10_000, bytes32(0));

        assertEq(other.balanceOf(address(fleet)), 0, "revenue left the fleet entirely");
        vm.expectRevert(Keyfleet.NoSurplus.selector);
        fleet.recognizeSurplus(address(other));
        assertEq(rewards.backed(address(other)), 9_800, "the liability is unchanged");
    }

    /// @dev Invariant: recognition pays the same fee as an ordinary receipt, on the USDC route too,
    /// and reports no payment reference because there is no payer to name.
    function test_recognizedUsdcSurplusPaysTheFeeThroughStaking() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(usdc));
        usdc.mint(address(fleet), 10_000e6);

        vm.prank(bob);
        fleet.recognizeSurplus(address(usdc));

        assertEq(staking.registered(), 200e6, "the fee was registered revenue");
        assertEq(staking.lastRef(), bytes32(0), "with no payment reference");
        assertEq(fleet.freeCapital(address(usdc)), 9_800e6);
    }

    /// @dev Invariant: keys are paid in USDC and USDC is also a deposit asset, yet free capital, the
    /// Cascade completion reserve and reward backing stay three separate figures. A USDC capital
    /// deposit moves only capital, a USDC revenue deposit moves only backing, neither leaves a
    /// surplus behind, and the reimbursement a level completion pays lands beside the revenue in the
    /// ledger without disturbing it.
    function test_usdcDepositsAndUsdcPurchasesKeepCapitalReserveAndBackingApart() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        _admit(fleet, address(usdc));
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, _wallet(3));
        assertEq(fleet.freeCapital(address(usdc)), 19_000_000, "level 1 released its reserve to capital");
        assertEq(fleet.cascadeReserve(), 11_400_000, "key 3 opened the level 2 reserve");

        _depositCapital(fleet, usdc, 1_000e6);
        assertEq(fleet.freeCapital(address(usdc)), 19_000_000 + 980e6, "a capital deposit moves only capital");
        assertEq(fleet.cascadeReserve(), 11_400_000, "and leaves the reserve alone");

        _depositRevenue(fleet, usdc, 1_000e6, bytes32(0));
        assertEq(rewards.backed(address(usdc)), 980e6, "a revenue deposit moves only backing");
        assertEq(fleet.freeCapital(address(usdc)), 19_000_000 + 980e6, "and leaves capital alone");
        assertEq(fleet.cascadeReserve(), 11_400_000, "and the reserve");
        assertEq(fleet.surplus(address(usdc)), 0, "neither deposit left anything unaccounted");
        vm.expectRevert(Keyfleet.NoSurplus.selector);
        fleet.recognizeSurplus(address(usdc));

        _buy(fleet, _wallet(4));
        _buy(fleet, _wallet(5));
        assertTrue(fleet.levelCompleted(2), "level 2 completed");
        assertEq(fleet.cascadeReserve(), 0);
        assertEq(fleet.freeCapital(address(usdc)), 19_000_000 + 980e6 + 14_200_000, "only the surplus is capital");
        assertEq(rewards.backed(address(usdc)), 980e6 + 20_000_000, "the reimbursement joins the revenue");
        assertEq(rewards.accrued(address(usdc), 1), 490e6 + 10_000_000, "key 1 earned revenue and repayment");

        assertEq(usdc.balanceOf(address(fleet)), fleet.freeCapital(address(usdc)), "the fleet holds only capital");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds only backing");
        assertEq(usdc.balanceOf(treasury), 2 * 500_000 + 3 * 600_000, "the treasury holds only purchase shares");
        assertEq(staking.registered(), 2 * 20e6, "staking holds only the two deposit fees");

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _one(1), address(0)), 500e6, "both are paid in one claim");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "and the ledger still balances");
    }

    function _one(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    // --- 6. guards and invariants -----------------------------------------

    /// @dev Invariant: the guard is one lock over all three entry points, not three separate ones,
    /// so a token that calls back mid-transfer cannot slip into a sibling entry point either. Every
    /// ordered pair is covered, including the three cross-function ones.
    function test_reentryIsRejectedForEveryOrderedPairOfEntryPoints() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);

        bytes4[3] memory entries =
            [Keyfleet.depositCapital.selector, Keyfleet.depositRevenue.selector, Keyfleet.recognizeSurplus.selector];
        for (uint256 outer = 0; outer < entries.length; ++outer) {
            for (uint256 inner = 0; inner < entries.length; ++inner) {
                ReenteringToken token = new ReenteringToken();
                _admit(fleet, address(token));
                token.mint(payer, 100_000);
                token.mint(address(fleet), 100_000);
                token.arm(fleet, entries[inner]);

                vm.startPrank(payer);
                token.approve(address(fleet), 100_000);
                vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
                _callEntry(fleet, entries[outer], address(token));
                vm.stopPrank();

                assertEq(fleet.freeCapital(address(token)), 0, "nothing was booked");
            }
        }
    }

    function _callEntry(Keyfleet fleet, bytes4 entry, address asset) private {
        if (entry == Keyfleet.depositCapital.selector) fleet.depositCapital(asset, 10_000);
        else if (entry == Keyfleet.depositRevenue.selector) fleet.depositRevenue(asset, 10_000, bytes32(0));
        else fleet.recognizeSurplus(asset);
    }

    /// @dev Invariant: the staking contract is called from inside a deposit, so the guard has to
    /// hold against it too. A staking contract that called back into the fleet could otherwise book
    /// a second receipt against a balance the first one had not finished accounting for.
    function test_reentryFromTheStakingContractIsRejected() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(usdc));
        staking.setCallback(fleet);

        _fund(fleet, usdc, 10_000e6);
        vm.prank(payer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        fleet.depositCapital(address(usdc), 10_000e6);

        assertEq(fleet.freeCapital(address(usdc)), 0, "nothing was booked");
        assertEq(usdc.balanceOf(payer), 10_000e6, "the payer keeps every unit");
    }

    /// @dev Invariant: the fee is only settled once the staking contract has actually taken it. One
    /// that reports the whole fee without pulling it would leave the tokens in the fleet under a
    /// live approval, where a later call would recognize them as surplus and book them twice.
    function test_stakingThatCreditsWithoutPullingIsRejected() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _admit(fleet, address(usdc));
        staking.setCreditWithoutPulling(true);

        _fund(fleet, usdc, 10_000e6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.FeeRegistrationFailed.selector, 200e6, 200e6));
        fleet.depositCapital(address(usdc), 10_000e6);

        assertEq(usdc.balanceOf(payer), 10_000e6, "the payer keeps every unit");
        assertEq(usdc.balanceOf(address(fleet)), 0, "the fleet holds nothing");
        assertEq(usdc.allowance(address(fleet), address(staking)), 0, "no approval survives the revert");
    }

    /// @dev Invariant: levels are a Fibonacci notion only, so the view refuses to answer for the two
    /// Fleet.Tech presets rather than inventing a level for them.
    function test_completedLevelsRefusesToAnswerForFleetTechPresets() public {
        Keyfleet classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        vm.expectRevert(Keyfleet.NotFibonacciPreset.selector);
        classic.completedLevels();

        Keyfleet accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        vm.expectRevert(Keyfleet.NotFibonacciPreset.selector);
        accelerant.completedLevels();
    }

    /// @dev Invariant: a level counts as complete exactly when its last token id has been minted,
    /// which is the only thing the revenue split reads, and it is derived from the mint count alone.
    function test_completedLevelsTracksTheMintCountExactly() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        uint256[11] memory expected = [uint256(0), 0, 1, 1, 1, 2, 2, 2, 2, 2, 3];
        for (uint256 minted = 0; minted <= 10; ++minted) {
            assertEq(fleet.completedLevels(), expected[minted], "completed levels after this many mints");
            if (minted < 10) _buy(fleet, _wallet(minted + 1));
        }
    }

    /// @dev Invariant: whatever sequence of receipts and bare transfers it sees, the fleet always
    /// holds at least what it says it has booked, so no recorded bucket is ever unbacked.
    function testFuzz_balanceAlwaysCoversEveryBookedBucket(
        uint96 capitalAmount,
        uint96 revenueAmount,
        uint96 donation,
        uint96 usdcDonation
    ) public {
        capitalAmount = uint96(bound(capitalAmount, 1, type(uint96).max));
        revenueAmount = uint96(bound(revenueAmount, 1, type(uint96).max));

        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _admit(fleet, address(other));
        _admit(fleet, address(usdc));
        // Three Cascade keys: level 1 completes and empties its reserve, and key 3 starts refilling
        // it for level 2, so there is both a completed cohort and a live reserve to protect.
        _buyMany(fleet, 3);

        _depositCapital(fleet, other, capitalAmount);
        _assertCovered(fleet, other);

        _depositRevenue(fleet, other, revenueAmount, bytes32(0));
        _assertCovered(fleet, other);

        if (donation > 0) {
            other.mint(address(fleet), donation);
            _assertCovered(fleet, other);
            fleet.recognizeSurplus(address(other));
            _assertCovered(fleet, other);
        }

        if (usdcDonation > 0) {
            usdc.mint(address(fleet), usdcDonation);
            _assertCovered(fleet, usdc);
            fleet.recognizeSurplus(address(usdc));
            _assertCovered(fleet, usdc);
            assertGt(fleet.cascadeReserve(), 0, "the reserve survived recognition");
        }
    }

    function _assertCovered(Keyfleet fleet, MockToken token) private view {
        assertGe(
            token.balanceOf(address(fleet)),
            fleet.accountedBalance(address(token)),
            "the fleet holds at least what it booked"
        );
    }
}

/// @dev The worst case of `depositRevenue` is a Fibonacci fleet with every level complete taking a
/// brand new asset: twenty cohort indexes move, the asset is registered in the ledger for the first
/// time, and every slot it touches is cold. The state is built in `setUp`, which runs as its own
/// transaction, and the measured call additionally cools every account it reads.
contract KeyfleetDepositsGasTest is Test {
    using stdStorage for StdStorage;

    uint64 private constant VOTING_WINDOW = 24 hours;

    StdStorage private fleetStore;

    MockToken private usdc;
    MockToken private revenueAsset;
    KeyfleetAssetRegistry private registry;
    MockStaking private staking;
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV1 private factory = IRegentsAutolaunchFactoryV1(address(0xFAC7));
    Keyfleet private fleet;

    address private safe = address(0x5AFE);
    address private treasury = address(0x7EA5);
    address private payer = address(0xDEDE);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        revenueAsset = new MockToken("Revenue", "REV");
        registry = new KeyfleetAssetRegistry(safe, address(usdc));
        staking = new MockStaking(usdc);
        fleet = new Keyfleet(
            KeyfleetPresets.Preset.FibonacciSyndicate,
            usdc,
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", "https://keys.regents.sh/alpha/")
        );

        vm.startPrank(safe);
        registry.setFactoryTokenAllowed(address(revenueAsset), true);
        registry.setFleetTokenAllowed(address(fleet), address(revenueAsset), true);
        vm.stopPrank();

        // One key in every level, bought at that level's first token id, so all twenty cohorts have
        // members. Minting all 46,365 keys would take the same cohort sizes an hour to reach.
        for (uint256 level = 1; level <= KeyfleetPresets.MAX_FIBONACCI_LEVEL; ++level) {
            uint256 start = _levelStart(level);
            fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(start - 1);
            uint256 price = fleet.nextPrice();
            usdc.mint(payer, price);
            vm.startPrank(payer);
            usdc.approve(address(fleet), price);
            uint256 tokenId = fleet.purchase(payer, address(0), price, block.timestamp);
            vm.stopPrank();
            assertEq(tokenId, start, "bought the first key of the level");
        }
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);

        revenueAsset.mint(payer, 1_000_000e18);
        vm.prank(payer);
        revenueAsset.approve(address(fleet), type(uint256).max);
    }

    function _levelStart(uint256 level) private pure returns (uint256) {
        if (level == 1) return 1;
        uint256 previous = 1;
        uint256 current = 2;
        uint256 total = 2;
        for (uint256 i = 1; i < level - 1; ++i) {
            (previous, current) = (current, previous + current);
            total += current;
        }
        return total + 1;
    }

    /// @dev Invariant: the deposit cost is bounded by the twenty-level preset and does not grow with
    /// the number of keys or holders, so revenue can always be paid in however large the fleet gets.
    function test_worstCaseRevenueDepositAtTwentyCompletedLevels() public {
        assertEq(fleet.completedLevels(), 20, "every level is complete");

        vm.cool(address(fleet));
        vm.cool(address(fleet.REWARDS()));
        vm.cool(address(revenueAsset));
        vm.cool(address(registry));

        vm.prank(payer);
        uint256 before = gasleft();
        fleet.depositRevenue(address(revenueAsset), 1_000_000e18, bytes32("svc"));
        uint256 used = before - gasleft();

        emit log_named_uint("worst-case depositRevenue gas", used);
        assertLt(used, 946_000, "worst-case deposit stays under the published ceiling");

        KeyfleetRewards rewards = fleet.REWARDS();
        uint256 net = 1_000_000e18 - (1_000_000e18 * 200) / 10_000;
        assertEq(rewards.backed(address(revenueAsset)), net, "the whole net is backed");
        assertGt(rewards.cohortIndex(address(revenueAsset), 20), 0, "the twentieth level was paid");
    }
}
