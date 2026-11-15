defmodule Keyfleet.SearchTest do
  # A fleet's search finds what each reader may read and nothing else, and
  # pages through every match once, whatever the page size.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Keyfleet.NotebookHubHelpers, only: [notebook: 4]

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Dms
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.NotebookHubHelpers
  alias Keyfleet.Notebooks
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Projects
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Search
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fibonacci_syndicate"
  @general "proj-0000000000000001"
  @understanding "proj-0000000000000002"

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)
    # Keys 1, 2 and 3 are sold, each to a different person.
    for {token_id, owner} <- [{1, "a"}, {2, "b"}, {3, "c"}], do: epoch!(token_id, owner)
    :ok
  end

  test "each reader finds what they may read" do
    writer = PairingHelpers.agent_for!(human("a"))
    post!(writer, "general", "The deploy went out at noon")
    post!(writer, "coding", "Deployed the survey script to the hull")
    wall!(human("b"), 1, "Thanks for the deploy")
    dm!(human("a"), 1, 2, "The deploy key is in the vault")
    task = Workspace.create(@fleet, "task", %{"title" => "Deploying the probe"})
    Workspace.create(@fleet, "note", %{"title" => "Lunch", "body" => "Soup"})

    member = found(human("a"), "deploy")
    assert kinds(member) == %{"dm" => 1, "item" => 1, "post" => 3}
    assert Enum.find(member, &(&1.kind == "item")).id == task

    # Key 3's holder reads every room and the workspace, but not a message
    # between Keys 1 and 2.
    assert kinds(found(human("c"), "deploy")) == %{"item" => 1, "post" => 3}

    # Anyone else finds the Public room's post and the wall's, nothing more.
    outsider = found(human("z"), "deploy")
    assert kinds(outsider) == %{"post" => 2}
    assert Enum.all?(outsider, &(&1.room == nil or &1.room.slug == "general"))
    assert kinds(found(nil, "deploy")) == %{"post" => 2}
  end

  test "a post written as a muted Key, or taken off its wall, is left out" do
    writer = PairingHelpers.agent_for!(human("a"))
    post!(writer, "general", "Rotor check passed")
    wall!(human("b"), 3, "Rotor spares arrived")

    Rooms.mute_key!(@fleet, 1, actor: human("c"))
    assert [%{wall: 3}] = found(human("c"), "rotor")

    [%{id: removed}] = Enum.filter(found(human("c"), "rotor"), &(&1.wall == 3))
    Rooms.remove_from_wall!(@fleet, 3, removed, actor: human("c"))
    assert found(human("c"), "rotor") == []
    assert length(found(human("b"), "rotor")) == 1
  end

  test "pages hold every match once, newest first, at any page size" do
    writer = PairingHelpers.agent_for!(human("a"))

    for n <- 1..7, do: post!(writer, "general", "Hull reading #{n}")
    for n <- 1..5, do: dm!(human("a"), 1, 2, "Hull note #{n}")
    for n <- 1..4, do: Workspace.create(@fleet, "note", %{"title" => "Hull plate #{n}"})

    whole = walk(human("a"), "hull", 50)
    assert length(whole) == 16
    assert Enum.uniq_by(whole, &{&1.kind, &1.id}) == whole

    assert whole
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [newer, older] -> DateTime.compare(newer.at, older.at) != :lt end)

    for size <- [1, 3, 7], do: assert(walk(human("a"), "hull", size) == whole)
  end

  # Costly failure: a fleet's notebooks never turn up in its search, so a
  # member looking for one by its title or description never finds it.
  test "a member finds the notebooks the hub lists for them by a word of their title or description" do
    serve!(%{
      @general => [
        notebook(1, "Hull survey", "Plates and rivets, port side", ~U[2026-11-01 09:00:00Z]),
        notebook(
          2,
          "Rotor log",
          "Readings of the HULL after the storm",
          ~U[2026-11-02 09:00:00Z]
        ),
        notebook(3, "Lunch", "Soup", ~U[2026-11-03 09:00:00Z])
      ]
    })

    assert [by_description, by_title] = found(human("a"), "hull")

    assert %{kind: "notebook", title: "Rotor log", project: "general", at: at} = by_description
    assert DateTime.compare(at, ~U[2026-11-02 09:00:00Z]) == :eq
    assert by_description.match == "Readings of the HULL after the storm"
    assert by_description.url == Notebooks.notebook_url(@fleet, @general, by_description.id)

    assert %{kind: "notebook", title: "Hull survey", match: "Plates and rivets, port side"} =
             by_title

    # The hub was asked as the member, never as the site.
    assert_received {:listed, @general, "u_97", "hull"}
    assert [%{title: "Lunch"}] = found(human("a"), "soup")
  end

  test "a project whose notebooks the hub doesn't let the reader into brings none, and nor does holding no Key" do
    serve!(%{
      @general => [notebook(1, "Hull survey", "", ~U[2026-11-01 09:00:00Z])],
      @understanding => {:status, 403}
    })

    assert [%{kind: "notebook", project: "general"}] = found(human("a"), "hull")
    assert_received {:listed, @general, "u_97", "hull"}
    assert_received {:listed, @understanding, "u_97", "hull"}

    assert found(human("z"), "hull") == []
    assert found(nil, "hull") == []
    refute_received {:listed, _space, _subject, _q}
  end

  test "pages hold every notebook once among the other matches, at any page size" do
    writer = PairingHelpers.agent_for!(human("a"))
    for n <- 1..3, do: post!(writer, "general", "Hull reading #{n}")
    now = DateTime.utc_now()

    serve!(%{
      @general => [
        notebook(1, "Hull plan", "", DateTime.add(now, 60)),
        notebook(2, "Hull a", "", DateTime.add(now, -60)),
        notebook(3, "Hull b", "", DateTime.add(now, -60))
      ],
      @understanding => [notebook(4, "Hull notes", "", DateTime.add(now, -30))]
    })

    whole = walk(human("a"), "hull", 50)
    assert kinds(whole) == %{"notebook" => 4, "post" => 3}
    assert Enum.uniq_by(whole, &{&1.kind, &1.id}) == whole

    assert whole
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [newer, older] -> DateTime.compare(newer.at, older.at) != :lt end)

    for size <- [1, 2, 3], do: assert(walk(human("a"), "hull", size) == whole)
  end

  test "a fleet without a hub, and a hub that doesn't answer in time, still find everything else" do
    writer = PairingHelpers.agent_for!(human("a"))
    post!(writer, "general", "Hull reading")

    assert [%{kind: "post"}] = found(human("a"), "hull")

    serve!(%{
      @general => {:after, 1_000, [notebook(1, "Hull survey", "", ~U[2026-11-01 09:00:00Z])]}
    })

    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    Application.put_env(:keyfleet, :notebooks, Keyword.put(notebooks, :search_timeout_ms, 100))

    assert [%{kind: "post"}] = found(human("a"), "hull")

    assert Repo.exists?(
             from(error in ErrorTracker.Error,
               where:
                 like(error.reason, ^"The notebook hub of #{@fleet} did not answer a search%")
             )
           )
  end

  test "a query with no words in it, or too long, is refused" do
    for query <- ["   ", "hull\0", "-zz", "-a -b", ~s(-"a b"), "or -a"] do
      assert Search.page(@fleet, query, nil, human("a")) == {:error, :query}, inspect(query)
    end

    assert Search.page(@fleet, String.duplicate("a", Search.max_query() + 1), nil, human("a")) ==
             {:error, :query}

    assert {:ok, %{matches: [], cursor: nil}} = Search.page(@fleet, "the", nil, human("a"))
    assert {:ok, %{matches: []}} = Search.page(@fleet, "hull -zz", nil, human("a"))
  end

  defp found(actor, query) do
    {:ok, %{matches: matches}} = Search.page(@fleet, query, nil, 50, actor)
    matches
  end

  defp walk(actor, query, size, cursor \\ nil, pages \\ []) do
    {:ok, %{matches: matches, cursor: next}} = Search.page(@fleet, query, cursor, size, actor)
    pages = [matches | pages]

    if next,
      do: walk(actor, query, size, next, pages),
      else: pages |> Enum.reverse() |> Enum.concat()
  end

  defp kinds(matches), do: Enum.frequencies_by(matches, & &1.kind)

  # The fleet's hub, with `general` and `understanding` each in a space of
  # their own.
  defp serve!(spaces) do
    for {project, space} <- [{"general", @general}, {"understanding", @understanding}] do
      @fleet
      |> Projects.project!(project, actor: %Actors.System{})
      |> Projects.record_space!(space, actor: %Actors.System{})
    end

    NotebookHubHelpers.serve!(@fleet, spaces)
  end

  defp post!(actor, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp wall!(actor, token_id, body) do
    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: token_id, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp dm!(actor, from, to, body) do
    Dms.send_dm!(
      %{
        fleet_id: @fleet,
        from_token_id: from,
        to_token_id: to,
        body: body,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  # Each person has their own account, so their mutes are their own.
  defp human(character),
    do: %Actors.Human{
      human_account_id: :binary.first(character),
      wallet_addresses: [wallet(character)]
    }

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet(owner),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/1"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end
