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

Run `make check-contracts` from the repository root to check formatting, build, and
run the focused authorization and admission tests. Foundry must be installed;
the compiler may be downloaded on first use. Tests require no RPC or external
Solidity libraries.
