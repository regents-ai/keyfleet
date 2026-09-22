# Deploying the four fleets

A release is deployed in two steps.

1. **Deploy.** `DeployKeyfleets` deploys the shared asset registry, the four
   fixed fleets in their fixed order, and the directory that names them. It
   writes no file of its own.
2. **Record.** After the deployment has been broadcast, `RecordKeyfleets` reads
   the release back from the chain, checks every value against the manifest, and
   only then writes the published deployment manifest.

The steps are separate because Forge runs a script in full, locally, before it
broadcasts anything. A file written by the deployment step would be written by
a dry run too, and by a broadcast that failed partway, naming contracts that do
not exist. The record step runs only against what the chain actually holds.

Each fleet deploys its own reward ledger and voting controller inside its own
constructor, so there is no step in which a fleet exists without them and no
step in which a fleet could be pointed at someone else's.

Everything the deployment decides is in one file. `contracts/deployments/base.json`
is the Base input and `contracts/deployments/anvil.json` is the lab input. Nothing
else configures a deployment: there is no environment variable other than the
name of the manifest, and no value either step invents for itself.

## What a manifest says

| Key | What it fixes |
| --- | --- |
| `chainId` | The only chain this manifest may be deployed to or recorded on. |
| `regent` | The REGENT token, listed among the deposit assets the Safe is to admit. No fleet holds it. Must hold code; on Base must be `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`. |
| `usdc` | The USDC every key is paid in. On Base must be `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`; a fleet refuses a USDC that is not its registry's or does not report six decimals. |
| `treasury` | Where the 2% fee on deposits of any asset other than USDC goes. |
| `staking` | The Regents revenue staking contract. It registers the 2% USDC deposit fee and the 5% protocol share of every purchase as revenue, credits REGENT stakers their staked share and keeps the rest as treasury residual. |
| `regentSafe` | The Safe that administers deposit admission. |
| `autolaunchFactory` | The one Autolaunch factory the fleets may ever launch through. |
| `assetRegistry` | An existing shared registry, or zero to deploy one with the release. |
| `autolaunchFactoryMayBeEmpty` | Whether the factory may still be undeployed. Ignored on Base. |
| `votingWindow` | Seconds a proposal stays open. 86,400 on both manifests. |
| `fleets.*` | Per fleet: ERC-721 `name`, `symbol` and `baseTokenURI`. |

The key price is not a manifest value: it is fixed in the contracts (see D6).
Each fleet carries its own `baseTokenURI`: all four mint token ids from 1, so a
single shared base would make `tokenURI` ambiguous across the release.

Every address in the two manifests is recorded, not derived. The Autolaunch
factory address is the one the rehearsed ceremony predicts and is replaced by the
deployed manifest of that ceremony once it has run.

## Running it

All commands run from `contracts/`. Both steps take the same
`KEYFLEET_MANIFEST` and the same RPC. For the anvil manifest, `RPC_URL` is one of
the Base forks under Rehearsing: the manifest names Base's own USDC and REGENT,
and a plain `anvil` without a fork holds neither, so the deployment is refused.

```sh
cd contracts

# Step 1, simulated. Sends nothing, needs no signer, and writes no deployment file.
KEYFLEET_MANIFEST=anvil forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$RPC_URL"

# Step 1, deployed.
KEYFLEET_MANIFEST=anvil forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$RPC_URL" --broadcast --unlocked --sender <lab account>

# Step 2, once the broadcast has finished.
KEYFLEET_MANIFEST=anvil forge script script/RecordKeyfleets.s.sol:RecordKeyfleets \
  --rpc-url "$RPC_URL"
```

A simulation leaves Forge's own transaction log under
`broadcast/DeployKeyfleets.s.sol/<chainId>/dry-run/`, which git ignores. A
broadcast writes `broadcast/DeployKeyfleets.s.sol/<chainId>/run-latest.json`,
which is what the record step reads.

Base is the same pair of commands with the Base manifest and a signer that
keeps its key in hardware:

```sh
KEYFLEET_MANIFEST=base forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address> --broadcast --verify

KEYFLEET_MANIFEST=base forge script script/RecordKeyfleets.s.sol:RecordKeyfleets \
  --rpc-url "$BASE_RPC_URL"
```

`--verify` wants an explorer API key in `ETHERSCAN_API_KEY`; leave the flag off
and verify afterwards if there is none to hand. The record step sends nothing
and needs no signer.

No private key goes in a file, an environment variable or a command line.
Neither step reads one: they read the manifest and the chain, and signing is
entirely the caller's business. The deployer receives no authority anywhere in
the release — no spending, no moderation, no admission, no vote — so the
deploying address matters only for paying gas.

## Rehearsing

There are two places to rehearse, and they rehearse different things.

Every purchase is paid in Base USDC, so a rehearsal that buys keys runs on a fork
of Base, where the real USDC exists, and funds the buying wallet from an address
that already holds USDC on the fork.

**A plain Base fork, for the Base manifest.**

```sh
anvil --fork-url "$BASE_RPC_URL" --gas-limit 100000000
```

This keeps Base's chain id, 8453, so the Base manifest deploys and records there
exactly as it would on Base, against the real REGENT, USDC, staking contract and
Safe. It also applies Base's rule that the Autolaunch factory must already hold
code: until the Autolaunch ceremony has run on Base, the deployment step refuses
on the fork just as it would on Base. A fork rehearsal writes
`broadcast/DeployKeyfleets.s.sol/8453/` and `deployments/base.deployed.json`;
delete both before the real deployment, so neither the record step nor anyone
reading the repository mistakes the rehearsal for the release. Git keeps both
paths on purpose: the Base broadcast log and `base.deployed.json` are the
evidence of the real deployment and are committed with it, while everything a
chain-31337 lab rehearsal writes is ignored.

**The Autolaunch Base lab, for the anvil manifest.** The lab in the Autolaunch
worktree is started from `contracts/v1` with
`REGENT_BASE_RPC_URL=<Base RPC> python3 bin/local-base-lab.py start`, optionally
with `--fork-block <block>`. It takes no other option: it always runs on chain id
31337, picks its own port and prints the RPC URL to use. It deploys its own
Autolaunch factory at a fresh address, so the factory address in `anvil.json`
holds no code there. The anvil manifest permits that, which means fleets
deployed to the lab are pinned to an address with no factory behind it and can
never launch. The lab rehearses deployment, recording, purchases and votes; it
cannot rehearse an Autolaunch. It starts anvil without a gas limit of its own, so
blocks keep the forked Base block's gas limit. Its `fund` command hands out
REGENT only; a wallet gets USDC for a purchase the same way as on the plain fork
below.

**A plain fork on chain 31337, for the anvil manifest without the lab.**

```sh
anvil --fork-url "$BASE_RPC_URL" --chain-id 31337 --gas-limit 100000000
export RPC_URL=http://127.0.0.1:8545

# USDC for a purchase, from a fork address that holds it. Amounts are atomic
# USDC: 10000000 is 10 USDC, the price of the first key of every fleet.
cast rpc anvil_impersonateAccount <address holding USDC> --rpc-url "$RPC_URL"
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "transfer(address,uint256)" \
  <wallet> <atomic USDC> --from <address holding USDC> --unlocked --rpc-url "$RPC_URL"
cast rpc anvil_stopImpersonatingAccount <address holding USDC> --rpc-url "$RPC_URL"
```

Buy with a fresh address on either fork, not one of anvil's default accounts:
on a Base fork account 1 carries delegated code whose NFT callback reverts, so a
key minted to it fails.

REGENT, USDC and the staking contract are Base's own on either fork; the
Autolaunch factory has no code on this one either. The deployment comes to about
32.6 million gas in all, each fleet about 8.0 million of it, or about 10.4
million at Forge's default 130% gas estimate. `--gas-limit 100000000` holds the
whole deployment in one block; at anvil's default block gas limit the broadcast
has stalled with the last fleet still pending.

## What the deployment step refuses

- A manifest whose `chainId` is not the chain it is running on.
- On Base, a `usdc` other than Base USDC
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, or a `regent` other than Base
  REGENT `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`. Every key price is written
  in six-decimal USDC, so a look-alike with other decimals would misprice every
  key.
- On any chain, a `regent` address that holds no code, the zero address included.
- An Autolaunch factory address that holds no code. A lab manifest may waive this
  with `"autolaunchFactoryMayBeEmpty": true`; the waiver is ignored on Base, and
  the deployed manifest records that a waiver was in force so a lab deployment is
  never mistaken for a production one.
- A supplied `assetRegistry` bound to a different Safe than the manifest names.
- A USDC address that is not the one the registry is bound to, or that does not
  report six decimals, both of which the fleet itself refuses at construction.
- A set of fleets the directory will not name: a fleet in the wrong slot, or one
  whose treasury, asset registry, staking contract, Autolaunch factory or voting
  window differs from the others. USDC is compared through the registry, since a
  fleet accepts only its registry's USDC.

## What the record step refuses

- A broadcast with a transaction that has no receipt, or a receipt that did not
  succeed.
- A broadcast that created no directory, or a directory with no code on the
  chain it is run against.
- The same chain, USDC, REGENT and Autolaunch factory refusals as the deployment
  step.
- Any value that differs from the manifest, read back from the chain: the
  asset registry, its Safe and its USDC, the treasury, the staking contract,
  the Autolaunch factory and the voting window, and for each fleet its name,
  symbol and metadata base. The directory only accepts four fleets of the right
  presets that share one registry, treasury, staking contract, factory and voting
  window, so those shared values are read once. REGENT is held by no fleet, so it
  is published as the manifest names it, once the refusals above have passed.

## What the record step writes

`contracts/deployments/<name>.deployed.json`, the published deployment manifest.
Every address, every fleet value, the vote window, the deposit fee and the reward
ledger's bounds are read from the chain, not copied from the input. The supply,
price and split constants come from the `KeyfleetPresets` library the record
step was compiled with; the code hash of the directory and of each fleet is
recorded so anyone can check later that the deployed code is the code those
constants came from. It carries:

- the chain and the deployment block — the lowest block any deployment
  transaction landed in, so a reader starting there misses no purchase made the
  moment a fleet appeared;
- the directory and its code hash, the registry, and the four fleets with each
  one's code hash, reward ledger, voting controller, name, symbol, metadata base
  and supply;
- REGENT, USDC, `qUsdc` — the first key's price, 10000000 atomic USDC, which is
  10 USDC — the treasury, the staking contract and the Regents Safe;
- the numeric bounds, the fee basis points and the fixed vote window;
- the Autolaunch binding: the ABI name `RegentsAutolaunchFactoryV1`, the factory
  and the strategy it publishes, and the code hash of each, so the binding can be
  checked against the Autolaunch ceremony's own manifest, and whether the lab
  waiver for a missing factory applied, which is never the case on Base;
- the initial asset flags the Safe is to set — USDC and REGENT, globally and for
  each fleet — marked as awaiting the Regents Safe;
- the terms the release discloses: public-read chat, no refunds, service rewards
  to keys only, the Safe's authority and the two separate 2% deductions.

There is no configuration UI anywhere in the product, so this file is where those
values are published, and it is what the app is seeded from.

The directory is the address the app holds. It answers with the four fleets in
slot order and with `isFleet`, and each fleet answers for its own ledger,
controller, preset and wiring, so nothing downstream has to keep a pasted list of
addresses in step.

## What the Safe does next

Neither step sets an allowlist flag, because admission is the Safe's alone.
Deposits are refused for every asset until the Safe has sent, in one Safe
transaction:

1. `setFactoryTokenAllowed(USDC, true)` and `setFactoryTokenAllowed(REGENT, true)`
   on the registry — the protocol-level catalogue.
2. `setFleetTokenAllowed(fleet, USDC, true)` and
   `setFleetTokenAllowed(fleet, REGENT, true)` for each of the four fleets — eight
   calls, because a global approval deliberately does not expose every fleet.

Both flags are required for admission, and a local approval can never override a
global disablement. A launched Autolaunch token is admitted the same way and only
after the launch is proven; nothing about a launch admits a token by itself.

## Decided

**The 5% protocol share goes to the Regents staking contract.** Every purchase
sets its 5% aside in the fleet's `protocolShareOwed`, and anyone may call
`sendProtocolShare()` on the fleet to register the whole owed amount as revenue
with the staking contract through `depositUSDC`, as the 2% USDC deposit fee
already is. The staking contract credits REGENT stakers their staked share and
keeps the rest as treasury residual. A paused staking contract delays that send
and never a purchase.

**D6 — the key price.** Every key is paid in USDC on Base. The first key of every
ladder costs 10 USDC (`Q_USDC`, 10,000,000 atomic USDC); Fibonacci levels step by
1.2, Accelerant primary mints by 1.05, and every Classic key costs 10 USDC. The
price is fixed in the contracts, so neither manifest carries it. The 5% protocol
share, the referral credit, capital, the Cascade reserve and repayment and the
Accelerant rebate are all USDC.

**Names, symbols and metadata base.** Every fleet's symbol is `KEYFLEET`. The
collections are named Keyfleet Syndicate, Keyfleet Cascade, Keyfleet Classic and
Keyfleet Accelerant. The name of each key, such as "Keyfleet Syndicate #01-01",
comes from the site's metadata, not from the contract. The site is keyfleet.ai:
the Base manifest's metadata base is `https://keyfleet.ai/metadata/<slot>/`, for
example `https://keyfleet.ai/metadata/syndicate/`, and the lab manifest uses
`http://localhost:4000/metadata/<slot>/`.

**D7 — the treasury address.** The treasury is the Regents Safe
`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, the same address that administers
deposit admission. It receives the non-USDC deposit fees, and it is immutable per
fleet.

The protocol-share decision is built into the contracts. The others are inputs
to the manifest only: none of them changes a line of contract code, and the
script deploys whatever the manifest says.
