defmodule KeyfleetWeb.AgentNotebookFilesTest do
  # Agents make a fleet's notebooks and write their files through their own
  # signed requests here. The hub is a local server that keeps files as the
  # real one does: adding a file at a path already taken is refused.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, Fleets, Keys, Notebooks, PairingHelpers}
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @notebook "nb-0123456789abcdef"
  @api "/api/v1/agent/fleets/#{@fleet}/notebooks"
  @workspace "/api/v1/projects/proj-fleet/notebooks/#{@notebook}/workspace/"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    files = start_supervised!({Agent, fn -> %{} end})
    test = self()

    hub =
      SignedAgentHelpers.serve!(:hub, fn conn, _opts ->
        {:ok, body, conn} = read_body(conn)
        conn = fetch_query_params(conn)
        [pass] = get_req_header(conn, "x-keyfleet-assertion")
        subject = JOSE.JWT.peek_payload(pass).fields["sub"]
        send(test, {:hub, conn.method, conn.request_path, subject, conn.query_params, body})
        hub_answer(conn, files, body)
      end)

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :fleets, %{@fleet => hub}))
    Notebooks.record_hub!(@fleet, "proj-fleet", actor: %System{})

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    %{secret: secret, files: files, first: agent!(2), second: agent!(3)}
  end

  # Costly failure: agents keeping one shared log lose each other's entries,
  # because one agent's writing silently replaces another's at the same path.
  test "agents each add files of their own to one notebook, and adding never replaces a file",
       c do
    created =
      post!(c, c.first, "#{@api}/create", %{
        "title" => "Classic #1 pilot log",
        "code" => "import marimo",
        "idempotency_key" => "log-1"
      })

    assert json_response(created, 200) == %{
             "notebook_id" => @notebook,
             "title" => "Classic #1 pilot log"
           }

    first = c.first.subject

    assert_receive {:hub, "POST", "/api/v1/projects/proj-fleet/notebooks", ^first, _query, body}
    assert Jason.decode!(body)["description"] == ""

    files = "#{@api}/#{@notebook}/files/"
    entry = %{"path" => "log/a.md", "content" => "First, from the first agent."}
    assert json_response(post!(c, c.first, files <> "add", entry), 200)["path"] == "log/a.md"
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "true"}, _body}

    taken = post!(c, c.second, files <> "add", %{entry | "content" => "Second, over the first."})
    assert json_response(taken, 409)["error"]["code"] == "notebook_file_conflict"

    own = %{"path" => "log/b.md", "content" => "Second, from the second agent."}
    assert json_response(post!(c, c.second, files <> "add", own), 200)["path"] == "log/b.md"

    listed = json_response(post!(c, c.first, files <> "list", %{"path" => "log"}), 200)
    assert Enum.map(listed["entries"], & &1["path"]) == ["log/a.md", "log/b.md"]
    assert listed["cursor"] == nil

    read = &json_response(post!(c, c.second, files <> "read", %{"path" => &1}), &2)
    assert read.("log/a.md", 200)["content"] == "First, from the first agent."

    # Writing a file is how its own writer replaces it.
    post!(c, c.first, files <> "write", %{entry | "content" => "First, corrected."})
    assert_receive {:hub, "PUT", @workspace <> "files", ^first, %{"create" => "false"}, _body}
    assert read.("log/a.md", 200)["content"] == "First, corrected."

    assert read.("log/none.md", 404)["error"]["code"] == "notebook_file_not_found"
    Agent.update(c.files, &Map.put(&1, "chart.png", <<0xFF, 0xD8, 0xFF>>))
    assert read.("chart.png", 422)["error"]["code"] == "notebook_file_not_text"
    Agent.update(c.files, &Map.put(&1, "big.md", String.duplicate("a", 1024 * 1024 + 1)))
    assert read.("big.md", 422)["error"]["code"] == "notebook_file_too_large"
  end

  defp post!(c, agent, path, body) do
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(agent.signer, c.secret, "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
  end

  # An agent with a profile, paired with the person who owns Key `token_id`.
  defp agent!(token_id) do
    {:ok, signer} = Siwa.LocalSigner.new()
    wallet = String.downcase(signer.address)
    epoch!(token_id, wallet)

    profile =
      Keyfleet.Agents.ensure_profile!(%{name: "Mate #{token_id}", declared_harness: "local"},
        actor: PairingHelpers.pair_wallet!(wallet)
      )

    %{signer: signer, subject: Notebooks.agent_subject(profile.id)}
  end

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: owner,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end

  ## The hub

  defp hub_answer(
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/proj-fleet/notebooks"} = conn,
         _files,
         body
       ) do
    [_key] = get_req_header(conn, "idempotency-key")
    json(conn, 201, %{success: true, data: %{id: @notebook, title: Jason.decode!(body)["title"]}})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @workspace <> "entries"} = conn,
         files,
         _body
       ) do
    folder = conn.query_params["path"] <> "/"

    items =
      for {path, content} <- Enum.sort(Agent.get(files, & &1)),
          String.starts_with?(path, folder),
          do: item(path, content)

    json(conn, 200, %{success: true, data: %{items: items}})
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @workspace <> "files"} = conn,
         files,
         _body
       ) do
    case Agent.get(files, &Map.fetch(&1, conn.query_params["path"])) do
      {:ok, content} ->
        send_resp(conn, 200, content)

      :error ->
        json(conn, 404, %{success: false, error: %{code: "NOT_FOUND", message: "No such file"}})
    end
  end

  defp hub_answer(
         %Plug.Conn{method: "PUT", request_path: @workspace <> "files"} = conn,
         files,
         body
       ) do
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
         %Plug.Conn{method: "POST", request_path: "/api/v1/projects/proj-fleet/members"} = conn,
         _files,
         _body
       ),
       do: json(conn, 201, %{success: true, data: %{}})

  defp hub_answer(conn, _files, _body), do: json(conn, 200, %{success: true, data: %{}})

  defp item(path, content),
    do: %{
      path: path,
      name: Path.basename(path),
      kind: "file",
      size: byte_size(content),
      modified_at: 1
    }

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
