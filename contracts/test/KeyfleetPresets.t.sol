// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";

interface Vm {
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
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

    function fibonacciLevelOf(uint256 keyNumber) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelOf(keyNumber);
    }

    function fibonacciLevelPrice(uint256 level, uint256 start) external pure returns (uint256) {
        return KeyfleetPresets.fibonacciLevelPrice(level, start);
    }

    function classicPrice(uint256 keyNumber, uint256 start) external pure returns (uint256) {
        return KeyfleetPresets.classicPrice(keyNumber, start);
    }

    function accelerantNextPrice(uint256 previousPrice, uint256 stepPercent) external pure returns (uint256) {
        return KeyfleetPresets.accelerantNextPrice(previousPrice, stepPercent);
    }

    function accelerantPrice(uint256 mintIndex, uint256 start, uint256 stepPercent) external pure returns (uint256) {
        return KeyfleetPresets.accelerantPrice(mintIndex, start, stepPercent);
    }

    function splitPurchase(KeyfleetPresets.Preset preset, uint256 gross, bool hasPredecessor)
        external
        pure
        returns (KeyfleetPresets.PurchaseSplit memory)
    {
        return KeyfleetPresets.splitPurchase(preset, gross, hasPredecessor);
    }
}

contract KeyfleetPresetsTest {
    // Named like forge-std's own cheatcode handle, so the calls read the same as in every other test.
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Ten USDC in atomic units, the first key of every founding fleet.
    uint256 private constant Q_USDC = 10_000_000;
    /// @dev Ten USDC in atomic units, the start the Classic table is written for.
    uint256 private constant CLASSIC_START = 10_000_000;
    /// @dev The founding Accelerant fleet's step, the highest an Accelerant fleet may choose.
    uint256 private constant FOUNDING_STEP = 5;
    /// @dev One US cent in atomic USDC.
    uint256 private constant CENT = 10_000;
    /// @dev The levels the written-out tables cover. There is no last level; this is only how far the
    ///      tables go.
    uint256 private constant TABLE_LEVELS = 20;
    /// @dev The highest level the loops below walk, which takes 701,408,730 keys sold to complete.
    uint256 private constant HIGH_LEVEL = 40;
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

    /// @dev The ceil-rounded 1.2x ladder from `start`, written out independently of the library.
    function _referenceFibonacciPrice(uint256 level, uint256 start) private pure returns (uint256) {
        uint256 price = start;
        for (uint256 i = 1; i < level; ++i) {
            uint256 numerator = price * 120;
            price = numerator % 100 == 0 ? numerator / 100 : (numerator / 100) + 1;
        }
        return price;
    }

    /// @dev The ceil-rounded 1.05x ladder from `start`, written out independently of the library.
    function _referenceAccelerantPrice(uint256 mintIndex, uint256 start, uint256 stepPercent)
        private
        pure
        returns (uint256)
    {
        uint256 price = start;
        for (uint256 i = 0; i < mintIndex; ++i) {
            uint256 numerator = price * (100 + stepPercent);
            price = numerator % 100 == 0 ? numerator / 100 : (numerator / 100) + 1;
        }
        return price;
    }

    /// @dev Starting prices a fleet anyone creates may choose, in whole cents, from the lowest to the
    ///      highest, including some whose scaled Classic prices fall between cents.
    function _starts() private pure returns (uint256[6] memory) {
        return [uint256(10_000_000), 10_010_000, 12_340_000, 16_000_000, 99_990_000, 1_000_000_000_000];
    }

    // --- 1. supply tables ----------------------------------------------------------------------

    /// @dev Invariant: each level holds the sum of the two levels before it, and key numbers run on
    ///      through every level without a last one.
    function testFibonacciSupplyAndCumulativeTablesMatchThePublishedValues() public view {
        uint256[20] memory supplies = _supplyTable();
        uint256[20] memory cumulative = _cumulativeTable();
        for (uint256 level = 1; level <= TABLE_LEVELS; ++level) {
            require(presets.fibonacciLevelSupply(level) == supplies[level - 1], "Level supply");
            require(presets.fibonacciTotalSupplyThrough(level) == cumulative[level - 1], "Cumulative supply");
        }
        for (uint256 level = 3; level <= HIGH_LEVEL; ++level) {
            require(
                presets.fibonacciLevelSupply(level)
                    == presets.fibonacciLevelSupply(level - 1) + presets.fibonacciLevelSupply(level - 2),
                "Level is sum of two before it"
            );
            require(
                presets.fibonacciTotalSupplyThrough(level)
                    == presets.fibonacciTotalSupplyThrough(level - 1) + presets.fibonacciLevelSupply(level),
                "Cumulative adds the level"
            );
        }
        require(presets.fibonacciLevelSupply(1) == 2, "Level 1 holds two keys");
        require(presets.fibonacciLevelSupply(8) == 55, "Level 8 holds 55 keys");
        require(presets.fibonacciLevelSupply(21) == 28_657, "Level 21 follows level 20");
        require(presets.fibonacciLevelSupply(30) == 2_178_309, "Level 30 holds 2,178,309 keys");
        require(presets.fibonacciTotalSupplyThrough(30) == 5_702_884, "5,702,884 keys through level 30");
        require(presets.fibonacciLevelSupply(40) == 267_914_296, "Level 40 holds 267,914,296 keys");
        require(presets.fibonacciTotalSupplyThrough(40) == 701_408_730, "701,408,730 keys through level 40");
    }

    /// @dev Invariant: level 0 is rejected by every level-taking function, and levels start at 1.
    function testLevelZeroIsRejected() public {
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelSupply(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciTotalSupplyThrough(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelStart(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelEnd(0);
        vm.expectRevert(KeyfleetPresets.LevelOutOfBounds.selector);
        presets.fibonacciLevelPrice(0, Q_USDC);
    }

    /// @dev Invariant: there is no last level, and the arithmetic reverts rather than wraps where it
    ///      would leave 256 bits. The cumulative supply first does so at level 367, where a key would
    ///      cost more than 10^29 USDC.
    function testLevelsHaveNoLastOneAndTheArithmeticNeverWraps() public {
        require(presets.fibonacciTotalSupplyThrough(366) > presets.fibonacciTotalSupplyThrough(365), "Level 366");
        require(presets.fibonacciLevelSupply(368) > presets.fibonacciLevelSupply(367), "Level 368 supply");
        require(presets.fibonacciLevelPrice(367, Q_USDC) > 1e35, "Level 367 costs more than 10^29 USDC");
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        presets.fibonacciTotalSupplyThrough(367);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        presets.fibonacciLevelSupply(369);
    }

    // --- 2. key number to level boundaries -----------------------------------------------------

    /// @dev Invariant: key numbers are contiguous, and each level's first and last key map back to it
    ///      while the keys either side of the level fall into the neighbouring levels.
    function testKeyNumbersMapToLevelsAtEveryBoundary() public view {
        require(presets.fibonacciLevelOf(1) == 1, "Key 1 is level 1");
        require(presets.fibonacciLevelOf(2) == 1, "Key 2 is level 1");
        require(presets.fibonacciLevelOf(3) == 2, "Key 3 is level 2");
        require(presets.fibonacciLevelOf(5) == 2, "Key 5 is level 2");
        require(presets.fibonacciLevelOf(6) == 3, "Key 6 is level 3");
        require(presets.fibonacciLevelOf(10) == 3, "Key 10 is level 3");
        require(presets.fibonacciLevelOf(46_365) == 20, "Key 46,365 ends level 20");
        require(presets.fibonacciLevelOf(46_366) == 21, "Key 46,366 starts level 21");
        require(presets.fibonacciLevelOf(701_408_730) == 40, "Key 701,408,730 ends level 40");
        require(presets.fibonacciLevelOf(701_408_731) == 41, "and the next starts level 41");

        for (uint256 level = 1; level <= HIGH_LEVEL; ++level) {
            uint256 start = presets.fibonacciLevelStart(level);
            uint256 end = presets.fibonacciLevelEnd(level);
            require(presets.fibonacciLevelOf(start) == level, "Level start round-trips");
            require(presets.fibonacciLevelOf(end) == level, "Level end round-trips");
            require(end - start + 1 == presets.fibonacciLevelSupply(level), "Level span equals supply");
            require(presets.fibonacciLevelOf(end + 1) == level + 1, "Key after end is next level");
            if (level > 1) {
                require(start == presets.fibonacciLevelEnd(level - 1) + 1, "Levels are contiguous");
                require(presets.fibonacciLevelOf(start - 1) == level - 1, "Key before start is previous level");
            }
        }
        require(presets.fibonacciLevelStart(1) == 1, "Key numbers are 1-based");
    }

    /// @dev Invariant: key number 0 is rejected by every key-number-taking function; keys start at 1.
    function testKeyNumberZeroIsRejected() public {
        vm.expectRevert(KeyfleetPresets.KeyNumberOutOfBounds.selector);
        presets.fibonacciLevelOf(0);
        vm.expectRevert(KeyfleetPresets.KeyNumberOutOfBounds.selector);
        presets.classicPrice(0, CLASSIC_START);
    }

    // --- 3. fibonacci prices -------------------------------------------------------------------

    /// @dev Invariant: at the founding start of ten USDC, level 1 costs ten USDC and every further
    ///      level compounds it by 1.2 with upward rounding applied at each step. The first five
    ///      figures are the ones the platform mirrors.
    function testFibonacciLevelPricesCompoundByOnePointTwoWithUpwardRounding() public view {
        require(presets.fibonacciLevelPrice(1, Q_USDC) == 10_000_000, "Level 1 costs 10 USDC");
        require(presets.fibonacciLevelPrice(2, Q_USDC) == 12_000_000, "Level 2 literal");
        require(presets.fibonacciLevelPrice(3, Q_USDC) == 14_400_000, "Level 3 literal");
        require(presets.fibonacciLevelPrice(4, Q_USDC) == 17_280_000, "Level 4 literal");
        require(presets.fibonacciLevelPrice(5, Q_USDC) == 20_736_000, "Level 5 literal");
        require(presets.fibonacciLevelPrice(20, Q_USDC) == 319_480_010, "Level 20 literal");
        require(presets.fibonacciLevelPrice(30, Q_USDC) == 1_978_136_019, "Level 30 costs about 1,978 USDC");
        require(presets.fibonacciLevelPrice(40, Q_USDC) == 12_248_096_849, "Level 40 costs about 12,248 USDC");
        require(presets.fibonacciLevelPrice(102, Q_USDC) < 1e15, "Level 102 costs under a billion USDC");
        require(presets.fibonacciLevelPrice(103, Q_USDC) > 1e15, "Level 103 costs over a billion USDC");
        for (uint256 level = 1; level <= HIGH_LEVEL; ++level) {
            require(presets.fibonacciLevelPrice(level, Q_USDC) == _referenceFibonacciPrice(level, Q_USDC), "Ladder");
        }
    }

    /// @dev Invariant: the first step whose 1.2x is fractional rounds up rather than truncating.
    function testFibonacciLevelPricesRoundUpWhereTheStepIsFractional() public view {
        require(presets.fibonacciLevelPrice(8, Q_USDC) == 35_831_808, "Level 8 is exact");
        require(presets.fibonacciLevelPrice(9, Q_USDC) == 42_998_170, "ceil(42,998,169.6) is 42,998,170");
    }

    /// @dev Invariant: a fleet's level 1 costs exactly its starting price, and every later level
    ///      follows the same 1.2x ceil-rounded ladder from that price, for every starting price a
    ///      creator may choose.
    function testFibonacciLevelPricesStartFromTheStartingPrice() public view {
        uint256[6] memory starts = _starts();
        for (uint256 s = 0; s < starts.length; ++s) {
            uint256 start = starts[s];
            require(presets.fibonacciLevelPrice(1, start) == start, "Level 1 costs the starting price");
            for (uint256 level = 2; level <= HIGH_LEVEL; ++level) {
                require(
                    presets.fibonacciLevelPrice(level, start) == _referenceFibonacciPrice(level, start),
                    "The ladder starts from the starting price"
                );
            }
        }
        require(presets.fibonacciLevelPrice(2, 25_000_000) == 30_000_000, "25 USDC then 30 USDC");
        require(presets.fibonacciLevelPrice(3, 25_000_000) == 36_000_000, "then 36 USDC");
    }

    // --- 4. classic ----------------------------------------------------------------------------

    /// @dev 10^(1/1023), the ratio from one Classic key's exact price to the next, in units of 1e-36,
    ///      rounded down. Written out independently of the generated table it checks.
    uint256 private constant CLASSIC_STEP = 1_002_253_351_306_309_679_922_542_762_744_250_256;
    uint256 private constant FIXED_ONE = 1e36;

    /// @dev Invariant: Classic sells 1024 keys; at the founding start key 1 costs exactly 10 USDC and
    ///      key 1024 exactly 100 USDC.
    function testClassicSellsOneThousandTwentyFourKeysFromTenToOneHundredUsdc() public {
        require(KeyfleetPresets.CLASSIC_SUPPLY == 1024, "Classic supply");
        require(KeyfleetPresets.CLASSIC_START_USDC == CLASSIC_START, "The table is written for 10 USDC");
        require(presets.classicPrice(1, CLASSIC_START) == 10_000_000, "Key 1 costs 10 USDC");
        require(presets.classicPrice(144, CLASSIC_START) == 13_800_000, "Key 144 costs 13.80 USDC");
        require(presets.classicPrice(512, CLASSIC_START) == 31_590_000, "Key 512 costs 31.59 USDC");
        require(presets.classicPrice(1024, CLASSIC_START) == 100_000_000, "Key 1024 costs 100 USDC");
        vm.expectRevert(KeyfleetPresets.KeyNumberOutOfBounds.selector);
        presets.classicPrice(0, CLASSIC_START);
        vm.expectRevert(KeyfleetPresets.KeyNumberOutOfBounds.selector);
        presets.classicPrice(1025, CLASSIC_START);
    }

    /// @dev Invariant: at the founding start of 10 USDC every one of the 1024 prices is today's table
    ///      exactly: 1000 * 10^((n - 1) / 1023) cents rounded to the nearest cent. The exact price is
    ///      walked one key at a time in 36-decimal fixed point, whose error after 1023 steps is below
    ///      1e-29 of a cent, far inside the smallest distance of any key's exact price from a half
    ///      cent (about 5.2e-4 of a cent).
    function testEveryClassicPriceIsTheSteadyPercentageCurveRoundedToTheCent() public view {
        uint256 exactCents = 1000 * FIXED_ONE;
        uint256 total;
        for (uint256 keyNumber = 1; keyNumber <= KeyfleetPresets.CLASSIC_SUPPLY; ++keyNumber) {
            uint256 price = presets.classicPrice(keyNumber, CLASSIC_START);
            require(price == (exactCents + FIXED_ONE / 2) / FIXED_ONE * CENT, "Rounded to the nearest cent");
            total += price;
            if (keyNumber < KeyfleetPresets.CLASSIC_SUPPLY) exactCents = exactCents * CLASSIC_STEP / FIXED_ONE;
        }
        require(10_000 * FIXED_ONE - exactCents < 1e8, "1023 steps multiply the first price by ten");
        require(total == 40_040_480_000, "The whole fleet costs 40,040.48 USDC");
    }

    /// @dev Invariant: any other starting price multiplies the table by start / 10 USDC and rounds up
    ///      to the cent: every price is a whole number of cents, never below the exact scaled price
    ///      and less than a cent above it.
    function testClassicPricesScaleFromTheStartingPriceRoundedUpToTheCent() public view {
        uint256[6] memory starts = _starts();
        for (uint256 keyNumber = 1; keyNumber <= KeyfleetPresets.CLASSIC_SUPPLY; ++keyNumber) {
            uint256 tableAtomic = presets.classicPrice(keyNumber, CLASSIC_START);
            for (uint256 s = 0; s < starts.length; ++s) {
                uint256 price = presets.classicPrice(keyNumber, starts[s]);
                uint256 exactTimesTableStart = tableAtomic * starts[s];
                require(price % CENT == 0, "A whole number of cents");
                require(price * CLASSIC_START >= exactTimesTableStart, "Never below the exact scaled price");
                require((price - CENT) * CLASSIC_START < exactTimesTableStart, "Less than a cent above it");
            }
            require(
                presets.classicPrice(keyNumber, 20_000_000) == 2 * tableAtomic, "Twice the start is twice every price"
            );
        }
    }

    /// @dev Invariant: the scaling never moves the ends of the curve: key 1 costs exactly the starting
    ///      price and key 1024 exactly ten times it, for every starting price in whole cents.
    function testFuzzClassicFirstKeyCostsTheStartAndTheLastTenTimesIt(uint256 seed) public view {
        uint256 cents = KeyfleetPresets.MIN_START_USDC / CENT + seed
            % ((KeyfleetPresets.MAX_START_USDC - KeyfleetPresets.MIN_START_USDC) / CENT + 1);
        uint256 start = cents * CENT;
        require(presets.classicPrice(1, start) == start, "Key 1 costs the starting price");
        require(presets.classicPrice(1024, start) == 10 * start, "Key 1024 costs ten times it");
    }

    // --- 5. accelerant -------------------------------------------------------------------------

    /// @dev Invariant: at the founding start and step each primary mint costs the previous one
    ///      compounded by 1.05, rounded up. The first three figures are the ones the platform mirrors.
    function testAccelerantPriceCompoundsByOnePointZeroFivePerPrimaryMint() public view {
        require(presets.accelerantPrice(0, Q_USDC, FOUNDING_STEP) == 10_000_000, "First mint costs 10 USDC");
        require(presets.accelerantPrice(1, Q_USDC, FOUNDING_STEP) == 10_500_000, "Second mint");
        require(presets.accelerantPrice(2, Q_USDC, FOUNDING_STEP) == 11_025_000, "Third mint");
        require(presets.accelerantPrice(3, Q_USDC, FOUNDING_STEP) == 11_576_250, "Fourth mint is exact");
        require(presets.accelerantPrice(4, Q_USDC, FOUNDING_STEP) == 12_155_063, "ceil(12,155,062.5) is 12,155,063");
        require(presets.accelerantNextPrice(2, FOUNDING_STEP) == 3, "ceil(2.1) is 3");
    }

    /// @dev Invariant: a fleet's step is a whole percent from 1 to 5, and each primary mint costs that
    ///      many percent more than the one before, rounded up.
    function testAccelerantStepsRunFromOneToFivePercent() public view {
        require(KeyfleetPresets.MIN_ACCELERANT_STEP_PERCENT == 1, "The lowest step is 1%");
        require(KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT == FOUNDING_STEP, "The highest step is 5%");
        require(presets.accelerantPrice(1, Q_USDC, 1) == 10_100_000, "1% on 10 USDC");
        require(presets.accelerantPrice(2, Q_USDC, 1) == 10_201_000, "and 1% again");
        require(presets.accelerantPrice(1, Q_USDC, 3) == 10_300_000, "3% on 10 USDC");
        require(presets.accelerantNextPrice(2, 1) == 3, "ceil(2.02) is 3");
    }

    /// @dev Invariant: stepping one price at a time gives the same ladder as pricing an index
    ///      directly, from every starting price and at every step.
    function testAccelerantNextPriceMatchesPricingByIndex() public view {
        uint256[6] memory starts = _starts();
        for (uint256 step = 1; step <= FOUNDING_STEP; ++step) {
            for (uint256 s = 0; s < starts.length; ++s) {
                uint256 walked = starts[s];
                for (uint256 index = 0; index < 48; ++index) {
                    uint256 price = presets.accelerantPrice(index, starts[s], step);
                    require(price == walked, "Chained price matches indexed price");
                    require(price == _referenceAccelerantPrice(index, starts[s], step), "Price ladder");
                    walked = presets.accelerantNextPrice(walked, step);
                }
            }
        }
    }

    /// @dev Invariant: an Accelerant fleet's first key costs exactly its starting price and each
    ///      later key its step more, rounded up.
    function testAccelerantPricesStartFromTheStartingPrice() public view {
        require(presets.accelerantPrice(0, 20_000_000, 5) == 20_000_000, "Key 1 costs the starting price");
        require(presets.accelerantPrice(1, 20_000_000, 5) == 21_000_000, "Key 2 costs 5% more");
        require(presets.accelerantPrice(2, 20_000_000, 5) == 22_050_000, "Key 3 another 5%");
        require(presets.accelerantPrice(1, 10_010_000, 5) == 10_510_500, "10.01 USDC steps to 10.5105 USDC");
        require(presets.accelerantPrice(0, 20_000_000, 2) == 20_000_000, "Any step starts at the start");
        require(presets.accelerantPrice(1, 20_000_000, 2) == 20_400_000, "Key 2 costs 2% more");
    }

    /// @dev Invariant: the last of the 2000 keys prices without overflow even from the highest
    ///      starting price at the highest step, and index 2000 is rejected.
    function testAccelerantLastKeyPricesWithoutOverflowAndTwoThousandIsRejected() public {
        require(KeyfleetPresets.MAX_ACCELERANT_KEYS == 2000, "Published Accelerant supply bound");
        uint256 last = presets.accelerantPrice(1999, Q_USDC, FOUNDING_STEP);
        require(last == _referenceAccelerantPrice(1999, Q_USDC, FOUNDING_STEP), "Last key on the ladder");
        require(last < type(uint256).max / 105, "One more step would still not overflow");
        uint256 highest = presets.accelerantPrice(1999, KeyfleetPresets.MAX_START_USDC, FOUNDING_STEP);
        require(highest < type(uint256).max / 105, "Nor from the highest starting price");
        vm.expectRevert(KeyfleetPresets.MintIndexOutOfBounds.selector);
        presets.accelerantPrice(2000, Q_USDC, FOUNDING_STEP);
    }

    // --- 6. starting prices --------------------------------------------------------------------

    /// @dev Invariant: the founding fleets all start at 10 USDC, the start the Classic table is
    ///      written for, and an open fleet's starting price runs from 10 to 1,000,000 USDC.
    function testFoundingStartPricesAndOpenBounds() public pure {
        require(KeyfleetPresets.Q_USDC == Q_USDC, "Founding fleets start at 10 USDC");
        require(KeyfleetPresets.CLASSIC_START_USDC == Q_USDC, "So the founding Classic fleet is the table");
        require(KeyfleetPresets.MIN_START_USDC == 10_000_000, "Lowest open start is 10 USDC");
        require(KeyfleetPresets.MAX_START_USDC == 1_000_000_000_000, "Highest open start is 1,000,000 USDC");
        require(KeyfleetPresets.CENT_USDC == CENT, "A cent is 10,000 atomic USDC");
    }

    // --- 7. ceilDiv ------------------------------------------------------------------------------

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

    /// @dev Invariant: Syndicate and Classic send everything after the 10% protocol share to capital.
    function testSyndicateAndClassicSendEverythingAfterTheProtocolShareToCapital() public view {
        require(KeyfleetPresets.PROTOCOL_BPS == 1000, "Published protocol share");
        KeyfleetPresets.PurchaseSplit memory syndicate =
            presets.splitPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 10_000, true);
        require(syndicate.protocol == 1000, "Protocol 10%");
        require(syndicate.capital == 9000, "Capital 90%");
        require(syndicate.reserve == 0, "No reserve");
        require(syndicate.rebate == 0, "No rebate");

        KeyfleetPresets.PurchaseSplit memory classic =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechClassic, 10_000, true);
        require(classic.protocol == 1000, "Classic protocol 10%");
        require(classic.capital == 9000, "Classic capital 90%");
        require(classic.reserve == 0 && classic.rebate == 0, "Classic has no reserve or rebate");
    }

    /// @dev Invariant: Cascade sends everything after the protocol share to the level-completion reserve.
    function testCascadeSendsEverythingAfterTheProtocolShareToTheReserve() public view {
        KeyfleetPresets.PurchaseSplit memory split =
            presets.splitPurchase(KeyfleetPresets.Preset.FibonacciCascade, 10_000, false);
        require(split.protocol == 1000, "Protocol 10%");
        require(split.reserve == 9000, "Reserve 90%");
        require(split.capital == 0, "No capital");
        require(split.rebate == 0, "No rebate");
    }

    /// @dev Invariant: an Accelerant purchase with a predecessor pays capital 20% and rebates the
    ///      remaining 70%, while the very first mint sends everything after the protocol share to
    ///      capital.
    function testAccelerantRebatesThePredecessorOnlyWhenThereIsOne() public view {
        require(KeyfleetPresets.ACCELERANT_CAPITAL_BPS == 2000, "Published Accelerant capital share");
        KeyfleetPresets.PurchaseSplit memory later =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 10_000, true);
        require(later.protocol == 1000, "Protocol 10%");
        require(later.capital == 2000, "Capital 20%");
        require(later.rebate == 7000, "Rebate 70%");
        require(later.reserve == 0, "No reserve");

        KeyfleetPresets.PurchaseSplit memory dusty =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 10_009, true);
        require(dusty.protocol == 1000 && dusty.capital == 2001, "Both shares floored");
        require(dusty.rebate == 7008, "The rebate takes the dust");

        KeyfleetPresets.PurchaseSplit memory firstMint =
            presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 10_000, false);
        require(firstMint.protocol == 1000, "First mint protocol 10%");
        require(firstMint.capital == 9000, "First mint sends the other 90% to capital");
        require(firstMint.rebate == 0, "Nobody to rebate");
        require(firstMint.reserve == 0, "No reserve");
    }

    /// @dev Invariant: the four parts always sum to gross, the protocol share is always 10% floored,
    ///      reserve belongs to Cascade alone and rebate to Accelerant primary mints with a
    ///      predecessor alone.
    function testFuzzSplitAlwaysSumsToGrossAndKeepsEachPartToItsPreset(
        uint8 presetSeed,
        uint256 grossSeed,
        bool hasPredecessor
    ) public view {
        KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(presetSeed % 4);
        uint256 gross = (grossSeed % (uint256(1) << 200)) + 1;
        KeyfleetPresets.PurchaseSplit memory split = presets.splitPurchase(preset, gross, hasPredecessor);

        require(split.protocol + split.capital + split.reserve + split.rebate == gross, "Parts sum to gross");
        require(split.protocol == (gross * 1000) / BPS, "Protocol is 10% floored");

        bool isCascade = preset == KeyfleetPresets.Preset.FibonacciCascade;
        require(isCascade == (split.reserve > 0), "Reserve belongs to Cascade alone");

        bool isAccelerantWithPredecessor = preset == KeyfleetPresets.Preset.FleetTechAccelerant && hasPredecessor;
        require(
            isAccelerantWithPredecessor == (split.rebate > 0),
            "Rebate belongs to Accelerant mints with a predecessor alone"
        );
        if (isAccelerantWithPredecessor) {
            require(split.capital == (gross * 2000) / BPS, "Capital is 20% floored");
        } else if (!isCascade) {
            require(split.capital == gross - split.protocol, "Capital absorbs the dust");
        } else {
            require(split.capital == 0, "Cascade sends nothing to capital");
        }
    }

    /// @dev Invariant: a purchase of zero is rejected for every preset.
    function testZeroGrossIsRejectedForEveryPreset() public {
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 0, true);
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FibonacciCascade, 0, false);
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FleetTechClassic, 0, false);
        vm.expectRevert(KeyfleetPresets.ZeroGross.selector);
        presets.splitPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 0, true);
    }

    // --- 9. rounding direction ----------------------------------------------------------------

    /// @dev Invariant: each Fibonacci step rounds up, never down, and never by more than one unit.
    function testFibonacciStepAlwaysRoundsUpByLessThanOneUnit() public view {
        for (uint256 level = 2; level <= HIGH_LEVEL; ++level) {
            uint256 previous = presets.fibonacciLevelPrice(level - 1, Q_USDC);
            uint256 current = presets.fibonacciLevelPrice(level, Q_USDC);
            require(current * 100 >= previous * 120, "Never rounds down");
            require(current * 100 - previous * 120 < 100, "Never rounds up by a whole unit");
        }
    }
}
