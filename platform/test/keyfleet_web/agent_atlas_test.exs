defmodule KeyfleetWeb.AgentAtlasTest do
  # An agent reads a fleet's Atlas through its own signed requests: the
  # swarm's counts in one window and the things changed in it, a page at a
  # time, as they were counted. Every answer is held to the contract.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys, PairingHelpers}
  alias Keyfleet.Actors.System
  alias Keyfleet.Atlas.Count
  alias KeyfleetWeb.{Endpoint, SignedAgentHelpers, WorkspacePage}

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @person "0x00000000000000000000000000000000000000a1"
  @notebook "nb-0123456789abcdef"
  @swarm "/api/v1/agent/fleets/{fleet_id}/atlas/swarm"
  @things "/api/v1/agent/fleets/{fleet_id}/atlas/things"
  @board "/api/v1/agent/fleets/{fleet_id}/graph/board"
  # A time in the week from Monday 2 November 2026 that every touch but the
  # last falls in.
  @in_week "2026-11-04T12:00:00Z"

  # Each change: the thing, its kind, its project, when and as which Key.
  @touches [
    {"task#1", "task", "general", ~U[2026-11-02 09:15:00Z], 1},
    {"task#1", "task", "general", ~U[2026-11-02 09:40:00Z], 2},
    {"task#1", "task", "general", ~U[2026-11-03 14:00:00Z], 1},
    {"goal#2", "goal", "general", ~U[2026-11-02 10:00:00Z], 1},
    {"goal#2", "goal", "general", ~U[2026-11-04 11:00:00Z], 1},
    {"finding#3", "finding", "lab", ~U[2026-11-04 16:30:00Z], 2},
    {@notebook, "notebook", "lab", ~U[2026-11-05 08:00:00Z], 2},
    {@notebook, "notebook", "lab", ~U[2026-11-05 09:00:00Z], 2},
    {@notebook, "notebook", "lab", ~U[2026-11-05 10:00:00Z], 2},
    {@notebook, "notebook", "lab", ~U[2026-11-05 11:00:00Z], 2},
    {"note#4", "note", "lab", ~U[2026-11-06 12:00:00Z], nil},
    # The week after.
    {"task#5", "task", "general", ~U[2026-11-09 09:00:00Z], 1}
  ]

  # The week's things, the most changes and then the most Keys first, and
  # the one changed last first.
  @most_active [@notebook, "task#1", "goal#2", "finding#3", "note#4"]
  @newest ["note#4", @notebook, "finding#3", "goal#2", "task#1"]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    record!(1, @person)

    :ok =
      Count.count(
        @fleet,
        for {thing, kind, project, at, key} <- @touches do
          %{thing: thing, kind: kind, project: project, at: at, key: key}
        end
      )

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    {:ok, signer} = Siwa.LocalSigner.new()
    PairingHelpers.pair_wallet!(String.downcase(signer.address), @person)
    %{secret: secret, signer: signer}
  end

  test "a member's agent reads the week's counts, by day, as they were counted", c do
    swarm = post!(c, @swarm, %{"at" => @in_week}, 200)

    assert swarm["window"] == %{
             "span" => "week",
             "start" => "2026-11-02T00:00:00Z",
             "end" => "2026-11-09T00:00:00Z"
           }

    assert swarm["bucket"] == "day"
    assert swarm["totals"] == %{"changes" => 11, "things" => 5, "actors" => 2}

    assert counts(swarm["buckets"]) == [
             {~U[2026-11-02 00:00:00Z], 3, 2, 2},
             {~U[2026-11-03 00:00:00Z], 1, 1, 1},
             {~U[2026-11-04 00:00:00Z], 2, 2, 2},
             {~U[2026-11-05 00:00:00Z], 4, 1, 1},
             {~U[2026-11-06 00:00:00Z], 1, 1, 0}
           ]

    assert Enum.all?(swarm["buckets"], &(Map.keys(&1) == ~w(actors at changes things)))
    assert Enum.map(swarm["most_active"], & &1["id"]) == @most_active

    task = Enum.find(swarm["most_active"], &(&1["id"] == "task#1"))

    assert %{
             "kind" => "task",
             "project" => "general",
             "key" => 1,
             "changes" => 3,
             "actors" => 2
           } = task

    assert at(task["changed_at"]) == ~U[2026-11-03 14:00:00Z]
    assert task["page"] == Endpoint.url() <> WorkspacePage.item_path(@fleet, "task#1")

    note = Enum.find(swarm["most_active"], &(&1["id"] == "note#4"))
    assert %{"key" => nil, "actors" => 0, "changes" => 1} = note
  end

  test "the swarm splits its buckets by project or kind, and narrows to a project or source",
       c do
    by_project = post!(c, @swarm, %{"at" => @in_week, "by" => "project"}, 200)

    assert by_project["buckets"]
           |> Enum.map(&{at(&1["at"]), &1["project"], &1["changes"]})
           |> Enum.sort() == [
             {~U[2026-11-02 00:00:00Z], "general", 3},
             {~U[2026-11-03 00:00:00Z], "general", 1},
             {~U[2026-11-04 00:00:00Z], "general", 1},
             {~U[2026-11-04 00:00:00Z], "lab", 1},
             {~U[2026-11-05 00:00:00Z], "lab", 4},
             {~U[2026-11-06 00:00:00Z], "lab", 1}
           ]

    by_kind = post!(c, @swarm, %{"at" => @in_week, "by" => "kind", "bucket" => "hour"}, 200)
    assert by_kind["bucket"] == "hour"
    refute Enum.any?(by_kind["buckets"], &Map.has_key?(&1, "project"))

    assert by_kind["buckets"]
           |> Enum.filter(&(&1["kind"] == "notebook"))
           |> Enum.map(&{at(&1["at"]), &1["changes"]}) == [
             {~U[2026-11-05 08:00:00Z], 1},
             {~U[2026-11-05 09:00:00Z], 1},
             {~U[2026-11-05 10:00:00Z], 1},
             {~U[2026-11-05 11:00:00Z], 1}
           ]

    lab = post!(c, @swarm, %{"at" => @in_week, "project" => "lab", "most_active" => 2}, 200)
    assert lab["totals"] == %{"changes" => 6, "things" => 3, "actors" => 1}
    assert Enum.map(lab["most_active"], & &1["id"]) == [@notebook, "finding#3"]

    notebooks = post!(c, @swarm, %{"at" => @in_week, "source" => "notebook"}, 200)
    assert notebooks["totals"] == %{"changes" => 4, "things" => 1, "actors" => 1}

    month =
      post!(c, @swarm, %{"at" => @in_week, "window" => "month", "most_active" => 0}, 200)

    assert month["bucket"] == "day"
    assert month["totals"] == %{"changes" => 12, "things" => 6, "actors" => 2}
    assert month["most_active"] == []
  end

  test "keyset paging returns every thing of the window once, in either order", c do
    for {order, expected} <- [{"newest", @newest}, {"active", @most_active}] do
      body = %{"window" => "week", "at" => @in_week, "order" => order, "limit" => 2}
      assert pages(c, body) == expected, order
    end

    # A day's things, a kind and a source.
    assert pages(c, %{"at" => "2026-11-02T12:00:00Z", "limit" => 1}) == ["goal#2", "task#1"]

    assert pages(c, %{"window" => "week", "at" => @in_week, "kind" => "task", "limit" => 1}) ==
             ["task#1"]

    assert pages(c, %{"window" => "year", "at" => @in_week, "source" => "notebook"}) ==
             [@notebook]
  end

  test "an agent whose person holds no Key in the fleet is refused as the workspace refuses it",
       c do
    {:ok, signer} = Siwa.LocalSigner.new()
    PairingHelpers.pair_wallet!(String.downcase(signer.address))
    stranger = %{c | signer: signer}

    board = post!(stranger, @board, %{}, 403)
    assert board["error"]["code"] == "workspace_members_only"

    assert post!(stranger, @swarm, %{}, 403) == board
    assert post!(stranger, @things, %{}, 403) == board

    unknown = post!(c, @board, %{}, 404, "no_such_fleet")
    assert unknown["error"]["code"] == "fleet_unknown"
    assert post!(c, @swarm, %{}, 404, "no_such_fleet") == unknown
    assert post!(c, @things, %{}, 404, "no_such_fleet") == unknown
  end

  test "a body the Atlas can't read is refused before anything is read", c do
    for {template, body, code} <- [
          # An hour is shorter than a year, but a year holds more than 1,000.
          {@swarm, %{"window" => "year", "bucket" => "hour"}, "invalid_request"},
          {@swarm, %{"window" => "day", "bucket" => "day"}, "invalid_request"},
          {@swarm, %{"window" => "week", "bucket" => "month"}, "invalid_request"},
          {@swarm, %{"window" => "fortnight"}, "invalid_request"},
          {@swarm, %{"at" => "last tuesday"}, "invalid_request"},
          {@swarm, %{"most_active" => 51}, "out_of_range"},
          {@swarm, %{"most_active" => "5"}, "invalid_request"},
          {@swarm, %{"bucket" => "day", "limit" => 5}, "invalid_request"},
          {@things, %{"after" => "not a place"}, "invalid_request"},
          {@things, %{"kind" => "pin"}, "invalid_request"},
          {@things, %{"order" => "oldest"}, "invalid_request"},
          {@things, %{"limit" => 0}, "out_of_range"},
          {@things, %{"limit" => 101}, "out_of_range"}
        ] do
      refused = post!(c, template, body, 422)
      assert refused["error"]["code"] == code, inspect(body)
    end
  end

  # Every thing of the window, page after page, each page's next_after sent
  # back as after until there is none.
  defp pages(c, body) do
    page = post!(c, @things, body, 200)
    ids = Enum.map(page["things"], & &1["id"])

    case page["next_after"] do
      nil -> ids
      next -> ids ++ pages(c, Map.put(body, "after", next))
    end
  end

  defp counts(buckets),
    do: Enum.map(buckets, &{at(&1["at"]), &1["changes"], &1["things"], &1["actors"]})

  defp at(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    DateTime.truncate(at, :second)
  end

  # Signs and sends one request to the route `template` names, and holds its
  # answer, of `status`, to the contract.
  defp post!(c, template, body, status, fleet \\ @fleet) do
    path = String.replace(template, "{fleet_id}", fleet)
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "POST", path, raw)

    conn =
      request.headers
      |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 153}}, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> dispatch(@endpoint, :post, path, raw)

    answer = json_response(conn, status)
    assert ContractSchema.response_errors(answer, "POST", template, status) == []
    answer
  end

  defp record!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end
end
