# Fleet notebook hub

Each Keyfleet fleet gets its own private notebook hub on Fly: a copy of
[marimohub](https://github.com/marimo-team/marimohub) that only that fleet's
members can open. When someone opens a notebook, the hub starts a short-lived
Fly machine for it, the notebook's code runs on that machine, and the machine
is deleted when the session ends. Nothing here is on Fly yet.

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
  image at the pinned version (marimo 0.25.0 and its usual libraries), plus:
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
  one-entry lockfile change that adds `compute-fly` to marimohub's workspace.
- **`local/`**: the local end-to-end proof (see below).
- **`scripts/`**: `workspace.sh` prepares marimohub at the pin with
  `compute-fly` inside it. `build-images.sh` builds the three images.
  `check.sh` runs every check.

## Building and checking

You need Node 24 (marimohub's version) first on your PATH, plus Docker.

```sh
notebook-hub/scripts/check.sh        # or: make check-notebook-hub, from the repository root
```

This does four things:

1. Fetches marimohub at the pinned version into `notebook-hub/.work/` (the
   first run only).
2. Runs the type check, lint and tests for `compute-fly`, and bundles it.
3. Builds the three images:
   - `keyfleet/marimo-sandbox:f103eb2`, marimohub's notebook image, about 3 GB;
   - `keyfleet/notebook-runner:f103eb2`;
   - `keyfleet/notebook-hub:f103eb2`, about 440 MB.
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
- **Tokens and secrets per fleet**:
  - a Fly token that may manage machines in `kf-nbk-<fleet>` only;
  - a key for that fleet's bucket only;
  - two random secrets made locally, one for hub sign-in cookies and one for
    helper passwords.
- **Running costs**:
  - one small machine (shared-cpu-1x, 1 GB) running all the time per fleet;
  - notebook machines, charged only while sessions run;
  - Tigris storage.

None of this exists yet, and nothing here creates it.

## Setting up one fleet

Each step names the command. Check the flags against the current `flyctl`
before running anything: none of this has run against real Fly yet.

1. **Build the images**: run `notebook-hub/scripts/build-images.sh`.
2. **Create both apps**:
   - `fly apps create kf-nbk-<fleet> --org <org>`
   - `fly apps create kf-nb-<fleet> --org <org>`
3. **Push the images.** Run `fly auth docker`, then:
   - tag `keyfleet/notebook-runner:f103eb2` as `registry.fly.io/kf-nbk-<fleet>:f103eb2` and push it;
   - tag `keyfleet/notebook-hub:f103eb2` as `registry.fly.io/kf-nb-<fleet>:f103eb2` and push it.
4. **Create the fleet's bucket**: `fly storage create --name <bucket> --org <org>`.
   Keep the key id and secret it prints for step 6.
5. **Make the machine token**: `fly tokens create deploy --app kf-nbk-<fleet>`.
   It can manage machines in the runner app only.
6. **Set the hub's secrets.** Use `fly secrets set --app kf-nb-<fleet> --stage`
   to set:
   - `MARIMOHUB_AUTH_SESSION_SECRET`
   - `MARIMOHUB_COMPUTE_FLY_HELPER_SECRET` (each of these two from `openssl rand -hex 32`)
   - `FLY_API_TOKEN` (from step 5)
   - `MARIMOHUB_STORAGE_S3_ACCESS_KEY_ID` and `MARIMOHUB_STORAGE_S3_SECRET_ACCESS_KEY` (from step 4)
7. **Fill in the hub's settings.** Copy `hub/fly.hub.toml`, replace every
   `<…>` placeholder (`hub/hub.env.example` says what each setting means),
   and copy `hub/fly.runner.toml` the same way.
8. **Deploy the hub, private, as one machine**:
   `fly deploy --config <copied fly.hub.toml> --no-public-ips --ha=false`.
   Nothing is deployed to `kf-nbk-<fleet>`: the hub starts its machines there.
9. **Point Keyfleet's server at the hub**: `http://kf-nb-<fleet>.internal:3000`
   over Fly's private network.

## Things to know

- **The hub must not share a web address with keyfleet.ai.** In this setup,
  notebook pages are served from the hub's own web address. A notebook's page
  can therefore run scripts as that address, which is what
  `MARIMOHUB_SANDBOX_PROXY_ACK_UNTRUSTED` acknowledges. Give each fleet's hub
  its own address, for example `<fleet>.notebooks.keyfleet.ai`, never a path
  under keyfleet.ai itself.
- **Fly's private network covers the whole organization.** Other apps in the
  organization can reach a notebook machine's helper and notebook ports. Both
  still need the right password, but that network is not fenced off per fleet.
- **Notebook machines can reach the internet.**
- **Machine names.** Each machine is named after its marimohub session sandbox,
  so the hub finds an existing machine again after a restart instead of
  starting a second one.
