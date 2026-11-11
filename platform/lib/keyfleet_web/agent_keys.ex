defmodule KeyfleetWeb.AgentKeys do
  @moduledoc """
  The Keys a person's agents act for, as the Agents page shows them beside
  each agent (`KeyfleetWeb.AgentsPanel`) and once an agent pairs
  (`KeyfleetWeb.PairingBox`): each Key an agent's wallet holds an active shard
  of, linked to its page, or, for an agent with none, where to give it one: the
  agent's shard press on the page of a Key the person holds
  (`KeyfleetWeb.KeyLinks.give_shard_path/3`). An agent with no shard
  whose person holds no Key has neither.

  Shards and holders are public, as the chain records them. A failed read
  comes back as `{:error, failure}` (`KeyfleetWeb.PageRead`), so the page says
  so rather than crashing.
  """

  alias Keyfleet.Actors.Human
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.PageRead

  @doc """
  `{:ok, keys}`, where for each of `wallets` keys holds `{:shards, keys}`,
  each key `%{label, path}`; `{:give, path}`; or `nil`, read for the signed-in
  `account`. `{:error, failure}` when the read fails.
  """
  def read(_account, []), do: {:ok, %{}}

  def read(account, wallets) do
    PageRead.run("account", fn ->
      actor = Human.for_account(account)
      give_from = give_from(actor.wallet_addresses)

      Map.new(wallets, &{&1, keys(&1, actor, give_from)})
    end)
  end

  defp keys(wallet, actor, give_from) do
    case Keys.active_shards_held_by!(wallet, actor: actor) do
      [] -> give(give_from, wallet)
      shards -> {:shards, Enum.map(shards, &key/1)}
    end
  end

  defp key(%{fleet_id: fleet_id, token_id: token_id}),
    do: %{
      label: "#{Fleets.name(fleet_id)} Key #{Rules.grouped(token_id)}",
      path: KeyLinks.page_path(fleet_id, token_id)
    }

  defp give(nil, _wallet), do: nil

  defp give({fleet_id, token_id}, wallet),
    do: {:give, KeyLinks.give_shard_path(fleet_id, token_id, wallet)}

  # The person's lowest-numbered Key in the first open fleet where they hold one.
  defp give_from([]), do: nil

  defp give_from(wallets) do
    Enum.find_value(Fleets.open_fleet_ids(), fn fleet_id ->
      case fleet_id |> Keys.lowest_held(wallets, 1) |> Map.values() |> List.flatten() do
        [] -> nil
        token_ids -> {fleet_id, Enum.min(token_ids)}
      end
    end)
  end
end
