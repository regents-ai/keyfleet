// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";

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
/// behaviours the protocol-share send depends on: it pulls the USDC itself with `transferFrom` and
/// it reports how much it observed arriving. `setPaused` reproduces `whenNotPaused`, `setShortfall`
/// reproduces a contract that accepts the tokens but reports less than it took, `setCreditWithoutPulling`
/// reproduces one that reports the whole amount without ever pulling it, and `setCallback` reproduces
/// one that calls back into a chosen fleet entry point while the fleet is mid-registration. Like the
/// live contract, it refuses to register an amount of zero.
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
    bytes4 private _callbackTarget;

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

    /// @dev `target` is the selector of the fleet entry point to call back into.
    function setCallback(Keyfleet fleet, bytes4 target) external {
        _callbackFleet = fleet;
        _callbackTarget = target;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received) {
        require(amount != 0, "AMOUNT_ZERO");
        if (paused) revert StakingPaused();
        if (_callbackTarget == Keyfleet.purchase.selector) {
            _callbackFleet.purchase(address(this), type(uint256).max, block.timestamp);
        } else if (_callbackTarget == Keyfleet.sendProtocolShare.selector) {
            _callbackFleet.sendProtocolShare();
        }

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

/// @dev A token that calls back into a chosen fleet entry point the first time it moves after being
/// armed, from inside the transfer the fleet is in the middle of.
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
        if (_target == Keyfleet.sendProtocolShare.selector) _fleet.sendProtocolShare();
        else _fleet.recognizeSurplus(address(this));
    }
}

/// @dev How money that reaches a fleet is sorted. USDC, REGENT and, once launched, the fleet's own
/// token are income, and all of it goes to the keys; every other token is shared money. The owed
/// protocol share, the Cascade reserve and reward backing are never surplus.
contract KeyfleetIncomeTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private regent;
    MockToken private usdc;
    MockToken private other;
    MockStaking private staking;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV2 private factory = IRegentsAutolaunchFactoryV2(address(0xFAC7));

    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    event IncomeRecognized(address indexed asset, address indexed caller, uint256 amount);
    event SharedMoneyRecognized(address indexed asset, address indexed caller, uint256 amount);
    event ProtocolShareSent(address indexed caller, uint256 amount);

    function setUp() public {
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        staking = new MockStaking(usdc);
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = _deployWith(preset, regent);
    }

    function _deployWith(KeyfleetPresets.Preset preset, IERC20 regentToken) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            regentToken,
            staking,
            factory,
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

    function _buy(Keyfleet fleet, address receiver) private returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, 2 * price, block.timestamp);
        vm.stopPrank();
    }

    /// @dev One key per wallet, because the Fibonacci holding limit is one key per level below
    /// level 8 and the identity of a holder never matters to income.
    function _buyMany(Keyfleet fleet, uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
    }

    function _wallet(uint256 index) private pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    /// @dev Sends `amount` of `token` to the fleet by plain transfer and sorts it, as anyone may.
    function _receive(Keyfleet fleet, MockToken token, uint256 amount) private returns (uint256 sorted) {
        token.mint(address(fleet), amount);
        vm.prank(bob);
        sorted = fleet.recognizeSurplus(address(token));
    }

    function _one(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    // --- 1. income goes to the keys -----------------------------------------

    /// @dev Invariant: USDC and REGENT that reach a fleet are income and go to the keys in full,
    /// equally per key on Classic. Nothing is kept as shared money and nothing is taken off the top.
    function test_usdcAndRegentIncomeGoesWhollyToTheKeys() public {
        MockToken[2] memory incomeTokens = [usdc, regent];
        for (uint256 i = 0; i < incomeTokens.length; ++i) {
            MockToken token = incomeTokens[i];
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
            KeyfleetRewards rewards = fleet.REWARDS();
            uint256 first = _buy(fleet, alice);
            uint256 second = _buy(fleet, bob);
            uint256 third = _buy(fleet, bob);
            uint256 capitalBefore = fleet.freeCapital(address(token));

            token.mint(address(fleet), 10_000);
            vm.expectEmit(true, true, true, true, address(fleet));
            emit IncomeRecognized(address(token), bob, 10_000);
            vm.prank(bob);
            assertEq(fleet.recognizeSurplus(address(token)), 10_000, "the whole receipt is sorted");

            assertEq(rewards.accrued(address(token), first), 3_333);
            assertEq(rewards.accrued(address(token), second), 3_333);
            assertEq(rewards.accrued(address(token), third), 3_333);
            assertEq(rewards.backed(address(token)), 10_000, "the whole receipt is backed, dust included");
            assertEq(token.balanceOf(address(rewards)), 10_000, "and the tokens are actually there");
            assertEq(fleet.freeCapital(address(token)), capitalBefore, "income never becomes shared money");
            assertEq(fleet.surplus(address(token)), 0, "nothing is left unsorted");
        }
    }

    /// @dev Invariant: any token that is not an income token becomes shared money in full, and
    /// nothing of it reaches the keys or the ledger.
    function test_anyOtherTokenBecomesSharedMoney() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);

        other.mint(address(fleet), 10_000);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit SharedMoneyRecognized(address(other), bob, 10_000);
        vm.prank(bob);
        assertEq(fleet.recognizeSurplus(address(other)), 10_000);

        assertEq(fleet.freeCapital(address(other)), 10_000, "all of it is shared money");
        assertEq(other.balanceOf(address(rewards)), 0, "the ledger holds none of it");
        assertFalse(rewards.isRewardAsset(address(other)), "and the ledger does not know the token");
        assertEq(fleet.surplus(address(other)), 0);
    }

    /// @dev Invariant: Fibonacci income is equal per completed level first and equal per key within
    /// a level second, so a small early level earns more per key than a large later one.
    function test_fibonacciIncomeIsEqualPerCompletedLevelThenPerKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 5);
        assertEq(fleet.completedLevels(), 2, "levels 1 and 2 are fully minted");

        _receive(fleet, regent, 10_000);

        // 10_000 splits 5_000 to level 1 across two keys and 5_000 to level 2 across three.
        assertEq(rewards.accrued(address(regent), 1), 2_500);
        assertEq(rewards.accrued(address(regent), 2), 2_500);
        assertEq(rewards.accrued(address(regent), 3), 1_666);
        assertEq(rewards.accrued(address(regent), 4), 1_666);
        assertEq(rewards.accrued(address(regent), 5), 1_666);
        assertEq(rewards.backed(address(regent)), 10_000, "the whole receipt is backed");
    }

    /// @dev Invariant: an unfinished level earns nothing, and the keys already minted into it start
    /// at the index the allocation left behind rather than picking up earlier income.
    function test_incompleteLevelEarnsNothingAndItsKeysStartAtTheCurrentIndex() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 6); // key 6 opens level 3, which has five keys.
        assertEq(fleet.completedLevels(), 2, "level 3 is still open");

        _receive(fleet, regent, 10_000);
        assertEq(rewards.accrued(address(regent), 6), 0, "the open level earned nothing");
        assertEq(rewards.cohortIndex(address(regent), 3), 0, "its index never moved");

        _buyMany(fleet, 4); // completes level 3 with keys 7 to 10.
        assertEq(fleet.completedLevels(), 3);
        assertEq(rewards.accrued(address(regent), 10), 0, "a key minted later starts from here");

        _receive(fleet, regent, 10_000);
        // 10_000 over three levels: 3_333 each, and the last level absorbs the remainder.
        assertEq(rewards.accrued(address(regent), 6), 666, "level 3 keys share only the second receipt");
        assertEq(rewards.accrued(address(regent), 10), 666, "the late key earns the same as its level mates");
        assertEq(rewards.accrued(address(regent), 1), 4_166, "level 1 keeps its first-receipt share");
    }

    /// @dev Invariant: the remainder of the equal split across levels is allocated to the last
    /// completed level, so the whole receipt is backed and nothing is stranded in the fleet.
    function test_splitRemainderGoesToTheLastCompletedLevel() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 10);
        assertEq(fleet.completedLevels(), 3);

        _receive(fleet, regent, 10_000);

        uint256 precision = rewards.PRECISION();
        // 10_000 over three levels is 3_333 each with 1 left over, which level 3 takes.
        assertEq(rewards.cohortIndex(address(regent), 1), (3_333 * precision) / 2);
        assertEq(rewards.cohortIndex(address(regent), 2), (3_333 * precision) / 3);
        assertEq(rewards.cohortIndex(address(regent), 3), (3_334 * precision) / 5);
        assertEq(rewards.backed(address(regent)), 10_000, "every unit is backed");
        assertEq(regent.balanceOf(address(fleet)), 0, "and none of it is left in the fleet");
    }

    /// @dev Invariant: income no key can receive yet is refused rather than kept as shared money,
    /// and waits in the fleet, still unsorted, until a key can receive it. That is no key at all on
    /// Classic, and no completed level on a Fibonacci preset.
    function test_incomeWaitsUntilAKeyCanReceiveIt() public {
        Keyfleet classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        usdc.mint(address(classic), 10_000);
        vm.expectRevert(Keyfleet.NoEligibleKeys.selector);
        classic.recognizeSurplus(address(usdc));
        assertEq(classic.surplus(address(usdc)), 10_000, "the receipt is still unsorted");
        assertEq(classic.freeCapital(address(usdc)), 0, "and none of it became shared money");

        uint256 tokenId = _buy(classic, alice);
        assertEq(classic.recognizeSurplus(address(usdc)), 10_000, "the first key can receive it");
        assertEq(classic.REWARDS().accrued(address(usdc), tokenId), 10_000);

        Keyfleet fibonacci = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buy(fibonacci, alice);
        assertEq(fibonacci.completedLevels(), 0, "level 1 is not complete with one of its two keys");
        regent.mint(address(fibonacci), 10_000);
        vm.expectRevert(Keyfleet.NoEligibleKeys.selector);
        fibonacci.recognizeSurplus(address(regent));

        _buy(fibonacci, bob);
        assertEq(fibonacci.recognizeSurplus(address(regent)), 10_000, "a completed level can receive it");
    }

    /// @dev Invariant: an amount too small to divide across the eligible levels is refused rather
    /// than quietly allocating zero to some of them, and waits for more.
    function test_incomeSmallerThanTheEligibleLevelCountWaitsForMore() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buyMany(fleet, 10);

        regent.mint(address(fleet), 2);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        fleet.recognizeSurplus(address(regent));

        regent.mint(address(fleet), 1);
        assertEq(fleet.recognizeSurplus(address(regent)), 3, "three units split across three levels");
    }

    /// @dev Invariant: sorting with nothing to sort is harmless. It returns zero and emits nothing,
    /// so a keeper that calls it on a schedule never fails.
    function test_nothingToSortReturnsZero() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);

        vm.recordLogs();
        assertEq(fleet.recognizeSurplus(address(usdc)), 0);
        assertEq(fleet.recognizeSurplus(address(other)), 0);
        assertEq(vm.getRecordedLogs().length, 0, "nothing sorted, nothing said");
    }

    // --- 2. what is never surplus ---------------------------------------------

    /// @dev Invariant: sorting touches only the part of the balance nothing else has a purpose for.
    /// The Cascade completion reserve is accounted for, so an incomplete level's reserve can never
    /// be handed to the keys or turned into shared money by anyone.
    function test_theCascadeReserveIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buyMany(fleet, 3); // level 1 completes, key 3 starts the level 2 reserve.
        uint256 reserve = fleet.cascadeReserve();
        uint256 capital = fleet.freeCapital(address(usdc));
        assertGt(reserve, 0, "key 3 funds the level 2 reserve");
        assertEq(fleet.surplus(address(usdc)), 0, "an accounted balance shows no surplus");

        usdc.mint(address(fleet), 10_000);
        assertEq(fleet.surplus(address(usdc)), 10_000, "a plain transfer is the whole surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 10_000);

        assertEq(fleet.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(fleet.freeCapital(address(usdc)), capital, "and so is shared money");
        assertEq(fleet.surplus(address(usdc)), 0, "nothing is left unsorted");
    }

    /// @dev Invariant: sorting cannot reclassify a recorded obligation, because reward backing sits
    /// in the ledger and is never part of the fleet's own balance.
    function test_rewardBackingIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        _receive(fleet, regent, 10_000);

        assertEq(regent.balanceOf(address(fleet)), 0, "income left the fleet entirely");
        assertEq(fleet.recognizeSurplus(address(regent)), 0, "so there is nothing to sort");
        assertEq(rewards.backed(address(regent)), 10_000, "the obligation is unchanged");
    }

    /// @dev Invariant: keys are paid in USDC and USDC is also an income token, yet shared money,
    /// the Cascade completion reserve, the owed protocol share and reward backing stay separate
    /// figures. USDC income moves only backing, and the repayment a level completion makes lands
    /// beside it in the ledger without disturbing it.
    function test_usdcIncomeAndUsdcPurchasesKeepEveryFigureApart() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, _wallet(3));
        assertEq(fleet.freeCapital(address(usdc)), 19_600_000, "level 1 released its reserve to shared money");
        assertEq(fleet.cascadeReserve(), 11_760_000, "key 3 opened the level 2 reserve");

        _receive(fleet, usdc, 1_000e6);
        assertEq(rewards.backed(address(usdc)), 1_000e6, "income moves only backing");
        assertEq(rewards.accrued(address(usdc), 1), 500e6, "shared across level 1's two keys");
        assertEq(fleet.freeCapital(address(usdc)), 19_600_000, "and leaves shared money alone");
        assertEq(fleet.cascadeReserve(), 11_760_000, "and the reserve");

        _buy(fleet, _wallet(4));
        _buy(fleet, _wallet(5));
        assertTrue(fleet.levelCompleted(2), "level 2 completed");
        assertEq(fleet.cascadeReserve(), 0);
        assertEq(
            fleet.freeCapital(address(usdc)), 19_600_000 + 15_280_000, "only what the repayment left is shared money"
        );
        assertEq(rewards.backed(address(usdc)), 1_000e6 + 20_000_000, "the repayment joins the income");
        assertEq(rewards.accrued(address(usdc), 1), 500e6 + 10_000_000, "key 1 earned income and repayment");

        uint256 owed = 2 * 200_000 + 3 * 240_000;
        assertEq(fleet.protocolShareOwed(), owed, "the owed share is 2% of each purchase");
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.freeCapital(address(usdc)) + owed,
            "the fleet holds only shared money and the owed share"
        );
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds only backing");

        fleet.sendProtocolShare();
        assertEq(staking.registered(), owed, "staking registered exactly the owed share");
        assertEq(usdc.balanceOf(address(fleet)), fleet.freeCapital(address(usdc)), "leaving the fleet shared money");

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _one(1), address(0)), 510e6, "both are paid in one claim");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "and the ledger still balances");
    }

    // --- 3. guards and invariants -----------------------------------------

    /// @dev Invariant: sorting income moves it into the ledger, so an income token that calls back
    /// mid-transfer must meet the guard, whichever guarded entry point it tries.
    function test_anIncomeTokenThatCallsBackIsRefused() public {
        bytes4[2] memory targets = [Keyfleet.recognizeSurplus.selector, Keyfleet.sendProtocolShare.selector];
        for (uint256 i = 0; i < targets.length; ++i) {
            ReenteringToken token = new ReenteringToken();
            Keyfleet fleet = _deployWith(KeyfleetPresets.Preset.FleetTechClassic, IERC20(address(token)));
            _buy(fleet, alice);
            token.mint(address(fleet), 100_000);
            token.arm(fleet, targets[i]);

            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            fleet.recognizeSurplus(address(token));

            assertEq(fleet.surplus(address(token)), 100_000, "nothing was sorted");
            assertEq(fleet.REWARDS().backed(address(token)), 0, "and nothing was backed");
        }
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
    /// which is the only thing the income split reads, and it is derived from the mint count alone.
    function test_completedLevelsTracksTheMintCountExactly() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        uint256[11] memory expected = [uint256(0), 0, 1, 1, 1, 2, 2, 2, 2, 2, 3];
        for (uint256 minted = 0; minted <= 10; ++minted) {
            assertEq(fleet.completedLevels(), expected[minted], "completed levels after this many mints");
            if (minted < 10) _buy(fleet, _wallet(minted + 1));
        }
    }

    /// @dev Invariant: whatever receipts it sees in whatever tokens, the fleet always holds at least
    /// what it has booked, the ledger holds exactly what it has backed, and every unit received is
    /// either still unsorted, shared money or backing.
    function testFuzz_balancesAlwaysCoverEveryBookedFigure(uint96 usdcIn, uint96 regentIn, uint96 otherIn) public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        // Three Cascade keys: level 1 completes and empties its reserve, and key 3 starts refilling
        // it for level 2, so there is both a completed cohort and a live reserve to protect.
        _buyMany(fleet, 3);
        uint256 reserve = fleet.cascadeReserve();
        uint256 owed = fleet.protocolShareOwed();
        uint256 usdcCapital = fleet.freeCapital(address(usdc));
        uint256 usdcBacked = rewards.backed(address(usdc));

        usdc.mint(address(fleet), usdcIn);
        regent.mint(address(fleet), regentIn);
        other.mint(address(fleet), otherIn);
        _assertCovered(fleet, usdc);
        _assertCovered(fleet, regent);
        _assertCovered(fleet, other);

        fleet.recognizeSurplus(address(usdc));
        fleet.recognizeSurplus(address(regent));
        fleet.recognizeSurplus(address(other));

        assertEq(fleet.cascadeReserve(), reserve, "the reserve survived sorting");
        assertEq(fleet.protocolShareOwed(), owed, "and so did the owed share");
        assertEq(fleet.freeCapital(address(usdc)), usdcCapital, "USDC income never becomes shared money");
        assertEq(rewards.backed(address(usdc)), usdcBacked + usdcIn, "all of it is backed");
        assertEq(rewards.backed(address(regent)), regentIn, "and so is all the REGENT");
        assertEq(fleet.freeCapital(address(other)), otherIn, "every other token is shared money");
        _assertCovered(fleet, usdc);
        _assertCovered(fleet, regent);
        _assertCovered(fleet, other);

        fleet.sendProtocolShare();
        _assertCovered(fleet, usdc);
    }

    function _assertCovered(Keyfleet fleet, MockToken token) private view {
        KeyfleetRewards rewards = fleet.REWARDS();
        assertGe(
            token.balanceOf(address(fleet)),
            fleet.accountedBalance(address(token)),
            "the fleet holds at least what it booked"
        );
        assertEq(token.balanceOf(address(rewards)), rewards.backed(address(token)), "the ledger holds its backing");
    }

    // --- 4. protocol share -------------------------------------------------

    /// @dev Invariant: on every preset, anyone at all, holding no key, may send the whole owed share,
    /// and it reaches the staking contract as registered revenue under the fleet's source tag and the
    /// protocol-share reference, with the approval fully consumed. Nothing is left owed and the fleet
    /// is left holding exactly its capital and reserve. A second send has nothing to send.
    function test_anyoneSendsTheWholeOwedShareToStaking() public {
        address stranger = address(0x5791);
        uint256 registeredBefore;
        for (uint256 p = 0; p < 4; ++p) {
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset(p));
            _buyMany(fleet, 5);
            uint256 owed = fleet.protocolShareOwed();
            assertGt(owed, 0, "the purchases left a share owed");
            assertEq(fleet.balanceOf(stranger), 0, "the caller holds no key");

            vm.expectEmit(true, true, true, true, address(fleet));
            emit ProtocolShareSent(stranger, owed);
            vm.prank(stranger);
            assertEq(fleet.sendProtocolShare(), owed, "the whole owed share was sent");

            assertEq(staking.registered(), registeredBefore + owed, "staking registered exactly the owed share");
            assertEq(staking.lastAmount(), owed, "in one registration");
            assertEq(staking.lastTag(), keccak256("keyfleet"), "under the keyfleet source tag");
            assertEq(staking.lastRef(), keccak256("keyfleet.protocol-share"), "carrying the protocol-share reference");
            assertEq(fleet.PROTOCOL_SHARE_REF(), keccak256("keyfleet.protocol-share"));
            assertEq(staking.lastPayer(), address(fleet), "paid by the fleet itself");
            assertEq(usdc.allowance(address(fleet), address(staking)), 0, "no approval is left behind");
            assertEq(fleet.protocolShareOwed(), 0, "nothing is owed any more");
            assertEq(
                usdc.balanceOf(address(fleet)),
                fleet.freeCapital(address(usdc)) + fleet.cascadeReserve(),
                "the fleet holds only capital and reserve"
            );
            registeredBefore = staking.registered();

            vm.prank(stranger);
            vm.expectRevert(Keyfleet.ZeroAmount.selector);
            fleet.sendProtocolShare();
        }
    }

    /// @dev Invariant: a paused staking contract stops the send and never a purchase. The whole
    /// share stays owed, purchases keep adding to it, and once staking reopens one send registers
    /// everything that built up.
    function test_pausedStakingStopsTheSendButNeverAPurchase() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();
        staking.setPaused(true);

        vm.expectRevert(MockStaking.StakingPaused.selector);
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "the whole share is still owed");
        assertEq(usdc.allowance(address(fleet), address(staking)), 0, "no approval survives the revert");

        _buy(fleet, bob);
        assertEq(fleet.totalMinted(), 2, "a purchase goes through while staking is paused");
        assertEq(fleet.protocolShareOwed(), 2 * owed, "and adds its share on top");
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.freeCapital(address(usdc)) + fleet.protocolShareOwed(),
            "the fleet holds capital and the owed share"
        );

        staking.setPaused(false);
        assertEq(fleet.sendProtocolShare(), 2 * owed, "one send registers everything that built up");
        assertEq(staking.registered(), 2 * owed);
        assertEq(fleet.protocolShareOwed(), 0);
    }

    /// @dev Invariant: the send believes the staking contract only when it reports receiving the
    /// whole owed share and has spent its approval, so one that under-reports or credits without
    /// pulling is refused, the share stays owed, and a later purchase still accrues on top.
    function test_stakingThatMisreportsTheShareIsRefusedAndTheShareStaysOwed() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();

        staking.setShortfall(1);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.StakingRegistrationFailed.selector, owed, owed - 1));
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "an under-report leaves the share owed");
        staking.setShortfall(0);

        staking.setCreditWithoutPulling(true);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.StakingRegistrationFailed.selector, owed, owed));
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "a credit without a pull leaves the share owed");
        assertEq(usdc.allowance(address(fleet), address(staking)), 0, "and no approval behind");

        _buy(fleet, bob);
        assertEq(fleet.protocolShareOwed(), 2 * owed, "a later purchase accrues on top");
        assertEq(staking.registered(), 0, "nothing was ever registered");
        assertEq(usdc.balanceOf(address(staking)), 0, "and nothing was ever taken");
    }

    /// @dev Invariant: the send calls the staking contract, so the guard has to hold against it. A
    /// staking contract that called back into a purchase or into a second send could otherwise act
    /// on a fleet whose owed share it had not finished taking.
    function test_reentryFromTheStakingContractDuringASendIsRejected() public {
        bytes4[2] memory targets = [Keyfleet.purchase.selector, Keyfleet.sendProtocolShare.selector];
        for (uint256 i = 0; i < targets.length; ++i) {
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
            _buy(fleet, alice);
            uint256 owed = fleet.protocolShareOwed();
            staking.setCallback(fleet, targets[i]);

            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            fleet.sendProtocolShare();

            assertEq(fleet.protocolShareOwed(), owed, "the share is still owed");
            assertEq(fleet.totalMinted(), 1, "no key was bought from inside the send");
        }
        assertEq(staking.registered(), 0, "nothing was registered");
    }

    /// @dev Invariant: the owed share is accounted for, so it is never surplus. A stray transfer
    /// alone shows as surplus, and sorting it pays that transfer to the keys and leaves the owed
    /// share exactly where it was.
    function test_theOwedShareIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 owed = fleet.protocolShareOwed();
        uint256 capital = fleet.freeCapital(address(usdc));

        assertEq(fleet.accountedBalance(address(usdc)), capital + owed, "the owed share is accounted for");
        assertEq(fleet.surplus(address(usdc)), 0, "so purchases leave no surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 0);

        usdc.mint(address(fleet), 10_000);
        assertEq(fleet.surplus(address(usdc)), 10_000, "only the stray transfer is surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 10_000);
        assertEq(fleet.protocolShareOwed(), owed, "sorting left the owed share untouched");
        assertEq(fleet.freeCapital(address(usdc)), capital, "and shared money");
        assertEq(fleet.REWARDS().backed(address(usdc)), 10_000, "the stray transfer went to the keys");
        assertEq(fleet.surplus(address(usdc)), 0);
    }

    /// @dev Invariant: a send takes exactly the owed share and nothing else the fleet holds. USDC
    /// that arrived by a plain transfer and has not been recognized stays behind as surplus.
    function test_aSendTakesOnlyTheOwedShareAndLeavesStraysAsSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();
        uint256 capital = fleet.freeCapital(address(usdc));
        usdc.mint(address(fleet), 10_000);

        assertEq(fleet.sendProtocolShare(), owed, "the send reports the owed share");
        assertEq(staking.registered(), owed, "staking registered exactly the owed share");
        assertEq(usdc.balanceOf(address(staking)), owed, "and took exactly that");
        assertEq(fleet.surplus(address(usdc)), 10_000, "the stray transfer is still surplus");
        assertEq(fleet.freeCapital(address(usdc)), capital, "and shared money is unchanged");
        assertEq(usdc.balanceOf(address(fleet)), capital + 10_000);
    }
}

/// @dev The worst case of sorting income is a Fibonacci fleet with every level complete: twenty
/// cohort indexes move and every slot it touches is cold. The state is built in `setUp`, which runs
/// as its own transaction, and the measured call additionally cools every account it reads.
contract KeyfleetIncomeGasTest is Test {
    using stdStorage for StdStorage;

    /// @dev Each ceiling is the measured execution gas plus twenty percent, rounded up to the
    /// nearest thousand.
    uint256 private constant SEND_CEILING = 262_000;
    uint256 private constant SORT_CEILING = 813_000;

    StdStorage private fleetStore;

    MockToken private usdc;
    MockToken private regent;
    MockStaking private staking;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    /// @dev These suites never launch; the Autolaunch factory is exercised in its own suite.
    IRegentsAutolaunchFactoryV2 private factory = IRegentsAutolaunchFactoryV2(address(0xFAC7));
    Keyfleet private fleet;

    address private payer = address(0xDEDE);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        regent = new MockToken("Regent", "REGENT");
        staking = new MockStaking(usdc);
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        fleet = new Keyfleet(
            KeyfleetPresets.Preset.FibonacciSyndicate,
            usdc,
            regent,
            staking,
            factory,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", "https://keys.regents.sh/alpha/"),
            _randomness(),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));

        // One key in every level, bought at that level's first token id, so all twenty cohorts have
        // members. Minting all 46,365 keys would take the same cohort sizes an hour to reach.
        for (uint256 level = 1; level <= KeyfleetPresets.MAX_FIBONACCI_LEVEL; ++level) {
            uint256 start = _levelStart(level);
            fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(start - 1);
            uint256 price = fleet.nextPrice();
            usdc.mint(payer, price);
            vm.startPrank(payer);
            usdc.approve(address(fleet), price);
            uint256 tokenId = fleet.purchase(payer, price, block.timestamp);
            vm.stopPrank();
            assertEq(tokenId, start, "bought the first key of the level");
        }
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID);

        regent.mint(address(fleet), 1_000_000e18);
    }

    /// @dev A send touches one fleet slot and one registration. It is measured with the fleet, USDC
    /// and the staking stand-in all cold, against the mock staking contract, whose own bookkeeping
    /// is most of the figure, so this is a regression bound; the figure to publish is measured on
    /// a fork of Base.
    function test_sendProtocolShareGas() public {
        uint256 owed = fleet.protocolShareOwed();
        assertGt(owed, 0, "the twenty purchases left a share owed");

        vm.cool(address(fleet));
        vm.cool(address(usdc));
        vm.cool(address(staking));

        uint256 before = gasleft();
        fleet.sendProtocolShare();
        uint256 used = before - gasleft();

        emit log_named_uint("sendProtocolShare gas", used);
        assertLt(used, SEND_CEILING, "the send stays under its ceiling");
        assertEq(staking.registered(), owed, "the whole owed share was registered");
    }

    /// @dev A fleet's randomness: the mock coordinator and the suite's subscription.
    function _randomness() private view returns (Keyfleet.Randomness memory) {
        return Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)),
            subscriptionId: vrfSubscription,
            keyHash: keccak256("key hash")
        });
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

    /// @dev Invariant: the cost of sorting income is bounded by the twenty-level preset and does not
    /// grow with the number of keys or holders, so income can always reach the keys however large
    /// the fleet gets.
    function test_worstCaseIncomeAtTwentyCompletedLevels() public {
        assertEq(fleet.completedLevels(), 20, "every level is complete");

        vm.cool(address(fleet));
        vm.cool(address(fleet.REWARDS()));
        vm.cool(address(regent));

        uint256 before = gasleft();
        fleet.recognizeSurplus(address(regent));
        uint256 used = before - gasleft();

        emit log_named_uint("worst-case recognizeSurplus gas", used);
        assertLt(used, SORT_CEILING, "worst-case sorting stays under the published ceiling");

        KeyfleetRewards rewards = fleet.REWARDS();
        assertEq(rewards.backed(address(regent)), 1_000_000e18, "the whole receipt is backed");
        assertGt(rewards.cohortIndex(address(regent), 20), 0, "the twentieth level was paid");
    }
}
