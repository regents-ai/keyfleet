defmodule KeyfleetWeb.AgentCodeFileTest do
  # Agents read one file of a project's code at a commit, whole, through their
  # own signed requests: the file a commit's read cuts short among them. The
  # code store holds one commit of a few files.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, Code, CodeHistory, ContractSchema, Fleets, Keys, PairingHelpers}
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  # `general`'s repository is named after its fleet.
  @repository @fleet
  @in_project "/api/v1/agent/fleets/#{@fleet}/projects/general/code"
  @limit 512 * 1024

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    Code.record_repository!(@repository, "z6MkOwner", actor: %System{})
    %{secret: secret, agent: agent!(2)}
  end

  test "a file whose patch the commit's read cut short comes back whole, with its size and sha256",
       c do
    whole = Enum.map_join(1..2_000, "\n", &"line #{&1}: #{String.duplicate("x", 40)}")
    assert byte_size(whole) > 64 * 1024
    commit = serve(%{"lib/big.ex" => whole, "README.md" => "Hello\n"})

    changed = c |> get!(c.agent, "#{@in_project}/commits/#{commit}") |> json_response(200)

    assert %{"patch_truncated" => true} =
             Enum.find(changed["files"], &(&1["path"] == "lib/big.ex"))

    file = c |> read!(%{"commit" => commit, "path" => "lib/big.ex"}) |> json_response(200)
    assert ContractSchema.errors(file, "CodeFile") == []
    assert file["content"] == whole
    assert file["size"] == byte_size(whole)
    assert file["sha256"] == :sha256 |> :crypto.hash(whole) |> Base.encode16(case: :lower)
    assert file["commit_url"] == changed["commit_url"]

    top = c |> read!(%{"commit" => commit, "path" => "README.md"}) |> json_response(200)
    assert %{"content" => "Hello\n", "size" => 6} = top
  end

  test "a file past the limit is refused with the limit and its size; one that isn't text plainly",
       c do
    large = :binary.copy("a", @limit + 1)
    commit = serve(%{"data/large.txt" => large, "data/picture.png" => <<0, 159, 146, 150>>})

    too_large =
      c |> read!(%{"commit" => commit, "path" => "data/large.txt"}) |> json_response(422)

    assert ContractSchema.errors(too_large, "CodeFileRefusedError") == []
    assert too_large["error"]["code"] == "code_file_too_large"
    assert too_large["error"]["hint"] =~ "#{@limit} bytes"
    assert too_large["error"]["hint"] =~ "#{@limit + 1}"

    # The largest file it reads comes back whole.
    commit = serve(%{"data/large.txt" => :binary.copy("a", @limit)})

    assert %{"size" => @limit} =
             c |> read!(%{"commit" => commit, "path" => "data/large.txt"}) |> json_response(200)

    commit = serve(%{"data/picture.png" => <<0, 159, 146, 150>>})

    not_text =
      c |> read!(%{"commit" => commit, "path" => "data/picture.png"}) |> json_response(422)

    assert ContractSchema.errors(not_text, "CodeFileRefusedError") == []
    assert not_text["error"]["code"] == "code_file_not_text"
  end

  test "an unknown path or commit, a folder, or a body it doesn't take is refused", c do
    commit = serve(%{"lib/app.ex" => "defmodule App do\nend\n"})

    for body <- [
          %{"commit" => commit, "path" => "lib/missing.ex"},
          %{"commit" => CodeHistory.hash(9), "path" => "lib/app.ex"},
          %{"commit" => commit, "path" => "lib"},
          %{"commit" => commit, "path" => "lib/../lib/app.ex"},
          %{"commit" => commit, "path" => "/lib/app.ex"}
        ] do
      unknown = c |> read!(body) |> json_response(404)
      assert ContractSchema.errors(unknown, "CodeFileNotFoundError") == []
      assert unknown["error"]["code"] == "file_unknown", inspect(body)
    end

    for body <- [
          %{"commit" => "main", "path" => "lib/app.ex"},
          %{"commit" => commit, "path" => ""},
          %{"commit" => commit, "path" => String.duplicate("a/", 512) <> "b"},
          %{"commit" => commit},
          %{"commit" => commit, "path" => "lib/app.ex", "page" => 1}
        ] do
      refused = c |> read!(body) |> json_response(422)
      assert refused["error"]["code"] == "invalid_request", inspect(body)
    end

    no_project =
      c
      |> post!(c.agent, "/api/v1/agent/fleets/#{@fleet}/projects/nothing/code/file", %{
        "commit" => commit,
        "path" => "lib/app.ex"
      })
      |> json_response(404)

    assert no_project["error"]["code"] == "project_unknown"
  end

  test "an agent whose person holds none of the fleet's Keys reads none of its files", c do
    commit = serve(%{"lib/app.ex" => "defmodule App do\nend\n"})
    body = %{"commit" => commit, "path" => "lib/app.ex"}

    refused = c |> post!(stranger!(), "#{@in_project}/file", body) |> json_response(403)
    assert ContractSchema.errors(refused, "CodeNotHolderError") == []
    assert refused["error"]["code"] == "code_not_holder"

    assert %{"content" => "defmodule App do\nend\n"} = c |> read!(body) |> json_response(200)
  end

  defp read!(c, body), do: post!(c, c.agent, "#{@in_project}/file", body)

  # The code store holding one commit of `files`, a path's bytes by its
  # path; the commit read cuts each file's patch at 64 KiB, as the store
  # does. Answers the commit's hash.
  defp serve(files) do
    hash = :sha |> :crypto.hash(:erlang.term_to_binary(files)) |> Base.encode16(case: :lower)
    commit = %{CodeHistory.commit(1) | "hash" => hash, "files" => Enum.map(files, &changed/1)}

    Req.Test.stub(Code.NodeClient, fn conn ->
      ["", "api", "v1", "repos", "z6MkOwner", @repository, read | segments] =
        String.split(conn.request_path, "/")

      path = Enum.map_join(segments, "/", &URI.decode/1)
      at = fetch_query_params(conn).query_params["ref"]

      case read do
        "commits" -> CodeHistory.answer(conn, [commit], segments)
        _read when at != hash -> send_resp(conn, 404, "")
        "tree" -> Req.Test.json(conn, %{"entries" => entries(files, path), "path" => path})
        "blob" -> blob(conn, files, path, hash)
      end
    end)

    hash
  end

  defp changed({path, bytes}) do
    %{
      "path" => path,
      "old_path" => nil,
      "status" => "added",
      "additions" => 1,
      "deletions" => 0,
      "binary" => false,
      "patch" => binary_part(bytes, 0, min(byte_size(bytes), 64 * 1024)),
      "patch_truncated" => byte_size(bytes) > 64 * 1024
    }
  end

  # `git show` answers a folder with its names, as text.
  defp blob(conn, files, path, hash) do
    case {files[path], entries(files, path)} do
      {nil, []} -> send_resp(conn, 404, "")
      {nil, entries} -> send_resp(conn, 200, folder_text(hash, path, entries))
      {bytes, _none} -> send_resp(conn, 200, bytes)
    end
  end

  defp folder_text(hash, path, entries),
    do: "tree #{hash}:#{path}\n\n" <> Enum.map_join(entries, "\n", & &1["name"])

  # Each entry of `folder` as the store answers it: its `git ls-tree -l` line.
  defp entries(files, folder) do
    prefix = if folder == "", do: "", else: folder <> "/"

    files
    |> Enum.filter(fn {path, _bytes} -> String.starts_with?(path, prefix) end)
    |> Enum.map(fn {path, bytes} ->
      case path |> String.replace_prefix(prefix, "") |> String.split("/", parts: 2) do
        [name] -> %{"type" => "blob", "name" => name, "size" => byte_size(bytes)}
        [name, _rest] -> %{"type" => "tree", "name" => name, "size" => nil}
      end
    end)
    |> Enum.uniq()
  end

  defp post!(c, agent, path, body) do
    raw = Jason.encode!(body)

    request =
      SignedAgentHelpers.sign(agent.signer, c.secret, "www.example.com", "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
  end

  defp get!(c, agent, path) do
    request = SignedAgentHelpers.sign(agent.signer, c.secret, "www.example.com", "GET", path, nil)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 150}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :get, path)
  end

  # An agent with a profile, owning Key `token_id`.
  defp agent!(token_id) do
    agent = stranger!()

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: agent.wallet,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )

    agent
  end

  # An agent with a profile, paired with a person holding no Key.
  defp stranger! do
    {:ok, signer} = Siwa.LocalSigner.new()
    wallet = String.downcase(signer.address)

    Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
      actor: PairingHelpers.pair_wallet!(wallet)
    )

    %{signer: signer, wallet: wallet}
  end
end
