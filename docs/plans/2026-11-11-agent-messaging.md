# Agent messaging: Buzz or our own

11 November 2026. Keyfleet lane. Read-only research: nothing was installed, run or changed.
Sources: github.com/block/buzz (README, ARCHITECTURE.md, NOSTR.md, the agent and identity
documents, the production compose bundle) and github.com/block/buzz-app, read 11 Nov
04:00Z; Keyfleet main 209b118a.

## Short answer

Keep Keyfleet's own rooms and direct messages, and copy the one thing Buzz does that we
lack: an agent hears a mention or a direct message straight away, and its runner on the
person's computer wakes it to answer. Moving onto Buzz would give every person and agent a
second key, a second member list, new servers to pay for and a public server with no abuse
limits, and it would replace pages people already use with a separate app.

## Buzz

- Block's open-source workspace for people and agents (Apache 2.0, about 36,900 stars,
  changed many times a day).
- One server, called a relay, written in Rust, with Postgres, Redis and file storage beside
  it. A prebuilt image exists, so a trial needs only Docker.
- Everyone signs in with a private key kept on their own computer (a Nostr key). There is
  no email, wallet or Privy sign-in. A draft feature lets the relay trust an outside issuer
  that vouches for a key, but each person and agent still holds the key.
- Agents (Claude Code, Codex, Goose, Pi) run on the person's own computer, through the Buzz
  desktop app or its runner. When someone mentions an agent, the runner starts it, hands it
  the new messages and posts its answer: one question at a time per room, the rest queued
  and sent together.
- Rooms, threads, direct messages, search, canvases, files, voice calls, git patches and
  scheduled workflows. Agents can do everything a person can.
- Gaps Buzz lists itself: no rate limits at all; workflow approval steps not wired; two
  workflow actions unbuilt. Buzz 1.0 moved to a new app repository on 10 Nov, builds
  straight from main, and says plugin updates can break.

## Keyfleet today

- Rooms in each fleet, Key walls, direct messages, quote requests, mutes and read marks:
  about 5,500 lines, with 23 agent tools, each on all five surfaces (page, browser tools,
  `/mcp`, signed requests, regents-cli).
- Membership comes from Keys on Base and pairing. People and agents post as a Key. The
  proposals list sits beside the chat.
- People see new messages live on the page. Agents see them only at their next scheduled
  check-in, every 10 minutes to once a day. Messages have no mentions, so nothing tells an
  agent it was asked something. This is one reason the work loop stalls: an agent answers a
  day late, or never.

## Side by side

| | Buzz relay | Keyfleet's own |
| --- | --- | --- |
| Sign-in | A second key for every person and agent; Privy accounts have none | Privy and agent sign-in, as today |
| Room members | Buzz's own list; a job would copy Key holders into it, a second source of truth | Keys and pairing, read from the chain |
| An agent hears a mention | At once, and the runner wakes it | At its next check-in; fixed by the plan below |
| People read messages | In the Buzz app, or on pages we rebuild to read the relay | On keyfleet.ai |
| Abuse limits | None built | The site's limits and access rules |
| Servers | A new Fly app and machine, Redis, file storage and room on the shared database, which is near its connection limit: new spend | Nothing new |
| Messages already sent | Moved or dropped; moved ones lose who signed them | Stay |
| Work to switch | Delete rooms and messages on all five surfaces, the regents-cli commands and the guides; build the key link and the member copy | Three additions |
| Upkeep | Follow a project that changes daily and just started 1.0 | Ours |

## Worth taking from Buzz

1. **Mentions.** `@Key 19` or an agent's name in a room, wall or direct message becomes a
   mention the agent can list. It also arrives in its sync. Keyfleet only.
2. **Live feed.** A signed agent keeps one connection open and receives its mentions, direct
   messages and replies the moment they are posted, from the page's own live updates.
   Every site would use this, so it is built in ash-template first.
3. **Wake-up runner.** A regents-cli command on the person's computer holds the feed and
   starts the person's agent (Claude Code, Codex) when it is mentioned, one question at a
   time per room, the way Buzz's runner does. regents-cli's lane, shared by every site.

## Decision

**1. Agent messaging for Keyfleet?**

- a) Keep Keyfleet's own rooms and direct messages, and add mentions (Keyfleet), the live
  feed (ash-template first, then all five sites) and the wake-up runner (regents-cli). No
  new servers.
- b) Run a Buzz relay for Keyfleet and move rooms and direct messages onto it: Keyfleet's
  own are deleted, every person and agent gets a Nostr key, and Fly gets a new app, Redis
  and storage.
- c) Try Buzz on the Mac for a day first: its relay in Docker, the desktop app and one
  Claude agent, nothing on keyfleet.ai, then decide between a and b.

Recommendation: **a**, because the agents' real gap is hearing a mention in time, which
three small additions close, while Buzz would split sign-in, membership and reading away
from keyfleet.ai.
