# Contracts

A dependency-free Foundry workspace pinned to Solidity 0.8.26.

`KeyfleetAssetRegistry` is shared by fleets. Its constructor permanently binds
`REGENT_SAFE` and `BASE_USDC` to nonzero addresses supplied at construction. The
caller must supply the intended Safe contract and canonical Base USDC address;
the registry does not verify their identity or chain. Neither address receives
implicit token approval.

Only calls from `REGENT_SAFE` can change the factory-wide or fleet-specific token
flags. Individual Safe owners have no direct authority. `isTokenAllowed(fleet,
token)` requires both flags and rejects zero addresses. Each setter emits its
scope, affected addresses, and new flag value, including repeated assignments.
Disabling one scope leaves the other scope unchanged.

This registry controls new deposit admission only. It holds no deposit accounting
or claim history and cannot transfer tokens or spend fleet funds. Fleet contracts
must consult it when accepting deposits; those contracts are outside this slice.
There is no administrator transfer, upgrade path, or deployment script.

`KeyfleetPresets` is a pure internal library and the single source of truth for
the supply, price, holding-limit and purchase-split arithmetic of the four
presets: `FibonacciSyndicate`, `FibonacciCascade`, `FleetTechClassic` and
`FleetTechAccelerant`. It has no storage, holds no tokens, and makes no external
calls. Every function is `internal pure` with checked arithmetic. Fleet contracts
that hold state are outside this slice.

Prices are derived from a reference price `q` in atomic REGENT units, accepted
only within `1 <= q <= MAX_Q` where `MAX_Q` is `1e24`; anything outside reverts.
Both ladders are computed iteratively from the first step, never as a closed-form
power, and every step rounds up:

- Fibonacci level price: level 1 costs `q`, and each further level costs
  `ceilDiv(previous * 120, 100)`. `MAX_FIBONACCI_LEVEL` is 20.
- Accelerant primary price: the first mint costs `q`, and each further mint costs
  `ceilDiv(previous * 105, 100)`. `MAX_ACCELERANT_KEYS` is 2000, so mint indexes
  run 0 through 1999. Only primary mints advance the price; secondary sales do
  not, so the caller must count primary mints when choosing a mint index.
- Fleet.Tech Classic: `CLASSIC_SUPPLY` is 144 and every primary key costs `q`.

At those bounds the largest intermediate product stays far inside 256 bits, which
the tests assert directly at level 20 and at Accelerant index 1999.

Fibonacci level supplies are 2, 3, 5, 8, 13, ... through 17711 at level 20. Token
ids are 1-based and contiguous across levels, so `FIBONACCI_MAX_TOKEN_ID` is the
cumulative supply through level 20, 46365. The per-wallet holding limit is one key
for levels 1 through 7 and the level supply divided by 10, rounded down, from
level 8 up.

Purchase splits are stated in basis points of gross: `PROTOCOL_BPS` 500 to the
Regents treasury on every purchase, `REFERRAL_BPS` 1000 charged only when a
referrer is supplied, and `ACCELERANT_CAPITAL_BPS` 1000 on Accelerant purchases
that have a predecessor. Each fee is rounded down and the preset's main part
absorbs the dust, so the five parts always sum to exactly the gross amount.
Syndicate and Classic send the remainder to capital, Cascade sends it to the
level-completion reserve, an Accelerant purchase with a predecessor pays capital
its 10% and rebates the rest to the holder of the preceding key, and the first
Accelerant mint sends the remainder to capital. A gross amount of zero reverts.

Run `make check-contracts` from the repository root to check formatting, build,
and run the focused authorization, admission and preset-arithmetic tests. Foundry
must be installed; the compiler may be downloaded on first use. Tests require no
RPC or external Solidity libraries.
