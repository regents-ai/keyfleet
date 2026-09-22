# Contracts

An optional Foundry workspace. It is empty: KeyFleet ships no Solidity, and
`make check-contracts` only says so.

When the product needs contracts, run `forge init --no-git --force .` here,
commit the project, and replace the `check-contracts` target in the root
Makefile with `cd contracts && forge fmt --check && forge build && forge test`.
The `.gitignore` already covers Foundry's `out/`, `cache/` and dry-run
broadcasts.
