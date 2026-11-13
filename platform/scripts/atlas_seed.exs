# A year of a busy fleet's work in its Atlas, to try the Atlas at the scale it
# is built for and to time its reads: 5,000 changes to the workspace's items
# and 500 notebooks made or saved a day on average, across 60 projects and 40
# Keys, quieter at weekends and growing over the year. Each day is counted as
# the site counts it (`Keyfleet.Atlas.Count`), with the items and notebooks
# their titles come from. `scripts/atlas_reads.exs` then times every read the
# page and the agents' tools make at that size.
#
# Only for a local dev or test database:
#
#     MIX_ENV=test MIX_TEST_PARTITION=_atlas mix ecto.create
#     MIX_ENV=test MIX_TEST_PARTITION=_atlas mix keyfleet.setup_local_auth
#     MIX_ENV=test MIX_TEST_PARTITION=_atlas mix run -e 'Keyfleet.Fleets.bootstrap_catalog!()'
#     MIX_ENV=test MIX_TEST_PARTITION=_atlas mix run scripts/atlas_seed.exs [fleet]
#     MIX_ENV=test MIX_TEST_PARTITION=_atlas mix run scripts/atlas_reads.exs [fleet]
#
# The fleet is fleet_tech_classic unless named, and must have nothing counted
# yet. Counting only adds, so a second run on the same fleet is refused.

alias Keyfleet.{Access, Atlas, Graph, Projects, Repo}
alias Keyfleet.Atlas.Count

repo = Repo.config()

unless Mix.env() in [:dev, :test] and repo[:url] == nil and
         repo[:hostname] in ["127.0.0.1", "localhost"] do
  Mix.raise("The Atlas seed writes only to a local dev or test database.")
end

# The test database lends a connection to one caller for two minutes at most;
# this run keeps its own, outside a transaction, for as long as it takes.
if repo[:pool] == Ecto.Adapters.SQL.Sandbox,
  do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false, ownership_timeout: :infinity)

fleet = List.first(System.argv(), "fleet_tech_classic")
system = %Keyfleet.Actors.System{}
read_as = [actor: system, context: Access.context(system, fleet, :member)]
Keyfleet.Fleets.get_fleet!(fleet)

if Atlas.swarm!(
     fleet,
     :year,
     ~U[2000-01-01 00:00:00Z],
     ~U[2100-01-01 00:00:00Z],
     %{by: []},
     read_as
   ) != [] do
  Mix.raise("#{fleet} has work counted in its Atlas already.")
end

:rand.seed(:exsss, {2026, 11, 13})

# The year up to yesterday.
days = 365
first_day = Date.add(Date.utc_today(), -days)

## The fleet's projects and Keys

titles =
  ~w(Harbour Pricing Outreach Ledger Survey Lighthouse Charts Signals Treasury Docks Tides Compass
     Beacon Atlas Anchor Rigging Galley Mooring Ballast Keel Sextant Mast Hull Bridge Cargo Course
     Reef Shoal Current Delta Estuary Fjord Gulf Inlet Lagoon Strait Sound Bay Cove Haven Port
     Quay Wharf Pier Jetty Buoy Channel Isle Atoll Cape Headland Bluff Dune Marsh Tideway Mainsail
     Foresail Spinnaker)
  |> Enum.take(59)

projects =
  [{Projects.general(), "General"}] ++
    Enum.map(titles, fn title -> {String.downcase(title), title} end)

existing = fleet |> Projects.project_titles!(authorize?: false) |> MapSet.new(& &1.name)

# Each project is held by a Key of its own, as a Key holds one at a time.
for {{name, title}, index} <- Enum.with_index(projects, 1), name not in existing do
  Keyfleet.Projects.Project
  |> Ash.Changeset.for_create(:create, %{fleet_id: fleet, name: name, title: title, key: index},
    actor: system
  )
  |> Ash.create!()
end

# The workspace's items are kept beside the copy of its log.
Graph.get_cursor!(fleet, actor: system) ||
  Graph.start_cursor!(%{fleet_id: fleet, run_id: "atlas_seed"}, actor: system)

# Busier projects first; a few start late in the year and a few go quiet.
project_plan =
  projects
  |> Enum.with_index()
  |> Enum.map(fn {{name, _title}, rank} ->
    %{
      name: name,
      weight: 1 / :math.pow(rank + 1, 1.05),
      from: if(rank >= 48, do: 120 + rank * 3, else: 0),
      until: if(rank in 18..22, do: 200 + rank, else: days),
      keys: Enum.take_random(1..40, 3 + rem(rank * 7, 9))
    }
  end)

# One of `weighted`'s values, each as likely as its weight.
pick = fn weighted ->
  point = :rand.uniform() * Enum.sum_by(weighted, &elem(&1, 1))

  weighted
  |> Enum.reduce_while({point, nil}, fn {value, weight}, {left, _last} ->
    if left <= weight, do: {:halt, {0, value}}, else: {:cont, {left - weight, value}}
  end)
  |> elem(1)
end

# Work peaks in the European afternoon and the American morning, in UTC.
hours = for hour <- 0..23, do: {hour, 0.25 + :math.exp(-:math.pow((hour - 15) / 4.5, 2))}

types = [
  {"task", 40},
  {"finding", 15},
  {"note", 15},
  {"evidence", 12},
  {"goal", 9},
  {"dead_end", 5},
  {"service", 4}
]

defaults = %{
  "goal" => %{
    "status" => "open",
    "success_criteria" => [],
    "open_questions" => [],
    "discussion" => []
  },
  "task" => %{
    "deliverable" => nil,
    "acceptance_criteria" => [],
    "progress" => "doing",
    "next_step" => nil,
    "commit_ref" => nil,
    "notebook_ref" => nil,
    "result_ref" => nil,
    "discussion" => []
  },
  "finding" => %{"confidence" => "medium", "uncertainty" => nil, "discussion" => []},
  "evidence" => %{"digest" => nil, "excerpt" => nil, "how_obtained" => nil, "discussion" => []},
  "service" => %{
    "payment_asset" => nil,
    "price_proposal" => nil,
    "implementation_refs" => [],
    "discussion" => []
  },
  "note" => %{"discussion" => []},
  "dead_end" => %{"discussion" => []}
}

verbs =
  ~w(Draft Check Map Price Survey Compare Write Measure Review Plan Test Collect Trace Sketch Settle)

nouns =
  ~w(berths tariffs routes ledgers buoys charts manifests tides crews contracts depths quotes moorings lanes)

title_of = fn -> "#{Enum.random(verbs)} #{Enum.random(nouns)} #{:rand.uniform(400)}" end

## A year, a day at a time

started = System.monotonic_time(:millisecond)
written = [actor: system, bulk_options: [return_errors?: true, stop_on_error?: true]]
contract = "0x" <> String.duplicate("b2", 20)

{_state, totals} =
  Enum.reduce(
    0..(days - 1),
    {%{items: %{}, notebooks: %{}, seq: 0}, %{changes: 0, notebooks: 0}},
    fn day, {state, totals} ->
      date = Date.add(first_day, day)
      growth = 0.7 + 0.6 * day / (days - 1)
      weekday = if Date.day_of_week(date) in [6, 7], do: 0.6, else: 1.16
      noise = 0.85 + :rand.uniform() * 0.3
      changes = round(5_000 * growth * weekday * noise)
      saves = round(500 * growth * weekday * noise)

      live = for plan <- project_plan, day >= plan.from, day < plan.until, do: {plan, plan.weight}

      moment = fn ->
        hour = pick.(hours)

        DateTime.new!(
          date,
          Time.new!(hour, :rand.uniform(60) - 1, :rand.uniform(60) - 1),
          "Etc/UTC"
        )
      end

      key_of = fn plan -> if :rand.uniform() < 0.03, do: nil, else: Enum.random(plan.keys) end

      # Items: three in ten changes make one, the rest patch one made lately in
      # the same project, the newest most often.
      {state, item_touches, made} =
        Enum.reduce(1..changes, {state, [], []}, fn _n, {state, touches, made} ->
          plan = pick.(live)
          recent = Map.get(state.items, plan.name, [])
          at = moment.()
          key = key_of.(plan)

          if recent == [] or :rand.uniform() < 0.3 do
            seq = state.seq + 1
            type = pick.(types)
            id = "#{type}##{seq}"

            object = %{
              fleet_id: fleet,
              id: id,
              type: type,
              project: plan.name,
              data: Map.put(defaults[type], "title", title_of.()),
              sys:
                Map.merge(if(type in ["goal", "task"], do: %{"joined" => []}, else: %{}), %{
                  "project" => plan.name,
                  "archived" => false,
                  "created_by" => %{
                    "key" => %{"chain_id" => 8453, "contract" => contract, "token_id" => key || 1},
                    "ownership_epoch" => 1,
                    "kind" => "agent",
                    "wallet" => "0x" <> String.duplicate("a1", 20)
                  }
                }),
              version: 1,
              changed_seq: seq,
              changed_at: DateTime.to_iso8601(at)
            }

            items = Map.put(state.items, plan.name, Enum.take([{id, type} | recent], 400))

            {%{state | seq: seq, items: items},
             [%{thing: id, kind: type, project: plan.name, at: at, key: key} | touches],
             [object | made]}
          else
            index = floor(length(recent) * :math.pow(:rand.uniform(), 3))
            {id, type} = Enum.at(recent, index)

            {state, [%{thing: id, kind: type, project: plan.name, at: at, key: key} | touches],
             made}
          end
        end)

      # Notebooks: one in five is new, the rest saved again, each at most once
      # an hour, as the hub's hourly read sees them.
      {state, notebook_touches, kept} =
        Enum.reduce(1..saves, {state, [], []}, fn _n, {state, touches, kept} ->
          plan = pick.(live)
          recent = Map.get(state.notebooks, plan.name, [])
          at = moment.()
          key = key_of.(plan)

          {id, state} =
            if recent == [] or :rand.uniform() < 0.2 do
              id = "nb-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

              {id,
               %{
                 state
                 | notebooks: Map.put(state.notebooks, plan.name, Enum.take([id | recent], 200))
               }}
            else
              {Enum.at(recent, floor(length(recent) * :math.pow(:rand.uniform(), 2))), state}
            end

          notebook = %{
            fleet_id: fleet,
            id: id,
            project: plan.name,
            space: "proj-#{plan.name}",
            title: "#{Enum.random(verbs)} #{Enum.random(nouns)}",
            author: "k_#{key || 1}",
            key: key,
            created_at: at,
            updated_at: at
          }

          {state,
           [%{thing: id, kind: "notebook", project: plan.name, at: at, key: key} | touches],
           [notebook | kept]}
        end)

      notebook_touches =
        Enum.uniq_by(notebook_touches, &{&1.thing, Atlas.Span.start(:hour, &1.at)})

      made
      |> Enum.chunk_every(2_000)
      |> Enum.each(&Graph.project_objects!(&1, written))

      # A notebook keeps when it was made and its last save.
      kept
      |> Enum.group_by(& &1.id)
      |> Enum.map(fn {_id, saves} ->
        first = Enum.min_by(saves, & &1.created_at, DateTime)
        last = Enum.max_by(saves, & &1.updated_at, DateTime)
        %{last | created_at: first.created_at}
      end)
      |> then(&Atlas.keep_notebooks!(&1, written))

      :ok = Count.count(fleet, item_touches ++ notebook_touches)

      if rem(day + 1, 10) == 0 or day == days - 1 do
        seconds = div(System.monotonic_time(:millisecond) - started, 1000)
        IO.puts("Counted #{day + 1} days to #{date} in #{seconds} s")
      end

      {state,
       %{
         changes: totals.changes + length(item_touches),
         notebooks: totals.notebooks + length(notebook_touches)
       }}
    end
  )

IO.puts("""

#{fleet}: #{totals.changes} changes to items and #{totals.notebooks} notebooks made or saved, \
#{Float.round(totals.changes / days, 1)} and #{Float.round(totals.notebooks / days, 1)} a day.
""")
