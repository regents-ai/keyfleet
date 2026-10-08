// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetClassicPrices} from "./KeyfleetClassicPrices.sol";

/// @notice Supply, price and purchase-split arithmetic for the fleet presets.
/// @dev Pure arithmetic only: no storage, no tokens, no external calls. Every constant here is part of
///      the published product contract and is reproduced in the deployment manifest. All arithmetic is
///      checked. The two Fibonacci presets have no last level: supply and price carry on by the same rule
///      for ever, and a level or key number so large that its arithmetic would leave 256 bits reverts. No
///      fleet can reach one: a level's price passes a billion USDC at level 103, while the Fibonacci
///      sums first leave 256 bits at level 367.
///
///      Every price here is in atomic USDC, millionths of one USDC, and is what a fleet charges. Every
///      price is scaled from the fleet's starting price, the price of its first key: the Fibonacci and
///      Accelerant ladders start from it, and the Classic table is multiplied by it over
///      `CLASSIC_START_USDC`. The four sold founding fleets start at `Q_USDC`, which gives exactly the
///      prices the fleets were designed with. An Accelerant fleet also has its own step, the whole
///      percent each primary mint costs more than the one before, from 1% to 5%; the founding
///      Accelerant fleet's is 5%. The Regents Club fleet is never sold: its keys are given, one per
///      Regents Club Pass, so it has a supply and no price.
library KeyfleetPresets {
    /// @notice The fleet presets. `RegentsClub` is the fifth founding fleet's alone.
    enum Preset {
        FibonacciSyndicate,
        FibonacciCascade,
        FleetTechClassic,
        FleetTechAccelerant,
        RegentsClub
    }

    /// @notice How a single gross purchase amount is divided. The four parts always sum to gross.
    /// @param protocol Protocol share for REGENT revenue staking, taken once on every purchase.
    /// @param capital Share that goes to the fleet's treasury.
    /// @param reserve Level-completion reserve, used by Fibonacci Cascade only.
    /// @param rebate Share paid to the holder of the preceding key, used by Accelerant primary mints after the first only.
    struct PurchaseSplit {
        uint256 protocol;
        uint256 capital;
        uint256 reserve;
        uint256 rebate;
    }

    /// @notice Fibonacci level zero is rejected; levels start at 1.
    error LevelOutOfBounds();
    /// @notice Key number is rejected outside the preset's range: zero for Fibonacci, and outside
    ///         `1 <= keyNumber <= CLASSIC_SUPPLY` for Classic.
    error KeyNumberOutOfBounds();
    /// @notice Accelerant mint index is rejected at or above `MAX_ACCELERANT_KEYS`.
    error MintIndexOutOfBounds();
    /// @notice A purchase of zero is rejected.
    error ZeroGross();
    /// @notice Division by zero in `ceilDiv`.
    error ZeroDenominator();

    /// @notice The reference price Q, 10 USDC, in atomic USDC: the starting price of every founding
    ///         fleet.
    uint256 internal constant Q_USDC = 10_000_000;
    /// @notice The first key of the Classic table, 10 USDC: the price the table is written for.
    uint256 internal constant CLASSIC_START_USDC = 10_000_000;
    /// @notice The lowest starting price a fleet anyone creates may set: 10 USDC.
    uint256 internal constant MIN_START_USDC = 10_000_000;
    /// @notice The highest starting price a fleet anyone creates may set: 1,000,000 USDC.
    uint256 internal constant MAX_START_USDC = 1_000_000_000_000;
    /// @notice The decimals `Q_USDC` is written in. A fleet refuses a USDC reporting any other.
    uint8 internal constant USDC_DECIMALS = 6;

    /// @notice Each Fibonacci level costs the previous level times 120/100, rounded up.
    uint256 internal constant FIBONACCI_STEP_NUMERATOR = 120;
    uint256 internal constant FIBONACCI_STEP_DENOMINATOR = 100;

    /// @notice Fleet.Tech Classic key supply.
    uint256 internal constant CLASSIC_SUPPLY = 1024;
    /// @notice Regents Club key supply: one key for each of the 1,998 Regents Club Passes.
    uint256 internal constant CLUB_SUPPLY = 1998;
    /// @notice One US cent in atomic USDC. Every Classic price is a whole number of cents.
    uint256 internal constant CENT_USDC = 10_000;

    /// @notice Highest number of Fleet.Tech Accelerant keys, so valid mint indexes are 0..1999.
    uint256 internal constant MAX_ACCELERANT_KEYS = 2000;
    /// @notice The lowest Accelerant step: each primary mint at least 1% dearer than the one before.
    uint256 internal constant MIN_ACCELERANT_STEP_PERCENT = 1;
    /// @notice The highest Accelerant step, 5%, which is also the founding Accelerant fleet's.
    uint256 internal constant MAX_ACCELERANT_STEP_PERCENT = 5;

    /// @notice Protocol share of gross for REGENT revenue staking, in basis points: 10%.
    uint256 internal constant PROTOCOL_BPS = 1000;
    /// @notice Capital share of gross on Accelerant purchases with a predecessor, in basis points: 20%.
    uint256 internal constant ACCELERANT_CAPITAL_BPS = 2000;
    /// @notice Basis-point denominator.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Divides `a` by `b`, rounding up.
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert ZeroDenominator();
        if (a == 0) return 0;
        return (a - 1) / b + 1;
    }

    /// @notice Key supply of a Fibonacci level: 2, 3, 5, 8, 13, ... each level the sum of the two before it.
    function fibonacciLevelSupply(uint256 level) internal pure returns (uint256) {
        _requireLevel(level);
        uint256 previous = 1;
        uint256 current = 2;
        for (uint256 i = 1; i < level; ++i) {
            (previous, current) = (current, previous + current);
        }
        return current;
    }

    /// @notice Cumulative Fibonacci key supply of levels 1 through `level`.
    function fibonacciTotalSupplyThrough(uint256 level) internal pure returns (uint256) {
        _requireLevel(level);
        uint256 previous = 1;
        uint256 current = 2;
        uint256 total = 2;
        for (uint256 i = 1; i < level; ++i) {
            (previous, current) = (current, previous + current);
            total += current;
        }
        return total;
    }

    /// @notice First key number of a Fibonacci level. Key numbers are 1-based and contiguous across levels.
    function fibonacciLevelStart(uint256 level) internal pure returns (uint256) {
        _requireLevel(level);
        if (level == 1) return 1;
        return fibonacciTotalSupplyThrough(level - 1) + 1;
    }

    /// @notice Last key number of a Fibonacci level.
    function fibonacciLevelEnd(uint256 level) internal pure returns (uint256) {
        return fibonacciTotalSupplyThrough(level);
    }

    /// @notice Level that owns a Fibonacci key number.
    function fibonacciLevelOf(uint256 keyNumber) internal pure returns (uint256) {
        if (keyNumber == 0) revert KeyNumberOutOfBounds();
        uint256 previous = 1;
        uint256 current = 2;
        uint256 cumulative = 2;
        uint256 level = 1;
        while (keyNumber > cumulative) {
            (previous, current) = (current, previous + current);
            cumulative += current;
            ++level;
        }
        return level;
    }

    /// @notice USDC price of a Fibonacci level key. Level 1 costs exactly `start`; every further level
    ///         compounds the previous level's price by 120/100 with upward rounding at each step.
    /// @dev Computed iteratively from level 1, never as a closed-form power, so the rounding is exact.
    function fibonacciLevelPrice(uint256 level, uint256 start) internal pure returns (uint256) {
        _requireLevel(level);
        uint256 price = start;
        for (uint256 i = 1; i < level; ++i) {
            price = ceilDiv(price * FIBONACCI_STEP_NUMERATOR, FIBONACCI_STEP_DENOMINATOR);
        }
        return price;
    }

    /// @notice USDC price of Fleet.Tech Classic key `keyNumber` in a fleet starting at `start`: the
    ///         table's price, 10 USDC for key 1 to 100 USDC for key 1024 with each key the same
    ///         percentage dearer than the one before, multiplied by `start / CLASSIC_START_USDC` and
    ///         rounded up to the cent. At `start` 10 USDC that is the table itself.
    /// @dev Read from the generated cent table in `KeyfleetClassicPrices`, the same table the site reads.
    function classicPrice(uint256 keyNumber, uint256 start) internal pure returns (uint256) {
        if (keyNumber == 0 || keyNumber > CLASSIC_SUPPLY) revert KeyNumberOutOfBounds();
        bytes memory cents = KeyfleetClassicPrices.CENTS;
        uint256 offset = 2 * (keyNumber - 1);
        uint256 tableCents = (uint256(uint8(cents[offset])) << 8) | uint8(cents[offset + 1]);
        return ceilDiv(tableCents * start, CLASSIC_START_USDC) * CENT_USDC;
    }

    /// @notice USDC price of the Accelerant primary mint after one priced at `previousPrice`, in a
    ///         fleet whose step is `stepPercent`: `stepPercent` percent dearer, rounded up.
    function accelerantNextPrice(uint256 previousPrice, uint256 stepPercent) internal pure returns (uint256) {
        return ceilDiv(previousPrice * (100 + stepPercent), 100);
    }

    /// @notice USDC price of the Accelerant primary mint at `mintIndex`, where index 0 is the first
    ///         mint and costs `start`, in a fleet whose step is `stepPercent`.
    /// @dev Only primary mints advance the price. Secondary sales of an Accelerant key never advance it,
    ///      so the fleet contract must count primary mints, not transfers, when choosing `mintIndex`.
    ///      The cost is linear in `mintIndex` (about 950k gas at index 1999), so a fleet contract must
    ///      persist its current price and step it with `accelerantNextPrice`, enforcing
    ///      `MAX_ACCELERANT_KEYS` itself; this function is for one-off quotes and views.
    function accelerantPrice(uint256 mintIndex, uint256 start, uint256 stepPercent) internal pure returns (uint256) {
        if (mintIndex >= MAX_ACCELERANT_KEYS) revert MintIndexOutOfBounds();
        uint256 price = start;
        for (uint256 i = 0; i < mintIndex; ++i) {
            price = accelerantNextPrice(price, stepPercent);
        }
        return price;
    }

    /// @notice Divides a gross purchase into its parts. Each floored share leaves its dust in the
    ///         preset's main part, so the four parts always sum to exactly `gross`.
    /// @param preset The fleet preset being purchased from.
    /// @param gross The USDC purchase amount, which must be nonzero.
    /// @param hasPredecessor Whether an Accelerant purchase has a preceding key; ignored by other presets.
    function splitPurchase(Preset preset, uint256 gross, bool hasPredecessor)
        internal
        pure
        returns (PurchaseSplit memory split)
    {
        if (gross == 0) revert ZeroGross();
        split.protocol = (gross * PROTOCOL_BPS) / BPS_DENOMINATOR;
        uint256 remainder = gross - split.protocol;

        if (preset == Preset.FibonacciCascade) {
            split.reserve = remainder;
        } else if (preset == Preset.FleetTechAccelerant && hasPredecessor) {
            split.capital = (gross * ACCELERANT_CAPITAL_BPS) / BPS_DENOMINATOR;
            split.rebate = remainder - split.capital;
        } else {
            split.capital = remainder;
        }
    }

    function _requireLevel(uint256 level) private pure {
        if (level == 0) revert LevelOutOfBounds();
    }
}
