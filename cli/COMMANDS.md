# Keyfleet commands

Run `regents keyfleet --help` for the released command line. This guide follows `commands.json`; run `make check-cli` to check it against the API description.

## regents keyfleet fleets list

Compare the fleets.

`GET /api/v1/fleets` · `listFleets` · public · read


## regents keyfleet fleets get <fleet>

Read one fleet.

`GET /api/v1/fleets/{fleet_id}` · `getFleet` · public · read

- `fleet` (optional, string): The fleet.
