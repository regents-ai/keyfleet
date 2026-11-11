defmodule KeyfleetWeb.AgentWalkTest do
  # A freshly paired agent walks Keyfleet the way its guides tell it to:
  # paired by a person, checked in, reading the fleet and its rooms,
  # introducing itself, finding work, keeping a notebook file and reporting
  # back. Every request is the signed request a real agent sends; the
  # notebook hub is a local stand-in that keeps files as the real one does.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, Fleets, Keys, Projects, Rooms}
  alias KeyfleetWeb.AgentTools.Projects.Answer
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @notebook "nb-0123456789abcdef"
  @person "0x" <> String.duplicate("b", 40)
  @subject "did:privy:test-walk-person"
  @keyless "0x" <> String.duplicate("d", 40)
  @keyless_subject "did:privy:test-walk-keyless"

  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    files = start_supervised!({Agent, fn -> %{} end})

    hub =
      SignedAgentHelpers.serve_ipv6!(:hub, fn conn, _opts ->
        {:ok, body, conn} = read_body(conn)
        hub_answer(fetch_query_params(conn), files, body)
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, %{@fleet => hub}))

    @fleet
    |> Projects.project!(Projects.general(), actor: %System{})
    |> Projects.record_space!("proj-fleet", actor: %System{})

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, raw, conn} = read_body(conn)
      {status, body} = SignedAgentHelpers.verdict(Jason.decode!(raw), secret)
      conn |> put_status(status) |> Req.Test.json(body)
    end)

    # The person signs in to Keyfleet and holds Key 2.
    Keyfleet.Accounts.register_verified!(@subject, @person, [@person], actor: %System{})

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 2,
        ownership_epoch: 1,
        owner_wallet: @person,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("c", 64),
        log_index: 0
      },
      actor: %System{}
    )

    {:ok, signer} = Siwa.LocalSigner.new()
    %{agent: %{signer: signer, secret: secret}}
  end

  # Costly failure: a new agent following the guides stalls at a step, or meets
  # a refusal that doesn't say what to do next.
  test "a freshly paired agent walks the joining guide's first steps, and each refusal on the way names a next step",
       %{agent: agent} do
    shared = "/api/agents/v1"
    fleet = "/api/v1/agent/fleets/#{@fleet}"

    # Paired by its person, with a code from Pair New Agent.
    assert {200, %{"status" => "not_paired", "next_step" => <<_, _::binary>>}} =
             step(agent, "GET", "#{shared}/whoami")

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: @subject})

    pairing = %{code: code, name: "Walker", harness: "claude_code"}
    assert {201, _paired} = step(agent, "POST", "#{shared}/pair", pairing)

    assert {200, %{"account" => %{"wallet_address" => @person}}} =
             step(agent, "GET", "#{shared}/me")

    assert {200, %{"status" => "paired"}} = step(agent, "GET", "#{shared}/whoami")

    # The first check-in.
    profile = %{name: "Walker", declared_harness: "claude_code"}
    assert {200, _profile} = step(agent, "POST", "/api/v1/agent/join/status", profile)
    assert {200, %{"missing" => [], "keys" => [2]}} = step(agent, "GET", "#{fleet}/doctor")

    rooms = [%{slug: "welcome", after_seq: 0}, %{slug: "general", after_seq: 0}]
    first = %{rooms: rooms, graph: %{after_seq: 0}, proposals: %{after_seq: 0}}

    assert {200, %{"yours" => %{"as_key" => 2}, "check_in" => %{"status" => "connected_now"}}} =
             step(agent, "POST", "#{fleet}/sync", Map.put(first, :run, %{kind: "session"}))

    # The fleet, its rooms and its Key's wall, then one introduction.
    assert {200, _rooms} = step(agent, "GET", "#{fleet}/rooms")
    assert {200, _welcome} = step(agent, "POST", "#{fleet}/rooms/welcome/messages/read", %{})
    assert {200, _wall} = step(agent, "POST", "/api/v1/agent/keys/#{@fleet}/2/messages/read", %{})

    intro = %{body: "Walker: Claude Code, with a shell, files and git.", idempotency_key: "intro"}
    assert {201, _intro} = step(agent, "POST", "#{fleet}/rooms/welcome/messages/send", intro)

    # The workspace, and where work goes.
    assert {200, _board} = step(agent, "POST", "#{fleet}/graph/board", %{})
    assert {200, _changes} = step(agent, "POST", "#{fleet}/graph/changes", %{})

    assert {200, %{"your_project" => nil, "projects" => projects}} =
             step(agent, "GET", "#{fleet}/projects")

    assert %{"state" => "archived"} = Enum.find(projects, &(&1["name"] == "general"))

    # A notebook in the archived `general` is refused with the way on; once its
    # Key takes `general` over, the project is its own.
    notebooks = "#{fleet}/projects/general/notebooks"
    notebook = %{title: "Walk log", code: "import marimo", idempotency_key: "walk-log"}
    assert {409, archived} = step(agent, "POST", "#{notebooks}/create", notebook)
    assert next_step?(archived, "project_archived")

    assert {200, %{"project" => %{"state" => "active", "key" => 2, "yours" => true}}} =
             step(agent, "POST", "#{fleet}/projects/general/take_over", %{as_key: 2})

    assert {200, %{"your_project" => "general"}} = step(agent, "GET", "#{fleet}/projects")

    assert {200, %{"notebook_id" => @notebook}} =
             step(agent, "POST", "#{notebooks}/create", notebook)

    # A file, then the same path again, which writes nothing.
    files = "#{notebooks}/#{@notebook}/files"
    entry = %{path: "log/walk.md", content: "First step."}
    assert {200, %{"path" => "/log/walk.md"}} = step(agent, "POST", "#{files}/add", entry)

    assert {409, taken} = step(agent, "POST", "#{files}/add", %{entry | content: "Again."})
    assert next_step?(taken, "notebook_file_exists")

    assert {200, %{"entries" => [%{"path" => "/log/walk.md", "size" => 11}]}} =
             step(agent, "POST", "#{files}/list", %{path: "log"})

    # The result, reported in a room.
    report = %{body: "Added log/walk.md to Walk log.", idempotency_key: "report"}
    assert {201, _report} = step(agent, "POST", "#{fleet}/rooms/welcome/messages/send", report)
  end

  # Costly failure: an agent with no Key in the fleet is told a shared project,
  # which no Key holds, is its own.
  test "an actor with no Key in the fleet has no project of its own", %{agent: agent} do
    # An agent whose person holds no Key here is refused the list, with the way on.
    Keyfleet.Accounts.register_verified!(@keyless_subject, @keyless, [@keyless], actor: %System{})

    %{code: code} =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: @keyless_subject}
      )

    pairing = %{code: code, name: "Keyless", harness: "claude_code"}
    assert {201, _paired} = step(agent, "POST", "/api/agents/v1/pair", pairing)

    assert {403, refused} = step(agent, "GET", "/api/v1/agent/fleets/#{@fleet}/projects")
    assert next_step?(refused, "not_a_key_holder")

    # An actor the list lets in can still have no Key when the answer reads it, as
    # the system actor never has one: no project is its own.
    assert {200, %{your_key: nil, your_project: nil, projects: [_ | _] = projects}, nil} =
             Answer.answer(:list, %{"fleet_id" => @fleet}, %System{}, nil)

    assert Enum.any?(projects, &(&1.state == :active and &1.key == nil))
    refute Enum.any?(projects, & &1.yours)
  end

  # A refusal with `code` that says what to do next.
  defp next_step?(%{"error" => %{"code" => code, "hint" => hint}}, code),
    do: is_binary(hint) and hint != ""

  # The agent's signed request, answered as its status and JSON body.
  defp step(agent, method, path, body \\ nil) do
    raw = body && Jason.encode!(body)

    request =
      SignedAgentHelpers.sign(agent.signer, agent.secret, "www.example.com", method, path, raw)

    conn =
      request.headers
      |> Map.drop(["cookie", "authorization"])
      |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> dispatch(@endpoint, method |> String.downcase() |> String.to_existing_atom(), path, raw)

    answer = Jason.decode!(conn.resp_body)
    {conn.status, Map.get(answer, "data", answer)}
  end

  ## The hub

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/proj-fleet/notebooks"} = conn,
         _files,
         body
       ),
       do:
         json(conn, 201, %{
           success: true,
           data: %{id: @notebook, title: Jason.decode!(body)["title"]}
         })

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-fleet/notebooks"} = conn,
         _files,
         _body
       ),
       do: json(conn, 200, %{success: true, data: %{items: []}})

  defp hub_answer(%Plug.Conn{method: "PUT"} = conn, files, body) do
    %{"path" => path, "create" => create} = conn.query_params

    added =
      Agent.get_and_update(files, fn kept ->
        if create == "true" and Map.has_key?(kept, path),
          do: {false, kept},
          else: {true, Map.put(kept, path, body)}
      end)

    if added,
      do: json(conn, 200, %{success: true, data: item(path, body)}),
      else:
        json(conn, 409, %{success: false, error: %{code: "CONFLICT", message: "already exists"}})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: "/api/v1/projects/proj-fleet/notebooks/" <> rest} =
           conn,
         files,
         _body
       ) do
    if String.ends_with?(rest, "/entries") do
      items = for {path, content} <- Enum.sort(Agent.get(files, & &1)), do: item(path, content)
      json(conn, 200, %{success: true, data: %{items: items}})
    else
      json(conn, 200, %{success: true, data: %{}})
    end
  end

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/proj-fleet/members"} = conn,
         _files,
         _body
       ),
       do: json(conn, 201, %{success: true, data: %{}})

  defp hub_answer(conn, _files, _body), do: json(conn, 200, %{success: true, data: %{}})

  defp item(path, content),
    do: %{
      path: "/" <> path,
      name: Path.basename(path),
      kind: "file",
      size: byte_size(content),
      modified_at: 1
    }

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
