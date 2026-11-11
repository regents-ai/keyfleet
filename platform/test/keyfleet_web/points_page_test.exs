defmodule KeyfleetWeb.PointsPageTest do
  # What a signed-in person gets from Points on the first render, with no wait: their
  # own figures and their place on the leaderboard beside other people's names or
  # wallets, and what their paired agent reads at /api/v1/account/points. Keyfleet
  # earns nothing (no start time, no rule approved), so this test approves one rule and
  # a start time for itself and records an award the way a site's checked action does.
  # The board every reader shares is then read once, as its producer reads it on notice.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Points.Board
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.SignedAgentHelpers

  defmodule Source do
    @moduledoc false
    # The site's own check of an action, as an adapter answers it: the facts it saved.
    def verify(%{"source_event_key" => key}),
      do: Map.fetch(Application.get_env(:regent_points, :test_facts, %{}), key)
  end

  @rule "account.activated"

  setup %{conn: conn} do
    keys = [:starts_at, :approved_rules, :adapters, :test_facts]
    previous = Map.new(keys, &{&1, Application.fetch_env(:regent_points, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:regent_points, key, value)
        {key, :error} -> Application.delete_env(:regent_points, key)
      end)

      SharedReading.delete(Board.key())
    end)

    Application.put_env(:regent_points, :starts_at, DateTime.add(DateTime.utc_now(), -86_400))
    Application.put_env(:regent_points, :approved_rules, [@rule])
    Application.put_env(:regent_points, :adapters, %{@rule => Source})

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    {:ok, signer} = Siwa.LocalSigner.new()
    person_wallet = new_wallet()
    other_wallet = new_wallet()

    # The person's account is made with the pairing, named for their wallet.
    PairingHelpers.pair_wallet!(String.downcase(signer.address), person_wallet)

    person =
      Accounts.register_verified!(
        "did:privy:test-" <> person_wallet,
        person_wallet,
        [person_wallet],
        actor: %System{}
      )

    other =
      Accounts.register_verified!("did:privy:points-other", other_wallet, [other_wallet],
        actor: %System{}
      )

    for account <- [person, other], do: earn(account)
    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true)
    assert :ok = Board.read()

    %{
      conn: init_test_session(conn, %{human_account_id: person.id}),
      person: person,
      other: other,
      other_wallet: other_wallet,
      secret: secret,
      signer: signer
    }
  end

  test "the first render carries the person's figures, place and the open list", %{conn: conn} do
    page = conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()

    assert text(page, "#points-total .rg-points-total__figure") == "25"
    assert text(page, "#points-total dl") =~ "+25"
    assert text(page, "#points-total dl") =~ "#1"
    assert text(page, ~s(#points-todo li[data-done="true"])) =~ "Account activated"

    # Two accounts level on points share first place; only the reader's row is marked.
    ranks =
      page
      |> LazyHTML.query("#points-board li .rg-points-board__rank")
      |> Enum.map(&LazyHTML.text/1)

    assert ranks == ["1", "1"]
    assert page |> LazyHTML.query(~s(#points-board li[data-you="true"])) |> Enum.count() == 1
    refute text(page, "#points-page") =~ "Loading"
  end

  # Every wallet is public: another person with no name shows by their wallet, whose
  # copy icon copies it in full. Nothing else about the account leaves it.
  test "a person with no name shows by their wallet, with its copy icon", c do
    html = c.conn |> get("/account/points") |> html_response(200)
    page = LazyHTML.from_document(html)

    copies =
      page
      |> LazyHTML.query(
        ~s(#points-board li[data-you="false"] [id^="points-board-wallet-"][id$="-copy"])
      )
      |> LazyHTML.attribute("data-copy-text")

    assert c.other_wallet in copies
    assert text(page, "#points-board") =~ Regent.Primitives.short_address(c.other_wallet)
    refute html =~ c.other.privy_user_id
  end

  # A person's paired agent reads the same figures the page shows, and its copy of
  # the leaderboard carries a place, a name or wallet and a total for each row.
  test "a paired agent is answered with the page's figures", c do
    page = c.conn |> get("/account/points") |> html_response(200) |> LazyHTML.from_document()
    answer = c |> agent_points() |> json_response(200)

    assert answer["points"] == text(page, "#points-total .rg-points-total__figure")
    assert answer["rank"] == 1
    assert answer["earned_today"] == "25"

    assert %{"done" => true, "left" => false} =
             Enum.find(answer["to_do"], &(&1["label"] == "Account activated"))

    assert length(answer["leaderboard"]) ==
             page |> LazyHTML.query("#points-board li") |> Enum.count()

    for row <- answer["leaderboard"] do
      assert row |> Map.keys() |> Enum.sort() == ~w(ens_name name points rank wallet you)
    end

    assert %{"name" => nil, "ens_name" => nil, "you" => false} =
             Enum.find(answer["leaderboard"], &(&1["wallet"] == c.other_wallet))
  end

  # While the board is held for signed-in readers, a signed-out visitor gets none of it.
  test "a signed-out visitor is asked to sign in and gets nothing from the board", c do
    html = build_conn() |> get("/account/points") |> html_response(200)
    page = LazyHTML.from_document(html)

    assert Enum.count(LazyHTML.query(page, "#points-signed-out")) == 1
    assert Enum.empty?(LazyHTML.query(page, "#points-total"))
    assert Enum.empty?(LazyHTML.query(page, "#points-board"))
    refute html =~ c.other_wallet
  end

  # Where the page would show the board as not read, the agent gets no half answer.
  test "while the board is not read, the agent's whole answer is unavailable", c do
    SharedReading.delete(Board.key())

    assert %{"error" => %{"code" => "account_unavailable"}} =
             c |> agent_points() |> json_response(503)
  end

  # Records the account's activation the way a site's checked action does.
  defp earn(account) do
    key = "#{@rule}:#{account.id}"
    at = DateTime.utc_now()

    facts = %{
      source_app: "keyfleet",
      source_kind: "test",
      source_event_key: key,
      account_id: account.id,
      actor_kind: "human",
      actor_id: to_string(account.id),
      source_action_at: at,
      qualified_at: at,
      evidence_ref: "test:" <> key,
      evidence: %{}
    }

    saved = Application.get_env(:regent_points, :test_facts, %{})
    Application.put_env(:regent_points, :test_facts, Map.put(saved, key, facts))

    {:ok, _} =
      RegentPoints.record_event(
        %{rule_id: @rule, source_app: "keyfleet", source_kind: "test", source_event_key: key},
        actor: RegentPoints.Store.system()
      )
  end

  # The paired agent's own signed request; the sign-in service's check of its
  # signature is answered by the test's own server.
  defp agent_points(c) do
    path = "/api/v1/account/points"
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "GET", path, nil)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 152}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> get(path)
  end

  defp text(page, selector),
    do: page |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp new_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end
