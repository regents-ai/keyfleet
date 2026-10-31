defmodule KeyfleetWeb.AgentCodeCommitsTest do
  # Agents read a project's history and one commit through their own signed
  # requests, each commit naming the Key and agent whose push first sent it.
  # The code store is `Keyfleet.CodeHistory`'s line of commits.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, Code, CodeHistory, ContractSchema, Fleets, Keys, PairingHelpers}
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  # `general`'s repository is named after its fleet.
  @repository @fleet
  @api "/api/v1/agent/fleets/#{@fleet}/projects/general/code/commits"

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

  test "each commit names the push that first sent it, whichever push is followed up first", c do
    # Key 2's agent sent steps 1 and 2 to main, then steps 3 and 4.
    first = send!(c.agent, 2)
    second = send!(c.agent, 4)

    # The later push is followed up first: it still leaves out what the
    # earlier tip reaches.
    assert :ok = perform_job(Code.Sent, %{push_id: second.id})
    assert :ok = perform_job(Code.Sent, %{push_id: first.id})

    history = c |> post!(c.agent, @api, %{}) |> json_response(200)
    assert ContractSchema.errors(history, "CodeCommits") == []
    assert history["head"] == CodeHistory.hash(4)
    assert history["next"] == nil

    assert for(
             commit <- history["commits"],
             do: {commit["subject"], commit["sent_by"]["pushed_at"]}
           ) ==
             [
               {"Step 4", second.pushed_at},
               {"Step 3", second.pushed_at},
               {"Step 2", first.pushed_at},
               {"Step 1", first.pushed_at}
             ]
             |> Enum.map(fn {subject, at} -> {subject, DateTime.to_iso8601(at)} end)

    assert %{"token_id" => 2, "agent_name" => "Mate 2", "ref" => "refs/heads/main"} =
             hd(history["commits"])["sent_by"]

    commit = c |> get!(c.agent, "#{@api}/#{CodeHistory.hash(3)}") |> json_response(200)
    assert ContractSchema.errors(commit, "CodeCommit") == []
    assert commit["subject"] == "Step 3"
    assert commit["message"] =~ "Why step 3 was taken."
    assert commit["parents"] == [CodeHistory.hash(2)]
    assert [%{"path" => "steps/3.txt", "status" => "added", "additions" => 1}] = commit["files"]
    assert commit["sent_by"]["pushed_at"] == DateTime.to_iso8601(second.pushed_at)
  end

  test "the history reads on, thirty at a time, from the page it started on", c do
    send!(c.agent, 32)

    first = c |> post!(c.agent, @api, %{}) |> json_response(200)
    assert length(first["commits"]) == 30
    assert first["next"] == %{"from" => CodeHistory.hash(32), "page" => 2}

    # A commit sent meanwhile doesn't move the pages already started.
    send!(c.agent, 33)

    second = c |> post!(c.agent, @api, first["next"]) |> json_response(200)
    assert ContractSchema.errors(second, "CodeCommits") == []
    assert Enum.map(second["commits"], & &1["subject"]) == ["Step 2", "Step 1"]
    assert second["next"] == nil
  end

  test "a commit or a page the history doesn't have, or a body it doesn't take, is refused", c do
    send!(c.agent, 1)

    unknown = c |> get!(c.agent, "#{@api}/#{CodeHistory.hash(9)}") |> json_response(404)
    assert ContractSchema.errors(unknown, "CodeReadNotFoundError") == []
    assert unknown["error"]["code"] == "commit_unknown"

    for body <- [%{"page" => 2}, %{"from" => CodeHistory.hash(9)}, %{"from" => "main"}] do
      past = c |> post!(c.agent, @api, body) |> json_response(404)
      assert past["error"]["code"] == "history_page_unknown"
    end

    for body <- [%{"page" => "2"}, %{"cursor" => "x"}, %{"from" => 7}] do
      refused = c |> post!(c.agent, @api, body) |> json_response(422)
      assert refused["error"]["code"] == "invalid_request"
    end
  end

  # Key 2's agent sends steps 1 to `n` to main: the store holds them
  # and the push is recorded, its job waiting.
  defp send!(agent, n) do
    commits = Enum.map(n..1//-1, &CodeHistory.commit/1)
    Req.Test.stub(Code.NodeClient, &serve(&1, commits))
    waiting = waiting()

    :ok =
      Code.record_pushes(
        @fleet,
        "general",
        %{token_id: 2, wallet: agent.wallet, acting_agent_wallet: agent.wallet},
        [%{ref: "refs/heads/main", head: CodeHistory.hash(n)}]
      )

    [push_id] = waiting() -- waiting
    Code.push!(push_id, actor: %System{})
  end

  # The pushes whose commits are waiting to be recorded.
  defp waiting, do: for(job <- all_enqueued(worker: Code.Sent), do: job.args["push_id"])

  defp serve(conn, commits) do
    ["", "api", "v1", "repos", "z6MkOwner", @repository, "commits" | rest] =
      String.split(conn.request_path, "/")

    CodeHistory.answer(conn, commits, rest)
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
    {:ok, signer} = Siwa.LocalSigner.new()
    wallet = String.downcase(signer.address)

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

    Keyfleet.Agents.ensure_profile!(%{name: "Mate #{token_id}", declared_harness: "local"},
      actor: PairingHelpers.pair_wallet!(wallet)
    )

    %{signer: signer, wallet: wallet}
  end
end
