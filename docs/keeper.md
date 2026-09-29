# Running the keeper

The keeper is the one part of the site that sends transactions. It runs inside
the site on Ethereum, from one wallet Regent keeps for nothing else, and sends
only two permissionless calls, both to a fleet's own contract. Neither lets the
caller choose where money goes:

- every 30 seconds, `requestReveal(tokenId)` for keys with no seed whose
  request the coordinator never accepted;
- every hour, starting five minutes after the site starts, it checks each
  fleet's `protocolShareOwed()`, and once a day for each fleet that owes any,
  sends `sendProtocolShare()`, which moves the whole owed 10% in USDC to the
  Regents Safe fixed in the fleet.

It holds itself to these limits. The amounts are set in `platform/config/config.exs`
under `Keyfleet.Keeper`; the proposed Ethereum values, and why each was chosen,
are below.

| Limit | What happens |
|---|---|
| Base fee above `max_fee_wei` (3 gwei) | Reveals wait, and nothing is sent, until the fee falls. No transaction ever offers more than this per unit of gas. |
| A fleet's randomness subscription under `min_vrf_balance_wei` (0.1 ETH) | That fleet's reveals wait until the subscription is funded. |
| `daily_spend_wei` (0.02 ETH) spent in 24 hours | Nothing is sent until the day's spending falls back under it. |
| The wallet under `low_balance_wei` (0.02 ETH) | An alert asks for it to be topped up. |
| No receipt after 60 seconds (30 checks, two seconds apart) | The same transaction is raised by a quarter, at the same nonce, up to three times, never above `max_fee_wei`. |
| Someone else uses the wallet | The keeper stops, and stays stopped across restarts until it is resumed by hand. |

### Why these values

Ethereum makes a block every 12 seconds. A reveal is sent with at least
200,000 gas and a protocol share with its estimate plus 30%, so each call costs
at most about 0.0006 ETH at 3 gwei. The values are a proposal: the founder
approves them before the wallet or any subscription is funded.

| Setting | Value | What it protects | Why |
|---|---|---|---|
| `max_fee_wei` | 3 gwei | The wallet, from paying for a fee spike. | Ethereum's base fee has mostly sat well under 3 gwei; none of these calls is urgent, so waiting out a spike costs nothing. |
| `daily_spend_wei` | 0.02 ETH | The wallet, from a bug or loop draining it in a day. | About 30 calls at the highest fee: far more than a normal day's reveals and four protocol shares. |
| `low_balance_wei` | 0.02 ETH | Sending, from stopping because the wallet ran dry. | One full day's spending ceiling, so there is a day to top it up. |
| `min_vrf_balance_wei` | 0.1 ETH | Reveals, from requests Chainlink would refuse. | Chainlink holds back roughly the cost of a request at the 200 gwei lane's price cap before it accepts one; 0.1 ETH covers that with room. |
| Receipt wait | 60 seconds | Stuck transactions, from waiting forever. | Five Ethereum blocks: long enough that a fair fee is mined, short enough to raise a stuck one soon. |

Everything below uses the names of secrets, never their values. Commands that
read a secret read it from your terminal without echoing it.

## What you need

- [Foundry](https://book.getfoundry.sh) for `cast`.
- [flyctl](https://fly.io/docs/flyctl/install/), logged in to the Regent
  organization, with access to the `keyfleet` app (and `keyfleet-staging` for
  staging).
- A password manager for the keeper's key.
- ETH on Ethereum to fund the wallet.

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

Once the founder approves the limits, send 0.05 ETH on Ethereum to the address,
and top it up whenever the keeper alerts that it is under 0.02 ETH. Staging gets its own wallet, made and funded the same
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

You should see `Keeper on: sending from 0x… on chain 1.`, naming your
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
hours against the 0.02 ETH limit, and what it may still spend on transactions
waiting to be included; and its last 20 transactions, each with its function,
fleet, nonce, outcome and hash. A round is recorded only when it sent something
or a pause began or ended, so a quiet keeper shows old rounds. Each hash can be
looked up on [Etherscan](https://etherscan.io).

The site's metrics, served at `/metrics` on the private metrics port (9091 on
Fly), carry the keeper's figures:

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
| the wallet is under 0.02 ETH | Send it more ETH on Ethereum. Nothing else is needed. |
| the base fee is above 3 gwei | Nothing. Reveals go on by themselves once the fee falls, and a line says so. |
| a fleet's VRF subscription holds under 0.1 ETH | Fund the subscription (below). Reveals go on by themselves. |
| a fleet is not a consumer of its VRF subscription | The Safe adds the fleet to the subscription, as in [deployment](deployment.md#what-the-safe-does-next). |
| the VRF coordinator refused a reveal | Nothing at first: the keeper waits an hour for that fleet and asks again. If it keeps happening, check the subscription and Chainlink's status. |
| sending would take the day's spending past 0.02 ETH | Look at the last transactions with `keeper-status`. Sending goes on by itself when the day's spending falls. |
| a transaction reverted | Look it up on Etherscan. The keeper goes on; a call that keeps reverting is a bug to report. |
| the node refused a transaction, or gave a receipt it cannot have | Usually the node. Check the RPC provider; the keeper tries again next round. |
| the keeper has stopped sending | See below. |

## When it stops

The keeper stops when:

- the wallet has transactions pending that the keeper did not send;
- another transaction took a nonce where the keeper had sent one;
- the node names a different hash for a transaction than the keeper signed.

Each means something other than the keeper may be using the wallet. Nothing is
sent until a person has looked. Check the wallet's history on Etherscan. If
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
never does. Its coordinator and id are in every fleet's deployed manifest, such
as `contracts/deployments/ethereum.classic.deployed.json`, under `vrf`. From a
wallet of your own:

```sh
cast send <coordinator> "fundSubscriptionWithNative(uint256)" <subscription id> \
  --value 0.2ether --rpc-url <Ethereum RPC> --ledger
```

Use `--ledger` or `--trezor` as you sign; never paste a key into the command.
Keep at least 0.2 ETH in it, twice the keeper's 0.1 ETH floor. [Deployment](deployment.md#keeping-the-subscription-funded)
explains why it must never run dry.

## Turning it off

```sh
fly secrets unset KEYFLEET_KEEPER_PRIVATE_KEY -a keyfleet
```

The site restarts with `Keeper off` and sends nothing. Keys can still be
revealed, and the protocol share sent, by anyone calling the same functions by
hand.

## Changing the wallet

1. Make and fund a new wallet, as above.
2. Run `keeper-status` and wait until none of the old wallet's transactions is
   waiting.
3. Turn it on with the new key. The keeper starts afresh with the new wallet
   and never touches what the old one sent.
4. Move what is left in the old wallet to the new one, from your own machine:
   `cast send <new address> --value <amount> --rpc-url <Ethereum RPC> --interactive`,
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
  command runs the rewards and wallet-button labs on anvils of their own, and
  the release package's external test, which needs Docker.
