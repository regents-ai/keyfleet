# The anvil lab

A local chain holding one Keyfleet Classic fleet built from the real contracts, and the site on
http://localhost:4097 sending every wallet button to that chain, with real Privy sign-in. Your
wallet is given keys 1 and 2, at least 1 ETH and 10,000 of the lab's USDC.

## Start it

From this `platform` directory, with your own wallet address:

```sh
direnv exec /Users/sean/Documents/regent/repos/keyfleet/platform scripts/anvil-lab.sh 0xYourWallet
```

- The chain answers at http://127.0.0.1:8546 (chain id 31337, a block every 2 seconds).
- The site answers at http://localhost:4097, reading the lab's own database, `keyfleet_lab_dev`.
- Ctrl-C stops both. The chain is saved in `tmp/anvil-lab`, so starting again keeps the fleet and
  everything done with it. Starting with another wallet moves keys 1 and 2 to that wallet.
- Privy must allow `http://localhost:4097` as an origin for the app.
- The first button you press asks your wallet to add the network "Keyfleet lab"; say yes.

## Moving time

Votes close, presence lasts 48 hours and the daily split opens a day after the first sale. To jump
ahead, in another terminal (the jump shows from the next block, 2 seconds later):

```sh
cast rpc evm_increaseTime 3600 --rpc-url http://127.0.0.1:8546    # an hour
cast rpc evm_increaseTime 86400 --rpc-url http://127.0.0.1:8546   # a day
```

## What to try

Sign in at http://localhost:4097/account with the wallet you started the lab with.

Fleet page, http://localhost:4097/app/fleets/fleet_tech_classic

- **Buy key**: Approve, then Buy key. Key 3 shows as yours.
- **Token launch** panel, once a launch proposal is carried out (below): Settle the sale is
  disabled with "Sale still running" until about 20 seconds have passed, then works; Add to the
  daily split works after settling; Release tokens and Collect pool fees work once added. Each
  disabled button says why in a few words and comes back by itself.

Key page, http://localhost:4097/app/keys/fleet_tech_classic/1

- **Mark present** marks keys 1 and 2 in one transaction; the card then says present until when.
  After a two-day jump it says not present.
- **Issue a shard** to a second wallet you own; then End or Renew it. **Let shards vote** and
  **Stop shards voting** switch for both keys at once.
- **Claim** per asset, after the daily split has run: paid to the key's holder, also when the
  shard's wallet presses it. With nothing to claim the button says "Nothing to claim".
- **Ask again for the draw**: the lab never draws traits, so the key stays undrawn.

Proposals page, http://localhost:4097/app/fleets/fleet_tech_classic/proposals

- **Treasury**: 1 ETH, 500 REGENT and 500 USDC, set aside for claims, advances out, the rate and
  the next split. **Run the daily split** says when it opens; jump a day and it works, and the
  preview shows each asset's balance, threshold, amount per key, last run and next opening.
- **Propose** each kind: Decision, Payment, Advance, Daily split rate (0.10–2.00%), A key's
  edits, Signature (approve or revoke) and Token launch, voting for 1, 6, 24 or 48 hours.
- **Tidy up** clears proposals whose time to carry out has passed.

A proposal's page, http://localhost:4097/app/fleets/fleet_tech_classic/proposals/1

- Shows what it does in plain words, Yes, No and Abstain, how many keys were present, when voting
  closes and when it must be carried out by.
- **Vote yes**, **Vote no**, **Abstain**, with keys 1 and 2 at once. **Cancel** while open.
- Jump past the close, then **Carry it out**: a payment arrives, an advance shows under
  Advances out with **Return**, a new rate shows in Treasury.

## Starting over

Stop the lab, then remove `tmp/anvil-lab` and the `keyfleet_lab_dev` database yourself. The next
start builds a new chain and records its fleet. A lab whose chain was removed while the database
was kept refuses to start and says so.
