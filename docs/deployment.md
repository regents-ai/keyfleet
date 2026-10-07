# Deploying the fleets

Each fleet is deployed and recorded on its own: Keyfleet Classic first, and each
of the others later, one at a time, when the founder opens it. Nothing is
deployed before the first fleet, and fleets share only the randomness
subscription.

No fleet may be deployed yet. Before any deploy the contracts must be complete
and audited by an outside auditor, the Regents Safe on Ethereum must be chosen,
and the founder must give the go; the
[contracts README](../contracts/README.md#status) lists what is decided and
what is on hold.

A fleet is deployed in two steps.

1. **Deploy.** `DeployKeyfleets` deploys the one fleet it is told to. It writes
   no file of its own.
2. **Record.** After the deployment has been broadcast, and after the Safe has
   added the fleet to the randomness subscription, `RecordKeyfleets` reads the
   fleet back from the chain, checks every value against the manifest, and only
   then writes that fleet's published deployment manifest.

Nothing puts a fleet's keys on sale until its deployed manifest is recorded in
the app by hand with `bin/seed-deployment` (see
[deploy-checklist.md](deploy-checklist.md)). The app refuses to record a fleet
whose chain, USDC or trait table differs from a fleet it has already recorded.

The steps are separate because Forge runs a script in full, locally, before it
broadcasts anything. A file written by the deployment step would be written by
a dry run too, and by a broadcast that failed partway, naming contracts that do
not exist. The record step runs only against what the chain actually holds.

Each fleet deploys its own reward ledger, voting controller and shard record
inside its own constructor, so there is no step in which a fleet exists without
them and no step in which a fleet could be pointed at someone else's.

Everything the deployment decides is in one file and one environment variable.
`contracts/deployments/ethereum.json` is the Ethereum input and
`contracts/deployments/anvil.json` is the lab input. The protocol treasury, the
Safe that receives the 10% protocol share of every key sale, is the one value
not in the file: both steps take it from `KEYFLEET_PROTOCOL_TREASURY`, which has
no default, so no run can fall back on an address nobody chose. Nothing else
configures a deployment: there is no other environment variable than the name
of the manifest and of the fleet, and no value either step invents for itself.

## What a manifest says

| Key | What it fixes |
| --- | --- |
| `chainId` | The only chain this manifest may be deployed to or recorded on. |
| `usdc` | The USDC every key is paid in, and every fleet's one income token. On Ethereum must be `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`; a fleet refuses a USDC that does not report six decimals. |
| `fleets.*` | Per fleet, under `syndicate`, `cascade`, `classic` and `accelerant`: ERC-721 `name`, `symbol` and `baseTokenURI`. A run reads only the fleet it deploys. |
| `vrf.coordinator` | The Chainlink VRF v2.5 coordinator every key's traits are requested from. Must hold code; on Ethereum must be `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`. |
| `vrf.subscriptionId` | The coordinator subscription that pays for every request, written as a decimal string because ids exceed what JSON numbers hold exactly. The coordinator must know it. |
| `vrf.keyHash` | The gas lane. The coordinator must know it; on Ethereum must be the 200 gwei lane `0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9`. |
| `traitTableHash` | `keccak256` of the published trait-table file, byte for byte, that every key's traits are drawn from. Must not be zero. |

And from the environment:

| Variable | What it fixes |
| --- | --- |
| `KEYFLEET_PROTOCOL_TREASURY` | The Regents Safe on Ethereum, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, the same for every fleet (the founder's choice of 29 September 2026). It receives the whole owed 10% protocol share whenever anyone calls `sendProtocolShare()`, and on Ethereum it must own the randomness subscription. Fixed in each fleet for good. Required, never zero, no default: on Ethereum the deployment and record steps refuse any other address (`ETHEREUM_PROTOCOL_TREASURY` in `contracts/script/KeyfleetManifest.sol`). |

The key price is not a manifest value: it is fixed in the contracts (see D6).
Each fleet carries its own `baseTokenURI`: all four mint token ids from 1, so a
single shared base would make `tokenURI` ambiguous across the release.

Every address in the two manifests is recorded, not derived. The Ethereum
coordinator and 200 gwei gas lane are the ones Chainlink lists for Ethereum
mainnet on its VRF v2.5 supported-networks page
(<https://docs.chain.link/vrf/v2-5/supported-networks>).

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
fleet until it is listed, and on Ethereum it also refuses one whose
subscription the protocol treasury does not own.

## Keeping the subscription funded

The subscription must never run dry. On Ethereum each answer is paid in ETH at
up to the 200 gwei lane's price cap, so the right balance to keep and the alert
level must be set from a measured cost per key before the first sale; the lab
figures of about 0.05 ETH kept and an alert at 0.02 ETH are placeholders. A request made while it is empty waits unanswered, and pending
requests block both removing a consumer and cancelling the subscription until
they are answered, so an empty subscription cannot simply be closed and
replaced.

Nothing on the site asks again by itself for keys still waiting on a seed.
Anyone can ask again with `requestReveal(tokenId)`: a key whose request was
refused shows a Try again button on its page, which sends that call from the
visitor's own wallet. Asking while the subscription is below the alert level or
while Ethereum gas is above the 200 gwei lane's price cap only waits too.

On a fork of Ethereum the coordinator is Ethereum's own, so a rehearsal creates
and funds its own subscription on the fork from the lab account, writes that id
into the manifest it deploys, and adds the fleets from the same account.

## Running it

All commands run from `contracts/`. The two steps take the same
`KEYFLEET_MANIFEST`, the same `KEYFLEET_FLEET` (`syndicate`, `cascade`,
`classic` or `accelerant`), the same `KEYFLEET_PROTOCOL_TREASURY` and the same
RPC. None has a default. For the anvil manifest, `RPC_URL` is the Ethereum fork
under Rehearsing: the manifest names Ethereum's own USDC and VRF coordinator,
and a plain `anvil` without a fork holds neither, so the deployment is refused.

```sh
cd contracts

# Step 1, simulated. Sends nothing, needs no signer, and writes no deployment file.
KEYFLEET_MANIFEST=anvil KEYFLEET_FLEET=classic KEYFLEET_PROTOCOL_TREASURY=<lab treasury> \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets --rpc-url "$RPC_URL"

# Step 1, deployed.
KEYFLEET_MANIFEST=anvil KEYFLEET_FLEET=classic KEYFLEET_PROTOCOL_TREASURY=<lab treasury> \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$RPC_URL" --broadcast --unlocked --sender <lab account>

# Between the steps, the subscription owner adds the fleet.
cast send <coordinator> "addConsumer(uint256,address)" <subscription id> <fleet> \
  --from <lab account> --unlocked --rpc-url "$RPC_URL"

# Step 2, once the broadcast has finished and the fleet is a consumer.
KEYFLEET_MANIFEST=anvil KEYFLEET_FLEET=classic KEYFLEET_PROTOCOL_TREASURY=<lab treasury> \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$RPC_URL"
```

A simulation leaves Forge's own transaction log under
`broadcast/DeployKeyfleets.s.sol/<chainId>/dry-run/`, which git ignores. A
broadcast writes `broadcast/DeployKeyfleets.s.sol/<chainId>/run-latest.json`,
which is what the record step reads. Forge keeps only the latest broadcast
there, so each fleet is recorded straight after its own deployment, before the
next fleet is deployed; the dated `run-<timestamp>.json` beside it keeps each
fleet's broadcast for good.

Ethereum is the same commands with the Ethereum manifest, the Regents Safe as
the treasury and a signer that keeps its key in hardware:

```sh
KEYFLEET_MANIFEST=ethereum KEYFLEET_FLEET=classic \
  KEYFLEET_PROTOCOL_TREASURY=0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$ETHEREUM_RPC_URL" --ledger --sender <deployer address> --broadcast --verify

KEYFLEET_MANIFEST=ethereum KEYFLEET_FLEET=classic \
  KEYFLEET_PROTOCOL_TREASURY=0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$ETHEREUM_RPC_URL"
```

`--verify` wants an explorer API key in `ETHERSCAN_API_KEY`; leave the flag off
and verify afterwards if there is none to hand. The record step sends nothing
and needs no signer. On Ethereum, the Safe adds the fleet to the subscription
between the two steps, as described under "What the Safe does next".

No private key goes in a file, an environment variable or a command line.
Neither step reads one: they read the manifest and the chain, and signing is
entirely the caller's business. The deployer receives no authority anywhere in
the release — no spending, no moderation, no vote — so the
deploying address matters only for paying gas.

## Rehearsing

Every purchase is paid in Ethereum USDC, so a rehearsal that buys keys runs on a
fork of Ethereum, where the real USDC and VRF coordinator exist, and funds the
buying wallet from an address that already holds USDC on the fork.

**A plain Ethereum fork, for the Ethereum manifest.**

```sh
anvil --fork-url "$ETHEREUM_RPC_URL" --gas-limit 100000000
```

This keeps Ethereum's chain id, 1, so the Ethereum manifest deploys and records
there exactly as it would on Ethereum, against the real USDC and coordinator. A
fork rehearsal writes `broadcast/DeployKeyfleets.s.sol/1/` and
`deployments/ethereum.<fleet>.deployed.json`; delete both before the real
deployment, so neither the record step nor anyone reading the repository
mistakes the rehearsal for the release. Git keeps both paths on purpose: the
Ethereum broadcast log and each `ethereum.<fleet>.deployed.json` are the
evidence of the real deployment and are committed with it, while everything a
chain-31337 lab rehearsal writes is ignored.

**A fork on chain 31337, for the anvil manifest.**

```sh
anvil --fork-url "$ETHEREUM_RPC_URL" --chain-id 31337 --gas-limit 100000000
export RPC_URL=http://127.0.0.1:8545

# USDC for a purchase, from a fork address that holds it. Amounts are atomic
# USDC: 10000000 is 10 USDC, the price of the first key of Syndicate, Cascade
# and Accelerant; Classic's first key costs 8000000, 8 USDC.
cast rpc anvil_impersonateAccount <address holding USDC> --rpc-url "$RPC_URL"
cast send 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 "transfer(address,uint256)" \
  <wallet> <atomic USDC> --from <address holding USDC> --unlocked --rpc-url "$RPC_URL"
cast rpc anvil_stopImpersonatingAccount <address holding USDC> --rpc-url "$RPC_URL"
```

Buy with a fresh address, not one of anvil's default accounts, which may carry
delegated code on a mainnet fork whose NFT callback reverts, so a key minted to
it fails.

A fleet run deploys four contracts in one transaction: the fleet (15,891 bytes
of deployed code), its reward ledger (5,204), its voting controller (7,401) and
its shard record (2,204), by `forge build --sizes`. Each byte of deployed code
costs 200 gas. The gas a whole run takes has not been measured on a fork of
Ethereum; measure it before relying on it. `--gas-limit 100000000` leaves room
for a run in one block.

## What the deployment step refuses

- A manifest whose `chainId` is not the chain it is running on.
- A zero protocol treasury. `KEYFLEET_PROTOCOL_TREASURY` unset stops the run
  before anything is deployed.
- On Ethereum, a protocol treasury other than the Regents Safe
  `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`.
- On Ethereum, a `usdc` other than Ethereum USDC
  `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`. Every key price is written in
  six-decimal USDC, so a look-alike with other decimals would misprice every key.
- A USDC that does not report six decimals, which the fleet itself refuses at
  construction.
- On Ethereum, a `vrf.coordinator` other than
  `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`, or a `vrf.keyHash` other than
  the 200 gwei lane
  `0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9`.
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
- The same chain, treasury, USDC and randomness refusals as the deployment step.
- A fleet the subscription does not list as a consumer. The Safe adds it before
  this step runs.
- On Ethereum, a subscription whose owner is not the protocol treasury.
- Any value that differs from the manifest, read back from the chain: the
  fleet's preset, which must be the one for the fleet named, USDC, the protocol
  treasury, the coordinator, subscription, gas lane and trait table hash, and
  the fleet's name, symbol and metadata base. Every fleet on a chain is checked
  against the same manifest, so they all share those values.

## What the record step writes

`contracts/deployments/<name>.<fleet>.deployed.json`, the fleet's published
deployment manifest, such as `ethereum.classic.deployed.json`. Every address,
every fleet value and the income token are read from the chain, not copied from
the input. The supply, price and split constants come from the
`KeyfleetPresets` library the record step was compiled with; the fleet's code
hash is recorded so anyone can check later that the deployed code is the code
those constants came from. It carries:

- the chain and the deployment block — the lowest block the run's transactions
  landed in, so a reader starting there misses no purchase made the moment the
  fleet appeared;
- under `fleet` the fleet's name in the manifest (`slot`, such as `classic`),
  address, code hash, reward ledger, voting controller, shard record, name,
  symbol and metadata base;
- USDC, `qUsdc` — the reference price the Syndicate, Cascade and Accelerant
  ladders start from, 10000000 atomic USDC, which is 10 USDC; Classic prices
  from its own table — and the protocol treasury;
- under `bounds` the two supply limits, Classic's 1,024 keys and Accelerant's
  2,000 (Syndicate and Cascade have none), and under `fees` the fee basis
  points: the 10% protocol share and the Accelerant 20% capital share;
- the randomness terms: the coordinator and its code hash, the subscription id
  as a decimal string, the gas lane, the three block confirmations, the 100,000
  gas each answer is given, and that requests are paid in ETH, under `vrf`;
- the trait table hash, as its own `traitTableHash`;
- the income token, under `incomeTokens`: USDC alone;
- the terms the release discloses: public-read chat, no refunds, service rewards
  to keys only, what the 10% fee is and is not, and that the Regents Safe
  receives the protocol share and owns the randomness subscription only.

There is no configuration UI anywhere in the product, so this file is where those
values are published, and it is what the app is seeded from, one fleet at a
time. Each fleet answers for its own ledger, controller, shard record, preset
and wiring, so
nothing downstream has to keep a pasted list of addresses in step.

## What the Safe does next

The Regents Safe's one part in a release is the randomness subscription. After
each fleet is deployed, and before its record step, the Safe adds the fleet as
a consumer with `addConsumer(subId, fleet)`. It has no other step: there is no
admission list, and the Safe holds no authority over any fleet's votes, claims,
prices or money. It receives the protocol share whenever anyone sends it, and
moves it on by hand.

## Decided

**Fully owned fleets (27 September 2026), on Ethereum (29 September 2026).**
Regents takes 10% of each key purchase, once, and nothing else. Every purchase
sets its 10% aside in the fleet's `protocolShareOwed`, and anyone may call
`sendProtocolShare()` on the fleet to transfer the whole owed amount in USDC to
the Regents Safe, fixed in the fleet as `PROTOCOL_TREASURY`. Regents moves it on
by hand. A treasury that cannot receive delays that send and never a purchase.
Income in USDC goes 100% to the keys, every other token is shared money, and
only a vote of more than half of all keys sold spends it. There is no token
launch. The [contracts README](../contracts/README.md) states the rules.

**D6 — the key price.** Every key is paid in USDC on Ethereum. The first key of
the Fibonacci and Accelerant ladders costs 10 USDC (`Q_USDC`, 10,000,000 atomic
USDC); Fibonacci levels step by 1.2, with no last level, and Accelerant primary
mints by 1.05 up to 2,000 keys. Classic's 1,024 keys run from 8 USDC for the
first to 80 USDC for the last, each key about 0.2253% dearer than the one
before, rounded to the nearest cent, and 32,032.45 USDC for all of them. The
price is fixed in the contracts, so neither manifest carries it. The 10%
protocol share, shared money from key sales, the Cascade reserve and repayment
and the Accelerant rebate are all USDC. An Accelerant key after the first sends
20% to shared money and 70% to the holder of the key before it.

**Names, symbols and metadata base.** Every fleet's symbol is `KEYFLEET`. The
collections are named Keyfleet Syndicate, Keyfleet Cascade, Keyfleet Classic and
Keyfleet Accelerant. The name of each key, such as "Keyfleet Syndicate #12",
comes from the site's metadata, not from the contract. The site is keyfleet.ai:
the Ethereum manifest's metadata base is `https://keyfleet.ai/metadata/<slot>/`, for
example `https://keyfleet.ai/metadata/syndicate/`, and the lab manifest uses
`http://localhost:4000/metadata/<slot>/`. The contract's `tokenURI` is that base
followed by the key's number, and the site answers it for every key sold:

- until the key's traits are drawn, its name, a description, the Interim
  Keyfleet Access Pass
  `https://media.regents.sh/ipfs/QmddjWKS43UPY3V1muZJGVx8zkpxCUXwmsy29heg1qNETy`
  (one picture for every key in every fleet, kept on IPFS like the cards) and the attributes `Level` (for
  Syndicate and Cascade only) and `Status: Revealing`, with
  `Cache-Control: max-age=30`;
- once they are drawn, the same with its traits in place of `Status` and
  `properties` holding its `seed` and `trait_table_hash`. While its card is
  being drawn it keeps the pass, with `Cache-Control: max-age=30`; once the
  card is kept on IPFS, the picture is `https://media.regents.sh/ipfs/<cid>`
  and `properties.card` is `ipfs://<cid>`, with
  `Cache-Control: public, max-age=3600`, so a reveal corrected by hand after a
  reorg shows within the hour;
- a slot that is not one of the four, or a key not yet sold, is 404.

Each recorded reveal queues a `key_art` job that has the private key-art
service (`key-art/`, at `KEY_ART_URL`) draw the card, keeps it on IPFS through
Regent's Lighthouse account (`LIGHTHOUSE_API_KEY`) and records its address
against that reveal; see [key-art/README.md](../key-art/README.md).

**Random key traits.** Every key's traits come from Chainlink VRF v2.5 and
nothing else. One
subscription, owned by the Regents Safe, pays for every fleet in ETH; on
Ethereum the coordinator is `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a` and the
gas lane the 200 gwei one. Every fleet fixes the trait table's hash at construction, and
each trait is drawn by weight from the key's seed as the contracts README
describes.

**The Regents Safe (29 September 2026).** On Ethereum it is
`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, the protocol treasury of every
fleet. It is still given to each run as `KEYFLEET_PROTOCOL_TREASURY`, which has
no default; the scripts only refuse any other address on Ethereum. It receives
the protocol share, owns the randomness subscription, and holds nothing in any
fleet.

The fully owned fleet, key price and random-trait decisions are built into the
contracts. The others are inputs to the manifest only: none of them changes a
line of contract code, and the script deploys whatever the manifest says.
