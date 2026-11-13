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
  alias Keyfleet.Usage.Count
  alias Keyfleet.WorkspaceFixtures, as: Workspace

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

  test "anyone reads a fleet's usage, and only the server counts it" do
    count!(@fleet, @november)
    person = %Keyfleet.Actors.Human{human_account_id: 1, wallet_addresses: [@wallet]}

    assert %{fleet_id: @fleet, month: @november} = Usage.month_usage!(@fleet, @november)

    for actor <- [nil, person] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Usage.count_month(@fleet, @november, actor: actor)

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
