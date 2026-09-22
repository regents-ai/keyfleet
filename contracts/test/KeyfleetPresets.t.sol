// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";

interface Vm {
    function expectRevert(bytes4 selector) external;
}

/// @dev Exposes the internal library externally so reverts can be asserted with `vm.expectRevert`.
contract PresetsHarness {
    function ceilDiv(uint256 a, uint256 b) external pure returns (uint256) {
        return KeyfleetPresets.ceilDiv(a, b);
    }

    function fibonacciLevelSupply(uint256 level) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelSupply(level);
    }

    function fibonacciTotalSupplyThrough(uint256 level) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciTotalSupplyThrough(level);
    }

    function fibonacciLevelStart(uint256 level) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelStart(level);
    }

    function fibonacciLevelEnd(uint256 level) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelEnd(level);
    }

    function fibonacciLevelOf(uint256 tokenId) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelOf(tokenId);
    }

    function fibonacciLevelPrice(uint256 q, uint256 level) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelPrice(q, level);
    }

    function fibonacciHoldingLimit(uint256 level) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciHoldingLimit(level);
    }

    function classicPrice(uint256 q) external pure returns (uint256) {
        return KeyfleetPresets.classicPrice(q);
    }

    function accelerantNextPrice(uint256 previousPrice) external pure returns (uint256) {
        return KeyfleetPresets.accelerantNextPrice(previousPrice);
    }

    function accelerantPrice(uint256 q, uint256 mintIndex) external pure returns (uint256) {
        return KeyfleetPresets.accelerantPrice(q, mintIndex);
    }

    function splitPurchase(KeyfleetPresets.Preset preset, uint256 gross, bool hasReferrer, bool hasPredecessor)
        external
        pure
        returns (KeyfleetPresets.PurchaseSplit memory)
    {
        return KeyfleetPresets.splitPurchase(preset, gross, hasReferrer, hasPredecessor);
    }
}

contract KeyfleetPresetsTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant MAX_Q = 1e24;
    uint256 private constant MAX_LEVEL = 20;
    uint256 private constant MAX_TOKEN_ID = 46_365;
    uint256 private constant BPS = 10_000;

    PresetsHarness private presets;

    function setUp() public {
        presets = new PresetsHarness();
    }

    // --- helpers -------------------------------------------------------------------------------

    /// @dev The published supply table, written out rather than derived, so the library must match it.
    function _supplyTable() private pure returns (uint256[20] memory) {
        return
            [uint256(2), 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181, 6765, 10_946, 17_711];
    }

    /// @dev The published cumulative table, written out rather than derived.
    function _cumulativeTable() private pure returns (uint256[20] memory) {
        return [
            uint256(2),
            5,
            10,
            18,
            31,
            52,
            86,
            141,
            230,
            374,
            607,
            984,
            1594,
            2581,
            4178,
            6762,
            10_943,
            17_708,
            28_654,
            46_365
        ];
    }

    /// @dev The ceil-rounded 1.2x ladder written out independently of the library implementation.
    function _referenceFibonacciPrice(uint256 q, uint256 level) private pure returns (uint256) {
        uint256 price = q;
        for (uint256 i = 1; i < level; ++i) {
            uint256 numerator = price * 120;
            price = numerator % 100 == 0 ? numerator / 100 : (numerator / 100) + 1;
        }
        return price;
    }

    /// @dev The ceil-rounded 1.05x ladder written out independently of the library implementation.
    function _referenceAccelerantPrice(uint256 q, uint256 mintIndex) private pure returns (uint256) {
        uint256 price = q;
        for (uint256 i = 0; i < mintIndex; ++i) {
            uint256 numerator = price * 105;
            price = numerator % 100 == 0 ? numerator / 100 : (numerator / 100) + 1;
        }
        return price;
    }

    // --- 1. supply tables ----------------------------------------------------------------------

    /// @dev Invariant: each level holds the sum of the two levels before it, and the cumulative
    ///      supply through level 20 is the highest token id.
    function testFibonacciSupplyAndCumulativeTablesMatchThePublishedValues() public view {
        uint256[20] memory supplies = _supplyTable();
        uint256[20] memory cumulative = _cumulativeTable();
        for (uint256 level = 1; level <= MAX_LEVEL; ++level) {
            require(presets.fibonacciLevelSupply(level) == supplies[level - 1], "Level supply");
            require(presets.fibonacciTotalSupplyThrough(level) == cumulative[level - 1], "Cumulative supply");
            if (level >= 3) {
                require(
                    supplies[level - 1] == supplies[level - 2] + supplies[level - 3], "Level is sum of two before it"
                );
            }
        }
        require(presets.fibonacciLevelSupply(1) == 2, "Level 1 holds two keys");
        require(presets.fibonacciLevelSupply(8) == 55, "Level 8 holds 55 keys");
        require(presets.fibonacciLevelSupply(MAX_LEVEL) == 17_711, "Level 20 holds 17711 keys");
        require(presets.fibonacciTotalSupplyThrough(MAX_LEVEL) == MAX_TOKEN_ID, "Highest token id");
        require(KeyfleetPresets.FIBONACCI_MAX_TOKEN_ID == MAX_TOKEN_ID, "Published highest token id");
        require(KeyfleetPresets.MAX_FIBONACCI_LEVEL == MAX_LEVEL, "Published highest level");
    }

    /// @dev Invariant: level 0 and any level above 20 are rejected by every level-taking function.
    function testLevelsOutsideOneThroughTwentyAreRejected() public {
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelSupply(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelSupply(21);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciTotalSupplyThrough(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciTotalSupplyThrough(21);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelStart(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelStart(21);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelEnd(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelEnd(21);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciHoldingLimit(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciHoldingLimit(21);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelPrice(1e18, 0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelPrice(1e18, 21);
    }

    // --- 2. token to level boundaries ----------------------------------------------------------

    /// @dev Invariant: token ids are contiguous, and each level's first and last id map back to it
    ///      while the ids either side of the level fall into the neighbouring levels.
    function testTokenIdsMapToLevelsAtEveryBoundary() public view {
        require(presets.fibonacciLevelOf(1) == 1, "Token 1 is level 1");
        require(presets.fibonacciLevelOf(2) == 1, "Token 2 is level 1");
        require(presets.fibonacciLevelOf(3) == 2, "Token 3 is level 2");
        require(presets.fibonacciLevelOf(5) == 2, "Token 5 is level 2");
        require(presets.fibonacciLevelOf(6) == 3, "Token 6 is level 3");
        require(presets.fibonacciLevelOf(10) == 3, "Token 10 is level 3");
        require(presets.fibonacciLevelOf(MAX_TOKEN_ID) == MAX_LEVEL, "Highest token is level 20");

        for (uint256 level = 1; level <= MAX_LEVEL; ++level) {
            uint256 start = presets.fibonacciLevelStart(level);
            uint256 end = presets.fibonacciLevelEnd(level);
            require(presets.fibonacciLevelOf(start) == level, "Level start round-trips");
            require(presets.fibonacciLevelOf(end) == level, "Level end round-trips");
            require(end - start + 1 == presets.fibonacciLevelSupply(level), "Level span equals supply");
            if (level > 1) {
                require(start == presets.fibonacciLevelEnd(level - 1) + 1, "Levels are contiguous");
                require(presets.fibonacciLevelOf(start - 1) == level - 1, "Id before start is previous level");
            }
            if (level < MAX_LEVEL) {
                require(presets.fibonacciLevelOf(end + 1) == level + 1, "Id after end is next level");
            }
        }
        require(presets.fibonacciLevelStart(1) == 1, "Token ids are 1-based");
    }

    /// @dev Invariant: token id 0 and anything past the highest minted id are rejected.
    function testTokenIdsOutsideTheMintedRangeAreRejected() public {
        vm.expectRevert(KeyfleetPresets.TokenIdOutOfBounds.selector);
        presets.fibonacciLevelOf(0);
        vm.expectRevert(KeyfleetPresets.TokenIdOutOfBounds.selector);
        presets.fibonacciLevelOf(MAX_TOKEN_ID + 1);
    }

    // --- 3. fibonacci prices -------------------------------------------------------------------

    /// @dev Invariant: level 1 costs the reference price and every further level compounds it by
    ///      1.2 with upward rounding applied at each step.
    function testFibonacciLevelPricesCompoundByOnePointTwoWithUpwardRounding() public view {
        uint256 q = 10e18;
        require(presets.fibonacciLevelPrice(q, 1) == 10e18, "Level 1 costs q");
        require(presets.fibonacciLevelPrice(q, 2) == 12e18, "Level 2 literal");
        require(presets.fibonacciLevelPrice(q, 3) == 14.4e18, "Level 3 literal");
        require(presets.fibonacciLevelPrice(q, 4) == 17.28e18, "Level 4 literal");
        require(presets.fibonacciLevelPrice(q, 5) == 20.736e18, "Level 5 literal");
        for (uint256 level = 1; level <= MAX_LEVEL; ++level) {
            require(presets.fibonacciLevelPrice(q, level) == _referenceFibonacciPrice(q, level), "Price ladder");
        }
    }

    /// @dev Invariant: with an odd reference price every step rounds up rather than truncating.
    function testFibonacciLevelPricesRoundUpOnOddReferencePrices() public view {
        require(presets.fibonacciLevelPrice(7, 1) == 7, "Level 1 costs q");
        require(presets.fibonacciLevelPrice(7, 2) == 9, "ceil(7 x 1.2) is 9");
        require(presets.fibonacciLevelPrice(7, 3) == 11, "ceil(9 x 1.2) is 11");
        require(presets.fibonacciLevelPrice(7, 4) == 14, "ceil(11 x 1.2) is 14");
        require(presets.fibonacciLevelPrice(1, 2) == 2, "ceil(1 x 1.2) is 2");
    }

    // --- 4. holding limits ---------------------------------------------------------------------

    /// @dev Invariant: one key per wallet below level 8, a tenth of the level supply from level 8 up.
    function testHoldingLimitIsOneKeyBelowLevelEightAndATenthOfSupplyAbove() public view {
        for (uint256 level = 1; level <= 7; ++level) {
            require(presets.fibonacciHoldingLimit(level) == 1, "Levels 1-7 allow one key");
        }
        require(presets.fibonacciHoldingLimit(8) == 5, "Level 8 allows 5");
        require(presets.fibonacciHoldingLimit(9) == 8, "Level 9 allows 8");
        require(presets.fibonacciHoldingLimit(10) == 14, "Level 10 allows 14");
        require(presets.fibonacciHoldingLimit(MAX_LEVEL) == 1771, "Level 20 allows 1771");
        for (uint256 level = 8; level <= MAX_LEVEL; ++level) {
            require(presets.fibonacciHoldingLimit(level) == presets.fibonacciLevelSupply(level) / 10, "Tenth of supply");
        }
    }

    // --- 5. classic ----------------------------------------------------------------------------

    /// @dev Invariant: Classic has a fixed 144-key supply and every primary key costs the reference price.
    function testClassicSupplyIsFixedAndEveryPrimaryKeyCostsTheReferencePrice() public view {
        require(KeyfleetPresets.CLASSIC_SUPPLY == 144, "Classic supply");
        require(presets.classicPrice(1) == 1, "Lowest reference price");
        require(presets.classicPrice(10e18) == 10e18, "Classic price is q");
        require(presets.classicPrice(MAX_Q) == MAX_Q, "Highest reference price");
    }

    // --- 6. accelerant -------------------------------------------------------------------------

    /// @dev Invariant: each primary mint costs the previous one compounded by 1.05, rounded up.
    function testAccelerantPriceCompoundsByOnePointZeroFivePerPrimaryMint() public view {
        require(presets.accelerantPrice(100, 0) == 100, "First mint costs q");
        require(presets.accelerantPrice(100, 1) == 105, "Second mint");
        require(presets.accelerantPrice(100, 2) == 111, "ceil(110.25) is 111");
        require(presets.accelerantPrice(100, 3) == 117, "ceil(116.55) is 117");
        uint256 q = 10e18;
        require(presets.accelerantPrice(q, 0) == q, "Index 0 is q");
        require(presets.accelerantPrice(q, 1) == (q * 105) / 100, "Index 1 is ceil(q x 1.05)");
    }

    /// @dev Invariant: stepping one price at a time gives the same ladder as pricing an index directly.
    function testAccelerantNextPriceMatchesPricingByIndex() public view {
        uint256 q = 3_333_333_333;
        uint256 walked = q;
        for (uint256 index = 0; index < 48; ++index) {
            require(presets.accelerantPrice(q, index) == walked, "Chained price matches indexed price");
            require(presets.accelerantPrice(q, index) == _referenceAccelerantPrice(q, index), "Price ladder");
            walked = presets.accelerantNextPrice(walked);
        }
    }

    /// @dev Invariant: the last of the 2000 keys prices without overflow and index 2000 is rejected.
    function testAccelerantLastKeyPricesAtTheHighestReferencePriceAndTwoThousandIsRejected() public {
        require(KeyfleetPresets.MAX_ACCELERANT_KEYS == 2000, "Published Accelerant supply bound");
        uint256 last = presets.accelerantPrice(MAX_Q, 1999);
        require(last > MAX_Q, "Last key costs more than the first");
        require(last < type(uint256).max / 105, "One more step would still not overflow");
        vm.expectRevert(KeyfleetPresets.MintIndexOutOfBounds.selector);
        presets.accelerantPrice(MAX_Q, 2000);
    }

    // --- 7. reference price bounds -------------------------------------------------------------

    /// @dev Invariant: every function taking a reference price rejects 0 and anything above MAX_Q,
    ///      and accepts MAX_Q itself at the most expensive point of each ladder.
    function testReferencePriceBoundsAreEnforcedEverywhereQIsAccepted() public {
        require(KeyfleetPresets.MAX_Q == MAX_Q, "Published bound");

        vm.expectRevert(KeyfleetPresets.QOutOfBounds.selector);
        presets.fibonacciLevelPrice(0, 1);
        vm.expectRevert(KeyfleetPresets.QOutOfBounds.selector);
        presets.fibonacciLevelPrice(MAX_Q + 1, 1);
        vm.expectRevert(KeyfleetPresets.QOutOfBounds.selector);
        presets.classicPrice(0);
        vm.expectRevert(KeyfleetPresets.QOutOfBounds.selector);
        presets.classicPrice(MAX_Q + 1);
        vm.expectRevert(KeyfleetPresets.QOutOfBounds.selector);
        presets.accelerantPrice(0, 0);
        vm.expectRevert(KeyfleetPresets.QOutOfBounds.selector);
        presets.accelerantPrice(MAX_Q + 1, 0);

        uint256 topLevel = presets.fibonacciLevelPrice(MAX_Q, MAX_LEVEL);
        require(topLevel == _referenceFibonacciPrice(MAX_Q, MAX_LEVEL), "Level 20 at the bound");
        require(topLevel < type(uint256).max / 120, "One more step would still not overflow");
        require(presets.fibonacciLevelPrice(1, MAX_LEVEL) > 0, "Lowest reference price at the bound");
        require(presets.accelerantPrice(1, KeyfleetPresets.MAX_ACCELERANT_KEYS - 1) > 0, "Lowest price, last key");
    }

    /// @dev Invariant: ceilDiv rejects a zero denominator and rounds up otherwise.
    function testCeilDivRoundsUpAndRejectsAZeroDenominator() public {
        require(presets.ceilDiv(0, 100) == 0, "Zero numerator");
        require(presets.ceilDiv(1, 100) == 1, "Rounds up");
        require(presets.ceilDiv(100, 100) == 1, "Exact division");
        require(presets.ceilDiv(101, 100) == 2, "Rounds up past exact");
        vm.expectRevert(KeyfleetPresets.ZeroDenominator.selector);
        presets.ceilDiv(1, 0);
    }

    // --- 8. purchase split ---------------------------------------------------------------------

    /// @dev Invariant: Syndicate and Classic send everything after fees to capital.
    function testSyndicateAndClassicSendEverythingAfterFeesToCapital() public view {
        KeyfleetPresets.PurchaseSplit memory withReferrer =
            presets.splitPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 10_000, true, false);
        require(withReferrer.protocol == 500, "Protocol 5%");
        require(withReferrer.referral == 1000, "Referral 10%");
        require(withReferrer.capital == 8500, "Capital 85%");
        require(withReferrer.reserve == 0, "No reserve");
        require(withReferrer.rebate == 0, "No rebate");

        KeyfleetPresets.PurchaseSplit memory withoutReferrer =
            presets.splitPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 10_000, false, true);
        require(withoutReferrer.protocol == 500, "Protocol 5%");
        require(withoutReferrer.referral == 0, "No referral deduction");
        require(withoutReferrer.capital == 9500, "Capital 95%");
        require(withoutReferrer.reserve == 0, "No reserve");
        require(withoutReferrer.rebate == 0, "No rebate");

        KeyfleetPresets.PurchaseSplit memory classic =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechClassic, 10_000, true, true);
        require(classic.protocol == 500 && classic.referral == 1000, "Classic fees");
        require(classic.capital == 8500, "Classic capital");
        require(classic.reserve == 0 && classic.rebate == 0, "Classic has no reserve or rebate");
    }

    /// @dev Invariant: Cascade sends everything after fees to the level-completion reserve.
    function testCascadeSendsEverythingAfterFeesToTheReserve() public view {
        KeyfleetPresets.PurchaseSplit memory withReferrer =
            presets.splitPurchase(KeyfleetPresets.Preset.FibonacciCascade, 10_000, true, true);
        require(withReferrer.protocol == 500, "Protocol 5%");
        require(withReferrer.referral == 1000, "Referral 10%");
        require(withReferrer.reserve == 8500, "Reserve 85%");
        require(withReferrer.capital == 0, "No capital");
        require(withReferrer.rebate == 0, "No rebate");

        KeyfleetPresets.PurchaseSplit memory withoutReferrer =
            presets.splitPurchase(KeyfleetPresets.Preset.FibonacciCascade, 10_000, false, false);
        require(withoutReferrer.protocol == 500, "Protocol 5%");
        require(withoutReferrer.referral == 0, "No referral deduction");
        require(withoutReferrer.reserve == 9500, "Reserve 95%");
        require(withoutReferrer.capital == 0, "No capital");
    }

    /// @dev Invariant: an Accelerant purchase with a predecessor pays capital 10% and rebates the rest,
    ///      while the very first mint sends everything after fees to capital.
    function testAccelerantRebatesThePredecessorOnlyWhenThereIsOne() public view {
        KeyfleetPresets.PurchaseSplit memory withReferrer =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 10_000, true, true);
        require(withReferrer.protocol == 500, "Protocol 5%");
        require(withReferrer.referral == 1000, "Referral 10%");
        require(withReferrer.capital == 1000, "Capital 10%");
        require(withReferrer.rebate == 7500, "Rebate 75%");
        require(withReferrer.reserve == 0, "No reserve");

        KeyfleetPresets.PurchaseSplit memory withoutReferrer =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 10_000, false, true);
        require(withoutReferrer.protocol == 500, "Protocol 5%");
        require(withoutReferrer.referral == 0, "No referral deduction");
        require(withoutReferrer.capital == 1000, "Capital 10%");
        require(withoutReferrer.rebate == 8500, "Rebate 85%");

        KeyfleetPresets.PurchaseSplit memory firstMint =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 10_000, true, false);
        require(firstMint.protocol == 500 && firstMint.referral == 1000, "First mint fees");
        require(firstMint.capital == 8500, "First mint sends the rest to capital");
        require(firstMint.rebate == 0, "Nobody to rebate");
        require(firstMint.reserve == 0, "No reserve");
    }

    /// @dev Invariant: the five parts always sum to gross, the protocol fee is always 5% floored,
    ///      referral is deducted only with a referrer, reserve belongs to Cascade alone and rebate to
    ///      Accelerant primary mints with a predecessor alone.
    function testFuzzSplitAlwaysSumsToGrossAndKeepsEachPartToItsPreset(
        uint8 presetSeed,
        uint256 grossSeed,
        bool hasReferrer,
        bool hasPredecessor
    ) public view {
        KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(presetSeed % 4);
        uint256 gross = (grossSeed % (uint256(1) << 200)) + 1;
        KeyfleetPresets.PurchaseSplit memory split = presets.splitPurchase(preset, gross, hasReferrer, hasPredecessor);

        require(
            split.protocol + split.referral + split.capital + split.reserve + split.rebate == gross,
            "Parts sum to gross"
        );
        require(split.protocol == (gross * 500) / BPS, "Protocol is 5% floored");

        if (hasReferrer) {
            require(split.referral == (gross * 1000) / BPS, "Referral is 10% floored");
            if (gross >= 10) require(split.referral > 0, "A referrer earns on any priced purchase");
        } else {
            require(split.referral == 0, "No referrer means no referral");
        }

        bool isCascade = preset == KeyfleetPresets.Preset.FibonacciCascade;
        require(isCascade == (split.reserve > 0), "Reserve belongs to Cascade alone");

        bool isAccelerantWithPredecessor = preset == KeyfleetPresets.Preset.FleetTechAccelerant && hasPredecessor;
        require(
            isAccelerantWithPredecessor == (split.rebate > 0),
            "Rebate belongs to Accelerant mints with a predecessor alone"
        );
        if (isAccelerantWithPredecessor) {
            require(split.capital == (gross * 1000) / BPS, "Capital is 10% floored");
        } else if (!isCascade) {
            require(split.capital == gross - split.protocol - split.referral, "Capital absorbs the dust");
        } else {
            require(split.capital == 0, "Cascade sends nothing to capital");
        }
    }

    /// @dev Invariant: a purchase of zero is rejected for every preset.
    function testZeroGrossIsRejectedForEveryPreset() public {
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 0, true, true);
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FibonacciCascade, 0, false, false);
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FleetTechClassic, 0, true, false);
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 0, false, true);
    }

    // --- 9. rounding direction -----------------------------------------------------------------

    /// @dev Invariant: each Fibonacci step rounds up, never down, and never by more than one unit.
    function testFuzzFibonacciStepAlwaysRoundsUpByLessThanOneUnit(uint256 qSeed, uint256 levelSeed) public view {
        uint256 q = (qSeed % MAX_Q) + 1;
        uint256 level = (levelSeed % (MAX_LEVEL - 1)) + 2;
        uint256 previous = presets.fibonacciLevelPrice(q, level - 1);
        uint256 current = presets.fibonacciLevelPrice(q, level);
        require(current * 100 >= previous * 120, "Never rounds down");
        require(current * 100 - previous * 120 < 100, "Never rounds up by a whole unit");
    }
}
