# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Writes the Keyfleet Classic key prices, the one source both the contract and the site read.

Key n of 1,024 costs 8 USDC times 10^((n - 1) / 1023), rounded to the nearest cent: key 1 costs
exactly 8.00 USDC, key 1,024 exactly 80.00 USDC, and each key the same percentage more than the
one before. The prices are worked out here to 60 significant digits and written as whole cents to:

- contracts/src/KeyfleetClassicPrices.sol, a table of 1,024 two-byte big-endian cent values;
- platform/priv/classic_key_prices.txt, one cent value per line, key 1 first.

Run from anywhere with `uv run scripts/classic_prices.py`.
"""

from decimal import ROUND_HALF_UP, Decimal, getcontext
from pathlib import Path

SUPPLY = 1024
FIRST_CENTS = 800
LAST_CENTS = 8000

ROOT = Path(__file__).resolve().parent.parent
SOLIDITY = ROOT / "contracts/src/KeyfleetClassicPrices.sol"
SITE = ROOT / "platform/priv/classic_key_prices.txt"


def exact_cents(key: int) -> Decimal:
    ratio = Decimal(LAST_CENTS) / Decimal(FIRST_CENTS)
    return Decimal(FIRST_CENTS) * ratio ** (Decimal(key - 1) / Decimal(SUPPLY - 1))


def prices() -> list[int]:
    getcontext().prec = 60
    cents = []
    for key in range(1, SUPPLY + 1):
        exact = exact_cents(key)
        rounded = exact.quantize(Decimal(1), rounding=ROUND_HALF_UP)
        # No key sits within a billionth of a cent of a half cent, so every reading of the formula
        # with ordinary double precision rounds to the same cent.
        assert key in (1, SUPPLY) or abs(abs(exact - rounded) - Decimal("0.5")) > Decimal("1e-9"), key
        cents.append(int(rounded))
    assert cents[0] == FIRST_CENTS and cents[-1] == LAST_CENTS
    return cents


def solidity(cents: list[int]) -> str:
    table = "".join(f"{value:04x}" for value in cents)
    return f"""// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The price of every Fleet.Tech Classic key, in whole US cents.
/// @dev Written by `scripts/classic_prices.py`; change the script, never this file. Key n of
///      {SUPPLY:,} costs 800 * 10^((n - 1) / 1023) cents, rounded to the nearest cent, and is the
///      big-endian two-byte value at byte offset 2 * (n - 1) of `CENTS`.
library KeyfleetClassicPrices {{
    bytes internal constant CENTS =
        hex"{table}";
}}
"""


def main() -> None:
    cents = prices()
    SOLIDITY.write_text(solidity(cents))
    SITE.write_text("".join(f"{value}\n" for value in cents))
    total = sum(cents)
    print(f"{SUPPLY} keys: first {cents[0] / 100:.2f}, key 144 {cents[143] / 100:.2f}, "
          f"key 512 {cents[511] / 100:.2f}, last {cents[-1] / 100:.2f}, all {total / 100:,.2f} USDC")


if __name__ == "__main__":
    main()
