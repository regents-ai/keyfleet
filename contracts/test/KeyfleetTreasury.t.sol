// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev The fleet's free capital lives in its treasury and nowhere else: the capital part of every
/// purchase and a completed Cascade level's released reserve arrive there as REGENT, bought in the
/// purchase that books them, and every token sent to the fleet's manager outside a purchase is
/// forwarded there as it was paid. The manager keeps only the Cascade reserve and the owed protocol
/// share, the ledger only its backing, and the REGENT buyer nothing at all.
contract KeyfleetTreasuryTest is KeyfleetFixture {
    MockToken private other;
    address private mallory = address(0x4A11);

    function setUp() public {
        _setUpFixture();
        other = new MockToken("Other", "OTH");
    }

    function _buyGross(KeyfleetManager fleet, address receiver) private returns (uint256 gross) {
        gross = fleet.nextPrice();
        _buy(fleet, receiver);
    }

    /// @dev The manager holds exactly its reserve, its owed share and anything not yet forwarded;
    /// the ledger exactly its backing; neither holds REGENT, and the shared buyer holds nothing.
    function _assertNoFreeCapitalOutsideTheTreasury(KeyfleetManager fleet) private view {
        KeyfleetRewards rewards = fleet.REWARDS();
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.cascadeReserve() + fleet.protocolShareOwed() + fleet.pendingConversion()
                + fleet.surplus(address(usdc)),
            "the manager holds its reserve, its owed share, its booked USDC and anything not yet sorted"
        );
        assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds its backing");
        assertEq(regent.balanceOf(address(fleet)), 0, "the manager keeps no REGENT");
        assertEq(regent.balanceOf(address(rewards)), 0, "nor does the ledger");
        assertEq(usdc.balanceOf(address(regentBuyer)), 0, "the buyer keeps no USDC");
        assertEq(weth.balanceOf(address(regentBuyer)), 0, "no WETH");
        assertEq(regent.balanceOf(address(regentBuyer)), 0, "and no REGENT");
    }

    // --- bindings ------------------------------------------------------------

    /// @dev Invariant: every treasury is bound to its own fleet's manager, voting controller and
    /// ledger, at the addresses the factory predicted for that fleet number, and to exactly the
    /// USDC, REGENT, staking contract and Autolaunch factory the factory names. Its split
    /// thresholds are 100 whole units of each token. Founding and open fleets alike.
    function test_theTreasuryIsBoundToItsOwnFleetAndTheFactorysBindings() public {
        KeyfleetManager[] memory fleets = new KeyfleetManager[](3);
        fleets[0] = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        fleets[1] = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        fleets[2] = _createOpen(KeyfleetPresets.Preset.FleetTechAccelerant, 25e6);

        for (uint256 i = 0; i < fleets.length; ++i) {
            KeyfleetManager fleet = fleets[i];
            KeyfleetTreasury treasury = fleet.TREASURY();
            uint256 id = fleet.FLEET_ID();
            (address manager, address votes, address predicted, address rewards) = factory.predict(id);

            assertEq(address(treasury), predicted, "deployed where the factory predicted");
            assertGt(address(treasury).code.length, 0, "and deployed");
            assertEq(address(treasury.MANAGER()), manager, "MANAGER is the fleet's manager");
            assertEq(address(treasury.MANAGER()), keys.managerOf(id), "the manager the collection registered");
            assertEq(address(treasury.VOTES()), votes, "VOTES is the fleet's controller");
            assertEq(address(treasury.VOTES()), address(fleet.VOTES()), "the one its manager names");
            assertEq(address(treasury.REWARDS()), rewards, "REWARDS is the fleet's ledger");
            assertEq(address(treasury.REWARDS()), address(fleet.REWARDS()), "the one its manager names");
            assertEq(address(fleet.VOTES().TREASURY()), address(treasury), "its controller names it back");
            assertEq(address(fleet.REWARDS().TREASURY()), address(treasury), "and so does its ledger");

            assertEq(address(treasury.USDC()), address(factory.USDC()), "the factory's USDC");
            assertEq(address(treasury.USDC()), address(usdc));
            assertEq(address(treasury.REGENT()), address(factory.REGENT()), "the factory's REGENT");
            assertEq(address(treasury.REGENT()), address(regent));
            assertEq(address(treasury.REGENT_STAKING()), address(factory.REGENT_STAKING()), "the factory's staking");
            assertEq(address(treasury.REGENT_STAKING()), address(staking));
            assertEq(address(treasury.AUTOLAUNCH()), address(factory.AUTOLAUNCH()), "the factory's Autolaunch");
            assertEq(address(treasury.AUTOLAUNCH()), address(autolaunch));

            assertEq(treasury.PROTOCOL_SHARE_TAG(), keccak256("keyfleet.protocol_share"), "the protocol share tag");
            assertEq(treasury.USDC_THRESHOLD(), 100e6, "100 USDC by its six decimals");
            assertEq(treasury.REGENT_THRESHOLD(), 100e18, "100 REGENT by its eighteen decimals");
        }
        assertTrue(
            address(fleets[0].TREASURY()) != address(fleets[2].TREASURY()), "every fleet has a treasury of its own"
        );
    }

    /// @dev Invariant: only the fleet's own manager asks its treasury to deposit the protocol share,
    /// and every deposit names that manager as its source reference. Nobody else reaches it: not a
    /// stranger, not the fleet's controller or ledger, not another fleet's manager.
    function test_onlyItsManagerDepositsTheProtocolShareUnderItsOwnAddress() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager another = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetTreasury treasury = fleet.TREASURY();
        _buyMany(fleet, 3);
        usdc.mint(address(treasury), 1e6);

        address[4] memory callers = [mallory, address(fleet.VOTES()), address(fleet.REWARDS()), address(another)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(KeyfleetTreasury.OnlyManager.selector);
            treasury.depositProtocolShare(1e6);
        }

        uint256 owed = fleet.protocolShareOwed();
        vm.prank(mallory);
        assertEq(fleet.sendProtocolShare(), owed);
        assertEq(staking.totalUsdcReceived(), owed, "staking took the whole owed share");
        assertEq(staking.lastSourceTag(), keccak256("keyfleet.protocol_share"), "under the protocol share tag");
        assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(fleet)))), "naming the manager");
        assertEq(usdc.balanceOf(address(treasury)), 1e6, "nothing of the share stayed in the treasury");
        assertEq(usdc.allowance(address(treasury), address(staking)), 0, "and no allowance either");
    }

    // --- where every unit lands ------------------------------------------------------------

    /// @dev Invariant: on every preset, across sales, Cascade completions, Accelerant rebates and
    /// USDC and another token sent to the manager, every USDC unit paid or received lands in exactly
    /// one of the treasury, the Cascade reserve, the owed share, the ledger's backing, the USDC
    /// booked for REGENT, or, once its piece runs, the REGENT market in exchange for REGENT that went
    /// whole to the treasury; none of it is free capital in the manager, the ledger or the buyer.
    function testFuzz_everyUnitLandsInTheTreasuryTheReserveTheOwedShareOrBacking(
        uint8 presetIndex,
        uint8 count,
        uint64 received,
        uint64 stray
    ) public {
        KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(bound(presetIndex, 0, 3));
        count = uint8(bound(count, 1, 40));
        KeyfleetManager fleet = _deploy(preset);
        KeyfleetRewards rewards = fleet.REWARDS();
        address treasury = address(fleet.TREASURY());

        uint256 paid;
        for (uint256 i = 0; i < count; ++i) {
            paid += _buyGross(fleet, _wallet(i + 1));
            _assertNoFreeCapitalOutsideTheTreasury(fleet);
        }
        _convertAll();
        _assertNoFreeCapitalOutsideTheTreasury(fleet);
        uint256 swapped = usdc.balanceOf(address(v3Pool));
        assertEq(regent.balanceOf(treasury), _regentFor(swapped), "every swapped unit came back as REGENT");
        assertEq(usdc.balanceOf(treasury), 0, "purchases send the treasury no USDC");

        uint256 backed = rewards.backed(address(usdc));
        usdc.mint(address(fleet), received);
        fleet.recognizeSurplus(address(usdc));
        assertEq(usdc.balanceOf(treasury), received, "USDC sent to the manager is the treasury's, unswapped");
        assertEq(rewards.backed(address(usdc)), backed, "and never the keys'");
        other.mint(address(fleet), stray);
        fleet.recognizeSurplus(address(other));

        _assertNoFreeCapitalOutsideTheTreasury(fleet);
        assertEq(
            usdc.balanceOf(treasury) + fleet.cascadeReserve() + fleet.protocolShareOwed()
                + rewards.backed(address(usdc)) + fleet.pendingConversion() + fleet.surplus(address(usdc)) + swapped,
            paid + received,
            "every USDC unit is in the treasury, the reserve, the owed share, the backing, booked or swapped"
        );
        assertEq(regent.balanceOf(treasury), _regentFor(swapped), "the forwarding swapped nothing");
        assertEq(other.balanceOf(treasury), stray, "every other token is in the treasury");
        assertEq(other.balanceOf(address(fleet)), 0, "and none of it stays in the manager");
    }

    /// @dev Invariant: the treasury's part of each purchase is booked in the manager in the
    /// purchase itself and reaches the treasury as REGENT once its pieces run, on every preset: the
    /// capital part on Classic, Syndicate and Accelerant, and on Cascade nothing per key but, in the
    /// purchase that completes a level, the released reserve after repaying the previous level in
    /// USDC through the ledger. The treasury never receives USDC from a purchase.
    function test_eachPurchaseBooksItsTreasuryPartAndItsPiecesBringItAsRegent() public {
        for (uint256 p = 0; p < 4; ++p) {
            KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(p);
            KeyfleetManager fleet = _deploy(preset);
            address treasury = address(fleet.TREASURY());
            bool cascade = preset == KeyfleetPresets.Preset.FibonacciCascade;
            for (uint256 i = 0; i < 6; ++i) {
                KeyfleetPresets.PurchaseSplit memory split = fleet.quote();
                uint256 before = regent.balanceOf(treasury);
                uint256 reserveBefore = fleet.cascadeReserve();
                uint256 keyNumber = fleet.totalMinted() + 1;
                bool completes = cascade && keyNumber == KeyfleetPresets.fibonacciLevelEnd(fleet.levelOf(keyNumber));
                uint256 repaid =
                    completes && fleet.levelOf(keyNumber) > 1 ? fleet.levelGrossPaid(fleet.levelOf(keyNumber) - 1) : 0;
                _buy(fleet, _wallet(i + 1));
                uint256 booked = completes ? reserveBefore + split.reserve - repaid : split.capital;
                assertEq(fleet.pendingConversion(), booked, "the purchase books the treasury's part");
                assertEq(regent.balanceOf(treasury), before, "and swaps none of it");
                _convertAll();
                assertEq(regent.balanceOf(treasury) - before, _regentFor(booked), "its pieces bring it as REGENT");
                assertEq(usdc.balanceOf(treasury), 0, "never USDC");
            }
            if (cascade) assertTrue(fleet.levelCompleted(2), "two Cascade levels completed, one with a repayment");
        }
    }
}
