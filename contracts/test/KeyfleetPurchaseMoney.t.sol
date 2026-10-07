// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev Where every USDC of a purchase goes, now that the treasury's part is bought as REGENT in
/// the same purchase. The test keeps its own record of each purchase, worked out from the preset
/// rules, and after every purchase checks it against the manager, the ledger, the pools and every
/// balance: the protocol share and the Cascade reserve stay in the manager as USDC, rebates and
/// repayments reach the ledger as USDC, everything else is swapped, the treasury receives exactly
/// the REGENT that USDC buys, and nothing is left anywhere else. A swap that does not fill exactly
/// or pays nothing reverts the whole purchase.
contract KeyfleetPurchaseMoneyTest is KeyfleetFixture {
    /// @dev WETH the stand-in v3 pool pays per atomic USDC.
    uint256 private constant WETH_PER_ATOMIC_USDC = 4e8;

    /// @dev The test's own record of one fleet's purchases, in atomic USDC.
    /// @param paid Gross USDC paid by buyers.
    /// @param protocol Protocol share set aside.
    /// @param reserve Cascade reserve of the level being sold.
    /// @param toRewards Rebates and repayments paid into the ledger.
    /// @param swapped USDC turned into REGENT for the treasury.
    /// @param levelGross Cascade: gross paid for the level being sold.
    /// @param previousLevelGross Cascade: gross paid for the last completed level.
    struct Record {
        uint256 paid;
        uint256 protocol;
        uint256 reserve;
        uint256 toRewards;
        uint256 swapped;
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
    /// need not divide evenly: the rounding dust of each split stays in the part that is swapped,
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

    // --- a swap that does not fill exactly ----------------------------------

    /// @dev Invariant: when the USDC leg takes only part of the USDC, the purchase reverts with
    /// `SwapIncomplete` and nothing is booked, on every preset. A Cascade purchase that completes no
    /// level makes no swap, so it goes through regardless. Once the pool fills again, the same
    /// purchase goes through.
    function test_aPartialFillOnTheUsdcLegRevertsThePurchase() public {
        _refuseOnEveryPreset(Fault.UsdcLegPartial);
    }

    /// @dev Invariant: when the REGENT leg takes only part of the WETH, the purchase reverts with
    /// `SwapIncomplete` and nothing is booked, on every preset; once the pool fills, it goes
    /// through.
    function test_aPartialFillOnTheRegentLegRevertsThePurchase() public {
        _refuseOnEveryPreset(Fault.RegentLegPartial);
    }

    /// @dev Invariant: a REGENT leg that pays out nothing reverts the purchase with `NothingBought`
    /// and nothing is booked, on every preset.
    function test_aRegentLegThatPaysNothingRevertsThePurchase() public {
        _refuseOnEveryPreset(Fault.RegentLegPaysNothing);
    }

    // --- helpers -------------------------------------------------------------

    function _buyAndCheck(KeyfleetPresets.Preset preset, uint256 count) private {
        KeyfleetManager fleet = _deploy(preset);
        for (uint256 i = 0; i < count; ++i) {
            _purchase(fleet);
        }
        assertGt(record.swapped, 0, "the purchases bought REGENT");
    }

    /// @dev Buys the next key for a fresh wallet, records it and checks every balance.
    function _purchase(KeyfleetManager fleet) private {
        uint256 gross = fleet.nextPrice();
        uint256 keyNumber = fleet.totalMinted() + 1;
        _buy(fleet, _wallet(keyNumber));
        _book(fleet, gross, keyNumber);
        _assertBooks(fleet);
    }

    /// @dev Records one purchase of `gross` for key `keyNumber` by the preset rules: 10% protocol
    /// share; on Cascade the rest is reserved, and a level's last key repays the level before in
    /// full and swaps what is left; on later Accelerant keys 20% is swapped and the rest rebated;
    /// otherwise the rest is swapped.
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
                record.swapped += record.reserve - repayment;
                record.reserve = 0;
                record.previousLevelGross = record.levelGross;
                record.levelGross = 0;
            }
        } else if (preset == KeyfleetPresets.Preset.FleetTechAccelerant && keyNumber > 1) {
            uint256 capital = gross / 5;
            record.swapped += capital;
            record.toRewards += gross - protocol - capital;
        } else {
            record.swapped += gross - protocol;
        }
    }

    /// @dev Every USDC paid is in exactly one place, the treasury holds exactly the REGENT the
    /// swapped USDC buys and no USDC, and nothing is left in the manager beyond what it booked, nor
    /// in the buyer contract, the factory, the collection or the ledger beyond its backing.
    function _assertBooks(KeyfleetManager fleet) private view {
        KeyfleetRewards rewards = fleet.REWARDS();
        address treasury = address(fleet.TREASURY());
        uint256 owed = fleet.protocolShareOwed();
        uint256 reserve = fleet.cascadeReserve();
        uint256 inRewards = usdc.balanceOf(address(rewards));
        uint256 swapped = usdc.balanceOf(address(v3Pool));

        assertEq(owed, record.protocol, "the owed share is 10% of every purchase");
        assertEq(reserve, record.reserve, "the Cascade reserve is as booked");
        assertEq(inRewards, record.toRewards, "the ledger got exactly the rebates and repayments");
        assertEq(rewards.backed(address(usdc)), inRewards, "and backs all of it");
        assertEq(swapped, record.swapped, "the pool got exactly the USDC bound for the treasury");
        assertEq(record.paid, owed + reserve + inRewards + swapped, "every USDC paid is accounted for");
        assertEq(usdc.totalSupply(), record.paid, "and every USDC that exists was paid for a key");

        assertEq(regent.balanceOf(treasury), _regentFor(swapped), "the treasury got the REGENT it bought");
        assertEq(usdc.balanceOf(treasury), 0, "and no USDC");
        assertEq(weth.balanceOf(address(poolManager)), swapped * WETH_PER_ATOMIC_USDC, "every WETH went on");
        assertEq(poolManager.delta(address(weth)), 0, "nothing owed to the PoolManager");
        assertEq(poolManager.delta(address(regent)), 0, "nor by it");

        assertEq(usdc.balanceOf(address(fleet)), owed + reserve, "the manager holds only what it booked");
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

    /// @dev The USDC the next purchase of `fleet` turns into REGENT; zero when it makes no swap.
    function _nextSwap(KeyfleetManager fleet) private view returns (uint256) {
        uint256 gross = fleet.nextPrice();
        uint256 keyNumber = fleet.totalMinted() + 1;
        uint256 rest = gross - gross / 10;
        KeyfleetPresets.Preset preset = fleet.PRESET();
        if (preset == KeyfleetPresets.Preset.FibonacciCascade) {
            uint256 level = KeyfleetPresets.fibonacciLevelOf(keyNumber);
            if (keyNumber != KeyfleetPresets.fibonacciLevelEnd(level)) return 0;
            uint256 repayment = level == 1 ? 0 : fleet.levelGrossPaid(level - 1);
            return fleet.cascadeReserve() + rest - repayment;
        }
        if (preset == KeyfleetPresets.Preset.FleetTechAccelerant && keyNumber > 1) return gross / 5;
        return rest;
    }

    /// @dev On every founding fleet: breaks the swap by `fault`, buys keys that make no swap (they
    /// go through), then shows the first purchase that swaps reverts with nothing booked, and,
    /// when the pool can be mended, that the very same purchase then goes through.
    function _refuseOnEveryPreset(Fault fault) private {
        for (uint256 p = 0; p < 4; ++p) {
            KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset(p));
            if (fault == Fault.UsdcLegPartial) v3Pool.setFillBps(9000);
            if (fault == Fault.RegentLegPartial) poolManager.setFillBps(9000);
            while (_nextSwap(fleet) == 0) {
                _buy(fleet, _wallet(fleet.totalMinted() + 1));
            }

            uint256 swap = _nextSwap(fleet);
            uint256 wethIn = swap * WETH_PER_ATOMIC_USDC;
            bytes memory reason;
            if (fault == Fault.UsdcLegPartial) {
                reason = abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, swap, swap * 9000 / 10_000);
            } else if (fault == Fault.RegentLegPartial) {
                reason =
                    abi.encodeWithSelector(KeyfleetRegentBuyer.SwapIncomplete.selector, wethIn, wethIn * 9000 / 10_000);
            } else {
                // The PoolManager reports the WETH taken in full and no REGENT paid out.
                poolManager.setReportedDelta((-int256(wethIn)) << 128);
                reason = abi.encodeWithSelector(KeyfleetRegentBuyer.NothingBought.selector);
            }
            (address to, uint256 price) = _refused(fleet, reason);

            if (fault == Fault.RegentLegPaysNothing) continue;
            v3Pool.setFillBps(10_000);
            poolManager.setFillBps(10_000);
            uint256 regentBefore = regent.balanceOf(address(fleet.TREASURY()));
            vm.prank(buyer);
            fleet.purchase(to, price, block.timestamp, new bytes32[](0));
            assertEq(
                regent.balanceOf(address(fleet.TREASURY())),
                regentBefore + _regentFor(swap),
                "the same purchase goes through once the pool fills"
            );
            assertEq(usdc.balanceOf(buyer), 0, "with the buyer's same USDC");
        }
    }

    /// @dev The figures a refused purchase must leave as they were.
    struct Books {
        uint256 minted;
        uint256 owed;
        uint256 reserve;
        uint256 current;
        uint256 inManager;
        uint256 inRewards;
        uint256 inPool;
        uint256 regentHeld;
    }

    function _books(KeyfleetManager fleet) private view returns (Books memory) {
        return Books({
            minted: fleet.totalMinted(),
            owed: fleet.protocolShareOwed(),
            reserve: fleet.cascadeReserve(),
            current: fleet.currentPrice(),
            inManager: usdc.balanceOf(address(fleet)),
            inRewards: usdc.balanceOf(address(fleet.REWARDS())),
            inPool: usdc.balanceOf(address(v3Pool)),
            regentHeld: regent.balanceOf(address(fleet.TREASURY()))
        });
    }

    /// @dev Funds and approves the next purchase of `fleet`, which must revert with `reason`, and
    /// checks nothing was booked, paid, bought or minted. Leaves the buyer funded and approved.
    function _refused(KeyfleetManager fleet, bytes memory reason) private returns (address to, uint256 price) {
        Books memory before = _books(fleet);
        price = fleet.nextPrice();
        to = _wallet(before.minted + 1);

        uint256 keysHeld = keys.balanceOf(to);
        usdc.mint(buyer, price);
        uint256 funds = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(reason);
        fleet.purchase(to, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();

        Books memory afterwards = _books(fleet);
        assertEq(afterwards.minted, before.minted, "no key was sold");
        assertEq(keys.balanceOf(to), keysHeld, "or minted");
        assertEq(afterwards.owed, before.owed, "no share was booked");
        assertEq(afterwards.reserve, before.reserve, "no reserve was booked");
        assertEq(afterwards.current, before.current, "the price did not step");
        assertEq(afterwards.inManager, before.inManager, "the manager's USDC is unchanged");
        assertEq(afterwards.inRewards, before.inRewards, "and the ledger's");
        assertEq(afterwards.inPool, before.inPool, "the pool kept no USDC");
        assertEq(afterwards.regentHeld, before.regentHeld, "the treasury got no REGENT");
        assertEq(usdc.balanceOf(buyer), funds, "the buyer kept the price");
        assertEq(weth.balanceOf(address(regentBuyer)), 0, "and the buyer contract holds no WETH");
        assertEq(usdc.allowance(address(fleet), address(regentBuyer)), 0, "or allowance");
    }
}
