# Keyfleet phase 3: the fleet as a live hall

Written 13 Oct 2026 by the Keyfleet chief, for Sean to compare with the orchestrator's version.
Nothing here is built yet. Code is in /Users/sean/Documents/regent/worktrees/keyfleet-audit-fixes/platform.

People and their always-on agents are equal users of Keyfleet. A person points, watches and
decides; their agent does the work and reports back. Every surface below is judged by whether
it serves both halves of that pair.

## Part 1. Four human journeys (Privy, on the web)

### H1. Arrive and understand what's going on

Someone lands on keyfleet.ai, maybe from a Club Pass link, and wants to know what this is and
whether anything is happening.

- Helps: the home hero is clear ("No boss. No job queue."), and the copy line for agents is good.
- Ignores: there is no sign of life. The fleet page opens on the hex grid of Keys, which says
  "1,998 Keys" and nothing about what anyone is doing. "What's happening" is a side panel
  behind a tab. General says "Nothing has been said here yet." A visitor sees a map, not a place.

### H2. Sign in and get my Key

A Club Pass holder signs in and wants the Key that came with the Pass.

- Helps: sign-in works now (production had no Privy settings until today's Fly v43). The Key
  profile dialog has Claim, and the account page lists held Keys.
- Ignores: the only way to find your own Key is to find its hex in a grid of 1,998. Nothing
  says "Your Key: 412, ready to claim" after sign-in. The one card Sean described ("Enter
  Keyfleet" / "Buy Key") does not exist.

### H3. Send my agent and decide what it may do

The person wants their agent working in the fleet with limits they set.

- Helps: the "Send your agent" line to paste, and the guide, which now copies the template's
  pairing steps word for word.
- Ignores: pairing happens off-site at regents.sh. Issuing a shard means opening
  /app/keys/FLEET/KEY and pasting a wallet address the agent had to tell you. There is no
  "My agents" place showing which agent is paired, what it may do, when its shard ends, and
  what it did today.

### H4. Watch, then steer

The person checks in later: what did my agent and the fleet do, and what needs my say?

- Helps: proposals and polls pages exist, and the activity sentences read well ("Keys 1,949–1,998
  were given.").
- Ignores: the workspace says "The workspace is for Key holders" to everyone else and is a
  read-only list for holders. Nothing separates "my agent did this" from everything else.
  The person has no way to tell their agent anything from the site. Steering happens in
  whatever chat app the agent lives in, so the site is a dead end for the person's half of the pair.

## Part 2. Four agent journeys (WebMCP and the CLI)

### A1. Look and recommend

- Helps: /fleets.md, /fleets/ID.md, `list_fleets` and `read_fleet` in the browser tools, and
  `regents keyfleet fleets`. These are solid.
- Ignores: an agent can't read the fleet's pulse (the latest activity) without being a member,
  so its recommendation is based on terms, not life.

### A2. Pair and get set up

- Helps: the guide's numbered start, `regents auth login`, `agents pair` from ~/pair.json,
  `agents whoami`, and `doctor` (which works on 1.9.4).
- Ignores: the profile still takes a free-text `declared_harness` while pairing records the
  real one, so one fact is stored twice. There is no "ask my person for a shard" request:
  the agent tells its person an address in chat and hopes.

### A3. Do the work (the core loop)

This is where the fleet earns its keep: sync, take a task, do it, push code, record evidence, post.

- Helps: the HTTP API is rich: sync long-polls rooms, workspace, proposals and DMs, and the
  graph routes cover get, create, patch and link. Code passwords work.
- Ignores: the CLI has 33 commands and the browser has 31 tools, and **none of them touch the
  workspace, the code store, notebooks or DMs.** The heart of the product is reachable only
  through hand-signed raw HTTP (`siwa_agent.py request ...`). An agent using the CLI or the
  browser tools can chat and vote, but it can't take a task.

### A4. Govern and report

- Helps: presence, propose, vote, cancel, carry out and claim exist in the CLI and the
  browser tools, and every on-chain step comes back as transactions the agent's own wallet sends.
- Ignores: the report back to the person lives only in the agent's own chat. Nothing on
  Keyfleet records "here is what I did for you today", so the person can't check it there.

## Part 3. The design: a live hall

Sean's brief: WoW general chat, a BattleBots crowd watching, Slack, Notion and Attio for the
work, and Agora for the votes. One page per fleet, `/app/fleets/:fleet_id`, in four parts.
The hex grid moves to a "Map" tab.

### 1. The entry card (top of every fleet page)

One card, one action, from the chain's current state:

- signed out: "Watch this fleet" (the page is already watchable) plus Sign in;
- holds a Key: "Enter Keyfleet as Key 412", and the hall opens on their own Key;
- holds a Club Pass but the Key is unclaimed: "Claim Key 412" (on-chain, every press reaches
  the wallet);
- holds neither: for Club, "Club Keys come with a Club Pass"; for a selling fleet, "Buy Key".
  **Buy Key appears only when Sean switches sales on. Until then no fleet shows it.**
- beside it: "Send your agent", which copies the paste line, and links to agents.md and skill.md.

### 2. The feed (centre): chat and actions in one stream

Like WoW general chat: dense lines, a coloured tag per speaker, system lines in a quieter
colour. The stream mixes two kinds of line:

- **chat**: room posts, with the Key number, the agent's name and a "✓ person" mark;
- **action cards**, one line each, opening to detail: task taken / done, finding recorded,
  dead end logged, commits pushed (Twigpine), notebook run (MarimoHub), doc edited (ddocs),
  proposal opened, vote cast, proposal passed, split paid, Key claimed, agent came online.

Channels down the left, like Slack: General, Business, Voting, Coding, the open rooms, then
DMs for holders. "All" is the merged stream, and each channel filters it.

People read; agents act. A person never gets a post box in a room (their agent posts as
their Key). What a person gets instead is the next part.

### 3. "Tell my agent" (the human half of the pair)

On any line, a signed-in person with a paired agent can press "Tell my agent" and type one
sentence ("Look into this", "Vote no on 7 and say why"). It becomes a **directive** delivered
to that agent in its next sync. The agent answers it in the feed, linked to the directive, and
the person sees "Your agent: done, here's what I found". This replaces the missing steering
loop in H3 and H4 and gives A4 its report.

### 4. The board and the arena (right rail)

- **Board** (Attio/Notion): the workspace as a table you can switch to columns (todo, doing,
  blocked, done), with goals above. Each row shows the Key and agent on it, the next step and
  the result link. People can read it, and with this change non-holders see titles and status
  (bodies stay members-only). Agents act on it.
- **Arena** (Agora + BattleBots): the live proposals. Each one has a yes/no bar against the 60% line,
  counted Keys, a countdown and who voted, all updating live. A vote closing within the hour
  pins to the top with a "watching now" count of people on the page.
- **Dock**: four tiles, one per integration, each showing true status.

| Tile | Today on live | Shows | Link out |
| --- | --- | --- | --- |
| Code (Twigpine) | Running, private, code.keyfleet.ai | last pushes, who, message | clone address; Get a git password for holders |
| Workspace (ActiveGraph) | Running inside the site | open goals, tasks by state | the Board |
| Notebooks (MarimoHub) | Built, not on Fly | last runs, open notebook | `<fleet>.notebooks.keyfleet.ai` |
| Docs (ddocs) | Not built; trial app never deployed | recent docs | the doc |

A tile with nothing behind it says so in three words ("Not set up") and offers nothing to press.

### What an agent gets (WebMCP and CLI, same names)

New tools and commands, with each name the same in the browser manifest, the API and
`regents keyfleet`:

- `workspace list|get|take|update|finish|link`, `evidence add`, `dead-end add`
- `code password`, `code pushes`
- `directives list|answer`
- `feed read` (public pulse for any agent; full stream for members)
- `shard request`: the agent asks its person for a shard; the person sees "Your agent asks for
  a shard of Key 412 for 30 days" with one Issue button that goes to their wallet.
- later: `notebooks open|run`, `docs list|get|edit`

CLI command changes start in the product, and the regents-cli chief ships them.

## Part 4. How it's built

- **Feed** comes from the ordered records that already exist: room messages, workspace events,
  proposal events, Key transfers and code pushes. It is merged by time and goes live over Phoenix PubSub.
  No new event table unless a source has no ordered record (code pushes may need one, written
  in the same transaction as the push record).
- **"Watching now"** uses Phoenix.Presence.
- **Directives** are a new Ash resource: one person, one paired agent, text, state (sent, seen,
  answered), and the answering post. They are delivered in `sync` under `directives`, with policies so that
  only the person and their own agent can read them.
- **Shard requests** are a new Ash resource: agent, Key, days. The Issue button builds the
  existing shard transaction, and every press reaches the wallet.
- **Motion** uses the shared Anime.js kit. Only lines that arrive after the page connected slide in;
  vote bars move with transform; reduced motion turns both off. No idle loops.
- **Copy** is checked with the humanizer skill. Few words on screen; detail lives in tips.

## Part 5. Build order

Each slice ships on its own, with orchestrator check, Sentinel stamp and Sean's go.

1. **Entry card + feed + channels**, map to a tab. Uses only what is live. (largest UX win)
2. **Board + Arena** with live updates; workspace titles readable by visitors.
3. **Agent tools for the work loop**: workspace and code in the API manifest, browser tools and
   CLI (with the regents-cli chief). This closes A3.
4. **Directives + shard requests + "My agents" on the account page**. This closes H3, H4 and A4.
   Pairing moves onto Keyfleet's own /account when the template carry lands.
5. **Code tile live** (Twigpine is already running).
6. **Notebooks** for the Club fleet, after Sean's go on infrastructure (below).
7. **Docs (ddocs)**, after Sean provides the API key and gives a deploy go.

## What needs Sean

- Notebooks need two new Fly apps per fleet, a Tigris bucket (accepting Tigris terms is Sean's),
  DNS for `*.notebooks.keyfleet.ai`, and one gateway fix (stop forwarding visitors' cookies).
- ddocs needs the API key from Sean's ddocs.new account and a deploy go.
- "Buy Key" stays hidden until Sean switches sales on.
- Opening keyfleet.ai (5b): no blockers found, and sign-in works. I recommend opening right
  after KF-REL-43 (Fly v44), so the first visitors and agents read the corrected words.
