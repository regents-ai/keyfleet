// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetStack} from "../script/KeyfleetStack.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";
import {MockRegentRevenueStaking} from "./mocks/MockRegentRevenueStaking.sol";
import {MockRegent} from "./mocks/MockRegent.sol";
import {MockAutolaunchFactory} from "./mocks/MockAutolaunchFactory.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev The fleet's free capital lives in its treasury and nowhere else: the capital part of every
/// purchase, a completed Cascade level's released surplus and every token other than USDC are
/// sent there in the call that books them. The core keeps only the Cascade reserve and the owed
/// protocol share, and the ledger only its backing.
contract KeyfleetTreasuryTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private other;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    address private buyer = address(0xB0B0B0);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
    }

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = KeyfleetStack.deploy(
            preset,
            usdc,
            new MockRegentRevenueStaking(usdc),
            new MockRegent(),
            new MockAutolaunchFactory(),
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    function _buy(Keyfleet fleet, address receiver) private returns (uint256 gross) {
        gross = fleet.nextPrice();
        usdc.mint(buyer, gross);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), gross);
        fleet.purchase(receiver, gross, block.timestamp);
        vm.stopPrank();
    }

    /// @dev The core holds exactly its reserve and owed share, the ledger exactly its backing.
    function _assertNoFreeCapitalOutsideTheTreasury(Keyfleet fleet) private view {
        KeyfleetRewards rewards = fleet.REWARDS();
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.cascadeReserve() + fleet.protocolShareOwed() + fleet.surplus(address(usdc)),
            "the core holds its reserve, its owed share and anything not yet sorted"
        );
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds its backing");
    }

    /// @dev Invariant: the treasury is bound to its fleet and its ledger, holds the fleet's USDC,
    /// and names the staking contract the protocol share goes to and REGENT, neither ever zero. Its
    /// split thresholds are 100 whole units of each token.
    function test_theTreasuryIsTheFleetsOwn() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetTreasury treasury = fleet.TREASURY();

        assertEq(address(treasury.FLEET()), address(fleet), "bound to the fleet");
        assertGt(address(treasury).code.length, 0, "and deployed at the address the fleet names");
        assertEq(address(treasury.USDC()), address(usdc), "the fleet's USDC");
        assertGt(address(treasury.REGENT_STAKING()).code.length, 0, "a staking contract");
        assertEq(treasury.PROTOCOL_SHARE_TAG(), keccak256("keyfleet.protocol_share"), "the protocol share tag");

        assertEq(address(treasury.REWARDS()), address(fleet.REWARDS()), "the fleet's ledger");
        assertEq(treasury.USDC_THRESHOLD(), 100e6, "100 USDC by its six decimals");
        assertEq(treasury.REGENT_THRESHOLD(), 100e18, "100 REGENT by its eighteen decimals");
        assertGt(address(treasury.AUTOLAUNCH()).code.length, 0, "a launch factory");

        MockRegent regent = new MockRegent();
        IRegentRevenueStaking staking = IRegentRevenueStaking(address(treasury.REGENT_STAKING()));
        IRegentsAutolaunchFactoryV2 autolaunch = treasury.AUTOLAUNCH();
        _expectZeroRefused(IRegentRevenueStaking(address(0)), regent, autolaunch);
        _expectZeroRefused(staking, MockRegent(address(0)), autolaunch);
        _expectZeroRefused(staking, regent, IRegentsAutolaunchFactoryV2(address(0)));
    }

    function _expectZeroRefused(
        IRegentRevenueStaking staking,
        MockRegent regent,
        IRegentsAutolaunchFactoryV2 autolaunch
    ) private {
        Keyfleet unbound = new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table"),
            KeyfleetStack.companionsOfNextFleet()
        );
        new KeyfleetVotes(unbound);
        vm.expectRevert(KeyfleetTreasury.ZeroAddress.selector);
        new KeyfleetTreasury(unbound, staking, regent, autolaunch);
    }

    /// @dev Invariant: on every preset, across sales, Cascade completions, Accelerant rebates and
    /// USDC and another token sent to the fleet contract, every unit paid or received lands in
    /// exactly one of the treasury, the Cascade reserve, the owed share or the ledger's backing, and
    /// none of it is free capital in the core or the ledger.
    function testFuzz_everyUnitLandsInTheTreasuryTheReserveTheOwedShareOrBacking(
        uint8 presetIndex,
        uint8 keys,
        uint64 received,
        uint64 stray
    ) public {
        KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(bound(presetIndex, 0, 3));
        keys = uint8(bound(keys, 1, 40));
        Keyfleet fleet = _deploy(preset);
        KeyfleetRewards rewards = fleet.REWARDS();
        address treasury = address(fleet.TREASURY());

        uint256 paid;
        for (uint256 i = 0; i < keys; ++i) {
            paid += _buy(fleet, address(uint160(0x100000 + i)));
            _assertNoFreeCapitalOutsideTheTreasury(fleet);
        }

        uint256 backed = rewards.backed(address(usdc));
        uint256 capital = usdc.balanceOf(treasury);
        usdc.mint(address(fleet), received);
        fleet.recognizeSurplus(address(usdc));
        assertEq(usdc.balanceOf(treasury), capital + received, "USDC sent to the fleet is the treasury's");
        assertEq(rewards.backed(address(usdc)), backed, "and never the keys'");
        other.mint(address(fleet), stray);
        fleet.recognizeSurplus(address(other));

        _assertNoFreeCapitalOutsideTheTreasury(fleet);
        assertEq(
            usdc.balanceOf(treasury) + fleet.cascadeReserve() + fleet.protocolShareOwed()
                + rewards.backed(address(usdc)) + fleet.surplus(address(usdc)),
            paid + received,
            "every USDC unit is in the treasury, the reserve, the owed share or the backing"
        );
        assertEq(other.balanceOf(treasury), stray, "every other token is in the treasury");
        assertEq(other.balanceOf(address(fleet)), 0, "and none of it stays in the core");
    }

    /// @dev Invariant: the capital part of each purchase reaches the treasury in the purchase
    /// itself, on every preset that has one.
    function test_eachPurchaseSendsItsCapitalToTheTreasury() public {
        for (uint256 p = 0; p < 4; ++p) {
            Keyfleet fleet = _deploy(KeyfleetPresets.Preset(p));
            address treasury = address(fleet.TREASURY());
            for (uint256 i = 0; i < 3; ++i) {
                KeyfleetPresets.PurchaseSplit memory split = fleet.quote();
                uint256 before = usdc.balanceOf(treasury);
                uint256 releasedBefore = fleet.cascadeReserve();
                bool completes = KeyfleetPresets.Preset(p) == KeyfleetPresets.Preset.FibonacciCascade
                    && fleet.totalMinted() + 1
                        == KeyfleetPresets.fibonacciLevelEnd(fleet.levelOf(fleet.totalMinted() + 1));
                _buy(fleet, address(uint160(0x100000 + i)));
                if (completes) {
                    assertEq(
                        usdc.balanceOf(treasury) - before,
                        releasedBefore + split.reserve,
                        "a completed first level sends its whole reserve"
                    );
                } else {
                    assertEq(usdc.balanceOf(treasury) - before, split.capital, "the capital part, in the purchase");
                }
            }
        }
    }
}
