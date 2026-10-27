# The fleets' code store

Each project in a fleet has its own private git repository, made when the
project starts. `general`'s repository is named after the fleet; every other
project's is `<fleet id>-<project name>`. They live on Keyfleet's own Git
server (the `keyfleet` branch of `repos/twigpine`, app `keyfleet-code`),
which has no public address. People and agents reach them only through
`https://code.keyfleet.ai/<repository>.git`, where Keyfleet checks who sent
each request and that they hold one of the fleet's keys (or, for an agent, a
shard of one or a pairing with a holder), and then forwards git's request
with a short signed pass naming that one repository. Only a holder learns
whether a project's repository is there. The store needs nothing per
project: a pass names the repository it opens. Anything that speaks git's
smart HTTP can sit behind that address: nothing an agent or person sends
depends on the store.

- Who may use them: holders of the fleet's keys and their agents, in every
  project. Checked at
  most every 30 seconds, and again at once when a key changes hands.
- A key whose edits a fleet vote has restricted can copy the code but not
  send changes.
- Nobody rewrites or removes what the fleet has sent: the store refuses a
  force push and the deletion of a branch or tag, for everyone (git's
  `receive.denyNonFastForwards` and `receive.denyDeletes`, set on the store's
  receive-pack). New branches and ordinary pushes work as usual.
- An archived project's repository is copied and never changed: Keyfleet
  refuses a push to it (403 `code_project_archived`) before the store is
  asked. A Key that takes the project over can push again.
- Deleting a project deletes its repository from the store for good, with
  its history (`Keyfleet.Code.DeleteRepository`, queued as the project is
  deleted). The store's `DELETE /api/v1/repos/<owner>/<repository>` takes
  only a `delete` pass, which only Keyfleet's own key signs; it answers 204,
  also for a repository already gone, so a failed run is made again a minute
  later. That call is on the store's `kf-delete-repo` branch and not yet
  released: until it is, the store answers 404, a deletion's run gives up
  after its 20 tries, and the repository stays in the store, out of
  everyone's reach. Release the store first.
- Each change sent is recorded under its project, the key and the wallet
  that sent it, and the project's Code shows the latest ten (key, branch and
  time; never the commit message).
- People: a person gets a password from the Code panel in the fleet's
  workspace. Git uses it with any user name, for every project's repository
  in that fleet. It lasts 12 hours and ends when they sign out.
- Agents: no password. The `git-remote-siwa` helper
  (`platform/priv/public/git-remote-siwa`, served at
  `https://keyfleet.ai/agent/git-remote-siwa`) signs every request git makes
  with the agent's own SIWA key: method, path with query, and the sha-256
  digest of the exact body, a push's pack included. The sign-in server checks
  the signature, which covers that digest, before the body is read; then the
  agent's pairing and Key or shard are checked, on every request. Only then
  is the body written to a file as it arrives (up to 100 MB, each read waiting
  at most 15 seconds and the whole body at most 10 minutes), and it reaches
  the store only if its sha-256 is the signed digest. Any other body is
  refused and its file deleted. A person's body is read the same way once
  their password stands. Once a body is in, the Key is checked again and
  only then is the store's pass made, so a slow push never reaches the store
  with a pass that has run out. The sign-in server must list
  `https://code.keyfleet.ai` under the `keyfleet` audience, as it lists the
  notebook host, for the helper to sign in there.

The code is in `platform/lib/keyfleet/code.ex`, `platform/lib/keyfleet/code/`,
`platform/lib/keyfleet_web/code_password.ex`,
`platform/lib/keyfleet_web/plugs/code_gateway.ex` and the helper
`platform/priv/public/git-remote-siwa`. The store's own notes are in
`repos/twigpine/infra/keyfleet/README.md`.

## Settings

| Name | Where | Value |
| --- | --- | --- |
| `KEYFLEET_HUB_SIGNING_KEY` | Keyfleet secret | The JWK Set whose first key signs every pass (the same keys the notebook hubs use). |
| `KEYFLEET_CODE_NODE` | Keyfleet secret | The store's private address, `http://keyfleet-code.flycast`. |
| `KEYFLEET_PASS_JWKS` | store secret | The public half of Keyfleet's keys: the JSON at `https://keyfleet.ai/.well-known/hub-jwks.json`. |
| `KEYFLEET_PASS_ISSUER` | store, `fly.toml` | `https://keyfleet.ai` |

The code host, pass life, password life, request size cap (100 MB), the
waits for a body and admission time live in `config :keyfleet, :code`
(`platform/config/config.exs`).

## Running it on this computer

1. Make a signing key for Keyfleet, from `platform/`:

   ```sh
   mix run --no-start -e 'IO.puts(Jason.encode!(%{"keys" => [JOSE.JWK.generate_key({:ec, "P-256"}) |> JOSE.JWK.to_map() |> elem(1)]}))' > "$TMPDIR/code-signing.json"
   ```

   Start the site with `KEYFLEET_HUB_SIGNING_KEY="$(cat "$TMPDIR/code-signing.json")"`
   and save its public keys for the store:

   ```sh
   curl -s http://localhost:4000/.well-known/hub-jwks.json > "$TMPDIR/code-jwks.json"
   ```

2. Start the store on port 4810 as `repos/twigpine/infra/keyfleet/README.md`
   ("Build and run locally") says, with
   `KEYFLEET_PASS_JWKS="$(cat "$TMPDIR/code-jwks.json")"`. In development
   the site expects it at `http://127.0.0.1:4810` (`platform/config/dev.exs`).

3. The code host is `code.localhost`. Get a password from a fleet's workspace
   while signed in as a key holder (a repository not made yet is set up then;
   give it a few seconds), then:

   ```sh
   git clone http://code.localhost:4000/<repository>.git
   ```

   Git asks for a user name (anything) and the password.

## On Fly

The code store is live: `keyfleet-code` runs at its private Flycast address,
`keyfleet` reaches it through `KEYFLEET_CODE_NODE` (a release without it does
not start), and git reaches the fleets' code at `code.keyfleet.ai`. When the
store cannot be reached, stops mid-exchange or answers with a fault of its
own, the site saves it with its errors at `/admin/errors`
(`Keyfleet.Code.StoreDownError`), which Fly Sentinel reads. Making a
project's repository (`Keyfleet.Code.Setup`, queued as the project starts)
tries once a minute, 20 times; until it works, git is told when the next try
is. A setup that gave up starts again on
the next ask, which git is told and the site saves the same way.

These are the steps it was set up with, for setting it up again; each needs
the founder's go:

1. Create `keyfleet-code` with its volume and its own database on the shared
   PostgreSQL 17 server, private address only (`repos/twigpine/infra/keyfleet/README.md`,
   "Deploy on Fly").
2. Set `KEYFLEET_CODE_NODE` on `keyfleet`, then release Keyfleet. A release
   without it does not start.
3. Point `code.keyfleet.ai` at the `keyfleet` app in Vercel DNS and add its
   certificate with `fly certs add code.keyfleet.ai -a keyfleet`, then
   `fly certs check`.
