defmodule Keyfleet.PostingKeyTest do
  @moduledoc """
  A person holding several of a fleet's Keys chooses the one they post as. What
  their agent writes for them is written as it, and the fleet's list of agents
  shows the agent as it, while their wallets hold it; once it leaves them they
  post as their first Key again. Only a Key their wallets hold is chosen.
  """
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Errors.KeyNotHeldError
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    # The person's two wallets hold Keys 25 and 41; their agent writes for them.
    epoch!(25, wallet("a"))
    epoch!(41, wallet("b"))

    writer =
      PairingHelpers.agent_for!(%Actors.Human{
        human_account_id: 0,
        wallet_addresses: [wallet("a"), wallet("b")]
      })

    %{writer: writer, person: writer.pairing}
  end

  test "a person's agent posts as their first Key until they choose another",
       %{writer: writer, person: person} do
    assert post!(writer, "First") |> written_as() == {25, wallet("a")}
    assert listed_key(writer) == 25

    assert {:ok, _choice} = Keys.choose_posting_key(@fleet, 41, actor: person)

    assert post!(writer, "Second") |> written_as() == {41, wallet("b")}
    assert listed_key(writer) == 41
    assert Keys.identity(person, @fleet) == %{token_id: 41, wallet: wallet("b")}
  end

  test "once the chosen Key leaves their wallets, they post as their first Key again",
       %{writer: writer, person: person} do
    assert {:ok, _choice} = Keys.choose_posting_key(@fleet, 41, actor: person)

    epoch!(41, wallet("c"), ownership_epoch: 2, log_index: 1)

    assert post!(writer, "After the sale") |> written_as() == {25, wallet("a")}
    assert listed_key(writer) == 25
  end

  test "a Key their wallets don't hold is refused and the choice stays",
       %{writer: writer, person: person} do
    epoch!(7, wallet("c"))
    assert {:ok, _choice} = Keys.choose_posting_key(@fleet, 41, actor: person)

    for token_id <- [7, 999] do
      assert {:error, %Ash.Error.Invalid{errors: [%KeyNotHeldError{}]}} =
               Keys.choose_posting_key(@fleet, token_id, actor: person)
    end

    assert {:error, %Ash.Error.Forbidden{}} = Keys.choose_posting_key(@fleet, 41, actor: writer)
    assert post!(writer, "Still") |> written_as() == {41, wallet("b")}
  end

  defp post!(actor, body) do
    {:ok, message} =
      Rooms.send_message(
        %{fleet_id: @fleet, slug: "general", body: body, idempotency_key: Ash.UUID.generate()},
        actor: actor
      )

    message
  end

  defp written_as(message), do: {message.as_key, message.author_wallet}

  defp listed_key(%Actors.Agent{wallet_address: wallet}),
    do: Enum.find(Keyfleet.Agents.agents_here!(@fleet), &(&1.wallet_address == wallet)).key

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp epoch!(token_id, owner, overrides \\ []) do
    %{
      fleet_id: @fleet,
      token_id: token_id,
      ownership_epoch: 1,
      owner_wallet: owner,
      block_number: 10 + token_id,
      block_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <>
          Base.encode16(:crypto.hash(:sha256, "#{token_id}/#{event.ownership_epoch}"),
            case: :lower
          )
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
