# Deploying Keyfleet

Keyfleet lives on Base (chain 8453). The whole system is deployed once: one
factory, which creates the one key collection, the shared shard record, the
shared REGENT buyer and the Regents Club claims contract. Fleets are then
created through the factory: the five founding fleets by the Regents Safe, and later fleets by anyone once the Safe
has moved the collection to phase 3.

Nothing may be deployed yet. Before any deploy every Keyfleet contract must pass
the internal audit the founder chose on 9 Oct in place of an outside one, with
its findings fixed, and the founder must give the go; the
[contracts README](../contracts/README.md#status) lists what is decided and what
is on hold. Key sales stay off until the founder says so: every fleet's sales
open only through a phase step, which is a Safe transaction the founder signs.

The release runs in seven steps, in this order:

1. **Subscription.** Create the Chainlink VRF subscription, fund it and move it
   to the Regents Safe. Write its id and the keeper's address into the manifest.
2. **Deploy.** `DeployKeyfleets` deploys the system in five transactions from
   one account. It writes no file of its own and creates no fleet.
3. **Consumer.** The Safe adds the collection to the subscription.
4. **Founding fleets.** `KeyfleetSafeSteps` with the step `founding-fleets`
   writes one Safe transaction per founding fleet. The founder signs each, in
   order: Classic #1, Syndicate #1, Accelerant #1, Cascade #1, Regents Club #1.
5. **Record.** `RecordKeyfleets` reads the system and every fleet back from the
   chain, checks them against the manifest, and writes the published record,
   `contracts/deployments/base.deployed.json`.
6. **Phases.** Only when the founder says when sales open, `KeyfleetSafeSteps`
   with the step `advance-phase` writes the next phase step for the founder to
   sign, naming that moment: phase 1 opens Classic #1 and the Regents Club,
   phase 2 opens Syndicate #1, Accelerant #1 and Cascade #1, phase 3 lets
   anyone create a fleet.
7. **Regents Club gifts.** Once phase 1 has opened, `KeyfleetSafeSteps` with
   the step `club-gifts` writes the Safe transactions that give the 1,998
   Regents Club keys, 80 per transaction, each to the holder of its Pass, for
   the founder to sign.

Before step 1, go through the deploy-day checklist in the
[contracts README](../contracts/README.md#deploy-day-checklist): the keeper,
the keeper's job list of public buttons (pieces, daily splits and the protocol
share), the REGENT pool hook's fee that pieces rely on, the collection metadata
address, the subscription id and the consumer, REGENT staking unpaused, and
factories that can never be removed.

Nothing in steps 1 to 5 puts any key on sale. The site lists the fleets only
once the record is loaded into it by hand with `seed-deployment` (see
[deploy-checklist.md](deploy-checklist.md)), and it shows each fleet's buy
button as closed until the collection says that fleet's sales are open.

The deploy and record steps are separate because Forge runs a script in full,
locally, before it broadcasts anything. A file written by the deployment step
would be written by a dry run too, and by a broadcast that failed partway,
naming contracts that do not exist. The record step runs only against what the
chain actually holds.

## The five deployment transactions

`contracts/script/KeyfleetSystem.sol` does this for the deployment script, the
suite and the fork tests. From one account, in order:

1. `KeyfleetManagerDeployer`
2. `KeyfleetVotesDeployer`
3. `KeyfleetTreasuryDeployer`
4. `KeyfleetRewardsDeployer`
5. `KeyfleetFactory`, whose constructor deploys `KeyfleetKeys`, `KeyfleetShards`
   and `KeyfleetRegentBuyer`

Each deployer is told the factory's address before the factory exists: the
deploying account's fifth contract address from now, worked out from its nonce.
The factory refuses any deployer that names another address, so a transaction
sent from the account in between, or a wrong order, stops the deployment rather
than binding the wrong contract. The deployers exist because of Base's size
limits: no contract may have more than 24,576 bytes of code or 49,152 bytes of
deployment code, and the factory could not carry the four fleet contracts'
creation code itself.

The factory holds no money and has no administrator. The deploying account
receives no authority anywhere in the system, so it matters only for paying gas.
The gas these five transactions use on Base is still to measure on a Base fork;
the [contracts README](../contracts/README.md#gas) has the figures measured so
far.

## What a manifest says

Everything the deployment decides is in one file:
`contracts/deployments/base.json` for Base and
`contracts/deployments/anvil.json` for a fork of Base on chain 31337. Every
script reads the manifest named by `KEYFLEET_MANIFEST`; none invents a value or
falls back on one nobody chose.

| Key | What it fixes |
| --- | --- |
| `chainId` | The only chain this manifest may be deployed to or recorded on. |
| `safe` | The Regents Safe: the only account that may move the phase, create the founding fleets, replace the keeper or allow another factory, and the receiver of the 2.5% resale royalty. On Base it must be `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. |
| `keeper` | The Regents wallet that records an open fleet's card deck once and may ask for a key's metadata refresh. It must not be zero. |
| `regentStaking` | Where each fleet's treasury deposits the 10% protocol share. On Base it must be REGENT revenue staking, `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`. |
| `autolaunchFactory` | The Autolaunch factory a fleet launches its own token through. On Base it must be Autolaunch Revstake v2's factory, `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E`. |
| `regentsClubPass` | The Regents Club Pass collection: the holder of Pass N receives Regents Club key N. On Base it must be `0x2208aaDBdEcd47D3B4430b5b75a175f6d885D487`, Passes 1 to 1,998. |
| `collection.name`, `collection.symbol` | On Base `Keyfleet` and `KEYFLEET`. |
| `collection.baseTokenURI` | The fixed address every key's metadata is read from: the base followed by the token id. On Base it must be `https://keyfleet.ai/metadata/keys/`. |
| `collection.contractURI` | The collection page's own metadata, `https://keyfleet.ai/metadata/collection.json` in `base.json`. It is not pinned; the record step checks it against the chain. |
| `vrf.coordinator` | The Chainlink VRF v2.5 coordinator. On Base it must be `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`. |
| `vrf.subscriptionId` | The subscription that pays for every request, written as a decimal string because ids are longer than JSON numbers hold exactly. The coordinator must know it. |
| `vrf.keyHash` | The gas lane. On Base it must be the 2 gwei lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` (the release's) or the 30 gwei lane `0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70`. |
| `traitTableHash` | `keccak256` of the published trait table file, byte for byte. Must not be zero. |
| `route.usdc`, `route.weth`, `route.regent` | On Base `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, `0x4200000000000000000000000000000000000006` and `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`. |
| `route.v3Pool` | The USDC/WETH Uniswap v3 pool. On Base the 0.05% pool `0xd0b53D9277642d899DF5C87A3966A349A798F224`. |
| `route.poolManager` | The Uniswap v4 PoolManager. On Base `0x498581fF718922c3f8e6A244956aF099B2652b2b`. |
| `route.v4Pool` | The WETH/REGENT v4 pool key: on Base `currency0` WETH, `currency1` REGENT, `fee` 8388608 (`0x800000`, the hook sets the fee), `tickSpacing` 200, `hooks` `0xd60D6B218116cFd801E28F78d011a203D2b068Cc`. |
| `foundingFleets.classic`, `.syndicate`, `.accelerant`, `.cascade`, `.regentsClub` | Each founding fleet's `deckHash`, `deckSize` and `profile` (`name`, `description`, `imageLink`). |

Prices, supplies and splits are not manifest values: they are fixed in the
contracts. The four sold founding fleets start at 10 USDC, and Accelerant #1
steps 5% per key. The Regents Club is never sold: its 1,998 keys are given.

`base.json` carries the trait table hash
`0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`, the five
founding decks below, profiles named "Classic #1", "Syndicate #1",
"Accelerant #1", "Cascade #1" and "Regents Club #1" with an empty description
and image link, a
zero `keeper` and `"subscriptionId": "0"`. So a Base deployment is refused until
the keeper's address and the Regents subscription id are written in.

| Founding fleet | `deckHash` | `deckSize` |
| --- | --- | --- |
| Classic #1 | `0xe9b1900adb56811096d08f67852af8a64ec509ed2982e94f14f172f687b577e7` | 1000 |
| Syndicate #1 | `0x1298cf785709867c5397762ba4dfa3d4a1c1394db0cd26444285c48cc6e57706` | 1000 |
| Accelerant #1 | `0xbac8510a15a85770ff5cb64b4f0fef57244235ee79327ce3e3e375ce629b6d4d` | 1000 |
| Cascade #1 | `0x2942590c4d3873db390aef50e4648137fdb93729a370105a1aa9a62e43222b66` | 1000 |
| Regents Club #1 | `0xae0f753ba8230305e046ff8811b49f86c6024bbbbaa5e40d659d5e5d2698a67b` | 1998 |

On every founding fleet, key N holds card N of its deck, with no random draw; a
founding key past its deck draws.

`anvil.json` is for a fork of Base on chain 31337: it names Base's own
addresses, the Regents Club Pass included, the same trait table and decks, anvil's first account as keeper,
metadata on `http://localhost:4000`, and a zero subscription for the rehearsal
to write in.

Every Base address is pinned in `contracts/script/KeyfleetManifest.sol` with its
source: USDC from Circle's contract addresses page, the coordinator and gas
lanes from Chainlink's VRF v2.5 supported-networks page
(<https://docs.chain.link/vrf/v2-5/supported-networks>), REGENT and REGENT
revenue staking from Regent's own Base bindings and verified Basescan source,
the Autolaunch factory from Autolaunch Revstake v2's deployment manifest
(6 October 2026), and the swap route from the pools on Base.

## Step 1: the randomness subscription

Every key's card or traits come from one Chainlink VRF random number, and one
subscription pays for every fleet's requests in ETH. Before the deployment:

1. Create the subscription on the Base coordinator (`createSubscription()`, or
   Chainlink's VRF app) and fund it in ETH with
   `fundSubscriptionWithNative(subId)`.
2. Move its ownership to the Regents Safe on Base,
   `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`:
   `requestSubscriptionOwnerTransfer(subId, 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e)`
   from the creator, then `acceptSubscriptionOwnerTransfer(subId)` from the Safe.
3. Write the subscription id into `vrf.subscriptionId` and the keeper wallet's
   address into `keeper` in `base.json`.

### Keeping the subscription funded

The subscription must never run dry. Each answer is paid in ETH at up to the
2 gwei lane's price cap. Sixteen real answers on Base read on 7 October 2026
cost about 0.4 to 1.4 US cents each, about half a cent for a key's
100,000-gas answer.

Chainlink answers a request only while the balance covers its most it could
cost: 200,000 gas for checking the proof plus the 100,000-gas callback, at the
lane's 2 gwei cap, plus the 60% premium, which is 0.00096 ETH, plus an L1 fee
that has been under 0.000001 ETH. Call it 0.001 ETH a key. A request the
balance cannot cover waits up to 24 hours and then expires. Each key gets one
accepted request and never another, so a key whose request expires never gets
its card or traits, and nothing can give it one later.

- **Fund it with 0.5 ETH before the first sale.** That covers 500 keys waiting
  at once at the cap, and about 100,000 answers at today's prices.
- **Never let it fall below 0.25 ETH**, enough for 250 keys waiting at once at
  the cap.
- **Check it by hand.** Nothing watches the balance for you. When it is
  below 0.3 ETH, top it up back to 0.5 ETH. The balance is the second value
  `getSubscription` returns:

  ```sh
  cast call 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 \
    "getSubscription(uint256)(uint96,uint96,uint64,address,address[])" <subId> \
    --rpc-url "$BASE_RPC_URL"
  ```

  Anyone can top it up with `fundSubscriptionWithNative(subId)`.

Pending requests block both removing a consumer and cancelling the
subscription until they are answered, so an empty subscription cannot simply
be closed and replaced.

Anyone can ask again for a key whose request was refused, with
`requestReveal(tokenId)` on the collection. The deck backend asks for the keys
of an open fleet that waited for its deck.

## Step 2: deploy

All commands run from `contracts/`. Base, with a signer that keeps its key in
hardware:

```sh
cd contracts

# Simulated. Sends nothing and writes no deployment file.
KEYFLEET_MANIFEST=base \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address>

# Deployed: five transactions, the four deployers then the factory.
KEYFLEET_MANIFEST=base \
  forge script script/DeployKeyfleets.s.sol:DeployKeyfleets \
  --rpc-url "$BASE_RPC_URL" --ledger --sender <deployer address> --broadcast --slow --verify
```

`--slow` sends each transaction only after the one before has landed, so the
five keep their order. The deploying account must send nothing else until all
five have landed: its fifth contract address from the start is the factory's.
`--verify` wants an explorer API key in `ETHERSCAN_API_KEY`; leave the flag off
and verify afterwards if there is none to hand.

A simulation leaves Forge's own log under
`broadcast/DeployKeyfleets.s.sol/8453/dry-run/`, which git ignores. A broadcast
writes `broadcast/DeployKeyfleets.s.sol/8453/run-latest.json`, which the Safe
steps and the record step read to find the factory.

No private key goes in a file, an environment variable or a command line. No
script reads one: they read the manifest and the chain, and signing is entirely
the caller's business.

### What the deployment step refuses

- A manifest whose `chainId` is not the chain it is running on (`WrongChain`).
- On Base, any pinned field that is not Base's own (`NotBasePin(field)`): the
  Safe, REGENT revenue staking, the Autolaunch factory, the coordinator, the gas
  lane, the collection's name, symbol and metadata base, and every part of the
  swap route.
- A gas lane the coordinator does not know (`VrfKeyHashUnknown`), and a
  subscription it does not know, which includes the placeholder `"0"` (the
  coordinator's own `InvalidSubscription`).
- In the contracts themselves: a staking contract, Autolaunch factory,
  coordinator or route address with no code, a USDC that does not report six
  decimals, a v3 pool that does not hold exactly USDC and WETH, a v4 pool key
  that does not name exactly WETH and REGENT, a zero Safe or keeper, and a zero
  trait table hash.

## Step 3: the collection becomes a consumer

The Safe adds the collection to the subscription with
`addConsumer(subId, <collection address>)`, in the Chainlink app or as a Safe
transaction. The collection's address is `KEYS()` on the factory. A key sold
before this is still sold; its request is refused, and anyone can ask again
with `requestReveal(tokenId)` once the collection is added. The record step
refuses the deployment until the collection is listed.

## Step 4: the founding fleets

```sh
KEYFLEET_MANIFEST=base KEYFLEET_STEP=founding-fleets \
  forge script script/KeyfleetSafeSteps.s.sol:KeyfleetSafeSteps --rpc-url "$BASE_RPC_URL"
```

This sends nothing and needs no signer. It runs one `createFoundingFleet` per
founding fleet the collection does not have yet, in order, from the Safe's
address against Base's current state, and stops at the first call that would
revert with the collection's or factory's own error. It then writes each call as
its own Safe Transaction Builder file:

- `deployments/safe/base.founding-fleet-1.json` (Classic #1)
- `deployments/safe/base.founding-fleet-2.json` (Syndicate #1)
- `deployments/safe/base.founding-fleet-3.json` (Accelerant #1)
- `deployments/safe/base.founding-fleet-4.json` (Cascade #1)
- `deployments/safe/base.founding-fleet-5.json` (Regents Club #1)

The Safe's signers load each file in the Safe's Transaction Builder, check it
and sign it, one after another in that order: each creation uses about 11.8
million gas, so each is its own transaction. Run the step again after some have
landed and it writes files only for the fleets still missing. Each founding
fleet is created with its deck and no joining requirements, and its sales stay
closed.

## Step 5: record

Once the broadcast has finished, the collection is a consumer and the founding
fleets exist:

```sh
KEYFLEET_MANIFEST=base \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$BASE_RPC_URL"
```

It sends nothing and needs no signer. It writes
`contracts/deployments/base.deployed.json`. Run it again at any time to add the
fleets created since: it lists every fleet in the collection's registry.

### What the record step refuses

- A broadcast with a transaction that has no receipt (`BroadcastIncomplete`) or
  a receipt that did not succeed (`BroadcastReceiptFailed`), or one that created
  no factory (`FactoryNotInBroadcast`).
- A factory with no code on the chain it is run against (`FactoryMissing`).
- The same chain, pin, gas lane and subscription refusals as the deployment
  step.
- Any system value that differs from the manifest, read back from the chain
  (`RecordedMismatch(field)`): the Safe, the keeper, the collection's name,
  symbol, metadata base and collection metadata address, the coordinator,
  subscription and gas lane, the trait table hash, REGENT staking, the
  Autolaunch factory, the Regents Club Pass and claims contract, the shard
  record and every part of the swap route.
- A fleet whose four contracts are not where the factory places them, hold no
  code or do not point at each other, the collection and the fleet, or a
  founding fleet of another type or deck than the manifest's
  (`FleetNotBound(fleetId, part)`).
- A collection the subscription does not list as a consumer
  (`CollectionNotVrfConsumer`).
- On Base, a subscription whose owner is not the Regents Safe
  (`VrfSubscriptionNotOwnedByRegentsSafe`).

### What the record step writes

`contracts/deployments/base.deployed.json`, the one published record of the
system and every fleet. Every address and value is read from the chain, not
copied from the manifest. The supply, price and split constants come from the
`KeyfleetPresets` library the record step was compiled with, and every
contract's runtime code hash is recorded so anyone can check later that the
deployed code is the code those constants came from. It carries:

- `chainId` and `deploymentBlock`, the lowest block the deployment's
  transactions landed in, so a reader starting there misses nothing;
- `factory`: its address and code hash and its four deployers with theirs;
- `collection`: address, code hash, name, symbol, metadata base, collection
  metadata address, the Safe, the keeper and the royalty in basis points;
- `shards`: address and code hash;
- `regentBuyer`: address, code hash and the whole route;
- `usdc`, `regent`, `regentStaking`, `autolaunchFactory` and `regentsClubPass`;
- `clubClaims`: the Regents Club claims contract's address and code hash;
- `vrf`: the coordinator and its code hash, the subscription id as a decimal
  string, the gas lane, the three block confirmations, the 100,000 gas each
  answer is given, and that requests are paid in ETH;
- `traitTableHash`;
- `startPrice`: the lowest and highest starting price anyone may choose and
  its step, one cent, in atomic USDC;
- `bounds`: the three supply limits, Classic's 1,024 keys, the Regents Club's
  1,998 and Accelerant's 2,000 (Syndicate and Cascade have none);
- `fees`: the 10% protocol share, the Accelerant 20% capital share and the
  basis-point denominator;
- `fleets`, keyed by fleet number: each fleet's type, its number within its
  type, starting price, deck fingerprint and size (zero until recorded for an
  open fleet), its manager, votes, treasury and rewards addresses each with its
  code hash, its name, description and image link, its joining requirements,
  the tag its protocol share deposits carry, and the assets its daily split
  shares;
- `disclosures`: public-read chat, no refunds, service rewards to keys only,
  what the 10% fee and the 2.5% royalty are, that the treasury's part is turned
  into REGENT afterwards, a little at a time, at the market price with no
  minimum, and what the Regents Safe can and
  cannot do.

There is no configuration screen anywhere in the product, so this file is where
those values are published, and it is what the site is seeded from.

## Step 6: phases

Run only when the founder says when the next fleets' sales open, with that
moment as a Unix time in `KEYFLEET_OPENS_AT`:

```sh
KEYFLEET_MANIFEST=base KEYFLEET_STEP=advance-phase KEYFLEET_OPENS_AT=<unix time> \
  forge script script/KeyfleetSafeSteps.s.sol:KeyfleetSafeSteps --rpc-url "$BASE_RPC_URL"
```

The Safe's transaction must land before that moment, or the collection refuses
it (`OpensAtInvalid`) and the step is written again with a later time; a phase
also never opens before the previous one, nor more than 30 days after the
transaction lands. The phase number changes when the
transaction lands, and what it opens waits for the named moment.

It checks the step against Base's current state as the Safe and writes one file,
`deployments/safe/base.phase-1.json`, `base.phase-2.json` or
`base.phase-3.json`, for the founder to sign. Phase 1 needs all five founding
fleets and opens Classic #1's sales and the Regents Club's gifts together.
Phase 2 opens Syndicate #1, Accelerant #1 and Cascade #1's sales together.
Phase 3 lets anyone create a fleet
from its opening, and each such fleet sells from the moment it is created. There is no step back, and nothing
else moves a phase.

## Step 7: Regents Club gifts

Run once phase 1 has opened:

```sh
KEYFLEET_MANIFEST=base KEYFLEET_STEP=club-gifts \
  forge script script/KeyfleetSafeSteps.s.sol:KeyfleetSafeSteps --rpc-url "$BASE_RPC_URL"
```

It sends nothing and needs no signer. It reads every Pass not given a key yet
at Base's latest block: key N goes to the wallet holding Pass N, or to the
claims contract (`CLUB_CLAIMS()` on the factory) when that holder is a contract
that does not answer the NFT receiver check, so would refuse the key, or when
Pass N has been burned. It checks every call as the Safe against Base's
current state, then writes one file per 80 keys,
`deployments/safe/base.club-gifts-1-80.json` to
`base.club-gifts-1921-1998.json`, for the founder to sign in order. Each uses
about 13.2 million gas. No money moves.

A Pass that changes hands after the step ran makes its batch revert whole, since
the contract gives key N only to the current holder of Pass N or to the claims
contract. Run the step again: it writes files only for the keys still not
given, read afresh. Whoever holds Pass N can later take a key held for it with
`claim(N)` on the claims contract, at any time, together with what it earned
while it waited. A key held for a burned Pass stays held, since nobody holds
that Pass.

A holder contract that answers the receiver check but still refuses the real
gift makes its whole batch revert, and the step reads it the same way again.
Name its key numbers in `KEYFLEET_CLUB_TO_CLAIMS`, comma-separated, and run the
step again: those keys go to the claims contract whoever holds their Pass.

```sh
KEYFLEET_MANIFEST=base KEYFLEET_STEP=club-gifts KEYFLEET_CLUB_TO_CLAIMS=212,977 \
  forge script script/KeyfleetSafeSteps.s.sol:KeyfleetSafeSteps --rpc-url "$BASE_RPC_URL"
```

## Fleets anyone creates

From phase 3 anyone may call `createFleet` on the factory, buying the new
fleet's key 1 in the same transaction. Such a fleet starts with no card deck, so
its keys wait for their random numbers. The deck backend sees `FleetCreated`,
builds the fleet's deck by the same process as the founding fleets, records it
from the keeper wallet with `setDeck(fleetId, deckHash, deckSize)`, then calls
`requestReveal(tokenId)` for each key minted while the fleet waited. Keys minted
afterwards ask at mint. Rerun the record step to add the new fleet to the
published record.

## The trait table

`traitTableHash` is `keccak256` of the trait table file itself, byte for byte.
Nothing is normalised or re-encoded before hashing, so the hash is taken of
exactly the bytes that are committed, with keccak256 (not the standardised
SHA3-256, which gives a different result). Once the system is deployed the file
can never change: a changed byte is a different hash, and the collection holds
the original one. The contracts README gives the rule that draws traits from a
key's seed and this table, for keys beyond their fleet's card deck.

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

The table ships with the site as `platform/priv/trait_tables/<traitTableHash>.json`,
named by the hash in lowercase `0x` hex. The site uses it only if its
`keccak256` is that name.

## Key metadata

The collection's `tokenURI` is `https://keyfleet.ai/metadata/keys/` followed by
the token id, which is the fleet number times 10^10 plus the key number. The
site answers it for every key sold, and nothing for a key not yet sold:

- the key's name, `<TYPE>—<fleet number>—<key number>`, each number padded to
  three digits, or four from 1,000, such as `CLASSIC—001—072`;
- traits that include `Fleet type`, `Fleet number`, the fleet's name and the key
  number, so a marketplace's trait filter narrows the one collection to one
  fleet;
- an interim picture until the key's permanent card is published, then the
  card, with its picture on `https://media.regents.sh/ipfs/<cid>`.

When a key's permanent card is published, the backend or the key's holder calls
`refreshMetadata(tokenId)`, and marketplaces fetch the card. A change to a
fleet's name, description or image link makes the collection announce a refresh
of all the fleet's keys.

## Rehearsing

Every purchase is paid in Base USDC, and the treasury's part becomes REGENT
through the real REGENT pools a piece at a time, so a rehearsal that buys keys
runs on a fork of Base.

**The fork suites.** With `BASE_RPC_URL` set, the suites in
`contracts/test/fork/` deploy the system from the committed Base manifest
through the real deployment and Safe steps, and run fleets, the swap, Lit and
Autolaunch against Base's own contracts. The contracts README lists them.

**A plain Base fork, for the Base manifest.**

```sh
anvil --fork-url "$BASE_RPC_URL"
```

This keeps Base's chain id, 8453, so the Base manifest deploys there exactly as
it would on Base, and the Safe steps write their files instead of sending.
Create and fund a subscription on the fork from an anvil account and write its
id and a keeper into the manifest for the rehearsal only; the record step will
then refuse it because the Regents Safe does not own the subscription, which is
the Base rule working. A fork rehearsal writes
`broadcast/DeployKeyfleets.s.sol/8453/`, `deployments/safe/base.*.json` and,
if it gets that far, `deployments/base.deployed.json`. Delete all three, and put
the manifest's keeper and subscription back, before the real deployment, so
nobody mistakes the rehearsal for the release. Git keeps those paths on purpose:
the Base broadcast log, the Safe's batch files and `base.deployed.json` are the
evidence of the real deployment and are committed with it, while everything a
chain-31337 rehearsal writes is ignored.

**A fork on chain 31337, for the anvil manifest.**

```sh
anvil --fork-url "$BASE_RPC_URL" --chain-id 31337
export RPC_URL=http://127.0.0.1:8545
```

Write a subscription created on the fork into `anvil.json`, then deploy with
`KEYFLEET_MANIFEST=anvil`, `--rpc-url "$RPC_URL"`, and
`--broadcast --unlocked --sender <anvil account>` in place of the hardware
signer. On chain 31337 the Safe steps send their calls straight from the Safe's
address, so let anvil act as the Safe first:

```sh
cast rpc anvil_impersonateAccount 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e --rpc-url "$RPC_URL"
cast rpc anvil_setBalance 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e 0x56BC75E2D63100000 --rpc-url "$RPC_URL"

KEYFLEET_MANIFEST=anvil KEYFLEET_STEP=founding-fleets \
  forge script script/KeyfleetSafeSteps.s.sol:KeyfleetSafeSteps \
  --rpc-url "$RPC_URL" --broadcast --unlocked
```

The subscription's owner adds the collection before the record step:

```sh
cast send 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634 "addConsumer(uint256,address)" \
  <subscription id> <collection address> --from <anvil account> --unlocked --rpc-url "$RPC_URL"

KEYFLEET_MANIFEST=anvil \
  forge script script/RecordKeyfleets.s.sol:RecordKeyfleets --rpc-url "$RPC_URL"
```

USDC for a purchase comes from a fork address that already holds it. Amounts are
atomic USDC: 10000000 is 10 USDC, the first key of every founding fleet.

```sh
cast rpc anvil_impersonateAccount <address holding USDC> --rpc-url "$RPC_URL"
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "transfer(address,uint256)" \
  <wallet> <atomic USDC> --from <address holding USDC> --unlocked --rpc-url "$RPC_URL"
cast rpc anvil_stopImpersonatingAccount <address holding USDC> --rpc-url "$RPC_URL"
```

The wallet approves the fleet's manager for the price and calls `purchase` on
the manager. Buy with a fresh address, not one of anvil's default accounts,
which may carry delegated code on a fork whose NFT callback reverts, so a key
minted to it fails.

**The anvil lab.** `contracts/script/AnvilLab.s.sol` is no part of a release:
it puts the system with Classic #1 on a plain local anvil, with stand-ins for
USDC, WETH, REGENT, both pools, REGENT staking, the coordinator and the
Autolaunch factory, for the site's anvil tests.

**The Base-fork lab.** `contracts/script/BaseForkLab.s.sol`, run by
`contracts/script/base-fork-lab.sh`, is no part of a release either: it puts the
system with Classic #1 selling on a local fork of Base run as chain 31337, for
the site on `http://localhost:4097`, so a wallet can buy a key with Base's own
USDC, and the treasury's part becomes REGENT through Base's own swap route. Everything comes from `base.json` except
the chain id, the Safe and keeper (anvil's first two default accounts), the
metadata addresses on the local site and a stand-in VRF coordinator. Every step
refuses any chain but 31337.

```sh
anvil --fork-url https://base.drpc.org --chain-id 31337 --port 8546

cd contracts
export KEYFLEET_LAB=http://127.0.0.1:8546
script/base-fork-lab.sh deploy <buyer address> [<buyer address> ...]
script/base-fork-lab.sh fund <buyer address> [...]   # more buyers later
script/base-fork-lab.sh fulfil                      # answer waiting card draws
```

`deploy` names a sales opening 10 minutes ahead, as the Safe must, then moves
the lab chain's clock past it, so Classic #1 sells at once. It writes
`contracts/deployments/base-fork-lab.json` in the shape of the release's
deployed record (`base.deployed.json`), and gives each buyer 100 ETH and exactly
1,000 USDC. No key is bought. On the lab chain, nobody presses the REGENT
buyer's `convert(250000000)` unless you do, once a piece is due. A buyer must be
a plain address with no code on Base: anvil's third default account
(`0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC`) has code on Base that passes on
any key it receives, so a purchase to it reverts.

## What the Safe does

The Regents Safe on Base, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, owns the
randomness subscription and REGENT revenue staking. In the release it adds the
collection to the subscription, creates the five founding fleets, moves the
phase when the founder says sales open, and gives the Regents Club keys, each
only to the holder of its Pass or to the claims contract. Later it may replace
the keeper or allow a newer factory for new fleets; existing fleets never
change. It receives the 2.5% resale royalty. It has no vote, claim or price in
any fleet, cannot mint any other key or move any key, and cannot move a fleet's
money.

## A fleet's Lit account

A fleet's treasury owns its Lit account on Base. Setting it up is the key
holders' business after the fleet exists, by proposals: each proposal's calls go
from the treasury to Lit's account contract,
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
takes 10% of each key purchase, once, in USDC, and nothing from money a fleet
receives afterwards. Every purchase sets its 10% aside in the fleet manager's
`protocolShareOwed`, and anyone may call `sendProtocolShare()` on the manager,
which deposits the whole owed amount into REGENT revenue staking on Base for
REGENT stakers. Every other amount a fleet's treasury receives is its capital,
spent only by a passed proposal's exact calls, apart from the daily split that
shares a small part of its ETH, REGENT and USDC among the keys.

**One collection, phases, and fleets anyone can create (7 October 2026).** One
collection named "Keyfleet" with the symbol KEYFLEET holds every key, with a
2.5% resale royalty to the Regents Safe. The Safe opens sales in three phases.
In phase 3 anyone creates a fleet of any type at a starting price from 10 to
1,000,000 USDC, buying its key 1, with an optional address list, NFT or token
balance as joining requirements. A fleet's name, description and image link
change only by its keys' vote.

**The treasury holds REGENT (7 October 2026), a piece at a time (8 October
2026).** Keys are paid in USDC. The treasury's part of every purchase is booked
in the fleet's manager, and the shared REGENT buyer turns it into REGENT for the
treasury in pieces of at most 250 USDC, no faster than 250 USDC every 15
minutes across all fleets, at the market price with no minimum, through one
fixed route. Anyone may trigger a piece and may ask for a smaller one, which
waits in proportion, and a piece that would itself move the route's price more
than 1% is refused. Front-running a piece is unprofitable only because the
REGENT pool's hook charges at least 1% on every swap.

**The fleet's own token (6 October 2026).** A fleet may launch its own token
through Autolaunch Revstake v2 on Base, by a passed proposal's call from its
treasury to the factory, naming the treasury as the launch's treasury.
Autolaunch's own fees, vesting and liquidity are the factory's and Keyfleet
changes none of them. Once the launch has sold, anyone may bind its token to the
daily split, once, from the next run, at 100 tokens; only tokens already
released to the treasury are split. Autolaunch opens its factory to launches
only when the Regents Safe unpauses it; until then no fleet can launch.

**The key price.** Every key is paid in USDC on Base and every price scales from
the fleet's starting price. The founding fleets start at 10 USDC. Fibonacci
levels step by 1.2, with no last level, and Accelerant primary mints by the
fleet's step, 1% to 5% chosen by its creator (5% for Accelerant #1), up to 2,000
keys. Classic's 1,024 keys run from the starting price to ten times it; at
10 USDC that is 10 USDC for the first to 100 USDC for the last, each key about
0.2253% dearer than the one before, rounded to the nearest cent, and
40,040.48 USDC for all of them. An Accelerant key after the
first sends 20% to the treasury and 70% to the holder of the key before it.

**Cards and randomness.** Every fleet's cards come from a pre-made deck, of
which only the fingerprint and size are on chain; decks stay private and only
the rarities are public. Every key's random number comes from Chainlink VRF
v2.5, paid from one Regents subscription in ETH on Base's 2 gwei lane, and a
key asks for it only once its fleet has a deck. Keys beyond a fleet's deck use
the trait draw from the one trait table the collection fixes.

Open questions for the founder, each with the recommendation the build follows
until answered, are in
[fleet-manager-factory-design.md](fleet-manager-factory-design.md#13-questions-only-sean-can-answer):
who records an open fleet's deck (the keeper wallet, recommended), who triggers
a key's permanent card (the backend, recommended), and which fleet number a
key's name shows (the number within its type, recommended).
