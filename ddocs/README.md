# keyfleet-ddocs: the dDocs trial server

The dDocs server (npm `@fileverse/api` 1.0.10, unchanged) as a private Fly app.
It saves documents in its own file database on the app's volume, then encrypts
each version, uploads it to Fileverse's IPFS service and records it on Gnosis,
with gas paid by Fileverse. The capability check that chose this is
`docs/k10/fileverse-ddocs.md` on the `codex/k10-workspace` branch.

This is the one-document trial: one dDocs account, one document, made from
inside the server. Nothing in KeyFleet calls it yet.

## Settings

Secret (`fly secrets set` on `keyfleet-ddocs`), set by Sean:

| Name | Value |
| --- | --- |
| `API_KEY` | The key from the KeyFleet dDocs account (ddocs.new, Settings, Developer Mode). |

Plain settings are in `fly.toml`: `PORT`, `IP`, `INLINE_WORKER` (publishing runs
inside the server) and `DB_PATH` (`/data/ddocs.sqlite` on the volume).

At start the server fetches the key's encrypted workspace details from
`apps-storage.fileverse.io` and stops if the key is missing or unknown.

The server checks requests by `?apiKey=` in the address, and its access log
prints every address. So the trial uses the command line inside the machine,
which reads the key from the environment, and nothing calls the HTTP API.

## Deploy

From this folder:

```sh
fly deploy --no-public-ips
fly ips list --app keyfleet-ddocs   # must show only the private (Flycast) address
```

The first deploy makes the 1 GB volume `keyfleet_ddocs_data` from `[[mounts]]`.

## The trial

```sh
fly ssh console --app keyfleet-ddocs -C "sh -c 'printf \"# KeyFleet dDocs trial\n\nOne document, saved by the server.\n\" > /tmp/trial.md && node node_modules/@fileverse/api/dist/commands/index.js create /tmp/trial.md'"
fly ssh console --app keyfleet-ddocs -C "node node_modules/@fileverse/api/dist/commands/index.js get <ddoc id>"
```

`get` shows the sync status. Once it reads synced, the document's link opens it
in ddocs.new, decrypted in the browser by the key after `#`.

## Build and run locally

```sh
docker build --platform linux/amd64 -t keyfleet-ddocs .
docker run --rm -p 8001:8001 -v keyfleet-ddocs:/data -e DB_PATH=/data/ddocs.sqlite -e API_KEY=… keyfleet-ddocs
```

Without `API_KEY` it stops at once with "API_KEY environment variable is not set".
