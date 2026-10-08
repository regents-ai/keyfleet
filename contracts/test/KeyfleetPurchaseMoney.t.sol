// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {FULL_PIECE, KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev Where every USDC of a purchase goes, now that the treasury's part is booked in the manager
/// and turned into REGENT later, piece by piece. The test keeps its own record of each purchase,
/// worked out from the preset rules, and after every purchase and again after the pieces checks it
/// against the manager, the ledger, the pools and every balance: the protocol share and the
/// Cascade reserve stay in the manager as USDC, rebates and repayments reach the ledger as USDC,
/// everything else is booked and then swapped, the treasury receives exactly the REGENT that USDC
/// buys, and nothing is left anywhere else. A purchase never touches the pools, so a pool that
/// fills only in part or pays nothing never stops one.
contract KeyfleetPurchaseMoneyTest is KeyfleetFixture {
    /// @dev WETH the stand-in v3 pool pays per atomic USDC.
    uint256 private constant WETH_PER_ATOMIC_USDC = 4e8;

    /// @dev The test's own record of one fleet's purchases, in atomic USDC.
    /// @param paid Gross USDC paid by buyers.
    /// @param protocol Protocol share set aside.
    /// @param reserve Cascade reserve of the level being sold.
    /// @param toRewards Rebates and repayments paid into the ledger.
    /// @param booked USDC booked to be turned into REGENT for the treasury.
    /// @param levelGross Cascade: gross paid for the level being sold.
    /// @param previousLevelGross Cascade: gross paid for the last completed level.
    struct Record {
        uint256 paid;
        uint256 protocol;
        uint256 reserve;
        uint256 toRewards;
        uint256 booked;
        uint256 levelGross;
        uint256 previousLevelGross;
    }

    /// @dev Which leg of the swap a revert test breaks, and how.
    enum Fault {
        UsdcLegPartial,
        RegentLegPartial,
        RegentLegPaysNothing
    }

    Record private record;

    function setUp() public {
        _setUpFixture();
    }

    // --- conservation ------------------------------------------------------

    function test_classicConservesEveryUsdcOverManyPurchases() public {
        _buyAndCheck(KeyfleetPresets.Preset.FleetTechClassic, 60);
    }

    function test_syndicateConservesEveryUsdcOverManyPurchases() public {
        _buyAndCheck(KeyfleetPresets.Preset.FibonacciSyndicate, 40);
    }

    function test_accelerantConservesEveryUsdcOverManyPurchases() public {
        _buyAndCheck(KeyfleetPresets.Preset.FleetTechAccelerant, 60);
    }

    /// @dev 53 keys: levels 1 to 6 complete, each releasing its leftover reserve, and key 53 starts
    /// the level 7 reserve.
    function test_cascadeConservesEveryUsdcOverManyPurchases() public {
        _buyAndCheck(KeyfleetPresets.Preset.FibonacciCascade, 53);
    }

    /// @dev The same accounting holds for a fleet anyone creates at any starting price, whose prices
    /// need not divide evenly: the rounding dust of each split stays in the part that is booked,
    /// and still nothing is lost or left behind. The creator's own key 1 is checked too.
    function testFuzz_anOpenFleetConservesEveryUsdcAtAnyStartPrice(uint8 presetSeed, uint256 startCents, uint8 more)
        public
    {
        KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(presetSeed % 4);
        uint256 startPrice = bound(startCents, 1_000, 100_000_000) * KeyfleetPresets.CENT_USDC;
        KeyfleetManager fleet = _createOpen(preset, startPrice);
        _book(fleet, startPrice, 1);
        _assertBooks(fleet);
        assertEq(usdc.balanceOf(creator), 0, "the creator paid exactly key 1");
        assertEq(usdc.allowance(creator, address(factory)), 0, "and left the factory no allowance");

        uint256 count = bound(more, 1, 12);
        for (uint256 i = 0; i < count; ++i) {
            _purchase(fleet);
        }
    }

    // --- a pool that does not fill exactly ------------------------------------

    /// @dev Invariant: when the USDC leg takes only part of the USDC, every purchase still goes
    /// through, on every preset, and the piece that meets it reverts with nothing moved. Once the
    /// pool fills again, the same piece goes through.
    function test_aPartialFillOnTheUsdcLegNeverStopsAPurchase() public {
        _sellThroughAFault(Fault.UsdcLegPartial);
    }

    /// @dev Invariant: the same when the REGENT leg takes only part of the WETH.
    function test_aPartialFillOnTheRegentLegNeverStopsAPurchase() public {
        _sellThroughAFault(Fault.RegentLegPartial);
    }

    /// @dev Invariant: the same when the REGENT leg pays out nothing.
    function test_aRegentLegThatPaysNothingNeverStopsAPurchase() public {
        _sellThroughAFault(Fault.RegentLegPaysNothing);
    }

    // --- helpers -------------------------------------------------------------

    /// @dev Buys `count` keys, running every piece due after each one, and checks the books after
    /// each purchase and after each round of pieces.
    function _buyAndCheck(KeyfleetPresets.Preset preset, uint256 count) private {
        KeyfleetManager fleet = _deploy(preset);
        for (uint256 i = 0; i < count; ++i) {
            _purchase(fleet);
            _convertAll();
            _assertBooks(fleet);
        }
        assertGt(record.booked, 0, "the purchases booked USDC for REGENT");
        assertEq(fleet.pendingConversion(), 0, "and all of it became REGENT");
    }

    /// @dev Buys the next key for a fresh wallet, records it and checks every balance.
    function _purchase(KeyfleetManager fleet) private {
        uint256 gross = fleet.nextPrice();
        uint256 keyNumber = fleet.totalMinted() + 1;
        uint256 inPool = usdc.balanceOf(address(v3Pool));
        _buy(fleet, _wallet(keyNumber));
        _book(fleet, gross, keyNumber);
        _assertBooks(fleet);
        assertEq(usdc.balanceOf(address(v3Pool)), inPool, "a purchase swaps nothing");
    }

    /// @dev Records one purchase of `gross` for key `keyNumber` by the preset rules: 10% protocol
    /// share; on Cascade the rest is reserved, and a level's last key repays the level before in
    /// full and books what is left; on later Accelerant keys 20% is booked and the rest rebated;
    /// otherwise the rest is booked.
    function _book(KeyfleetManager fleet, uint256 gross, uint256 keyNumber) private {
        uint256 protocol = gross / 10;
        record.paid += gross;
        record.protocol += protocol;
        KeyfleetPresets.Preset preset = fleet.PRESET();
        if (preset == KeyfleetPresets.Preset.FibonacciCascade) {
            record.reserve += gross - protocol;
            record.levelGross += gross;
            uint256 level = KeyfleetPresets.fibonacciLevelOf(keyNumber);
            if (keyNumber == KeyfleetPresets.fibonacciLevelEnd(level)) {
                uint256 repayment = level == 1 ? 0 : record.previousLevelGross;
                record.toRewards += repayment;
                record.booked += record.reserve - repayment;
                record.reserve = 0;
                record.previousLevelGross = record.levelGross;
                record.levelGross = 0;
            }
        } else if (preset == KeyfleetPresets.Preset.FleetTechAccelerant && keyNumber > 1) {
            uint256 capital = gross / 5;
            record.booked += capital;
            record.toRewards += gross - protocol - capital;
        } else {
            record.booked += gross - protocol;
        }
    }

    /// @dev Every USDC paid is in exactly one place, the booked USDC is either still booked or
    /// swapped, the treasury holds exactly the REGENT the swapped USDC buys and no USDC, and nothing
    /// is left in the manager beyond what it booked, nor in the buyer contract, the factory, the
    /// collection or the ledger beyond its backing.
    function _assertBooks(KeyfleetManager fleet) private view {
        KeyfleetRewards rewards = fleet.REWARDS();
        address treasury = address(fleet.TREASURY());
        uint256 owed = fleet.protocolShareOwed();
        uint256 reserve = fleet.cascadeReserve();
        uint256 inRewards = usdc.balanceOf(address(rewards));
        uint256 pending = fleet.pendingConversion();
        uint256 swapped = usdc.balanceOf(address(v3Pool));

        assertEq(owed, record.protocol, "the owed share is 10% of every purchase");
        assertEq(reserve, record.reserve, "the Cascade reserve is as booked");
        assertEq(inRewards, record.toRewards, "the ledger got exactly the rebates and repayments");
        assertEq(rewards.backed(address(usdc)), inRewards, "and backs all of it");
        assertEq(pending + swapped, record.booked, "the USDC bound for the treasury is booked or swapped");
        assertEq(record.paid, owed + reserve + inRewards + pending + swapped, "every USDC paid is accounted for");
        assertEq(usdc.totalSupply(), record.paid, "and every USDC that exists was paid for a key");

        assertEq(regent.balanceOf(treasury), _regentFor(swapped), "the treasury got the REGENT it bought");
        assertEq(usdc.balanceOf(treasury), 0, "and no USDC");
        assertEq(weth.balanceOf(address(poolManager)), swapped * WETH_PER_ATOMIC_USDC, "every WETH went on");
        assertEq(poolManager.delta(address(weth)), 0, "nothing owed to the PoolManager");
        assertEq(poolManager.delta(address(regent)), 0, "nor by it");

        assertEq(usdc.balanceOf(address(fleet)), owed + reserve + pending, "the manager holds only what it booked");
        assertEq(usdc.balanceOf(buyer), 0, "the buyer paid exactly the price");
        assertEq(usdc.allowance(buyer, address(fleet)), 0, "and left no allowance");
        assertEq(usdc.allowance(address(fleet), address(regentBuyer)), 0, "the manager left the buyer none");
        address[3] memory holdsNothing = [address(regentBuyer), address(factory), address(keys)];
        for (uint256 i = 0; i < holdsNothing.length; ++i) {
            assertEq(usdc.balanceOf(holdsNothing[i]), 0, "no stray USDC");
        }
        address[5] memory holdsNoSwapToken =
            [address(fleet), address(regentBuyer), address(factory), address(keys), address(rewards)];
        for (uint256 i = 0; i < holdsNoSwapToken.length; ++i) {
            assertEq(weth.balanceOf(holdsNoSwapToken[i]), 0, "no stray WETH");
            assertEq(regent.balanceOf(holdsNoSwapToken[i]), 0, "no stray REGENT");
        }
    }

    /// @dev On every founding fleet: breaks the pool by `fault`, buys keys until one books USDC for
    /// REGENT (every one goes through and the books hold), then shows the piece reverts with nothing
    /// moved, and that once the pool is mended the very same piece goes through.
    function _sellThroughAFault(Fault fault) private {
        for (uint256 p = 0; p < 4; ++p) {
            uint256 fresh = vm.snapshotState();
            KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset(p));
            if (fault == Fault.UsdcLegPartial) v3Pool.setFillBps(9000);
            if (fault == Fault.RegentLegPartial) poolManager.setFillBps(9000);
            // The PoolManager reports the WETH taken in full and no REGENT paid out.
            if (fault == Fault.RegentLegPaysNothing) poolManager.setReportedDelta(type(int128).min);
            while (fleet.pendingConversion() == 0) {
                _purchase(fleet);
            }

            uint256 pending = fleet.pendingConversion();
            uint256 inPool = usdc.balanceOf(address(v3Pool));
            uint256 regentHeld = regent.balanceOf(address(fleet.TREASURY()));
            uint256 opensAt = regentBuyer.nextPieceAt();
            if (block.timestamp < opensAt) vm.warp(opensAt);
            vm.expectRevert();
            regentBuyer.convert(FULL_PIECE);
            assertEq(fleet.pendingConversion(), pending, "the piece booked nothing off");
            assertEq(regentBuyer.nextInQueue(), address(fleet), "and the fleet keeps its place");
            assertEq(regentBuyer.nextPieceAt(), opensAt, "and no piece is counted");
            assertEq(usdc.balanceOf(address(v3Pool)), inPool, "the pool kept no USDC");
            assertEq(regent.balanceOf(address(fleet.TREASURY())), regentHeld, "the treasury got no REGENT");
            _assertBooks(fleet);

            v3Pool.setFillBps(10_000);
            poolManager.setFillBps(10_000);
            poolManager.clearReportedDelta();
            _convertAll();
            assertEq(
                regent.balanceOf(address(fleet.TREASURY())),
                regentHeld + _regentFor(pending),
                "the same piece goes through once the pool fills"
            );
            _assertBooks(fleet);
            delete record;
            vm.revertToState(fresh);
        }
    }
}
