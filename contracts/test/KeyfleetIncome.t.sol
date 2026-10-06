// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";

/// @dev Reports six decimals, as USDC does, because a fleet refuses a USDC with any other.
/// `setBlocked` reproduces USDC's blacklist: every transfer to the blocked address reverts.
contract MockToken is ERC20 {
    error Blocked(address account);

    address public blocked;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account) external {
        blocked = account;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && to == blocked) revert Blocked(to);
        super._update(from, to, value);
    }
}

/// @dev A six-decimal token that calls back into a chosen fleet entry point the first time it moves
/// after being armed, from inside the transfer the fleet is in the middle of.
contract ReenteringToken is ERC20 {
    Keyfleet private _fleet;
    bytes4 private _target;
    bool private _entered;

    constructor() ERC20("Reenter", "RE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

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

/// @dev How money that reaches a fleet is sorted. USDC is income, and all of it goes to the keys;
/// every other token is forwarded to the fleet's treasury. The owed protocol share, the Cascade reserve and reward
/// backing are never surplus.
contract KeyfleetIncomeTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private other;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    address private treasury = address(0x7EA5);
    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    event IncomeRecognized(address indexed asset, address indexed caller, uint256 amount);
    event ForwardedToTreasury(address indexed asset, address indexed caller, uint256 amount);
    event ProtocolShareSent(address indexed caller, uint256 amount);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = _deployWith(preset, usdc);
    }

    function _deployWith(KeyfleetPresets.Preset preset, IERC20 usdcToken) private returns (Keyfleet fleet) {
        fleet = KeyfleetStack.deploy(
            preset,
            usdcToken,
            treasury,
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

    /// @dev A token's capital: what the fleet's treasury holds of it.
    function _capital(Keyfleet fleet, MockToken token) private view returns (uint256) {
        return token.balanceOf(address(fleet.TREASURY()));
    }

    function _one(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    // --- 1. income goes to the keys -----------------------------------------

    /// @dev Invariant: USDC that reaches a fleet is income and goes to the keys in full, equally per
    /// key on Classic. Nothing goes to the treasury and nothing is taken off the top.
    function test_usdcIncomeGoesWhollyToTheKeys() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        uint256 first = _buy(fleet, alice);
        uint256 second = _buy(fleet, bob);
        uint256 third = _buy(fleet, bob);
        uint256 capitalBefore = _capital(fleet, usdc);

        usdc.mint(address(fleet), 10_000);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit IncomeRecognized(address(usdc), bob, 10_000);
        vm.prank(bob);
        assertEq(fleet.recognizeSurplus(address(usdc)), 10_000, "the whole receipt is sorted");

        assertEq(rewards.accrued(address(usdc), first), 3_333);
        assertEq(rewards.accrued(address(usdc), second), 3_333);
        assertEq(rewards.accrued(address(usdc), third), 3_333);
        assertEq(rewards.backed(address(usdc)), 10_000, "the whole receipt is backed, dust included");
        assertEq(usdc.balanceOf(address(rewards)), 10_000, "and the tokens are actually there");
        assertEq(_capital(fleet, usdc), capitalBefore, "income never reaches the treasury");
        assertEq(fleet.surplus(address(usdc)), 0, "nothing is left unsorted");
    }

    /// @dev Invariant: any token other than USDC is forwarded to the treasury in full, and nothing
    /// of it reaches the keys or the ledger or stays in the fleet.
    function test_anyOtherTokenIsForwardedToTheTreasury() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);

        other.mint(address(fleet), 10_000);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit ForwardedToTreasury(address(other), bob, 10_000);
        vm.prank(bob);
        assertEq(fleet.recognizeSurplus(address(other)), 10_000);

        assertEq(_capital(fleet, other), 10_000, "all of it is in the treasury");
        assertEq(other.balanceOf(address(fleet)), 0, "none of it stays in the fleet");
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

        _receive(fleet, usdc, 10_000);

        // 10_000 splits 5_000 to level 1 across two keys and 5_000 to level 2 across three.
        assertEq(rewards.accrued(address(usdc), 1), 2_500);
        assertEq(rewards.accrued(address(usdc), 2), 2_500);
        assertEq(rewards.accrued(address(usdc), 3), 1_666);
        assertEq(rewards.accrued(address(usdc), 4), 1_666);
        assertEq(rewards.accrued(address(usdc), 5), 1_666);
        assertEq(rewards.backed(address(usdc)), 10_000, "the whole receipt is backed");
    }

    /// @dev Invariant: an unfinished level earns nothing, and the keys already minted into it start
    /// at the index the allocation left behind rather than picking up earlier income.
    function test_incompleteLevelEarnsNothingAndItsKeysStartAtTheCurrentIndex() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 6); // key 6 opens level 3, which has five keys.
        assertEq(fleet.completedLevels(), 2, "level 3 is still open");

        _receive(fleet, usdc, 10_000);
        assertEq(rewards.accrued(address(usdc), 6), 0, "the open level earned nothing");
        assertEq(rewards.cohortIndex(address(usdc), 3), 0, "its index never moved");

        _buyMany(fleet, 4); // completes level 3 with keys 7 to 10.
        assertEq(fleet.completedLevels(), 3);
        assertEq(rewards.accrued(address(usdc), 10), 0, "a key minted later starts from here");

        _receive(fleet, usdc, 10_000);
        // 10_000 over three levels: 3_333 each, and the last level absorbs the remainder.
        assertEq(rewards.accrued(address(usdc), 6), 666, "level 3 keys share only the second receipt");
        assertEq(rewards.accrued(address(usdc), 10), 666, "the late key earns the same as its level mates");
        assertEq(rewards.accrued(address(usdc), 1), 4_166, "level 1 keeps its first-receipt share");
    }

    /// @dev Invariant: the remainder of the equal split across levels is allocated to the last
    /// completed level, so the whole receipt is backed and nothing is stranded in the fleet.
    function test_splitRemainderGoesToTheLastCompletedLevel() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 10);
        assertEq(fleet.completedLevels(), 3);
        uint256 held = usdc.balanceOf(address(fleet));

        _receive(fleet, usdc, 10_000);

        uint256 precision = rewards.PRECISION();
        // 10_000 over three levels is 3_333 each with 1 left over, which level 3 takes.
        assertEq(rewards.cohortIndex(address(usdc), 1), (3_333 * precision) / 2);
        assertEq(rewards.cohortIndex(address(usdc), 2), (3_333 * precision) / 3);
        assertEq(rewards.cohortIndex(address(usdc), 3), (3_334 * precision) / 5);
        assertEq(rewards.backed(address(usdc)), 10_000, "every unit is backed");
        assertEq(usdc.balanceOf(address(fleet)), held, "and none of it is left in the fleet");
    }

    /// @dev Invariant: income no key can receive yet is refused rather than sent to the treasury,
    /// and waits in the fleet, still unsorted, until a key can receive it. That is no key at all on
    /// Classic, and no completed level on a Fibonacci preset.
    function test_incomeWaitsUntilAKeyCanReceiveIt() public {
        Keyfleet classic = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        usdc.mint(address(classic), 10_000);
        vm.expectRevert(Keyfleet.NoEligibleKeys.selector);
        classic.recognizeSurplus(address(usdc));
        assertEq(classic.surplus(address(usdc)), 10_000, "the receipt is still unsorted");
        assertEq(_capital(classic, usdc), 0, "and none of it reached the treasury");

        uint256 tokenId = _buy(classic, alice);
        assertEq(classic.recognizeSurplus(address(usdc)), 10_000, "the first key can receive it");
        assertEq(classic.REWARDS().accrued(address(usdc), tokenId), 10_000);

        Keyfleet fibonacci = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buy(fibonacci, alice);
        assertEq(fibonacci.completedLevels(), 0, "level 1 is not complete with one of its two keys");
        usdc.mint(address(fibonacci), 10_000);
        vm.expectRevert(Keyfleet.NoEligibleKeys.selector);
        fibonacci.recognizeSurplus(address(usdc));

        _buy(fibonacci, bob);
        assertEq(fibonacci.recognizeSurplus(address(usdc)), 10_000, "a completed level can receive it");
    }

    /// @dev Invariant: an amount too small to divide across the eligible levels is refused rather
    /// than quietly allocating zero to some of them, and waits for more.
    function test_incomeSmallerThanTheEligibleLevelCountWaitsForMore() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buyMany(fleet, 10);

        usdc.mint(address(fleet), 2);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        fleet.recognizeSurplus(address(usdc));

        usdc.mint(address(fleet), 1);
        assertEq(fleet.recognizeSurplus(address(usdc)), 3, "three units split across three levels");
    }

    /// @dev Invariant: sorting with nothing to sort is harmless. It returns zero and emits nothing,
    /// so anyone who calls it on a schedule never fails.
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
    /// be handed to the keys or sent to the treasury by anyone.
    function test_theCascadeReserveIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buyMany(fleet, 3); // level 1 completes, key 3 starts the level 2 reserve.
        uint256 reserve = fleet.cascadeReserve();
        uint256 capital = _capital(fleet, usdc);
        assertGt(reserve, 0, "key 3 funds the level 2 reserve");
        assertEq(fleet.surplus(address(usdc)), 0, "an accounted balance shows no surplus");

        usdc.mint(address(fleet), 10_000);
        assertEq(fleet.surplus(address(usdc)), 10_000, "a plain transfer is the whole surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 10_000);

        assertEq(fleet.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(_capital(fleet, usdc), capital, "and so is the treasury");
        assertEq(fleet.surplus(address(usdc)), 0, "nothing is left unsorted");
    }

    /// @dev Invariant: sorting cannot reclassify a recorded obligation, because reward backing sits
    /// in the ledger and is never part of the fleet's own balance.
    function test_rewardBackingIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        _receive(fleet, usdc, 10_000);

        assertEq(fleet.surplus(address(usdc)), 0, "income left the fleet entirely");
        assertEq(fleet.recognizeSurplus(address(usdc)), 0, "so there is nothing to sort");
        assertEq(rewards.backed(address(usdc)), 10_000, "the obligation is unchanged");
    }

    /// @dev Invariant: keys are paid in USDC and USDC is also the income token, yet capital,
    /// the Cascade completion reserve, the owed protocol share and reward backing stay separate
    /// figures. USDC income moves only backing, and the repayment a level completion makes lands
    /// beside it in the ledger without disturbing it.
    function test_usdcIncomeAndUsdcPurchasesKeepEveryFigureApart() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, _wallet(3));
        assertEq(_capital(fleet, usdc), 18_000_000, "level 1 released its reserve to the treasury");
        assertEq(fleet.cascadeReserve(), 10_800_000, "key 3 opened the level 2 reserve");

        _receive(fleet, usdc, 1_000e6);
        assertEq(rewards.backed(address(usdc)), 1_000e6, "income moves only backing");
        assertEq(rewards.accrued(address(usdc), 1), 500e6, "shared across level 1's two keys");
        assertEq(_capital(fleet, usdc), 18_000_000, "and leaves the treasury alone");
        assertEq(fleet.cascadeReserve(), 10_800_000, "and the reserve");

        _buy(fleet, _wallet(4));
        _buy(fleet, _wallet(5));
        assertTrue(fleet.levelCompleted(2), "level 2 completed");
        assertEq(fleet.cascadeReserve(), 0);
        assertEq(_capital(fleet, usdc), 18_000_000 + 12_400_000, "only what the repayment left reaches the treasury");
        assertEq(rewards.backed(address(usdc)), 1_000e6 + 20_000_000, "the repayment joins the income");
        assertEq(rewards.accrued(address(usdc), 1), 500e6 + 10_000_000, "key 1 earned income and repayment");

        uint256 owed = 2 * 1_000_000 + 3 * 1_200_000;
        assertEq(fleet.protocolShareOwed(), owed, "the owed share is 10% of each purchase");
        assertEq(usdc.balanceOf(address(fleet)), owed, "the fleet holds only the owed share");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds only backing");

        fleet.sendProtocolShare();
        assertEq(usdc.balanceOf(treasury), owed, "the treasury received exactly the owed share");
        assertEq(usdc.balanceOf(address(fleet)), 0, "leaving the fleet nothing");

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _one(1), address(0)), 510e6, "both are paid in one claim");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "and the ledger still balances");
    }

    // --- 3. guards and invariants -----------------------------------------

    /// @dev Invariant: sorting income and sending the protocol share both move USDC, so a USDC that
    /// calls back mid-transfer must meet the guard, whichever guarded entry point it tries.
    function test_aUsdcThatCallsBackIsRefused() public {
        bytes4[2] memory targets = [Keyfleet.recognizeSurplus.selector, Keyfleet.sendProtocolShare.selector];
        for (uint256 i = 0; i < targets.length; ++i) {
            ReenteringToken token = new ReenteringToken();
            Keyfleet fleet = _deployWith(KeyfleetPresets.Preset.FleetTechClassic, IERC20(address(token)));
            uint256 price = fleet.nextPrice();
            token.mint(buyer, price);
            vm.startPrank(buyer);
            token.approve(address(fleet), price);
            fleet.purchase(alice, price, block.timestamp);
            vm.stopPrank();
            uint256 owed = fleet.protocolShareOwed();
            token.mint(address(fleet), 100_000);
            token.arm(fleet, targets[i]);

            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            fleet.recognizeSurplus(address(token));
            assertEq(fleet.surplus(address(token)), 100_000, "nothing was sorted");
            assertEq(fleet.REWARDS().backed(address(token)), 0, "and nothing was backed");

            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            fleet.sendProtocolShare();
            assertEq(fleet.protocolShareOwed(), owed, "and the share is still owed");
            assertEq(token.balanceOf(treasury), 0, "and nothing reached the treasury");
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
    /// either still unsorted, in the treasury or backing.
    function testFuzz_balancesAlwaysCoverEveryBookedFigure(uint96 usdcIn, uint96 otherIn) public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        // Three Cascade keys: level 1 completes and empties its reserve, and key 3 starts refilling
        // it for level 2, so there is both a completed cohort and a live reserve to protect.
        _buyMany(fleet, 3);
        uint256 reserve = fleet.cascadeReserve();
        uint256 owed = fleet.protocolShareOwed();
        uint256 usdcCapital = _capital(fleet, usdc);
        uint256 usdcBacked = rewards.backed(address(usdc));

        usdc.mint(address(fleet), usdcIn);
        other.mint(address(fleet), otherIn);
        _assertCovered(fleet, usdc);
        _assertCovered(fleet, other);

        fleet.recognizeSurplus(address(usdc));
        fleet.recognizeSurplus(address(other));

        assertEq(fleet.cascadeReserve(), reserve, "the reserve survived sorting");
        assertEq(fleet.protocolShareOwed(), owed, "and so did the owed share");
        assertEq(_capital(fleet, usdc), usdcCapital, "USDC income never reaches the treasury");
        assertEq(rewards.backed(address(usdc)), usdcBacked + usdcIn, "all of it is backed");
        assertEq(_capital(fleet, other), otherIn, "every other token is in the treasury");
        _assertCovered(fleet, usdc);
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
    /// and it reaches the protocol treasury in full. Nothing is left owed and the fleet is left
    /// holding exactly its reserve. A second send has nothing to send.
    function test_anyoneSendsTheWholeOwedShareToTheTreasury() public {
        address stranger = address(0x5791);
        uint256 receivedBefore;
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

            assertEq(usdc.balanceOf(treasury), receivedBefore + owed, "the treasury received exactly the owed share");
            assertEq(fleet.protocolShareOwed(), 0, "nothing is owed any more");
            assertEq(usdc.balanceOf(address(fleet)), fleet.cascadeReserve(), "the fleet holds only its reserve");
            receivedBefore = usdc.balanceOf(treasury);

            vm.prank(stranger);
            vm.expectRevert(Keyfleet.ZeroAmount.selector);
            fleet.sendProtocolShare();
        }
    }

    /// @dev Invariant: a USDC that refuses to pay the treasury stops the send and never a purchase.
    /// The whole share stays owed, purchases keep adding to it, and once the transfer goes through
    /// one send delivers everything that built up.
    function test_aRefusedSendLeavesTheShareOwedAndNeverStopsAPurchase() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();
        usdc.setBlocked(treasury);

        vm.expectRevert(abi.encodeWithSelector(MockToken.Blocked.selector, treasury));
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "the whole share is still owed");

        uint256 secondShare = fleet.nextPrice() / 10;
        _buy(fleet, bob);
        assertEq(fleet.totalMinted(), 2, "a purchase goes through while the send is refused");
        assertEq(fleet.protocolShareOwed(), owed + secondShare, "and adds its share on top");
        assertEq(usdc.balanceOf(address(fleet)), fleet.protocolShareOwed(), "the fleet holds only the owed share");

        usdc.setBlocked(address(0));
        assertEq(fleet.sendProtocolShare(), owed + secondShare, "one send delivers everything that built up");
        assertEq(usdc.balanceOf(treasury), owed + secondShare);
        assertEq(fleet.protocolShareOwed(), 0);
    }

    /// @dev Invariant: the owed share is accounted for, so it is never surplus. A stray transfer
    /// alone shows as surplus, and sorting it pays that transfer to the keys and leaves the owed
    /// share exactly where it was.
    function test_theOwedShareIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 owed = fleet.protocolShareOwed();
        uint256 capital = _capital(fleet, usdc);

        assertEq(fleet.accountedBalance(address(usdc)), owed, "the owed share is accounted for");
        assertEq(fleet.surplus(address(usdc)), 0, "so purchases leave no surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 0);

        usdc.mint(address(fleet), 10_000);
        assertEq(fleet.surplus(address(usdc)), 10_000, "only the stray transfer is surplus");
        assertEq(fleet.recognizeSurplus(address(usdc)), 10_000);
        assertEq(fleet.protocolShareOwed(), owed, "sorting left the owed share untouched");
        assertEq(_capital(fleet, usdc), capital, "and the treasury");
        assertEq(fleet.REWARDS().backed(address(usdc)), 10_000, "the stray transfer went to the keys");
        assertEq(fleet.surplus(address(usdc)), 0);
    }

    /// @dev Invariant: a send takes exactly the owed share and nothing else the fleet holds. USDC
    /// that arrived by a plain transfer and has not been recognized stays behind as surplus.
    function test_aSendTakesOnlyTheOwedShareAndLeavesStraysAsSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();
        uint256 capital = _capital(fleet, usdc);
        usdc.mint(address(fleet), 10_000);

        assertEq(fleet.sendProtocolShare(), owed, "the send reports the owed share");
        assertEq(usdc.balanceOf(treasury), owed, "the treasury received exactly the owed share");
        assertEq(fleet.surplus(address(usdc)), 10_000, "the stray transfer is still surplus");
        assertEq(_capital(fleet, usdc), capital, "and the treasury is unchanged");
        assertEq(usdc.balanceOf(address(fleet)), 10_000);
    }
}

/// @dev The cost of sorting income grows by one ledger write per completed Fibonacci level, and
/// never with the number of keys or holders. It is measured here at twenty, thirty and forty
/// completed levels, the last of which takes 701 million keys sold. Each state is built with one
/// key per level, bought at the level's first token id, and the mint count is then written straight
/// to the level's end, so the cohorts have members without minting every key. The measured call
/// cools every account it reads.
contract KeyfleetIncomeGasTest is Test {
    using stdStorage for StdStorage;

    /// @dev Each ceiling is the measured execution gas plus twenty percent, rounded up to the
    /// nearest thousand.
    uint256 private constant SEND_CEILING = 48_000;
    uint256 private constant SORT_20_CEILING = 804_000;
    uint256 private constant SORT_30_CEILING = 1_164_000;
    uint256 private constant SORT_40_CEILING = 1_523_000;

    StdStorage private fleetStore;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    Keyfleet private fleet;

    address private treasury = address(0x7EA5);
    address private payer = address(0xDEDE);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FibonacciSyndicate,
            usdc,
            treasury,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", "https://keys.regents.sh/alpha/"),
            _randomness(),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    /// @dev A send touches one fleet slot and one USDC transfer. It is measured with the fleet and
    /// USDC cold, against a plain ERC-20 standing in for USDC, so this is a regression bound; the
    /// figure to publish is measured on a fork of Base.
    function test_sendProtocolShareGas() public {
        _completeLevels(20);
        uint256 owed = fleet.protocolShareOwed();
        assertGt(owed, 0, "the purchases left a share owed");

        vm.cool(address(fleet));
        vm.cool(address(usdc));

        uint256 before = gasleft();
        fleet.sendProtocolShare();
        uint256 used = before - gasleft();

        emit log_named_uint("sendProtocolShare gas", used);
        assertLt(used, SEND_CEILING, "the send stays under its ceiling");
        assertEq(usdc.balanceOf(treasury), owed, "the whole owed share reached the treasury");
    }

    /// @dev Invariant: with twenty levels complete, sorting income pays all twenty.
    function test_incomeAtTwentyCompletedLevels() public {
        _measureSort(20, SORT_20_CEILING);
    }

    /// @dev Invariant: with thirty levels complete, sorting income pays all thirty.
    function test_incomeAtThirtyCompletedLevels() public {
        _measureSort(30, SORT_30_CEILING);
    }

    /// @dev Invariant: with forty levels complete, sorting income pays all forty, well inside one
    /// block.
    function test_incomeAtFortyCompletedLevels() public {
        _measureSort(40, SORT_40_CEILING);
    }

    function _measureSort(uint256 levels, uint256 ceiling) private {
        _completeLevels(levels);
        assertEq(fleet.completedLevels(), levels, "every level is complete");
        usdc.mint(address(fleet), 1_000_000e6);
        KeyfleetRewards rewards = fleet.REWARDS();
        uint256 backedBefore = rewards.backed(address(usdc));

        vm.cool(address(fleet));
        vm.cool(address(rewards));
        vm.cool(address(usdc));

        uint256 before = gasleft();
        fleet.recognizeSurplus(address(usdc));
        uint256 used = before - gasleft();

        emit log_named_uint(string.concat("recognizeSurplus gas at ", vm.toString(levels), " levels"), used);
        assertLt(used, ceiling, "sorting stays under its ceiling");
        assertEq(rewards.backed(address(usdc)), backedBefore + 1_000_000e6, "the whole receipt is backed");
        assertGt(rewards.cohortIndex(address(usdc), levels), 0, "the last level was paid");
    }

    /// @dev Buys the first key of every level up to `levels`, then writes the mint count to the
    /// last token id of that level.
    function _completeLevels(uint256 levels) private {
        for (uint256 level = 1; level <= levels; ++level) {
            uint256 start = KeyfleetPresets.fibonacciLevelStart(level);
            fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(start - 1);
            uint256 price = fleet.nextPrice();
            usdc.mint(payer, price);
            vm.startPrank(payer);
            usdc.approve(address(fleet), price);
            uint256 tokenId = fleet.purchase(payer, price, block.timestamp);
            vm.stopPrank();
            assertEq(tokenId, start, "bought the first key of the level");
        }
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(KeyfleetPresets.fibonacciLevelEnd(levels));
    }

    /// @dev A fleet's randomness: the mock coordinator and the suite's subscription.
    function _randomness() private view returns (Keyfleet.Randomness memory) {
        return Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)),
            subscriptionId: vrfSubscription,
            keyHash: keccak256("key hash")
        });
    }
}
