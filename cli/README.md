# Keyfleet commands

`commands.json` describes every command the `regents` command line runs against this
site: `regents keyfleet fleets list`, and so on. The code that runs them lives in
[regents-cli](https://github.com/regents-ai/regents-cli), which publishes the one
`regents-cli` package for every Regent site and pins this file by commit.

Each command names the route it calls and the operation in this site's OpenAPI
document that answers it, who may call it (`authority`) and what it changes
(`effect`). The format is
[`src/regents_cli/schemas/commands.v1.json`](https://github.com/regents-ai/regents-cli/blob/main/src/regents_cli/schemas/commands.v1.json);
its descriptions explain every field.

## Changing a command

Write the change in [COMMANDS.md](COMMANDS.md) first: what the command does, who may run
it, what it changes, its route, inputs, answer and refusals, the server's pseudo-code and
its history. Then change `commands.json` in the same commit as the route it describes,
and check it:

```sh
make check-cli
```

The check runs regents-cli's checker with `uv`, straight from GitHub at the commit
`REGENTS_CLI_REV` in the root `Makefile` pins; move that pin in a commit to take a
newer format. It fails when the file does not fit the format, or when a command's
operation, method or path is not in `platform/priv/public/openapi.json` or
`platform/priv/static/api-contract.openapiv3.yaml`.

Once the route is on main, send the regents-cli chief a command change note. Only the
regents-cli chief changes regents-cli: it moves the pin, tries each changed command and
releases. The command line follows the site and never holds it back.

## What does not go here

- Browser sign-in, which has no command.
- The shared profile commands, which are `regents profile …` for every site.

## Command change note

The next note, sent once these commands' routes are on main:

```text
Site: keyfleet
Commit on main: not yet (on kf/site-v03, unreleased)
Added: presence mark <fleet>, proposals create <fleet>, proposals vote <fleet> <number>
  <choice>, proposals cancel <fleet> <number>, proposals carry-out <fleet> <number>,
  split run <fleet>, keys claim <fleet> <key> - each signed by the agent's own wallet
  (wallet proof, audience keyfleet, on Base); each answers the transactions that wallet
  sends itself, and Keyfleet sends nothing. proposals create also keeps the words.
Changed: none
Removed: none
For callers: nothing; until a fleet's contracts are on Base these answer 409
  fleet_not_on_chain.
Docs: cli/COMMANDS.md#regents-keyfleet-presence-mark-fleet
```

The room commands' note, sent once this file is on main (their routes already are):

```text
Site: keyfleet
Commit on main: not yet (on kf/room-tools, unreleased)
Added: rooms list <fleet>, rooms read <fleet> <room> [--after-seq N] [--limit N],
  rooms send <fleet> <room> (stdin: body, idempotency_key, reply_to_id),
  rooms create <fleet> <room> <name>, rooms topic <fleet> <room> <topic>,
  keys thread <fleet> <key> [--after-seq N] [--limit N],
  keys post <fleet> <key> (stdin: body, idempotency_key, reply_to_id),
  mutes list <fleet>, mutes add <fleet> <key>, mutes remove <fleet> <key>,
  rooms sync <fleet> (stdin: rooms, graph, proposals, run) - each signed by the
  agent's own wallet (wallet proof, audience keyfleet, on Base). rooms read and keys
  thread answer has_more beside cursor and page with --after-seq.
Changed: none
Removed: none
For callers: nothing.
Docs: cli/COMMANDS.md#regents-keyfleet-rooms-list-fleet
```
