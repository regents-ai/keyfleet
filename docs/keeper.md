# Running the keeper

The keeper is the one part of the site that sends transactions. It runs inside
the site on Base, from one wallet Regent keeps for nothing else, and sends only
eight permissionless calls. None of them lets the caller choose where money
goes:

- every 30 seconds, `requestReveal(tokenId)` for keys that were sold but never
  got their random seed;
- every hour, starting five minutes after the site starts, for each fleet whose
  launch has graduated: `release()` on its vesting escrow, `collect(lpTokenId)`
  on its LP locker, `sweep(token)` on its payment receiver,
  `recognizeSurplusRevenue(token)` on its splitter and `recognizeSurplus(token)`
  on the fleet, each only when the chain says it would move something, and
  `syncLaunch()` on a fleet whose auction has ended but which has not yet
  recorded the result;
- once a day for each fleet, `sendProtocolShare()` while the fleet owes any.

It holds itself to these limits, which are fixed in the code:

| Limit | What happens |
|---|---|
| Base fee above 2 gwei | Reveals wait, and nothing is sent, until the fee falls. |
| A fleet's randomness subscription under 0.02 ETH | That fleet's reveals wait until the subscription is funded. |
| 0.01 ETH spent in 24 hours | Nothing is sent until the day's spending falls back under it. |
| No receipt after 30 seconds | The same transaction is raised by a quarter, at the same nonce, up to three times, never above 2 gwei. |
| Someone else uses the wallet | The keeper stops, and stays stopped across restarts until it is resumed by hand. |

Everything below uses the names of secrets, never their values. Commands that
read a secret read it from your terminal without echoing it.

## What you need

- [Foundry](https://book.getfoundry.sh) for `cast`.
- [flyctl](https://fly.io/docs/flyctl/install/), logged in to the Regent
  organization, with access to the `keyfleet` app (and `keyfleet-staging` for
  staging).
- A password manager for the keeper's key.
- ETH on Base to fund the wallet.

The site must already read the chain: `KEYFLEET_RPC_URL` is set on the app. The
keeper signs through the same node.

## Making the wallet

On your own machine:

```sh
cast wallet new
```

It prints an address and a private key. Put the key straight into your password
manager, and never into a chat, a ticket, a file in the repository or your shell
history. Use a new wallet for the keeper alone: if anything else sends from it,
the keeper stops.

Send 0.05 ETH on Base to the address, and top it up whenever the keeper alerts
that it is under 0.01 ETH. Staging gets its own wallet, made and funded the same
way. Never give staging production's key.

## Turning it on

```sh
read -rs K && printf 'KEYFLEET_KEEPER_PRIVATE_KEY=%s\n' "$K" | fly secrets import -a keyfleet; unset K
```

Paste the key at the silent prompt and press Enter. Fly restarts the site with
the new secret. For staging, use `-a keyfleet-staging` and the staging key.

Then check it came up:

```sh
fly logs -a keyfleet | grep Keeper
```

You should see `Keeper on: sending from 0x… on chain 8453.`, naming your
wallet's address. The site refuses to start, and says why without printing the
key, if `KEYFLEET_KEEPER_PRIVATE_KEY is malformed` or if the key is set but
`KEYFLEET_RPC_URL` is not. With no key at all it starts with
`Keeper off: no KEYFLEET_KEEPER_PRIVATE_KEY in production; nothing on this site
sends transactions.`

## Checking on it

```sh
fly ssh console -a keyfleet -C /app/bin/keeper-status
```

It prints the wallet's address; whether the keeper is stopped, and why; each
job's last recorded round; the wallet's balance; what it spent in the last 24
hours against the 0.01 ETH limit, and what it may still spend on transactions
waiting to be included; and its last 20 transactions, each with its function,
fleet, nonce, outcome and hash. A round is recorded only when it sent something
or a pause began or ended, so a quiet keeper shows old rounds. Each hash can be
looked up on [Basescan](https://basescan.org).

The site's `/metrics` page carries the keeper's figures:

| Metric | Meaning |
|---|---|
| `keyfleet_keeper_tx_total{function,outcome}` | Transactions settled, by call and by `mined`, `reverted`, `replaced` or `replaced_externally`. |
| `keyfleet_keeper_paused_total{job,reason}` | Each time a job paused or the keeper stopped, and why. |
| `keyfleet_keeper_wallet_balance_wei` | The wallet's balance. |
| `keyfleet_keeper_spent_24h_wei` | Spent in the last 24 hours, with anything still waiting at its highest possible cost. |
| `keyfleet_keeper_vrf_native_balance_wei{fleet}` | Each fleet's randomness subscription balance. |
| `keyfleet_keeper_reveals_waiting{fleet}` | Of the keys the last round looked at, those still waiting more than two minutes for a seed. |

## Alerts, and what to do

Every alert is one log line starting `Keeper alert:`. Watch for it with
`fly logs -a keyfleet | grep "Keeper alert"`.

| The alert says | Do this |
|---|---|
| the wallet is under 0.01 ETH | Send it more ETH on Base. Nothing else is needed. |
| the base fee is above 2 gwei | Nothing. Reveals go on by themselves once the fee falls, and a line says so. |
| a fleet's VRF subscription holds under 0.02 ETH | Fund the subscription (below). Reveals go on by themselves. |
| a fleet is not a consumer of its VRF subscription | The Safe adds the fleet to the subscription, as in [deployment](deployment.md#what-the-safe-does-next). |
| the VRF coordinator refused a reveal | Nothing at first: the keeper waits an hour for that fleet and asks again. If it keeps happening, check the subscription and Chainlink's status. |
| sending would take the day's spending past 0.01 ETH | Look at the last transactions with `keeper-status`. Sending goes on by itself when the day's spending falls. |
| a transaction reverted | Look it up on Basescan. The keeper goes on; a call that keeps reverting is a bug to report. |
| a launch record, distribution, escrow, splitter or receiver pays someone other than the fleet | Nothing is sent for that fleet's income. Report it at once: the launch is not wired as the fleet expects. |
| the node refused a transaction, or gave a receipt it cannot have | Usually the node. Check the RPC provider; the keeper tries again next round. |
| the keeper has stopped sending | See below. |

## When it stops

The keeper stops when:

- the wallet has transactions pending that the keeper did not send;
- another transaction took a nonce where the keeper had sent one;
- the node names a different hash for a transaction than the keeper signed.

Each means something other than the keeper may be using the wallet. Nothing is
sent until a person has looked. Check the wallet's history on Basescan. If
someone else has the key, turn the keeper off and rotate (below). Once the
wallet is the keeper's alone again:

```sh
fly ssh console -a keyfleet -C /app/bin/keeper-resume
fly apps restart keyfleet
```

`keeper-resume` prints the stop it cleared. The keeper sends again after the
restart, and first settles anything it left waiting.

## Funding a randomness subscription

The Regents Safe owns the subscription, but anyone may fund it, and the keeper
never does. Its coordinator and id are in `contracts/deployments/base.deployed.json`,
under `vrf`. From a wallet of your own:

```sh
cast send <coordinator> "fundSubscriptionWithNative(uint256)" <subscription id> \
  --value 0.05ether --rpc-url <Base RPC> --ledger
```

Use `--ledger` or `--trezor` as you sign; never paste a key into the command.
Keep about 0.05 ETH in it. [Deployment](deployment.md#keeping-the-subscription-funded)
explains why it must never run dry.

## Turning it off

```sh
fly secrets unset KEYFLEET_KEEPER_PRIVATE_KEY -a keyfleet
```

The site restarts with `Keeper off` and sends nothing. Keys can still be
revealed, and income moved, by anyone calling the same functions by hand.

## Changing the wallet

1. Make and fund a new wallet, as above.
2. Run `keeper-status` and wait until none of the old wallet's transactions is
   waiting.
3. Turn it on with the new key. The keeper starts afresh with the new wallet
   and never touches what the old one sent.
4. Move what is left in the old wallet to the new one, from your own machine:
   `cast send <new address> --value <amount> --rpc-url <Base RPC> --interactive`,
   which asks for the old key without echoing it.

## Testing it locally

From `platform/`:

- `mix test` runs the keeper's tests against a stand-in node. They need no
  chain and no key.
- `mix test.external` runs the keeper against a real node: it starts its
  own anvil on a free local port, builds a fleet on it with
  `contracts/script/KeeperLab.s.sol`, and drives the keeper's reveals and
  protocol share through it, including a request raised three times while no
  block is mined. It needs Foundry's `anvil` and `forge` on the path, uses only
  anvil's public test accounts, and stops its anvil when it finishes. The same
  command runs the release package's external test, which needs Docker.
