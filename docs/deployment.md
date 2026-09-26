# Deploying the fleets

Each fleet is deployed and recorded on its own: Keyfleet Classic first, and each
of the others later, one at a time, when the founder opens it.

Once per chain, before the first fleet, `DeployKeyfleetAssetRegistry` deploys
the asset registry every fleet on that chain shares. It applies the deployment
step's chain and USDC refusals.

**Write the address it prints into the manifest's `assetRegistry` and commit it
before doing anything else.** The registry step refuses only a manifest that
already names a registry, so running it again before that commit deploys a
second, wasted registry; the fleet steps would refuse a fleet aimed at the wrong
one, but nothing takes the wasted one back.

After that, a fleet is deployed in two steps.

1. **Deploy.** `DeployKeyfleets` deploys the one fleet it is told to, into the
   registry the manifest names. It never deploys a registry, and refuses a
   manifest that names none. It writes no file of its own.
2. **Record.** After the deployment has been broadcast, and after the Safe has
   added the fleet to the randomness subscription, `RecordKeyfleets` reads the
   fleet back from the chain, checks every value against the manifest, and only
   then writes that fleet's published deployment manifest.

Nothing puts a fleet's keys on sale until its deployed manifest is recorded in
the app by hand with `bin/seed-deployment` (see
[deploy-checklist.md](deploy-checklist.md)). The app refuses to record a fleet
whose chain, USDC, asset registry or trait table differs from a fleet it has
already recorded.

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
name of the manifest and of the fleet, and no value either step invents for
itself.

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
| `assetRegistry` | The shared registry every fleet on the chain uses. Zero until `DeployKeyfleetAssetRegistry` has deployed it; its address is then written here and committed before any fleet is deployed. Both fleet steps refuse zero or an address that holds no code. |
| `autolaunchFactoryMayBeEmpty` | Whether the factory may still be undeployed. Ignored on Base. |
| `votingWindow` | Seconds a proposal stays open. 86,400 on both manifests. |
| `fleets.*` | Per fleet, under `syndicate`, `cascade`, `classic` and `accelerant`: ERC-721 `name`, `symbol` and `baseTokenURI`. A run reads only the fleet it deploys. |
| `vrf.coordinator` | The Chainlink VRF v2.5 coordinator every key's traits are requested from. Must hold code; on Base must be `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`. |
| `vrf.subscriptionId` | The coordinator subscription that pays for every request, written as a decimal string because ids exceed what JSON numbers hold exactly. The coordinator must know it. |
| `vrf.keyHash` | The gas lane. The coordinator must know it; on Base must be the 2 gwei lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab`. |
| `traitTableHash` | `keccak256` of the published trait-table file, byte for byte, that every key's traits are drawn from. Must not be zero. |

The key price is not a manifest value: it is fixed in the contracts (see D6).
Each fleet carries its own `baseTokenURI`: all four mint token ids from 1, so a
single shared base would make `tokenURI` ambiguous across the release.

Every address in the two manifests is recorded, not derived. The Autolaunch
factory address is the one the rehearsed ceremony predicts and is replaced by the
deployed manifest of that ceremony once it has run.

Both committed manifests carry `"subscriptionId": "0"` and a zero
`traitTableHash` until the subscription below exists and the trait table is
final, and the deployment step refuses both.

## The randomness subscription

Every purchase asks Chainlink VRF for the random number its key's traits are
drawn from, and one subscription pays for every fleet's requests in ETH.
Before the release is deployed:

1. Create the subscription on the coordinator (`createSubscription()`, or
   Chainlink's VRF app) and fund it in ETH with
   `fundSubscriptionWithNative(subId)`.
2. Move its ownership to the Regents Safe:
   `requestSubscriptionOwnerTransfer(subId, <Safe>)` from the creator, then
   `acceptSubscriptionOwnerTransfer(subId)` from the Safe.
3. Write the subscription id into `vrf.subscriptionId` and the trait table's
   hash into `traitTableHash`.

## The trait table

`traitTableHash` is `keccak256` of the trait-table file itself, byte for byte:
the file the art agent delivers, committed to the repository at a path chosen
then. Nothing is normalised or re-encoded before hashing, so the hash is taken
of exactly the bytes that are committed, with Ethereum's keccak256 (not the
standardised SHA3-256, which gives a different result). Once the fleets are deployed the file can
never change: a changed byte is a different hash, and every fleet holds the
original one. The contracts README gives the rule that draws each key's traits
from its seed and this table.

The file is JSON: an object whose `traits` lists every trait in the order the
rule draws them, each with its `name` and its `values`, and each value with its
`name` and a whole-number `weight`. A value of weight 0 is never drawn, and each
trait's weights must add up to at least 1 and less than 2^32.

```json
{"traits": [
  {"name": "Hull", "values": [{"name": "Brass", "weight": 50}, {"name": "Gold", "weight": 5}]},
  {"name": "Sky", "values": [{"name": "Dawn", "weight": 1}, {"name": "Dusk", "weight": 1}]}
]}
```

The table ships with the site: the art agent commits it as
`platform/priv/trait_tables/<traitTableHash>.json`, named by the hash in
lowercase `0x` hex, and there is no copy step. The site uses it only if its
`keccak256` is that name; a missing or changed file answers revealed keys'
metadata with a server error.

Between a fleet's deployment and its record step the Safe adds that fleet to
the subscription with `addConsumer(subId, fleet)`. A key sold before its fleet
is added is still sold; its request is refused, and anyone can ask again for it
with `requestReveal(tokenId)` once the fleet is added. The record step refuses a
fleet until it is listed, and on Base it also refuses one whose subscription the
manifest's `regentSafe` does not own.

## Keeping the subscription funded

The subscription must never run dry. Keep about 0.05 ETH in it, and alert at
0.02 ETH. A request made while it is empty waits unanswered, and pending
requests block both removing a consumer and cancelling the subscription until
they are answered, so an empty subscription cannot simply be closed and
replaced.

Regent's retry job, which asks again for keys still waiting on a seed, does not
retry while the subscription is below the 0.02 ETH alert level or while Base gas
is above the 2 gwei lane's price cap, since a request made then would only wait
too. Anyone can still ask again with `requestReveal(tokenId)`; the rule governs
Regent's own job. That job is the keeper, and [keeper.md](keeper.md) is how to
run it.

On a fork of Base the coordinator is Base's own, so a rehearsal creates and
funds its own subscription on the fork from the lab account, writes that id into
the manifest it deploys, and adds the fleets from the same account.

## Running it

All commands run from `contracts/`. The registry step takes only
`KEYFLEET_MANIFEST` and the RPC, and runs once per chain:

```sh
cd contracts

# Once per chain, before the first fleet. Simulate first by leaving off --broadcast.
KEYFLEET_MANIFEST=anvil \
  forge script script/DeployKeyfleetAssetRegistry.s.sol:DeployKeyfleetAssetRegistry \
  --rpc-url "$RPC_URL" --broadcast --unlocked --sender <lab account>
```

It prints the registry's address.

**Write the printed address into the manifest's `assetRegistry` and commit it
before doing anything else.** The registry step refuses only a manifest that
already names a registry, so running it again before that commit deploys a
second, wasted registry; the fleet steps would refuse a fleet aimed at the wrong
one, but nothing takes the wasted one back.

The two fleet steps take the same
`KEYFLEET_MANIFEST`, the same `KEYFLEET_FLEET` (`syndicate`, `cascade`,
`classic` or `accelerant`) and the same RPC. Neither has a default. For the
anvil manifest, `RPC_URL` is one of
the Base forks under Rehearsing: the manifest names Base's own USDC and REGENT,
and a plain `anvil` without a fork holds neither, so the deployment is refused.

```sh
# Step 1, simulated. Sends nothing, needs no signer, and writes no deployment file.
KEYFLEET_MANIFEST=anvil KEYFLEET_FLEET=classic \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets --rpc-url "$RPC_URL"

# Step 1, deployed.
KEYFLEET_MANIFEST=anvil KEYFLEET_FLEET=classic \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$RPC_URL" --broadcast --unlocked --sender <lab account>

# Between the steps, the subscription owner adds the fleet.
cast send <coordinator> "addConsumer(uint256,address)" <subscription id> <fleet> \
  --from <lab account> --unlocked --rpc-url "$RPC_URL"

# Step 2, once the broadcast has finished and the fleet is a consumer.
KEYFLEET_MANIFEST=anvil KEYFLEET_FLEET=classic \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$RPC_URL"
```

A simulation leaves Forge's own transaction log under
`broadcast/DeployKeyfleets.s.sol/<chainId>/dry-run/`, which git ignores. A
broadcast writes `broadcast/DeployKeyfleets.s.sol/<chainId>/run-latest.json`,
which is what the record step reads. Forge keeps only the latest broadcast
there, so each fleet is recorded straight after its own deployment, before the
next fleet is deployed; the dated `run-<timestamp>.json` beside it keeps each
fleet's broadcast for good.

Base is the same commands with the Base manifest and a signer that keeps its
key in hardware:

```sh
KEYFLEET_MANIFEST=base \
  forge script script/DeployKeyfleetAssetRegistry.s.sol:DeployKeyfleetAssetRegistry \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address> --broadcast --verify

KEYFLEET_MANIFEST=base KEYFLEET_FLEET=classic \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address> --broadcast --verify

KEYFLEET_MANIFEST=base KEYFLEET_FLEET=classic \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$BASE_RPC_URL"
```

`--verify` wants an explorer API key in `ETHERSCAN_API_KEY`; leave the flag off
and verify afterwards if there is none to hand. The record step sends nothing
and needs no signer. The registry step runs once on Base, before Classic.

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
`broadcast/DeployKeyfleets.s.sol/8453/` and `deployments/base.<fleet>.deployed.json`;
delete both before the real deployment, so neither the record step nor anyone
reading the repository mistakes the rehearsal for the release. Git keeps both
paths on purpose: the Base broadcast log and each `base.<fleet>.deployed.json`
are the evidence of the real deployment and are committed with it, while
everything a chain-31337 lab rehearsal writes is ignored.

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
Autolaunch factory has no code on this one either. Each fleet came to about 8.0
million gas, or about 10.4 million at Forge's default 130% gas estimate; the
registry is its own run before the first fleet. That was measured on an earlier version of
the fleet. Its code has grown since, to 21,865 bytes, and each byte of deployed
code costs 200 gas, so each run now costs more; measure it again on the fork
before relying on it. `--gas-limit 100000000` leaves room for a run in one
block.

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
- An `assetRegistry` that is zero or holds no code: the registry step runs
  first.
- An `assetRegistry` bound to a different Safe than the manifest names.
- A USDC address that is not the one the registry is bound to, or that does not
  report six decimals, both of which the fleet itself refuses at construction.
- On Base, a `vrf.coordinator` other than
  `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`, or a `vrf.keyHash` other than
  the 2 gwei lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab`.
- On any chain, a coordinator that holds no code, a gas lane the coordinator
  does not know, a subscription the coordinator does not know (which includes
  the placeholder `"0"`), and a zero `traitTableHash`, which the fleet itself
  also refuses at construction.
- A fleet name other than `syndicate`, `cascade`, `classic` or `accelerant`.

## What the record step refuses

- A broadcast with a transaction that has no receipt, or a receipt that did not
  succeed.
- A broadcast that created no fleet, or a fleet with no code on the chain it is
  run against.
- The same chain, USDC, REGENT, Autolaunch factory and randomness refusals as
  the deployment step.
- A fleet the subscription does not list as a consumer. The Safe adds it before
  this step runs.
- On Base, a subscription whose owner is not the manifest's `regentSafe`.
- Any value that differs from the manifest, read back from the chain: the
  fleet's preset, which must be the one for the fleet named, the asset
  registry, its Safe and its USDC, the treasury, the staking contract, the
  Autolaunch factory, the voting window, the coordinator, subscription, gas lane
  and trait table hash, and the fleet's name, symbol and metadata base. Every
  fleet on a chain is checked against the same manifest, so they all share
  those values, the asset registry included. REGENT is held by no fleet, so it is published as the manifest
  names it, once the refusals above have passed.

## What the record step writes

`contracts/deployments/<name>.<fleet>.deployed.json`, the fleet's published
deployment manifest, such as `base.classic.deployed.json`. Every address, every
fleet value, the vote window, the deposit fee and the reward ledger's bounds are
read from the chain, not copied from the input. The supply, price and split
constants come from the `KeyfleetPresets` library the record step was compiled
with; the fleet's code hash is recorded so anyone can check later that the
deployed code is the code those constants came from. It carries:

- the chain and the deployment block — the lowest block the run's transactions
  landed in, so a reader starting there misses no purchase made the moment the
  fleet appeared;
- the registry, and under `fleet` the fleet's name in the manifest (`slot`,
  such as `classic`), address, code hash, reward ledger, voting controller,
  name, symbol, metadata base and supply;
- REGENT, USDC, `qUsdc` — the first key's price, 10000000 atomic USDC, which is
  10 USDC — the treasury, the staking contract and the Regents Safe;
- the numeric bounds, the fee basis points and the fixed vote window;
- the Autolaunch binding: the ABI name `RegentsAutolaunchFactoryV1`, the factory
  and the strategy it publishes, and the code hash of each, so the binding can be
  checked against the Autolaunch ceremony's own manifest, and whether the lab
  waiver for a missing factory applied, which is never the case on Base;
- the randomness terms: the coordinator and its code hash, the subscription id
  as a decimal string, the gas lane, the three block confirmations, the 100,000
  gas each answer is given, the one-hour wait before anyone may ask again, and
  that requests are paid in ETH, under `vrf`;
- the trait table hash, as its own `traitTableHash`;
- the initial asset flags the Safe is to set — USDC and REGENT, globally and for
  the fleet — marked as awaiting the Regents Safe;
- the terms the release discloses: public-read chat, no refunds, service rewards
  to keys only, the Safe's authority and the two separate 2% deductions.

There is no configuration UI anywhere in the product, so this file is where those
values are published, and it is what the app is seeded from, one fleet at a
time. Each fleet answers for its own ledger, controller, preset and wiring, so
nothing downstream has to keep a pasted list of addresses in step.

## What the Safe does next

Neither step sets an allowlist flag, because admission is the Safe's alone.
Deposits are refused for every asset until the Safe has sent, in one Safe
transaction:

1. `setFactoryTokenAllowed(USDC, true)` and `setFactoryTokenAllowed(REGENT, true)`
   on the registry — the protocol-level catalogue. These are sent once, with the
   first fleet, since every later fleet shares the registry.
2. `setFleetTokenAllowed(fleet, USDC, true)` and
   `setFleetTokenAllowed(fleet, REGENT, true)` for each fleet as it is deployed —
   two calls per fleet, because a global approval deliberately does not expose
   every fleet.

Both flags are required for admission, and a local approval can never override a
global disablement. A launched Autolaunch token is admitted the same way and only
after the launch is proven; nothing about a launch admits a token by itself.

Never admit more than seven assets besides USDC to one fleet. A fleet's ledger
holds at most eight reward assets for its whole life, USDC included, and anyone
can use up a slot with a tiny revenue deposit in any admitted asset. Once the
launch has settled, income in a ninth asset can never be recognized.

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
Keyfleet Accelerant. The name of each key, such as "Keyfleet Syndicate #12",
comes from the site's metadata, not from the contract. The site is keyfleet.ai:
the Base manifest's metadata base is `https://keyfleet.ai/metadata/<slot>/`, for
example `https://keyfleet.ai/metadata/syndicate/`, and the lab manifest uses
`http://localhost:4000/metadata/<slot>/`. The contract's `tokenURI` is that base
followed by the key's number, and the site answers it for every key sold:

- until the key's traits are drawn, its name, a description, the fleet's
  waiting picture `/art/<slot>/revealing.png` and the attributes `Level` (for
  Syndicate and Cascade only) and `Status: Revealing`, with
  `Cache-Control: max-age=30`;
- once they are drawn, the same with its traits in place of `Status`, the
  picture `/art/<traitTableHash>/<slot>/<number>.png`, and `properties` holding
  its `seed` and `trait_table_hash`, with
  `Cache-Control: public, max-age=3600`, so a reveal corrected by hand after a
  reorg and newly delivered pictures show within the hour;
- a slot that is not one of the four, or a key not yet sold, is 404.

The pictures are not served yet; the art agent delivers them at those paths.

**Random key traits.** Every key's traits come from Chainlink VRF v2.5 and
nothing else. One
subscription, owned by the Regents Safe, pays for every fleet in ETH; on Base
the coordinator is `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` and the gas lane
the 2 gwei one. Every fleet fixes the trait table's hash at construction, and
each trait is drawn by weight from the key's seed as the contracts README
describes.

**D7 — the treasury address.** The treasury is the Regents Safe
`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, the same address that administers
deposit admission. It receives the non-USDC deposit fees, and it is immutable per
fleet.

The protocol-share and random-trait decisions are built into the contracts. The others are inputs
to the manifest only: none of them changes a line of contract code, and the
script deploys whatever the manifest says.
