// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Supply, price, holding-limit and purchase-split arithmetic for the four fleet presets.
/// @dev Pure arithmetic only: no storage, no tokens, no external calls. Every constant here is part of
///      the published product contract and is reproduced in the deployment manifest. All arithmetic is
///      checked; the bounds below keep every intermediate product far inside 256 bits.
///
///      Every price here is in atomic USDC, millionths of one USDC, and is what a fleet charges.
library KeyfleetPresets {
    /// @notice The four fleet presets.
    enum Preset {
        FibonacciSyndicate,
        FibonacciCascade,
        FleetTechClassic,
        FleetTechAccelerant
    }

    /// @notice How a single gross purchase amount is divided. The five parts always sum to gross.
    /// @param protocol Protocol share for the Regents staking contract, taken on every purchase.
    /// @param referral Referrer share, zero when no referrer is supplied.
    /// @param capital Fleet capital share.
    /// @param reserve Level-completion reserve, used by Fibonacci Cascade only.
    /// @param rebate Share paid to the holder of the preceding key, used by Accelerant primary mints after the first only.
    struct PurchaseSplit {
        uint256 protocol;
        uint256 referral;
        uint256 capital;
        uint256 reserve;
        uint256 rebate;
    }

    /// @notice Fibonacci level is rejected outside `1 <= level <= MAX_FIBONACCI_LEVEL`.
    error LevelOutOfBounds();
    /// @notice Fibonacci token id is rejected outside `1 <= tokenId <= FIBONACCI_MAX_TOKEN_ID`.
    error TokenIdOutOfBounds();
    /// @notice Accelerant mint index is rejected at or above `MAX_ACCELERANT_KEYS`.
    error MintIndexOutOfBounds();
    /// @notice A purchase of zero is rejected.
    error ZeroGross();
    /// @notice Division by zero in `ceilDiv`.
    error ZeroDenominator();

    /// @notice The reference price Q, 10 USDC, in atomic USDC.
    uint256 internal constant Q_USDC = 10_000_000;
    /// @notice The decimals `Q_USDC` is written in. A fleet refuses a USDC reporting any other.
    uint8 internal constant USDC_DECIMALS = 6;

    /// @notice Highest Fibonacci level, whose supply is 17711 keys.
    uint256 internal constant MAX_FIBONACCI_LEVEL = 20;
    /// @notice Cumulative Fibonacci supply through `MAX_FIBONACCI_LEVEL`, and so the highest token id.
    uint256 internal constant FIBONACCI_MAX_TOKEN_ID = 46_365;
    /// @notice Highest level whose per-wallet holding limit is a single key.
    uint256 internal constant FIBONACCI_SINGLE_KEY_MAX_LEVEL = 7;
    /// @notice Above `FIBONACCI_SINGLE_KEY_MAX_LEVEL` the holding limit is the level supply over this divisor.
    uint256 internal constant FIBONACCI_HOLDING_DIVISOR = 10;
    /// @notice Each Fibonacci level costs the previous level times 120/100, rounded up.
    uint256 internal constant FIBONACCI_STEP_NUMERATOR = 120;
    uint256 internal constant FIBONACCI_STEP_DENOMINATOR = 100;

    /// @notice Fleet.Tech Classic key supply.
    uint256 internal constant CLASSIC_SUPPLY = 144;

    /// @notice Highest number of Fleet.Tech Accelerant keys, so valid mint indexes are 0..1999.
    uint256 internal constant MAX_ACCELERANT_KEYS = 2000;
    /// @notice Each Accelerant primary mint costs the previous primary mint times 105/100, rounded up.
    uint256 internal constant ACCELERANT_STEP_NUMERATOR = 105;
    uint256 internal constant ACCELERANT_STEP_DENOMINATOR = 100;

    /// @notice Protocol share of gross for the Regents staking contract, in basis points.
    uint256 internal constant PROTOCOL_BPS = 500;
    /// @notice Referrer share of gross, in basis points, applied only when a referrer is supplied.
    uint256 internal constant REFERRAL_BPS = 1000;
    /// @notice Capital share of gross on Accelerant purchases with a predecessor, in basis points.
    uint256 internal constant ACCELERANT_CAPITAL_BPS = 1000;
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

    /// @notice First token id of a Fibonacci level. Token ids are 1-based and contiguous across levels.
    function fibonacciLevelStart(uint256 level) internal pure returns (uint256) {
        _requireLevel(level);
        if (level == 1) return 1;
        return fibonacciTotalSupplyThrough(level - 1) + 1;
    }

    /// @notice Last token id of a Fibonacci level.
    function fibonacciLevelEnd(uint256 level) internal pure returns (uint256) {
        return fibonacciTotalSupplyThrough(level);
    }

    /// @notice Level that owns a Fibonacci token id.
    function fibonacciLevelOf(uint256 tokenId) internal pure returns (uint256) {
        if (tokenId == 0 || tokenId > FIBONACCI_MAX_TOKEN_ID) revert TokenIdOutOfBounds();
        uint256 previous = 1;
        uint256 current = 2;
        uint256 cumulative = 2;
        uint256 level = 1;
        while (tokenId > cumulative) {
            (previous, current) = (current, previous + current);
            cumulative += current;
            ++level;
        }
        return level;
    }

    /// @notice USDC price of a Fibonacci level key. Level 1 costs exactly `Q_USDC`; every further level
    ///         compounds the previous level's price by 120/100 with upward rounding at each step.
    /// @dev Computed iteratively from level 1, never as a closed-form power, so the rounding is exact.
    function fibonacciLevelPrice(uint256 level) internal pure returns (uint256) {
        _requireLevel(level);
        uint256 price = Q_USDC;
        for (uint256 i = 1; i < level; ++i) {
            price = ceilDiv(price * FIBONACCI_STEP_NUMERATOR, FIBONACCI_STEP_DENOMINATOR);
        }
        return price;
    }

    /// @notice Keys of one Fibonacci level a single wallet may hold: one below level 8, a tenth of the
    ///         level supply from level 8 up.
    /// @dev The fleet contract applies this on mint and on incoming transfer; the library only computes it.
    function fibonacciHoldingLimit(uint256 level) internal pure returns (uint256) {
        _requireLevel(level);
        if (level <= FIBONACCI_SINGLE_KEY_MAX_LEVEL) return 1;
        return fibonacciLevelSupply(level) / FIBONACCI_HOLDING_DIVISOR;
    }

    /// @notice USDC price of any Fleet.Tech Classic primary key, which is the reference price itself.
    function classicPrice() internal pure returns (uint256) {
        return Q_USDC;
    }

    /// @notice USDC price of the Accelerant primary mint after one priced at `previousPrice`.
    function accelerantNextPrice(uint256 previousPrice) internal pure returns (uint256) {
        return ceilDiv(previousPrice * ACCELERANT_STEP_NUMERATOR, ACCELERANT_STEP_DENOMINATOR);
    }

    /// @notice USDC price of the Accelerant primary mint at `mintIndex`, where index 0 is the first
    ///         mint and costs `Q_USDC`.
    /// @dev Only primary mints advance the price. Secondary sales of an Accelerant key never advance it,
    ///      so the fleet contract must count primary mints, not transfers, when choosing `mintIndex`.
    ///      The cost is linear in `mintIndex` (about 950k gas at index 1999), so a fleet contract must
    ///      persist its current price and step it with `accelerantNextPrice`, enforcing
    ///      `MAX_ACCELERANT_KEYS` itself; this function is for one-off quotes and views.
    function accelerantPrice(uint256 mintIndex) internal pure returns (uint256) {
        if (mintIndex >= MAX_ACCELERANT_KEYS) revert MintIndexOutOfBounds();
        uint256 price = Q_USDC;
        for (uint256 i = 0; i < mintIndex; ++i) {
            price = accelerantNextPrice(price);
        }
        return price;
    }

    /// @notice Divides a gross purchase into its parts. Each fee is floored and the preset's main part
    ///         absorbs the dust, so the five parts always sum to exactly `gross`.
    /// @param preset The fleet preset being purchased from.
    /// @param gross The USDC purchase amount, which must be nonzero.
    /// @param hasReferrer Whether a referrer is supplied; without one nothing is deducted for referral.
    /// @param hasPredecessor Whether an Accelerant purchase has a preceding key; ignored by other presets.
    function splitPurchase(Preset preset, uint256 gross, bool hasReferrer, bool hasPredecessor)
        internal
        pure
        returns (PurchaseSplit memory split)
    {
        if (gross == 0) revert ZeroGross();
        split.protocol = (gross * PROTOCOL_BPS) / BPS_DENOMINATOR;
        split.referral = hasReferrer ? (gross * REFERRAL_BPS) / BPS_DENOMINATOR : 0;
        uint256 remainder = gross - split.protocol - split.referral;

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
        if (level == 0 || level > MAX_FIBONACCI_LEVEL) revert LevelOutOfBounds();
    }
}
