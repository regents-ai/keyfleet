# Times every read the Atlas page and the agents' tools make, on a fleet's
# Atlas as it stands (seeded by `scripts/atlas_seed.exs`), and shows each
# statement a read runs with its plan, after what the Atlas takes to store.
#
# Only for a local dev or test database:
#
#     MIX_ENV=test MIX_TEST_PARTITION=_atlas mix run scripts/atlas_reads.exs [fleet]
#
# The fleet is fleet_tech_classic unless named.

alias Keyfleet.{Access, Atlas, Projects, Repo}
alias KeyfleetWeb.AtlasPage

repo = Repo.config()

unless Mix.env() in [:dev, :test] and repo[:url] == nil and
         repo[:hostname] in ["127.0.0.1", "localhost"] do
  Mix.raise("The Atlas reads are timed only on a local dev or test database.")
end

# The test database lends a connection to one caller for two minutes at most;
# this run keeps its own, outside a transaction, for as long as it takes.
if repo[:pool] == Ecto.Adapters.SQL.Sandbox,
  do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)

fleet = List.first(System.argv(), "fleet_tech_classic")
system = %Keyfleet.Actors.System{}
read_as = [actor: system, context: Access.context(system, fleet, :member)]
Keyfleet.Fleets.get_fleet!(fleet)

## What it takes to store

Repo.query!("ANALYZE")

sizes =
  Repo.query!(
    """
    SELECT c.relname, c.reltuples::bigint, pg_size_pretty(pg_relation_size(c.oid)),
           pg_size_pretty(pg_indexes_size(c.oid))
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relkind = 'r'
      AND c.relname IN ('atlas_things', 'atlas_buckets', 'atlas_notebooks', 'graph_objects')
    ORDER BY c.relname
    """,
    [repo[:migration_default_prefix]]
  )

IO.puts("Table | Rows (estimate) | Rows' size | Indexes' size")

for [name, rows, size, indexes] <- sizes.rows,
    do: IO.puts("#{name} | #{rows} | #{size} | #{indexes}")

## Each read, timed, with the plan of every statement it runs

parent = self()

:telemetry.attach(
  "atlas-reads-plans",
  [:keyfleet, :repo, :query],
  fn _event, _measurements, metadata, _config ->
    if self() == parent and Process.get(:atlas_reads_capture),
      do: send(parent, {:statement, metadata.query, metadata.params})
  end,
  nil
)

plans = fn ->
  receive do
    {:statement, sql, params} -> [{sql, params}]
  after
    0 -> []
  end
end

now = DateTime.utc_now()
year_start = Atlas.Span.start(:year, now)
busiest = Projects.general()

reads = [
  {"Picture rows, all work", fn -> AtlasPage.rows(fleet, nil, read_as) end},
  {"Picture rows, notebooks", fn -> AtlasPage.rows(fleet, :notebook, read_as) end},
  {"Active strip, the year",
   fn -> AtlasPage.most_active(fleet, :year, now, [limit: 8] ++ read_as) end},
  {"Active strip, a day",
   fn -> AtlasPage.most_active(fleet, :day, now, [limit: 8] ++ read_as) end},
  {"Blocks, the year by project and kind",
   fn ->
     {from, to} = AtlasPage.window(:year, now)
     AtlasPage.swarm(fleet, :year, from, to, %{by: [:project, :kind]}, read_as)
   end},
  {"Blocks, a kind's things, the year",
   fn ->
     AtlasPage.most_active(fleet, :year, now, [limit: 100, project: busiest, kind: "task"] ++ read_as)
   end},
  {"List totals, the year", fn -> AtlasPage.totals(fleet, :year, now, nil, read_as) end},
  {"List projects, the year", fn -> AtlasPage.projects(fleet, :year, now, nil, read_as) end},
  {"List latest, the year",
   fn -> AtlasPage.newest(fleet, :year, now, [limit: 20] ++ read_as) end},
  {"List latest, second page",
   fn ->
     %{after: cursor} = AtlasPage.newest(fleet, :year, now, [limit: 20] ++ read_as)
     AtlasPage.newest(fleet, :year, now, [limit: 20, after: cursor] ++ read_as)
   end},
  {"Most active tasks, the year",
   fn -> AtlasPage.most_active(fleet, :year, now, [limit: 20, kind: "task"] ++ read_as) end},
  {"Most active of a project, the year",
   fn -> AtlasPage.most_active(fleet, :year, now, [limit: 20, project: busiest] ++ read_as) end},
  {"Newest notebooks, a month",
   fn -> AtlasPage.newest(fleet, :month, now, [limit: 20, source: :notebook] ++ read_as) end},
  {"Agent swarm, a month by day and kind",
   fn ->
     {from, to} = AtlasPage.window(:month, now)
     AtlasPage.swarm(fleet, :day, from, to, %{by: [:kind]}, read_as)
   end},
  {"Agent swarm, the year by week",
   fn -> AtlasPage.swarm(fleet, :week, year_start, now, %{by: []}, read_as) end}
]

IO.puts("\nRead | Median of 9 (ms) | Slowest (ms) | Statements")

details =
  for {name, read} <- reads do
    read.()
    times = for _ <- 1..9, do: elem(:timer.tc(read), 0) / 1000
    sorted = Enum.sort(times)

    Process.put(:atlas_reads_capture, true)
    read.()
    Process.delete(:atlas_reads_capture)
    statements = Stream.repeatedly(plans) |> Enum.take_while(&(&1 != [])) |> Enum.concat()

    IO.puts(
      "#{name} | #{Float.round(Enum.at(sorted, 4), 1)} | #{Float.round(List.last(sorted), 1)} | #{length(statements)}"
    )

    {name, statements}
  end

for {name, statements} <- details, {sql, params} <- statements do
  plan = Repo.query!("EXPLAIN (ANALYZE, BUFFERS) " <> sql, params)
  IO.puts("\n## #{name}\n\n#{sql}\n")
  for [line] <- plan.rows, do: IO.puts(line)
end
