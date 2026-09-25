defmodule Keyfleet.KeyThreadRaceTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  # Each post runs on a connection of its own and commits. The thread, its
  # posts, the keys and the fleet's key reading are all removed when the test
  # ends, so no other test sees them.
  @fleet "fibonacci_syndicate"

  setup do
    owners = for _ <- 1..2, do: random_wallet()
    token_ids = for _ <- 1..2, do: :rand.uniform(1_000_000_000) + 1_000_000_000

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Fleets.bootstrap_catalog!()
      ChainHelpers.seed_cursor!(@fleet)

      for {owner, token_id} <- Enum.zip(owners, token_ids) do
        Keys.record_epoch!(
          %{
            fleet_id: @fleet,
            token_id: token_id,
            ownership_epoch: 0,
            owner_wallet: owner,
            block_number: 10,
            block_hash: "0x" <> String.duplicate("a", 64),
            transaction_hash: random_hash(),
            log_index: 0
          },
          actor: %Actors.System{}
        )
      end
    end)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> clean_up(token_ids) end) end)

    %{
      owners: Enum.map(owners, &%Actors.Human{human_account_id: 1, wallet_addresses: [&1]}),
      thread_key: Enum.min(token_ids)
    }
  end

  test "two first posts to a key at the same moment open one thread between them",
       %{owners: owners, thread_key: thread_key} do
    results = race(thread_key, Enum.zip(owners, ["Welcome aboard", "Glad you are here"]))

    assert [{:ok, first}, {:ok, second}] = results
    assert first.room_id == second.room_id
    assert Enum.sort([first.seq, second.seq]) == [1, 2]

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      thread = Rooms.get_key_thread!(@fleet, thread_key)
      assert {thread.id, thread.head_seq} == {first.room_id, 2}
      assert Enum.map(Rooms.read_key_thread!(@fleet, thread_key), & &1.seq) == [1, 2]

      assert Repo.query!(
               "SELECT count(*) FROM keyfleet_app.rooms WHERE fleet_id = $1 AND kind = 'key'",
               [@fleet]
             ).rows == [[1]]
    end)
  end

  defp race(token_id, posts) do
    parent = self()

    callers =
      for {owner, body} <- posts do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, self()})

          receive do
            :go ->
              Rooms.send_to_key(
                %{
                  fleet_id: @fleet,
                  token_id: token_id,
                  body: body,
                  idempotency_key: Ash.UUID.generate()
                },
                actor: owner
              )
          after
            10_000 -> raise "posting barrier timed out"
          end
        end)
      end

    for _ <- callers do
      assert_receive {:ready, _}, 10_000
    end

    Enum.each(callers, &send(&1.pid, :go))
    Task.await_many(callers, 15_000)
  end

  # Posts and key records refuse to be deleted. Their guards are set aside
  # inside this one transaction, which no other connection sees, and are back
  # in place when it commits.
  defp clean_up(token_ids) do
    Repo.transaction(fn ->
      Repo.query!("ALTER TABLE keyfleet_app.messages DISABLE TRIGGER immutable_messages")
      Repo.query!("ALTER TABLE keyfleet_app.key_attachments DISABLE TRIGGER immutable_key_epochs")

      Repo.query!(
        "DELETE FROM keyfleet_app.messages WHERE room_id IN " <>
          "(SELECT id FROM keyfleet_app.rooms WHERE fleet_id = $1 AND kind = 'key')",
        [@fleet]
      )

      Repo.query!("DELETE FROM keyfleet_app.rooms WHERE fleet_id = $1 AND kind = 'key'", [@fleet])

      Repo.query!(
        "DELETE FROM keyfleet_app.key_attachments WHERE fleet_id = $1 AND token_id = ANY($2)",
        [@fleet, token_ids]
      )

      Repo.query!("DELETE FROM keyfleet_app.chain_cursors WHERE fleet_id = $1", [@fleet])
      Repo.query!("ALTER TABLE keyfleet_app.key_attachments ENABLE TRIGGER immutable_key_epochs")
      Repo.query!("ALTER TABLE keyfleet_app.messages ENABLE TRIGGER immutable_messages")
    end)
  end

  defp random_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
  defp random_hash, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
end
