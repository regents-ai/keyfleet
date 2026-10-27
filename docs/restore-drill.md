# Restore drill

The drill proves that Keyfleet's data comes back: the fleets' work graphs and
code from Fly volume snapshots, and the database from a point-in-time restore.
Everything is restored onto scratch copies. The live volumes and the
production database are only read; the live site keeps running throughout.

`scripts/restore-drill.sh` runs every step. The Mac build session runs it, in
one sitting, after Sean types his go for the drill naming the commit it runs
from, for example `go restore drill Keyfleet <sha>`. A relayed go or a card tap
does not count.

## Where the data lives

| Data | Where | How it comes back |
| --- | --- | --- |
| Each fleet's work graph | `/data/graph/<fleet id>.sqlite` on the volume `keyfleet_graph`, attached to the `keyfleet` graph machine `d891115dbe7098` (`iad`) | A Fly volume snapshot restored onto a new volume |
| The fleets' code | `/data/repos` and the store's identity key `/data/keys/identity.pem` on the volume `keyfleet_code_data` of the app `keyfleet-code` | A Fly volume snapshot restored onto a new volume |
| Everything else: fleets, rooms, messages, notebook results, pairings, sign-in | Fly Managed Postgres cluster `dzx6qo6xqzvojpv5` (`regents-platform-prod`), schema `keyfleet_app` | A point-in-time restore into a new cluster |
| The code store's own records (repositories, pushes) | The database its `DATABASE_URL` secret names | The same restore, when that database is on the same cluster; `check` says which |

The database is Fly Managed Postgres, not Neon and not a Fly Postgres app:
`platform/lib/keyfleet/database_config.ex` admits only the host
`direct.dzx6qo6xqzvojpv5.flympg.net`, and `fly.toml` mounts the graph volume.
The cluster is shared by every Regents site; Keyfleet's tables are only its
`keyfleet_app` schema. A restore always copies the whole cluster into a new
one: Fly offers no per-schema restore.

A notebook page members link to is kept in the database
(`notebook_saved_outputs`), so the database restore covers it. The notebook
hubs' own volumes and the pictures bucket are outside this drill.

## What changes, and what needs the go

| Step | Changes | Needs `--live` and Sean's go |
| --- | --- | --- |
| `check` | Nothing. Reads Fly, the live site, and two machines' environment cut down to host and database name | No |
| `snapshot` | Takes one extra snapshot of each live volume. The volumes stay attached and in use | Yes |
| `restore-volumes` | Creates two scratch volumes and one sleeping machine named `restore-drill` in each of `keyfleet` and `keyfleet-code` | Yes |
| `verify-volumes` | Nothing. Reads the scratch copies | No |
| `restore-db` | Creates a new cluster `keyfleet-drill-<time>`, a full copy of the shared cluster, billed separately while it exists | Yes |
| `verify-db` | Nothing. Read-only queries on both clusters | No |
| `cleanup` | Destroys the scratch machines, volumes and cluster the drill recorded, and nothing else | Yes |
| `rollback <version>` | Deploys an earlier release's image. For an incident, not part of the drill | Yes |

The script refuses every step marked yes unless it is given `--live`. Cleanup
destroys only what the drill recorded, and refuses the live machine, any volume
not named as a drill volume or still attached, and the production cluster.

The drill machines sleep and serve nothing: they have no services, so no
request reaches them. The `keyfleet` drill machine still receives the app's
secrets, as every machine in the app does.

## Before the drill

- The branch with this script is on the Mac checkout, and the go names its commit.
- `fly`, `jq`, `psql` and `curl` are installed, and `fly auth whoami` is an
  account in the `regents` organization. Managed Postgres commands refuse an
  old-style token ("MPG commands require updated tokens"); `fly auth login`
  again if they do.
- No `fly mpg proxy` is running: `fly mpg connect` uses the same local port.
- What the drill made is recorded under `~/.keyfleet/restore-drill` (set
  `KEYFLEET_DRILL_STATE` to move it). `check` writes it afresh and `cleanup`
  removes it.

## The drill

Run from the repository root. Each step prints `==>` headings; the shapes below
are what to expect, with Fly's own tables abridged.

### 1. Check

```sh
scripts/restore-drill.sh check
```

Expect, in order: the flyctl version and account; `https://keyfleet.ai/healthz
answered 200`; `fly status` showing `d891115dbe7098` started; the newest
releases, the live one first and the rollback target under it; each live
volume, for example

```
keyfleet_graph vol_… 1 GB, snapshots kept 5 days, scheduled true
keyfleet_code_data vol_… 3 GB, snapshots kept 5 days, scheduled true
```

with its snapshots; the live graph files, one fleet id per line
(`regents_club` among them); the live code store's repositories and their
count; `fly mpg list` with `dzx6qo6xqzvojpv5` `ready`;
the cluster's backups of the last 24 hours; then

```
keyfleet reads direct.dzx6qo6xqzvojpv5.flympg.net/<database>
keyfleet-code reads <host>/<database>
==> Leftovers from an earlier drill
none
```

Leftovers are listed by app, id and name. Stop if any line says `Refusing`
or any leftover is listed. If `scheduled` is `false` or a volume has no
snapshots, that is a finding: the volume has no automatic backups.

### 2. Snapshot the live volumes (live)

```sh
scripts/restore-drill.sh snapshot --live
```

Expect `Scheduled to snapshot volume vol_…` and, within ten minutes,
`vol_…: snapshot vs_…` for each volume, then the health line. A snapshot
catches the graph files as a crash would; SQLite replays its log when the
copy is opened, which step 4 checks.

### 3. Restore the snapshots onto scratch volumes (live)

```sh
scripts/restore-drill.sh restore-volumes --live
```

Expect, for each app, `scratch volume keyfleet_graph_drill vol_… from vs_…`
(and `keyfleet_code_drill`), Fly's machine summary, and
`drill machine <id>`. The live machine and volumes are untouched.

### 4. Verify the restored volumes

```sh
scripts/restore-drill.sh verify-volumes
```

Expect one line per fleet graph, `<fleet id> ok <events>`, for example
`regents_club ok 1874`, then `Every live fleet graph came back and passes its
integrity check.`; then, against the repositories `check` listed,

```
identity key: present
<owner>/<repository>.git ok <refs>
repositories: <n>
The code store's key and every live repository came back.
```

The key itself is never printed. `repositories: 0` is expected while no fleet
has a code store yet (the Regents Club's waits on its setup job).

### 5. Restore the database to a point in time (live)

```sh
scripts/restore-drill.sh restore-db --live
```

The restore point is ten minutes before the command runs; `--at
2026-10-17T03:00:00Z` names another, inside the cluster's recovery window.
Expect

```
Restoring cluster dzx6qo6xqzvojpv5 to point in time 2026-10-17T03:00:00Z...
Restore initiated successfully!
  Cluster ID: <new id>
  Cluster Name: keyfleet-drill-<time>
==> Waiting for <new id> to be ready
<new id> is ready.
```

then the health line. Fly provisions the copy in the background; the script
waits up to 90 minutes. If Fly answers `point-in-time restore is not supported
for this cluster`, that is the drill's finding: the shared cluster has backups
but no point-in-time recovery.

### 6. Verify the restored database

```sh
scripts/restore-drill.sh verify-db
```

It runs the same read-only queries on production and on the restore, for rows
written at least five minutes before the restore point, and names rows only by
id and hash. Expect

```
keyfleet: migration matches (migration 20261015213318)
keyfleet: fleets matches (fleets 5 <hash>)
keyfleet: newest-message matches (newest-message <id> <time>)
keyfleet: newest-notebook-result matches (newest-notebook-result <fleet> <notebook> <source> <saved at> <page hash>)
keyfleet, counts (production now, then restored):
```

and two pairs of counts. The newest message and the newest kept notebook page
must be the same row in both, the page byte for byte; when there is none
before the cutoff, both read `none`. Counts can differ only
by rows removed after the restore point. When the code store's database is on
the same cluster, `keyfleet-code: code-repositories matches` follows.

The reads use `fly mpg connect`'s default user, with the operator's psqlrc set
aside. If that user cannot read `keyfleet_app` or the code store's database,
the step stops with `production gave no … line`: a finding about access, not
a failed restore.

### 7. Clean up (live)

```sh
scripts/restore-drill.sh cleanup --live
```

Expect the two drill machines and volumes destroyed, `Removing the restored
cluster keyfleet-drill-<time>`, the health line and `fly status` showing only
the graph machine `d891115dbe7098` and the site machine. The snapshots from step 2 expire with the volume's snapshot
retention. Run cleanup even when a step failed: it removes whatever the drill
recorded making, finding the restored cluster by the name `restore-db` records
before it asks Fly.

## If something goes wrong during the drill

Nothing live is changed, so going back is cleanup. Run
`scripts/restore-drill.sh cleanup --live`. If a scratch cluster or volume is
left, `check` lists it; remove it by its id, after reading its name, with
`fly mpg destroy <id>` or `fly volumes destroy <id> --app <app>`, never the
production cluster or a volume named `keyfleet_graph` or `keyfleet_code_data`.

## Rolling the site back

A rollback puts an earlier release's code back. It is app-only: the database
keeps every migration that ran (migrations are never undone), and the old
release's `/app/bin/migrate` finds nothing to run.

```sh
fly releases --app keyfleet --image
scripts/restore-drill.sh rollback v78 --live
```

Fly release numbers run one ahead of product numbers. On 17 October 2026 the
live release is Fly v80 (product v79, `ffeb3c52`) and the rollback target is
Fly v78 (`602443c8`); the release stack shipping next moves both, and `check`
lists the current ones. No migration was added between `602443c8` and the
release stack's tip, so v78's code meets the tables it knows. The script lists
any migration the live release carries that the target does not, and asks
before going on. It deploys only a completed release, with the `fly.toml` of
the target's own commit, to the graph machine and then the site machine, as
`scripts/deploy.sh` releases. By hand it is

```sh
git show <target commit>:platform/fly.toml > /tmp/fly.toml
fly deploy --app keyfleet --config /tmp/fly.toml --image <the target's Docker Image> --ha=false --process-groups graph
fly deploy --app keyfleet --config /tmp/fly.toml --image <the target's Docker Image> --ha=false --process-groups site --strategy bluegreen
```

then `https://keyfleet.ai/healthz` answers 200 and `fly status --app keyfleet`
shows the target's image.

A target from before the site and graph machines were split (21 October
2026) has one machine in its `fly.toml`; going back to one is the split's own
rollback, in the deploy checklist's "Two machines" section.

## A real loss (not the drill)

These are the steps the drill rehearses, put into service. None is verified
yet, and each needs Sean's typed go naming it.

- **The graph volume.** Fork the damaged volume to keep it
  (`fly volumes fork <id> --name keyfleet_graph_lost --app keyfleet`), stop
  and destroy the graph machine, destroy the damaged volume, create
  `keyfleet_graph` from the chosen snapshot (`fly volumes create keyfleet_graph
  --snapshot-id <vs_…> --region iad --size <GB> --app keyfleet`), then release
  with `scripts/deploy.sh production`, which creates the graph machine on it.
  The new machine has a new id; update `LIVE_MACHINE` here and in the script.
- **The code store volume.** The same, in `keyfleet-code`, with
  `keyfleet_code_data`, deployed from the code store's checkout, `repos/twigpine`
  (`infra/keyfleet/README.md`, "Deploy on Fly").
- **The database.** A point-in-time restore makes a new cluster with a new id
  and host. Keyfleet admits only `dzx6qo6xqzvojpv5`, and every Regents site
  shares that cluster, so moving to a restored one is a coordinated change:
  each site's release names the new cluster, and each site's database secrets
  are set to it.
