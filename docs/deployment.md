# Deploying the fleets

The fleets live on Base (chain 8453). Each fleet is deployed and recorded on its
own: Keyfleet Classic first, and each of the others later, one at a time, when
the founder opens it. Nothing is deployed before the first fleet, and fleets
share only the randomness subscription.

No fleet may be deployed yet. Before any deploy the contracts must be complete
and audited by an outside auditor, and the founder must give the go; the
[contracts README](../contracts/README.md#status) lists what is decided and
what is on hold. Key sales stay off until the founder says so.

A fleet is five contracts: `Keyfleet` (the fleet itself), which creates its
`KeyfleetRewards` ledger and its `KeyfleetShards` record as it is deployed, then
its `KeyfleetVotes` controller and its `KeyfleetTreasury`. It is deployed in two
steps.

1. **Deploy.** `DeployKeyfleets` deploys the one fleet it is told to, as three
   transactions from one account. It writes no file of its own.
2. **Record.** After the deployment has been broadcast, and after the Safe has
   added the fleet to the randomness subscription, `RecordKeyfleets` reads the
   fleet's five contracts back from the chain, checks every value against the
   manifest, and only then writes that fleet's published deployment manifest.

Nothing puts a fleet's keys on sale until its deployed manifest is recorded in
the app by hand with `bin/seed-deployment` (see
[deploy-checklist.md](deploy-checklist.md)). The app refuses to record a fleet
whose chain, USDC or trait table differs from a fleet it has already recorded.

The steps are separate because Forge runs a script in full, locally, before it
broadcasts anything. A file written by the deployment step would be written by
a dry run too, and by a broadcast that failed partway, naming contracts that do
not exist. The record step runs only against what the chain actually holds.

## The order of the three transactions

The fleet goes first. Before it exists it is told where its controller and its
treasury will be: the deploying account's next two contract addresses, worked
out from its nonce. The fleet keeps both addresses for good and, as it is
deployed, creates its ledger (bound to the fleet, the treasury's address and the
shard record) and its shard record. The controller goes second and the treasury
third, from the same account, each at the address the fleet was given, and each
refuses to deploy for a fleet that does not name it. So a wrong address, or any
other transaction sent from the account in between, stops the deployment rather
than binding the wrong contract. `contracts/script/KeyfleetStack.sol` does this
for the deployment script, the anvil lab and the suite.

The order exists because of Base's size limits: no contract may have more than
24,576 bytes of code or 49,152 bytes of deployment code, and the fleet with its
controller and treasury inside it would pass the second. Deployed one Classic
fleet at a time on a local fork of Base, the three transactions measured:

| Transaction | Gas |
| --- | --- |
| The fleet, with its ledger and shard record | 6,045,638 |
| The voting controller | 3,210,157 |
| The treasury | 2,039,359 |
| All three | 11,295,154 |

A purchase made in the moment between the fleet and its treasury sends its
capital to the treasury's address, where the treasury finds it once deployed.

## What a manifest says

Everything the deployment decides is in one file:
`contracts/deployments/base.json` for Base and `contracts/deployments/anvil.json`
for the lab. The only environment variables are the manifest's name and the
fleet's. Neither step invents a value or falls back on one nobody chose.

| Key | What it fixes |
| --- | --- |
| `chainId` | The only chain this manifest may be deployed to or recorded on. |
| `usdc` | The USDC every key is paid in. On Base it must be native Base USDC, `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`; a fleet refuses a USDC that does not report six decimals. |
| `regentStaking` | Where each fleet's treasury deposits the 10% protocol share. On Base it must be REGENT revenue staking, `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`. |
| `regent` | The REGENT token the daily split shares among keys. On Base it must be `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`. |
| `fleets.*` | Per fleet, under `syndicate`, `cascade`, `classic` and `accelerant`: the collection `name`, `symbol` and `baseTokenURI`. A run reads only the fleet it deploys. |
| `vrf.coordinator` | The Chainlink VRF v2.5 coordinator every key's traits are requested from. On Base it must be `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`. |
| `vrf.subscriptionId` | The subscription that pays for every request, written as a decimal string because ids are longer than JSON numbers hold exactly. The coordinator must know it. |
| `vrf.keyHash` | The gas lane. On Base it must be the 2 gwei lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` (the release's) or the 30 gwei lane `0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70`. |
| `traitTableHash` | `keccak256` of the published trait-table file, byte for byte, that every key's traits are drawn from. Must not be zero. |

The key price is not a manifest value: it is fixed in the contracts. Each fleet
carries its own `baseTokenURI`: all four number their keys from 1, so a single
shared base would make `tokenURI` ambiguous across the release.

Every Base address is pinned in `contracts/script/KeyfleetManifest.sol` with its
source: USDC from Circle's contract addresses page, the coordinator and gas
lanes from Chainlink's VRF v2.5 supported-networks page
(<https://docs.chain.link/vrf/v2-5/supported-networks>), and REGENT and REGENT
revenue staking from Regent's own Base bindings and verified Basescan source.

`base.json` carries the final trait table's hash and `"subscriptionId": "0"`, so
a Base deployment is refused until the Regents subscription id is written in.
`anvil.json` is for a fork of Base on chain 31337: it names Base's own
addresses, with a zero subscription and a zero trait table hash for the lab to
write in.

## The randomness subscription

Every purchase asks Chainlink VRF for the random number its key's traits are
drawn from, and one subscription pays for every fleet's requests in ETH. Before
the first fleet is deployed:

1. Create the subscription on the Base coordinator (`createSubscription()`, or
   Chainlink's VRF app) and fund it in ETH with
   `fundSubscriptionWithNative(subId)`.
2. Move its ownership to the Regents Safe on Base,
   `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`:
   `requestSubscriptionOwnerTransfer(subId, <Safe>)` from the creator, then
   `acceptSubscriptionOwnerTransfer(subId)` from the Safe.
3. Write the subscription id into `vrf.subscriptionId` in `base.json`.

Between each fleet's deployment and its record step the Safe adds that fleet to
the subscription with `addConsumer(subId, fleet)`. A key sold before its fleet
is added is still sold; its request is refused, and anyone can ask again for it
with `requestReveal(tokenId)` once the fleet is added. The record step refuses a
fleet until it is listed, and on Base it also refuses one whose subscription the
Regents Safe does not own.

## Keeping the subscription funded

The subscription must never run dry. Each answer is paid in ETH at up to the
2 gwei lane's price cap. The balance to keep and the alert level must be set
from a measured cost per key before the first sale. A request made while the
subscription is empty waits unanswered, and pending requests block both removing
a consumer and cancelling the subscription until they are answered, so an empty
subscription cannot simply be closed and replaced.

Nothing on the site asks again by itself for keys still waiting on a seed.
Anyone can ask again with `requestReveal(tokenId)`: a key whose request was
refused shows a Try again button on its page, which sends that call from the
visitor's own wallet.

## The trait table

`traitTableHash` is `keccak256` of the trait-table file itself, byte for byte:
the file the art agent delivers. Nothing is normalised or re-encoded before
hashing, so the hash is taken of exactly the bytes that are committed, with
keccak256 (not the standardised SHA3-256, which gives a different result). Once
the fleets are deployed the file can never change: a changed byte is a
different hash, and every fleet holds the original one. The contracts README
gives the rule that draws each key's traits from its seed and this table.

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

## Running it

All commands run from `contracts/`. The two steps take the same
`KEYFLEET_MANIFEST` (`base` or `anvil`), the same `KEYFLEET_FLEET` (`syndicate`,
`cascade`, `classic` or `accelerant`) and the same RPC. Neither has a default.

Base, with a signer that keeps its key in hardware:

```sh
cd contracts

# Step 1, simulated. Sends nothing and writes no deployment file.
KEYFLEET_MANIFEST=base KEYFLEET_FLEET=classic \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address>

# Step 1, deployed: three transactions, the fleet, its controller, its treasury.
KEYFLEET_MANIFEST=base KEYFLEET_FLEET=classic \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address> --broadcast --slow --verify

# Between the steps, the Regents Safe adds the fleet to the subscription.

# Step 2, once the broadcast has finished and the fleet is a consumer.
KEYFLEET_MANIFEST=base KEYFLEET_FLEET=classic \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$BASE_RPC_URL"
```

`--slow` sends each transaction only after the one before has landed, so the
three keep their order. The deploying account must send nothing else between
them: its next two addresses are the ones the fleet was given. `--verify` wants
an explorer API key in `ETHERSCAN_API_KEY`; leave the flag off and verify
afterwards if there is none to hand. The record step sends nothing and needs no
signer.

A simulation leaves Forge's own transaction log under
`broadcast/DeployKeyfleets.s.sol/<chainId>/dry-run/`, which git ignores. A
broadcast writes `broadcast/DeployKeyfleets.s.sol/<chainId>/run-latest.json`,
which is what the record step reads. Forge keeps only the latest broadcast
there, so each fleet is recorded straight after its own deployment, before the
next fleet is deployed; the dated `run-<timestamp>.json` beside it keeps each
fleet's broadcast for good.

No private key goes in a file, an environment variable or a command line.
Neither step reads one: they read the manifest and the chain, and signing is
entirely the caller's business. The deployer receives no authority anywhere in
the release, no spending, no vote and no setting, so the deploying address
matters only for paying gas.

## Rehearsing

Every purchase is paid in Base USDC, so a rehearsal that buys keys runs on a
fork of Base, where the real USDC, REGENT, REGENT staking and VRF coordinator
exist.

**A plain Base fork, for the Base manifest.**

```sh
anvil --fork-url "$BASE_RPC_URL"
```

This keeps Base's chain id, 8453, so the Base manifest deploys and records there
exactly as it would on Base. Create and fund a subscription on the fork from an
anvil account and write its id into the manifest for the rehearsal only; the
record step will then refuse it because the Regents Safe does not own it, which
is the Base rule working. A fork rehearsal writes
`broadcast/DeployKeyfleets.s.sol/8453/` and
`deployments/base.<fleet>.deployed.json`; delete both, and put the manifest's
subscription back, before the real deployment, so nobody mistakes the
rehearsal for the release. Git keeps both paths on purpose: the Base broadcast
log and each `base.<fleet>.deployed.json` are the evidence of the real
deployment and are committed with it, while everything a chain-31337 lab
rehearsal writes is ignored.

**A fork on chain 31337, for the anvil manifest.**

```sh
anvil --fork-url "$BASE_RPC_URL" --chain-id 31337
export RPC_URL=http://127.0.0.1:8545
```

Write a subscription created on the fork and a trait table hash into
`anvil.json`, then run both steps as above with `KEYFLEET_MANIFEST=anvil`,
`--rpc-url "$RPC_URL"`, and `--broadcast --unlocked --sender <anvil account>` in
place of the hardware signer. The subscription's owner adds the fleet between
the steps:

```sh
cast send 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 "addConsumer(uint256,address)" \
  <subscription id> <fleet> --from <anvil account> --unlocked --rpc-url "$RPC_URL"
```

USDC for a purchase comes from a fork address that already holds it. Amounts are
atomic USDC: 10000000 is 10 USDC, the price of the first key of Syndicate,
Cascade and Accelerant; Classic's first key costs 8000000, 8 USDC.

```sh
cast rpc anvil_impersonateAccount <address holding USDC> --rpc-url "$RPC_URL"
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "transfer(address,uint256)" \
  <wallet> <atomic USDC> --from <address holding USDC> --unlocked --rpc-url "$RPC_URL"
cast rpc anvil_stopImpersonatingAccount <address holding USDC> --rpc-url "$RPC_URL"
```

Buy with a fresh address, not one of anvil's default accounts, which may carry
delegated code on a fork whose NFT callback reverts, so a key minted to it
fails.

`contracts/script/AnvilLab.s.sol` is separate from both: it puts one Classic
fleet on a plain local anvil, with stand-ins for USDC, REGENT, REGENT staking
and the coordinator, for the site's anvil tests, and returns the addresses of
the fleet's five contracts and the stand-in staking.

## What the deployment step refuses

- A manifest whose `chainId` is not the chain it is running on.
- On Base, a `usdc` other than native Base USDC
  `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. Every key price is written in
  six-decimal USDC, so a look-alike with other decimals would misprice every key.
- On Base, a `regentStaking` other than REGENT revenue staking
  `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`, and a `regent` other than
  `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`.
- On Base, a `vrf.coordinator` other than
  `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`, or a `vrf.keyHash` other than
  the 2 gwei or 30 gwei lane.
- On any chain, a staking contract, REGENT or coordinator that holds no code, a
  gas lane the coordinator does not know, a subscription the coordinator does
  not know (which includes the placeholder `"0"`), and a zero `traitTableHash`,
  which the fleet itself also refuses.
- A USDC that does not report six decimals, which the fleet itself refuses.
- A fleet name other than `syndicate`, `cascade`, `classic` or `accelerant`.

## What the record step refuses

- A broadcast with a transaction that has no receipt, or a receipt that did not
  succeed.
- A broadcast that created no fleet, or a fleet with no code on the chain it is
  run against.
- A ledger, controller, treasury or shard record that holds no code or does not
  name the fleet as its own.
- The same chain, USDC, staking, REGENT and randomness refusals as the
  deployment step.
- A fleet the subscription does not list as a consumer. The Safe adds it before
  this step runs.
- On Base, a subscription whose owner is not the Regents Safe.
- Any value that differs from the manifest, read back from the chain: the
  fleet's preset, which must be the one for the fleet named, USDC, the
  treasury's staking contract and REGENT, the coordinator, subscription, gas lane
  and trait table hash, and the fleet's name, symbol and metadata base. Every
  fleet on a chain is checked against the same manifest, so they all share those
  values.

## What the record step writes

`contracts/deployments/<name>.<fleet>.deployed.json`, the fleet's published
deployment manifest, such as `base.classic.deployed.json`. Every address and
every fleet value is read from the chain, not copied from the input. The
supply, price and split constants come from the `KeyfleetPresets` library the
record step was compiled with; each of the five contracts' code hash is
recorded so anyone can check later that the deployed code is the code those
constants came from. It carries:

- the chain and the deployment block, the lowest block the run's transactions
  landed in, so a reader starting there misses no purchase made the moment the
  fleet appeared;
- under `fleet` the fleet's name in the manifest (`slot`, such as `classic`),
  its address and code hash, the ledger, controller, treasury and shard record
  addresses each with its code hash (`rewardsCodeHash`, `votesCodeHash`,
  `treasuryCodeHash`, `shardsCodeHash`), and the name, symbol and metadata base;
- USDC and `qUsdc`, the reference price the Syndicate, Cascade and Accelerant
  ladders start from (10000000 atomic USDC, which is 10 USDC; Classic prices
  from its own table);
- REGENT revenue staking, REGENT and the tag every protocol share deposit
  carries (`protocolShareTag`);
- under `bounds` the two supply limits, Classic's 1,024 keys and Accelerant's
  2,000 (Syndicate and Cascade have none), and under `fees` the 10% protocol
  share and the Accelerant 20% capital share;
- under `vrf` the coordinator and its code hash, the subscription id as a
  decimal string, the gas lane, the three block confirmations, the 100,000 gas
  each answer is given, and that requests are paid in ETH;
- the trait table hash;
- `splitAssets`, the assets the daily split shares at deployment: ETH, REGENT
  and USDC;
- the terms the release discloses: public-read chat, no refunds, service rewards
  to keys only, what the 10% fee is and is not, and what the Regents Safe owns.

There is no configuration screen anywhere in the product, so this file is where
those values are published, and it is what the app is seeded from, one fleet at
a time.

## What the Safe does next

The Regents Safe on Base, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, owns the
randomness subscription and REGENT revenue staking. After each fleet is
deployed, and before its record step, the Safe adds the fleet as a consumer with
`addConsumer(subId, fleet)`. It has no other step: there is no admission list,
it does not receive the 10%, and it holds no authority over any fleet's votes,
claims, prices or money.

## The fleet's Lit account

The fleet's treasury owns its Lit account on Base. Setting it up is the key
holders' business after the record, by proposals: each proposal's calls go from
the treasury to Lit's account contract,
`0xaaaaa9120fe271f653cfdb6bf400db93d2dea7aa` (named by Lit's node
configuration). The calls create the account, register the inbox action, make
one group with it, and mint one usage key for the operator that may run that
action and nothing else; later proposals replace or remove the key. When Lit
asks the account's owner to sign a request, a proposal approves that exact
request's digest with `approveSignatureHash`, and the treasury answers Lit's
check for it. Lit takes a signed request only within five minutes of the time it
names, and only once, so the proposal names the time it will be carried out and
the operator sends the request to Lit straight after. Voting and claims never
depend on Lit.

## Decided

**Fully owned fleets (27 September 2026), on Base (6 October 2026).** Regents
takes 10% of each key purchase, once, in USDC, and nothing else. Every purchase
sets its 10% aside in the fleet's `protocolShareOwed`, and anyone may call
`sendProtocolShare()` on the fleet, which deposits the whole owed amount into
REGENT revenue staking on Base for REGENT stakers. Every other amount a fleet
receives is its treasury's capital, spent only by a passed proposal's exact
calls, apart from the daily split that shares a small part of its ETH, REGENT
and USDC among the keys. There is no token launch. The
[contracts README](../contracts/README.md) states the rules.

**The key price.** Every key is paid in USDC on Base. The first key of the
Fibonacci and Accelerant ladders costs 10 USDC (`Q_USDC`, 10,000,000 atomic
USDC); Fibonacci levels step by 1.2, with no last level, and Accelerant primary
mints by 1.05 up to 2,000 keys. Classic's 1,024 keys run from 8 USDC for the
first to 80 USDC for the last, each key about 0.2253% dearer than the one
before, rounded to the nearest cent, and 32,032.45 USDC for all of them. The
price is fixed in the contracts, so neither manifest carries it. An Accelerant
key after the first sends 20% to the treasury and 70% to the holder of the key
before it.

**Names, symbols and metadata base.** Every fleet's symbol is `KEYFLEET`. The
collections are named Keyfleet Syndicate, Keyfleet Cascade, Keyfleet Classic and
Keyfleet Accelerant. The name of each key, such as "Keyfleet Syndicate #12",
comes from the site's metadata, not from the contract. The site is keyfleet.ai:
the Base manifest's metadata base is `https://keyfleet.ai/metadata/<slot>/`, for
example `https://keyfleet.ai/metadata/syndicate/`. The contract's `tokenURI` is
that base followed by the key's number, and the site answers it for every key
sold:

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

**Random key traits.** Every key's traits come from Chainlink VRF v2.5 and
nothing else. One subscription, owned by the Regents Safe, pays for every fleet
in ETH, on Base's 2 gwei gas lane. Every fleet fixes the trait table's hash at
deployment, and each trait is drawn by weight from the key's seed as the
contracts README describes.

The fully owned fleet, key price and random-trait decisions are built into the
contracts. The others are inputs to the manifest only: none of them changes a
line of contract code, and the script deploys whatever the manifest says.
