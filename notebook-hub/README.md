# Fleet notebook hub

Each Keyfleet fleet gets its own private notebook hub on Fly: a copy of
[marimohub](https://github.com/marimo-team/marimohub) that only that fleet's
members can open. When someone opens a notebook, the hub starts a short-lived
Fly machine for it, the notebook's code runs on that machine, and the machine
is deleted when the session ends. The Regents Club's hub is being set up on
Fly; no other fleet's is.

People never reach the hub directly. Keyfleet's own server sits in front of it,
checks who is signed in and what they may see, and passes a signed note about
them to the hub. That part is built separately, in `platform/`.

## The pieces

- **`compute-fly/`**: the part of the hub that starts, finds and deletes
  notebook machines through Fly's machine service. It follows marimohub's own
  rules for add-ons and is bundled into the hub image as one file. Each machine
  is tagged with its hub's name, so a hub only ever sees and removes its own
  machines. Machines get no public address, no bucket keys and none of the
  hub's own passwords. Each one gets its own helper password, worked out from
  one hub secret and the machine's id, and a time limit after which it shuts
  itself down even if the hub never asks.
- **`runner/`**: the notebook machine's image. It is marimohub's own notebook
  image at the pinned version (marimo 0.25.2 and its usual libraries), plus:
  - a small helper the hub uses to run commands and read and write the
    notebook's files on the machine;
  - a relay so the hub can reach the notebook over Fly's private network.
  The helper runs as the system user, while notebook code runs as an ordinary
  user that cannot see the helper's password, not even by looking at other
  programs on the machine.
- **`hub/`**: the hub image (marimohub built from source at the pinned version,
  with `compute-fly` added), the two Fly app templates, and
  `hub.env.example`, which lists every hub setting with a one-line meaning.
- **`marimohub/`**: the exact marimohub version used (`pin.env`) and the
  patches the hub image applies to it, in this order:
  - `pnpm-lock.patch`, the lockfile change (made by pnpm) that adds
    `compute-fly` to marimohub's workspace and declares `@smithy/core`;
  - `catalog-commit.patch`, our fix to marimohub's catalog (below);
  - `storage-errors.patch`, which puts the store's answer in error lines
    (below);
  - `sweep-concurrency.patch`, which cleans up deleted notebooks 16 at a time;
  - `storage-read-retry.patch`, which tries again a read the store cancels
    with 408;
  - `app-pool-sweep.patch`, which sweeps app pools 16 at a time and passes over
    a deleted notebook's empty pool;
  - `storage-calls.patch`, which names each failed store call and its object in
    its log line, and gives the storage client five tries, 1, 2, 4 and 8
    seconds apart;
  - `maintenance-lock-landed.patch`, which keeps a lease whose write landed
    before the store refused the client's retry of it, and logs who holds a
    lease whenever a loop is refused it;
  - `notebook-prune-hourly.patch`, which moves each notebook's upload and
    thumbnail cleanup to its own hourly loop, and skips reading a notebook's
    thumbnail record when no image is over a day old.
- **`local/`**: the local end-to-end proof (see below).
- **`scripts/`**: `workspace.sh` prepares marimohub at the pin with
  `compute-fly` inside it. `build-images.sh` builds the three images.
  `check.sh` runs every check.

## Building and checking

You need marimohub's exact Node version (24.22.1 at this pin, from its
`.node-version`) first on your PATH, plus Docker.

```sh
make check-notebook-hub              # from the repository root; or notebook-hub/scripts/check.sh
```

This check is not part of `make check`, because it builds a 3 GB image. It
must succeed before any hub or runner image is pushed to Fly. It does four
things:

1. Fetches marimohub at the pinned version into `notebook-hub/.work/` (the
   first run only).
2. Runs the type check, lint and tests for `compute-fly`, and bundles it.
3. Builds the three images:
   - `keyfleet/marimo-sandbox:626ec14`, marimohub's notebook image, about 3 GB;
   - `keyfleet/notebook-runner:626ec14`;
   - `keyfleet/notebook-hub:626ec14-24dafab`, about 440 MB. The part after
     the dash names the patches in `marimohub/`, so a changed patch gives a
     new tag. `build-images.sh` prints the tag it built on its last line.
4. Runs the helper's tests inside the runner image.

The first image build takes a while; later runs reuse Docker's cache.

## The local proof

```sh
notebook-hub/local/run.sh            # after the images are built
```

What runs:

- The hub image, with dev sign-in (no real sign-in) and notebooks saved to a
  folder.
- A stand-in for Fly's machine service, `local/fake-fly-api.mjs`, which starts
  each "machine" as a Docker container. Those containers sit on a network that
  only carries IPv6 addresses, as Fly's private network does.

What it checks, in 13 steps:

- A session starts on a new machine.
- The hub reaches the notebook through the relay.
- A cell runs as the ordinary user, and the helper password is nowhere it can
  see.
- The notebook's files and results are saved back to the hub after the session
  ends.
- The machine is gone afterwards.
- A second hub name sees only its own machines.

It uses a free local port (4791) and removes everything it started. Hub and
stand-in logs are kept in `notebook-hub/.work/local/`.

What the local proof cannot show, because it needs real Fly:

- That Fly's machine service accepts these requests as written. In particular:
  - the token header format;
  - searching machines by their tags;
  - machine names being unique.
- How quickly Fly's private addresses (`<machine>.vm.<app>.internal`) start
  answering after a machine starts.
- What Fly adds inside a real machine, for example its local machine service
  at `/.fly/api`. The test checks that notebook code cannot read the helper
  password, but it does not check what Fly itself exposes.
- That Fly deletes a machine whose lifetime ran out (`auto_destroy`).
- Real Tigris storage, and how long a 3 GB image takes to start the first
  time.
- Real sign-in through Keyfleet's server.

## Before anything goes on Fly: founder approval

For four fleets, setting this up means:

- **8 Fly apps**: `kf-nb-<fleet>` (the hub) and `kf-nbk-<fleet>` (its notebook
  machines) for each fleet.
- **4 Tigris buckets**: one per fleet, holding its notebooks and results.
- **4 private networks**: one per fleet, holding only that fleet's two apps,
  plus one Flycast address per hub on the organization's default network.
- **Tokens and secrets per fleet**:
  - a Fly token, good for a year, narrowed to the app `kf-nbk-<fleet>` alone;
  - a key for that fleet's bucket only;
  - two random secrets made locally, one for hub sign-in cookies and one for
    helper passwords.
- **Running costs**:
  - one small machine (shared-cpu-1x, 1 GB) running all the time per fleet;
  - notebook machines, charged only while sessions run;
  - Tigris storage.

The Regents Club's was set up on 13 October 2026 and Classic #1's on 21 October
2026 (Sean's go in Classic #1's pilot). The other fleets have none of this yet,
and nothing here creates it.

## Setting up one fleet

Each step names the command. The flags were checked against the help text of
flyctl v0.4.107. Every step has run on real Fly, for the Regents Club and for
Classic #1 (Classic #1's with flyctl v0.4.120).

Each fleet's hub and runner apps share a private network of their own,
`kf-nb-<fleet>-net`. Notebook machines therefore cannot reach the shared
database or any other Regent app over Fly's private network. The hub has one
private (Flycast) address on the organization's default network, which is how
Keyfleet's server reaches it. Every other app on that network can reach that
address too: what keeps them out of a fleet's notebooks is the signed note
Keyfleet's server puts on each request, which the hub checks.

1. **Check and build the images**: run `make check-notebook-hub` from the
   repository root. It must succeed before anything is pushed.
2. **Create both apps on the fleet's own network**:
   - `fly apps create kf-nb-<fleet> --org <org> --network kf-nb-<fleet>-net`
   - `fly apps create kf-nbk-<fleet> --org <org> --network kf-nb-<fleet>-net`
3. **Build for Fly and push the images.** Fly's machines run `linux/amd64`. On an
   Apple Silicon Mac the check above builds `arm64` images, so build again for
   Fly first: `DOCKER_DEFAULT_PLATFORM=linux/amd64 notebook-hub/scripts/build-images.sh`
   (same tags). Then run `fly auth docker` and:
   - tag `keyfleet/notebook-runner:626ec14` as `registry.fly.io/kf-nbk-<fleet>:626ec14` and push it;
   - tag `keyfleet/notebook-hub:626ec14-24dafab` as `registry.fly.io/kf-nb-<fleet>:626ec14-24dafab`
     and push it, then set the same tag in `[build] image` of
     `hub/fleets/<fleet>.hub.toml`.
4. **Create the fleet's bucket on the hub app. Sean runs this one himself**:
   `fly storage create --app kf-nb-<fleet> --name <bucket>`. Fly sets the
   bucket's key on the hub app itself, as the secrets `AWS_ACCESS_KEY_ID` and
   `AWS_SECRET_ACCESS_KEY`, and also shows both values on the screen of
   whoever runs it. So no agent runs it, and nothing it prints is pasted
   anywhere. The hub's storage reads those two when its own
   `MARIMOHUB_STORAGE_S3_ACCESS_KEY_ID` and
   `MARIMOHUB_STORAGE_S3_SECRET_ACCESS_KEY` are unset, so leave them unset.
   Accepting Tigris' terms at the prompt is Sean's decision each time; never
   pass `-y`.
5. **Make the hub's Fly token and set its other secrets, without printing any
   of them.** A plain deploy token for `kf-nbk-<fleet>` can also list and
   manage the organization's WireGuard connections (tried 13 October 2026), so
   it is narrowed before it is stored:
   - `fly tokens create deploy --app kf-nbk-<fleet> --name kf-nb-<fleet>-hub --expiry 8760h`
     makes it, good for one year. Its value goes straight into the next
     command, never to the screen or a file that outlives the command.
   - `fly tokens attenuate -f <caveat file>`, with the token in
     `FLY_API_TOKEN`, narrows it. The caveat file holds exactly:

     ```json
     [{"type":"IfPresent","body":{"ifs":[{"type":"FeatureSet","body":{"features":{}}}],"else":"rwcdC"}}]
     ```

   - Check the narrowed token three ways before storing it: listing the
     machines of `kf-nbk-<fleet>` answers; listing WireGuard connections is
     refused; listing the machines of `keyfleet` is refused.
   - Store it with the two random secrets:

     ```sh
     fly secrets set --app kf-nb-<fleet> --stage \
       MARIMOHUB_AUTH_SESSION_SECRET="$(openssl rand -hex 32)" \
       MARIMOHUB_COMPUTE_FLY_HELPER_SECRET="$(openssl rand -hex 32)" \
       FLY_API_TOKEN="<the narrowed token>"
     ```

   The narrowed token has full control of the runner app, which holds only
   notebook machines, and nothing else: no WireGuard, no image builder, no
   other app. Write its listed ID and its last day under "Tokens on record"
   below. To withdraw one, `fly tokens list --app kf-nbk-<fleet>` and
   `fly tokens revoke <listed ID>`; a token's own value is not accepted there.
6. **Fill in the hub's settings.** Copy `hub/fly.hub.toml` and
   `hub/fly.runner.toml` into `hub/fleets/` as `<fleet>.hub.toml` and
   `<fleet>.runner.toml`, and replace every `<…>` placeholder
   (`hub/hub.env.example` says what each setting means). The Regents Club's
   and Classic #1's copies are there.
7. **Deploy the hub, private, as one machine**:
   `fly deploy --config notebook-hub/hub/fleets/<fleet>.hub.toml --no-public-ips --ha=false`.
   Nothing is deployed to `kf-nbk-<fleet>`: the hub starts its machines there.
8. **Give Keyfleet's server one private address for the hub**:
   `fly ips allocate-v6 --private --app kf-nb-<fleet>`, with no `--network`.
   This makes a Flycast address on the organization's default network, which
   the `keyfleet` app is on and which has no name to pass, not on the fleet's
   own network.
9. **Give the fleet's notebooks their web address.** In Vercel DNS, point
   `<fleet, hyphenated>.notebooks.keyfleet.ai` at the `keyfleet` app's own
   addresses, as `regents-club.notebooks` is: an A record and an AAAA record
   with the addresses `fly ips list --app keyfleet` shows
   (`vercel dns add keyfleet.ai <fleet, hyphenated>.notebooks A <v4>`, and the
   same with `AAAA <v6>`), then
   `fly certs add <fleet, hyphenated>.notebooks.keyfleet.ai --app keyfleet` and
   `fly certs check` until it is issued.
10. **Point Keyfleet's server at the hub**: add
    `<fleet_id>=http://kf-nb-<fleet>.flycast` to the `keyfleet` app's
    `KEYFLEET_HUB_FLEETS` secret (pairs separated by commas). Setting it
    restarts the live site once.

## Tokens on record

Each hub's Fly token lasts a year and is replaced before its last day: make
and narrow a new one as in step 5, set it, deploy, then revoke the old one by
its listed ID.

| Fleet | Token name | Listed ID | Made | Last day |
| --- | --- | --- | --- | --- |
| Regents Club | `kf-nb-regents-club-hub` | `60XMXnbzk4eybuLoxgj02GxemnCgP23j2v2DXkMFZ7` | 13 October 2026 | 13 October 2027, 17:48 UTC |
| Classic #1 | `kf-nb-fleet-tech-classic-hub` | `3KZ2ZnjxkaoyjCw9k7lMKRko8OCavNkxlpywokgS8` | 21 October 2026 | 21 October 2027, 07:09 UTC |
| Syndicate #1 | `kf-nb-fibonacci-syndicate-hub` | `gRAgA4abnyV5aIqVmNRyQOmx6vC9jNkZqv9V2OJCz8` | 23 October 2026 | 23 October 2027, 01:36 UTC |
| Cascade #1 | `kf-nb-fibonacci-cascade-hub` | `zQgwgYqbO69nqf9qXZzvRQXnkKCB5amyGwBlK6AFPX` | 23 October 2026 | 23 October 2027, 01:36 UTC |
| Accelerant #1 | `kf-nb-fleet-tech-accelerant-hub` | `3KZ2ZnjxkaoyjCw9k7lMKRko8OCpoD028NpMn9GCmv` | 23 October 2026 | 23 October 2027, 01:36 UTC |

## Things to know

- **The hub must not share a web address with keyfleet.ai.** In this setup,
  notebook pages are served from the hub's own web address. A notebook's page
  can therefore run scripts as that address, which is what
  `MARIMOHUB_SANDBOX_PROXY_ACK_UNTRUSTED` acknowledges. Sean chose
  `<fleet>.notebooks.keyfleet.ai` (4 Oct 2026). Keyfleet's own sign-in cookie
  is a `__Host-` cookie, so a notebook page cannot set or replace it.
- **Each fleet has its own private network.** A fleet's notebook machines can
  reach that fleet's hub and the fleet's other notebook machines, and nothing
  else on Fly's private network. The hub's sign-in and each machine's helper
  password still guard those ports.
- **The hub's Flycast address is open to the default network.** Any Regent app
  on the organization's default network can connect to it. The hub lets in
  only requests carrying Keyfleet's signed note.
- **Not verified on real Fly** (waiting on the Regents Club hub's first
  deploy):
  - that the hub, on its own network, still reaches Fly's machine service at
    `_api.internal:4280` (if not, `MARIMOHUB_COMPUTE_FLY_API_URL` can point at
    Fly's public machine service instead);
  - that machine names (`<machine>.vm.kf-nbk-<fleet>.internal`) resolve
    between the two apps on their shared network;
  - that Keyfleet's server reaches `kf-nb-<fleet>.flycast`.
- **Notebook machines can reach the public internet**, including any Regent
  site's public address.
- **Machine names.** Each machine is named after its marimohub session sandbox,
  so the hub finds an existing machine again after a restart instead of
  starting a second one.
- **The hub keeps a snapshot its catalog names (`catalog-commit.patch`).**
  marimohub moves its catalog to a new snapshot with a conditional write. Its
  storage client retries a write whose answer was lost; when the first try
  had already landed, the retry is refused, and marimohub at the pin then
  deleted the snapshot its catalog had just moved to. The hub stopped with
  "Catalog has not been initialized" until the catalog was rebuilt (Classic #1
  and the Regents Club, 27 Oct 2026). With the patch, the hub reads the catalog
  before deleting, and keeps the snapshot when the catalog names it. The patch
  adds three tests to marimohub's `recovery.test.ts`. Drop the patch when
  marimohub ships the same fix.
- **A failed storage call names the store's answer (`storage-errors.patch`).**
  marimohub logs a refused storage call with only the client's error name, so a
  reply with no error code reads "Unknown". With the patch, `request_error` and
  the other error lines carry `error.storage`: the HTTP status, the store's
  request ids and how many tries were made. A support ticket to the store needs
  those ids (Classic #1 saves refused with "Unknown", 27 Oct 2026).
- **Hub integrations are off (`MARIMOHUB_INTEGRATIONS=off`).** marimohub's
  integrations hold data-source settings and their secrets for notebooks.
  Keyfleet's gateway never opens their routes and nothing in Keyfleet makes
  one, so every hub runs with them off and needs no `MARIMOHUB_SECRETS_KEK`.
  With them on and no key, each hub warned "integration secret sources: none"
  at every start (27 Oct 2026). Turning them on later means opening the routes
  in the gateway and giving each hub its own key.
