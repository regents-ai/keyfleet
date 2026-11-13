defmodule Keyfleet.UsageTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Event
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Usage
  alias Keyfleet.Usage.{Count, ReadHub}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.SignedAgentHelpers

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @system %Keyfleet.Actors.System{}
  @october ~D[2026-10-01]
  @november ~D[2026-11-01]
  @wallet "0x" <> String.duplicate("a1", 20)

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    %{rooms: Rooms.bootstrap_rooms!(Fleets.catalog_ids())}
  end

  test "a month's chat is the posts written in it, by UTC, in the fleet's rooms and on its Keys' walls",
       %{rooms: rooms} do
    general = room_id(rooms, @fleet, "general")
    wall = Rooms.open_key_thread!(@fleet, 7, actor: @system).id

    line!(@fleet, general, ~U[2026-10-31 23:59:59.999999Z], "Last of October")
    line!(@fleet, general, ~U[2026-11-01 00:00:00.000000Z], "First of November")
    line!(@fleet, wall, ~U[2026-11-15 12:00:00Z], "Grüße an Key 7", in_key_thread: true)
    line!(@fleet, general, ~U[2026-11-20 08:00:00Z], "Hull survey", kind: "room_named")
    line!(@fleet, general, ~U[2026-11-30 23:59:59.999999Z], "Last of November")
    line!(@fleet, general, ~U[2026-12-01 00:00:00.000000Z], "First of December")

    line!(
      @other_fleet,
      room_id(rooms, @other_fleet, "general"),
      ~U[2026-11-10 00:00:00Z],
      "Elsewhere"
    )

    november = count!(@fleet, @november)
    october = count!(@fleet, @october)

    assert {november.chat_posts, november.chat_bytes} ==
             {3, bytes(["First of November", "Grüße an Key 7", "Last of November"])}

    assert {october.chat_posts, october.chat_bytes} == {1, bytes(["Last of October"])}
  end

  test "a month's workspace is the record its log had taken by the month's end" do
    Workspace.open_log(@fleet)

    events = [
      event(1, "object.created", "2026-10-31T23:59:59Z", %{"id" => "goal#1"}),
      event(2, "patch.applied", "2026-11-01T00:00:00Z", %{"target" => "goal#1", "diff" => %{}}),
      event(3, "object.created", "2026-11-30T23:59:59.999999Z", %{"id" => "task#3"}),
      # Written on the last evening of November by a clock five hours behind
      # UTC, which is already December.
      event(4, "object.created", "2026-11-30T20:00:00-05:00", %{"id" => "task#4"}),
      event(5, "object.created", "2026-12-01T00:00:00Z", %{"id" => "task#5"})
    ]

    Graph.record_events!(events, actor: @system)

    november = count!(@fleet, @november)
    october = count!(@fleet, @october)

    assert {november.workspace_bytes, november.workspace_items} ==
             {size(Enum.take(events, 3)), 2}

    assert {october.workspace_bytes, october.workspace_items} == {size(Enum.take(events, 1)), 1}
  end

  test "a fleet with nothing yet counts nothing" do
    assert %{workspace_bytes: 0, workspace_items: 0, chat_posts: 0, chat_bytes: 0} =
             count!(@fleet, @november)
  end

  test "each hourly count keeps one row a fleet for this month and the last, the same each time",
       %{rooms: rooms} do
    this_month = Date.beginning_of_month(Date.utc_today())
    last_month = Date.shift(this_month, month: -1)
    line!(@fleet, room_id(rooms, @fleet, "general"), DateTime.utc_now(), "Morning")

    assert perform_job(Count, %{}) == :ok
    first = figures()
    assert perform_job(Count, %{}) == :ok

    assert figures() == first

    assert Map.keys(first) ==
             Enum.sort(
               for fleet <- Fleets.catalog_ids(),
                   month <- [last_month, this_month],
                   do: {fleet, month}
             )

    assert first[{@fleet, this_month}] == {0, 0, 1, bytes(["Morning"])}
    assert first[{@fleet, last_month}] == {0, 0, 0, 0}
    assert Usage.this_month(@fleet).chat_posts == 1
  end

  test "a month's notebook hours are the time each machine ran in it, by UTC" do
    record!([
      # Across the turn of the month: an hour in each.
      machine("sess-turn", :session, ~U[2026-10-31 23:00:00Z], ~U[2026-11-01 01:00:00Z]),
      # Ended as November began: all of it in October.
      machine("run_edge", :run, ~U[2026-10-31 23:30:00Z], ~U[2026-11-01 00:00:00Z]),
      machine("run_short", :run, ~U[2026-11-10 10:00:00Z], ~U[2026-11-10 10:30:00Z]),
      # Still running when last read, after two hours.
      machine("sess-open", :session, ~U[2026-11-20 08:00:00Z], nil,
        seen_at: ~U[2026-11-20 10:00:00Z]
      ),
      machine("sess-dec", :session, ~U[2026-12-01 00:00:00Z], ~U[2026-12-01 00:10:00Z]),
      machine("sess-other", :session, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 10:00:00Z],
        fleet_id: @other_fleet
      )
    ])

    assert notebooks!(@fleet, @november) == 3600 + 1800 + 7200
    assert notebooks!(@fleet, @october) == 3600 + 1800
    assert notebooks!(@other_fleet, @november) == 3600
  end

  describe "the hourly hub read" do
    setup do
      %{hub: hub!(@fleet)}
    end

    test "counts this month's notebook hours from the machines the hub lists, the same each time",
         %{hub: hub} do
      from = DateTime.new!(this_month(), ~T[00:00:00])

      listed(hub, [
        listing("sess-a", "session", DateTime.add(from, 3600), DateTime.add(from, 5400)),
        listing("run_b", "run", DateTime.add(from, 7200), DateTime.add(from, 7290)),
        # Started last month: only its time this month counts here.
        listing("sess-c", "session", DateTime.add(from, -1800), DateTime.add(from, 1800))
      ])

      assert perform_job(Count, %{}) == :ok
      assert_enqueued(worker: ReadHub, args: %{fleet_id: @fleet})
      refute_enqueued(worker: ReadHub, args: %{fleet_id: @other_fleet})

      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok
      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok

      assert Usage.this_month(@fleet).notebook_seconds == 1800 + 90 + 1800

      assert [
               %{id: "run_b", kind: :run},
               %{id: "sess-a", kind: :session},
               %{id: "sess-c", kind: :session, ended_at: %DateTime{}}
             ] = machines(@fleet)

      # Last month ended before its hub was first read, and the other fleet
      # has no hub: neither has a figure.
      assert Usage.month_usage!(@fleet, last_month()).notebook_seconds == nil
      assert Usage.this_month(@other_fleet).notebook_seconds == nil
    end

    test "a machine still running counts until the last read that saw it, and stops there when its end is never seen",
         %{hub: hub} do
      started = lately()
      count!(@fleet, this_month())

      listed(hub, [listing("sess-open", "session", started, nil)])
      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok
      [%{seen_at: first_seen}] = machines(@fleet)

      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok
      [%{ended_at: nil, seen_at: last_seen}] = machines(@fleet)
      assert DateTime.after?(last_seen, first_seen)
      assert Usage.this_month(@fleet).notebook_seconds == ran(started, last_seen)

      # The hub drops its record before a read sees it end.
      listed(hub, [])
      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok

      assert [%{ended_at: nil, seen_at: ^last_seen}] = machines(@fleet)
      assert Usage.this_month(@fleet).notebook_seconds == ran(started, last_seen)
    end

    test "a machine seen running and then ended counts until its end", %{hub: hub} do
      started = lately()
      ended = DateTime.add(started, 300)
      count!(@fleet, this_month())

      listed(hub, [listing("run_c", "run", started, nil)])
      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok

      listed(hub, [listing("run_c", "run", started, ended)])
      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok

      assert [%{ended_at: ^ended}] = machines(@fleet)
      assert Usage.this_month(@fleet).notebook_seconds == ran(started, ended)
    end

    test "last month is counted again once it has a figure", %{hub: hub} do
      last_start = DateTime.new!(last_month(), ~T[00:00:00])
      assert perform_job(Count, %{}) == :ok

      # Counted while last month was under way.
      Usage.count_notebooks!(Usage.month_usage!(@fleet, last_month()), actor: @system)

      listed(hub, [
        listing("run_d", "run", DateTime.add(last_start, 60), DateTime.add(last_start, 660))
      ])

      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok

      assert Usage.month_usage!(@fleet, last_month()).notebook_seconds == 600
      assert Usage.this_month(@fleet).notebook_seconds == 0
    end

    test "a hub that lists no machines counts no hours" do
      count!(@fleet, this_month())

      assert perform_job(ReadHub, %{fleet_id: @fleet}) == :ok
      assert Usage.this_month(@fleet).notebook_seconds == 0
    end

    test "a hub that cannot be read leaves the figures as they were", %{hub: hub} do
      count!(@fleet, this_month())
      listed(hub, :down)

      assert {:error, {:hub, _address, {:status, 503}}} =
               perform_job(ReadHub, %{fleet_id: @fleet})

      assert Usage.this_month(@fleet).notebook_seconds == nil
      assert machines(@fleet) == []
    end
  end

  test "anyone reads a fleet's usage, and only the server counts it" do
    count!(@fleet, @november)
    person = %Keyfleet.Actors.Human{human_account_id: 1, wallet_addresses: [@wallet]}

    assert %{fleet_id: @fleet, month: @november} = usage = Usage.month_usage!(@fleet, @november)

    for actor <- [nil, person] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Usage.count_month(@fleet, @november, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = Usage.count_notebooks(usage, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Usage.Machine
               |> Ash.Changeset.for_create(
                 :record,
                 machine("sess-x", :session, ~U[2026-11-02 00:00:00Z], ~U[2026-11-02 01:00:00Z]),
                 actor: actor
               )
               |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               Usage.Machine
               |> Ash.Query.for_read(
                 :during,
                 %{fleet_id: @fleet, from: ~U[2026-11-01 00:00:00Z], to: DateTime.utc_now()},
                 actor: actor
               )
               |> Ash.read()

      assert {:error, %Ash.Error.Forbidden{}} =
               Event
               |> Ash.Query.for_read(
                 :taken_before,
                 %{fleet_id: @fleet, before: DateTime.utc_now()},
                 actor: actor
               )
               |> Ash.read()

      assert {:error, %Ash.Error.Forbidden{}} =
               Rooms.Message
               |> Ash.Query.for_read(
                 :written_between,
                 %{fleet_id: @fleet, from: ~U[2026-11-01 00:00:00Z], to: DateTime.utc_now()},
                 actor: actor
               )
               |> Ash.read()
    end
  end

  defp count!(fleet_id, month), do: Usage.count_month!(fleet_id, month, actor: @system)

  # The month's notebook hours, in seconds, counted from the machines recorded.
  defp notebooks!(fleet_id, month),
    do:
      fleet_id
      |> count!(month)
      |> Usage.count_notebooks!(actor: @system)
      |> Map.fetch!(:notebook_seconds)

  defp this_month, do: Date.beginning_of_month(Date.utc_today())
  defp last_month, do: Date.shift(this_month(), month: -1)

  # Ten minutes ago, or the month's start when that is later, so a machine
  # started then runs in this month alone.
  defp lately,
    do:
      Enum.max(
        [DateTime.add(DateTime.utc_now(), -600), DateTime.new!(this_month(), ~T[00:00:00])],
        DateTime
      )

  # A machine as a hub read records it, last seen at its end unless
  # `:seen_at` says otherwise.
  defp machine(id, kind, started_at, ended_at, opts \\ []),
    do: %{
      fleet_id: Keyword.get(opts, :fleet_id, @fleet),
      id: id,
      kind: kind,
      started_at: started_at,
      ended_at: ended_at,
      seen_at: Keyword.get(opts, :seen_at, ended_at)
    }

  defp record!(machines), do: Usage.record_machines!(machines, actor: @system)

  # The fleet's machines as recorded, by id.
  defp machines(fleet_id) do
    Usage.Machine
    |> Ash.Query.for_read(
      :during,
      %{fleet_id: fleet_id, from: ~U[2000-01-01 00:00:00Z], to: ~U[2100-01-01 00:00:00Z]},
      actor: @system
    )
    |> Ash.Query.sort(:id)
    |> Ash.read!()
  end

  # Whole seconds from `started_at` until `until`, as the count rounds them.
  defp ran(started_at, until),
    do: round(DateTime.diff(until, started_at, :microsecond) / 1_000_000)

  # A fleet's hub answering its machine list with what `listed/2` last put
  # there, or refusing it while `:down`.
  defp hub!(fleet_id) do
    {:ok, hub} = Agent.start_link(fn -> [] end)

    address =
      SignedAgentHelpers.serve!(:hub, fn
        %Plug.Conn{method: "GET", request_path: "/api/v1/admin/machines"} = conn, _opts ->
          case Agent.get(hub, & &1) do
            :down ->
              Plug.Conn.send_resp(conn, 503, "")

            items ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                200,
                Jason.encode!(%{success: true, data: %{items: items, next_cursor: nil}})
              )
          end
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(notebooks, :fleets, %{fleet_id => address})
    )

    hub
  end

  defp listed(hub, items), do: Agent.update(hub, fn _ -> items end)

  # A machine as the hub lists it.
  defp listing(id, kind, started_at, ended_at),
    do: %{
      id: id,
      kind: kind,
      started_at: DateTime.to_iso8601(started_at),
      ended_at: ended_at && DateTime.to_iso8601(ended_at)
    }

  # Every month counted, by fleet and month, with its figures.
  defp figures do
    for usage <- Ash.read!(Usage.Month), into: %{} do
      {{usage.fleet_id, usage.month},
       {usage.workspace_bytes, usage.workspace_items, usage.chat_posts, usage.chat_bytes}}
    end
  end

  defp room_id(rooms, fleet_id, slug),
    do: Enum.find(rooms, &(&1.fleet_id == fleet_id and &1.slug == slug)).id

  # A line written to a room at `at`: a post unless `:kind` says otherwise.
  defp line!(fleet_id, room_id, at, body, opts \\ []) do
    Repo.insert_all(
      "messages",
      [
        %{
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          seq: System.unique_integer([:positive]),
          fleet_id: fleet_id,
          room_id: Ecto.UUID.dump!(room_id),
          kind: Keyword.get(opts, :kind, "post"),
          in_key_thread: Keyword.get(opts, :in_key_thread, false),
          author_kind: "human",
          author_wallet: @wallet,
          as_key: 1,
          body: body,
          body_digest: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          idempotency_key: Ash.UUID.generate(),
          inserted_at: DateTime.to_naive(at)
        }
      ],
      prefix: "keyfleet_app"
    )
  end

  defp event(seq, type, timestamp, payload),
    do: %{
      fleet_id: @fleet,
      seq: seq,
      event_id: "evt_#{seq}",
      type: type,
      actor: "keyfleet:reactions",
      timestamp: timestamp,
      payload: payload
    }

  # The events as a reader receives them.
  defp size(events),
    do: events |> Enum.map(&(&1 |> Event.view() |> Jason.encode!() |> byte_size())) |> Enum.sum()

  defp bytes(bodies), do: bodies |> Enum.map(&byte_size/1) |> Enum.sum()
end
