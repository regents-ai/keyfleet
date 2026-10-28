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

Write the change in [COMMANDS.md](COMMANDS.md) first: its purpose, access and changes,
its route, inputs, answer and refusals, the server's pseudo-code and
its history. Then change `commands.json` in the same commit as the route it describes,
and check it:

```sh
make check-cli
```

The check runs regents-cli's checker with `uv`, straight from GitHub at the commit
`REGENTS_CLI_REV` in the root `Makefile` pins (regents-cli 1.10.20); move that pin
in a commit to take a newer format. It fails when the file does not fit the format, or when a command's
operation, method or path is not in `platform/priv/public/openapi.json` or
`platform/priv/static/api-contract.openapiv3.yaml`.

Once the route is on main, send the regents-cli chief a command change note. Only the
regents-cli chief changes regents-cli: it moves the pin, tries each changed command and
releases. The command line follows the site and never holds it back.

## What does not go here

- Browser sign-in, which has no command.
- The shared profile commands, which are `regents profile …` for every site.

## Command change note

```text
Site: keyfleet
Commit on main: <the full commit>
Added: <each new command with its arguments, and whose wallet signs it>
Changed: <each command whose route, inputs or answer changed>
Removed: <each command taken out>
For callers: <what a caller does differently, or nothing>
Docs: cli/COMMANDS.md#<the first command's heading>
```
