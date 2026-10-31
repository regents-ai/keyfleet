defmodule KeyfleetWeb.AgentPinsTest do
  # An agent pins a project's code on the workspace board and takes its pin
  # off through its own signed requests, as its person does on the page. The
  # code store is a stand-in that holds one folder, `goals`, with one file.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.{Accounts, ChainHelpers, Code, Fleets, Graph, Keys, PairingHelpers, Projects}
  alias Keyfleet.Actors.{Human, System}
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  # `general`'s repository is named after its fleet.
  @repository @fleet
  @api "/api/v1/agent/fleets/#{@fleet}/graph"
  @person "0x00000000000000000000000000000000000000a1"
  @other "0x00000000000000000000000000000000000000b2"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    record!(1, @person)
    record!(2, @other)

    Projects.take_over_project!(@fleet, 1, "general",
      actor: %Human{human_account_id: 1, wallet_addresses: [@person]}
    )

    Code.record_repository!(@repository, "z6MkOwner", actor: %System{})
    Req.Test.stub(Code.NodeClient, &tree/1)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    {:ok, signer} = Siwa.LocalSigner.new()
    agent = PairingHelpers.pair_wallet!(String.downcase(signer.address), @person)
    %{secret: secret, signer: signer, agent: agent}
  end

  test "pins a folder and a file, keeps one pin when pinned again, and takes it off", c do
    folder = %{"project" => "general", "place" => "code", "target" => "goals"}

    pinned = c |> post!("pin", folder) |> json_response(200)

    assert pinned == %{
             "pin" => %{
               "project" => "general",
               "place" => "code",
               "target" => "goals",
               "title" => "goals",
               "folder" => true
             }
           }

    assert c |> post!("pin", folder) |> json_response(200) == pinned

    file = %{folder | "target" => "goals/first.md"}
    assert %{"pin" => %{"folder" => false}} = c |> post!("pin", file) |> json_response(200)

    assert pinned_paths() == ["goals", "goals/first.md"]

    assert c |> post!("unpin", folder) |> json_response(200) == %{"unpinned" => pinned["pin"]}
    assert pinned_paths() == ["goals/first.md"]

    again = c |> post!("unpin", folder) |> json_response(404)
    assert again["error"]["code"] == "pin_unknown"
  end

  test "what the project doesn't hold, or a project or fleet that isn't there, is refused", c do
    for {target, code} <- [
          {"plans", "pin_target_unknown"},
          {"goals/../goals", "pin_target_unknown"},
          {"goals/", "pin_target_unknown"}
        ] do
      body = %{"project" => "general", "place" => "code", "target" => target}
      assert c |> post!("pin", body) |> json_response(404) |> code() == code, target
    end

    # The fleet keeps no notebooks hub here, so no notebook is there to pin.
    notebook = %{"project" => "general", "place" => "docs", "target" => "nb-0123456789abcdef"}
    assert c |> post!("pin", notebook) |> json_response(404) |> code() == "pin_target_unknown"

    for name <- ["elsewhere", "General"] do
      elsewhere = %{"project" => name, "place" => "code", "target" => "goals"}
      assert c |> post!("pin", elsewhere) |> json_response(404) |> code() == "project_unknown"
    end

    for op <- ["pin", "unpin"] do
      body = %{"project" => "general", "place" => "code", "target" => "goals"}
      refused = post!(c, op, body, "/api/v1/agent/fleets/no_such_fleet/graph")
      assert refused |> json_response(404) |> code() == "fleet_unknown", op
    end

    for body <- [
          %{"project" => "general", "place" => "wall", "target" => "goals"},
          %{"project" => "general", "place" => "code", "target" => ""},
          %{"project" => "general", "place" => "code", "target" => String.duplicate("a", 1025)},
          %{"project" => "general", "place" => "code"}
        ] do
      refused = post!(c, "pin", body)
      assert refused.status == 422, inspect({body, refused.resp_body})
    end
  end

  test "another member's pin stays theirs", c do
    other =
      Accounts.register_verified!("did:privy:test-other", @other, [@other], actor: %System{})

    Graph.pin!(
      %{
        fleet_id: @fleet,
        project: "general",
        place: :code,
        target: "goals",
        title: "goals",
        folder?: true
      },
      actor: %Human{human_account_id: other.id, wallet_addresses: [@other]}
    )

    body = %{"project" => "general", "place" => "code", "target" => "goals"}
    assert c |> post!("unpin", body) |> json_response(403) |> code() == "pin_not_yours"

    # Pinning it too leaves the pin as its pinner made it.
    assert %{"pin" => %{"target" => "goals"}} = c |> post!("pin", body) |> json_response(200)
    assert [%{human_account_id: id}] = Graph.pins!(@fleet, :code, "general", authorize?: false)
    assert id == other.id
  end

  test "an agent whose person holds no Key in the fleet is told the workspace is for members",
       c do
    {:ok, signer} = Siwa.LocalSigner.new()
    PairingHelpers.pair_wallet!(String.downcase(signer.address))

    body = %{"project" => "general", "place" => "code", "target" => "goals"}
    refused = post!(%{c | signer: signer}, "pin", body)
    assert refused |> json_response(403) |> code() == "workspace_members_only"
  end

  defp code(body), do: body["error"]["code"]

  # Read past the policy: the test checks what the board holds, not who may
  # read it.
  defp pinned_paths do
    @fleet
    |> Graph.pins!(:code, "general", authorize?: false)
    |> Enum.map(& &1.target)
    |> Enum.sort()
  end

  # The code store's tree: the top holds the folder `goals`, which holds one file.
  defp tree(conn) do
    ["", "api", "v1", "repos", "z6MkOwner", @repository, "tree" | path] =
      String.split(conn.request_path, "/")

    case path do
      [""] -> Req.Test.json(conn, %{"entries" => [entry("goals", "tree")]})
      [] -> Req.Test.json(conn, %{"entries" => [entry("goals", "tree")]})
      ["goals"] -> Req.Test.json(conn, %{"entries" => [entry("first.md", "blob")]})
      _other -> Req.Test.json(conn, %{"entries" => []})
    end
  end

  defp entry(name, type), do: %{"name" => name, "type" => type, "size" => 10}

  defp post!(c, op, body, api \\ @api) do
    path = "#{api}/#{op}"
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 152}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
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
