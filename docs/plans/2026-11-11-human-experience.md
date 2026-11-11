# Human experience: what people hit, and the order to fix it

11 November 2026. Keyfleet lane. Read-only: built from the source on main (5c650c5d) and
the onboarding branch `kf/onboarding-1106` (59606365). Every "now" line comes from the
code, not a screen; each change is checked on localhost before it ships.

## First visit today

1. **Home.** Four lines of reading, then three first moves (watch, connect, buy) and a
   paste box. The header says "Purchase Key" while the hero says "Buy Next Key".
2. **/connect.** Pick one of ten runtimes, all marked "Unverified", and paste a prompt,
   before signing in, pairing or buying. The order is backwards.
3. **Buy.** Two warnings, a checkbox, Approve USDC, Buy Key. After the buy confirms,
   nothing says what to do next.
4. **Pair.** People find Pair New Agent themselves; /pair is titled "Bring your agent".
   The message to copy is long.
5. **Shard.** People type their agent's wallet address and a number of days, under risk
   lines. This is the biggest stall.
6. **Daily run and present.** Never named: five dots with a five-word tip.

`kf/onboarding-1106` fixes 2, 3, 6 and most of 4 and 5: it removes /connect, shows "You're
in" with "Set up your agent" after a buy, and gives a Key holder's fleet page a setup list
(Pair inline, Shard as one press for 30 days, Daily run, Present) that goes away once done.
It is about 32 commits behind main.

## Problems, ranked by value to people

| # | Problem | Page | Change | Size | Kind |
| --- | --- | --- | --- | --- | --- |
| 1 | Setup is in the wrong order and stops after buying | /, /connect, Buy Key | Ship `kf/onboarding-1106`, rebased | M | Release order: decision 2 |
| 2 | Buying has four names ("Purchase Key", "Buy Next Key", "Buy Key", "Buy Key {n}") and a sentence | header, /, /{fleet} | "Buy Key" everywhere; number and price sit in the facts beside it | S | Ordinary |
| 3 | Four different texts to paste to an agent; only the pairing message links it to the person | /, /{fleet}, /connect, Pair New Agent | The pairing message is the one paste | S | Decision 4 |
| 4 | The fleet's Message box sends people to regents.sh to pair | /{fleet} side rail | "Pair New Agent" opens Keyfleet's own window; an example message as placeholder | S | Ordinary |
| 5 | Giving a shard means typing a wallet address and days under warnings | /{fleet}/keys/:id | One press per paired agent | M | Decision 5 |
| 6 | Risk lines still on the buy window, Key page and treasury (moved out on 4 Nov) | Buy Key, Key page, treasury | Move them to a Risks section of docs.md; delete FleetRisks | M | Ordinary, decided 4 Nov |
| 7 | The home page repeats its buttons and runs long (Fleet Tools, eight sentence-shaped goal titles) | / | Headline, one line, Watch and Buy Key, facts | M | Decision 3 for the two lists |
| 8 | The fleet bar shows file names; the feed and sign-in carry helper lines | /{fleet} | Remove them | S | Ordinary |
| 9 | /pair is titled "Bring your agent"; "Pair New Agent" is a fixed label | /pair | Title "Pair New Agent", no tagline | S | Ordinary |
| 10 | Account pages repeat the menu, carry taglines and still show Credits | /account | Land credits-out; cut taglines in ash-template first; move to the shared /account | L | Ordinary, template-first |
| 11 | Open proposals sit above the hall and the workspace | /{fleet}, /{fleet}/workspace | One line each, opening the Proposals tab; votes stay there, never gated | M | Ordinary |
| 12 | Each Key transfer writes its own feed line | /{fleet} feed | Transfers close together read as one line | M | Ordinary |
| 13 | The workspace shows internal tool names and teaching text | /{fleet}/workspace | Place names alone | S–M | After task joins |
| 14 | Five choices to reach a task | /{fleet}/workspace | One list of open work with filters | L | After task joins |
| 15 | Every runtime says "Unverified" | /agents | Remove the label (audit question 2, 9 Nov) | S | Decision 6 |

## Build order, one worker at a time

1. Rebase `kf/onboarding-1106` onto main as its own branch; ship it per decision 2.
2. One buy name (2), the Message box (4), /pair title (9), fleet-page wording (8).
3. Risk lines to the docs (6).
4. Shard press (5), home page and one paste (7, 3), after decisions 3 to 5.
5. Proposals as one line (11); transfers grouped (12).
6. Account: template first (10).
7. After task joins lands: workspace names and navigation (13, 14).

Steps 2 to 5 all touch `fleet_live.ex` or `home_live.ex`, so they run one after another,
after the onboarding rebase.
