// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";

/// @dev Reports six decimals, as USDC does, because a fleet refuses a USDC with any other.
contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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

/// @dev Money that reaches the fleet contract outside a purchase, and the owed protocol share.
/// Everything sent to the fleet, USDC included, is forwarded whole to the fleet's treasury. The
/// owed protocol share, the Cascade reserve and reward backing are never surplus, and the owed
/// share is deposited into REGENT staking through the treasury.
contract KeyfleetIncomeTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private other;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    MockRegentRevenueStaking private staking;
    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);

    event ForwardedToTreasury(address indexed asset, address indexed caller, uint256 amount);
    event ProtocolShareSent(address indexed caller, uint256 amount);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        staking = new MockRegentRevenueStaking(usdc);
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
            staking,
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
    /// level 8.
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

    function _usdcOnly() private view returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = address(usdc);
    }

    function _one(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    // --- 1. everything sent to the fleet is the treasury's ----------------------

    /// @dev Invariant: money sent to the fleet contract outside a purchase goes whole to the
    /// treasury, USDC exactly as any other token, whoever sorts it and whether or not any key has
    /// been sold. None of it reaches the keys or the ledger or stays in the fleet.
    function test_everyTokenSentToTheFleetGoesToTheTreasury() public {
        for (uint256 p = 0; p < 4; ++p) {
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset(p));
            KeyfleetRewards rewards = fleet.REWARDS();
            MockToken[2] memory tokens = [usdc, other];
            for (uint256 t = 0; t < tokens.length; ++t) {
                tokens[t].mint(address(fleet), 10_000);
                vm.expectEmit(true, true, true, true, address(fleet));
                emit ForwardedToTreasury(address(tokens[t]), bob, 10_000);
                vm.prank(bob);
                assertEq(fleet.recognizeSurplus(address(tokens[t])), 10_000, "the whole balance, before any sale");
                assertEq(_capital(fleet, tokens[t]), 10_000, "all of it is in the treasury");
                assertEq(tokens[t].balanceOf(address(fleet)), 0, "none of it stays in the fleet");
                assertEq(rewards.backed(address(tokens[t])), 0, "and none of it is owed to the keys");
            }

            uint256 tokenId = _buy(fleet, alice);
            uint256 capital = _capital(fleet, usdc);
            uint256 backed = rewards.backed(address(usdc));
            _receive(fleet, usdc, 10_000);
            assertEq(_capital(fleet, usdc), capital + 10_000, "after a sale too");
            assertEq(rewards.backed(address(usdc)), backed, "the ledger is untouched");
            assertEq(rewards.accrued(address(usdc), tokenId), 0, "and the key earned nothing from it");
        }
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
    /// be sent to the treasury by anyone.
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
        assertEq(_capital(fleet, usdc), capital + 10_000, "only the transfer reached the treasury");
        assertEq(fleet.surplus(address(usdc)), 0, "nothing is left unsorted");
    }

    /// @dev Invariant: sorting cannot reclassify a recorded obligation, because reward backing sits
    /// in the ledger and is never part of the fleet's own balance. An Accelerant rebate is backing.
    function test_rewardBackingIsNeverSurplus() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 rebate = rewards.backed(address(usdc));
        assertGt(rebate, 0, "the second key rebated the first");

        assertEq(fleet.surplus(address(usdc)), 0, "the rebate left the fleet entirely");
        assertEq(fleet.recognizeSurplus(address(usdc)), 0, "so there is nothing to sort");
        assertEq(rewards.backed(address(usdc)), rebate, "the obligation is unchanged");
    }

    /// @dev Invariant: keys are paid in USDC and USDC also reaches the fleet outside purchases, yet
    /// capital, the Cascade completion reserve, the owed protocol share and reward backing stay
    /// separate figures. USDC sent to the fleet moves only capital, and the repayment a level
    /// completion makes is the only USDC that reaches the ledger.
    function test_usdcSentToTheFleetAndUsdcPurchasesKeepEveryFigureApart() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, _wallet(3));
        assertEq(_capital(fleet, usdc), 18_000_000, "level 1 released its reserve to the treasury");
        assertEq(fleet.cascadeReserve(), 10_800_000, "key 3 opened the level 2 reserve");

        _receive(fleet, usdc, 1_000e6);
        assertEq(_capital(fleet, usdc), 18_000_000 + 1_000e6, "the payment is capital");
        assertEq(rewards.backed(address(usdc)), 0, "and owes the keys nothing");
        assertEq(fleet.cascadeReserve(), 10_800_000, "the reserve is untouched");

        _buy(fleet, _wallet(4));
        _buy(fleet, _wallet(5));
        assertTrue(fleet.levelCompleted(2), "level 2 completed");
        assertEq(fleet.cascadeReserve(), 0);
        assertEq(
            _capital(fleet, usdc),
            18_000_000 + 1_000e6 + 12_400_000,
            "only what the repayment left reaches the treasury"
        );
        assertEq(rewards.backed(address(usdc)), 20_000_000, "the repayment is the ledger's only backing");
        assertEq(rewards.accrued(address(usdc), 1), 10_000_000, "key 1 earned its repayment");

        uint256 owed = 2 * 1_000_000 + 3 * 1_200_000;
        assertEq(fleet.protocolShareOwed(), owed, "the owed share is 10% of each purchase");
        assertEq(usdc.balanceOf(address(fleet)), owed, "the fleet holds only the owed share");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds only backing");

        fleet.sendProtocolShare();
        assertEq(staking.totalUsdcReceived(), owed, "staking received exactly the owed share");
        assertEq(usdc.balanceOf(address(fleet)), 0, "leaving the fleet nothing");

        vm.prank(alice);
        assertEq(rewards.claim(_one(1), _usdcOnly())[0], 10_000_000, "the repayment is claimed");
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "and the ledger still balances");
    }

    // --- 3. guards and invariants -----------------------------------------

    /// @dev Invariant: sorting and sending the protocol share both move USDC, so a USDC that calls
    /// back mid-transfer must meet the guard, whichever guarded entry point it tries.
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
            uint256 capital = token.balanceOf(address(fleet.TREASURY()));
            token.mint(address(fleet), 100_000);
            token.arm(fleet, targets[i]);

            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            fleet.recognizeSurplus(address(token));
            assertEq(fleet.surplus(address(token)), 100_000, "nothing was sorted");
            assertEq(token.balanceOf(address(fleet.TREASURY())), capital, "and nothing reached the treasury");

            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            fleet.sendProtocolShare();
            assertEq(fleet.protocolShareOwed(), owed, "and the share is still owed");
            assertEq(token.balanceOf(address(staking)), 0, "and nothing reached staking");
        }
    }

    /// @dev Invariant: whatever it is sent in whatever tokens, the fleet always holds at least what
    /// it has booked, the ledger holds exactly what it has backed, and every unit sent ends up in the
    /// treasury.
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
        assertEq(_capital(fleet, usdc), usdcCapital + usdcIn, "every USDC unit sent is in the treasury");
        assertEq(rewards.backed(address(usdc)), usdcBacked, "and none of it is backing");
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
    /// and it is deposited into REGENT staking in full, tagged as a Keyfleet protocol share from this
    /// fleet. It passes through the treasury without staying there, the treasury's approval is used
    /// up, and the fleet itself approves nothing. A second send has nothing to send.
    function test_anyoneDepositsTheWholeOwedShareIntoStaking() public {
        address stranger = address(0x5791);
        for (uint256 p = 0; p < 4; ++p) {
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset(p));
            KeyfleetTreasury fleetTreasury = fleet.TREASURY();
            _buyMany(fleet, 5);
            uint256 owed = fleet.protocolShareOwed();
            uint256 capital = _capital(fleet, usdc);
            uint256 depositedBefore = staking.totalUsdcReceived();
            assertGt(owed, 0, "the purchases left a share owed");
            assertEq(fleet.balanceOf(stranger), 0, "the caller holds no key");

            vm.recordLogs();
            vm.expectEmit(true, true, true, true, address(fleet));
            emit ProtocolShareSent(stranger, owed);
            vm.prank(stranger);
            assertEq(fleet.sendProtocolShare(), owed, "the whole owed share was sent");
            _assertTheFleetApprovedNothing(fleet);

            assertEq(staking.totalUsdcReceived(), depositedBefore + owed, "staking received exactly the owed share");
            assertEq(staking.lastSourceTag(), keccak256("keyfleet.protocol_share"), "tagged as a protocol share");
            assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(fleet)))), "from this fleet");
            assertEq(_capital(fleet, usdc), capital, "nothing stayed in the treasury");
            assertEq(usdc.allowance(address(fleetTreasury), address(staking)), 0, "the approval is used up");
            assertEq(fleet.protocolShareOwed(), 0, "nothing is owed any more");
            assertEq(usdc.balanceOf(address(fleet)), fleet.cascadeReserve(), "the fleet holds only its reserve");

            vm.prank(stranger);
            vm.expectRevert(Keyfleet.ZeroAmount.selector);
            fleet.sendProtocolShare();
        }
    }

    /// @dev Invariant: a paused staking contract stops the send and never a purchase. The whole call
    /// unwinds, so the share stays owed in the fleet and nothing waits in the treasury; purchases
    /// keep adding to it, and once staking takes deposits again one send delivers everything.
    function test_aPausedStakingLeavesTheShareOwedAndNeverStopsAPurchase() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();
        uint256 capital = _capital(fleet, usdc);
        staking.setPaused(true);

        vm.expectRevert(bytes("PAUSED"));
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "the whole share is still owed");
        assertEq(usdc.balanceOf(address(fleet)), owed, "and still held by the fleet");
        assertEq(_capital(fleet, usdc), capital, "not by the treasury");

        uint256 secondShare = fleet.nextPrice() / 10;
        _buy(fleet, bob);
        assertEq(fleet.totalMinted(), 2, "a purchase goes through while staking is paused");
        assertEq(fleet.protocolShareOwed(), owed + secondShare, "and adds its share on top");
        assertEq(usdc.balanceOf(address(fleet)), fleet.protocolShareOwed(), "the fleet holds only the owed share");

        staking.setPaused(false);
        assertEq(fleet.sendProtocolShare(), owed + secondShare, "one send delivers everything that built up");
        assertEq(staking.totalUsdcReceived(), owed + secondShare);
        assertEq(fleet.protocolShareOwed(), 0);
    }

    /// @dev Invariant: the deposit counts only if staking took exactly the owed share. A staking
    /// contract that reports less, or takes less and leaves part of the approval standing, reverts
    /// the send and leaves the share owed in the fleet.
    function test_aDepositThatIsNotExactlyTheOwedShareIsRefused() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        uint256 owed = fleet.protocolShareOwed();

        staking.setShort(0, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.StakingDepositFailed.selector, owed, owed - 1));
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "a short report leaves the share owed");

        staking.setShort(1, 0);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.StakingDepositFailed.selector, owed, owed));
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owed, "a short pull leaves the share owed");

        staking.setShort(0, 0);
        assertEq(fleet.sendProtocolShare(), owed, "an exact deposit goes through");
    }

    /// @dev Invariant: only the fleet can ask its treasury to deposit, so nobody can make the
    /// treasury spend its capital on a deposit.
    function test_onlyTheFleetAsksItsTreasuryToDeposit() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        KeyfleetTreasury fleetTreasury = fleet.TREASURY();

        vm.expectRevert(KeyfleetTreasury.OnlyFleet.selector);
        fleetTreasury.depositProtocolShare(1);
    }

    /// @dev Invariant: the owed share is accounted for, so it is never surplus. A stray transfer
    /// alone shows as surplus, and sorting it sends that transfer to the treasury and leaves the
    /// owed share exactly where it was.
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
        assertEq(_capital(fleet, usdc), capital + 10_000, "the stray transfer went to the treasury");
        assertEq(fleet.REWARDS().backed(address(usdc)), 0, "and none of it to the keys");
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
        assertEq(staking.totalUsdcReceived(), owed, "staking received exactly the owed share");
        assertEq(fleet.surplus(address(usdc)), 10_000, "the stray transfer is still surplus");
        assertEq(_capital(fleet, usdc), capital, "and the treasury is unchanged");
        assertEq(usdc.balanceOf(address(fleet)), 10_000);
    }

    /// @dev No USDC `Approval` in the recorded logs has the fleet as its owner.
    function _assertTheFleetApprovedNothing(Keyfleet fleet) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(usdc) && logs[i].topics[0] == IERC20.Approval.selector) {
                assertTrue(address(uint160(uint256(logs[i].topics[1]))) != address(fleet), "the fleet approves nothing");
            }
        }
    }
}

/// @dev The cost of sending the owed protocol share, measured after purchases across twenty
/// Fibonacci levels. The state is built with one key per level, bought at the level's first token
/// id, so the fleet owes a share without minting every key. The measured call cools every account
/// it reads.
contract KeyfleetIncomeGasTest is Test {
    using stdStorage for StdStorage;

    /// @dev The measured execution gas plus twenty percent, rounded up to the nearest thousand.
    uint256 private constant SEND_CEILING = 181_000;

    StdStorage private fleetStore;

    MockToken private usdc;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    Keyfleet private fleet;

    MockRegentRevenueStaking private staking;
    address private payer = address(0xDEDE);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        staking = new MockRegentRevenueStaking(usdc);
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FibonacciSyndicate,
            usdc,
            staking,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", "https://keys.regents.sh/alpha/"),
            _randomness(),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    /// @dev A send touches one fleet slot, moves the share to the treasury, and the treasury
    /// approves staking and deposits. It is measured with the fleet, its treasury, USDC and staking
    /// cold, against a plain ERC-20 standing in for USDC and the stand-in staking contract, so this
    /// is a regression bound; the figure against the real staking contract is measured on a fork of
    /// Base.
    function test_sendProtocolShareGas() public {
        _buyAcrossLevels(20);
        uint256 owed = fleet.protocolShareOwed();
        assertGt(owed, 0, "the purchases left a share owed");

        vm.cool(address(fleet));
        vm.cool(address(fleet.TREASURY()));
        vm.cool(address(usdc));
        vm.cool(address(staking));

        uint256 before = gasleft();
        fleet.sendProtocolShare();
        uint256 used = before - gasleft();

        emit log_named_uint("sendProtocolShare gas", used);
        assertLt(used, SEND_CEILING, "the send stays under its ceiling");
        assertEq(staking.totalUsdcReceived(), owed, "the whole owed share reached staking");
    }

    /// @dev Buys the first key of every level up to `levels`, writing the mint count to the key
    /// before each level's first.
    function _buyAcrossLevels(uint256 levels) private {
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
