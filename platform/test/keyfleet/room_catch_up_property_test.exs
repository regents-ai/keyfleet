defmodule Keyfleet.RoomCatchUpPropertyTest do
  @moduledoc """
  What lets an agent trust its place in the rooms: catching up from the place
  it last reached, however posts land between its catch-ups and however few
  it asks for at a time, it reads every post once, in each room's order, and
  none twice.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @fleet "fibonacci_syndicate"
  @rooms ["general", "coding"]
  @places %{graph: 0, proposals: 0, keys: [], dms: nil, quotes: nil}
  @system %Actors.System{}
  # The most posts one sync answers from a room (`Keyfleet.Rooms`).
  @sync_page 50

  setup do
    # A sync reads the workspace too, in a repeatable-read snapshot, which
    # Postgres allows inside the sandbox only at that level already.
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Every run posts; the hourly allowance an agent has is not what's checked.
    limits = Application.fetch_env!(:keyfleet, :limits)
    on_exit(fn -> Application.put_env(:keyfleet, :limits, limits) end)

    Application.put_env(
      :keyfleet,
      :limits,
      Keyword.put(limits, :agent_posts, limit: 1_000_000, window_seconds: 3_600)
    )

    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [wallet()]}
    epoch!()
    %{writer: PairingHelpers.agent_for!(owner)}
  end

  property "RC-SYNC: a sync from the cursors it last answered reads every post once, in order",
           %{writer: writer} do
    check all steps <- list_of(step(), max_length: 12), max_runs: 15 do
      start = Map.new(@rooms, &{&1, head(&1)})

      {posted, read, cursors} =
        Enum.reduce(steps, {[], [], start}, fn
          {:post, slug}, {posted, read, cursors} ->
            {[{slug, post!(writer, slug).id} | posted], read, cursors}

          # More than one sync answers from a room, so the next takes the rest.
          {:burst, slug}, {posted, read, cursors} ->
            burst = for _ <- 1..(@sync_page + 1), do: {slug, post!(writer, slug).id}
            {Enum.reverse(burst) ++ posted, read, cursors}

          :sync, {posted, read, cursors} ->
            {got, cursors} = sync!(writer, cursors)
            {posted, read ++ got, cursors}
        end)

      read = drain(writer, read, cursors)

      for slug <- @rooms do
        assert ids(read, slug) == posted |> Enum.reverse() |> ids(slug)
      end
    end
  end

  property "RC-PAGE: a room read page by page from any place reads every later post once",
           %{writer: writer} do
    check all count <- integer(0..8),
              back <- integer(0..10),
              limit <- integer(1..4),
              max_runs: 25 do
      for _ <- 1..count//1, do: post!(writer, "general")
      head = head("general")
      from = max(head - back, 0)

      pages = pages(writer, from, limit, [])
      seqs = pages |> List.flatten() |> Enum.map(& &1.seq)

      assert seqs == Enum.to_list((from + 1)..head//1)
      # Every page but the last is full and says more follow.
      for page <- Enum.drop(pages, -1), do: assert(length(page) == limit)
    end
  end

  defp step do
    frequency([
      {6, tuple({constant(:post), member_of(@rooms)})},
      {3, constant(:sync)},
      {1, tuple({constant(:burst), member_of(@rooms)})}
    ])
  end

  # One sync without waiting: the posts it answered, as `{slug, id}`, and the
  # cursors it answered for next time.
  defp sync!(writer, cursors) do
    {:ok, %{rooms: rooms}} =
      Rooms.sync(
        @fleet,
        Enum.map(@rooms, &%{slug: &1, after_seq: cursors[&1]}),
        @places,
        writer,
        false
      )

    {for(room <- rooms, post <- room.messages, do: {room.slug, post.id}),
     Map.new(rooms, &{&1.slug, &1.cursor})}
  end

  # Syncs until a sync answers nothing new.
  defp drain(writer, read, cursors) do
    case sync!(writer, cursors) do
      {[], _cursors} -> read
      {got, cursors} -> drain(writer, read ++ got, cursors)
    end
  end

  defp pages(writer, after_seq, limit, pages) do
    page = Rooms.read_messages!(@fleet, "general", %{after_seq: after_seq, limit: limit}, actor: writer)

    if Rooms.more_after?(page),
      do: pages(writer, List.last(page).seq, limit, [page | pages]),
      else: Enum.reverse([page | pages])
  end

  defp ids(pairs, slug), do: for({^slug, id} <- pairs, do: id)

  defp post!(writer, slug) do
    {:ok, post} =
      Rooms.send_message(
        %{fleet_id: @fleet, slug: slug, body: "Hull survey", idempotency_key: Ash.UUID.generate()},
        actor: writer
      )

    post
  end

  defp head(slug), do: Rooms.get_room!(@fleet, slug, authorize?: false).head_seq

  defp wallet, do: "0x" <> String.duplicate("a", 40)

  defp epoch! do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: wallet(),
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> Base.encode16(:crypto.hash(:sha256, "1/1"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end
end
